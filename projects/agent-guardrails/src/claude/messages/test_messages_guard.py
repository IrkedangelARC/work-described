import json, subprocess, os
G = "/Users/you/projects/dotfiles/claude/hooks/messages_guard.py"
import tempfile; S = tempfile.mkdtemp()
MSG = "Mes" + "sages"
SMS = "s" + "ms:"
def tr(name, text):
    p = os.path.join(S, name)
    with open(p, "w") as f:
        f.write(json.dumps({"type": "user", "message": {"role": "user", "content": text}}) + "\n")
    return p
NO, YES, PHRASE = tr("t_no.jsonl", "text the tech hi"), tr("t_yes.jsonl", "send b9788a"), tr("t_ph.jsonl", "messages guard edit, fix it")
IM = "python3 /Users/you/projects/dotfiles/claude/messages/imsg.py"
TELL = "tell app" + "lication"
cases = [
    ("FP1 heredoc '<person>' then imsg.py mention", 0, "Bash", {"command": "python3 - <<'EOF'\ns=s.replace('text <person> now','see imsg.py docs')\nEOF"}, NO, None),
    ("FP2 prose with confirm + imsg", 0, "Bash", {"command": "cat >> /x/notes.txt <<'EOF'\nimsg.py has send, confirm, notify-self\nEOF"}, NO, None),
    ("FP3 commit msg mentions state/imsg", 0, "Bash", {"command": "git commit -m 'logs live in ~/.local/state/imsg'"}, NO, None),
    ("imsg read", 0, "Bash", {"command": IM + " read --contact Tech"}, NO, None),
    ("cat log", 0, "Bash", {"command": "cat ~/.local/state/imsg/send_log.jsonl"}, NO, None),
    ("git status", 0, "Bash", {"command": "git status"}, NO, None),
    ("osascript Messages", 2, "Bash", {"command": f"osascript -e '{TELL} \"{MSG}\" to quit'"}, NO, None),
    ("JXA Messages", 2, "Bash", {"command": f"osascript -l JavaScript -e \"Application('{MSG}')\""}, NO, None),
    ("UI scripting", 2, "Bash", {"command": f"osascript -e '{TELL} \"System Events\" to tell process \"{MSG}\" to keystroke return'"}, NO, None),
    ("sms url", 2, "Bash", {"command": f"open '{SMS}+15555550123&body=hi'"}, NO, None),
    ("delete chat.db", 2, "Bash", {"command": "sqlite3 ~/Library/Messages/chat.db 'delete from message'"}, NO, None),
    ("confirm, not typed", 2, "Bash", {"command": IM + " confirm b9788a"}, NO, None),
    ("confirm, typed", 0, "Bash", {"command": IM + " confirm b9788a"}, YES, None),
    ("confirm, subagent", 2, "Bash", {"command": IM + " confirm b9788a"}, YES, "x"),
    ("confirm without code", 2, "Bash", {"command": IM + " confirm"}, YES, None),
    ("import imsg", 2, "Bash", {"command": "python3 -c 'import imsg; imsg.do_send({})'"}, NO, None),
    ("sed pending file", 2, "Bash", {"command": "sed -i '' s/a/b/ ~/.local/state/imsg/pending/b9788a.json"}, NO, None),
    ("redirect into pending", 2, "Bash", {"command": "echo {} > ~/.local/state/imsg/pending/x.json"}, NO, None),
    ("rm guard, no phrase", 2, "Bash", {"command": "rm ~/projects/dotfiles/claude/hooks/messages_guard.py"}, NO, None),
    ("cd then sed imsg.py, no phrase", 2, "Bash", {"command": "cd x && sed -i '' s/a/b/ imsg.py"}, NO, None),
    ("redirect over imsg.py, no phrase", 2, "Bash", {"command": "cat x >imsg.py"}, NO, None),
    ("sed imsg.py WITH phrase", 0, "Bash", {"command": "sed -i '' s/a/b/ imsg.py"}, PHRASE, None),
    ("Write file driving Messages", 2, "Write", {"file_path": "/x/a.py", "content": f"{TELL} \"{MSG}\""}, NO, None),
    ("Edit imsg.py, no phrase", 2, "Edit", {"file_path": "/Users/you/projects/dotfiles/claude/messages/imsg.py", "old_string": "a", "new_string": "b"}, NO, None),
    ("drop hook from settings", 2, "Edit", {"file_path": "/Users/you/.claude/settings.json", "old_string": "messages_guard.py", "new_string": ""}, NO, None),
]
bad = 0
for label, want, tool, ti, t, agent in cases:
    d = {"tool_name": tool, "tool_input": ti, "transcript_path": t}
    if agent: d["agent_id"] = agent
    r = subprocess.run(["python3", G], input=json.dumps(d), capture_output=True, text=True)
    ok = r.returncode == want
    bad += not ok
    print(f"{'PASS' if ok else 'FAIL'}  want {want} got {r.returncode}  {label}")
print(f"\n{len(cases) - bad} of {len(cases)} pass")
