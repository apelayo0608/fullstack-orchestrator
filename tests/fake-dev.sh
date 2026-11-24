#!/usr/bin/env bash
# Stand-in for a developer CLI, used by the tests through ORCH_DEV_CMD.
# Writes a few files over a couple of seconds so the live change feed has something
# to report in stages, then ends with a normal DEV REPORT.
#
# ORCH_FAKE_FILES overrides the file list (space separated) so parallel workers can
# write into their own scope.
set -euo pipefail

files="${ORCH_FAKE_FILES:-src/app.ts src/features/feature.ts NOTES.md}"
list=""
for f in $files; do
  mkdir -p "$(dirname "$f")"
  printf 'created by the stub developer%s: %s\n' "${ORCH_FAKE_TAG:+ ($ORCH_FAKE_TAG)}" "$f" >> "$f"
  list="${list:+$list, }$f"
  sleep 0.3
done

cat <<EOF
## DEV REPORT
- Status: done
- Files changed: $list
- Tests: not run (stub)
- Security notes: none
- Open questions: none
EOF
