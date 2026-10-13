#!/usr/bin/env bash
# Reference fix: a symptom-level saturation alert on sessions that are inside
# the server and not making progress, with a hold time, a severity and a
# runbook link. Waits until Prometheus reports it firing.
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/08-saturation-alert/common.sh"

prometheus_up || die "Prometheus is not running — ./lab up --observability"

cat > "$RULE_FILE" <<'YAML'
groups:
  - name: mysql-saturation
    rules:
      - alert: MySQLThreadsRunningHigh
        # Threads_running counts sessions executing a statement, including
        # those waiting for a lock. Sustained, it means work is queuing.
        expr: mysql_global_status_threads_running > 10
        for: 30s
        labels:
          severity: page
        annotations:
          summary: "{{ $labels.instance }} has {{ $value }} threads running for 30s"
          description: >-
            Sessions are queuing inside MySQL. Check for lock waits
            (sys.innodb_lock_waits) and long transactions first.
          runbook_url: "https://github.com/MoiToiTech/dbre-academy/blob/main/courses/mysql-production-dba/08-monitoring-observability/README.md#runbook-threads-running"
YAML
echo "Wrote $RULE_FILE"
prom_reload >/dev/null
for _ in $(seq 1 30); do
  if prom_query 'ALERTS{alertname="MySQLThreadsRunningHigh",alertstate="firing",instance="primary"}' | grep -q firing; then
    echo "MySQLThreadsRunningHigh is firing"; exit 0
  fi
  sleep 3
done
die "MySQLThreadsRunningHigh did not fire within 90s"
