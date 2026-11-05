---
name: orchestrator-models
description: Show or change which provider, model and thinking level the fullstack-orchestrator uses for its developer and its reviewer. The orchestrator itself is always the model this session is running. Use when the user invokes orchestrator-models, or asks to change, switch or pick the developer or reviewer model of the fullstack orchestrator.
---

# Orchestrator models

The fullstack-orchestrator has three roles:
- **Orchestrator:** this session, on whatever model the harness has selected right now. It is not configured here. To change it, the user switches the model in the harness (`/model` in Claude Code, the model picker in Codex, Cursor or Qoder).
- **Developer:** writes all code. Provider `opencode`, `claude` or `codex`.
- **Reviewer:** read-only. Provider `auto` (the other vendor of the orchestrator's model: GPT reviews under a Claude model, Opus under a GPT model), or a forced `opencode`, `claude` or `codex`.

## Script

Use `models.sh` from the fullstack-orchestrator skill, which is installed next to this one: take this skill's directory, go to its parent (the skills folder), then `fullstack-orchestrator/scripts/models.sh`. For example, `~/.claude/skills/orchestrator-models` → `~/.claude/skills/fullstack-orchestrator/scripts/models.sh`. Run it with `bash <path> ...`. Never run `set dev` or `set review` without a value: that form needs an interactive terminal.

## Steps

1. Run `bash <models.sh> show` and show the user the developer and reviewer rows. Name the orchestrator as the model you are running now.
2. Ask which role to change: developer, reviewer or both. If the user already said, skip the question. Use the host's question tool if it has one (e.g. AskUserQuestion); otherwise ask in chat. In the questions below, make the current value the first option.
3. For each role, ask:
   - **Provider:** `opencode`, `claude`, `codex`. The reviewer also gets `auto`; with `auto`, skip the model and thinking questions.
   - **Model:**
     - `opencode`: run `opencode models` (ids look like `provider/model`) and offer the likeliest ones. The user can type any listed id.
     - `claude`: `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-4-5-20251001`.
     - `codex`: `gpt-6.1-sol`, `gpt-6.1-luna`.
     - The user may type any other id.
   - **Thinking:** `low`, `medium`, `high`, `xhigh`, `max`. For the developer, also ask about `risk: high` tasks (default `max`) when the user wants control over it.
4. Save with these commands. Set the provider first, because the model check depends on it:
   - Developer:
     - `set dev-runner <provider>`
     - `set dev <model>`
     - `set dev-effort <level>`
     - optionally `set dev-effort-high-risk <level>`
   - Reviewer, forced provider:
     - `set review-runner <provider>`
     - `set review <model>`
     - `set review-effort <level>`
   - Reviewer `auto`:
     - `set review-runner auto`
     - `reset review`
     - `reset review-effort`
5. Pass any warning from the script on to the user, for example a model that `opencode models` doesn't list.
6. Warn the user if the reviewer ends up on the same vendor as the orchestrator (for example a Claude reviewer under a Claude session), because that loses the independent cross-vendor review. If they confirm, keep it.
7. Run `show` again and report the final developer and reviewer. Choices are saved in `~/.config/fullstack-orchestrator/models.env` and apply from the next `delegate-dev.sh` or `delegate-review.sh` run. Nothing needs a restart.
