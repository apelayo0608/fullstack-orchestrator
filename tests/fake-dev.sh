#!/usr/bin/env bash
# Stand-in for a developer CLI, used by tests/run.sh through ORCH_DEV_CMD.
# It writes a few files over a couple of seconds so the live change feed has something
# to report in stages, then ends with a normal DEV REPORT.
set -euo pipefail

mkdir -p src
printf 'export const a = 1;\n' > src/app.ts
sleep 0.4
printf 'export const b = 2;\n' >> src/app.ts
mkdir -p src/features
printf 'export const feature = true;\n' > src/features/feature.ts
sleep 0.4
printf 'notes from the stub developer\n' > NOTES.md

cat <<'EOF'
## DEV REPORT
- Status: done
- Files changed: src/app.ts, src/features/feature.ts, NOTES.md
- Tests: not run (stub)
- Security notes: none
- Open questions: none
EOF
