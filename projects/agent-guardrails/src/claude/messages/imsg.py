#!/usr/bin/env python3
"""imsg: the ONE way Claude reads and sends iMessage/SMS on the operator's Mac.

Policy: /Users/you/projects/dotfiles/claude/messages/MESSAGES_POLICY.txt
Decisions: 2026-11-12, questions/messages_guardrails_questions_2026-11-12.xlsx (M1 to M9).

  chats    [--days N]                                 recent chats, names resolved
  whois    NAME                                        Contacts handles for a name
  read     --contact NAME | --handle H | --group NAME  [--days N] [--limit N] [--search T] [--reveal-codes]
  send     --to NAME|HANDLE [--handle H] --text T [--attach PATH ...]   preview only, prints a code
  send     --group "Exact Name" --text T [--attach PATH ...]            preview only, lists members
  confirm  CODE                                        the real send; the guard hook requires the operator
                                                       to have typed CODE in his latest message
  notify-self --text T                                 text the operator's own number (automation, M8)
  log      [--n N]                                     recent sends

Reads chat.db read-only (mode=ro). One-time codes are redacted unless --reveal-codes (only when
the operator asks for a specific code). Recipients must be in Contacts or be the operator's own handles (M3).
No tapbacks, edits or unsends exist here (M7). Every send is logged (M9).
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

HOME = Path.home()
CHAT_DB = HOME / "Library/Messages/chat.db"
AB_GLOB = str(HOME / "Library/Application Support/AddressBook/**/AddressBook-v22.abcddb")
STATE = HOME / ".local/state/imsg"
PENDING = STATE / "pending"
LOG = STATE / "send_log.jsonl"
OUTBOX = HOME / "Pictures/imsg_outbox"     # Messages can only attach files from places it may read
EXPIRY_S = 600
APPLE_EPOCH = 978307200

CODE_WORDS = re.compile(r"\b(code|verif\w*|otp|passcode|pin|2fa|one[- ]time|security|login|sign[- ]in|auth\w*)\b", re.I)
CODE_DIGITS = re.compile(r"(?<![\d$.,])\d{4,8}(?![\d,]|\.\d)")


# ── helpers ────────────────────────────────────────────────────────────────

def die(msg: str, code: int = 1):
    print(f"imsg: {msg}", file=sys.stderr)
    sys.exit(code)


def norm(handle: str) -> str:
    """Comparable key: emails lowercased, phones as their last 10 digits."""
    h = (handle or "").strip()
    if "@" in h:
        return h.lower()
    d = re.sub(r"\D", "", h)
    return d[-10:] if len(d) >= 10 else d


def chatdb() -> sqlite3.Connection:
    if not CHAT_DB.exists():
        die(f"{CHAT_DB} not found")
    return sqlite3.connect(f"file:{CHAT_DB}?mode=ro", uri=True)


def apple_ts(ns: int) -> datetime:
    return datetime.fromtimestamp((ns or 0) / 1e9 + APPLE_EPOCH)


def since_ns(days: float) -> int:
    return int((time.time() - APPLE_EPOCH - days * 86400) * 1e9)


def body_text(text, blob) -> str:
    if text:
        return text
    if not blob:
        return ""
    try:
        b = blob.split(b"NSString")[1][5:]
        if b[0] == 0x81:
            n = int.from_bytes(b[1:3], "little")
            return b[3:3 + n].decode("utf-8", "replace")
        return b[1:1 + b[0]].decode("utf-8", "replace")
    except Exception:
        return ""


def redact(text: str, sender_handle: str) -> str:
    short_code_sender = bool(re.fullmatch(r"\d{4,6}", re.sub(r"\D", "", sender_handle or ""))) and "@" not in (sender_handle or "")
    if short_code_sender or CODE_WORDS.search(text):
        return CODE_DIGITS.sub("[CODE]", text)
    return text


# ── Contacts ───────────────────────────────────────────────────────────────

_CONTACTS = None


def contacts() -> list[dict]:
    """Every Contacts card across all sources: {name, handles[], me}."""
    global _CONTACTS
    if _CONTACTS is not None:
        return _CONTACTS
    cards: dict[tuple, dict] = {}
    for path in glob.glob(AB_GLOB, recursive=True):
        try:
            con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            recs = con.execute("SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZNICKNAME, ZORGANIZATION, "
                               "ZCONTAINERWHERECONTACTISME FROM ZABCDRECORD").fetchall()
            phones = con.execute("SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER WHERE ZFULLNUMBER IS NOT NULL").fetchall()
            emails = con.execute("SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS WHERE ZADDRESS IS NOT NULL").fetchall()
            con.close()
        except sqlite3.Error:
            continue
        by_pk: dict[int, list] = {}
        for owner, h in phones + emails:
            by_pk.setdefault(owner, []).append(h.strip())
        for pk, first, last, nick, org, me in recs:
            name = " ".join(x for x in (first, last) if x) or org or nick
            if not name or pk not in by_pk:
                continue
            key = (name.lower(),)
            card = cards.setdefault(key, {"name": name, "nick": nick or "", "org": org or "",
                                          "handles": [], "me": False})
            card["me"] = card["me"] or bool(me)
            card["nick"] = card["nick"] or nick or ""
            card["org"] = card["org"] or org or ""
            for h in by_pk[pk]:
                if norm(h) not in {norm(x) for x in card["handles"]}:
                    card["handles"].append(h)
    _CONTACTS = list(cards.values())
    return _CONTACTS


def own_handles() -> set[str]:
    out = {norm(h) for c in contacts() if c["me"] for h in c["handles"]}
    with chatdb() as con:
        for (login,) in con.execute("SELECT DISTINCT account_login FROM chat WHERE account_login IS NOT NULL"):
            if ":" in login:
                out.add(norm(login.split(":", 1)[1]))
    out.discard("")
    return out


def name_for(handle: str) -> str | None:
    k = norm(handle)
    for c in contacts():
        if k in {norm(h) for h in c["handles"]}:
            return c["name"]
    return "Me" if k in own_handles() else None


def find_contacts(query: str) -> list[dict]:
    q = query.strip().lower()
    exact = [c for c in contacts() if q in (c["name"].lower(), c["nick"].lower())]
    if exact:
        return exact
    return [c for c in contacts() if q in c["name"].lower() or (c["nick"] and q in c["nick"].lower())]


def last_use(handle: str) -> tuple[int, str | None]:
    """(latest message date, service) for a 1:1 chat with this handle."""
    k = norm(handle)
    best = (0, None)
    with chatdb() as con:
        rows = con.execute("SELECT c.chat_identifier, c.service_name, MAX(m.date) FROM chat c "
                           "JOIN chat_message_join j ON j.chat_id = c.ROWID JOIN message m ON m.ROWID = j.message_id "
                           "WHERE c.style = 45 GROUP BY c.ROWID").fetchall()
    for ident, svc, d in rows:
        if norm(ident) == k and (d or 0) > best[0]:
            best = (d or 0, svc)
    return best


# ── read ───────────────────────────────────────────────────────────────────

def cmd_chats(a):
    with chatdb() as con:
        rows = con.execute("SELECT c.ROWID, c.chat_identifier, c.display_name, c.service_name, c.style, MAX(m.date) d "
                           "FROM chat c JOIN chat_message_join j ON j.chat_id=c.ROWID JOIN message m ON m.ROWID=j.message_id "
                           "WHERE m.date > ? GROUP BY c.ROWID ORDER BY d DESC", (since_ns(a.days),)).fetchall()
    for rid, ident, dname, svc, style, d in rows:
        label = f"GROUP {dname or ident}" if style == 43 else (name_for(ident) or "NOT IN CONTACTS")
        print(f"{apple_ts(d):%Y-%m-%d %H:%M}  {svc:<8} {label}  [{ident}]")


def cmd_whois(a):
    found = find_contacts(a.name)
    if not found:
        die(f"no Contacts card matches {a.name!r}")
    for c in found:
        print(c["name"] + (" (me)" if c["me"] else ""))
        for h in c["handles"]:
            d, svc = last_use(h)
            used = f"last {apple_ts(d):%Y-%m-%d} via {svc}" if d else "no chat history"
            print(f"  {h}  ({used})")


def chat_rows_for(con, a) -> list[int]:
    if a.group:
        ids = [r[0] for r in con.execute("SELECT ROWID FROM chat WHERE style=43 AND display_name=?", (a.group,))]
        if not ids:
            die(f"no group chat named exactly {a.group!r} (see: imsg.py chats)")
        return ids
    if a.handle:
        keys = {norm(a.handle)}
    else:
        found = find_contacts(a.contact)
        if len(found) != 1:
            die(f"{len(found)} Contacts cards match {a.contact!r}; be exact" +
                ("".join(f"\n  {c['name']}" for c in found[:10]) if found else ""))
        keys = {norm(h) for h in found[0]["handles"]}
    return [rid for rid, ident in con.execute("SELECT ROWID, chat_identifier FROM chat WHERE style=45")
            if norm(ident) in keys]


def cmd_read(a):
    if not (a.contact or a.handle or a.group):
        die("read needs --contact, --handle or --group")
    with chatdb() as con:
        ids = chat_rows_for(con, a)
        if not ids:
            die("no chat history found")
        q = (f"SELECT m.date, m.is_from_me, h.id, m.text, m.attributedBody, m.cache_has_attachments, m.ROWID "
             f"FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID LEFT JOIN handle h ON h.ROWID=m.handle_id "
             f"WHERE j.chat_id IN ({','.join('?' * len(ids))}) AND m.date > ? AND m.associated_message_type = 0 "
             f"ORDER BY m.date DESC LIMIT ?")
        rows = con.execute(q, (*ids, since_ns(a.days), a.limit * (5 if a.search else 1))).fetchall()
        out = []
        for d, mine, h, text, blob, has_att, rid in rows:
            t = body_text(text, blob).replace("￼", "").strip()
            if has_att:
                names = [r[0] for r in con.execute(
                    "SELECT a.transfer_name FROM attachment a JOIN message_attachment_join x ON x.attachment_id=a.ROWID "
                    "WHERE x.message_id=?", (rid,))]
                t = (t + " " if t else "") + " ".join(f"[attachment {n}]" for n in names if n)
            if a.search and a.search.lower() not in t.lower():
                continue
            if not a.reveal_codes:
                t = redact(t, h or "")
            who = "Me" if mine else (name_for(h or "") or h or "?")
            out.append(f"{apple_ts(d):%Y-%m-%d %H:%M}  {who}: {t}")
            if len(out) >= a.limit:
                break
    print("\n".join(reversed(out)) or "no messages in range")


# ── send ───────────────────────────────────────────────────────────────────

def file_sha(p: str) -> str:
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def resolve_one(a) -> tuple[str, str, str]:
    """(display name, handle, service) for a 1:1 send; refuses anything not in Contacts or the operator's own."""
    own = own_handles()
    target = a.handle or a.to
    looks_like_handle = "@" in target or len(re.sub(r"\D", "", target)) >= 7
    if looks_like_handle:
        name = name_for(target)
        if not name:
            die(f"{target} is not in Contacts and is not one of the operator's handles; add them to Contacts first (M3)")
        handle = target.strip()
    else:
        found = find_contacts(target)
        if len(found) != 1:
            die(f"{len(found)} Contacts cards match {target!r}; be exact or pass --handle" +
                "".join(f"\n  {c['name']}: {', '.join(c['handles'])}" for c in found[:10]))
        c = found[0]
        name = c["name"]
        ranked = sorted(c["handles"], key=lambda h: last_use(h)[0], reverse=True)
        used = [h for h in ranked if last_use(h)[0]]
        if len(used) >= 1:
            handle = used[0]
        elif len(c["handles"]) == 1:
            handle = c["handles"][0]
        else:
            die(f"{name} has several handles and no chat history; pick one with --handle:\n  " + "\n  ".join(c["handles"]))
    if norm(handle) in own:
        name = "Me"
    _, svc = last_use(handle)
    svc = "SMS" if svc in ("SMS", "RCS") else "iMessage"
    return name, handle, svc


