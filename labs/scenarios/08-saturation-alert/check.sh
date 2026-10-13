#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/08-saturation-alert/common.sh"

echo "Checking 08-saturation-alert"

if ! prometheus_up; then
  fail "Prometheus is not running"
  hint "this scenario needs the observability profile: ./lab up --observability"
  check_result; exit 1
fi
if pileup_running && blocker_present; then
  pass "the session pile-up is still in progress (alerts need a live condition)"
else
  fail "the session pile-up is not running, so no saturation alert can fire"
  hint "restart it with: ./lab scenario setup 08-saturation-alert (your rule file is kept)"
fi

rel="observability/prometheus/rules.d/saturation.yml"
if [ ! -f "$RULE_FILE" ]; then
  fail "no rule file at $rel"
  hint "create it with one alerting rule — the exercise shows the file format"
  check_result; exit 1
fi
pass "rule file $rel exists"

# 1. Valid Prometheus rules, according to Prometheus' own tool.
if out="$(dc exec -T prometheus promtool check rules "$RULE_FILE_IN_PROM" 2>&1)"; then
  pass "promtool check rules: $(printf '%s' "$out" | grep -o 'SUCCESS: [0-9]* rules found' || echo SUCCESS)"
else
  fail "promtool check rules rejected the file:"
  printf '%s\n' "$out" | sed 's/^/         /'
  check_result; exit 1
fi

# 2. Alert design: every alert has a hold time, a severity and a runbook.
names="$(sed -n 's/^[[:space:]-]*alert:[[:space:]]*\([A-Za-z0-9_:]*\).*/\1/p' "$RULE_FILE")"
n_alerts="$(printf '%s\n' "$names" | grep -c . || true)"
if [ "$n_alerts" -lt 1 ]; then
  fail "the file has no alerting rule (a rule with 'alert:', not only 'record:')"
  check_result; exit 1
fi
for key in for severity summary runbook_url; do
  n="$(grep -cE "^[[:space:]]*${key}:" "$RULE_FILE" || true)"
  if [ "$n" -ge "$n_alerts" ]; then
    pass "every alert has '$key'"
  else
    fail "$n of $n_alerts alert(s) have '$key'"
    case "$key" in
      for) hint "without 'for:' one noisy scrape pages someone; use 15s–60s in the lab" ;;
      severity) hint "a 'severity' label lets Alertmanager route page vs ticket" ;;
      *) hint "the person paged at 03:00 needs '$key' in annotations" ;;
    esac
  fi
done
if grep -qE 'mysql_global_status_(threads_running|innodb_row_lock_current_waits)' "$RULE_FILE"; then
  pass "the expression measures saturation (threads running or current row-lock waits)"
else
  fail "no expression uses mysql_global_status_threads_running or ..._innodb_row_lock_current_waits"
  hint "which panel on the dashboard moved when the pile-up started?"
fi

# 3. Loaded and firing for the primary, silent for the replica.
if ! out="$(prom_reload)"; then
  fail "Prometheus refused to reload: $out"
  check_result; exit 1
fi
re="$(printf '%s\n' "$names" | paste -sd'|' -)"
state=""
for i in $(seq 1 40); do
  state="$(prom_query "ALERTS{alertname=~\"$re\",instance=\"primary\"}" \
           | sed -n 's/.*alertstate="\([a-z]*\)".*/\1/p' | sort -u | head -1)"
  [ "$state" = "firing" ] && break
  [ "$i" = 1 ] && echo "  ... waiting for the alert to fire (up to 2 minutes; state: ${state:-inactive})"
  sleep 3
done
if [ "$state" = "firing" ]; then
  pass "your alert is firing for instance=primary"
else
  fail "your alert is not firing for the primary after 2 minutes (state: ${state:-inactive})"
  hint "test the expression in the Prometheus UI first; keep 'for:' at 60s or less here"
fi
replica="$(prom_query "ALERTS{alertname=~\"$re\",instance=\"replica\"}" | grep -c alertstate || true)"
expect "your alert stays quiet for the idle replica (series)" "$replica" "0"

check_result
