#!/usr/bin/env bash
# Send a task's diff to the read-only reviewer from the other vendor.
#
# Usage: delegate-review.sh --task T01 [--brief PATH] [--host claude|codex] [--repo DIR] [--dry-run]
#
#   --task     Task id already delegated with delegate-dev.sh (its baseline must exist).
#   --brief    Brief the work is judged against (default: .orchestrator/tasks/<task>.md).
#   --host     Who is orchestrating. Claude -> GPT reviewer via codex exec;
#              Codex -> Opus reviewer via claude -p. Default: detect-host.sh.
#   --repo     Any path inside the target git repo (default: current directory).
#   --dry-run  Print the reviewer command without running it.
#
# Writes .orchestrator/reviews/<task>-r<N>.diff and <task>-r<N>.md.
# Exit codes: 0 review written (read the verdict), 3 the reviewer modified the
# working tree (review discarded), other non-zero means the reviewer CLI failed.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

task="" brief="" host="" repo="." dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task=${2:?}; shift 2 ;;
    --brief) brief=${2:?}; shift 2 ;;
    --host) host=${2:?}; shift 2 ;;
    --repo) repo=${2:?}; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n $task ]] || die "--task is required"
check_task_id "$task"
host="${host:-$("$SCRIPT_DIR/detect-host.sh")}" || exit 1
[[ $host == claude || $host == codex ]] || die "--host must be claude or codex"
repo="$(repo_root "$repo")"
orch="$repo/.orchestrator"
brief="${brief:-$orch/tasks/$task.md}"
[[ -f $brief ]] || die "brief not found: $brief"

round=1
while [[ -e "$orch/reviews/$task-r$round.md" ]]; do round=$((round + 1)); done
diff_file="$orch/reviews/$task-r$round.diff"
out="$orch/reviews/$task-r$round.md"
prompt_file="$orch/logs/$task-review-r$round.prompt.md"
log="$orch/logs/$task-review-r$round.log"

if [[ $host == claude ]]; then
  reviewer="$ORCH_REVIEW_MODEL_ON_CLAUDE ($ORCH_REVIEW_EFFORT_ON_CLAUDE) via codex"
  cmd=(codex exec -m "$ORCH_REVIEW_MODEL_ON_CLAUDE"
       -c "model_reasoning_effort=\"$ORCH_REVIEW_EFFORT_ON_CLAUDE\""
       -c 'approval_policy="never"'
       -s read-only --ephemeral --skip-git-repo-check
       -C "$repo" -o "$out" -)
else
  reviewer="$ORCH_REVIEW_MODEL_ON_CODEX ($ORCH_REVIEW_EFFORT_ON_CODEX) via claude"
  allowed='Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*),Bash(git ls-files:*),Bash(git blame:*)'
  cmd=(claude -p --model "$ORCH_REVIEW_MODEL_ON_CODEX" --effort "$ORCH_REVIEW_EFFORT_ON_CODEX"
       --permission-mode dontAsk --allowedTools "$allowed"
       --disallowedTools 'Edit,Write,NotebookEdit'
       --no-session-persistence --output-format text)
fi

if (( dry_run )); then
  echo "repo:     $repo"
  echo "round:    $round"
  echo "reviewer: $reviewer"
  echo "command:  (cd $repo && ${cmd[*]} < <prompt>)"
  echo "output:   $out"
  exit 0
fi

[[ -f "$orch/baselines/$task.tree" ]] || die "no baseline for $task; run delegate-dev.sh --task $task first"
require_cmd "${cmd[0]}"
ensure_workspace "$repo"

base="$(<"$orch/baselines/$task.tree")"
before="$(worktree_tree "$repo")"
git -C "$repo" diff "$base" "$before" > "$diff_file"
[[ -s $diff_file ]] || die "no changes since the $task baseline; nothing to review"

checklist="$(awk '/^## Reviewer checklist/ {f=1; next} f && /^## / {exit} f' "$SKILL_DIR/references/security.md")"

cat > "$prompt_file" <<EOF
You are the REVIEWER and BUG HUNTER on an orchestrated team. A developer model
implemented the task below. The orchestrator routes your findings back to the
developer, so be precise.

HARD RULES
- You are strictly read-only. Do not create, edit, move or delete any file. Do not
  run formatters, package installs, migrations, builds, or tests that write files,
  and do not run git commands that write (commit, add, checkout, stash, reset,
  apply, or any --output flag). A guard hashes the working tree before and after
  your run and throws your review away if anything changed.
- Allowed: reading and searching files, and read-only git (diff, log, show, status,
  ls-files, blame).
- Report real, actionable defects only. Every finding needs a concrete failure
  scenario. Skip style preferences unless they hide a bug.

INPUTS
- Repository root: $repo
- Complete diff for this task (baseline -> now): .orchestrator/reviews/$task-r$round.diff
  Read all of it, then open the touched files and their callers for context.
- Task brief: between the BEGIN/END markers below.

===== BEGIN TASK BRIEF ($task) =====
$(cat "$brief")
===== END TASK BRIEF =====

CHECKLIST (go through every item; mark N/A when the diff does not touch it)
$checklist

OUTPUT: reply with exactly this markdown, nothing before or after it.

## REVIEW VERDICT: APPROVE | CHANGES_REQUIRED
(CHANGES_REQUIRED if there is at least one BLOCKER or MAJOR finding.)

### Findings
1. [BLOCKER|MAJOR|MINOR] <category: idor | crypto | mfa | auth | injection | correctness | tests | architecture | frontend | performance> - <file>:<line>
   - Problem: <one or two sentences>
   - Failure scenario: <concrete input or state -> wrong result>
   - Fix direction: <what to change; no full patches>
(Write "None." when there are no findings.)

### Checklist results
- <item>: PASS | FAIL (finding #) | N/A - <one line of evidence>
EOF

echo "Review round $round of $task by $reviewer..." >&2
set +e
if [[ $host == claude ]]; then
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT "${cmd[@]}" < "$prompt_file" 2>&1 | strip_ansi > "$log"
  status=${PIPESTATUS[0]}
else
  (cd "$repo" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT "${cmd[@]}" < "$prompt_file" > "$out" 2> "$log")
  status=$?
fi
set -e

after="$(worktree_tree "$repo")"
if [[ $before != "$after" ]]; then
  [[ -f $out ]] && mv "$out" "$out.rejected"
  {
    echo "!!! READ-ONLY VIOLATION: the reviewer changed the working tree. Review discarded."
    echo "Changed paths (pre-review -> now):"
    git -C "$repo" diff --stat "$before" "$after"
    echo "Nothing was reverted. Show these paths to the user and ask how to proceed."
  } >&2
  exit 3
fi

if (( status != 0 )) || [[ ! -s $out ]]; then
  [[ -f $out && ! -s $out ]] && rm -f "$out"
  echo "error: reviewer exited with status $status; see $log" >&2
  exit $(( status == 0 ? 1 : status ))
fi

echo "review: $out"
echo "diff:   $diff_file"
echo
cat "$out"
