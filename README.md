# AI Support Ticket Triage

An AI agent that triages support tickets for a marketing data platform. It classifies each ticket, finds relevant help articles, drafts a reply and routes it to the right queue. **Nothing is ever sent automatically:** a human approves, edits or rejects every draft, and every step is logged and measured. An MCP server lets Claude Code query the ticket data directly.

Built with n8n, Postgres and Grafana, all self-hosted in one `docker-compose.yml`. The LLM runs on Groq (`openai/gpt-oss-120b`), but the pipeline is model-agnostic: swapping models is a one-node change.

**Highlights**

- **Priority accuracy 64% → 78%** across 3 measured prompt versions, category accuracy 100%, with **zero critical tickets downgraded**
- **~2.3 seconds** from ticket received to draft ready, about 2,000 tokens per ticket
- **Found the real bottleneck:** knowledge base coverage, not the model. 51% of tickets had no matching article
- **Claude Code + MCP** over the ticket database, read-only, for questions like "which KB articles should we write next?"

![Dashboard](docs/dashboard.png)

## The problem

Support teams at marketing data platforms see the same ticket types every day: "Meta spend doesn't match Ads Manager", "Google Ads connector says invalid_grant", "GA4 conversions are missing". Each one needs to be read, categorised, prioritised, matched to the right help article and answered. That's 10 to 20 minutes of agent time per ticket before any real investigation starts.

The risky part isn't speed, it's priority. A broken pipeline sitting in a normal queue means a customer's dashboards are wrong all day.

## How it works

```mermaid
flowchart LR
    A[Ticket webhook] --> B[(Save ticket)]
    B --> C[LLM: classify<br/>category, priority, confidence]
    C --> D[Validate JSON]
    D --> E[(Save classification)]
    E --> F[(KB keyword search)]
    F --> G[LLM: draft reply<br/>KB only, says when unsure]
    G --> H{Route}
    H -- "high/urgent, unsure,<br/>low confidence, invalid" --> I[Human queue]
    H -- "confident, normal/low" --> J[Draft review]
    I --> K[Review endpoint:<br/>approve / edit / reject]
    J --> K
    K --> L[(Logs, latency,<br/>time saved)]
    L --> M[Grafana]
    L --> N[MCP server<br/>read-only]
    N --> O[Claude Code]
```

1. **Ingest:** a webhook receives the ticket and stores it in Postgres with the raw payload.
2. **Classify:** the LLM returns category, priority, confidence and a one-line reason. Output is forced into a strict JSON schema, then validated again in code. Invalid output is flagged, never trusted, and the ticket goes to a human.
3. **KB lookup:** Postgres full-text search over help articles, with a boost for articles in the same category.
4. **Draft:** the LLM writes a reply using only the KB articles it was given. If they don't cover the issue, it says so (`is_unsure`) instead of guessing, and asks for the specific details needed.
5. **Route:** high or urgent priority, an unsure drafter, low confidence or invalid output goes to the human queue. Everything else becomes a draft waiting for an agent.
6. **Review:** a separate endpoint lets an agent approve as-is, approve with edits, or reject. Whether the draft was edited is tracked automatically.
7. **Measure:** latency and tokens per step, routing reasons, edit rate and estimated time saved, all queryable in SQL, shown in Grafana and available to Claude Code through MCP.

## Results

### Eval: 36 labelled tickets, 3 prompt versions

I wrote 36 realistic tickets across all 5 categories, including deliberately tricky ones (an auth error that looks like an API error, a vague "numbers look weird", a ticket with two issues). Each prompt version runs the full set through an n8n eval workflow and gets scored in SQL.

| Prompt | Change | Category | Priority | Too high | Too low | Critical tickets downgraded |
|---|---|---|---|---|---|---|
| v1 | Baseline | 97.2% | 63.9% | 12 | 1 | 0 |
| v2 | "Start from normal, escalate only with evidence" | 100% | 61.1% | 2 | 12 | 9 |
| v3 | Priority defined by impact: "is data still flowing, will it recover?" Ties go up | **100%** | **77.8%** | 6 | 2 | **0** |

What I learned:

