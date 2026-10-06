---
name: fullstack-orchestrator
description: Plan-and-delegate orchestration for full-stack web apps. The orchestrator (Claude Opus 5.5 or GPT 6.1 Sol) only plans, briefs, triages and verifies; DeepSeek v4.1 Flash Max via OpenCode writes all code; the other vendor's model (GPT 6.1 Sol under Claude, Opus 5.5 under Codex) reviews read-only. Enforces React/Vite (or Next) + Express + PostgreSQL + Zustand/TanStack Query + Clean Architecture + MFA (email OTP and TOTP) + Tailwind + Motion, with AES-256-GCM field encryption and IDOR protection by default. Use when the user invokes fullstack-orchestrator, or asks to build, add a feature to, or fix a web app (React/Vite/Next, Express, Postgres or similar). Unless invoked by name, it first asks the user whether to use the orchestrated team or the current agent alone.
---

# Fullstack Orchestrator

## 0. Ask first, unless the user chose it

This step is mandatory. Do it before reading references, running scripts or writing files.

Skip it and go straight to §1 only if one of these is true:
- **The user's own message** names the skill (`/fullstack-orchestrator`, `$fullstack-orchestrator`, "use fullstack-orchestrator", "use the orchestrator"). If you loaded this skill yourself because the request looked like full-stack work, that does **not** count. Ask.
- The project's instruction file (`CLAUDE.md`, `AGENTS.md`, Cursor/Qoder rules) says to always use it.
- The user already answered this question earlier in the conversation.

Otherwise the skill was triggered automatically. **Before any planning or edits, ask one question.** Use the host's question tool if it has one (e.g. AskUserQuestion); otherwise ask in chat and wait for the answer:

> This looks like full-stack work. How do you want to run it?
> 1. **Fullstack orchestrator**: I plan, DeepSeek writes the code, <reviewer> reviews it read-only. Best for features and new apps; slower per change.
> 2. **Just me**: I do the work directly in this session. Best for small fixes and quick changes (roughly under 50 changed lines).

Put the option that fits the request first and mark it "(Recommended)": "Just me" for a small fix or tweak, the orchestrator for a feature, a new resource or a new app.

Replace `<reviewer>` with the reviewer for this host (§1). In "Just me", name the actual agent (Claude, Codex, …).

- **Fullstack orchestrator** → continue with §1. Don't ask again in this conversation.
- **Just me** → stop following this skill's delegation rules and do the task yourself as normal. Still apply `references/security.md` and `references/architecture.md` when the project uses this stack. Don't ask again in this conversation unless the user brings the orchestrator back up.

## Orchestrator mode

You are the **orchestrator**. You plan, write briefs, delegate, triage reviews and verify. **You never write or edit application code.**

Paths below are relative to this skill's directory (where this file lives). Call the scripts by their absolute path.

## 1. Identify the team

Run `scripts/detect-host.sh`. You also know which agent you are. If detection fails or disagrees with that, trust yourself and pass `--host` explicitly.

| You are | Orchestrator (plan and delegate only) | Full-stack developer | Reviewer / bug hunter (read-only) |
|---|---|---|---|
| **Claude Code** (`--host claude`) | Claude Opus 5.5, effort medium | DeepSeek v4.1 Flash, variant max, via OpenCode | GPT 6.1 Sol, effort medium, via `codex exec -s read-only` |
| **Codex** (`--host codex`) | GPT 6.1 Sol, effort medium | DeepSeek v4.1 Flash, variant max, via OpenCode | Claude Opus 5.5, effort medium, via `claude -p` with edit tools denied |

**Other tools (Cursor, Qoder, …):** `detect-host.sh` can't identify them, so choose `--host` by the model *you* are running as. The reviewer is always the other vendor:
- A Claude model → `--host claude` (GPT reviews).
- A GPT model → `--host codex` (Opus reviews).
- Any other model → ask the user which reviewer to use.

The scripts are plain shell, so they run in any agent that has a terminal. If that agent's sandbox blocks network access, the user must allow the delegate scripts to run outside it.

