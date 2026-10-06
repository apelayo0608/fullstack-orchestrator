#!/usr/bin/env bash
# Print which agent is orchestrating this session: "claude" or "codex".
# ORCH_HOST=claude|codex overrides detection. Exits 1 when it cannot tell.
set -euo pipefail

case "${ORCH_HOST:-}" in
  claude|codex) echo "$ORCH_HOST"; exit 0 ;;
  "") ;;
  *) echo "ORCH_HOST must be 'claude' or 'codex' (got '$ORCH_HOST')" >&2; exit 2 ;;
esac

in_claude=0 in_codex=0
[[ "${CLAUDECODE:-}" == 1 ]] && in_claude=1
[[ -n "${CODEX_THREAD_ID:-}${CODEX_SESSION_ID:-}" ]] && in_codex=1

if (( in_claude && !in_codex )); then
  echo claude
elif (( in_codex && !in_claude )); then
  echo codex
else
  echo "cannot tell Claude Code from Codex here; pass --host claude|codex or set ORCH_HOST" >&2
  exit 1
fi
