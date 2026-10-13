#!/usr/bin/env bash
# End-to-end test of Challenge #001, from scratch:
#   start → the incident is detected → a symptom-only fix is rejected →
#   the reference fix passes → reset → detected again → fixed again → clean.
# Exit code 0 only if every step behaves. Runs in CI on amd64 and arm64.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
export NO_COLOR=1
export CH001_PROJECT="${CH001_PROJECT:-ch001test}"
export CH001_PORT="${CH001_PORT:-13316}"
fails=0
step() { printf '\n=== %s\n' "$*"; }
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
q() { docker compose -f docker-compose.yml exec -T db mysql -uroot -pchallenge --batch --skip-column-names "$@" 2>/dev/null; }

expect_unresolved() {
  local out; out=$(./challenge verify 2>&1 | tr '\r' '\n'); local rc=$?
  printf '%s\n' "$out" | grep -E '✓|✗'
  if [ $rc -ne 0 ] && grep -q 'row locks (healthy' <<<"$out" && grep -q '✗ The condition behind' <<<"$out"; then
    pass "verify reports the incident ($1)"
  else
    fail "verify should report the incident ($1)"
  fi
  local locks; locks=$(grep -oE 'takes [0-9]+ row locks' <<<"$out" | grep -oE '[0-9]+')
  if [ "${locks:-0}" -ge 100000 ]; then pass "claim takes $locks row locks ($1)"; else fail "claim should take >= 100000 row locks, took ${locks:-?} ($1)"; fi
}
expect_resolved() {
  local out; out=$(./challenge verify 2>&1 | tr '\r' '\n'); local rc=$?
  printf '%s\n' "$out" | grep -E '✓|✗|resolved'
  [ $rc -eq 0 ] && pass "verify passes ($1)" || fail "verify should pass ($1)"
}

trap './challenge clean >/dev/null 2>&1' EXIT

step "doctor"
./challenge doctor || fail "doctor"

step "start from scratch"
start=$SECONDS
./challenge start || { fail "start"; exit 1; }
echo "start took $((SECONDS - start)) s"

step "evidence a participant can find"
hll=$(q -e "SHOW ENGINE INNODB STATUS\G" | grep -oE 'History list length [0-9]+' | grep -oE '[0-9]+$')
[ "${hll:-0}" -ge 30000 ] && pass "history list length $hll" || fail "history list length ${hll:-?} (expected >= 30000)"
est=$(q -e "EXPLAIN FORMAT=JSON SELECT id FROM shop.outbox WHERE status = 'pending' ORDER BY id LIMIT 10" | grep -oE '"rows_examined_per_scan": [0-9]+' | grep -oE '[0-9]+$')
pending=$(q -e "SELECT COUNT(*) FROM shop.outbox WHERE status = 'pending'")
[ "${est:-0}" -ge 10000 ] && pass "EXPLAIN estimates $est rows for $pending pending" || fail "EXPLAIN estimate ${est:-?} (expected >= 10000)"
idle=$(q -e "SELECT COUNT(*) FROM information_schema.innodb_trx t JOIN information_schema.processlist p ON p.id = t.trx_mysql_thread_id WHERE p.command = 'Sleep' AND t.trx_rows_modified = 0")
[ "$idle" = 1 ] && pass "one idle transaction is open" || fail "expected one idle transaction, found ${idle:-?}"
./challenge status

step "incident detected"
expect_unresolved "initial"

step "symptom-only fix (OPTIMIZE TABLE) is not accepted"
q -e "OPTIMIZE TABLE shop.outbox" >/dev/null
out=$(./challenge verify 2>&1 | tr '\r' '\n')
grep -q '✗ The condition behind' <<<"$out" && pass "OPTIMIZE alone does not resolve it" || fail "OPTIMIZE alone must not resolve it"

step "reference fix"
instructor/solve.sh || fail "solve.sh"
expect_resolved "after fix"
out=$(./challenge verify 2>&1 | tr '\r' '\n')
grep -q 'reference fix (instructor/solve.sh) was used, so no share link' <<<"$out" && ! grep -q 'linkedin.com' <<<"$out" \
  && pass "no share link after the reference fix" || fail "a reference fix must not get a share link"

step "solved by hand: share link offered"
# The learner's way: find the idle session and end it, without solve.sh.
q -e "SELECT CONCAT('KILL ', t.trx_mysql_thread_id) FROM information_schema.innodb_trx t JOIN information_schema.processlist p ON p.id = t.trx_mysql_thread_id WHERE p.command = 'Sleep' AND t.trx_rows_modified = 0" > /dev/null
q -e "DELETE FROM challenge.run WHERE k = 'reference_fix'"
out=$(./challenge verify 2>&1 | tr '\r' '\n')
grep -q 'linkedin.com/sharing/share-offsite/?url=https%3A%2F%2Fmoitoi.tech%2Facademy%2Fsolved%2Fchallenge-001' <<<"$out" \
  && pass "share link offered when solved by hand" || fail "share link missing after a hand fix"
./challenge status

step "reset returns to the incident"
start=$SECONDS
./challenge reset || fail "reset"
echo "reset took $((SECONDS - start)) s"
expect_unresolved "after reset"

step "fix again (repeatable)"
instructor/solve.sh || fail "solve.sh after reset"
expect_resolved "after second fix"

step "clean"
./challenge clean && pass "clean" || fail "clean"
[ -z "$(docker compose -f docker-compose.yml ps -aq)" ] && pass "no containers left" || fail "containers left behind"
[ -z "$(docker volume ls -q --filter "name=${CH001_PROJECT}_")" ] && pass "no volumes left" || fail "volumes left behind"

printf '\n%s\n' "$([ $fails -eq 0 ] && echo 'ALL PASSED' || echo "$fails FAILED")"
exit "$fails"
