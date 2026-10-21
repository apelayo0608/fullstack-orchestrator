#!/usr/bin/env bash
# Show what a delegated developer is changing, live. Runner-agnostic: it watches
# the task's git working tree, so it behaves the same for opencode, claude and codex.
#
# Usage: watch-changes.sh [--task T01] [--repo DIR] [--interval SECS] [--full]
#                         [--json] [--once] [--summary] [--follow]
#
#   --task      Task id already delegated with delegate-dev.sh.
#   --repo      Any path inside the target git repo (default: current directory).
#   --interval  Poll interval in seconds (default ORCH_WATCH_INTERVAL, 1).
#   --full      Also stream the diff hunks as files change, not just the file list.
#   --json      Emit JSONL events (one per changed file) instead of the human view.
#   --once      Print the current state and exit.
#   --summary   Print "CHANGES: <n> files, +<added> -<removed>" plus the file list, then exit.
#   --follow    Keep watching until the task's developer run exits (default when not --once).
#
# The baseline is .orchestrator/baselines/<task>.tree, the same snapshot delegate-dev.sh
# takes before the task's first run and check.sh diffs against. Without one it falls back
# to HEAD, so it also works on a task that has not started yet.
#
# In the human view, a TTY gets a redrawn panel; a pipe or log gets one line per event,
# so `watch-changes.sh --task T01 | tee live.log` is safe. `--json` is append-only.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

task="" repo="." interval="${ORCH_WATCH_INTERVAL:-1}" full=0 json=0 once=0 summary=0 follow=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task=${2:?}; shift 2 ;;
    --repo) repo=${2:?}; shift 2 ;;
    --interval) interval=${2:?}; shift 2 ;;
    --full) full=1; shift ;;
    --json) json=1; shift ;;
    --once) once=1; shift ;;
    --summary) summary=1; shift ;;
    --follow) follow=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ $interval =~ ^[0-9]+$ ]] && (( interval > 0 )) || die "--interval must be a positive integer"

main="$(main_root "$repo")"
orch="$main/.orchestrator"

