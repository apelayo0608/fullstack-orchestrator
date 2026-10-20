#!/usr/bin/env bash
# Fan one task out to several developers at once, then integrate their work.
#
# Usage: delegate-parallel.sh --task T01 --workers .orchestrator/tasks/T01.workers.md
#                             [--repo DIR] [--max-parallel N] [--stagger SECS]
#                             [--no-integrate] [--lenient] [--allow-overlap]
#                             [--cleanup] [--dry-run]
#
#   --task          Parent task id whose slices these are (T01). Worker ids are the ones
#                   in the manifest; their risk comes from the parent row of plan.md.
#   --workers       Worker manifest. Format:
#                     ## Worker: web
#                     brief: .orchestrator/tasks/T01-web.md
#                     scope: client/src/**, client/*.json
#                     env: KEY=VALUE      (optional, repeatable; the value may contain spaces)
#                     ## Worker: api
#                     brief: .orchestrator/tasks/T01-api.md
#                     scope: server/src/**, migrations/**
#                     ## Shared
#                     contract: .orchestrator/contracts/T01.md     (optional but recommended)
#   --repo          Any path inside the target git repo (default: current directory).
#   --max-parallel  How many developers run at once (default ORCH_MAX_PARALLEL, 2).
#   --stagger       Seconds between worker starts (default ORCH_STAGGER_SECS, 3) so the
#                   provider is less likely to rate-limit simultaneous runs.
#   --no-integrate  Fan out and report only; merge the worktrees yourself.
#   --lenient       Report scope violations instead of refusing to integrate that worker.
#   --allow-overlap Allow overlapping scopes (the merge may then conflict).
#   --cleanup       Remove the worker worktrees after a successful integration.
#   --dry-run       Validate the manifest and print the plan without running anything.
#
# How it works
# - Every worker gets a worktree pinned to the SAME snapshot tree of the main tree, so
#   their diffs share one ancestor and merge with real 3-way semantics.
# - The shared contract is inlined into each worker's brief, so the two sides agree on
#   the API shape before they start.
# - Each worker runs delegate-dev.sh --no-check: static checks run per worker (cheap, no
#   model, no test DB), the full test command runs once, after integration.
# - After the runs, a worker whose diff leaves its declared scope is not integrated.
# - Integration merges each worker's tree as a commit into a fresh <task>-int worktree,
#   runs check.sh there, and writes .orchestrator/tasks/<task>.parallel-report.md.
#
# Exit codes: 0 integrated and checks pass, 2 usage/manifest error, 4 checks failed
# after integration, 5 merge conflict, 6 scope violation.
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { echo "error: this script needs bash 4+ (macOS: brew install bash)" >&2; exit 1; }
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

task="" manifest="" repo="." max_parallel="${ORCH_MAX_PARALLEL:-2}" stagger="${ORCH_STAGGER_SECS:-3}"
integrate=1 lenient=0 allow_overlap=0 cleanup=0 dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task=${2:?}; shift 2 ;;
    --workers) manifest=${2:?}; shift 2 ;;
    --repo) repo=${2:?}; shift 2 ;;
    --max-parallel) max_parallel=${2:?}; shift 2 ;;
    --stagger) stagger=${2:?}; shift 2 ;;
    --no-integrate) integrate=0; shift ;;
    --lenient) lenient=1; shift ;;
    --allow-overlap) allow_overlap=1; shift ;;
    --cleanup) cleanup=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

[[ -n $task ]] || { echo "error: --task is required" >&2; exit 2; }
[[ -n $manifest ]] || { echo "error: --workers is required" >&2; exit 2; }
check_task_id "$task"

