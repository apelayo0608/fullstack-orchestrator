#!/usr/bin/env bash
# Hand one task brief to the full-stack developer (DeepSeek through OpenCode).
#
# Usage: delegate-dev.sh --task T01 [--brief PATH] [--repo DIR] [--new-session] [--no-check] [--watch] [--dry-run]
#
#   --task         Task id, e.g. T01. The brief defaults to .orchestrator/tasks/<task>.md.
#   --brief        Brief to send instead, e.g. .orchestrator/tasks/T01-fix1.md for a fix round.
#   --repo         Any path inside the target git repo (default: current directory).
#   --new-session  Start a fresh OpenCode session instead of continuing this task's session.
#   --no-check     Skip the automated checks (check.sh) after the run.
#   --watch        Open a Terminal.app window (macOS) with the OpenCode TUI on this task's
#                  session, so you can watch the developer live. Typing there steers it.
#   --dry-run      Print the command and prompt location without running anything.
#
# Provider, model and thinking level come from ORCH_DEV_RUNNER (opencode | claude | codex),
# ORCH_DEV_MODEL and ORCH_DEV_EFFORT / ORCH_DEV_EFFORT_HIGH_RISK; see `fullstack-orchestrator models`.
# Fix rounds in the same session get a short prompt (the session already holds the contract).
#
# The first run of a task records a baseline snapshot of the working tree so
# delegate-review.sh can diff the whole task. Full output: .orchestrator/logs/.
# If the task has a worktree (task-worktree.sh create), the developer works there.
# Runs can take many minutes: run this in the background or with a long timeout.
# The "Watch live:" line on stderr is the command that opens the same live view anywhere.
#
# After the run, check.sh runs the static rules and the test command. Failures go
# straight back to the developer in the same session, up to ORCH_MAX_CHECK_FIXES
# times, so no review round is spent on them.
# Exit codes: 0 done (checks pass or skipped), 4 checks still failing, other
# non-zero means OpenCode or the checks failed to run.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

task="" brief="" repo="." new_session=0 no_check=0 watch=0 dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task=${2:?}; shift 2 ;;
    --brief) brief=${2:?}; shift 2 ;;
    --repo) repo=${2:?}; shift 2 ;;
    --new-session) new_session=1; shift ;;
    --no-check) no_check=1; shift ;;
    --watch) watch=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n $task ]] || die "--task is required"
check_task_id "$task"
repo="$(main_root "$repo")"
orch="$repo/.orchestrator"
work="$(task_workdir "$repo" "$task")"
brief="${brief:-$orch/tasks/$task.md}"
[[ -f $brief ]] || die "brief not found: $brief"

runner="$ORCH_DEV_RUNNER"; check_runner "$runner"
risk="$(plan_risk "$orch" "$task")"; risk="${risk:-high}"
effort="$(dev_effort "$risk")"
model_id="${ORCH_DEV_MODEL%%#*}"

session_file="$orch/sessions/$task.id"
started_file="$orch/sessions/$task.started"
if (( new_session )); then rm -f "$started_file"; fi
if (( !new_session )) && [[ -f $session_file ]]; then
  session="$(<"$session_file")"
else
  hash="$(printf '%s' "$work$task" | shasum -a 256 | cut -c1-32)"
  case "$runner" in
    claude) # claude needs a UUID
      session="${hash:0:8}-${hash:8:4}-4${hash:13:3}-a${hash:17:3}-${hash:20:12}" ;;
    *) session="$(session_id "$work" "$task")" ;;
  esac
  (( new_session )) && [[ $runner == opencode ]] && session="${session}_$(date +%s)"
  (( new_session )) && [[ $runner == claude ]] && session="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z' || echo "$session")"
fi
# Codex has no resumable session here, so it always needs the full contract.
resumed=0
[[ -f $started_file && $runner != codex ]] && (( !new_session )) && resumed=1

