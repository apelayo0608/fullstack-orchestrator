# fullstack-orchestrator

A shared skill for **Claude Code**, **Codex** and **Antigravity**. It turns the host into a plan-and-delegate orchestrator for full-stack apps:

| Host | Orchestrator | Developer | Reviewer (read-only) |
|---|---|---|---|
| Claude Code | Opus 5.5 · medium | configurable (default OpenCode) · high, max for risk-high tasks | GPT 6.1 Sol · medium (`codex exec -s read-only`) |
| Codex | GPT 6.1 Sol · medium | same | Opus 5.5 · medium (`claude -p`, edit tools denied) |
| Antigravity (`agy` or the app) | Gemini 4 Argon · medium | same | Opus 5.5 · medium (`claude -p`, edit tools denied) |

Every role's **provider, model and thinking level** can be changed (see [Swap models](#swap-models)). Developer and reviewer providers can be `opencode`, `claude`, `codex` or `antigravity` (Google's Antigravity CLI, for Gemini 4).

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
| `npm run doctor` | Check CLIs, links and the developer model |
| `npm run uninstall-skill` | Remove the skill from both hosts |

Optional global command, usable from anywhere:
```bash
npm install -g ~/Documents/AI-Skills/fullstack-orchestrator
```
```bash
fullstack-orchestrator install
```
npm blocks install scripts on global installs, so run `fullstack-orchestrator install` once yourself. After that you can use `fullstack-orchestrator doctor` and `fullstack-orchestrator uninstall`. Run `uninstall` before `npm uninstall -g fullstack-orchestrator`, because npm doesn't run uninstall hooks.

**Antigravity** (the `agy` CLI and the app) loads global skills from `~/.gemini/config/skills`; the installer links there when `~/.gemini/config` exists or `agy` is on PATH. Check with `agy -p "/skills"`. `detect-host.sh` recognises Antigravity by its `ANTIGRAVITY_*` variables.

**Cursor and Qoder** read the same `SKILL.md` format from `~/.cursor/skills` and `~/.qoder/skills`. The installer links into those too when `~/.cursor` or `~/.qoder` exists. To limit which tools get it, use `fullstack-orchestrator install --only=cursor,qoder,antigravity` or `npm run setup -- --only=...`. In those tools the skill picks the reviewer from the orchestrator's model: Claude → GPT reviews, GPT → Opus reviews.

Requirements: `opencode` (logged in to the `opencode-go` provider), `codex`, `claude`, `git`, `perl`, and `shasum` on PATH.

## Launch

```bash
claude --model claude-opus-5-5 --effort medium
```
```bash
codex -m gpt-6.1-sol -c model_reasoning_effort="medium"
```
```bash
agy --model gemini-4-argon --effort medium
```
Then ask for the work, or invoke it explicitly: `/fullstack-orchestrator …` in Claude Code and Antigravity, `$fullstack-orchestrator …` in Codex.

### Codex sandbox
Codex's default sandbox blocks network access and writes outside the workspace. The delegate scripts need both: they call OpenCode and Claude, which write to `~/.local/share/opencode` and `~/.claude`. Codex will ask to run them with escalated permissions. To stop being asked every time, you can add allow rules to `~/.codex/rules/default.rules` yourself:

```
prefix_rule(pattern=["/Users/adrian/.codex/skills/fullstack-orchestrator/scripts/delegate-dev.sh"], decision="allow")
prefix_rule(pattern=["/Users/adrian/.codex/skills/fullstack-orchestrator/scripts/delegate-review.sh"], decision="allow")
```

## Swap models

```bash
fullstack-orchestrator models                 # show provider, model and thinking of every role
fullstack-orchestrator models setup           # interactive for every role; Enter keeps a value
fullstack-orchestrator models set dev         # pick provider, then model, then thinking level
fullstack-orchestrator models set review      # same for the reviewer ("auto" = the other vendor of the host)
fullstack-orchestrator models set dev-runner claude       # provider: opencode | claude | codex | antigravity
fullstack-orchestrator models set dev opencode-go/deepseek-v4-pro
fullstack-orchestrator models set dev-effort medium       # risk low/none tasks
fullstack-orchestrator models set dev-effort-high-risk max
fullstack-orchestrator models set review-runner opencode  # force a provider (needs `review <model>`)
fullstack-orchestrator models set review-effort high
fullstack-orchestrator models set review-effort-delta low # later review rounds
fullstack-orchestrator models set orch-claude-effort high
fullstack-orchestrator models reset [role]    # back to the defaults
```

| Role | Provider | Model | Thinking |
|---|---|---|---|
| Developer | `dev-runner` (opencode, claude, codex, antigravity) | `dev` | `dev-effort`, `dev-effort-high-risk` (a `#variant` on the model id pins it for all tasks) |
| Reviewer | `review-runner` (auto, opencode, claude, codex, antigravity) | `review` (empty = per-host default) | `review-effort`, `review-effort-low`, `review-effort-delta` |
| Orchestrator | the host: Claude Code, Codex or Antigravity | `orch-claude`, `orch-codex`, `orch-antigravity` | `orch-claude-effort`, `orch-codex-effort`, `orch-antigravity-effort` |

