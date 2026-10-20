# Shared helpers for the fullstack-orchestrator scripts. Source, don't execute.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
# Per-user model choices (scripts/models.sh) load first, so they beat the defaults
# in config/models.env and survive a reinstall; exported variables beat both.
ORCH_USER_CONFIG="${ORCH_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/fullstack-orchestrator/models.env}"
# shellcheck disable=SC1090
[[ -f $ORCH_USER_CONFIG ]] && source "$ORCH_USER_CONFIG"
# shellcheck source=../config/models.env
source "$SKILL_DIR/config/models.env"

export NO_COLOR=1

die() { echo "error: $*" >&2; exit 1; }

# Print the leading comment block of the calling script as its help text.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' is not on PATH"; }

check_task_id() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,40}$ ]] || die "task id must match [A-Za-z0-9][A-Za-z0-9_-]* (got '$1')"
}

repo_root() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null \
    || die "$1 is not inside a git repository. Ask the user before running 'git init' there."
}

# The main working tree, even when called from inside a task worktree.
# .orchestrator/ (plan, briefs, reviews) always lives here.
main_root() {
  local common
  repo_root "$1" >/dev/null
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"
  if [[ $(basename "$common") == .git ]]; then dirname "$common"; else repo_root "$1"; fi
}

# Where a task's code lives: its registered worktree (task-worktree.sh create),
# or the main working tree.
task_workdir() {
  local main=$1 task=$2 rec="$1/.orchestrator/worktrees/$2.path" wt
  if [[ -f $rec ]]; then
    wt="$(<"$rec")"
    [[ -d $wt ]] || die "worktree for $task is registered but missing: $wt (task-worktree.sh remove --task $task --force)"
    echo "$wt"
  else
    echo "$main"
  fi
}

# Test command for checks: ORCH_CHECK_CMD, else the "Test commands:" line of plan.md.
plan_test_cmd() {
  local orch=$1 line
  if [[ -n ${ORCH_CHECK_CMD:-} ]]; then echo "$ORCH_CHECK_CMD"; return; fi
  [[ -f $orch/plan.md ]] || return 0
  line="$(grep -m1 -i '^Test commands:' "$orch/plan.md" | sed -E 's/^[Tt]est commands:[[:space:]]*//; s/`//g')" || true
  [[ $line == *'<'*'>'* ]] && return 0   # still the template placeholder
  echo "$line"
}

# The task's risk (high | low | none) from the "risk" column of plan.md's task table.
# A worker id ("T03-web") falls back to its parent task ("T03"), so parallel slices
# inherit the risk of the slice they belong to.
plan_risk() {
  local orch=$1 task=$2 base risk
  [[ -f $orch/plan.md ]] || return 0
  risk="$(risk_from_plan "$orch/plan.md" "$task")"
  base="${task%-*}"
  if [[ -z $risk && $base != "$task" ]]; then
    risk="$(risk_from_plan "$orch/plan.md" "$base")"
  fi
  printf '%s' "$risk"
}

risk_from_plan() {
  awk -F'|' -v t="$2" '
    /^\|/ && !col { for (i = 1; i <= NF; i++) { h = $i; gsub(/[[:space:]]/, "", h); if (tolower(h) == "risk") col = i } next }
    col && /^\|/ { id = $2; gsub(/[[:space:]]/, "", id); if (id == t) { r = $col; gsub(/[[:space:]]/, "", r); print tolower(r); exit } }
  ' "$1"
}

