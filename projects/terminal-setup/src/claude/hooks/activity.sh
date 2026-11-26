#!/bin/bash
# Claude Code activity feed + per-session state (hooks in ~/.claude/settings.json).
#   activity.sh tool     PreToolUse (async): append one line to ~/.claude/activity.log, state=working
#   activity.sh working  UserPromptSubmit
#   activity.sh idle     Stop
#   activity.sh waiting  Notification (permission / question)
#   activity.sh end      SessionEnd: drop the state file
# View: ~/.claude/hooks/activity-view.sh (tmux prefix + a). States: ~/.tmux/scripts/claude-states.sh
mode=$1
input=$(cat)
LOG=~/.claude/activity.log
STATE_DIR=~/.claude/state
IFS=$'\t' read -r sid tool detail < <(printf '%s' "$input" | /usr/bin/jq -r '
  def short: gsub("\n.*"; "") | if length > 110 then .[0:107] + "..." else . end;
  [ (.session_id // "unknown"),
    (.tool_name // ""),
    ( .tool_input as $i | (.tool_name // "") as $t |
      if   $t == "Bash" then ($i.command // "")
      elif ($t | test("^(Read|Edit|Write|NotebookEdit|MultiEdit)$")) then ($i.file_path // $i.notebook_path // "")
      elif ($t | test("^(Grep|Glob)$")) then (($i.pattern // "") + (if $i.path then "  in " + $i.path else "" end))
      elif $t == "WebFetch" then ($i.url // "")
      elif $t == "WebSearch" then ($i.query // "")
      elif $t == "Agent" then (($i.subagent_type // "agent") + ": " + ($i.description // ""))
      elif $t == "Skill" then ($i.skill // "")
      else ($i.description // $i.command // "") end | tostring | short )
  ] | @tsv' 2>/dev/null)
[ -z "$sid" ] && exit 0

# Name = tmux session (".N" when not pane 1), else the working directory.
name=""; pane=""
if [ -n "$TMUX_PANE" ]; then
  name=$(/opt/homebrew/bin/tmux display -p -t "$TMUX_PANE" '#S#{?#{!=:#{pane_index},1},.#{pane_index},}' 2>/dev/null)
  pane=$TMUX_PANE
fi
[ -z "$name" ] && name=$(printf '%s' "$input" | /usr/bin/jq -r '.cwd // "claude"' | xargs basename)

state_file="$STATE_DIR/$sid"
case "$mode" in
  end) rm -f "$state_file"; exit 0 ;;
  tool) st=working ;;
  *) st=$mode ;;
esac
printf '%s\t%s\t%s\t%s\n' "$name" "$st" "$(date +%s)" "$pane" > "$state_file"

if [ "$mode" = "tool" ]; then
  . ~/.claude/statusline-colors.sh 2>/dev/null; R=$'\e[0m'
  case "$tool" in
    Read|Grep|Glob|LSP)                 c=$IN ;;
    Bash|PowerShell)                    c=$OP ;;
    Edit|Write|MultiEdit|NotebookEdit)  c=$OUT ;;
    *)                                  c=$MON ;;
  esac
  if [[ $tool == mcp__* ]]; then short_tool="mcp:${tool##*__}"; else short_tool=$tool; fi
  detail=${detail//$HOME/\~}
  printf '%s%s%s %s%-10s%s %s%-9s%s %s\n' "$SUB" "$(date +%H:%M:%S)" "$R" "$TXT" "$name" "$R" "$c" "$short_tool" "$R" "$detail" >> "$LOG"
  # Keep the log small: past ~2 MB, keep the last 3000 lines.
  if [ "$(stat -f %z "$LOG" 2>/dev/null || echo 0)" -gt 2000000 ]; then
    tail -n 3000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
fi
exit 0