- **The overall score hides the direction of mistakes.** v1 over-escalated almost everything, which sends most tickets to humans and kills the automation. v2 fixed that by overcorrecting: its score barely moved, but it downgraded 9 genuinely broken pipelines. That's the dangerous failure, so I started tracking too-high and too-low separately.
- **Describe impact, not surface features.** v2 said "an error message alone is not high", so the model downgraded real outages. v3 asks whether the customer's data is still flowing, which generalises better.
- **Errors aren't symmetric.** An extra human review costs a few minutes. A missed outage costs a customer's trust. v3 deliberately breaks ties upwards.
- **Labels can be wrong too.** After v3, I reviewed every miss and asked "is the model wrong or is my label wrong?" One label was inconsistent with my own rubric (#24, auth failing on every run, labelled normal while a similar ticket was high). I fixed it with a written reason, and all runs were rescored against the corrected label.
- **I stopped at v3.** Tuning further against the same 36 tickets would mostly overfit to them.

### Live pipeline (synthetic demo traffic)

| Metric | Value |
|---|---|
| Median time, ticket received to draft saved | ~2.3 s |
| Slowest step | Drafting, ~1.5 s average, ~2.1 s p95 |
| Tokens per ticket (classify + draft) | ~2,000 |
| Tickets auto-drafted (not sent to human queue) | ~28% |
| Approved drafts edited by the agent | ~22% |
| Estimated time saved per approved draft | ~12.5 min |

### The bottleneck is the knowledge base, not the AI

In a demo run of 43 tickets, the drafter flagged `model_unsure` on **51%** of them. For 11 tickets it was the *only* reason they went to a human. The KB has just 6 articles, so the drafter correctly refuses to guess.

That means automation could roughly double (about 28% to 53%) **without touching the model**, just by writing help articles for the gaps. The "why tickets went where they did" panel in Grafana, and the `kb_gaps` MCP tool below, show exactly which gaps to fill first.

### Self-reported confidence is useless for routing

The confidence threshold never fired once. The model reports 0.93 to 0.98 confidence on everything, including a ticket that just says "numbers look weird". Self-reported LLM confidence is poorly calibrated, so routing relies on priority and the drafter's `is_unsure` flag instead.

## Claude Code + MCP

`mcp-server/server.py` is a small MCP server over the ticket database. Registered in Claude Code, it turns the support data into something you can just ask about.

| Tool | What it answers |
|---|---|
| `ticket_summary` | Tickets, % auto-drafted, open queue, edit rate, minutes saved, pipeline time |
| `top_issues` | Categories by volume, how many were high/urgent, example subjects |
| `human_queue` | What's waiting for a human, oldest first, and why |
| `kb_gaps` | Where the drafter was unsure because no article covered the issue |
| `eval_results` | Classifier accuracy per prompt version |
| `describe_schema`, `run_sql` | Custom read-only queries |

Asked *"what were the top issues this week, and which KB articles should we write next?"*, Claude Code pulled `top_issues` and `kb_gaps` and came back with a prioritised writing plan: 22 unsure tickets in 30 days, led by connector re-authentication for platforms other than Google Ads (TikTok, LinkedIn's 60-day token expiry, Bing error 105, connectors lost after an SSO change), then diagnosis guides for data discrepancies the KB doesn't cover yet. It also pointed out that connector auth and API errors are the most severe categories: 11 of their 15 tickets were high or urgent.

![Claude Code using the MCP server](docs/mcp-kb-gaps.png)

**Safety:** the server connects as the read-only `grafana_ro` role, inside read-only transactions, with a 5 second statement timeout. It can't change or delete anything. I tested this by hiding a `DELETE` inside a `SELECT` (`WITH x AS (DELETE ...) SELECT ...`), and the database refused it.

## How time saved is calculated

`v_time_saved` compares a manual baseline per category (triage + writing a reply) against the time to review a draft (as-is or edited). **The baseline minutes in `handling_baselines` are my estimates**, based on handling ~100 inbound conversations a week as a retention team lead. They're assumptions to be replaced with real handle-time data from a helpdesk.

## Design decisions

- **Never auto-send.** Every draft needs a human decision. The AI saves time on reading, categorising and writing, not on judgment.
- **Strict schema plus code validation.** The LLM is forced into a JSON schema, and a code node re-checks every field. Bad output gets flagged and routed to a human instead of crashing the flow.
- **Keep every attempt.** Classifications store the raw response, model and prompt version, so a new prompt never overwrites history.
- **Least privilege.** Three database roles: n8n's internal storage, the workflows (read/write), and Grafana plus the MCP server (read-only). Ports are bound to localhost only.
- **Parameterised SQL everywhere.** Ticket text never gets concatenated into queries.
- **Model-agnostic.** The project started on Gemini and moved to Groq after hitting the Gemini free tier's 20 requests/day limit mid-eval. Only the HTTP node and the response parser changed.
- **Everything as code.** Schema, roles, Grafana datasource and dashboard, and the MCP config all live in this repo.

## Run it yourself

Requirements: Docker Desktop, Python 3.10+ (for the MCP server) and a free [Groq API key](https://console.groq.com).

```bash
git clone https://github.com/Gabbrriell/ai-support-triage.git
cd ai-support-triage
cp .env.example .env        # replace every change-me with a random string
docker compose up -d
```

Then:

1. Open n8n at http://localhost:5678 and create an account.
2. Import the three workflows from `Workflows/`.
3. Create two credentials:
   - **Postgres:** host `postgres`, database `support`, user `triage_app`, password `APP_DB_PASSWORD` from `.env`
   - **Header Auth:** name `Authorization`, value `Bearer <your Groq key>`
4. Attach them to the Postgres and HTTP Request nodes, then publish **Ticket triage** and **Review draft**.
5. Load the eval set and send demo traffic (PowerShell):
   ```powershell
   Get-Content db\seed\eval_cases.sql | docker compose exec -T postgres psql -U postgres -d support
   powershell -ExecutionPolicy Bypass -File scripts\seed-demo.ps1
   powershell -ExecutionPolicy Bypass -File scripts\review-demo.ps1
   ```
6. Open Grafana at http://localhost:3000, then **Dashboards > AI Support Triage**.
7. For Claude Code, install the MCP server's dependencies:
   ```bash
   python -m pip install -r mcp-server/requirements.txt
   ```
   Then open Claude Code in the project folder. It picks up `.mcp.json` automatically, so approve the `support-triage` server and check it with `/mcp`. The server reads the database password from `.env`.

Send a single ticket:

```powershell
$body = @{ subject = "Google Ads connector says invalid_grant"; body = "Extractions failing since Monday."; customer_email = "you@example.com"; account_name = "Acme" } | ConvertTo-Json
Invoke-RestMethod -Uri http://localhost:5678/webhook/ticket -Method Post -Body $body -ContentType "application/json"
```

## Repo structure

```
docker-compose.yml          Postgres (pgvector), n8n, Grafana
.mcp.json                   registers the MCP server with Claude Code
db/init/                    roles, schema, starter KB (runs on first start)
db/seed/eval_cases.sql      36 labelled eval tickets
Workflows/                  n8n exports: Ticket triage, Eval runner, Review draft
grafana/provisioning/       datasource + dashboard as code
mcp-server/                 read-only MCP server over the ticket database
scripts/                    demo traffic + simulated agent reviews
docs/                       screenshots
```

## Limitations

- **Demo data is synthetic.** Live metrics come from the eval tickets replayed as traffic and simulated reviews, not real customers.
- **The eval set is small and was used for tuning.** 36 tickets, labelled by one person, with prompts iterated against the same set, so the v3 score is likely optimistic for unseen tickets.
- **Time-saved baselines are estimates**, see above.
- **Webhooks have no authentication.** Fine on localhost; production needs header auth or signature verification.
- **The classify prompt exists in two places** (live flow and eval runner) and has to be kept in sync by hand.
- **KB search is keyword-only**, so it misses synonyms ("spend" vs "cost").
- **No helpdesk integration.** Tickets arrive by webhook, and reviews happen through an API call rather than inside Zendesk or Freshdesk.
