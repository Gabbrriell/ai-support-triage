-- Support triage schema. Runs once on first start (empty pg_data volume).
-- To re-run from scratch: docker compose down -v && docker compose up -d

CREATE EXTENSION IF NOT EXISTS vector;    -- pgvector, for KB embeddings (weekend 2+)
CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- fuzzy matching on KB titles

-- ---------------------------------------------------------------------------
-- tickets: one row per incoming ticket, written by the webhook step
-- ---------------------------------------------------------------------------
CREATE TABLE tickets (
    id              bigserial PRIMARY KEY,
    external_id     text UNIQUE,                       -- Zendesk/Freshdesk id, null for test tickets
    source          text NOT NULL DEFAULT 'webhook',    -- webhook | zendesk | freshdesk | eval
    customer_email  text,
    customer_name   text,
    account_name    text,                              -- the client company
    subject         text NOT NULL,
    body            text NOT NULL,
    raw_payload     jsonb,                             -- full webhook body, for debugging
    status          text NOT NULL DEFAULT 'new'
                    CHECK (status IN ('new','classified','human_queue','draft_review',
                                      'approved','closed','error')),
    received_at     timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX tickets_received_at_idx ON tickets (received_at);
CREATE INDEX tickets_status_idx      ON tickets (status);

-- ---------------------------------------------------------------------------
-- classifications: Claude's verdict per ticket. Keep every attempt, so a
-- re-run with a new prompt version doesn't overwrite history.
-- ---------------------------------------------------------------------------
CREATE TABLE classifications (
    id              bigserial PRIMARY KEY,
    ticket_id       bigint NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
    category        text CHECK (category IN ('data_discrepancy','connector_auth',
                                             'api_error','billing','other')),
    priority        text CHECK (priority IN ('urgent','high','normal','low')),
    confidence      numeric(4,3) CHECK (confidence BETWEEN 0 AND 1),
    reasoning       text,                              -- one-liner from the model, handy for review
    is_valid        boolean NOT NULL DEFAULT true,     -- false if JSON failed schema validation
    raw_response    jsonb,                             -- exactly what Claude returned
    model           text,
    prompt_version  text NOT NULL DEFAULT 'v1',
    input_tokens    int,
    output_tokens   int,
    created_at      timestamptz NOT NULL DEFAULT now(),
    -- a valid row must have all three fields
    CHECK (NOT is_valid OR (category IS NOT NULL AND priority IS NOT NULL AND confidence IS NOT NULL))
);
CREATE INDEX classifications_ticket_idx ON classifications (ticket_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- kb_articles: the knowledge base. Keyword search now, vectors later.
-- ---------------------------------------------------------------------------
-- builds the search document; marked IMMUTABLE so it can be a generated column
-- (array_to_string on its own is only STABLE)
CREATE FUNCTION kb_search_doc(p_title text, p_tags text[], p_body text)
RETURNS tsvector LANGUAGE sql IMMUTABLE AS $$
    SELECT setweight(to_tsvector('english'::regconfig, coalesce(p_title,'')), 'A') ||
           setweight(to_tsvector('english'::regconfig, coalesce(array_to_string(p_tags,' '),'')), 'A') ||
           setweight(to_tsvector('english'::regconfig, coalesce(p_body,'')), 'B')
$$;

CREATE TABLE kb_articles (
    id          bigserial PRIMARY KEY,
    slug        text UNIQUE NOT NULL,
    title       text NOT NULL,
    body        text NOT NULL,
    category    text CHECK (category IN ('data_discrepancy','connector_auth',
                                         'api_error','billing','other')),
    tags        text[] NOT NULL DEFAULT '{}',
    search_tsv  tsvector GENERATED ALWAYS AS (kb_search_doc(title, tags, body)) STORED,
    -- 1024 dims = Voyage voyage-3.5 (Anthropic's recommended embeddings).
    -- Change the number if you pick another model. Null until weekend 2.
    embedding   vector(1024),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX kb_articles_tsv_idx   ON kb_articles USING gin (search_tsv);
CREATE INDEX kb_articles_title_trgm ON kb_articles USING gin (title gin_trgm_ops);
-- add when embeddings exist:
-- CREATE INDEX kb_articles_embedding_idx ON kb_articles USING hnsw (embedding vector_cosine_ops);

-- Keyword KB search. ORs the ticket's words (plain AND would almost never match
-- a whole ticket), ranks by relevance, small boost for matching category.
-- n8n usage:  SELECT * FROM search_kb($1, $2, 3);
CREATE FUNCTION search_kb(query_text text, ticket_category text DEFAULT NULL, k int DEFAULT 3)
RETURNS TABLE (id bigint, slug text, title text, body text, category text, score real)
LANGUAGE sql STABLE AS $$
    WITH q AS (
        SELECT nullif(replace(plainto_tsquery('english', query_text)::text, '&', '|'), '')::tsquery AS tsq
    )
    SELECT a.id, a.slug, a.title, a.body, a.category,
           (ts_rank_cd(a.search_tsv, q.tsq)
             + CASE WHEN a.category = ticket_category THEN 0.2 ELSE 0 END)::real AS score
    FROM kb_articles a, q
    WHERE q.tsq IS NOT NULL AND a.search_tsv @@ q.tsq
    ORDER BY score DESC
    LIMIT k;
$$;

-- ---------------------------------------------------------------------------
-- drafts: Claude's reply + routing decision + what the human did with it.
-- Nothing here is ever auto-sent; status only moves via a human.
-- ---------------------------------------------------------------------------
CREATE TABLE drafts (
    id                 bigserial PRIMARY KEY,
    ticket_id          bigint NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
    classification_id  bigint REFERENCES classifications(id),
    draft_body         text,                            -- null if routed to human with no draft
    kb_article_ids     bigint[] NOT NULL DEFAULT '{}',  -- which articles were fed to Claude
    model_unsure       boolean NOT NULL DEFAULT false,  -- Claude said "not sure"
    routed_to          text NOT NULL CHECK (routed_to IN ('human_queue','draft_review')),
    routing_reason     text NOT NULL,                   -- e.g. 'confidence<0.7', 'priority=urgent', 'model_unsure'
    review_status      text NOT NULL DEFAULT 'pending'
                       CHECK (review_status IN ('pending','approved','rejected')),
    final_body         text,                            -- what the agent actually sent
    was_edited         boolean GENERATED ALWAYS AS (
                           final_body IS NOT NULL AND draft_body IS NOT NULL
                           AND final_body IS DISTINCT FROM draft_body
                       ) STORED,
    reviewed_by        text,
    reviewed_at        timestamptz,
    model              text,
    prompt_version     text NOT NULL DEFAULT 'v1',
    input_tokens       int,
    output_tokens      int,
    created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX drafts_ticket_idx ON drafts (ticket_id);
CREATE INDEX drafts_queue_idx  ON drafts (routed_to, review_status);

-- ---------------------------------------------------------------------------
-- pipeline_steps: one row per step per ticket. Feeds latency + error panels.
-- ---------------------------------------------------------------------------
CREATE TABLE pipeline_steps (
    id               bigserial PRIMARY KEY,
    ticket_id        bigint REFERENCES tickets(id) ON DELETE CASCADE,
    n8n_execution_id text,
    step             text NOT NULL CHECK (step IN ('ingest','classify','kb_lookup','draft','route')),
    status           text NOT NULL DEFAULT 'ok' CHECK (status IN ('ok','error','retry')),
    started_at       timestamptz NOT NULL,
    finished_at      timestamptz NOT NULL,
    duration_ms      int GENERATED ALWAYS AS (
                         (extract(epoch FROM (finished_at - started_at)) * 1000)::int
                     ) STORED,
    error_message    text,
    meta             jsonb                              -- anything else: kb hit count, retries, etc.
);
CREATE INDEX pipeline_steps_ticket_idx ON pipeline_steps (ticket_id);
CREATE INDEX pipeline_steps_time_idx   ON pipeline_steps (started_at);

-- ---------------------------------------------------------------------------
-- Eval set (weekend 2): labelled fake tickets + per-run results
-- ---------------------------------------------------------------------------
CREATE TABLE eval_cases (
    id                 serial PRIMARY KEY,
    subject            text NOT NULL,
    body               text NOT NULL,
    expected_category  text NOT NULL CHECK (expected_category IN ('data_discrepancy','connector_auth',
                                                                  'api_error','billing','other')),
    expected_priority  text NOT NULL CHECK (expected_priority IN ('urgent','high','normal','low')),
    notes              text                              -- why this label, tricky bits
);

CREATE TABLE eval_runs (
    id              serial PRIMARY KEY,
    prompt_version  text NOT NULL,
    model           text NOT NULL,
    notes           text,                                -- e.g. "added few-shot for GA4 vs Meta"
    started_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE eval_results (
    run_id              int NOT NULL REFERENCES eval_runs(id) ON DELETE CASCADE,
    case_id             int NOT NULL REFERENCES eval_cases(id) ON DELETE CASCADE,
    predicted_category  text,
    predicted_priority  text,
    confidence          numeric(4,3),
    is_valid_json       boolean NOT NULL DEFAULT true,
    PRIMARY KEY (run_id, case_id)
);

CREATE VIEW v_eval_accuracy AS
SELECT r.id AS run_id, r.prompt_version, r.model, r.notes,
       count(*)                                                        AS cases,
       round(avg((res.predicted_category = c.expected_category)::int), 3) AS category_acc,
       round(avg((res.predicted_priority = c.expected_priority)::int), 3) AS priority_acc,
       round(avg(res.is_valid_json::int), 3)                           AS valid_json_rate
FROM eval_runs r
JOIN eval_results res ON res.run_id = r.id
JOIN eval_cases c     ON c.id = res.case_id
GROUP BY r.id;

-- ---------------------------------------------------------------------------
-- Time saved. Baseline = how long a human takes without the agent, per category.
-- Tune these numbers and say where they came from in the README.
-- ---------------------------------------------------------------------------
CREATE TABLE handling_baselines (
    category                   text PRIMARY KEY,
    manual_triage_minutes      numeric NOT NULL,   -- reading + categorising + finding KB
    manual_reply_minutes       numeric NOT NULL,   -- writing the reply from scratch
    review_draft_minutes       numeric NOT NULL,   -- reviewing an approved-as-is draft
    edit_draft_minutes         numeric NOT NULL    -- reviewing + editing a draft
);
INSERT INTO handling_baselines VALUES
    ('data_discrepancy', 6, 12, 2, 5),
    ('connector_auth',   3,  6, 1, 3),
    ('api_error',        5, 10, 2, 5),
    ('billing',          3,  6, 1, 3),
    ('other',            4,  8, 2, 4);

-- minutes saved per reviewed ticket: (triage + reply) minus what the human actually spent
CREATE VIEW v_time_saved AS
SELECT d.id AS draft_id, d.ticket_id, t.received_at, c.category, d.was_edited,
       (b.manual_triage_minutes + b.manual_reply_minutes)
       - CASE WHEN d.was_edited THEN b.edit_draft_minutes ELSE b.review_draft_minutes END
         AS minutes_saved
FROM drafts d
JOIN tickets t              ON t.id = d.ticket_id
JOIN classifications c      ON c.id = d.classification_id
JOIN handling_baselines b   ON b.category = c.category
WHERE d.review_status = 'approved' AND d.routed_to = 'draft_review';

-- ---------------------------------------------------------------------------
-- Permissions: n8n workflows connect as triage_app, Grafana as grafana_ro
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO triage_app, grafana_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO triage_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO triage_app;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO triage_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO triage_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_ro;