# Without --task, use the only registered worktree or the only active baseline.
if [[ -z $task ]]; then
  shopt -s nullglob
  recs=("$orch"/worktrees/*.path) bases=("$orch"/baselines/*.tree)
  if (( ${#recs[@]} + ${#bases[@]} == 1 )); then
    [[ ${#recs[@]} -eq 1 ]] && task="$(basename "${recs[0]}" .path)" || task="$(basename "${bases[0]}" .tree)"
  fi
  shopt -u nullglob
fi
[[ -n $task ]] || die "--task is required (more than one task is active: $(ls "$orch"/baselines 2>/dev/null | sed 's/\.tree$//' | tr '\n' ' '))"
check_task_id "$task"

work="$(task_workdir "$main" "$task")"
base_file="$orch/baselines/$task.tree"
if [[ -f $base_file ]]; then base="$(<"$base_file")"; else base="$(git -C "$work" rev-parse HEAD 2>/dev/null || true)"; fi
[[ -n $base ]] || die "no baseline for $task and $work has no commits yet"

pid_file="$orch/sessions/$task.run.pid"
events_file="$orch/logs/$task-changes.jsonl"
mkdir -p "$orch/logs"
start=$(date +%s)
declare -A prev=() first_done=0

# escape for JSON strings (paths and status are the only free text)
json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

# current_state: fills STATE[path]="status added removed" for every changed file.
# It compares two tree objects (baseline vs. a snapshot of the working tree), the same
# way check.sh does. A plain `git diff <tree>` cannot see untracked files and reports a
# file that was untracked at baseline as a deletion, so both sides must be trees.
declare -A STATE=()
CUR_TREE=""
current_state() {
  STATE=()
  local line st p1 p2 added removed path cur
  cur="$(worktree_tree "$work" 2>/dev/null || true)"
  [[ -n $cur ]] || return 0
  CUR_TREE=$cur
  declare -A letters=()
  while IFS=$'\t' read -r st p1 p2; do
    [[ -n $st ]] || continue
    case "$st" in
      R*|C*) letters["$p2"]="${st:0:1}"; letters["$p1"]="${st:0:1}" ;;
      *)     letters["$p1"]="${st:0:1}" ;;
    esac
  done < <(git -C "$work" diff --name-status -M "$base" "$cur" 2>/dev/null || true)
  while IFS=$'\t' read -r added removed path; do
    [[ -n $path ]] || continue
    [[ $path == .orchestrator/* ]] && continue
    [[ $added == "-" ]] && added=0 && removed=0
    STATE["$path"]="${letters[$path]:-M} $added $removed"
  done < <(git -C "$work" diff --numstat --find-renames -M "$base" "$cur" 2>/dev/null || true)
}

totals() {
  local p files=0 added=0 removed=0 a r
  for p in "${!STATE[@]}"; do
    files=$((files + 1))
    read -r _ a r <<< "${STATE[$p]}"
    added=$((added + ${a:-0})); removed=$((removed + ${r:-0}))
  done
  printf '%s %s %s' "$files" "$added" "$removed"
}

# emit_diff <path>: the hunks for one file, so the user watches the code, not just names.
emit_diff() {
  local p=$1
  git -C "$work" diff --no-color --no-ext-diff "$base" "${CUR_TREE:-$base}" -- "$p" 2>/dev/null \
    | tail -n +5 | head -80 || true
}

redraw() {
  local p files added removed elapsed
  read -r files added removed <<< "$(totals)"
  elapsed=$(( $(date +%s) - start ))
  printf '\033[H\033[2J'
  printf '\033[1m%s\033[0m · live changes · %02d:%02d · %s file(s) · \033[32m+%s\033[0m \033[31m-%s\033[0m\n\n' \
    "$task" $((elapsed / 60)) $((elapsed % 60)) "$files" "$added" "$removed"
  if (( files == 0 )); then
    printf '  (no changes yet — waiting for the developer to write)\n'
  else
    for p in $(printf '%s\n' "${!STATE[@]}" | sort); do
      local s a r mark color
      read -r s a r <<< "${STATE[$p]}"
      case "$s" in
        A) color=32 ;; D) color=31 ;; R|C) color=35 ;; *) color=33 ;;
      esac
      printf '  \033[%sm%s\033[0m  %-52s \033[32m+%s\033[0m \033[31m-%s\033[0m\n' "$color" "$s" "$p" "$a" "$r"
    done
  fi
  printf '\n\033[2mCtrl-C to stop watching (the developer keeps running)\033[0m\n'
}

restore() { [[ -t 1 ]] && printf '\033[?25h\033[0m\n' || true; }
trap restore EXIT
trap 'exit 130' INT TERM

if (( summary )); then
  current_state
  read -r files added removed <<< "$(totals)"
  echo "CHANGES: $files file(s), +$added -$removed"
  for p in $(printf '%s\n' "${!STATE[@]}" | sort); do
    read -r s a r <<< "${STATE[$p]}"
    printf '  %s %s (+%s -%s)\n' "$s" "$p" "$a" "$r"
  done
  exit 0
fi

if (( once )); then
  current_state
  if (( json )); then
    for p in $(printf '%s\n' "${!STATE[@]}" | sort); do
      read -r s a r <<< "${STATE[$p]}"
      printf '{"t":%d,"file":"%s","status":"%s","added":%s,"removed":%s}\n' \
        $(( $(date +%s) - start )) "$(json_escape "$p")" "$s" "$a" "$r"
    done
  else
    redraw
  fi
  exit 0
fi

[[ -t 1 ]] && printf '\033[?25l'
declare -A EVENT=()
while :; do
  current_state
  now=$(( $(date +%s) - start ))
  local_events=()
  for p in "${!STATE[@]}"; do
    [[ ${prev[$p]:-} == "${STATE[$p]}" ]] && continue
    read -r s a r <<< "${STATE[$p]}"
    EVENT["$p"]="$(printf '{"t":%d,"file":"%s","status":"%s","added":%s,"removed":%s}' \
      "$now" "$(json_escape "$p")" "$s" "$a" "$r")"
    printf '%s\n' "${EVENT[$p]}" >> "$events_file"
    local_events+=("$p")
  done

  if (( json )); then
    for p in "${local_events[@]}"; do printf '%s\n' "${EVENT[$p]}"; done
  elif [[ -t 1 ]]; then
    redraw
    if (( full && first_done )); then
      for p in "${local_events[@]}"; do
        printf '\n\033[1m--- %s ---\033[0m\n' "$p"
        emit_diff "$p"
      done
      sleep 0.2
    fi
  else
    for p in "${local_events[@]}"; do
      read -r s a r <<< "${STATE[$p]}"
      printf '[%02d:%02d] %s %s (+%s -%s)\n' $((now / 60)) $((now % 60)) "$s" "$p" "$a" "$r"
      (( full )) && emit_diff "$p" || true
    done
  fi
  for p in "${!STATE[@]}"; do prev["$p"]="${STATE[$p]}"; done
  first_done=1

  # --follow: stop once the developer run that this feed belongs to has exited.
  if (( follow )) && [[ -f $pid_file ]]; then
    if ! kill -0 "$(<"$pid_file")" 2>/dev/null; then
      current_state
      (( json )) || (( ! json )) && { (( json )) || redraw; }
      break
    fi
  fi
  sleep "$interval"
done
