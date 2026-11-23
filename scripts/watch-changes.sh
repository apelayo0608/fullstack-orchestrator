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
prev="" first_done=0

# escape for JSON strings (paths and status are the only free text)
json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

# current_state: sets STATE to one "status<TAB>added<TAB>removed<TAB>path" line per changed
# file, sorted by path. Plain text, not an associative array: macOS ships bash 3.2.
# It compares two tree objects (baseline vs. a snapshot of the working tree), the same
# way check.sh does. A plain `git diff <tree>` cannot see untracked files and reports a
# file that was untracked at baseline as a deletion, so both sides must be trees.
STATE=""
CUR_TREE=""
current_state() {
  STATE=""
  local cur
  cur="$(worktree_tree "$work" 2>/dev/null || true)"
  [[ -n $cur ]] || return 0
  CUR_TREE=$cur
  STATE="$(awk -F'\t' '
    FILENAME == ARGV[1] { s = substr($1, 1, 1); if ($1 ~ /^[RC]/) L[$3] = s; L[$2] = s; next }
    $3 != "" && $3 !~ /^\.orchestrator\// {
      a = $1; r = $2; if (a == "-") { a = 0; r = 0 }
      print (($3 in L) ? L[$3] : "M") "\t" a "\t" r "\t" $3
    }' \
    <(git -C "$work" diff --name-status -M "$base" "$cur" 2>/dev/null || true) \
    <(git -C "$work" diff --numstat --find-renames -M "$base" "$cur" 2>/dev/null || true) \
    | sort -t "$(printf '\t')" -k4)"
}

# rows <text>: the non-empty STATE-format lines of <text>, for `while read` loops.
rows() { [[ -z $1 ]] || printf '%s\n' "$1"; }

totals() {
  rows "$STATE" | awk -F'\t' '{ a += $2; r += $3 } END { printf "%d %d %d", NR, a, r }'
}

# emit_diff <path>: the hunks for one file, so the user watches the code, not just names.
emit_diff() {
  local p=$1
  git -C "$work" diff --no-color --no-ext-diff "$base" "${CUR_TREE:-$base}" -- "$p" 2>/dev/null \
    | tail -n +5 | head -80 || true
}

redraw() {
  local s a r p files added removed elapsed color
  read -r files added removed <<< "$(totals)"
  elapsed=$(( $(date +%s) - start ))
  printf '\033[H\033[2J'
  printf '\033[1m%s\033[0m · live changes · %02d:%02d · %s file(s) · \033[32m+%s\033[0m \033[31m-%s\033[0m\n\n' \
    "$task" $((elapsed / 60)) $((elapsed % 60)) "$files" "$added" "$removed"
  if (( files == 0 )); then
    printf '  (no changes yet — waiting for the developer to write)\n'
  else
    while IFS=$'\t' read -r s a r p; do
      case "$s" in
        A) color=32 ;; D) color=31 ;; R|C) color=35 ;; *) color=33 ;;
      esac
      printf '  \033[%sm%s\033[0m  %-52s \033[32m+%s\033[0m \033[31m-%s\033[0m\n' "$color" "$s" "$p" "$a" "$r"
    done < <(rows "$STATE")
  fi
  printf '\n\033[2mCtrl-C to stop watching (the developer keeps running)\033[0m\n'
}

# json_rows <t> <text>: one JSON event per STATE-format line.
json_rows() {
  local t=$1 s a r p
  while IFS=$'\t' read -r s a r p; do
    printf '{"t":%d,"file":"%s","status":"%s","added":%s,"removed":%s}\n' "$t" "$(json_escape "$p")" "$s" "$a" "$r"
  done < <(rows "$2")
}

restore() { [[ -t 1 ]] && printf '\033[?25h\033[0m\n' || true; }
trap restore EXIT
trap 'exit 130' INT TERM

if (( summary )); then
  current_state
  read -r files added removed <<< "$(totals)"
  echo "CHANGES: $files file(s), +$added -$removed"
  while IFS=$'\t' read -r s a r p; do
    printf '  %s %s (+%s -%s)\n' "$s" "$p" "$a" "$r"
  done < <(rows "$STATE")
  exit 0
fi

if (( once )); then
  current_state
  if (( json )); then json_rows $(( $(date +%s) - start )) "$STATE"; else redraw; fi
  exit 0
fi

[[ -t 1 ]] && printf '\033[?25l'
while :; do
  current_state
  now=$(( $(date +%s) - start ))
  # Rows that are new or changed since the last poll.
  changed="$(rows "$STATE" | awk 'FILENAME == ARGV[1] { seen[$0] = 1; next } !($0 in seen)' <(rows "$prev") -)"
  events="$(json_rows "$now" "$changed")"
  [[ -z $events ]] || printf '%s\n' "$events" >> "$events_file"

  if (( json )); then
    rows "$events"
  elif [[ -t 1 ]]; then
    redraw
    if (( full && first_done )) && [[ -n $changed ]]; then
      while IFS=$'\t' read -r s a r p; do
        printf '\n\033[1m--- %s ---\033[0m\n' "$p"
        emit_diff "$p"
      done < <(rows "$changed")
      sleep 0.2
    fi
  else
    while IFS=$'\t' read -r s a r p; do
      printf '[%02d:%02d] %s %s (+%s -%s)\n' $((now / 60)) $((now % 60)) "$s" "$p" "$a" "$r"
      (( full )) && emit_diff "$p" || true
    done < <(rows "$changed")
  fi
  prev=$STATE
  first_done=1

  # --follow: stop once the developer run that this feed belongs to has exited.
  if (( follow )) && [[ -f $pid_file ]]; then
    if ! kill -0 "$(<"$pid_file")" 2>/dev/null; then
      current_state
      (( json )) || redraw
      break
    fi
  fi
  sleep "$interval"
done
