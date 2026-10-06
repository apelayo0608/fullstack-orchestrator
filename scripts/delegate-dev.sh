#!/usr/bin/env bash
# Hand one task brief to the full-stack developer (DeepSeek through OpenCode).
#
# Usage: delegate-dev.sh --task T01 [--brief PATH] [--repo DIR] [--new-session] [--watch] [--dry-run]
#
#   --task         Task id, e.g. T01. The brief defaults to .orchestrator/tasks/<task>.md.
#   --brief        Brief to send instead, e.g. .orchestrator/tasks/T01-fix1.md for a fix round.
#   --repo         Any path inside the target git repo (default: current directory).
#   --new-session  Start a fresh OpenCode session instead of continuing this task's session.
#   --watch        Open a Terminal.app window (macOS) with the OpenCode TUI on this task's
#                  session, so you can watch the developer live. Typing there steers it.
#   --dry-run      Print the command and prompt location without running anything.
#
# The first run of a task records a baseline snapshot of the working tree so
# delegate-review.sh can diff the whole task. Full output: .orchestrator/logs/.
# Runs can take many minutes: run this in the background or with a long timeout.
# The "Watch live:" line on stderr is the command that opens the same live view anywhere.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

task="" brief="" repo="." new_session=0 watch=0 dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task=${2:?}; shift 2 ;;
    --brief) brief=${2:?}; shift 2 ;;
    --repo) repo=${2:?}; shift 2 ;;
    --new-session) new_session=1; shift ;;
    --watch) watch=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n $task ]] || die "--task is required"
check_task_id "$task"
repo="$(repo_root "$repo")"
orch="$repo/.orchestrator"
brief="${brief:-$orch/tasks/$task.md}"
[[ -f $brief ]] || die "brief not found: $brief"

session_file="$orch/sessions/$task.id"
if (( !new_session )) && [[ -f $session_file ]]; then
  session="$(<"$session_file")"
else
  session="$(session_id "$repo" "$task")"
  (( new_session )) && session="${session}_$(date +%s)"
fi

ts="$(date +%Y%m%d-%H%M%S)"
prompt_file="$orch/logs/$task-dev-$ts.prompt.md"
log="$orch/logs/$task-dev-$ts.log"
cmd=(opencode run -m "$ORCH_DEV_MODEL" --auto -s "$session" --title "orch $task")
# The TUI attaches to the same background service as `opencode run`, so it shows the run live.
watch_cmd="cd $(printf %q "$repo") && opencode -s $(printf %q "$session")"

if (( dry_run )); then
  echo "repo:    $repo"
  echo "brief:   $brief"
  echo "session: $session"
  echo "command: (cd $repo && ${cmd[*]} \"<contract + brief>\")"
  echo "log:     $log"
  echo "watch:   $watch_cmd"
  exit 0
fi

require_cmd opencode
ensure_workspace "$repo"
[[ -f "$orch/baselines/$task.tree" ]] || worktree_tree "$repo" > "$orch/baselines/$task.tree"
echo "$session" > "$session_file"

cat > "$prompt_file" <<EOF
You are the FULL-STACK DEVELOPER on an orchestrated team. An orchestrator plans
and assigns work; you implement it; an independent reviewer audits your diff read-only.

RULES
- Implement exactly the brief below. Do not widen scope. If the brief is ambiguous
  or blocked, stop and explain in the report instead of guessing.
- Before writing code, read:
    $SKILL_DIR/references/architecture.md
    $SKILL_DIR/references/security.md
  Start from the templates in $SKILL_DIR/templates/ whenever the work touches
  encryption, auth/MFA, ownership checks, repositories, the API client, the Vite
  config, or animations. Adapt them; do not reinvent them.
- Non-negotiable:
    * Sensitive fields are encrypted with AES-256-GCM through the crypto module,
      with AAD bound to table, column, row id and owner id.
    * Every read or write of user-owned data is owner-scoped in the repository
      query. Never trust ownerId, userId or role from the request body. Foreign
      resources return 404.
    * Inputs are validated with zod (.strict()); SQL is parameterized.
    * Clean Architecture dependency rule: domain <- application <- infrastructure/interface.
- Write or update tests. Every new or changed resource endpoint needs a cross-user
  (IDOR) test. Run the tests, typecheck and lint, and fix failures before reporting.
- Do not commit, push, rewrite git history, or touch the .orchestrator/ directory.
- Never print secrets or key material.

Finish your final message with this section, exactly:

## DEV REPORT
- Status: done | partial | blocked
- Files changed: <paths>
- Tests: <commands run and results>
- Security notes: <encryption, ownership, MFA decisions>
- Open questions: <or "none">

---

# TASK BRIEF ($task)

$(cat "$brief")
EOF

echo "Delegating $task to $ORCH_DEV_MODEL (session $session)..." >&2
echo "Watch live: $watch_cmd" >&2
if (( watch )); then
  if [[ $(uname) == Darwin ]] && command -v osascript >/dev/null 2>&1; then
    # Open after the run has started so it creates the session with its title.
    ( sleep 3
      osascript -e 'on run argv' -e 'tell application "Terminal" to do script (item 1 of argv)' \
        -e 'tell application "Terminal" to activate' -e 'end run' "$watch_cmd" >/dev/null 2>&1 \
        || echo "warning: could not open the watch window; run the Watch live command yourself" >&2
    ) &
  else
    echo "warning: --watch needs macOS Terminal; run the Watch live command yourself" >&2
  fi
fi
set +e
(cd "$repo" && "${cmd[@]}" "$(cat "$prompt_file")") 2>&1 | strip_ansi > "$log"
status=${PIPESTATUS[0]}
set -e

echo "log: $log"
echo "session: $session"
echo
last_section "$log" "DEV REPORT"
echo
echo "Working tree changes (git status --short):"
git -C "$repo" status --short
if (( status != 0 )); then
  echo "error: opencode exited with status $status; see $log" >&2
  exit "$status"
fi
