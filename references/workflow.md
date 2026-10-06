# Orchestration workflow

All orchestration files live in `<repo>/.orchestrator/`. The scripts add it to `.git/info/exclude` automatically, so it is never committed.

```
.orchestrator/
  plan.md                 the plan and task board (you write it)
  tasks/T01.md            task briefs and fix briefs (you write them)
  baselines/T01.tree      working-tree snapshot taken before T01 started (script)
  sessions/T01.id         OpenCode session used by the developer for T01 (script)
  checks/T01-c1.md        automated check reports; T01.last = latest result (script)
  reviews/T01-r1.diff     task diff at review round 1 (script)
  reviews/T01-r2.delta.diff  changes since the previous round, reviewed in round 2+ (script)
  reviews/T01-r1.tree     working-tree snapshot the round reviewed (script)
  reviews/T01-r1.md       reviewer findings (script)
  worktrees/T03.path      task worktree location, .landed / .patch after landing (script)
  logs/                   full prompts and transcripts (script)
```

## 1. Plan (`.orchestrator/plan.md`)

Explore the repo first: existing structure, package scripts, conventions, what is already built. Then write:

```markdown
# Plan: <feature or project>
Goal: <one paragraph: what the user gets>
Stack decisions: <defaults from architecture.md, plus any deviation the user asked for>
Test commands: <e.g. npm run typecheck && npm run lint && npm test>
Parallel: <e.g. T03 and T04 in worktrees after T02, or "none">

## Tasks
| id  | title                              | depends | risk | status  | rounds | verdict |
|-----|------------------------------------|---------|------|---------|--------|---------|
| T01 | Scaffold api + web, Vite proxy      | -       | high | todo    | 0      |         |
| T02 | Users, sessions, login + email OTP | T01     | high | todo    | 0      |         |
| T03 | Invoices resource (scaffolded)     | T02     | high | todo    | 0      |         |
| T04 | Settings page layout and theming   | T02     | low  | todo    | 0      |         |

## Decisions and rejected findings
- T02 r1 #3 rejected: <one-line reason>

## Deferred (MINOR findings, follow-ups)
- ...
```

