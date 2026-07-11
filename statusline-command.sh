#!/bin/sh
input=$(cat)
echo "$input" > /tmp/statusline-last-input.json

# ANSI color codes
CYAN='\033[36m'
YELLOW='\033[33m'
MAGENTA='\033[35m'
ORANGE='\033[38;5;208m'
DIM='\033[2m'
RESET='\033[0m'

model=$(echo "$input" | jq -r '.model.display_name')
transcript_path=$(echo "$input" | jq -r '.transcript_path // ""')
remote_name=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  remote_name=$(tail -300 "$transcript_path" | python3 -c "
import sys, json, re
bridge_active = False
name = ''
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        if d.get('type') == 'system':
            s = d.get('subtype', '')
            c = d.get('content', '')
            if s == 'bridge_status':
                bridge_active = 'is active' in c
            elif s == 'local_command':
                if '/remote-control' in c:
                    m = re.search(r'<command-args>([^<]+)</command-args>', c)
                    if m:
                        name = m.group(1).strip()
                if 'disconnected' in c.lower():
                    bridge_active = False
                elif 'connecting' in c.lower():
                    bridge_active = True
    except:
        pass
if bridge_active and name:
    print(name)
" 2>/dev/null)
fi
effort=$(echo "$input" | jq -r '.effort.level // empty')
if [ -n "$remote_name" ]; then
  model="${ORANGE}${remote_name}${RESET} ${CYAN}${model}${RESET}"
else
  model="${CYAN}${model}${RESET}"
fi
if [ -n "$effort" ]; then
  model="${model}${DIM}:${RESET}${effort}"
fi
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
# Context usage: current input tokens vs. full context window size (matches used_percentage)
ctx_used=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
ctx_total=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$ctx_used" = "null" ] && ctx_used=0
[ "$ctx_total" = "null" ] && ctx_total=200000
[ "$ctx_total" = "0" ] && ctx_total=200000
# Git branch: walk up from cwd looking for .git FILE first (linked worktrees have .git as a file;
# nested repos like courses/ have .git as a directory, so this skips them and finds the worktree).
# Falls back to normal git lookup if no .git file is found (main worktree or plain repo).
branch=""
_dir="$cwd"
while [ "$_dir" != "/" ]; do
  if [ -f "$_dir/.git" ]; then
    branch=$(git -C "$_dir" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
    break
  fi
  _dir=$(dirname "$_dir")
done
if [ -z "$branch" ]; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
fi

# Session cost: use native field if available, otherwise compute from tokens
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
if [ -z "$cost" ]; then
  total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
  total_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
  # claude-opus-4: $15/M input, $75/M output; claude-sonnet-4: $3/M input, $15/M output
  # Use opus rates as a safe upper bound
  cost=$(awk "BEGIN { printf \"%.4f\", $total_input * 0.000015 + $total_output * 0.000075 }")
else
  cost=$(printf "%.4f" "$cost")
fi

SEP="${DIM} | ${RESET}"

# Format a token count as a compact string: 30006 -> 30K, 1000000 -> 1M
fmt_tokens() {
  awk "BEGIN {
    t = $1
    if (t >= 1000000) {
      v = t / 1000000
      if (v == int(v)) printf \"%dM\", v; else printf \"%.1fM\", v
    } else if (t >= 1000) {
      printf \"%dK\", int(t / 1000 + 0.5)
    } else {
      printf \"%d\", t
    }
  }"
}

# Context usage display, e.g. c:124K/1M
ctx_bar="${DIM}c:${RESET}$(fmt_tokens "$ctx_used")${DIM}/${RESET}$(fmt_tokens "$ctx_total")"

# Short display of cwd (replace $HOME with ~)
home="$HOME"
short_cwd="${cwd#$home}"
if [ "$short_cwd" != "$cwd" ]; then
  short_cwd="~$short_cwd"
fi

# Rate limits (5-hour session and 7-day weekly)
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_resets_at=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
week_resets_at=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# Format seconds-until-reset as "Xh Ym" or "Ym" if < 1 hour
_fmt_reset() {
  _epoch="$1"
  if [ -z "$_epoch" ]; then return; fi
  _now=$(date +%s)
  _secs=$((_epoch - _now))
  if [ "$_secs" -le 0 ] 2>/dev/null; then
    echo "soon"
    return
  fi
  _hrs=$((_secs / 3600))
  _mins=$(((_secs % 3600) / 60))
  if [ "$_hrs" -gt 0 ]; then
    echo "${_hrs}h${_mins}m"
  else
    echo "${_mins}m"
  fi
}

# Pick a pie glyph (● ◕ ◑ ◔ ○) for the fraction of a time-window still remaining.
# $1 = reset epoch, $2 = window length in seconds. Full pie = whole window left,
# empty circle = reset imminent. Lets you eyeball "time left" against "quota used".
_time_pie() {
  _epoch="$1"
  _window="$2"
  if [ -z "$_epoch" ] || [ -z "$_window" ]; then
    return
  fi
  if [ "$_window" -le 0 ] 2>/dev/null; then
    return
  fi
  _now=$(date +%s)
  _rem=$((_epoch - _now))
  if [ "$_rem" -lt 0 ]; then
    _rem=0
  fi
  if [ "$_rem" -gt "$_window" ]; then
    _rem=$_window
  fi
  # Permille of the window still remaining, bucketed into five glyphs (centered buckets).
  _pm=$((_rem * 1000 / _window))
  if [ "$_pm" -ge 875 ]; then
    printf '●'
  elif [ "$_pm" -ge 625 ]; then
    printf '◕'
  elif [ "$_pm" -ge 375 ]; then
    printf '◑'
  elif [ "$_pm" -ge 125 ]; then
    printf '◔'
  else
    printf '○'
  fi
}

# Which day (1-7) of the current 7-day window we're on, derived from the reset epoch.
# The window is 7 days long, so window_start = resets_at - 7d; day = elapsed_days + 1,
# computed here as 8 - ceil(days_until_reset).
_week_day() {
  _epoch="$1"
  if [ -z "$_epoch" ]; then return; fi
  _now=$(date +%s)
  awk "BEGIN {
    rem = $_epoch - $_now
    if (rem < 0) rem = 0
    days_until = int(rem / 86400)
    if (rem / 86400 > days_until) days_until = days_until + 1
    day = 8 - days_until
    if (day < 1) day = 1
    if (day > 7) day = 7
    print day
  }"
}

