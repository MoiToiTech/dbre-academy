#!/usr/bin/env bash
# Fast checks that need no running lab. Run from anywhere.
#   - every published port binds to 127.0.0.1
#   - every scenario has setup/check/reset/solve and a summary line
#   - every module has a lesson, an exercise and an assessment
#   - no placeholder text in course material
#   - compose file is valid with and without the observability profile
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO" || exit 1
fails=0
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
ok()  { printf 'ok   %s\n' "$*"; }

# Ports: "127.0.0.1:host:container" only.
if grep -nE '^\s*- "?[0-9$]' labs/docker-compose.yml | grep -v '127.0.0.1:' | grep -E ':[0-9]+"?$'; then
  bad "a port in labs/docker-compose.yml is not bound to 127.0.0.1"
else
  ok "all published ports bind to 127.0.0.1"
fi

for d in labs/scenarios/*/; do
  name="$(basename "$d")"
  for f in setup check reset solve; do
    [ -f "$d$f.sh" ] || bad "scenario $name: missing $f.sh"
  done
  grep -q '^# summary: ' "${d}setup.sh" 2>/dev/null || bad "scenario $name: setup.sh has no '# summary:' line"
done
ok "scenario layout checked ($(ls -d labs/scenarios/*/ 2>/dev/null | wc -l | tr -d ' ') scenarios)"

for d in courses/*/[0-9][0-9]-*/; do
  [ -f "${d}README.md" ] || bad "$d: missing README.md"
  [ -f "${d}exercise.md" ] || bad "$d: missing exercise.md"
  if [ ! -f "${d}quiz.md" ] && [ ! -f "${d}rubric.md" ]; then bad "$d: missing quiz.md or rubric.md"; fi
done
ok "module layout checked"

if grep -rniE '\b(TODO|TBD|FIXME|lorem ipsum|coming soon)\b' courses/ docs/curriculum.md README.md; then
  bad "placeholder text found (above)"
else
  ok "no placeholder text in course material"
fi

# Every scenario referenced in a lesson exists.
missing=""
for s in $(grep -rhoE 'scenario (setup|check|reset) [0-9]{2}-[a-z0-9-]+|lab check [0-9]{2}-[a-z0-9-]+' courses/ \
           | awk '{print $NF}' | sort -u); do
  [ -d "labs/scenarios/$s" ] || missing="$missing $s"
done
[ -z "$missing" ] && ok "every scenario named in a lesson exists" || bad "lessons name missing scenarios:$missing"

if command -v docker >/dev/null 2>&1; then
  docker compose -f labs/docker-compose.yml config -q && \
  docker compose -f labs/docker-compose.yml --profile observability config -q && \
    ok "docker compose config valid (default and observability)" || bad "docker compose config invalid"
fi

[ "$fails" -eq 0 ] && echo "static checks passed" || echo "$fails static check(s) failed"
exit "$fails"