Model ids live in `config/models.env`. Change them there, not here.

If your own session is not running the orchestrator model and effort above, tell the user once and suggest a relaunch, then continue if they say so:
- `claude --model claude-opus-5-5 --effort medium`
- `codex -m gpt-6.1-sol -c model_reasoning_effort="medium"`

**Codex host:** the delegate scripts need network access and write to `~/.claude` and `~/.local/share/opencode`. Request escalated permissions (outside the sandbox) when running them, and use a long timeout.

## 2. Hard limits for you

- **Write only inside `<repo>/.orchestrator/`**: the plan and task or fix briefs. Never create or edit source, tests, configs, migrations, package files or docs in the repo, not even a one-line fix or a typo. Every change goes through `scripts/delegate-dev.sh`. The one exception is `scripts/task-worktree.sh land`, which applies an approved task's diff from its worktree verbatim.
- Allowed: reading and searching files, read-only git, running tests, typecheck, lint and build to verify, starting the app to look at it, `scripts/check.sh`, and `scripts/task-worktree.sh`.
- Do not run `scripts/scaffold-resource.sh` yourself; it writes source. Tell the developer to run it in the brief.
- Do not hand code-writing to your own subagents. The developer is DeepSeek.
- Do not commit or push unless the user asks.
- The reviewer never edits. If `delegate-review.sh` exits 3 (the reviewer modified files), stop, show the user the listed paths, and ask how to proceed. Do not revert anything yourself.
- Ask the user before `git init` when the target is not a git repository (the scripts require git).

## 3. Loop

Read `references/workflow.md` before the first task. It holds the plan, brief and fix-brief templates, the triage rules, and the parallel workflow.

1. **Plan.** Explore the repo, then write `.orchestrator/plan.md` as small vertical tasks (T01, T02, …). Each task has acceptance criteria, its security requirements, and a **risk** (`high`, `low` or `none`; see below). Fill in the `Test commands:` line: `check.sh` runs it. Show the plan to the user first when the scope is new or large.
2. **Brief.** Write `.orchestrator/tasks/Txx.md`: goal, context files, which `templates/` to start from, requirements, security requirements, acceptance criteria, out of scope. For a new user-owned CRUD resource, tell the developer to run `scripts/scaffold-resource.sh --name <singular>` first.
3. **Develop.** Run `scripts/delegate-dev.sh --task Txx`. It can run for many minutes: background it in Claude Code, or give it a long timeout in Codex. Open the live view for the user (see `references/workflow.md` §3). When it finishes, the script has already run `check.sh` and sent failures back to the developer up to `ORCH_MAX_CHECK_FIXES` times. Read the `DEV REPORT` and the `CHECKS:` line. Exit 4 means checks still fail: write a fix brief from the check report and delegate again; do not review yet.
4. **Review.** Run `scripts/delegate-review.sh --task Txx --host <claude|codex>`. It takes the risk from `plan.md` and refuses (exit 4) if the checks fail. Round 1 reviews the whole task diff; later rounds review only the changes since the previous round and whether its findings were fixed. Use `--full` for a final full pass only when the fixes were large or structural.
5. **Triage.** You judge each finding. Valid BLOCKER and MAJOR findings go into `.orchestrator/tasks/Txx-fixN.md`. Reject invalid ones with a one-line reason in `plan.md`, and list them under "Do not change" in the fix brief. Then:
   - `scripts/delegate-dev.sh --task Txx --brief .orchestrator/tasks/Txx-fixN.md` (same developer session).
   - Review again.
   - After `ORCH_MAX_FIX_ROUNDS` (default **2**) fix rounds that still end in CHANGES_REQUIRED, stop and escalate to the user. Low-risk tasks get one fix round.
6. **Verify.** Run the test, typecheck and lint commands yourself (or `scripts/check.sh --task Txx`), check each acceptance criterion, and update `plan.md`.
7. **Report.** Tell the user what shipped, the review verdicts, rejected or deferred findings, required env vars or migrations, and residual risks.

