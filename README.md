# claude-statusline

A custom statusline script for [Claude Code](https://claude.com/claude-code).

## What it shows

```
Opus 4.7:high | c:12.4k [########------------] 42% s:35% w:18% | main
~/git/claude-statusline
```

- **Model** — display name from Claude Code, with effort level appended (e.g. `:high`). If a remote-control bridge is active, the remote name is shown in orange before the model name.
- **Context bar** (`c:`) — current input tokens in human-readable form, a 20-char progress bar, and the percentage of the model's context window used. Reserves 64k for output; assumes 1M context for `*1m*` model IDs, 200k otherwise.
- **Rate limits** (`s:` / `w:`) — 5-hour session and 7-day weekly usage percentages. When either crosses 90%, it turns yellow and appends the reset countdown (`resets in 2h15m`).
- **Git branch** — walks up from `cwd` looking for a `.git` file first so linked worktrees resolve correctly; falls back to a normal `git` lookup. Skips nested repos like `courses/` that have `.git` as a directory.
- **cwd** — `$HOME` collapsed to `~`.

## Install

Easiest: paste this repo's URL into Claude Code and ask it to set this as your statusline — it'll clone the repo and wire up `~/.claude/settings.json` for you.

Manual: clone the repo, make the script executable, and point Claude Code at it in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Users/you/git/claude-statusline/statusline-command.sh"
  }
}
```

Requires `jq` and `python3` on `PATH`.

## Debugging

Every invocation writes the raw JSON input to `/tmp/statusline-last-input.json`, which is useful for inspecting the fields Claude Code sends.
