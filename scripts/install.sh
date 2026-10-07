#!/usr/bin/env bash
# Install, remove or check the fullstack-orchestrator skill for Claude Code, Codex,
# Cursor and Qoder.
#
# Usage: fullstack-orchestrator <install|uninstall|doctor> [--copy] [--only=claude,codex,cursor,qoder]
#        fullstack-orchestrator models [show|setup|set <role> [<value>]|reset]   (provider, model, thinking per role)
#
#   install     Link this folder into each tool's user skills folder (default command):
#                 ~/.claude/skills  ~/.codex/skills  ~/.cursor/skills  ~/.qoder/skills
#               Cursor and Qoder are included only when ~/.cursor or ~/.qoder exists.
#   uninstall   Remove those links/copies (only if they are this skill).
#   doctor      Check the CLIs, models and links the skill needs.
#   --copy      Copy files instead of symlinking (re-run install after every update).
#   --only=...  Comma-separated tools to touch (also: --claude-only, --codex-only).
#
# Honors CLAUDE_CONFIG_DIR and CODEX_HOME when set.
set -euo pipefail

# Resolve symlinks (npm's global bin is a link to this file).
src="${BASH_SOURCE[0]}"
while [[ -L $src ]]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  src="$(readlink "$src")"
  [[ $src == /* ]] || src="$dir/$src"
done
SKILL_DIR="$(cd -P "$(dirname "$src")/.." && pwd)"
NAME=fullstack-orchestrator

# Model routing has its own script: fullstack-orchestrator models [show|setup|set|reset]
if [[ ${1:-} == models ]]; then shift; exec bash "$SKILL_DIR/scripts/models.sh" "$@"; fi

hosts=(claude codex)
[[ -d $HOME/.cursor ]] && hosts+=(cursor)
[[ -d $HOME/.qoder ]] && hosts+=(qoder)
all_hosts=("${hosts[@]}")

cmd=install copy=0
for arg in "$@"; do
  case "$arg" in
    install|uninstall|doctor) cmd=$arg ;;
    --copy) copy=1 ;;
    --claude-only) hosts=(claude) ;;
    --codex-only) hosts=(codex) ;;
    --only=*)
      IFS=, read -r -a hosts <<<"${arg#--only=}"
      for h in "${hosts[@]}"; do
        [[ $h =~ ^(claude|codex|cursor|qoder)$ ]] || { echo "unknown tool in --only: $h" >&2; exit 2; }
      done ;;
    -h|--help|help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$src"; exit 0 ;;
    *) echo "unknown argument: $arg (see --help)" >&2; exit 2 ;;
  esac
done

skills_dir() {
  case "$1" in
    claude) echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills" ;;
    codex) echo "${CODEX_HOME:-$HOME/.codex}/skills" ;;
    cursor) echo "$HOME/.cursor/skills" ;;
    qoder) echo "$HOME/.qoder/skills" ;;
  esac
}

# True when $1 is a link to, or a copy of, this skill.
is_ours() {
  [[ -L $1 ]] && return 0
  [[ -f $1/SKILL.md ]] && grep -q "^name: $NAME\$" "$1/SKILL.md"
}

install_host() {
  local dest
  dest="$(skills_dir "$1")/$NAME"
  mkdir -p "$(dirname "$dest")"
  if [[ -e $dest || -L $dest ]]; then
    is_ours "$dest" || { echo "  ! $dest exists and is not this skill; leaving it alone" >&2; return 1; }
    rm -rf "$dest"
  fi
  if (( copy )); then
    mkdir -p "$dest"
    (cd "$SKILL_DIR" && tar --exclude node_modules --exclude .git -cf - .) | (cd "$dest" && tar -xf -)
    echo "  ✓ $1: copied to $dest"
  else
    ln -s "$SKILL_DIR" "$dest"
    echo "  ✓ $1: $dest -> $SKILL_DIR"
  fi
}

uninstall_host() {
  local dest
  dest="$(skills_dir "$1")/$NAME"
  if [[ ! -e $dest && ! -L $dest ]]; then echo "  - $1: not installed"; return 0; fi
  is_ours "$dest" || { echo "  ! $dest is not this skill; leaving it alone" >&2; return 1; }
  rm -rf "$dest"
  echo "  ✓ $1: removed $dest"
}

check() { if command -v "$1" >/dev/null 2>&1; then echo "  ✓ $1"; else echo "  ✗ $1 not on PATH ($2)"; fail=1; fi; }

case "$cmd" in
  install)
    chmod +x "$SKILL_DIR"/scripts/*.sh
    echo "Installing $NAME from $SKILL_DIR"
    for h in "${hosts[@]}"; do install_host "$h"; done
    echo "Done. Start a new session and invoke $NAME (Claude/Cursor/Qoder: /$NAME, Codex: \$$NAME)."
    echo "Check your setup any time with: fullstack-orchestrator doctor  (or npm run doctor)"
    ;;
  uninstall)
    echo "Uninstalling $NAME"
    for h in "${hosts[@]}"; do uninstall_host "$h"; done
    ;;
  doctor)
    fail=0
    echo "CLIs:"
    check git "required"; check opencode "developer"; check codex "GPT reviewer / Codex host"
    check claude "Opus reviewer / Claude host"; check perl "log cleanup"; check shasum "session ids"
    echo "Links:"
    for h in "${all_hosts[@]}"; do
      dest="$(skills_dir "$h")/$NAME"
      if is_ours "$dest" 2>/dev/null; then echo "  ✓ $h: $dest"; else echo "  ✗ $h: not installed (run install)"; fail=1; fi
    done
    # shellcheck source=lib.sh
    source "$SKILL_DIR/scripts/lib.sh"
    echo "Roles: developer $ORCH_DEV_RUNNER, reviewer $ORCH_REVIEW_RUNNER (fullstack-orchestrator models)"
    for r in "$ORCH_DEV_RUNNER" "$ORCH_REVIEW_RUNNER"; do
      [[ $r == auto || $r == opencode ]] || command -v "$r" >/dev/null 2>&1 || { echo "  ✗ runner '$r' is not on PATH"; fail=1; }
    done
    if [[ $ORCH_DEV_RUNNER == opencode ]] && command -v opencode >/dev/null 2>&1; then
      echo "Developer model:"
      # The OpenCode background service can answer empty while it starts; retry once.
      models="$(opencode models 2>/dev/null || true)"
      grep -qxF "${ORCH_DEV_MODEL%%#*}" <<<"$models" || { sleep 2; models="$(opencode models 2>/dev/null || true)"; }
      if grep -qxF "${ORCH_DEV_MODEL%%#*}" <<<"$models"; then
        echo "  ✓ ${ORCH_DEV_MODEL%%#*} available in OpenCode"
      else
        echo "  ✗ ${ORCH_DEV_MODEL%%#*} not listed by 'opencode models' (log in with 'opencode auth')"; fail=1
      fi
    fi
    (( fail == 0 )) && echo "All good." || { echo "Fix the ✗ items above."; exit 1; }
    ;;
esac
