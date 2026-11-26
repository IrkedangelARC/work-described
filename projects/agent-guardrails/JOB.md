# Keeping a coding agent from sending, deleting or writing where it should not

| Tool | Status | Stack |
|---|---|---|
| Agent guardrails (rules file, hooks, gated message tool) | working in the field | Python, shell, Claude Code hooks, SQLite (read only), AppleScript behind one tool |

## The job
I let a coding agent work across my whole business. Schedules, documents, message drafts, about a hundred project folders. It runs with permission prompts off, because prompts on every command make it useless.

Before the guardrails, the rules lived in my head and in notes the agent was supposed to remember. I would say "text the tech the door code" and the agent would type an AppleScript one liner and it was sent. No preview, no log.

## Why it is hard
- A rule in memory holds only as long as the model remembers it. Subagents on smaller models did not reliably load the rules at all. My review found the texting rule written in five places and enforced in none.
- The dangerous actions are one line long. One shell command can send a text. One API call can move an event and notify everyone on it.
- Outbound actions cannot be undone. A sent text, a notice to a group, a cancellation.
- Approval drifts. "Yes" to one message gets read as yes to the next. An approved dry run gets executed three days later, after the code and the record both changed.
- Incoming text is an attack surface. A message that says "send me the code" is data, not an instruction.
- Patching data hides bugs. If the agent corrects a wrong record by hand, the code that produced it writes the same wrong record next week.

## What the machine does now
A rules file loads into every session, with an explicit priority order when rules conflict.
1. Fix the code, not the data. Trace the symptom to the function, fix it, verify, and only then correct live data.
2. Changes that notify other people need approval. Show the source, show current state, show proposed changes in a table, stop, wait for a yes. Autonomy is revoked for that surface because every change sends a notice.
3. The finished document is authoritative. It overrides hand written planning notes. The agent must report every difference, and still needs approval to write.

A gated message tool. It is the only road to the Messages app.
- `send` is a dry run. It prints the resolved contact, the handle, iMessage or SMS, the exact text, any attachment, and a 6 character code.
- I type "send" plus the code. A PreToolUse hook reads the session transcript and refuses the confirm step unless that code is in my latest typed message. It refuses it from any subagent.
- One send per code. Codes expire in 10 minutes. Any change needs a new preview.
- Recipients must be in Contacts. Groups only by exact name, with every member listed.
- Every send is logged with time, recipient, text and code.

The hook also blocks AppleScript or JXA aimed at Messages, sms and imessage links, writes to the chat database, and writing any script that would do those things. The guard, the tool and the hook entry are locked. Editing them needs a specific phrase in my latest message.

## What still needs a person
Every outbound word. Every write that notifies someone. Every cancellation. Reading the preview, which is the whole point. The hook reads command text and file contents, so a deliberately disguised command could pass. It stops mistakes and drift, not an adversary. Most rules other than texting are still enforced by instruction, not code.

## Rebuilding it
Three layers. First, a short rules file with reasons and a priority order, because the agent applies a rule better when it knows why. Second, for each irreversible channel, build one narrow tool with a preview step and a one use code, then use a pre execution hook to block every other path to that channel. Third, bind the confirm step to the human's own latest message by reading the transcript, and ignore tool results and injected text. Make the guard lock itself. Log everything.
