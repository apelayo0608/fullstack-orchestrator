#!/usr/bin/env bash
# Show or change the provider, model and thinking level of every role.
#
# Usage: fullstack-orchestrator models [show]
#        fullstack-orchestrator models setup
#        fullstack-orchestrator models set <role|role-field> [<value>]
#        fullstack-orchestrator models reset [<role|role-field>]
#
# Roles: dev, review, orch-claude, orch-codex. Each has a model; dev and review also have a
# provider (runner: opencode, claude or codex); every role has a thinking level.
#   set dev                      pick provider, model and thinking level interactively
#   set dev <provider/model>     e.g. opencode-go/deepseek-v4.1-flash (a #variant pins the thinking)
#   set dev-runner <opencode|claude|codex>
#   set dev-effort <level>       thinking level for tasks with risk low/none
#   set dev-effort-high-risk <level>   thinking level for risk: high tasks (default max)
#   set review                   pick provider, model and thinking level interactively
#   set review-runner <auto|opencode|claude|codex>   auto = the other vendor of the host
#   set review <model>           empty by default: auto uses the per-host defaults below
#   set review-effort <level>    round 1 / risk high;  review-effort-low;  review-effort-delta
#   set orch-claude <model>, orch-claude-effort <level>   (same for orch-codex)
#   set review-on-claude / review-on-codex [-effort|-effort-low]   per-host auto defaults
#
# Choices are saved to ~/.config/fullstack-orchestrator/models.env (or
# $XDG_CONFIG_HOME, or $ORCH_CONFIG_FILE), so they survive a reinstall. Variables
# exported in the shell still win. The orchestrator is the host session itself:
# launch it with the model shown here (claude --model ..., codex -m ...).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

roles=(dev review orch-claude orch-codex)

role_var() {
  case "$1" in
    dev) echo ORCH_DEV_MODEL ;;
    dev-runner) echo ORCH_DEV_RUNNER ;;
    dev-effort) echo ORCH_DEV_EFFORT ;;
    dev-effort-high-risk) echo ORCH_DEV_EFFORT_HIGH_RISK ;;
    review) echo ORCH_REVIEW_MODEL ;;
    review-runner) echo ORCH_REVIEW_RUNNER ;;
    review-effort) echo ORCH_REVIEW_EFFORT ;;
    review-effort-low) echo ORCH_REVIEW_EFFORT_LOW ;;
    review-effort-delta) echo ORCH_REVIEW_EFFORT_DELTA ;;
    orch-claude) echo ORCH_ORCHESTRATOR_MODEL_CLAUDE ;;
    orch-claude-effort) echo ORCH_ORCHESTRATOR_EFFORT_CLAUDE ;;
    orch-codex) echo ORCH_ORCHESTRATOR_MODEL_CODEX ;;
    orch-codex-effort) echo ORCH_ORCHESTRATOR_EFFORT_CODEX ;;
    review-on-claude) echo ORCH_REVIEW_MODEL_ON_CLAUDE ;;
    review-on-claude-effort) echo ORCH_REVIEW_EFFORT_ON_CLAUDE ;;
    review-on-claude-effort-low) echo ORCH_REVIEW_EFFORT_LOW_ON_CLAUDE ;;
    review-on-codex) echo ORCH_REVIEW_MODEL_ON_CODEX ;;
    review-on-codex-effort) echo ORCH_REVIEW_EFFORT_ON_CODEX ;;
    review-on-codex-effort-low) echo ORCH_REVIEW_EFFORT_LOW_ON_CODEX ;;
    *) die "unknown role '$1' (see --help)" ;;
  esac
}


