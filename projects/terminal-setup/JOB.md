# Watching several agent sessions from one terminal

| Tool | Status | Stack |
|---|---|---|
| Terminal setup (Ghostty, tmux, agent status line and activity feed) | working in the field | shell, tmux, Ghostty, jq, Claude Code hooks |

## The job
I run several coding agent sessions at once. Each lives in its own terminal session. Before this setup I tabbed through windows to find out which one had stopped to ask me something. A session could sit waiting on a permission question for twenty minutes while I watched a different one work.

I also needed the same terminal on the office workstation, my field laptop and the crew laptops, without hand copying config files.

## Why it is hard
- The agent's state is invisible from outside its pane. Working, idle and waiting on me all look like a quiet terminal.
- A crashed session never says goodbye. Any state file it left behind lies forever unless something ages it out.
- Status bar scripts run every couple of seconds. Anything slow, such as a git call in a huge repository or a network probe, makes the whole bar stutter.
- Context size is the real cost meter for a long session, and nothing shows it by default.
- The agent rewrites its own settings file in place. A symlink there gets replaced by a plain file, so that one file cannot live in a dotfiles repository.
- Fleet laptops must be able to pull the config but never push to it.
- tmux is not on a stock Mac. The terminal launches tmux by absolute path, so a missing install is a dead window.

## What the machine does now
- One repository of dotfiles, symlinked into the home folder by an install script with a dry run mode. Editing either path edits the same file.
- Ghostty starts straight into tmux through an attach script.
- `t <name>` switches to, or creates, a named tmux session per project from a small map of names to folders.
- Agent hooks write one state file per session. Working on prompt submit and on each tool call, waiting on a permission prompt or question, idle on stop, removed on session end.
- A tmux status segment reads those files and shows every session by name with a marker for working, waiting on me, or idle. It drops a state when its pane is gone or it is older than 12 hours.
- A notification hook raises a desktop banner when any session asks for permission or input.
- An activity feed logs one line per tool call across all sessions. Time, session name, tool, and the command, file or query, color coded by read, run, write. One key toggles the strip. The log trims itself to the last 3,000 lines past 2 MB.
- The agent status line shows model, context percentage with color thresholds at 50 and 80, effort level, folder, branch, lines added and removed. If the agent does not supply the percentage, the script computes it from the last usage block in the transcript.

## What still needs a person
Deciding which waiting session matters first. Merging the hooks block into the agent settings by hand on a new machine. Registering each fleet laptop's read only key. The auto sync hook is debounced but only prints a marker today. The real sync is a separate step I ask for.

## Rebuilding it
Use the agent's hook events as the only source of state. Each hook is a tiny shell script that parses the hook JSON with jq and writes a tab separated state file keyed by session id, with the tmux pane id inside. The status segment is a loop over that folder. Run tool call hooks async so they never slow the agent. Keep the agent settings file out of the repository, with a reference snapshot beside it. Give each fleet machine its own read only deploy key and an ssh host alias that uses only that key. Traps. Absolute paths for tmux and jq inside hooks, because hooks do not get your shell path. Garbage collect states by pane liveness, not just by age.