def group_target(name: str) -> tuple[str, str, list[str]]:
    with chatdb() as con:
        rows = con.execute("SELECT ROWID, guid, service_name FROM chat WHERE style=43 AND display_name=?", (name,)).fetchall()
        if len(rows) != 1:
            die(f"{len(rows)} group chats are named exactly {name!r}; see: imsg.py chats")
        rid, guid, svc = rows[0]
        members = [h for (h,) in con.execute("SELECT h.id FROM chat_handle_join j JOIN handle h ON h.ROWID=j.handle_id "
                                             "WHERE j.chat_id=?", (rid,))]
    return guid, svc, members


def write_pending(payload: dict) -> str:
    PENDING.mkdir(parents=True, exist_ok=True)
    os.chmod(STATE, 0o700)
    code = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()[:6]
    (PENDING / f"{code}.json").write_text(json.dumps({**payload, "created": time.time()}, indent=1))
    return code


def check_attachments(paths: list[str]) -> list[dict]:
    out = []
    for p in paths or []:
        p = os.path.abspath(os.path.expanduser(p))
        if not os.path.isfile(p):
            die(f"attachment not found: {p}")
        out.append({"path": p, "sha256": file_sha(p), "bytes": os.path.getsize(p)})
    return out


def cmd_send(a):
    if not a.text and not a.attach:
        die("nothing to send: give --text and/or --attach")
    atts = check_attachments(a.attach)
    if a.group:
        guid, svc, members = group_target(a.group)
        payload = {"kind": "group", "group": a.group, "chat_guid": guid, "service": svc,
                   "members": members, "text": a.text or "", "attachments": atts}
        who = [f"{name_for(h) or 'NOT IN CONTACTS'} ({h})" for h in members]
        head = [f"TO GROUP: {a.group}  via {svc}", f"MEMBERS ({len(members)}): " + "; ".join(who)]
    else:
        if not (a.to or a.handle):
            die("send needs --to, --handle or --group")
        name, handle, svc = resolve_one(a)
        payload = {"kind": "one", "name": name, "handle": handle, "service": svc,
                   "text": a.text or "", "attachments": atts}
        head = [f"TO: {name}  {handle}  via {svc}"]
    code = write_pending(payload)
    print("DRY RUN, nothing sent.")
    print("\n".join(head))
    print("TEXT:" + ("\n" + a.text if a.text else " (none)"))
    for x in atts:
        print(f"ATTACH: {x['path']}  ({x['bytes']:,} bytes)")
    print(f"\nTo send exactly this, the operator types:  send {code}")
    print(f"(code expires in {EXPIRY_S // 60} minutes; any change needs a new preview)")


