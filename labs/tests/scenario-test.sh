#!/usr/bin/env bash
# Integration test for one or more lab scenarios.
#
#   tests/scenario-test.sh <scenario> [<scenario> ...]
#   tests/scenario-test.sh --all
#
# For each scenario, against a running lab:
#   1. record the baseline (dataset fingerprint on both servers)
#   2. setup                 — must succeed
#   3. check                 — must FAIL: the fault is really there
#   4. solve (reference fix) — must succeed
#   5. check                 — must PASS: the check recognises the fix
#   6. reset                 — must succeed
#   7. baseline restored     — same fingerprint, replication healthy
#   8. setup + reset again   — reset also works on an unsolved scenario
#
# Requires the lab to be up (./lab up). Exit code is the number of failures.

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export LAB_DIR
# shellcheck source=../scripts/lib.sh
. "$LAB_DIR/scripts/lib.sh"
set +e

FAILURES=0
step_fail() { printf '%sFAIL%s [%s] %s\n' "$C_RED" "$C_OFF" "$1" "$2"; FAILURES=$((FAILURES + 1)); }
step_ok()   { printf '%sok%s   [%s] %s\n' "$C_GREEN" "$C_OFF" "$1" "$2"; }

baseline() {
  local out
  out="$(sql primary -N -B < "$LAB_DIR/datasets/shop/fingerprint.sql" 2>&1)"
  printf 'primary:%s\n' "$out"
  out="$(sql replica -N -B < "$LAB_DIR/datasets/shop/fingerprint.sql" 2>&1)"
  printf 'replica:%s\n' "$out"
}

replication_healthy() {
  [ "$(sqlv replica "SELECT CONCAT(c.SERVICE_STATE, '/', a.SERVICE_STATE)
                     FROM performance_schema.replication_connection_status c
                     JOIN performance_schema.replication_applier_status a USING (CHANNEL_NAME)")" = "ON/ON" ]
}

run_step() { # run_step <scenario> <script> <logfile>
  bash "$LAB_DIR/scenarios/$1/$2.sh" >"$3" 2>&1
}

test_scenario() {
  local s="$1" dir="$LAB_DIR/scenarios/$1" log before after start=$SECONDS
  log="$(mktemp)"
  echo "== $s"
  [ -d "$dir" ] || { step_fail "$s" "no such scenario"; return; }
  for f in setup check reset solve; do
    [ -f "$dir/$f.sh" ] || { step_fail "$s" "missing $f.sh"; return; }
  done

  before="$(baseline)"
  if run_step "$s" setup "$log"; then step_ok "$s" "setup"; else step_fail "$s" "setup exited non-zero"; cat "$log"; fi
  if run_step "$s" check "$log"; then step_fail "$s" "check passed before the fix — the fault is not detected"; cat "$log"
  else step_ok "$s" "check fails while the fault is present"; fi
  if run_step "$s" solve "$log"; then step_ok "$s" "reference fix applied"; else step_fail "$s" "solve exited non-zero"; cat "$log"; fi
  if run_step "$s" check "$log"; then step_ok "$s" "check passes after the fix"; else step_fail "$s" "check fails after the reference fix"; cat "$log"; fi
  if run_step "$s" reset "$log"; then step_ok "$s" "reset"; else step_fail "$s" "reset exited non-zero"; cat "$log"; fi

  wait_replica_caught_up 120 || step_fail "$s" "replica did not catch up after reset"
  replication_healthy && step_ok "$s" "replication healthy" || step_fail "$s" "replication not running after reset"
  after="$(baseline)"
  if [ "$before" = "$after" ]; then step_ok "$s" "dataset fingerprint restored"
  else step_fail "$s" "dataset differs from baseline after reset"; diff <(echo "$before") <(echo "$after"); fi

  if run_step "$s" setup "$log" && run_step "$s" reset "$log"; then step_ok "$s" "setup+reset without solving"
  else step_fail "$s" "setup+reset without solving failed"; cat "$log"; fi
  wait_replica_caught_up 120 >/dev/null || true
  after="$(baseline)"
  [ "$before" = "$after" ] && step_ok "$s" "baseline restored again" || step_fail "$s" "baseline not restored after unsolved reset"
  echo "   ($((SECONDS - start))s)"
  rm -f "$log"
}

if [ "${1:-}" = "--all" ]; then
  # shellcheck disable=SC2046  # scenario names never contain spaces
  set -- $(cd "$LAB_DIR/scenarios" && for d in */; do [ -f "$d/setup.sh" ] && printf '%s ' "${d%/}"; done)
fi
[ $# -gt 0 ] || { echo "usage: $0 <scenario>... | --all"; exit 2; }
is_running primary || die "lab not running — ./lab up first"

for s in "$@"; do test_scenario "$s"; done
echo
if [ "$FAILURES" -eq 0 ]; then echo "${C_GREEN}All scenario tests passed.${C_OFF}"; else echo "${C_RED}$FAILURES failure(s).${C_OFF}"; fi
exit "$FAILURES"
