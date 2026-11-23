#!/usr/bin/env bash
# Print which agent is orchestrating this session: "claude", "codex" or "antigravity".
# ORCH_HOST=claude|codex|antigravity overrides detection. Exits 1 when it cannot tell.
set -euo pipefail

case "${ORCH_HOST:-}" in
  claude|codex|antigravity) echo "$ORCH_HOST"; exit 0 ;;
  "") ;;
  *) echo "ORCH_HOST must be 'claude', 'codex' or 'antigravity' (got '$ORCH_HOST')" >&2; exit 2 ;;
esac

found=()
[[ "${CLAUDECODE:-}" == 1 ]] && found+=(claude)
[[ -n "${CODEX_THREAD_ID:-}${CODEX_SESSION_ID:-}" ]] && found+=(codex)
[[ -n "${ANTIGRAVITY_CONVERSATION_ID:-}${ANTIGRAVITY_AGENT:-}" ]] && found+=(antigravity)

if (( ${#found[@]} == 1 )); then
  echo "${found[0]}"
else
  echo "cannot tell Claude Code, Codex and Antigravity apart here${found[*]:+ (found: ${found[*]})}; pass --host claude|codex|antigravity or set ORCH_HOST" >&2
  exit 1
fi