SCRIPT_ONE = '''on run argv
    set svcName to item 1 of argv
    set theHandle to item 2 of argv
    set theText to item 3 of argv
    tell application "Messages"
        if svcName is "SMS" then
            set theAccount to 1st account whose service type = SMS
        else
            set theAccount to 1st account whose service type = iMessage
        end if
        set thePart to participant theHandle of theAccount
        if theText is not "" then send theText to thePart
        repeat with i from 4 to count of argv
            send (POSIX file (item i of argv)) to thePart
        end repeat
    end tell
end run'''

SCRIPT_GROUP = '''on run argv
    set theChat to item 1 of argv
    set theText to item 2 of argv
    tell application "Messages"
        set c to chat id theChat
        if theText is not "" then send theText to c
        repeat with i from 3 to count of argv
            send (POSIX file (item i of argv)) to c
        end repeat
    end tell
end run'''


def stage_attachments(atts: list[dict]) -> list[str]:
    OUTBOX.mkdir(parents=True, exist_ok=True)
    staged = []
    for x in atts:
        if not os.path.isfile(x["path"]) or file_sha(x["path"]) != x["sha256"]:
            die(f"attachment changed since the preview: {x['path']}; preview again")
        dst = OUTBOX / f"{int(time.time())}_{os.path.basename(x['path'])}"
        shutil.copy2(x["path"], dst)
        staged.append(str(dst))
    return staged