ts="$(date +%Y%m%d-%H%M%S)"
prompt_file="$orch/logs/$task-dev-$ts.prompt.md"
log="$orch/logs/$task-dev-$ts.log"
# dev_cmd [first]: the developer command (the prompt arrives on stdin, except for opencode).
dev_cmd() {
  case "$runner" in
    opencode)
      cmd=(opencode run -m "$model_id" ${effort:+--variant "$effort"} --auto -s "$session" --title "orch $task") ;;
    claude)
      cmd=(claude -p --model "$model_id" ${effort:+--effort "$effort"} --permission-mode bypassPermissions)
      if [[ -f $started_file ]]; then cmd+=(--resume "$session"); else cmd+=(--session-id "$session"); fi ;;
    codex)
      cmd=(codex exec -m "$model_id" ${effort:+-c "model_reasoning_effort=\"$effort\""}
           -c 'approval_policy="never"' -s workspace-write --skip-git-repo-check -C "$work" -) ;;
  esac
}
dev_cmd
# The OpenCode TUI attaches to the same background service as `opencode run`, so it shows the run live.
watch_cmd=""
[[ $runner == opencode ]] && watch_cmd="cd $(printf %q "$work") && opencode -s $(printf %q "$session")"

if (( dry_run )); then
  echo "repo:    $repo"
  [[ $work != "$repo" ]] && echo "workdir: $work (task worktree)"
  echo "brief:   $brief"
  echo "session: $session"
  echo "runner:  $runner  model: $model_id  thinking: ${effort:-default}  (risk $risk)"
  echo "prompt:   $( ((resumed)) && echo 'short (resumed session)' || echo 'full contract')"
  echo "command: (cd $work && ${cmd[*]} \"<contract + brief>\")"
  echo "log:     $log"
  echo "watch:   ${watch_cmd:-n/a ($runner has no live view)}"
  exit 0
fi

require_cmd "$runner"
ensure_workspace "$repo"
[[ -f "$orch/baselines/$task.tree" ]] || worktree_tree "$work" > "$orch/baselines/$task.tree"
echo "$session" > "$session_file"

if (( resumed )); then
cat > "$prompt_file" <<EOF
Continue as the FULL-STACK DEVELOPER in this same session, on the brief below. The same
rules apply (scope, security requirements, architecture, no commits, orch-allow); you have
already read the references, so reopen them only if you need to. Run only the tests for the
files you touched, plus typecheck and lint; the full suite runs in the automated checks.
Finish with the same "## DEV REPORT" section as before (Status, Files changed, Tests,
Security notes, Open questions).

---

# BRIEF ($task)

$(cat "$brief")
EOF
else
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
- For a new user-owned CRUD resource, run the scaffold first and adapt the generated
  files instead of writing the slice by hand:
    $SKILL_DIR/scripts/scaffold-resource.sh --name <singular> [--plural <plural>]
  It prints the remaining wiring steps (fields, router mount, composition root).
- Non-negotiable:
    * Sensitive fields are encrypted with AES-256-GCM through the crypto module,
      with AAD bound to table, column, row id and owner id.
    * Every read or write of user-owned data is owner-scoped in the repository
      query. Never trust ownerId, userId or role from the request body. Foreign
      resources return 404.
    * Inputs are validated with zod z.strictObject; SQL is parameterized.
    * Clean Architecture dependency rule: domain <- application <- infrastructure/interface.
- Write or update tests. Every new or changed resource endpoint needs a cross-user
  (IDOR) test. Run the tests for the files you touched, plus typecheck and lint, and fix
  failures before reporting. Do not run the whole suite repeatedly: the automated checks
  run the full test command once when you finish.
- Automated checks run on your diff when you finish and send failures back to you.
  They flag z.object in server code, actor ids read from req.body/query/params,
  interpolated SQL, "WHERE id = \$n" without owner_id in repositories, /api routers
  mounted without requireMfa, .only/.skip, @ts-ignore and any, dangerouslySetInnerHTML,
  secret-looking VITE_* vars, and new routes without an IDOR test. If a flagged line
  is a deliberate, safe exception, add an "orch-allow: <reason>" comment on it.
