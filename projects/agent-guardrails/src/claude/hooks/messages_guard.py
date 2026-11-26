#!/usr/bin/env python3
"""PreToolUse guard for iMessage/SMS (2026-11-12, decisions M1, M2, M6).

Blocks (exit 2, reason on stderr back to Claude):
  1. Any Bash command that drives Messages directly: AppleScript/JXA aimed at Messages,
     imessage:/sms: URLs, writes to chat.db. The only road is imsg.py.
  2. `imsg.py confirm CODE` unless the operator's latest typed message contains CODE, and never from a
     subagent (sends run in the main session where the operator sees the preview).
  3. Write/Edit of any file that would drive Messages, except imsg.py itself.
  4. Edits to the guard, imsg.py, or removing this hook from settings.json, unless the operator's latest
     message says "messages guard edit".
Policy: /Users/you/projects/dotfiles/claude/messages/MESSAGES_POLICY.txt
"""
import json
import re
import sys

GUARD_FILES = ("claude/messages/imsg.py", "messages_guard.py")
GUARD_PHRASE = "messages guard edit"

DRIVE_MESSAGES = [
    re.compile(r"""tell\s+(application|app)\s+(id\s+)?["']?(Messages|com\.apple\.(MobileSMS|iChat))\b""", re.I),
    re.compile(r"""Application\(\s*["'](Messages|com\.apple\.MobileSMS)["']\s*\)""", re.I),
    re.compile(r"""\b(imessage|sms|sms-?to)://""", re.I),
    re.compile(r"""open\s+(-\w+\s+)*["']?sms:""", re.I),
    re.compile(r"""\bcom\.apple\.(MobileSMS|iChat)\b""", re.I),
    re.compile(r"""process\s+["']Messages["']""", re.I),
]
CHATDB_WRITE = re.compile(r"chat\.db.*\b(insert|update|delete|drop|alter|replace|vacuum)\b|"
                          r"\b(insert|update|delete|drop|alter|vacuum)\b.*chat\.db|"
                          r"(>|\bcp\b|\bmv\b|\brm\b|\btee\b)[^|;&]*chat\.db", re.I | re.S)


def WRITES_TO(target: str) -> re.Pattern:
    """A shell command that writes to `target`: an editing command at the start of a simple
    command (line start or after ; & | && ||) with the target among its arguments on that line,
    or a redirect (>, >>) straight into the target."""
    return re.compile(
        rf"(?:^|[;&|(]|&&|\|\|)\s*(?:sudo\s+)?"
        rf"(?:sed\s+(?:-\S+\s+)*-i|perl\s+-\S*i|rm|mv|cp|tee|chmod|truncate|install|ln|touch|dd)\b"
        rf"[^;&|\n]*?\S*(?:{target})"
        rf"|>{{1,2}}\s*['\"]?\S*(?:{target})",
        re.M)


def block(msg: str):
    print(f"MESSAGES GUARD: {msg}\nPolicy: /Users/you/projects/dotfiles/claude/messages/MESSAGES_POLICY.txt",
          file=sys.stderr)
    sys.exit(2)


def last_user_text(transcript_path: str) -> str:
    """Text of the most recent message the operator typed (not tool results, not injected meta)."""
    last = ""
    try:
        with open(transcript_path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("type") != "user" or e.get("isMeta") or e.get("isCompactSummary"):
                    continue
                c = (e.get("message") or {}).get("content")
                if isinstance(c, str):
                    text = c
                elif isinstance(c, list):
                    if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
                        continue
                    text = " ".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
                else:
                    continue
                text = re.sub(r"<system-reminder>.*?</system-reminder>", "", text, flags=re.S)
                if text.strip():
                    last = text
    except OSError:
        pass
    return last


def main():
    try:
        d = json.load(sys.stdin)
    except ValueError:
        return
    tool = d.get("tool_name", "")
    ti = d.get("tool_input") or {}
    said = lambda: last_user_text(d.get("transcript_path", "")).lower()

    if tool == "Bash":
        cmd = ti.get("command", "")
        for p in DRIVE_MESSAGES:
            if p.search(cmd):
                block("direct Messages control is blocked. Use imsg.py send (preview) and let the operator type the code.")
        if CHATDB_WRITE.search(cmd):
            block("chat.db is read-only for Claude.")
        if re.search(r"\bimport\s+imsg\b|\bfrom\s+imsg\b|imsg\.(do_send|osascript|cmd_)|runpy|SourceFileLoader", cmd):
            block("imsg.py may only be run as a command (imsg.py <subcommand>), never imported.")
        # Writes only: an editing command or a redirect whose target is the path, on the same line.
        # (2026-11-12 false positives: prose like "<person> ... imsg.py" or a commit message that
        # merely mentions the path must pass.)
        if WRITES_TO(r"state/imsg").search(cmd):
            block("~/.local/state/imsg (pending previews, send log) is read-only for Claude.")
        m = re.search(r"\bimsg\.py\s+confirm\s+['\"]?([0-9a-fA-F]{6})\b", cmd)
        if m:
            if d.get("agent_id"):
                block("a subagent may not send. Return the draft; the send runs in the main session.")
            code = m.group(1).lower()
            if not re.search(rf"\b{code}\b", said()):
                block(f"send code {code} is not in the operator's latest message. Show the preview and wait for him to type: send {code}")
        elif re.search(r"\bimsg\.py\s+confirm\b", cmd):
            block("imsg.py confirm needs a 6 character code that the operator typed.")
        if WRITES_TO(r"imsg\.py|messages_guard\.py").search(cmd) and GUARD_PHRASE not in said():
            block(f"imsg.py and the guard hook are protected. The operator must say '{GUARD_PHRASE}'.")
        return

    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        path = ti.get("file_path") or ti.get("notebook_path") or ""
        new = ti.get("content") or ti.get("new_string") or ti.get("new_source") or ""
        if tool == "MultiEdit":
            new = "\n".join(e.get("new_string", "") for e in ti.get("edits", []))
        if "/.local/state/imsg" in path:
            block("~/.local/state/imsg is read-only for Claude.")
        if any(path.endswith(g) or g in path for g in GUARD_FILES):
            if GUARD_PHRASE not in said():
                block(f"{path} is guarded. The operator must say '{GUARD_PHRASE}'.")
            return
        if path.endswith("settings.json"):
            old = ti.get("old_string", "")
            removing = ("messages_guard" in old and "messages_guard" not in new) or \
                       (tool == "Write" and "messages_guard" not in new and "/.claude/" in path and "hooks" in new)
            if removing and GUARD_PHRASE not in said():
                block(f"removing the messages guard hook needs the operator to say '{GUARD_PHRASE}'.")
            return
        if any(p.search(new) for p in DRIVE_MESSAGES):
            block(f"{path} would drive Messages directly. Scripts must call imsg.py notify-self (the operator only) or imsg.py send.")


if __name__ == "__main__":
    main()
