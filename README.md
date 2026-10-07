# fullstack-orchestrator

A shared skill for **Claude Code** and **Codex**. It turns the host into a plan-and-delegate orchestrator for full-stack apps:

| Host | Orchestrator | Developer | Reviewer (read-only) |
|---|---|---|---|
| Claude Code | Opus 5.5 · medium | DeepSeek v4.1 Flash · max (OpenCode) | GPT 6.1 Sol · medium (`codex exec -s read-only`) |
| Codex | GPT 6.1 Sol · medium | DeepSeek v4.1 Flash · max (OpenCode) | Opus 5.5 · medium (`claude -p`, edit tools denied) |

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

**Cursor and Qoder** read the same `SKILL.md` format from `~/.cursor/skills` and `~/.qoder/skills`. The installer links into those too when `~/.cursor` or `~/.qoder` exists. To limit which tools get it, use `fullstack-orchestrator install --only=cursor,qoder` or `npm run setup -- --only=...`. In those tools the skill picks the reviewer from the orchestrator's model: Claude → GPT reviews, GPT → Opus reviews.

Requirements: `opencode` (logged in to the `opencode-go` provider), `codex`, `claude`, `git`, `perl`, and `shasum` on PATH.

## Launch

```bash
claude --model claude-opus-5-5 --effort medium
```
```bash
codex -m gpt-6.1-sol -c model_reasoning_effort="medium"
```
Then ask for the work, or invoke it explicitly: `/fullstack-orchestrator …` in Claude Code, `$fullstack-orchestrator …` in Codex.

### Codex sandbox
Codex's default sandbox blocks network access and writes outside the workspace. The delegate scripts need both: they call OpenCode and Claude, which write to `~/.local/share/opencode` and `~/.claude`. Codex will ask to run them with escalated permissions. To stop being asked every time, you can add allow rules to `~/.codex/rules/default.rules` yourself:

```
prefix_rule(pattern=["/Users/adrian/.codex/skills/fullstack-orchestrator/scripts/delegate-dev.sh"], decision="allow")
prefix_rule(pattern=["/Users/adrian/.codex/skills/fullstack-orchestrator/scripts/delegate-review.sh"], decision="allow")
```

## Swap models

```bash
fullstack-orchestrator models                 # show orchestrator, developer and reviewer models
fullstack-orchestrator models setup           # interactive; Enter keeps a value
fullstack-orchestrator models set dev        # pick provider, then model, then thinking level
fullstack-orchestrator models set dev opencode-go/deepseek-v4-pro#max
fullstack-orchestrator models set review-on-claude gpt-6.1-sol
fullstack-orchestrator models set review-on-claude-effort high
fullstack-orchestrator models reset [role]    # back to the defaults
```
Roles: `dev`, `orch-claude`, `orch-codex`, `review-on-claude`, `review-on-codex` (add `-effort` for effort, except `dev`, whose effort is the `#variant`). Choices are saved to `~/.config/fullstack-orchestrator/models.env`, so reinstalling does not lose them. `set dev` warns when OpenCode does not list the model. The orchestrator is your host session: launch it with the model `models` prints. To override once, export a variable, e.g. `ORCH_DEV_MODEL=... claude`. Defaults live in `config/models.env`; change them there only for the repo itself.

## What happens in a project

```
<repo>/.orchestrator/        (git-excluded automatically)
  plan.md  tasks/  baselines/  sessions/  reviews/  logs/
```
- The orchestrator writes `plan.md` and the briefs.
- `delegate-dev.sh` runs DeepSeek in a stable OpenCode session per task (`ses_orch_<repohash>_<task>`), so fix rounds keep context.
- After each developer run, `check.sh` runs static security rules on the added lines plus the plan's test command, and failures go straight back to DeepSeek (up to `ORCH_MAX_CHECK_FIXES`).
- `delegate-review.sh` refuses to review work that fails the checks, scales the review to the task's risk (`high` / `low` / `none` in `plan.md`), reviews the whole task diff in round 1 and only the changes since the last round after that, and fails with exit 3 if the reviewer changed any non-ignored file.
- `task-worktree.sh` gives independent tasks their own git worktrees so they can be developed and reviewed in parallel, then lands each one back into the main working tree.
- `scaffold-resource.sh` (run by the developer) generates a full owner-scoped CRUD slice from the notes templates.

## Speed settings

All in `config/models.env` (or exported per session):

| Variable | Default | Effect |
|---|---|---|
| `ORCH_MAX_CHECK_FIXES` | 2 | Automatic check-failure round trips to DeepSeek before the orchestrator steps in |
| `ORCH_MAX_FIX_ROUNDS` | 2 | Review fix rounds before escalating to you |
| `ORCH_REVIEW_EFFORT_LOW_ON_*` | low | Reviewer effort for `risk: low` tasks |
| `ORCH_CHECK_CMD` | (plan.md) | Test command for the checks |
| `ORCH_WORKTREE_ROOT` / `ORCH_WORKTREE_SETUP` | sibling folder / lockfile install | Where task worktrees go and how they get dependencies |

## Layout

```
SKILL.md               orchestrator instructions (both hosts)
agents/openai.yaml     Codex UI metadata
config/models.env      model routing
scripts/               detect-host.sh, delegate-dev.sh, delegate-review.sh, check.sh,
                       task-worktree.sh, scaffold-resource.sh, lib.sh
references/            workflow.md, security.md, architecture.md
templates/server/      crypto (AES-GCM, key ring, blind index, TOTP, OTP), owner-scoped repo + use cases,
                       auth/MFA services, middleware, routes, app, SQL migration, IDOR test suite
templates/client/      vite.config.ts, api client, query client, Zustand UI store, auth hooks, notes CRUD hooks,
                       Motion, Tailwind CSS
```
