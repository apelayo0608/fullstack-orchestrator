#!/usr/bin/env bash
# Tests for parallel delegation (delegate-parallel.sh). No model CLI needed:
# ORCH_DEV_CMD runs tests/fake-dev.sh for every worker.
#
# Usage: tests/parallel.sh
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
  mkdir -p .orchestrator/tasks .orchestrator/contracts
  cat > .orchestrator/plan.md <<'EOF'
# Plan: parallel test
Test commands: true

## Tasks
| id  | title      | depends | risk | status | rounds | verdict |
|-----|------------|---------|------|--------|--------|---------|
| T01 | two slices | -       | low  | todo   | 0      |         |
EOF
  printf '# T01 web\n\nBuild the client slice.\n' > .orchestrator/tasks/T01-web.md
  printf '# T01 api\n\nBuild the server slice.\n' > .orchestrator/tasks/T01-api.md
  cat > .orchestrator/contracts/T01.md <<'EOF'
GET /api/notes -> { items: [{ id, title }] }
EOF
}

manifest() {
  cat > .orchestrator/tasks/T01.workers.md <<EOF
## Worker: T01-web
brief: .orchestrator/tasks/T01-web.md
scope: client/**
env: ORCH_FAKE_FILES=client/src/app.ts client/src/ui.ts

## Worker: T01-api
brief: .orchestrator/tasks/T01-api.md
scope: server/**
env: ORCH_FAKE_FILES=server/src/notes.ts

## Shared
contract: .orchestrator/contracts/T01.md
EOF
}

export ORCH_DEV_CMD="bash $ROOT/tests/fake-dev.sh"

# 1. happy path: two workers, disjoint scopes, clean merge, checks pass
d="$TMP/happy"; make_repo "$d"; manifest
set +e
"$ROOT/scripts/delegate-parallel.sh" --task T01 --workers .orchestrator/tasks/T01.workers.md \
  --repo "$d" --max-parallel 2 --stagger 0 > "$TMP/happy.out" 2>&1
rc=$?
set -e
(( rc == 0 )) || fail "expected exit 0, got $rc: $(tail -n 25 "$TMP/happy.out")"
grep -q 'CHECKS: PASS' "$TMP/happy.out" || fail "checks did not pass: $(tail -n 20 "$TMP/happy.out")"
[[ -f "$d/.orchestrator/tasks/T01.parallel-report.md" ]] || fail "no parallel report"
int_wt="$(cat "$d/.orchestrator/worktrees/T01-int.path")"
[[ -f "$int_wt/client/src/app.ts" ]] || fail "web slice missing from the integration tree"
[[ -f "$int_wt/server/src/notes.ts" ]] || fail "api slice missing from the integration tree"
grep -q 'merged' "$d/.orchestrator/tasks/T01.parallel-report.md" || fail "report does not show a merge"
ok "two workers ran, merged into one tree, checks pass"

# the shared contract is inlined into each worker's generated brief
grep -q 'GET /api/notes' "$d/.orchestrator/logs/T01-web-brief.md" || fail "contract not inlined in the web brief"
grep -q 'server/\*\*' "$d/.orchestrator/logs/T01-api-brief.md" || fail "scope not stated in the api brief"
grep -q 'client/\*\*' "$d/.orchestrator/logs/T01-web-brief.md" || fail "scope not stated in the web brief"
ok "each worker brief carries the contract and its scope"

# 2. overlapping scopes are refused before anything runs
d="$TMP/overlap"; make_repo "$d"
cat > .orchestrator/tasks/T01.workers.md <<'EOF'
## Worker: T01-web
brief: .orchestrator/tasks/T01-web.md
scope: client/**
## Worker: T01-api
brief: .orchestrator/tasks/T01-api.md
scope: client/src/**
EOF
set +e
"$ROOT/scripts/delegate-parallel.sh" --task T01 --workers .orchestrator/tasks/T01.workers.md \
  --repo "$d" --stagger 0 > "$TMP/overlap.out" 2>&1
rc=$?
set -e
(( rc == 2 )) || fail "expected exit 2 for overlapping scopes, got $rc: $(cat "$TMP/overlap.out")"
grep -qi 'overlap' "$TMP/overlap.out" || fail "no overlap message"
[[ ! -f "$d/.orchestrator/worktrees/T01-web.path" ]] || fail "worktree created despite the validation error"
ok "overlapping scopes are refused up front"

# 3. a worker that leaves its scope is not integrated
d="$TMP/scope"; make_repo "$d"; manifest
# the web worker writes into the api slice
sed -i.bak 's#env: ORCH_FAKE_FILES=client/src/app.ts client/src/ui.ts#env: ORCH_FAKE_FILES=client/src/app.ts server/src/hijack.ts#' \
  .orchestrator/tasks/T01.workers.md && rm -f .orchestrator/tasks/T01.workers.md.bak
set +e
"$ROOT/scripts/delegate-parallel.sh" --task T01 --workers .orchestrator/tasks/T01.workers.md \
  --repo "$d" --max-parallel 2 --stagger 0 > "$TMP/scope.out" 2>&1
rc=$?
set -e
(( rc == 6 )) || fail "expected exit 6 for a scope violation, got $rc: $(tail -n 20 "$TMP/scope.out")"
grep -q 'OUT OF SCOPE' "$d/.orchestrator/tasks/T01.parallel-report.md" || fail "report does not flag the violation"
int_wt="$(cat "$d/.orchestrator/worktrees/T01-int.path")"
[[ ! -f "$int_wt/server/src/hijack.ts" ]] || fail "out-of-scope file was integrated"
ok "a worker that edits outside its scope is blocked from integration"

# 4. conflicting edits are reported, not silently merged
d="$TMP/conflict"; make_repo "$d"
cat > .orchestrator/tasks/T01.workers.md <<'EOF'
## Worker: T01-web
brief: .orchestrator/tasks/T01-web.md
scope: shared/**
env: ORCH_FAKE_FILES=shared/thing.ts
env: ORCH_FAKE_TAG=web
## Worker: T01-api
brief: .orchestrator/tasks/T01-api.md
scope: shared/**
env: ORCH_FAKE_FILES=shared/thing.ts
env: ORCH_FAKE_TAG=api
EOF
set +e
"$ROOT/scripts/delegate-parallel.sh" --task T01 --workers .orchestrator/tasks/T01.workers.md \
  --repo "$d" --max-parallel 2 --stagger 0 --allow-overlap > "$TMP/conflict.out" 2>&1
rc=$?
set -e
(( rc == 5 )) || fail "expected exit 5 for a merge conflict, got $rc: $(tail -n 20 "$TMP/conflict.out")"
[[ -f "$d/.orchestrator/tasks/T01.merge-conflicts.md" ]] || fail "no conflict report"
ok "conflicting edits stop integration with a report"

echo
echo "all parallel tests passed"
