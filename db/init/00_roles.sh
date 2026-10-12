#!/bin/bash
# Runs once, on first start with an empty pg_data volume.
# Three roles, least privilege:
#   n8n         owns the n8n database (n8n's internal storage)
#   triage_app  read/write on support tables (what your n8n workflows connect as)
#   grafana_ro  read-only on support tables
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v n8n_pw="$N8N_DB_PASSWORD" \
  -v app_pw="$APP_DB_PASSWORD" \
  -v graf_pw="$GRAFANA_DB_PASSWORD" <<'EOSQL'
CREATE ROLE n8n        LOGIN PASSWORD :'n8n_pw';
CREATE ROLE triage_app LOGIN PASSWORD :'app_pw';
CREATE ROLE grafana_ro LOGIN PASSWORD :'graf_pw';
CREATE DATABASE n8n OWNER n8n;
EOSQL