main="$(main_root "$repo")"
orch="$main/.orchestrator"
ensure_workspace "$main"
[[ $manifest == /* ]] || manifest="$main/$manifest"
[[ -f $manifest ]] || { echo "error: manifest not found: $manifest" >&2; exit 2; }

# --- Parse the manifest ------------------------------------------------------
declare -a WORKERS=()
declare -A BRIEF=() SCOPE=() ENVV=() RC=() STATIC=() TREE=()
CONTRACT=""
cur=""
while IFS= read -r line || [[ -n $line ]]; do
  line="${line%$'\r'}"
  [[ $line =~ ^[[:space:]]*#([^#]|$) ]] && continue
  if [[ $line =~ ^[[:space:]]*##[[:space:]]*Worker:[[:space:]]*(.+[^[:space:]])[[:space:]]*$ ]]; then
    cur="${BASH_REMATCH[1]}"; WORKERS+=("$cur"); continue
  fi
  [[ $line =~ ^[[:space:]]*##[[:space:]]*Shared ]] && { cur=""; continue; }
  [[ $line =~ ^[[:space:]]*([A-Za-z_-]+):[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] || continue
  key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
  case "$key" in
    brief)    [[ -n $cur ]] && BRIEF[$cur]=$val ;;
    scope)    [[ -n $cur ]] && SCOPE[$cur]=$val ;;
    env)      [[ -n $cur ]] && ENVV[$cur]+="$val"$'\n' ;;
    contract) CONTRACT=$val ;;
  esac
done < "$manifest"

# --- Validate ----------------------------------------------------------------
fail() { echo "error: $*" >&2; exit 2; }
(( ${#WORKERS[@]} > 0 )) || fail "the manifest declares no worker (expected '## Worker: <id>')"
[[ $max_parallel =~ ^[0-9]+$ ]] && (( max_parallel > 0 )) || fail "--max-parallel must be a positive integer"
[[ $stagger =~ ^[0-9]+$ ]] || fail "--stagger must be an integer"

declare -A SEEN=()
for wid in "${WORKERS[@]}"; do
  [[ -z ${SEEN[$wid]:-} ]] || fail "worker '$wid' is declared twice"
  SEEN[$wid]=1
  [[ $wid =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,40}$ ]] || fail "invalid worker id '$wid'"
  [[ $wid != "$task" ]] || fail "worker id must differ from the parent task id"
  [[ -n ${BRIEF[$wid]:-} ]] || fail "worker '$wid' has no 'brief:' line"
  [[ -n ${SCOPE[$wid]:-} ]] || fail "worker '$wid' has no 'scope:' line"
  local_brief="${BRIEF[$wid]}"
  [[ $local_brief = /* ]] || local_brief="$main/$local_brief"
  [[ -f $local_brief ]] || fail "worker '$wid' brief not found: ${BRIEF[$wid]}"
  BRIEF[$wid]=$local_brief
done

if (( ! allow_overlap )); then
  for a in "${WORKERS[@]}"; do
    for b in "${WORKERS[@]}"; do
      [[ $a < $b ]] || continue
      for pa in ${SCOPE[$a]//,/ }; do
        for pb in ${SCOPE[$b]//,/ }; do
          if globs_overlap "$pa" "$pb"; then
            fail "scopes of '$a' and '$b' overlap ('$pa' vs '$pb'); make them disjoint or pass --allow-overlap"
          fi
        done
      done
    done
  done
fi

if [[ -n $CONTRACT ]]; then
  [[ $CONTRACT = /* ]] || CONTRACT="$main/$CONTRACT"
  [[ -f $CONTRACT ]] || fail "contract not found: $CONTRACT"
else
  echo "warning: no 'contract:' in the manifest; workers may invent mismatched API shapes" >&2
fi

base="$(worktree_tree "$main")"
[[ -n $base ]] || fail "could not snapshot the main working tree"

if (( dry_run )); then
  echo "task:     $task"
  echo "base:     $base"
  echo "contract: ${CONTRACT:-none}"
  echo "parallel: $max_parallel at a time, ${stagger}s stagger"
  for wid in "${WORKERS[@]}"; do
    printf 'worker %-10s %s\n  scope: %s\n  brief: %s\n' "$wid" "" "${SCOPE[$wid]}" "${BRIEF[$wid]}"
    [[ -n ${ENVV[$wid]:-} ]] && echo "  env:   ${ENVV[$wid]}"
  done
  exit 0
fi

# --- Briefs with the shared contract inlined ---------------------------------
declare -A GENBRIEF=()
for wid in "${WORKERS[@]}"; do
  gen="$orch/logs/$wid-brief.md"
  {
    echo "# $task / worker $wid"
    echo
    echo "You are ONE of several developers working on $task in parallel. Other workers are"
    echo "editing other parts of the same codebase at the same time."
    echo
    echo "## Hard rules for parallel work"
    echo "- Stay inside your scope: ${SCOPE[$wid]}"
    echo "  Anything outside it belongs to another worker. Do not edit it, even to \"fix\" it."
    echo "- Never change files another worker owns; if the brief seems to need it, stop and"
    echo "  report it as an open question instead."
    echo "- Do not commit, push, or touch .orchestrator/."
    echo
    if [[ -n $CONTRACT ]]; then
      echo "## Shared contract (both sides code against this)"
      echo
      cat "$CONTRACT"
      echo
    fi
    echo "---"
    echo
    cat "${BRIEF[$wid]}"
  } > "$gen"
  GENBRIEF[$wid]=$gen
done

# --- Worktrees, all pinned to the same base ----------------------------------
for wid in "${WORKERS[@]}"; do
  if [[ -f "$orch/worktrees/$wid.path" ]]; then
    echo "reusing worktree for $wid: $(<"$orch/worktrees/$wid.path")" >&2
  else
    "$SCRIPT_DIR/task-worktree.sh" create --task "$wid" --repo "$main" --base-tree "$base" --no-install >&2 \
      || fail "could not create a worktree for $wid"
  fi
done

# --- Fan out -----------------------------------------------------------------
declare -a FEED_PIDS=() PIDS=()
start_feeds() {
  (( ${#FEED_PIDS[@]} == 0 )) || return 0
  for wid in "${WORKERS[@]}"; do
    "$SCRIPT_DIR/watch-changes.sh" --task "$wid" --repo "$main" --interval "${ORCH_WATCH_INTERVAL:-1}" 2>/dev/null \
      | awk -v p="$(printf '%-4s' "${wid##*-}")" '{ printf "%s | %s\n", p, $0; fflush() }' &
    FEED_PIDS+=($!)
  done
}
stop_feeds() {
  local p
  for p in "${FEED_PIDS[@]:-}"; do [[ -n $p ]] && kill "$p" 2>/dev/null || true; done
  FEED_PIDS=()
}
trap stop_feeds EXIT

echo "Fanning $task out to ${#WORKERS[@]} developers (max $max_parallel at a time)" >&2
start_feeds
i=0
for wid in "${WORKERS[@]}"; do
  if (( i >= max_parallel )); then
    wait -n 2>/dev/null || true
    i=$((i - 1))
  fi
  (
    cd "$main"
    envargs=()
    while IFS= read -r kv; do [[ -n $kv ]] && envargs+=("$kv"); done <<< "${ENVV[$wid]:-}"
    env "${envargs[@]}" ORCH_LIVE_CHANGES=0 \
      "$SCRIPT_DIR/delegate-dev.sh" --task "$wid" --repo "$main" --brief "${GENBRIEF[$wid]}" \
      --no-check --no-live
  ) > "$orch/logs/$wid-run.log" 2>&1 &
  PIDS+=("$!")
  i=$((i + 1))
  (( stagger > 0 )) && sleep "$stagger"
done

idx=0
worker_failed=0
for wid in "${WORKERS[@]}"; do
  set +e
  wait "${PIDS[$idx]}"
  RC[$wid]=$?
  set -e
  (( RC[$wid] == 0 )) || worker_failed=1
  idx=$((idx + 1))
done
stop_feeds

# --- Per-worker static checks and scope verification -------------------------
for wid in "${WORKERS[@]}"; do
  if (( ${RC[$wid]} != 0 )); then
    STATIC[$wid]="not run (developer exited ${RC[$wid]})"
    continue
  fi
  set +e
  "$SCRIPT_DIR/check.sh" --task "$wid" --repo "$main" --static-only --quiet > "$orch/logs/$wid-static.log" 2>&1
  sc=$?
  set -e
  if (( sc == 0 )); then STATIC[$wid]="pass"; else STATIC[$wid]="findings (exit $sc)"; fi
done

declare -A VIOLATIONS=() INTEGRATED=()
for wid in "${WORKERS[@]}"; do
  wt="$(task_workdir "$main" "$wid")"
  TREE[$wid]="$(worktree_tree "$wt")"
  [[ ${RC[$wid]} == 0 ]] || continue
  bad=""
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    path_in_scope "$p" "${SCOPE[$wid]}" || bad+="${bad:+, }$p"
  done < <(git -C "$main" diff --name-only "$base" "${TREE[$wid]}" 2>/dev/null || true)
  VIOLATIONS[$wid]=$bad
done

scope_blocked=0
for wid in "${WORKERS[@]}"; do
  if [[ -n ${VIOLATIONS[$wid]:-} ]]; then
    scope_blocked=1
    if (( lenient )); then
      echo "warning: $wid edited outside its scope: ${VIOLATIONS[$wid]}" >&2
    else
      echo "error: $wid edited outside its scope and will not be integrated: ${VIOLATIONS[$wid]}" >&2
    fi
  fi
done

# --- Integration -------------------------------------------------------------
int_task="$task-int"
int_wt="" conflicts="" checks="skipped" int_static=""
# Every worker commit shares this ancestor, so the merges are real three-way merges.
snap="$(cat "$orch/worktrees/${WORKERS[0]}.snapshot" 2>/dev/null || git -C "$main" rev-parse HEAD)"
integrate_worker() {
  local wid=$1 c
  c="$(GIT_AUTHOR_NAME=orchestrator GIT_AUTHOR_EMAIL=orchestrator@localhost \
       GIT_COMMITTER_NAME=orchestrator GIT_COMMITTER_EMAIL=orchestrator@localhost \
       git -C "$main" commit-tree "${TREE[$wid]}" -p "$snap" -m "orchestrator worker $wid for $task")" || return 1
  git -C "$int_wt" merge --no-ff --no-edit -m "Merge worker $wid into $task" "$c" >/dev/null 2>&1 || return 1
}

if (( integrate )); then
  # A leftover integration worktree from a previous attempt would not be at the base.
  if [[ -f "$orch/worktrees/$int_task.path" ]]; then
    "$SCRIPT_DIR/task-worktree.sh" remove --task "$int_task" --repo "$main" --force >&2 || true
  fi
  "$SCRIPT_DIR/task-worktree.sh" create --task "$int_task" --repo "$main" --base-tree "$base" >&2 \
    || fail "could not create the integration worktree"
  int_wt="$(task_workdir "$main" "$int_task")"

  for wid in "${WORKERS[@]}"; do
    [[ ${RC[$wid]} == 0 ]] || continue
    [[ -z ${VIOLATIONS[$wid]:-} ]] || (( lenient )) || continue
    if integrate_worker "$wid"; then
      INTEGRATED[$wid]=merged
    else
      conflicts="$(git -C "$int_wt" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')"
      git -C "$int_wt" merge --abort 2>/dev/null || true
      INTEGRATED[$wid]="conflict (${conflicts:-unknown files})"
      conflicts="${conflicts:-unknown}"
      break
    fi
  done

  if [[ -n $conflicts ]]; then
    {
      echo "# $task: merge conflicts"
      echo
      echo "Worker work did not merge into \`$int_task\`."
      echo
      echo "Conflicted files: $conflicts"
      echo
      echo "Resolve by giving the developer a merge brief in a worktree, or by rerunning with"
      echo "disjoint scopes. Worker worktrees are kept:"
      for wid in "${WORKERS[@]}"; do echo "- $wid: $(task_workdir "$main" "$wid")"; done
    } > "$orch/tasks/$task.merge-conflicts.md"
  else
    set +e
    "$SCRIPT_DIR/check.sh" --task "$int_task" --repo "$main" --quiet > "$orch/logs/$int_task-checks.log" 2>&1
    csc=$?
    set -e
    case "$csc" in
      0) checks="PASS" ;;
      4) checks="FAIL" ;;
      *) checks="error (exit $csc)" ;;
    esac
  fi
fi

# --- Report ------------------------------------------------------------------
report="$orch/tasks/$task.parallel-report.md"
{
  echo "# $task: parallel delegation report"
  echo
  echo "- Base tree: \`$base\`"
  echo "- Workers: ${#WORKERS[@]} (max $max_parallel at a time, ${stagger}s stagger)"
  echo "- Contract: ${CONTRACT:-none}"
  echo "- Integration: $( ((integrate)) && echo "$int_task" || echo 'skipped (--no-integrate)')"
  echo "- Integrated checks: $checks"
  echo
  echo "| worker | scope | run | static | scope check | integrated |"
  echo "|---|---|---|---|---|---|"
  for wid in "${WORKERS[@]}"; do
    run_stat="ok"; [[ ${RC[$wid]} == 0 ]] || run_stat="exit ${RC[$wid]}"
    scope_stat="ok"
    [[ -n ${VIOLATIONS[$wid]:-} ]] && scope_stat="OUT OF SCOPE: ${VIOLATIONS[$wid]}"
    echo "| $wid | \`${SCOPE[$wid]}\` | $run_stat | ${STATIC[$wid]} | $scope_stat | ${INTEGRATED[$wid]:-not integrated} |"
  done
  echo
  if [[ -n $conflicts ]]; then
    echo "## Conflicts"
    echo
    echo "Files: $conflicts"
    echo
    echo "See \`.orchestrator/tasks/$task.merge-conflicts.md\`."
    echo
  fi
  if [[ $checks == FAIL ]]; then
    echo "## Integration checks failed"
    echo
    echo "Report: \`$(ls -t "$orch/checks/$int_task"-c*.md 2>/dev/null | head -n 1)\`"
    echo
    echo "Files touched by each worker (use this to route a fix brief):"
    for wid in "${WORKERS[@]}"; do
      echo "- $wid: $(git -C "$main" diff --name-only "$base" "${TREE[$wid]}" 2>/dev/null | tr '\n' ' ')"
    done
    echo
  fi
  echo "## Logs"
  echo
  for wid in "${WORKERS[@]}"; do echo "- $wid: \`.orchestrator/logs/$wid-run.log\`, \`.orchestrator/logs/$wid-changes.jsonl\`"; done
} > "$report"

echo
for wid in "${WORKERS[@]}"; do
  printf '%-12s run:%s static:%s scope:%s %s\n' "$wid" \
    "$( [[ ${RC[$wid]} == 0 ]] && echo ok || echo "exit ${RC[$wid]}" )" \
    "${STATIC[$wid]}" \
    "$( [[ -n ${VIOLATIONS[$wid]:-} ]] && echo VIOLATION || echo ok )" \
    "${INTEGRATED[$wid]:-not integrated}"
done
echo
echo "report: $report"
[[ -n $int_wt ]] && echo "integration worktree: $int_wt"
echo "CHECKS: $checks"
(( worker_failed )) && echo "STATUS: failed — at least one worker did not finish (see the report)"

if (( cleanup )) && (( integrate )) && [[ $checks == PASS && -z $conflicts ]] && (( !worker_failed )); then
  for wid in "${WORKERS[@]}"; do
    "$SCRIPT_DIR/task-worktree.sh" remove --task "$wid" --repo "$main" --force >&2 || true
  done
fi

[[ -n $conflicts ]] && exit 5
[[ $scope_blocked == 1 ]] && (( ! lenient )) && exit 6
(( worker_failed )) && exit 7
[[ $checks == FAIL ]] && exit 4
exit 0
