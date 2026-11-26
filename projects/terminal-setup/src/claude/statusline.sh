#!/bin/bash
# Claude Code status line (ARC Screen, matches the tmux bracket bar)
# model │ ctx % │ effort │ dir │ branch │ +/- lines
input=$(cat)
j() { printf '%s' "$input" | /usr/bin/jq -r "$1" 2>/dev/null; }

model=$(j '.model.display_name // .model.id // "?"')
cwd=$(j '.workspace.current_dir // .cwd // empty')
transcript=$(j '.transcript_path // empty')
added=$(j '.cost.total_lines_added // 0')
removed=$(j '.cost.total_lines_removed // 0')
effort=$(/usr/bin/jq -r '.effortLevel // empty' ~/.claude/settings.json 2>/dev/null)

# Context usage: prefer the value Claude Code provides, else read the last usage block in the transcript
pct=$(j '.context_window.used_percentage // empty')
if [ -z "$pct" ] && [ -f "$transcript" ]; then
  size=$(j '.context_window.context_window_size // 200000')
  used=$(tail -n 200 "$transcript" | /usr/bin/jq -r 'select(.message.usage != null and (.isSidechain|not)) | .message.usage | (.input_tokens + (.cache_read_input_tokens//0) + (.cache_creation_input_tokens//0))' 2>/dev/null | tail -1)
  [ -n "$used" ] && pct=$(( used * 100 / size ))
fi
pct=${pct%.*}

# Colours generated from arc_brand.json (arc-style/tools/gen_terminal_theme.py)
R=$'\e[0m'
. ~/.claude/statusline-colors.sh 2>/dev/null
SEP="${DIM} │ ${R}"

out="${TXT}${model}${R}"
if [ -n "$pct" ]; then
  if   [ "$pct" -ge 80 ]; then c=$BAD; elif [ "$pct" -ge 50 ]; then c=$WARN; else c=$LIVE; fi
  out+="${SEP}${c}ctx ${pct}%${R}"
fi
[ -n "$effort" ] && out+="${SEP}${SUB}${effort}${R}"
[ -n "$cwd" ] && out+="${SEP}${TXT}${cwd##*/}${R}"
if [ -n "$cwd" ]; then
  br=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
  [ -n "$br" ] && out+="${SEP}${IN}${br}${R}"
fi
if [ "$added" != "0" ] || [ "$removed" != "0" ]; then
  out+="${SEP}${MON}+${added}${R} ${BAD}-${removed}${R}"
fi
printf '%s' "$out"