check_value() {
  [[ $1 =~ ^[A-Za-z0-9._:/#@+-]+$ ]] || die "'$1' is not a valid model/effort value (letters, digits and . _ : / # @ + - only)"
}

# Warn (never block) when OpenCode does not list an OpenCode model.
warn_unlisted() {
  local id=${1%%#*} models
  command -v opencode >/dev/null 2>&1 || return 0
  models="$(opencode models 2>/dev/null || true)"
  [[ -n $models ]] || return 0
  [[ $id == */* ]] || echo "warning: '$id' has no provider prefix; OpenCode ids look like provider/model" >&2
  grep -qxF "$id" <<<"$models" || echo "warning: '$id' is not listed by 'opencode models'; that step will fail until it is (check 'opencode auth')" >&2
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

# pick_model <role>: provider (runner), then model, then thinking level. Sets PICK_RUNNER,
# PICK_MODEL, PICK_EFFORT. For opencode the provider and model come from `opencode models`.
pick_model() {
  local role=$1 cur_runner cur_model cur_effort runners=(opencode claude codex)
  [[ -t 0 ]] || die "picking is interactive; use 'models set $role <model>' and '$role-runner'"
  if [[ $role == dev ]]; then
    cur_runner=$ORCH_DEV_RUNNER; cur_model=${ORCH_DEV_MODEL%%#*}; cur_effort=$ORCH_DEV_EFFORT
  else
    cur_runner=$ORCH_REVIEW_RUNNER; cur_model=$ORCH_REVIEW_MODEL; cur_effort=$ORCH_REVIEW_EFFORT
    runners=(auto "${runners[@]}")
  fi
  echo "Provider (runner) for $role:" >&2
  choose "provider" "$cur_runner" "${runners[@]}"
  PICK_RUNNER=$CHOICE
  if [[ $PICK_RUNNER == auto ]]; then
    PICK_MODEL="" PICK_EFFORT=""
    echo "auto uses the per-host reviewer defaults (models set review-on-claude / review-on-codex)." >&2
    return
  fi
  check_runner "$PICK_RUNNER"
  if [[ $PICK_RUNNER == opencode ]]; then
    require_cmd opencode
    local models providers=() list=() l provider model
    models="$(opencode models 2>/dev/null || true)"
    [[ -n $models ]] || die "'opencode models' listed nothing (log in with 'opencode auth')"
    while IFS= read -r l; do providers+=("$l"); done < <(cut -d/ -f1 <<<"$models" | sort -u)
    echo "OpenCode provider:" >&2
    choose "opencode provider" "$([[ $cur_model == */* ]] && echo "${cur_model%%/*}")" "${providers[@]}"
    provider=$CHOICE
    while IFS= read -r l; do list+=("${l#*/}"); done < <(grep "^$provider/" <<<"$models" || true)
    (( ${#list[@]} )) || die "no models listed for provider '$provider'"
    echo "Models for $provider:" >&2
    choose "model" "$([[ $cur_model == "$provider"/* ]] && echo "${cur_model#*/}")" "${list[@]}"
    model=$CHOICE
    PICK_MODEL="$provider/$model"
  else
    local suggestions=(claude-opus-5-5 claude-sonnet-5-5 claude-haiku-4-5-20251001)
    [[ $PICK_RUNNER == codex ]] && suggestions=(gpt-6.1-sol gpt-6.1-luna)
    echo "Models for $PICK_RUNNER (type any id):" >&2
    choose "model" "$cur_model" "${suggestions[@]}"
    PICK_MODEL=$CHOICE
  fi
  check_value "$PICK_MODEL"
  echo "Thinking level for $PICK_MODEL:" >&2
  choose "thinking" "${cur_effort:-none}" none low medium high xhigh max
  PICK_EFFORT=$CHOICE; [[ $PICK_EFFORT == none ]] && PICK_EFFORT=""
  return 0
}

write_var() {
  local var=$1 value=$2 tmp
  mkdir -p "$(dirname "$ORCH_USER_CONFIG")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/orch-models.XXXXXX")"
  { [[ -f $ORCH_USER_CONFIG ]] && grep -v "^: \"\${$var:=" "$ORCH_USER_CONFIG" || true; } >"$tmp"
  printf ': "${%s:=%s}"\n' "$var" "$value" >>"$tmp"
  mv "$tmp" "$ORCH_USER_CONFIG"
}

# apply_pick <role>: save what pick_model chose.
apply_pick() {
  local role=$1
  write_var "$(role_var "$role-runner")" "$PICK_RUNNER"
  if [[ $role == dev ]]; then
    write_var ORCH_DEV_MODEL "$PICK_MODEL"
    if [[ -n $PICK_EFFORT ]]; then check_value "$PICK_EFFORT"; write_var ORCH_DEV_EFFORT "$PICK_EFFORT"; fi
  else
    write_var ORCH_REVIEW_MODEL "$PICK_MODEL"
    write_var ORCH_REVIEW_EFFORT "$PICK_EFFORT"
  fi
  if [[ $PICK_RUNNER == opencode ]]; then warn_unlisted "$PICK_MODEL"; fi
  return 0
}

do_set() {
  local role=${1:-} value=${2:-} var
  [[ -n $role ]] || die "usage: models set <role> [<value>] (see --help)"
  if [[ -z $value && ( $role == dev || $role == review ) ]]; then
    pick_model "$role"; apply_pick "$role"
    echo "$role: runner=$PICK_RUNNER model=${PICK_MODEL:-auto} thinking=${PICK_EFFORT:-default}  (saved to $ORCH_USER_CONFIG)"
    return
  fi
  [[ -n $value ]] || die "usage: models set $role <value> (see --help)"
  var="$(role_var "$role")"
  check_value "$value"
  case "$role" in
    dev-runner) check_runner "$value" ;;
    review-runner) [[ $value == auto ]] || check_runner "$value" ;;
    dev) if [[ $ORCH_DEV_RUNNER == opencode ]]; then warn_unlisted "$value"; fi ;;
    review) if [[ $ORCH_REVIEW_RUNNER == opencode ]]; then warn_unlisted "$value"; fi ;;
  esac
  write_var "$var" "$value"
  echo "$role: $var=$value  (saved to $ORCH_USER_CONFIG)"
}

do_reset() {
  local role=${1:-} var tmp
  if [[ -z $role ]]; then
    rm -f "$ORCH_USER_CONFIG"; echo "Removed $ORCH_USER_CONFIG; defaults restored."; return
  fi
  var="$(role_var "$role")"
  [[ -f $ORCH_USER_CONFIG ]] || { echo "nothing to reset"; return; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/orch-models.XXXXXX")"
  grep -v "^: \"\${$var:=" "$ORCH_USER_CONFIG" >"$tmp" || true
  mv "$tmp" "$ORCH_USER_CONFIG"
  echo "$role reset to its default."
}

do_show() {
  local host n lo de think
  printf '%-22s %-9s %-26s %s\n' ROLE PROVIDER MODEL THINKING
  if [[ $ORCH_DEV_MODEL == *'#'* ]]; then think="${ORCH_DEV_MODEL#*#} (pinned in the model id)"
  else think="$ORCH_DEV_EFFORT; risk high: $ORCH_DEV_EFFORT_HIGH_RISK"; fi
  printf '%-22s %-9s %-26s %s\n' dev "$ORCH_DEV_RUNNER" "${ORCH_DEV_MODEL%%#*}" "$think"
  for host in claude codex; do
    resolve_review "$host" high full; n=$REV_EFFORT
    resolve_review "$host" low full; lo=$REV_EFFORT
    resolve_review "$host" high delta; de=$REV_EFFORT
    printf '%-22s %-9s %-26s %s\n' "review (host $host)" "$REV_RUNNER" "$REV_MODEL" \
      "${n:-default}; risk low: ${lo:-default}; later rounds: ${de:-default}"
  done
  printf '%-22s %-9s %-26s %s\n' orch-claude claude "$ORCH_ORCHESTRATOR_MODEL_CLAUDE" "$ORCH_ORCHESTRATOR_EFFORT_CLAUDE"
  printf '%-22s %-9s %-26s %s\n' orch-codex codex "$ORCH_ORCHESTRATOR_MODEL_CODEX" "$ORCH_ORCHESTRATOR_EFFORT_CODEX"
  echo
  echo "Config: $ORCH_USER_CONFIG$([[ -f $ORCH_USER_CONFIG ]] || echo ' (not created yet)')"
  echo "Change: fullstack-orchestrator models set <dev|review>   (interactive: provider, model, thinking)"
  echo "        fullstack-orchestrator models set <role>-runner|-effort <value>   (see 'models --help')"
  echo "Launch the orchestrator with:"
  echo "  claude --model $ORCH_ORCHESTRATOR_MODEL_CLAUDE --effort $ORCH_ORCHESTRATOR_EFFORT_CLAUDE"
  echo "  codex -m $ORCH_ORCHESTRATOR_MODEL_CODEX -c model_reasoning_effort=\"$ORCH_ORCHESTRATOR_EFFORT_CODEX\""
}

do_setup() {
  local r var ans evar
  [[ -t 0 ]] || die "setup is interactive; use 'models set <role> <value>' instead"
  echo "Press Enter to keep the current value."
  for r in dev review; do
    echo; echo "== $r =="
    pick_model "$r"; apply_pick "$r"
  done
  for r in orch-claude orch-codex; do
    var="$(role_var "$r")"; evar="$(role_var "$r-effort")"
    echo; echo "== $r (the host session itself) =="
    read -r -p "$r model [${!var}]: " ans
    if [[ -n $ans ]]; then check_value "$ans"; write_var "$var" "$ans"; fi
    choose "thinking" "${!evar}" low medium high xhigh max
    if [[ $CHOICE != "${!evar}" ]]; then check_value "$CHOICE"; write_var "$evar" "$CHOICE"; fi
  done
  echo; bash "$0" show
}

case "${1:-show}" in
  show) do_show ;;
  setup) do_setup ;;
  set) shift; do_set "$@" ;;
  reset) shift; do_reset "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown command '$1' (show | setup | set | reset)" ;;
esac