def osascript(script: str, args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(["osascript", "-", *args], input=script, capture_output=True, text=True, timeout=60)


def log_send(entry: dict):
    STATE.mkdir(parents=True, exist_ok=True)
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry, ensure_ascii=False) + "\n")


def do_send(p: dict, code: str, via: str) -> None:
    staged = stage_attachments(p.get("attachments", []))
    if p["kind"] == "group":
        r = osascript(SCRIPT_GROUP, [p["chat_guid"], p["text"], *staged])
    else:
        r = osascript(SCRIPT_ONE, [p["service"], p["handle"], p["text"], *staged])
    entry = {"time": datetime.now().isoformat(timespec="seconds"), "code": code, "via": via,
             "kind": p["kind"], "to": p.get("handle") or p.get("group"), "name": p.get("name"),
             "members": p.get("members"), "service": p["service"], "text": p["text"],
             "attachments": [x["path"] for x in p.get("attachments", [])],
             "ok": r.returncode == 0, "error": r.stderr.strip() or None}
    log_send(entry)
    if r.returncode != 0:
        die(f"Messages refused the send: {r.stderr.strip()}")
    print(f"SENT to {p.get('name') or p.get('group')} ({p.get('handle') or p['service']}). Logged in {LOG}")


def cmd_confirm(a):
    code = a.code.strip().lower()
    f = PENDING / f"{code}.json"
    if not f.exists():
        die(f"no pending send with code {code} (already sent, expired or never previewed)")
    p = json.loads(f.read_text())
    if time.time() - p["created"] > EXPIRY_S:
        f.unlink()
        die(f"code {code} expired; preview again")
    f.unlink()   # one send per code, even if the send then fails
    do_send(p, code, "confirm")


