#!/bin/sh
input=$(cat)
echo "$input" > /tmp/statusline-last-input.json

# ANSI color codes
CYAN='\033[36m'
GREEN='\033[32m'
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
ctx_input_tokens=$(echo "$input" | jq -r 'if .context_window.current_usage != null then (.context_window.current_usage.input_tokens + .context_window.current_usage.cache_creation_input_tokens + .context_window.current_usage.cache_read_input_tokens) else 0 end' 2>/dev/null || echo 0)
# Accurate context percentage: cache tokens / (model context - 64k reserved for output)
model_id=$(echo "$input" | jq -r '.model.id // ""')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
[ "$cache_create" = "null" ] && cache_create=0
[ "$cache_read" = "null" ] && cache_read=0
if echo "$model_id" | grep -qi "1m"; then total_context=1000000; else total_context=200000; fi
used=""
actual_tokens=$((cache_create + cache_read))
if [ "$actual_tokens" -gt 0 ] 2>/dev/null; then
  used=$(awk "BEGIN { u = ($actual_tokens / $total_context) * 100; if (u > 100) u = 100; printf \"%.1f\", u }")
fi
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

# Context token count in human-readable format (e.g. 1.2k, 45k, 150k)
ctx_tokens_display=""
if [ "$ctx_input_tokens" -gt 0 ] 2>/dev/null; then
  ctx_tokens_display=$(awk "BEGIN {
    t = $ctx_input_tokens
    if (t >= 1000) { printf \"%.1fk\", t / 1000 }
    else { printf \"%d\", t }
  }")
fi

# Context progress bar (20 chars wide) with colored filled/empty segments
# Format: ctx: 1.2k [########----] 42%
if [ -n "$used" ]; then
  filled=$(awk "BEGIN { printf \"%d\", ($used / 100) * 20 }")
  empty=$((20 - filled))
  filled_bar=""
  empty_bar=""
  i=0
  while [ $i -lt $filled ]; do filled_bar="${filled_bar}#"; i=$((i+1)); done
  i=0
  while [ $i -lt $empty ]; do empty_bar="${empty_bar}-"; i=$((i+1)); done
  used_display=$(printf "%.0f" "$used")
  if [ -n "$ctx_tokens_display" ]; then
    ctx_bar="${DIM}c:${RESET}${DIM}${ctx_tokens_display} [${RESET}${GREEN}${filled_bar}${RESET}${DIM}${empty_bar}]${RESET} ${used_display}%"
  else
    ctx_bar="${DIM}c:${RESET}${DIM}[${RESET}${GREEN}${filled_bar}${RESET}${DIM}${empty_bar}]${RESET} ${used_display}%"
  fi
else
  ctx_bar="${DIM}c:[--------------------]${RESET} --%"
fi

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

rate_str=""
if [ -n "$five_pct" ]; then
  five_fmt=$(printf "%.0f" "$five_pct")
  five_int=$(printf "%.0f" "$five_pct")
  if [ "$five_int" -ge 90 ] 2>/dev/null && [ -n "$five_resets_at" ]; then
    five_reset=$(_fmt_reset "$five_resets_at")
    rate_str="${YELLOW}${DIM}s:${RESET}${YELLOW}${five_fmt}%${RESET}${DIM} resets in ${five_reset}${RESET}"
  else
    rate_str="${DIM}s:${RESET}${five_fmt}%"
  fi
fi
if [ -n "$week_pct" ]; then
  week_fmt=$(printf "%.0f" "$week_pct")
  week_int=$(printf "%.0f" "$week_pct")
  if [ "$week_int" -ge 90 ] 2>/dev/null && [ -n "$week_resets_at" ]; then
    week_reset=$(_fmt_reset "$week_resets_at")
    week_part="${YELLOW}${DIM}w:${RESET}${YELLOW}${week_fmt}%${RESET}${DIM} resets in ${week_reset}${RESET}"
  else
    week_part="${DIM}w:${RESET}${week_fmt}%"
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