- Do not commit, push, rewrite git history, or touch the .orchestrator/ directory.
- Never print secrets or key material.

Finish your final message with this section, exactly:

## DEV REPORT
- Status: done | partial | blocked
- Files changed: <paths>
- Tests: <commands run and results>
- Security notes: <encryption, ownership, MFA decisions; every orch-allow you added>
- Open questions: <or "none">

---

# TASK BRIEF ($task)

$(cat "$brief")
EOF
fi

echo "Delegating $task to $model_id${effort:+ ($effort)} via $runner (session $session, $( ((resumed)) && echo 'short prompt' || echo 'full contract'))..." >&2
[[ -n $watch_cmd ]] && echo "Watch live: $watch_cmd" >&2
if (( watch )) && [[ -z $watch_cmd ]]; then
  echo "warning: --watch only works with the opencode runner" >&2
elif (( watch )); then
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

# run_dev <prompt file> <log>: one developer turn in this task's session.
run_dev() {
  local rc
  dev_cmd
  set +e
  if [[ $runner == opencode ]]; then
    (cd "$work" && "${cmd[@]}" "$(cat "$1")") 2>&1 | strip_ansi > "$2"
  else
    (cd "$work" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT "${cmd[@]}" < "$1") 2>&1 | strip_ansi > "$2"
  fi
  rc=${PIPESTATUS[0]}
  set -e
  if (( rc != 0 )); then
    echo "error: $runner exited with status $rc; see $2" >&2
    exit "$rc"
  fi
  touch "$started_file"
}

run_dev "$prompt_file" "$log"

check_status=skipped report=""
if (( !no_check )); then
  if last_section "$log" "DEV REPORT" | grep -qiE 'Status:[[:space:]]*blocked'; then
    echo "Developer reported blocked; skipping automated checks." >&2
  else
    fixes=0
    while :; do
      set +e
      "$SCRIPT_DIR/check.sh" --task "$task" --repo "$repo" --quiet >&2
      rc=$?
      set -e
      report="$(ls -t "$orch/checks/$task"-c*.md | head -n 1)"
      if (( rc == 0 )); then check_status=PASS; break; fi
      (( rc == 4 )) || { echo "error: check.sh failed to run (exit $rc)" >&2; exit "$rc"; }
      check_status=FAIL
      (( fixes < ORCH_MAX_CHECK_FIXES )) || break
      fixes=$((fixes + 1))
      echo "Checks failed; sending them back to the developer (auto-fix $fixes/$ORCH_MAX_CHECK_FIXES)..." >&2
      ts="$(date +%Y%m%d-%H%M%S)"
      prompt_file="$orch/logs/$task-dev-$ts-autofix$fixes.prompt.md"
      log="$orch/logs/$task-dev-$ts-autofix$fixes.log"
      {
        echo "The automated checks failed on your work for $task. Fix every item below, re-run"
        echo "the tests, typecheck and lint, then finish with the same \"## DEV REPORT\" section."
        echo "Do not widen scope. Use an \"orch-allow: <reason>\" comment only on a flagged line"
        echo "that is a deliberate, safe exception, and list each one under Security notes."
        echo
        cat "$report"
      } > "$prompt_file"
      run_dev "$prompt_file" "$log"
    done
  fi
fi

echo "log: $log"
echo "session: $session"
[[ $work != "$repo" ]] && echo "workdir: $work"
echo
last_section "$log" "DEV REPORT"
echo
echo "Working tree changes (git status --short):"
git -C "$work" status --short
echo
case "$check_status" in
  PASS) echo "CHECKS: PASS ($report)" ;;
  FAIL) echo "CHECKS: FAIL after $ORCH_MAX_CHECK_FIXES auto-fix round(s). Read $report and write a fix brief; do not send this to review yet."
        exit 4 ;;
  *) echo "CHECKS: skipped" ;;
esac
