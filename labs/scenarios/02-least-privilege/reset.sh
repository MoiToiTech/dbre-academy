#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"

# Only the scenario's own account and role; the built-in accounts (root,
# repl, app, exporter) are never touched.
sql primary <<'SQL'
DROP USER IF EXISTS 'report'@'%';
DROP ROLE IF EXISTS 'reporting_ro';
SQL
info "02-least-privilege reset"
