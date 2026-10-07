#!/usr/bin/env bash
# Show or change which models the orchestrator, developer and reviewer use.
#
# Usage: fullstack-orchestrator models [show]
#        fullstack-orchestrator models setup
#        fullstack-orchestrator models set <role> [<value>]
#        fullstack-orchestrator models reset [<role>]
#
# "set dev" with no value asks for the provider, then the model, then the thinking level (variant).
# Roles (set <role> <model>, or <role>-effort <low|medium|high|...>):
#   dev                 developer, OpenCode provider/model#variant
#   orch-claude         orchestrator when the host is Claude Code
#   orch-codex          orchestrator when the host is Codex
#   review-on-claude    reviewer when Claude orchestrates (runs through codex)
#   review-on-codex     reviewer when Codex orchestrates (runs through claude)
#
# Choices are saved to ~/.config/fullstack-orchestrator/models.env (or
# $XDG_CONFIG_HOME, or $ORCH_CONFIG_FILE), so they survive a reinstall. Variables
# exported in the shell still win. The orchestrator is the host session itself:
# launch it with the model shown here (claude --model ..., codex -m ...).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

roles=(dev orch-claude orch-codex review-on-claude review-on-codex)

role_var() {
  case "$1" in
    dev) echo ORCH_DEV_MODEL ;;
    orch-claude) echo ORCH_ORCHESTRATOR_MODEL_CLAUDE ;;
    orch-codex) echo ORCH_ORCHESTRATOR_MODEL_CODEX ;;
    review-on-claude) echo ORCH_REVIEW_MODEL_ON_CLAUDE ;;
    review-on-codex) echo ORCH_REVIEW_MODEL_ON_CODEX ;;
    dev-effort) die "the developer's effort is the #variant in its model id (e.g. ...#max)" ;;
    orch-claude-effort) echo ORCH_ORCHESTRATOR_EFFORT_CLAUDE ;;
    orch-codex-effort) echo ORCH_ORCHESTRATOR_EFFORT_CODEX ;;
    review-on-claude-effort) echo ORCH_REVIEW_EFFORT_ON_CLAUDE ;;
    review-on-codex-effort) echo ORCH_REVIEW_EFFORT_ON_CODEX ;;
    *) die "unknown role '$1' (see --help)" ;;
  esac
}

effort_var() {
  case "$1" in
    dev) return 1 ;;
    orch-claude) echo ORCH_ORCHESTRATOR_EFFORT_CLAUDE ;;
    orch-codex) echo ORCH_ORCHESTRATOR_EFFORT_CODEX ;;
    review-on-claude) echo ORCH_REVIEW_EFFORT_ON_CLAUDE ;;
    review-on-codex) echo ORCH_REVIEW_EFFORT_ON_CODEX ;;
  esac
}

in_user_file() { [[ -f $ORCH_USER_CONFIG ]] && grep -q "^: \"\${$1:=" "$ORCH_USER_CONFIG"; }