`Test commands:` is a single shell command line; `check.sh` runs it from the repo root (or the task's worktree) after every developer run and before every review. Set `ORCH_CHECK_CMD` to override it.

Risk (`high` | `low` | `none`) decides how much review a task gets; see SKILL.md §3. Keep `high` for anything near auth, MFA, crypto, sessions, migrations or user-owned data.

Task sizing: one vertical slice per task (migration → repository → use case → route → hook → UI → tests) that a reviewer can judge from one diff, typically under ~800 changed lines. Put scaffolding, auth/MFA and crypto infrastructure in early tasks, because later tasks depend on them.

Show the plan to the user before the first delegation when the scope is new or large.

## 2. Task brief (`.orchestrator/tasks/T01.md`)

DeepSeek sees only the brief plus the standing contract that `delegate-dev.sh` prepends. Make the brief self-contained.

```markdown
# T02: Users, sessions, login + email OTP

## Goal
<what exists when this is done, from the user's point of view>

## Context
- Read first: <existing files to follow or extend>
- Start from templates: templates/server/src/infrastructure/crypto/*, application/mfa/email-otp.service.ts, ...
- New CRUD resource: run `scaffold-resource.sh --name <singular>` first, then adapt (fields: <list>)
- Depends on: T01 (scaffold)

## Requirements
1. <concrete, testable behaviour>
2. ...

## Security requirements
- Encrypt: users.email_enc (AAD users/email_enc/id/id) + email_bidx blind index
- Ownership: <which resources, which repository methods>
- MFA/session: <relevant rules from security.md §3>

## Acceptance criteria
- [ ] <observable result, e.g. POST /api/auth/login returns { methods } and sets an mfa_pending cookie>
- [ ] Cross-user tests for <resources>
- [ ] `<test commands>` pass

## Out of scope
- <things the developer must not touch or build yet>
```

## 3. Delegate

```bash
<skill>/scripts/delegate-dev.sh --task T02
```
Runs can take many minutes. In Claude Code, run it with `run_in_background` and wait for the completion notice. In Codex, request escalated permissions and use a long timeout. When it finishes, read the printed `DEV REPORT`, `git status` and the `CHECKS:` line.

**Automated checks.** After the developer finishes, the script runs `check.sh`: static rules on the lines the task added (`z.object` in server code, actor ids from `req.body/query/params`, interpolated SQL, `WHERE id = $n` without `owner_id` in repositories, `/api` routers without `requireMfa`, `.only`/`.skip`, `@ts-ignore`/`any`, `dangerouslySetInnerHTML`, secret-looking `VITE_*` vars, new routes without an IDOR test), then the `Test commands:` line. Failures go straight back to the developer in the same session, up to `ORCH_MAX_CHECK_FIXES` (default 2) times. Exit 4 / `CHECKS: FAIL` means they still fail: write a fix brief from the check report. A line the developer marks `orch-allow: <reason>` is skipped by the rules; the reviewer is told to judge those exemptions.

**Live view.** Let the user watch DeepSeek work. The OpenCode TUI attaches to the same background service as the run:
- Claude desktop app (terminal-panel tools available): right after starting the background run, open a terminal tab in the panel and run the `watch` command that `delegate-dev.sh --task T02 --dry-run` prints (`cd <repo> && opencode -s <session>`). Reuse that tab for fix rounds of the same task.
- Anywhere else on macOS: add `--watch`; the script opens a Terminal.app window with the TUI.
- Otherwise: tell the user the `Watch live:` command the script prints on stderr.

Tell the user that typing in the live view sends messages into the developer's session. You do not need the view yourself; you still read the `DEV REPORT`.

- `Status: blocked` or open questions → answer them in a fix brief (or ask the user if it is their call), then re-delegate.
- Never patch the code yourself, even for one line.

## 4. Review

```bash
<skill>/scripts/delegate-review.sh --task T02 --host claude   # or --host codex
```
The script first makes sure `check.sh` passes on the current tree (exit 4 otherwise; `--skip-checks` only when the user asks). The risk comes from `plan.md` (override with `--risk`):
- `high`: full security checklist, normal effort.
- `low`: correctness, architecture, frontend and tests items only, at low effort.
- `none`: no model review; an APPROVE is recorded once the checks pass.

Round 1 gets the full task diff (baseline → now), the brief and the checklist. It returns `## REVIEW VERDICT: APPROVE | CHANGES_REQUIRED` with numbered findings.

Exit code 3 means the reviewer modified files. The review is discarded and nothing is reverted. Stop and show the user the listed paths.

## 5. Triage (your judgement, not a rubber stamp)

For each finding:
- **BLOCKER / MAJOR and valid** → goes into the fix brief.
- **Invalid** (misread code, out of scope, contradicts the user's decision) → reject it with a one-line reason under "Decisions and rejected findings".
- **MINOR** → include it if it is cheap and in the touched code; otherwise list it under "Deferred".

Fix brief (`.orchestrator/tasks/T02-fix1.md`):
```markdown
# T02 fix round 1
Review: .orchestrator/reviews/T02-r1.md
## Fix
1. Finding #2 (BLOCKER idor, src/...:42): <restate the problem and the expected behaviour>
2. ...
## Do not change
- <anything the reviewer flagged that you rejected, so the developer does not "fix" it>
## Acceptance
- [ ] Each fixed item has a test that failed before and passes now
- [ ] `<test commands>` pass
```
Then:
```bash
<skill>/scripts/delegate-dev.sh --task T02 --brief .orchestrator/tasks/T02-fix1.md
<skill>/scripts/delegate-review.sh --task T02 --host <host>
```
The developer continues in the same OpenCode session, so it remembers the task. Round 2 and later review only the changes since the previous round (`T02-r2.delta.diff`): the reviewer marks each earlier BLOCKER/MAJOR finding FIXED, NOT_FIXED or REJECTED and looks for regressions in the new changes. Pass `--full` to re-review the whole task diff when the fixes were large or restructured the code.

**Limit:** after `ORCH_MAX_FIX_ROUNDS` (default 2; one for `low` risk) rounds that still end in CHANGES_REQUIRED, stop. Report the open findings and your assessment to the user and ask how to proceed.

## 6. Verify and close

- Run the test, typecheck and lint commands yourself. Reading output and running tests is allowed; editing is not.
- Check each acceptance criterion against the code. Start the app if the task is UI-visible and the environment allows it.
- Update `plan.md`: status `done`, rounds, final verdict.
- Do not commit unless the user asked. If they want per-task commits, ask the developer to commit in the brief, or ask the user.

## 7. Report to the user

Per task or at the end:
- What was built.
- Review rounds and final verdict.
- Rejected or deferred findings.
- Anything the user must do (env vars, keys, migrations to run).
- Residual risks.

## 8. Parallel tasks (worktrees)

Independent tasks (their `depends` are done, they touch different files) can run at the same time, each in its own git worktree:

```bash
<skill>/scripts/task-worktree.sh create --task T03     # before T03's first delegate-dev.sh
<skill>/scripts/task-worktree.sh create --task T04
<skill>/scripts/delegate-dev.sh --task T03             # background
<skill>/scripts/delegate-dev.sh --task T04             # background
<skill>/scripts/delegate-review.sh --task T03 --host <host>   # while T04 is still developing
<skill>/scripts/task-worktree.sh land --task T03       # after APPROVE and your verification
<skill>/scripts/task-worktree.sh remove --task T03
```
- `create` starts the worktree from the main tree's current state, uncommitted changes included, copies ignored `.env*` files and installs dependencies from the lockfile (`ORCH_WORKTREE_SETUP` overrides; `--no-install` skips). Worktrees live in `<repo parent>/.<repo name>-orch/`.
- `delegate-dev.sh`, `check.sh` and `delegate-review.sh` find the worktree by task id. Plans, briefs and reviews stay in the main tree's `.orchestrator/`.
- `land` applies the task's diff to the main working tree only (nothing staged or committed). Exit 5 means it conflicts: the patch is saved at `.orchestrator/worktrees/Txx.patch`; write a brief for the developer to integrate it in the main tree, as a new task without a worktree.
- While any task runs in a worktree, run every other active task in a worktree too. Landing changes the main tree and would otherwise leak into a task developing there.
- Tasks whose tests share one database must not test at the same time. Give each worktree its own database in its `.env`, or keep those tasks serial.
- Verify in the worktree before landing (`check.sh --task Txx`), and run the full test command in the main tree after landing.

## Rules of thumb
- Without worktrees, run tasks one at a time per repository. The developer and reviewer share the working tree.
- Keep briefs short and concrete. Long, vague briefs make the developer improvise.
- Repeat the relevant security requirements in every brief that touches data. Do not assume the developer remembers them from earlier tasks.
- If the user changes direction mid-task, write a new brief; use `--new-session` only when the earlier context would mislead the developer.