# path_in_scope <path> <comma-or-space separated globs>: 0 when the path matches one.
# Patterns are bash globs, so "client/src/**" and "client/src/*.ts" both work.
path_in_scope() {
  local path=$1 scopes=$2 pat
  for pat in ${scopes//,/ }; do
    [[ -n $pat ]] || continue
    # shellcheck disable=SC2053  # deliberate: the pattern comes from the manifest
    [[ $path == $pat ]] && return 0
  done
  return 1
}

# globs_overlap <a> <b>: rough check that two scope patterns can match the same file.
# It compares the literal prefixes ("client/src/**" vs "client/**"), which catches the
# mistakes that matter here: a slice nested inside another, or duplicated scopes.
globs_overlap() {
  local a=${1%%/\*\*} b=${2%%/\*\*}
  a=${a%%\**} b=${b%%\**}
  a=${a%/} b=${b%/}
  [[ $a == "$b" || $a == "$b/"* || $b == "$a/"* ]]
}

# Create .orchestrator/ and keep it out of git without touching tracked files.
ensure_workspace() {
  local repo=$1 exclude
  mkdir -p "$repo/.orchestrator/"{tasks,reviews,logs,baselines,sessions,checks,worktrees}
  exclude="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  mkdir -p "$(dirname "$exclude")"
  grep -qxF '.orchestrator/' "$exclude" 2>/dev/null || echo '.orchestrator/' >> "$exclude"
}

# Hash the full working tree (tracked + untracked, minus ignored files) as a git
# tree object, using a throwaway index. Never touches HEAD, the real index or refs.
worktree_tree() {
  local repo=$1 tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/orch-index.XXXXXX")"
  cp "$(git -C "$repo" rev-parse --absolute-git-dir)/index" "$tmp" 2>/dev/null || rm -f "$tmp"
  GIT_INDEX_FILE="$tmp" git -C "$repo" add -A -- . >/dev/null 2>&1
  GIT_INDEX_FILE="$tmp" git -C "$repo" write-tree
  rm -f "$tmp"
}

# OpenCode session ids must start with "ses". One stable session per repo + task,
# so fix rounds keep the developer's context.
session_id() {
  local repo=$1 task=$2 hash
  hash="$(printf '%s' "$repo" | shasum -a 256 | cut -c1-8)"
  printf 'ses_orch_%s_%s' "$hash" "${task//-/_}"
}

strip_ansi() {
  if command -v perl >/dev/null 2>&1; then perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g'; else cat; fi
}

# Print the last "## <marker>" section of a file, or its tail if the marker is missing.
last_section() {
  local file=$1 marker=$2
  if grep -q "^## $marker" "$file"; then
    awk -v m="^## $marker" '$0 ~ m {buf=""; f=1} f {buf = buf $0 "\n"} END {printf "%s", buf}' "$file"
  else
    echo "(no '## $marker' section found; last 60 lines of output)"
    tail -n 60 "$file"
  fi
}

# --- Roles: provider (runner), model and thinking level ----------------------

check_runner() {
  [[ $1 == opencode || $1 == claude || $1 == codex ]] || die "runner must be opencode, claude or codex (got '$1')"
}

# dev_effort <risk>: the developer's thinking level. A #variant in ORCH_DEV_MODEL wins.
dev_effort() {
  local risk=${1:-high}
  if [[ $ORCH_DEV_MODEL == *'#'* ]]; then echo "${ORCH_DEV_MODEL#*#}"
  elif [[ $risk == high ]]; then echo "$ORCH_DEV_EFFORT_HIGH_RISK"
  else echo "$ORCH_DEV_EFFORT"; fi
}

# resolve_review <host|""> <risk> <mode>: sets REV_RUNNER, REV_MODEL, REV_EFFORT, REV_LABEL.
# host is only needed while ORCH_REVIEW_RUNNER=auto.
resolve_review() {
  local host=$1 risk=$2 mode=$3 d_model d_eff d_low
  REV_RUNNER=$ORCH_REVIEW_RUNNER
  if [[ $REV_RUNNER == auto ]]; then
    case "$host" in
      claude) REV_RUNNER=codex ;;
      codex) REV_RUNNER=claude ;;
      *) die "cannot pick the reviewer without a host (claude or codex)" ;;
    esac
    if [[ $host == claude ]]; then d_model=$ORCH_REVIEW_MODEL_ON_CLAUDE; d_eff=$ORCH_REVIEW_EFFORT_ON_CLAUDE; d_low=$ORCH_REVIEW_EFFORT_LOW_ON_CLAUDE
    else d_model=$ORCH_REVIEW_MODEL_ON_CODEX; d_eff=$ORCH_REVIEW_EFFORT_ON_CODEX; d_low=$ORCH_REVIEW_EFFORT_LOW_ON_CODEX; fi
  else
    check_runner "$REV_RUNNER"
    d_model="" d_eff="" d_low=""
  fi
  REV_MODEL=${ORCH_REVIEW_MODEL:-$d_model}
  [[ -n $REV_MODEL ]] || die "ORCH_REVIEW_MODEL is required when ORCH_REVIEW_RUNNER=$REV_RUNNER (fullstack-orchestrator models set review <model>)"
  REV_EFFORT=${ORCH_REVIEW_EFFORT:-$d_eff}
  if [[ $risk == low ]]; then REV_EFFORT=${ORCH_REVIEW_EFFORT_LOW:-${d_low:-$REV_EFFORT}}
  elif [[ $mode == delta && -n $ORCH_REVIEW_EFFORT_DELTA ]]; then REV_EFFORT=$ORCH_REVIEW_EFFORT_DELTA; fi
  REV_LABEL="$REV_MODEL${REV_EFFORT:+ ($REV_EFFORT)} via $REV_RUNNER"
}

