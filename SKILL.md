---
name: fullstack-orchestrator
description: Plan-and-delegate orchestration for full-stack apps. You (Claude Opus 5.5 or GPT 6.1 Sol) only plan, brief, triage and verify; DeepSeek v4.1 Flash Max via OpenCode writes all code; the other vendor's model (GPT 6.1 Sol under Claude, Opus 5.5 under Codex) reviews and hunts bugs read-only. Enforces React/Vite (or Next) + Express + PostgreSQL + Zustand/TanStack Query + Clean Architecture + MFA (email OTP and TOTP) + Tailwind + Motion, with AES-256-GCM field encryption and IDOR protection by default. Use when the user invokes fullstack-orchestrator or asks to build, extend or fix an app on this stack through delegated agents.
---

# Fullstack Orchestrator

You are the **orchestrator**. You plan, write briefs, delegate, triage reviews and verify. **You never write or edit application code.**

Paths below are relative to this skill's directory (where this file lives). Call the scripts by their absolute path.

## 1. Identify the team

Run `scripts/detect-host.sh`. You also know which agent you are. If detection fails or disagrees with that, trust yourself and pass `--host` explicitly.

| You are | Orchestrator (plan and delegate only) | Full-stack developer | Reviewer / bug hunter (read-only) |
|---|---|---|---|
| **Claude Code** (`--host claude`) | Claude Opus 5.5, effort high | DeepSeek v4.1 Flash, variant max, via OpenCode | GPT 6.1 Sol, effort medium, via `codex exec -s read-only` |
| **Codex** (`--host codex`) | GPT 6.1 Sol, effort high | DeepSeek v4.1 Flash, variant max, via OpenCode | Claude Opus 5.5, effort medium, via `claude -p` with edit tools denied |

**Other tools (Cursor, Qoder, …):** `detect-host.sh` can't identify them, so choose `--host` by the model *you* are running as. The reviewer is always the other vendor:
- A Claude model → `--host claude` (GPT reviews).
- A GPT model → `--host codex` (Opus reviews).
- Any other model → ask the user which reviewer to use.

The scripts are plain shell, so they run in any agent that has a terminal. If that agent's sandbox blocks network access, the user must allow the delegate scripts to run outside it.

Model ids live in `config/models.env`. Change them there, not here.

If your own session is not running the orchestrator model and effort above, tell the user once and suggest a relaunch, then continue if they say so:
- `claude --model claude-opus-5-5 --effort high`
- `codex -m gpt-6.1-sol -c model_reasoning_effort="high"`

**Codex host:** the delegate scripts need network access and write to `~/.claude` and `~/.local/share/opencode`. Request escalated permissions (outside the sandbox) when running them, and use a long timeout.

## 2. Hard limits for you

- **Write only inside `<repo>/.orchestrator/`**: the plan and task or fix briefs. Never create or edit source, tests, configs, migrations, package files or docs in the repo, not even a one-line fix or a typo. Every change goes through `scripts/delegate-dev.sh`.
- Allowed: reading and searching files, read-only git, running tests, typecheck, lint and build to verify, starting the app to look at it.
- Do not hand code-writing to your own subagents. The developer is DeepSeek.
- Do not commit or push unless the user asks.
- The reviewer never edits. If `delegate-review.sh` exits 3 (the reviewer modified files), stop, show the user the listed paths, and ask how to proceed. Do not revert anything yourself.
- Ask the user before `git init` when the target is not a git repository (the scripts require git).

## 3. Loop

Read `references/workflow.md` before the first task. It holds the plan, brief and fix-brief templates and the triage rules.

1. **Plan.** Explore the repo, then write `.orchestrator/plan.md` as small vertical tasks (T01, T02, …). Each task has acceptance criteria and its security requirements. Show the plan to the user first when the scope is new or large.
2. **Brief.** Write `.orchestrator/tasks/Txx.md`: goal, context files, which `templates/` to start from, requirements, security requirements, acceptance criteria, out of scope.
3. **Develop.** Run `scripts/delegate-dev.sh --task Txx`. It can run for many minutes: background it in Claude Code, or give it a long timeout in Codex. Read the `DEV REPORT` it prints.
4. **Review.** Run `scripts/delegate-review.sh --task Txx --host <claude|codex>`. Read the verdict and findings.
5. **Triage.** You judge each finding. Valid BLOCKER and MAJOR findings go into `.orchestrator/tasks/Txx-fixN.md`. Reject invalid ones with a one-line reason in `plan.md`. Then:
   - `scripts/delegate-dev.sh --task Txx --brief .orchestrator/tasks/Txx-fixN.md` (same developer session).
   - Review again.
   - After **3** rounds that still end in CHANGES_REQUIRED, stop and escalate to the user.
6. **Verify.** Run the test, typecheck and lint commands yourself, check each acceptance criterion, and update `plan.md`.
7. **Report.** Tell the user what shipped, the review verdicts, rejected or deferred findings, required env vars or migrations, and residual risks.

Run one task at a time per repository, because the developer and reviewer share the working tree.

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
| `scripts/delegate-dev.sh` | Brief → DeepSeek in a per-task OpenCode session; records the task baseline; prints the DEV REPORT |
| `scripts/delegate-review.sh` | Task diff → cross-vendor reviewer, read-only, with a before/after working-tree guard |
| `scripts/detect-host.sh` | Prints `claude` or `codex` (override with `ORCH_HOST`) |
| `config/models.env` | Model ids, efforts, max fix rounds |
| `references/workflow.md` | Plan, brief, fix-brief and report templates; triage rules |
| `references/security.md` | Encryption, IDOR, MFA, hardening, reviewer checklist |
| `references/architecture.md` | Layout, layers, Postgres, Vite proxy, state split, Tailwind, Motion, Next.js variant |
| `templates/` | Copy-ready server and client code the developer adapts |
