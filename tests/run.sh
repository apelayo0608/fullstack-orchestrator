#!/usr/bin/env bash
# Tests for the live change feed. No model CLI is needed: ORCH_DEV_CMD runs
# tests/fake-dev.sh in place of the developer.
#
# Usage: tests/run.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

make_repo() {
  local d=$1
  mkdir -p "$d"; cd "$d"
  git init -q
  git config user.email test@example.com
  git config user.name test
  printf 'base\n' > README.md
  git add . && git commit -qm init
  mkdir -p .orchestrator/tasks
  cat > .orchestrator/plan.md <<'EOF'
# Plan: test
Test commands: true

## Tasks
| id  | title | depends | risk | status | rounds | verdict |
|-----|-------|---------|------|--------|--------|---------|
| T01 | stub  | -       | low  | todo   | 0      |         |
EOF
  printf '# T01\n\nStub brief.\n' > .orchestrator/tasks/T01.md
}

# 1. summary + json on a dirty tree, with no baseline (falls back to HEAD)
d="$TMP/a"; make_repo "$d"
mkdir -p src; printf 'x\n' > src/new.ts
out="$("$ROOT/scripts/watch-changes.sh" --task T01 --summary)"
grep -q 'CHANGES: 1 file(s), +1 -0' <<< "$out" || fail "summary output: $out"
ok "summary reports one added file"

json="$("$ROOT/scripts/watch-changes.sh" --task T01 --once --json)"
grep -q '"file":"src/new.ts"' <<< "$json" || fail "json output: $json"
grep -q '"status":"A"' <<< "$json" || fail "json status not A: $json"
ok "json events include the new file"

# 2. end-to-end: delegate-dev + stub developer + feed on
ORCH_LIVE_CHANGES=1 ORCH_DEV_CMD="bash $ROOT/tests/fake-dev.sh" \
  "$ROOT/scripts/delegate-dev.sh" --task T01 --repo "$d" --no-check > "$TMP/dev.out" 2>&1 \
  || fail "delegate-dev failed: $(tail -n 25 "$TMP/dev.out")"
grep -q 'CHANGES: 3 file(s)' "$TMP/dev.out" || fail "expected 3 changed files: $(grep 'CHANGES' "$TMP/dev.out" || echo 'no CHANGES line')"
grep -q '## DEV REPORT' "$TMP/dev.out" || fail "no DEV REPORT in output"
grep -q 'CHECKS: skipped' "$TMP/dev.out" || fail "no CHECKS line"
[[ -s "$d/.orchestrator/logs/T01-changes.jsonl" ]] || fail "no change event log written"
ok "delegate-dev ran the stub and reported 3 changed files"

# 3. the feed sees a file created while it is running
cd "$d"
( sleep 0.6; printf 'later\n' > later.txt ) &
bg=$!
watch_out="$(timeout 5 "$ROOT/scripts/watch-changes.sh" --task T01 --interval 1 2>/dev/null || true)"
wait "$bg" 2>/dev/null || true
grep -q 'later.txt' <<< "$watch_out" || fail "live feed missed later.txt; got: $watch_out"
ok "live feed reported a file created mid-run"

# 4. a deleted tracked file is reported as D (needs a committed file and no baseline)
d2="$TMP/b"; make_repo "$d2"
printf 'bye\n' > gone.txt
git add gone.txt && git commit -qm add-gone
rm gone.txt
out="$("$ROOT/scripts/watch-changes.sh" --task T01 --summary)"
grep -q ' D gone.txt' <<< "$out" || fail "deleted file not marked D: $out"
ok "deleted files are marked D"

echo
echo "all tests passed"