def cmd_notify_self(a):
    own = sorted(h for h in own_handles() if "@" not in h)
    if not own:
        die("no own phone handle found (Me card or Messages account)")
    handle = "+1" + own[0] if len(own[0]) == 10 else own[0]
    do_send({"kind": "one", "name": "Me", "handle": handle, "service": "iMessage",
             "text": a.text, "attachments": []}, "self", "notify-self")


def cmd_log(a):
    if not LOG.exists():
        print("no sends logged yet")
        return
    for line in LOG.read_text().splitlines()[-a.n:]:
        e = json.loads(line)
        print(f"{e['time']}  {'OK ' if e['ok'] else 'ERR'} {e['via']:<11} {e.get('name') or e['to']}: {e['text'][:80]}")


# ── cli ────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("chats"); s.add_argument("--days", type=float, default=30)
    s = sub.add_parser("whois"); s.add_argument("name")
    s = sub.add_parser("read")
    s.add_argument("--contact"); s.add_argument("--handle"); s.add_argument("--group")
    s.add_argument("--days", type=float, default=7); s.add_argument("--limit", type=int, default=50)
    s.add_argument("--search"); s.add_argument("--reveal-codes", action="store_true")
    s = sub.add_parser("send")
    s.add_argument("--to"); s.add_argument("--handle"); s.add_argument("--group")
    s.add_argument("--text", default=""); s.add_argument("--attach", nargs="*", default=[])
    s = sub.add_parser("confirm"); s.add_argument("code")
    s = sub.add_parser("notify-self"); s.add_argument("--text", required=True)
    s = sub.add_parser("log"); s.add_argument("--n", type=int, default=20)
    a = ap.parse_args()
    {"chats": cmd_chats, "whois": cmd_whois, "read": cmd_read, "send": cmd_send, "confirm": cmd_confirm,
     "notify-self": cmd_notify_self, "log": cmd_log}[a.cmd](a)


if __name__ == "__main__":
    main()
