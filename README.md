# fullstack-orchestrator

A shared skill for **Claude Code** and **Codex**. It turns the host into a plan-and-delegate orchestrator for full-stack apps:

| Host | Orchestrator | Developer | Reviewer (read-only) |
|---|---|---|---|
| Claude Code | Opus 5.5 · high | DeepSeek v4.1 Flash · max (OpenCode) | GPT 6.1 Sol · medium (`codex exec -s read-only`) |
| Codex | GPT 6.1 Sol · high | DeepSeek v4.1 Flash · max (OpenCode) | Opus 5.5 · medium (`claude -p`, edit tools denied) |

Default stack and security rules: React/Vite (or Next) · Express 5 · PostgreSQL · Vite proxy · Zustand + TanStack Query · Clean Architecture · MFA (email OTP + TOTP) · Tailwind v4 · Motion. The rules are AES-256-GCM field encryption and IDOR protection (owner-scoped data access) by default.

## Install

From GitHub (private repo; needs access):
```bash
npm install -g github:apelayo0608/fullstack-orchestrator
```
```bash
fullstack-orchestrator install
```
To update, re-run the first command. The skill links keep pointing at the updated files.

From a local clone of this folder:

```bash
npm run setup
```
That links the skill into `~/.claude/skills` and `~/.codex/skills`. Other commands:

| Command | What it does |
|---|---|
| `npm run setup` | Install or re-link; safe to re-run |
| `npm run setup:copy` | Copy instead of symlink (re-run after every update) |
| `npm run doctor` | Check CLIs, links and the DeepSeek model |
| `npm run uninstall-skill` | Remove the skill from both hosts |

Optional global command, usable from anywhere:
```bash
npm install -g ~/Documents/AI-Skills/fullstack-orchestrator
```
```bash
fullstack-orchestrator install
```
npm blocks install scripts on global installs, so run `fullstack-orchestrator install` once yourself. After that you can use `fullstack-orchestrator doctor` and `fullstack-orchestrator uninstall`. Run `uninstall` before `npm uninstall -g fullstack-orchestrator`, because npm doesn't run uninstall hooks.

Requirements: `opencode` (logged in to the `opencode-go` provider), `codex`, `claude`, `git`, `perl`, and `shasum` on PATH.

## Launch

```bash
claude --model claude-opus-5-5 --effort high
```
```bash
codex -m gpt-6.1-sol -c model_reasoning_effort="high"
```
Then ask for the work, or invoke it explicitly: `/fullstack-orchestrator …` in Claude Code, `$fullstack-orchestrator …` in Codex.

### Codex sandbox
Codex's default sandbox blocks network access and writes outside the workspace. The delegate scripts need both: they call OpenCode and Claude, which write to `~/.local/share/opencode` and `~/.claude`. Codex will ask to run them with escalated permissions. To stop being asked every time, you can add allow rules to `~/.codex/rules/default.rules` yourself:

```
prefix_rule(pattern=["/Users/adrian/.codex/skills/fullstack-orchestrator/scripts/delegate-dev.sh"], decision="allow")
prefix_rule(pattern=["/Users/adrian/.codex/skills/fullstack-orchestrator/scripts/delegate-review.sh"], decision="allow")
```

## Swap models

Edit `config/models.env`, or export a variable for one session, e.g. `ORCH_DEV_MODEL='opencode-go/deepseek-v4-pro' …`. Check DeepSeek variants with `opencode run -m 'opencode-go/deepseek-v4.1-flash#<variant>' "hi"`; unknown variants are rejected.

## What happens in a project

```
<repo>/.orchestrator/        (git-excluded automatically)
  plan.md  tasks/  baselines/  sessions/  reviews/  logs/
```
- The orchestrator writes `plan.md` and the briefs.
- `delegate-dev.sh` runs DeepSeek in a stable OpenCode session per task (`ses_orch_<repohash>_<task>`), so fix rounds keep context.
- `delegate-review.sh` diffs the task against its baseline, runs the reviewer, and fails with exit 3 if the reviewer changed any non-ignored file.

## Layout

```
SKILL.md               orchestrator instructions (both hosts)
agents/openai.yaml     Codex UI metadata
config/models.env      model routing
scripts/               detect-host.sh, delegate-dev.sh, delegate-review.sh, lib.sh
references/            workflow.md, security.md, architecture.md
templates/server/      crypto (AES-GCM, key ring, blind index, TOTP, OTP), owner-scoped repo + use cases,
                       auth/MFA services, middleware, routes, app, SQL migration, IDOR test suite
templates/client/      vite.config.ts, api client, query client, Zustand UI store, auth hooks, Motion, Tailwind CSS
```
