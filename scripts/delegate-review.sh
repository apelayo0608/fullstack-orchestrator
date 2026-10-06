#!/usr/bin/env bash
# Send a task's diff to the read-only reviewer from the other vendor.
#
# Usage: delegate-review.sh --task T01 [--brief PATH] [--host claude|codex] [--risk high|low|none]
#                           [--full] [--skip-checks] [--repo DIR] [--dry-run]
#
#   --task         Task id already delegated with delegate-dev.sh (its baseline must exist).
#   --brief        Brief the work is judged against (default: .orchestrator/tasks/<task>.md).
#   --host         Who is orchestrating. Claude -> GPT reviewer via codex exec;
#                  Codex -> Opus reviewer via claude -p. Default: detect-host.sh.
#   --risk         high: full security checklist at the normal effort (default).
#                  low:  correctness/architecture/frontend/tests checklist at low effort.
#                  none: no model review; records an APPROVE once the checks pass.
#                  Default: the task's "risk" column in plan.md, else high.
#   --full         In round 2+, review the whole task diff again instead of the delta.
#   --skip-checks  Do not require a passing check.sh run first.
#   --repo         Any path inside the target git repo (default: current directory).
#   --dry-run      Print the reviewer command without running it.
#
# Round 1 reviews the whole task diff (baseline -> now). Later rounds review only
# what changed since the previous round, plus whether the previous findings are fixed.
# Writes .orchestrator/reviews/<task>-r<N>.{diff,tree,md} (+ .delta.diff in round 2+).
# Exit codes: 0 review written (read the verdict), 3 the reviewer modified the
# working tree (review discarded), 4 checks failed (fix them first), other non-zero
# means the reviewer CLI failed.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

task="" brief="" host="" risk="" repo="." full=0 skip_checks=0 dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task=${2:?}; shift 2 ;;
    --brief) brief=${2:?}; shift 2 ;;
    --host) host=${2:?}; shift 2 ;;
    --risk) risk=${2:?}; shift 2 ;;
    --full) full=1; shift ;;
    --skip-checks) skip_checks=1; shift ;;
    --repo) repo=${2:?}; shift 2 ;;
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
risk="${risk:-$(plan_risk "$orch" "$task")}"
risk="${risk:-high}"
[[ $risk == high || $risk == low || $risk == none ]] || die "--risk must be high, low or none (got '$risk')"
if [[ $risk != none ]]; then
  host="${host:-$("$SCRIPT_DIR/detect-host.sh")}" || exit 1
  [[ $host == claude || $host == codex ]] || die "--host must be claude or codex"
fi

round=1
while [[ -e "$orch/reviews/$task-r$round.md" ]]; do round=$((round + 1)); done
prev=$((round - 1))
diff_file="$orch/reviews/$task-r$round.diff"
delta_file="$orch/reviews/$task-r$round.delta.diff"
tree_file="$orch/reviews/$task-r$round.tree"
out="$orch/reviews/$task-r$round.md"
prompt_file="$orch/logs/$task-review-r$round.prompt.md"
log="$orch/logs/$task-review-r$round.log"

mode=full
(( round > 1 && !full )) && [[ -f "$orch/reviews/$task-r$prev.tree" && -f "$orch/reviews/$task-r$prev.md" ]] && mode=delta

if [[ $host == claude ]]; then
  effort="$ORCH_REVIEW_EFFORT_ON_CLAUDE"; [[ $risk == low ]] && effort="$ORCH_REVIEW_EFFORT_LOW_ON_CLAUDE"
  reviewer="$ORCH_REVIEW_MODEL_ON_CLAUDE ($effort) via codex"
  cmd=(codex exec -m "$ORCH_REVIEW_MODEL_ON_CLAUDE"
       -c "model_reasoning_effort=\"$effort\""
       -c 'approval_policy="never"'
       -s read-only --ephemeral --skip-git-repo-check
       -C "$work" -o "$out" -)
elif [[ $host == codex ]]; then
  effort="$ORCH_REVIEW_EFFORT_ON_CODEX"; [[ $risk == low ]] && effort="$ORCH_REVIEW_EFFORT_LOW_ON_CODEX"
  reviewer="$ORCH_REVIEW_MODEL_ON_CODEX ($effort) via claude"
  allowed='Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*),Bash(git ls-files:*),Bash(git blame:*)'
  cmd=(claude -p --model "$ORCH_REVIEW_MODEL_ON_CODEX" --effort "$effort"
       --permission-mode dontAsk --allowedTools "$allowed"
       --disallowedTools 'Edit,Write,NotebookEdit'
       --no-session-persistence --output-format text)
  # The diffs live in the main tree's .orchestrator/, outside a task worktree.
  [[ $work != "$repo" ]] && cmd+=(--add-dir "$orch")
fi

if (( dry_run )); then
  echo "repo:     $repo"
  [[ $work != "$repo" ]] && echo "workdir:  $work (task worktree)"
  echo "round:    $round ($mode)"
  echo "risk:     $risk"
  if [[ $risk == none ]]; then
    echo "reviewer: none (checks only)"
  else
    echo "reviewer: $reviewer"
    echo "command:  (cd $work && ${cmd[*]} < <prompt>)"
  fi
  echo "output:   $out"
  exit 0
fi

[[ -f "$orch/baselines/$task.tree" ]] || die "no baseline for $task; run delegate-dev.sh --task $task first"
ensure_workspace "$repo"

if (( round > ORCH_MAX_FIX_ROUNDS + 1 )); then
  echo "warning: this is review round $round, past ORCH_MAX_FIX_ROUNDS=$ORCH_MAX_FIX_ROUNDS fix rounds; you should be escalating to the user" >&2