rate_str=""
if [ -n "$five_pct" ]; then
  five_fmt=$(printf "%.0f" "$five_pct")
  five_int=$(printf "%.0f" "$five_pct")
  # Always show time-to-reset for the 5h session window: a pie glyph whose fill is
  # the fraction of the window still remaining, then the exact dim countdown.
  five_extra=""
  if [ -n "$five_resets_at" ]; then
    five_pie=$(_time_pie "$five_resets_at" 18000)
    five_reset=$(_fmt_reset "$five_resets_at")
    five_extra="${DIM}-${RESET}${five_pie}${DIM}${five_reset}${RESET}"
  fi
  if [ "$five_int" -ge 90 ] 2>/dev/null; then
    rate_str="${DIM}s:${RESET}${YELLOW}${five_fmt}%${RESET}${five_extra}"
  else
    rate_str="${DIM}s:${RESET}${five_fmt}%${five_extra}"
  fi
fi
if [ -n "$week_pct" ]; then
  week_fmt=$(printf "%.0f" "$week_pct")
  week_int=$(printf "%.0f" "$week_pct")
  week_day_suffix=""
  if [ -n "$week_resets_at" ]; then
    week_day=$(_week_day "$week_resets_at")
    if [ -n "$week_day" ]; then
      week_day_suffix="${DIM}-d${RESET}${week_day}"
    fi
  fi
  if [ "$week_int" -ge 90 ] 2>/dev/null && [ -n "$week_resets_at" ]; then
    week_reset=$(_fmt_reset "$week_resets_at")
    week_part="${YELLOW}${DIM}w:${RESET}${YELLOW}${week_fmt}%${RESET}${week_day_suffix}${DIM} resets in ${week_reset}${RESET}"
  else
    week_part="${DIM}w:${RESET}${week_fmt}%${week_day_suffix}"
  fi
  if [ -n "$rate_str" ]; then
    rate_str="${rate_str} ${week_part}"
  else
    rate_str="${week_part}"
  fi
fi

# Build output
ctx_with_rates="${ctx_bar}"
if [ -n "$rate_str" ]; then
  ctx_with_rates="${ctx_bar} ${rate_str}"
fi

if [ -n "$branch" ]; then
  printf '%b' "${model}${SEP}${ctx_with_rates}${SEP}${MAGENTA}${branch}${RESET}\n${YELLOW}${short_cwd}${RESET}"
else
  printf '%b' "${model}${SEP}${ctx_with_rates}\n${YELLOW}${short_cwd}${RESET}"
fi

