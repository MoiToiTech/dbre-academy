#!/usr/bin/env bash
# summary: The BI tool's 'report' account has ALL PRIVILEGES and no TLS; make it a TLS-only read-only role
. "$LAB_DIR/scripts/lib.sh"

bash "$LAB_DIR/scenarios/02-least-privilege/reset.sh" >/dev/null

info "Creating the over-privileged report@'%' account"
sql primary <<'SQL'
CREATE USER 'report'@'%' IDENTIFIED BY 'dbre-lab-report';
GRANT ALL PRIVILEGES ON *.* TO 'report'@'%' WITH GRANT OPTION;
SQL

echo
echo "Scenario ready. report@'%' (password dbre-lab-report) can do anything."
echo "Make it read-only on shop through a role, TLS-only and lockable."
echo "See exercise.md; check with:"
echo "  ./lab scenario check 02-least-privilege"