check_value() {
  [[ $1 =~ ^[A-Za-z0-9._:/#@+-]+$ ]] || die "'$1' is not a valid model/effort value (letters, digits and . _ : / # @ + - only)"
}

# Warn (never block) when OpenCode does not list the developer model.
warn_unlisted_dev() {
  local id=${1%%#*} models
  command -v opencode >/dev/null 2>&1 || return 0
  models="$(opencode models 2>/dev/null || true)"
  [[ -n $models ]] || return 0
  [[ $id == */* ]] || echo "warning: '$id' has no provider prefix; OpenCode ids look like provider/model#variant" >&2
  grep -qxF "$id" <<<"$models" || echo "warning: '$id' is not listed by 'opencode models'; the developer step will fail until it is (check 'opencode auth')" >&2
}

# choose "<prompt>" <current> <items...>: numbered menu; a number picks, text is taken
# as typed, Enter keeps <current>. Sets CHOICE.
choose() {
  local prompt=$1 current=$2 i=1 ans item; shift 2
  for item in "$@"; do printf '  %2d) %s\n' "$i" "$item" >&2; i=$((i + 1)); done
  read -r -p "$prompt [${current:-none}]: " ans
  if [[ -z $ans ]]; then CHOICE=$current
  elif [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= $# )); then CHOICE=${!ans}
  else CHOICE=$ans; fi
}

# Pick the developer model: provider first, then model, then variant.
pick_dev() {
  local models providers=() list=() cur=${ORCH_DEV_MODEL%%#*} variant=""
  [[ -t 0 ]] || die "picking is interactive; use 'models set dev <provider/model#variant>'"
  require_cmd opencode
  models="$(opencode models 2>/dev/null || true)"
  [[ -n $models ]] || die "'opencode models' listed nothing (log in with 'opencode auth')"
  while IFS= read -r l; do providers+=("$l"); done < <(cut -d/ -f1 <<<"$models" | sort -u)
  echo "Developer provider:" >&2
  choose "provider" "$([[ $cur == */* ]] && echo "${cur%%/*}")" "${providers[@]}"
  local provider=$CHOICE
  while IFS= read -r l; do list+=("${l#*/}"); done < <(grep "^$provider/" <<<"$models" || true)
  (( ${#list[@]} )) || die "no models listed for provider '$provider'"
  echo "Models for $provider:" >&2
  choose "model" "$([[ $cur == "$provider"/* ]] && echo "${cur#*/}")" "${list[@]}"
  local model=$CHOICE
  [[ $ORCH_DEV_MODEL == *'#'* ]] && variant=${ORCH_DEV_MODEL#*#}
  echo "Thinking level for $model:" >&2
  choose "thinking" "${variant:-none}" none low medium high max
  ans=$CHOICE; [[ $ans == none ]] && ans=""
  PICKED="$provider/$model${ans:+#$ans}"
  check_value "$PICKED"
}

write_var() {
  local var=$1 value=$2 tmp
  mkdir -p "$(dirname "$ORCH_USER_CONFIG")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/orch-models.XXXXXX")"
  { [[ -f $ORCH_USER_CONFIG ]] && grep -v "^: \"\${$var:=" "$ORCH_USER_CONFIG" || true; } >"$tmp"
  printf ': "${%s:=%s}"\n' "$var" "$value" >>"$tmp"
  mv "$tmp" "$ORCH_USER_CONFIG"
}

do_set() {
  local role=${1:-} value=${2:-} var
  [[ -n $role ]] || die "usage: models set <role> [<value>] (see --help)"
  if [[ -z $value && $role == dev ]]; then pick_dev; value=$PICKED; fi
  [[ -n $value ]] || die "usage: models set <role> <value> (see --help)"
  var="$(role_var "$role")"
  check_value "$value"
  [[ $role == dev ]] && warn_unlisted_dev "$value"
  write_var "$var" "$value"
  echo "$role: $var=$value  (saved to $ORCH_USER_CONFIG)"
}

do_reset() {
  local role=${1:-} var tmp vars=()
  if [[ -z $role ]]; then
    rm -f "$ORCH_USER_CONFIG"; echo "Removed $ORCH_USER_CONFIG; defaults restored."; return
  fi
  vars=("$(role_var "$role")")
  [[ -f $ORCH_USER_CONFIG ]] || { echo "nothing to reset"; return; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/orch-models.XXXXXX")"
  grep -v "^: \"\${${vars[0]}:=" "$ORCH_USER_CONFIG" >"$tmp" || true
  mv "$tmp" "$ORCH_USER_CONFIG"
  echo "$role reset to its default."
}

do_show() {
  local r var ev mark
  printf '%-18s %-36s %s\n' ROLE MODEL THINKING
  for r in "${roles[@]}"; do
    var="$(role_var "$r")"
    mark=""; in_user_file "$var" && mark=" *"
    ev="-"; if evar="$(effort_var "$r" 2>/dev/null)"; then ev="${!evar}"; fi
    printf '%-18s %-36s %s\n' "$r" "${!var}$mark" "$ev"
  done
  echo
  echo "* = set in $ORCH_USER_CONFIG"
  echo "Launch the orchestrator with:"
  echo "  claude --model $ORCH_ORCHESTRATOR_MODEL_CLAUDE --effort $ORCH_ORCHESTRATOR_EFFORT_CLAUDE"
  echo "  codex -m $ORCH_ORCHESTRATOR_MODEL_CODEX -c model_reasoning_effort=\"$ORCH_ORCHESTRATOR_EFFORT_CODEX\""
}

do_setup() {
  local r var ans evar
  [[ -t 0 ]] || die "setup is interactive; use 'models set <role> <value>' instead"
  echo "Press Enter to keep the current value."
  for r in "${roles[@]}"; do
    var="$(role_var "$r")"
    if [[ $r == dev ]]; then
      echo "dev (OpenCode), now ${!var}"
      pick_dev; [[ $PICKED == "${!var}" ]] || write_var "$var" "$PICKED"
      continue
    fi
    read -r -p "$r model [${!var}]: " ans
    if [[ -n $ans ]]; then check_value "$ans"; write_var "$var" "$ans"; fi
    if evar="$(effort_var "$r" 2>/dev/null)"; then
      echo "$r thinking level:"
      choose "thinking" "${!evar}" low medium high xhigh max
      [[ $CHOICE == "${!evar}" ]] || { check_value "$CHOICE"; write_var "$evar" "$CHOICE"; }
    fi
  done
  echo; ORCH_USER_CONFIG=$ORCH_USER_CONFIG bash "$0" show
}

case "${1:-show}" in
  show) do_show ;;
  setup) do_setup ;;
  set) shift; do_set "$@" ;;
  reset) shift; do_reset "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown command '$1' (show | setup | set | reset)" ;;
esac
