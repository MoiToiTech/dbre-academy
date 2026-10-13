#!/usr/bin/env bash
# The full lab verification, exactly as CI runs it:
#
#   1. destroy any previous lab of this project and start from scratch
#   2. ./lab up --observability
#   3. every scenario: setup / check-fails / solve / check-passes / reset
#   4. ./lab reset, then every executable block in every lesson, in order
#   5. ./lab destroy and confirm no containers or volumes remain
#
# Takes roughly 15–25 minutes. Run it from anywhere:  labs/tests/full-run.sh
# Set KEEP_LAB=1 to skip the final destroy.

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export LAB_DIR
# shellcheck source=../scripts/lib.sh
. "$LAB_DIR/scripts/lib.sh"
set +e

cd "$LAB_DIR" || exit 1
status=0
section() { printf '\n######## %s\n' "$*"; }

section "doctor"
./lab doctor || true

section "clean start"
./lab destroy >/dev/null 2>&1
start=$SECONDS
./lab up --observability || exit 1
echo "lab up took $((SECONDS - start))s"

section "scenarios"
tests/scenario-test.sh --all || status=1

section "lessons (doctest)"
./lab reset --observability >/dev/null || exit 1
tests/doctest.py || status=1

if [ -z "${KEEP_LAB:-}" ]; then
  section "teardown"
  ./lab destroy
  left="$(docker ps -a --filter "label=com.docker.compose.project=$DBRE_PROJECT" -q | wc -l | tr -d ' ')"
  vols="$(docker volume ls --filter "label=com.docker.compose.project=$DBRE_PROJECT" -q | wc -l | tr -d ' ')"
  if [ "$left" = "0" ] && [ "$vols" = "0" ]; then
    echo "teardown clean: no containers or volumes left for project $DBRE_PROJECT"
  else
    echo "teardown left $left container(s) and $vols volume(s)"; status=1
  fi
fi

section "result"
[ "$status" -eq 0 ] && echo "FULL RUN PASSED" || echo "FULL RUN FAILED"
exit "$status"
