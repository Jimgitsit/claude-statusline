# claude-statusline

A custom statusline script for [Claude Code](https://claude.com/claude-code).

## What it shows

```
Opus 4.8:high | c:12K/200K s:35%◕2h40m w:18%-d3 | main
~/git/claude-statusline
```

- **Model** — display name from Claude Code, with effort level appended (e.g. `:high`). If a remote-control bridge is active, the remote name is shown in orange before the model name.
- **Context** (`c:`) — current input tokens vs. the full context window, both in compact form (e.g. `c:12K/200K`, `c:1.2M/1M`). Values come straight from Claude Code's `context_window` fields (`total_input_tokens` / `context_window_size`, defaulting to 200k).
- **Rate limits** (`s:` / `w:`) — 5-hour session and 7-day weekly usage percentages. The session value always carries a time-to-reset indicator: a pie glyph whose fill is the fraction of the 5-hour window still remaining (`● ◕ ◑ ◔ ○`, full → empty as reset nears), followed by the exact countdown (e.g. `s:35%◕2h40m`). Reading the pie against the percentage shows whether you're burning fast — high `%` with a still-full pie means you're spending quota early in the window. The weekly value carries a `-d<N>` suffix for which day (1–7) of the current 7-day window you're on (e.g. `w:18%-d3`). When either usage crosses 90%, its percentage turns yellow.
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
