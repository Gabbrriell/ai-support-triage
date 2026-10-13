"""
MCP server for the support triage database.

Lets Claude Code (or any MCP client) answer questions like
"what were the top issues this week?" or "which KB articles should we write next?"

Safety: connects as the read-only grafana_ro role, inside read-only transactions,
with a 5 second statement timeout. It cannot change or delete anything.
The password is read from the project's .env file (GRAFANA_DB_PASSWORD).
"""
import json
import os
import pathlib

import psycopg
from psycopg.rows import dict_row
from mcp.server.fastmcp import FastMCP

ROOT = pathlib.Path(__file__).resolve().parent.parent


def _load_env() -> dict:
    env = {}
    path = ROOT / ".env"
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                env[key.strip()] = value.strip().strip('"').strip("'")
    return env


ENV = {**_load_env(), **os.environ}
CONN = dict(
    host=ENV.get("SUPPORT_DB_HOST", "localhost"),
    port=int(ENV.get("SUPPORT_DB_PORT", "5432")),
    dbname=ENV.get("SUPPORT_DB_NAME", "support"),
    user=ENV.get("SUPPORT_DB_USER", "grafana_ro"),
    password=ENV.get("GRAFANA_DB_PASSWORD", ""),
    options="-c default_transaction_read_only=on -c statement_timeout=5000",
    connect_timeout=5,
)
MAX_ROWS = 200

mcp = FastMCP("support-triage")


def _query(sql: str, params=None) -> str:
    """Run a read-only query and return rows as JSON text."""
    with psycopg.connect(**CONN, row_factory=dict_row) as conn:
        cur = conn.execute(sql, params)
        rows = cur.fetchmany(MAX_ROWS) if cur.description else []
    return json.dumps(rows, default=str, indent=1)


@mcp.tool()
def ticket_summary(days: int = 7) -> str:
    """Headline support metrics for the last N days: ticket count, % auto-drafted,
    open human queue, draft edit rate, estimated minutes saved, median pipeline time."""
    return _query(
        """
        SELECT
          (SELECT count(*) FROM tickets WHERE received_at >= now() - %(d)s * interval '1 day') AS tickets,
          (SELECT round(100.0 * avg((d.routed_to = 'draft_review')::int), 1)
             FROM drafts d JOIN tickets t ON t.id = d.ticket_id
            WHERE t.received_at >= now() - %(d)s * interval '1 day') AS auto_drafted_pct,
          (SELECT count(*) FROM drafts WHERE routed_to = 'human_queue' AND review_status = 'pending') AS human_queue_open,
          (SELECT round(100.0 * avg(d.was_edited::int), 1)
             FROM drafts d JOIN tickets t ON t.id = d.ticket_id
            WHERE d.review_status = 'approved' AND t.received_at >= now() - %(d)s * interval '1 day') AS edit_rate_pct,
          (SELECT coalesce(sum(minutes_saved), 0) FROM v_time_saved
            WHERE received_at >= now() - %(d)s * interval '1 day') AS minutes_saved,
          (SELECT round((percentile_cont(0.5) WITHIN GROUP (ORDER BY total) / 1000.0)::numeric, 1)
             FROM (SELECT ticket_id, sum(duration_ms) AS total FROM pipeline_steps
                    WHERE started_at >= now() - %(d)s * interval '1 day' GROUP BY ticket_id) x) AS median_pipeline_seconds
        """,
        {"d": days},
    )


@mcp.tool()
def top_issues(days: int = 7) -> str:
    """Ticket categories ranked by volume for the last N days, with how many were
    high/urgent and a few example subjects per category."""
    return _query(
        """
        SELECT coalesce(c.category, 'invalid') AS category,
               count(*) AS tickets,
               count(*) FILTER (WHERE c.priority IN ('urgent', 'high')) AS high_or_urgent,
               (array_agg(left(t.subject, 80) ORDER BY t.received_at DESC))[1:3] AS example_subjects
        FROM tickets t
        JOIN LATERAL (SELECT category, priority FROM classifications
                       WHERE ticket_id = t.id ORDER BY created_at DESC LIMIT 1) c ON true
        WHERE t.received_at >= now() - %(d)s * interval '1 day'
        GROUP BY 1
        ORDER BY tickets DESC
        """,
        {"d": days},
    )


@mcp.tool()
def human_queue(limit: int = 20) -> str:
    """Open tickets waiting for a human, oldest first, with the reason they were routed there."""
    return _query(
        """
        SELECT t.id AS ticket_id, t.account_name, left(t.subject, 80) AS subject,
               c.category, c.priority, d.routing_reason,
               round(extract(epoch FROM now() - t.received_at) / 60) AS waiting_minutes
        FROM drafts d
        JOIN tickets t ON t.id = d.ticket_id
        LEFT JOIN classifications c ON c.id = d.classification_id
        WHERE d.routed_to = 'human_queue' AND d.review_status = 'pending'
        ORDER BY t.received_at
        LIMIT %(n)s
        """,
        {"n": min(limit, MAX_ROWS)},
    )


@mcp.tool()
def kb_gaps(days: int = 30) -> str:
    """Where the knowledge base is missing articles: tickets where the drafter said it
    was unsure (no KB article covered the issue), grouped by category with examples.
    Use this to decide which help articles to write next."""
    return _query(
        """
        SELECT c.category,
               count(*) AS unsure_tickets,
               (array_agg(left(t.subject, 80) ORDER BY t.received_at DESC))[1:5] AS examples
        FROM drafts d
        JOIN tickets t ON t.id = d.ticket_id
        LEFT JOIN classifications c ON c.id = d.classification_id
        WHERE d.model_unsure AND t.received_at >= now() - %(d)s * interval '1 day'
        GROUP BY c.category
        ORDER BY unsure_tickets DESC
        """,
        {"d": days},
    )


@mcp.tool()
def eval_results() -> str:
    """Accuracy of each classifier prompt version on the labelled eval set."""
    return _query("SELECT * FROM v_eval_accuracy ORDER BY run_id")


@mcp.tool()
def describe_schema() -> str:
    """Tables, views and columns in the support database. Call this before writing run_sql queries."""
    return _query(
        """
        SELECT table_name, string_agg(column_name || ' ' || data_type, ', ' ORDER BY ordinal_position) AS columns
        FROM information_schema.columns
        WHERE table_schema = 'public'
        GROUP BY table_name
        ORDER BY table_name
        """
    )


@mcp.tool()
def run_sql(query: str) -> str:
    """Run a custom read-only SELECT against the support database (max 200 rows, 5s timeout).
    Writes are impossible: the connection is a read-only role in a read-only transaction."""
    q = query.strip().rstrip(";")
    if not q.lower().startswith(("select", "with")):
        return "Only SELECT or WITH queries are allowed."
    try:
        return _query(q)
    except psycopg.Error as e:
        return f"Query failed: {e}"


if __name__ == "__main__":
    mcp.run()