# --- Hang watchdog ------------------------------------------------------------

# Kill a process and all its descendants, children first (ps -ef: UID PID PPID on
# Linux, macOS and Git Bash). Git Bash: taskkill /T also reaches native Windows children.
kill_tree() {
  local c
  for c in $(ps -ef | awk -v p="$1" '$3 == p {print $2}'); do kill_tree "$c"; done
  [[ -r /proc/$1/winpid ]] && taskkill //F //T //PID "$(<"/proc/$1/winpid")" >/dev/null 2>&1
  kill "$1" 2>/dev/null
  return 0
}

# Progress fingerprint: sizes of the given files plus the working tree of <work>.
progress_sig() {
  local work=$1 f; shift
  for f in "$@"; do wc -c 2>/dev/null < "$f" || echo -; done
  worktree_tree "$work"
}

# run_watched <work> <file>... -- <cmd...>: run cmd in the background and check it every
# ORCH_HANG_CHECK_SECS. No growth in the files and no change in <work> since the last
# check means it hangs: kill its whole tree and return 124. Otherwise cmd's exit status.
run_watched() {
  local work=$1 files=() pid last now waited
  shift
  while [[ $1 != -- ]]; do files+=("$1"); shift; done
  shift
  (( ORCH_HANG_CHECK_SECS > 0 )) || { "$@"; return; }
  "$@" & pid=$!
  last="$(progress_sig "$work" "${files[@]}")"
  while :; do
    waited=0
    while (( waited < ORCH_HANG_CHECK_SECS )) && kill -0 "$pid" 2>/dev/null; do sleep 5; waited=$((waited + 5)); done
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; return; }
    now="$(progress_sig "$work" "${files[@]}")"
    if [[ $now == "$last" ]]; then
      kill_tree "$pid"; wait "$pid" 2>/dev/null
      return 124
    fi
    last=$now
  done
}

# Final text of a `claude -p --output-format stream-json` run (its stream is the watchdog's
# progress signal; text output stays silent until the end). Falls back to non-JSON lines.
claude_result() {
  require_cmd node
  node -e '
    let res = null; const other = [];
    for (const l of require("fs").readFileSync(process.argv[1], "utf8").split("\n")) {
      try { const j = JSON.parse(l); if (j.type === "result") res = j.result ?? JSON.stringify(j); }
      catch { if (l.trim()) other.push(l); }
    }
    process.stdout.write((res ?? other.join("\n")) + "\n");' "$1"
}