fi

# Checks gate: never spend a model review on work that fails the automated checks.
before="$(worktree_tree "$work")"
if (( !skip_checks )); then
  last="$(cat "$orch/checks/$task.last" 2>/dev/null || true)"
  if [[ $last != "PASS $before" ]]; then
    set +e
    "$SCRIPT_DIR/check.sh" --task "$task" --repo "$repo" --quiet >&2
    rc=$?
    set -e
    if (( rc == 4 )); then
      echo "error: automated checks fail for $task; send the report to the developer (fix brief) before reviewing" >&2
      exit 4
    fi
    (( rc == 0 )) || die "check.sh failed to run (exit $rc)"
    before="$(worktree_tree "$work")"   # tests may have touched files
  fi
fi

base="$(<"$orch/baselines/$task.tree")"
git -C "$repo" diff "$base" "$before" > "$diff_file"
[[ -s $diff_file ]] || die "no changes since the $task baseline; nothing to review"
echo "$before" > "$tree_file"

if [[ $risk == none ]]; then
  {
    echo "## REVIEW VERDICT: APPROVE"
    echo
    echo "Risk none: no model review. Automated checks passed on tree $before."
  } > "$out"
  echo "review: $out (risk none, checks only)"
  exit 0
fi
require_cmd "${cmd[0]}"

checklist="$(awk '/^## Reviewer checklist/ {f=1; next} f && /^## / {exit} f' "$SKILL_DIR/references/security.md")"
if [[ $risk == low ]]; then
  checklist="$(grep -E '\*\*(Correctness|Architecture|Frontend behaviour|Tests and build):\*\*' <<<"$checklist")"
fi

if [[ $mode == delta ]]; then
  git -C "$repo" diff "$(<"$orch/reviews/$task-r$prev.tree")" "$before" > "$delta_file"
  [[ -s $delta_file ]] || die "nothing changed since review round $prev; run the fix round first"
  fix_brief="$(ls -t "$orch/tasks/$task"-fix*.md 2>/dev/null | head -n 1 || true)"
  scope="This is review round $round. The developer has worked on the findings of round $prev.
Review the CHANGES SINCE ROUND $prev, not the whole task again.

INPUTS
- Repository root: $work
- Changes since round $prev (primary input; read all of it): $delta_file
- Previous review: $orch/reviews/$task-r$prev.md
- Fix brief the developer worked from: ${fix_brief:-none}
  Findings the orchestrator rejected are listed there under \"Do not change\".
- Complete task diff, for context only: $diff_file
- Task brief: between the BEGIN/END markers below.

YOUR JOB
1. For every BLOCKER and MAJOR finding of round $prev, decide FIXED, NOT_FIXED, or
   REJECTED (the fix brief rejected it). Check the code, not the developer's word.
2. Look for new defects and regressions introduced by the changes since round $prev.
   Open unchanged code only for context; do not re-audit it."
  findings_header="### Prior findings
- #<n> (<severity> <category>): FIXED | NOT_FIXED | REJECTED - <one line of evidence>

### New findings"
  checklist_rule="CHECKLIST (only the items the changes since round $prev touch; skip the rest)"
else
  scope="INPUTS
- Repository root: $work
- Complete diff for this task (baseline -> now): $diff_file
  Read all of it, then open the touched files and their callers for context.
- Task brief: between the BEGIN/END markers below."
  findings_header="### Findings"
  checklist_rule="CHECKLIST (go through every item; mark N/A when the diff does not touch it)"
fi

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
- Automated checks already passed: tests, typecheck, lint, and static rules for
  z.strictObject, actor ids from the request, interpolated SQL, unscoped WHERE id,
  routers without requireMfa, .only/.skip, type suppressions and raw HTML. Lines
  marked "orch-allow" were exempted on purpose; judge whether each exemption is safe.
  Spend your time on logic, ownership, crypto and flow bugs that those cannot see.

$scope

===== BEGIN TASK BRIEF ($task) =====
$(cat "$brief")
===== END TASK BRIEF =====

$checklist_rule
$checklist

OUTPUT: reply with exactly this markdown, nothing before or after it.

## REVIEW VERDICT: APPROVE | CHANGES_REQUIRED
(CHANGES_REQUIRED if there is at least one BLOCKER or MAJOR finding still open.)

$findings_header
1. [BLOCKER|MAJOR|MINOR] <category: idor | crypto | mfa | auth | injection | correctness | tests | architecture | frontend | performance> - <file>:<line>
   - Problem: <one or two sentences>
   - Failure scenario: <concrete input or state -> wrong result>
   - Fix direction: <what to change; no full patches>
(Write "None." when there are no findings.)

### Checklist results
- <item>: PASS | FAIL (finding #) | N/A - <one line of evidence>
EOF

echo "Review round $round ($mode, risk $risk) of $task by $reviewer..." >&2
set +e
if [[ $host == claude ]]; then
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT "${cmd[@]}" < "$prompt_file" 2>&1 | strip_ansi > "$log"
  status=${PIPESTATUS[0]}
else
  (cd "$work" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT "${cmd[@]}" < "$prompt_file" > "$out" 2> "$log")
  status=$?
fi
set -e

after="$(worktree_tree "$work")"
if [[ $before != "$after" ]]; then
  [[ -f $out ]] && mv "$out" "$out.rejected"
  rm -f "$tree_file"
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
  rm -f "$tree_file"
  echo "error: reviewer exited with status $status; see $log" >&2
  exit $(( status == 0 ? 1 : status ))
fi

echo "review: $out"
echo "diff:   $diff_file"
[[ $mode == delta ]] && echo "delta:  $delta_file"
echo
cat "$out"
