# Orchestration workflow

All orchestration files live in `<repo>/.orchestrator/`. The scripts add it to `.git/info/exclude` automatically, so it is never committed.

```
.orchestrator/
  plan.md                 the plan and task board (you write it)
  tasks/T01.md            task briefs and fix briefs (you write them)
  baselines/T01.tree      working-tree snapshot taken before T01 started (script)
  sessions/T01.id         OpenCode session used by the developer for T01 (script)
  reviews/T01-r1.diff     task diff sent to the reviewer (script)
  reviews/T01-r1.md       reviewer findings (script)
  logs/                   full prompts and transcripts (script)
```

## 1. Plan (`.orchestrator/plan.md`)

Explore the repo first: existing structure, package scripts, conventions, what is already built. Then write:

```markdown
# Plan: <feature or project>
Goal: <one paragraph: what the user gets>
Stack decisions: <defaults from architecture.md, plus any deviation the user asked for>
Test commands: <e.g. npm run typecheck && npm run lint && npm test>

## Tasks
| id  | title                              | depends | status  | rounds | verdict |
|-----|------------------------------------|---------|---------|--------|---------|
| T01 | Scaffold api + web, Vite proxy      | -       | todo    | 0      |         |
| T02 | Users, sessions, login + email OTP | T01     | todo    | 0      |         |

## Decisions and rejected findings
- T02 r1 #3 rejected: <one-line reason>

## Deferred (MINOR findings, follow-ups)
- ...
```

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
Runs can take many minutes. In Claude Code, run it with `run_in_background` and wait for the completion notice. In Codex, request escalated permissions and use a long timeout. When it finishes, read the printed `DEV REPORT` and `git status`.

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
The reviewer gets the full task diff (baseline → now), the brief and the security checklist. It returns `## REVIEW VERDICT: APPROVE | CHANGES_REQUIRED` with numbered findings.

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
The developer continues in the same OpenCode session, so it remembers the task. Each review covers the whole task diff again.

**Limit:** after `ORCH_MAX_FIX_ROUNDS` (default 3) rounds that still end in CHANGES_REQUIRED, stop. Report the open findings and your assessment to the user and ask how to proceed.

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

## Rules of thumb
- Run tasks one at a time per repository. The developer and reviewer share the working tree.
- Keep briefs short and concrete. Long, vague briefs make the developer improvise.
- Repeat the relevant security requirements in every brief that touches data. Do not assume the developer remembers them from earlier tasks.
- If the user changes direction mid-task, write a new brief; use `--new-session` only when the earlier context would mislead the developer.