Per-host reviewer defaults used while the runner is `auto` and `review` is empty: `review-on-claude`, `review-on-codex`, `review-on-antigravity` (and their `-effort`, `-effort-low`; `review-on-antigravity-runner` picks its provider, default `claude`). Choices are saved to `~/.config/fullstack-orchestrator/models.env`, so reinstalling does not lose them. `set dev` warns when OpenCode does not list the model. The `codex` developer has no resumable session, so it gets the full contract on every run; `claude`, `opencode` and `antigravity` resume and get a short prompt on fix rounds. The orchestrator is your host session: launch it with the model `models` prints. To override once, export a variable, e.g. `ORCH_DEV_MODEL=... claude`. Defaults live in `config/models.env`; change them there only for the repo itself.

### Google (Gemini) as developer or reviewer
Google's models run through the Antigravity CLI (`agy`), which replaced the Gemini CLI for unpaid and Google One accounts and is the only way to use Gemini 4 Argon. Install Antigravity, sign in once, and check `agy models`. Then:
```bash
fullstack-orchestrator models set dev-runner antigravity
```
```bash
fullstack-orchestrator models set dev gemini-4-argon
```
```bash
fullstack-orchestrator models set review-runner antigravity
```
```bash
fullstack-orchestrator models set review gemini-4-argon
```
Or run `models set dev` / `models set review` to pick from what `agy models` lists. Thinking levels map to `agy --effort`; a model id that already ends in a level (`gemini-4-argon-high`) pins it. The developer runs `agy -p --dangerously-skip-permissions` and resumes its conversation on fix rounds. The reviewer runs in Default agent mode (not Auto) with `request-review`: it can read and search the workspace and run only `git diff/log/show/status/ls-files/blame`, and every edit is denied; the working-tree guard still checks it changed nothing. If headless `agy` hits a denied action it ends the turn with no answer; the review file then says which action was denied.

## What happens in a project

```
<repo>/.orchestrator/        (git-excluded automatically)
  plan.md  tasks/  baselines/  sessions/  reviews/  logs/
```
- The orchestrator writes `plan.md` and the briefs.
- `delegate-dev.sh` runs the developer in a stable session per task (`ses_orch_<repohash>_<task>` for OpenCode), so fix rounds keep context and get a short prompt.
- While it runs, a **live change feed** shows the files the developer is creating, editing and deleting, with line counts and optionally the diff hunks — for every runner, not just OpenCode. `--watch` opens it in a second terminal window; `watch-changes.sh` runs it standalone, and every run also writes `.orchestrator/logs/<task>-changes.jsonl`.
- After each developer run, `check.sh` runs static security rules on the added lines plus the plan's test command, static findings are reported before the tests run, an unchanged tree reuses a passing result, and failures go straight back to the developer (up to `ORCH_MAX_CHECK_FIXES`).
- `delegate-review.sh` refuses to review work that fails the checks, scales the review to the task's risk (`high` / `low` / `none` in `plan.md`), reviews the whole task diff in round 1 and only the changes since the last round after that, and fails with exit 3 if the reviewer changed any non-ignored file.
- `task-worktree.sh` gives independent tasks their own git worktrees so they can be developed and reviewed in parallel, then lands each one back into the main working tree.
- `scaffold-resource.sh` (run by the developer) generates a full owner-scoped CRUD slice from the notes templates.

## Speed settings

All in `config/models.env` (or exported per session):

| Variable | Default | Effect |
|---|---|---|
| `ORCH_DEV_EFFORT` / `ORCH_DEV_EFFORT_HIGH_RISK` | high / max | Developer thinking level; max only where the risk is high |
| `ORCH_MAX_CHECK_FIXES` | 2 | Automatic check-failure round trips to the developer before the orchestrator steps in |
| `ORCH_MAX_FIX_ROUNDS` | 1 | Review fix rounds before escalating to you |
| `ORCH_HANG_CHECK_SECS` / `ORCH_HANG_RETRIES` | 300 / 2 | Every 5 min, a developer or reviewer run with no new output and no file changes is killed and restarted, up to 2 times (then exit 124); 0 disables |
| `ORCH_REVIEW_EFFORT_DELTA` | low | Reviewer effort for rounds after the first (fix verification) |
| `ORCH_REVIEW_EFFORT_LOW` | per-host (low) | Reviewer effort for `risk: low` tasks |
| `ORCH_SKIP_REVIEW_LINES` | 100 | `risk: low` tasks with fewer changed lines skip model review (0 disables) |
| `ORCH_CHECK_CMD` | (plan.md) | Test command for the checks |
| `ORCH_WATCH_INTERVAL` | 1 | Seconds between polls of the live change feed |
| `ORCH_LIVE_CHANGES` | (auto) | `1` forces the change feed on without a TTY, `0` forces it off |
| `ORCH_WORKTREE_ROOT` / `ORCH_WORKTREE_SETUP` | sibling folder / lockfile install | Where task worktrees go and how they get dependencies |

## Layout

```
SKILL.md               orchestrator instructions (both hosts)
agents/openai.yaml     Codex UI metadata
config/models.env      model routing
scripts/               detect-host.sh, delegate-dev.sh, delegate-review.sh, check.sh,
                       task-worktree.sh, scaffold-resource.sh, watch-changes.sh, lib.sh
tests/                 run.sh, fake-dev.sh (no model CLI needed)
references/            workflow.md, security.md, architecture.md
templates/server/      crypto (AES-GCM, key ring, blind index, TOTP, OTP), owner-scoped repo + use cases,
                       auth/MFA services, middleware, routes, app, SQL migration, IDOR test suite
templates/client/      vite.config.ts, api client, query client, Zustand UI store, auth hooks, notes CRUD hooks,
                       Motion, Tailwind CSS
```
