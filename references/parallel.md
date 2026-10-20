# Parallel delegation

One task can be split into slices that several developers build **at the same time**, then
integrated into one tree and checked once. This is for a task with a real seam — frontend and
backend of the same feature, or two independent resources — not for "do it faster".

## When to slice

Slice when:
- the plan's task touches two areas with a **contract** between them (HTTP API, shared types, events);
- each slice can be described without the other's implementation;
- the slices touch **disjoint paths**.

Do not slice auth, MFA, crypto, migrations or anything that mutates a shared invariant: those
are exactly the places where two agents guessing at each other's code produces something that
typechecks and is wrong.

## Manifest

`.orchestrator/tasks/<task>.workers.md`:

```markdown
## Worker: web
brief: .orchestrator/tasks/T01-web.md
scope: client/src/**, client/*.json
env: VITE_API_URL=http://localhost:4000

## Worker: api
brief: .orchestrator/tasks/T01-api.md
scope: server/src/**, migrations/**
env: DATABASE_URL=postgres://localhost:5433/orch_api

## Shared
contract: .orchestrator/contracts/T01.md
```

- `scope` is a comma-separated list of bash globs. Anything a worker touches outside it is a
  **scope violation** and that worker is not integrated.
- `env` is repeatable, one `KEY=VALUE` per line, and is exported only to that worker. Use it for
  a per-worker test database, or a frontend base URL pointing at the API slice.
- `contract` is inlined into every worker's brief. Without it two agents invent two different
  response shapes and the integration compiles but does not work.

## Run it

```bash
scripts/delegate-parallel.sh --task T01 --workers .orchestrator/tasks/T01.workers.md
```

What it does, in order:

1. Validates the manifest: unique ids, briefs exist, scopes non-empty and **disjoint**
   (`--allow-overlap` to bypass), contract exists.
2. Snapshots the main working tree once and creates **one worktree per worker pinned to that
   same tree**, so every worker diff shares an ancestor and merges three-way.
3. Fans out `delegate-dev.sh --no-check --live` per worker, at most `ORCH_MAX_PARALLEL`
   at a time, `ORCH_STAGGER_SECS` apart, with one prefixed live feed per worker.
4. Runs `check.sh --static-only` per worker — cheap, no model, no test database, and the
   findings are attributable to one worker's diff.
5. Verifies every changed path is inside that worker's scope.
6. Integrates: each worker's tree becomes a commit, merged into a fresh `<task>-int` worktree.
   Conflicted merges stop here with `.orchestrator/tasks/<task>.merge-conflicts.md`.
7. Runs the full test command **once** on the merged tree, then writes
   `.orchestrator/tasks/<task>.parallel-report.md`.

## Exit codes

| code | meaning |
|---|---|
| 0 | integrated, checks pass |
| 2 | manifest or usage error (nothing ran) |
| 4 | integration checks failed |
| 5 | merge conflict |
| 6 | a worker edited outside its scope (that worker was not integrated) |
| 7 | a worker process failed (its slice is missing) |

## After a run

- Review the **integration worktree** diff once (`--task <task>-int`), not each worker
  separately: a reviewer must judge what actually lands, and each half can look fine on its own
  while the pair is inconsistent.
- `CHECKS: PASS` plus the report is the hand-off. The report names the files each worker
  touched, which is what you need to route a fix brief if the integration check fails.
- Worker worktrees are kept for inspection; `--cleanup` removes them after a clean run.

## Recovery

- **Conflict** (exit 5): give the developer a merge brief in the integration worktree, or
  re-slice so the scopes are disjoint. The conflict report lists the files and worktree paths.
- **Scope violation** (exit 6): the worker's work is intact in its own worktree. Write a
  corrected brief and rerun that worker (`--task T01-web`), or take the file out of its scope
  and give it to the owner.
- **Worker failed** (exit 7): read `.orchestrator/logs/<worker>-run.log`. The other slices
  were still integrated; rerun only the failed worker.

## Limits

- **Cost scales with workers.** Two developers is two model bills and two rate-limit lanes.
- **Dependency installs**: workers are created with `--no-install` (static checks do not need
  them); the integration worktree installs once before running the full test command.
- **Databases**: the full test command runs only once, on the merged tree, so parallel workers
  do not race over one test database. Per-worker `env:` is for tests a worker runs itself.
- **Windows**: the scripts need bash 4+ (Git Bash usually ships 4.4+; macOS ships 3.2, so use
  `brew install bash`).
