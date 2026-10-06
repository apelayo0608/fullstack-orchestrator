#!/usr/bin/env bash
# Give a task its own git worktree so independent tasks can be developed and
# reviewed in parallel, then land the result back in the main working tree.
#
# Usage: task-worktree.sh <create|land|remove|list> [--task T03] [--repo DIR] [--no-install] [--force]
#
#   create  New worktree for the task, starting from the main tree's CURRENT state
#           (uncommitted changes included, via a snapshot commit; no branch, HEAD
#           or index is touched). Copies ignored .env files and installs
#           dependencies (ORCH_WORKTREE_SETUP, else detected from the lockfile).
#           Must run before the task's first delegate-dev.sh; after that,
#           delegate-dev.sh, delegate-review.sh and check.sh use it automatically.
#   land    Apply the task's whole diff (baseline -> worktree) to the main working
#           tree. Only the working tree changes; nothing is staged or committed.
#           Exit 5 on conflict: the patch is saved for a developer merge brief.
#   remove  Delete the worktree. Refuses until the task is landed, unless --force.
#   list    Show registered task worktrees.
#
#   --no-install  create: skip the dependency install.
#   --force       remove: discard an unlanded worktree.
#
# Worktrees live in ORCH_WORKTREE_ROOT (default: <repo parent>/.<repo name>-orch/).
# While any task runs in a worktree, run every other active task in its own worktree
# too: landing changes the main tree and would leak into a task developing there.
# Tasks that share a test database must not run their tests at the same time;
# give each worktree its own database (e.g. via its .env) or run those tasks serially.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

action="${1:-}"; [[ $# -gt 0 ]] && shift
task="" repo="." install=1 force=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task=${2:?}; shift 2 ;;
    --repo) repo=${2:?}; shift 2 ;;
    --no-install) install=0; shift ;;
    --force) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
case "$action" in create|land|remove|list) ;; -h|--help) usage; exit 0 ;; *) die "usage: task-worktree.sh <create|land|remove|list> --task Txx" ;; esac

main="$(main_root "$repo")"
orch="$main/.orchestrator"
ensure_workspace "$main"
wt_root="${ORCH_WORKTREE_ROOT:-$(dirname "$main")/.$(basename "$main")-orch}"

if [[ $action == list ]]; then
  shopt -s nullglob
  for rec in "$orch"/worktrees/*.path; do
    t="$(basename "$rec" .path)"
    state=active; [[ -f "$orch/worktrees/$t.landed" ]] && state=landed
    printf '%-10s %-7s %s\n' "$t" "$state" "$(<"$rec")"
  done
  exit 0
fi

[[ -n $task ]] || die "--task is required"
check_task_id "$task"
rec="$orch/worktrees/$task.path"

case "$action" in
  create)
    [[ -f $rec ]] && die "$task already has a worktree: $(<"$rec")"
    [[ -f "$orch/baselines/$task.tree" ]] && die "$task already started in the main tree; finish it there"
    wt="$wt_root/$task"
    [[ -e $wt ]] && die "$wt already exists"
    mkdir -p "$wt_root"

    tree="$(worktree_tree "$main")"
    parent=(); git -C "$main" rev-parse -q --verify HEAD >/dev/null && parent=(-p HEAD)
    snapshot="$(GIT_AUTHOR_NAME=orchestrator GIT_AUTHOR_EMAIL=orchestrator@localhost \
                GIT_COMMITTER_NAME=orchestrator GIT_COMMITTER_EMAIL=orchestrator@localhost \
                git -C "$main" commit-tree "$tree" "${parent[@]}" -m "orchestrator snapshot for $task")"
    git -C "$main" worktree add --detach "$wt" "$snapshot" >/dev/null
    echo "$wt" > "$rec"
    # The developer's baseline is the snapshot, so the task diff starts clean.
    echo "$tree" > "$orch/baselines/$task.tree"

    # Ignored env files do not travel with git; copy them.
    while IFS= read -r f; do
      [[ $f =~ (^|/)\.env(\.[A-Za-z0-9_-]+)?$ && $f != *node_modules/* ]] || continue
      mkdir -p "$wt/$(dirname "$f")"
      cp -p "$main/$f" "$wt/$f"
      echo "copied $f" >&2
    done < <(git -C "$main" ls-files --others --ignored --exclude-standard)

    if (( install )); then
      setup="${ORCH_WORKTREE_SETUP:-}"
      if [[ -z $setup ]]; then
        if   [[ -f $wt/pnpm-lock.yaml ]];    then setup="pnpm install --frozen-lockfile --prefer-offline"
        elif [[ -f $wt/bun.lock || -f $wt/bun.lockb ]]; then setup="bun install --frozen-lockfile"
        elif [[ -f $wt/yarn.lock ]];         then setup="yarn install --frozen-lockfile"
        elif [[ -f $wt/package-lock.json ]]; then setup="npm ci --prefer-offline --no-audit --no-fund"
        fi
      fi
      if [[ -n $setup ]]; then
        echo "installing dependencies: $setup" >&2
        (cd "$wt" && bash -c "$setup") > "$orch/logs/$task-worktree-setup.log" 2>&1 \
          || die "dependency install failed; see $orch/logs/$task-worktree-setup.log"
        # Installs must not count as task changes.
        worktree_tree "$wt" > "$orch/baselines/$task.tree"
      fi
    fi
    echo "worktree: $wt"
    echo "$task now develops, checks and reviews there automatically."
    ;;

  land)
    [[ -f $rec ]] || die "$task has no worktree"
    wt="$(task_workdir "$main" "$task")"
    patch="$orch/worktrees/$task.patch"
    git -C "$main" diff --binary "$(<"$orch/baselines/$task.tree")" "$(worktree_tree "$wt")" > "$patch"
    [[ -s $patch ]] || die "$task has no changes to land"
    last="" r=1
    while [[ -e "$orch/reviews/$task-r$r.md" ]]; do last="$orch/reviews/$task-r$r.md"; r=$((r + 1)); done
    if [[ -z $last ]] || ! grep -q '^## REVIEW VERDICT: APPROVE' "$last"; then
      echo "warning: $task's latest review is not APPROVE${last:+ ($last)}" >&2
    fi
    if git -C "$main" apply --check "$patch" 2>"$orch/logs/$task-land.log"; then
      git -C "$main" apply "$patch"
      touch "$orch/worktrees/$task.landed"
      echo "landed $task into $main (working tree only; nothing staged or committed)"
      git -C "$main" apply --stat "$patch"
    else
      echo "CONFLICT: $task does not apply cleanly to the main tree:" >&2
      cat "$orch/logs/$task-land.log" >&2
      echo "Patch saved at $patch. Write a merge brief for the developer to integrate it in the main tree." >&2
      exit 5
    fi
    ;;

  remove)
    [[ -f $rec ]] || die "$task has no worktree"
    wt="$(<"$rec")"
    if [[ ! -f "$orch/worktrees/$task.landed" ]] && (( !force )); then
      die "$task is not landed; run 'land' first, or pass --force to discard its work"
    fi
    if [[ -d $wt ]]; then git -C "$main" worktree remove --force "$wt"; else git -C "$main" worktree prune; fi
    rm -f "$rec" "$orch/worktrees/$task.landed"
    echo "removed $wt"
    ;;
esac