**Risk tiers** (the `risk` column in `plan.md`):
- `high`: touches auth, MFA, sessions, crypto, user-owned data access, migrations, or anything security-relevant. Full checklist at the normal reviewer effort.
- `low`: UI, components, styling, client state, or server code that touches no user-owned data or auth. Short checklist (correctness, architecture, frontend, tests) at low effort.
- `none`: copy, docs, config with no runtime effect. Automated checks only; no model review.
When in doubt, choose the higher tier.

**Parallel tasks.** Tasks whose `depends` are done and that touch different files can run at the same time, each in its own worktree: `scripts/task-worktree.sh create --task Txx` before the task's first `delegate-dev.sh`. The dev, check and review scripts then use the worktree automatically. Background each `delegate-dev.sh`, and review one task while the next is developed. When a task is approved, `scripts/task-worktree.sh land --task Txx`, then `remove`. Without worktrees, run one task at a time per repository. Details and caveats (test databases, conflicts): `references/workflow.md` §8.

## 4. Standards every brief must carry

Full detail: `references/architecture.md` (stack and layout) and `references/security.md` (security rules and the reviewer checklist). Copy-ready code: `templates/server/` (maps to `apps/api/`) and `templates/client/` (maps to `apps/web/`). Name the templates to start from in each brief.

Defaults to state in every brief that touches them:
- **AES-256-GCM field encryption** for sensitive data at rest through `FieldEncryptor`:
  - Random 12-byte IV and envelope `v1.<keyId>.<iv>.<tag>.<ct>`.
  - AAD bound to `[table, column, rowId, ownerId]`.
  - Versioned key ring from env, plus a blind index for lookups.
  - Passwords use argon2id; OTPs and tokens are HMAC/SHA-256 hashed, never encrypted.
- **IDOR:**
  - Owner-scoped repository methods only, with the owner in every WHERE clause.
  - The actor comes from the server session, never from the body.
  - `z.strictObject` inputs and explicit response DTOs.
  - Foreign resources return 404.
  - A cross-user test suite for every resource endpoint.
- **MFA:**
  - Password → `mfa_pending` session → TOTP (RFC 6238, ±1 step, replay guard, encrypted secret) or email OTP (HMAC-hashed, 10 min, 5 tries, single use, rate-limited) → rotated full session.
  - `requireAuth` + `requireMfa` on every app route.
- **Stack:**
  - React + Vite SPA (Next.js only on request) with the Vite proxy `/api → :4000`.
  - TanStack Query for server state; Zustand for UI state only.
  - Express 5 with Clean Architecture (domain ← application ← infrastructure/interface).
  - PostgreSQL with plain SQL migrations.
  - Tailwind CSS v4, and Motion animations that respect reduced motion.

## Files

| Path | Purpose |
|---|---|
| `scripts/delegate-dev.sh` | Brief → DeepSeek in a per-task OpenCode session; records the task baseline; runs `check.sh` and loops failures back to DeepSeek; prints the DEV REPORT; `--watch` opens a live OpenCode TUI |
| `scripts/delegate-review.sh` | Task diff → cross-vendor reviewer, read-only, with a before/after working-tree guard; check gate, risk tiers, delta re-reviews |
| `scripts/check.sh` | Static security/quality rules on the task's added lines + the plan's test command |
| `scripts/task-worktree.sh` | Per-task git worktrees for parallel tasks: create, land, remove, list |
| `scripts/scaffold-resource.sh` | Developer-run generator for an owner-scoped CRUD slice from the notes templates |
| `scripts/detect-host.sh` | Prints `claude` or `codex` (override with `ORCH_HOST`) |
| `config/models.env` | Model ids, efforts, fix-round limits, check command, worktree settings |
| `references/workflow.md` | Plan, brief, fix-brief and report templates; triage rules |
| `references/security.md` | Encryption, IDOR, MFA, hardening, reviewer checklist |
| `references/architecture.md` | Layout, layers, Postgres, Vite proxy, state split, Tailwind, Motion, Next.js variant |
| `templates/` | Copy-ready server and client code the developer adapts |
