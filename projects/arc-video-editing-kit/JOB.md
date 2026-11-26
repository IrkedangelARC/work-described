# Handing a freelance editor a scripted assistant for Resolve, with guard rails

| Tool | Status | Stack |
|---|---|---|
| ARC Video Editing kit | working on the bench | plain text guides, Python (stdlib), ffmpeg, DaVinci Resolve Studio 21.1 scripting API, a terminal coding agent |

## The job
I use freelance editors. They are good at editing and have never opened a terminal. My own edits now lean on scripts that talk to DaVinci Resolve. They check which files really have audio, find sentence boundaries, place markers, build a rough cut, bring a render to delivery loudness. I wanted a freelancer to have the same help without me sitting next to them, and without a script ever wrecking a timeline they spent a day on.

Before this, onboarding was a phone call and a list of specs in an email, and the deliverable came back at whatever loudness the render produced.

## Why it is hard
- The editor is expert in the craft and new to the tooling. Instructions must assume no Python and no shell, and still be exact.
- A coding agent with scripting access can delete a timeline, ripple every track, or overwrite a render in one call. Resolve's undo covers scripted changes one step at a time, which is not a safety plan.
- The API fails quietly. Calls return None or False. An agent that retries variations blindly does damage.
- External scripting needs the Studio version and a preference that only takes effect after a restart. The first hour is lost there if nobody says so.
- The house style is not written anywhere a newcomer can find. Holds of eight seconds or more, cuts at sentence ends, no cut to a moving camera, picture in picture at one third in one corner, -14 LUFS on every file.
- Client contact is mine. The kit must make it impossible to confuse "render finished" with "delivered".

## What the machine does now
The kit is a folder I share. Six numbered text files. Start here, setup (about thirty minutes), how a session goes, a prompt library, the edit standards, troubleshooting. A workspace folder is copied to the editor's Mac and the agent runs inside it.

The workspace carries a standing instruction file with non negotiable rules. Work only on a duplicate timeline, snapshot before and after and show the diff, dry run with a table and wait for go, never delete or move markers it did not create, never delete projects, timelines, clips or files without a typed yes for that item, ask before rendering, never send or upload anything. It also holds the deliverable spec, the edit style, and a list of verified API traps.

Five standalone tools on one shared helper. A setup check, a read only timeline snapshot with diff, a safe duplicate that names the copy with a timestamp, markers from a list (dry run by default, tagged so it only replaces its own), and a loudness tool that measures or produces a -14 LUFS, -1 dBTP copy without touching the picture and never overwrites. A permissions file pre-approves only the read only commands.

## What still needs a person
Every creative pick. Final colour. Watching each result, because the agent is fast and still wrong sometimes. Telling the agent when a hand edit happened so it takes a fresh snapshot. All client delivery. The kit was tested on a throwaway project. It has not been through a full paid job in a freelancer's hands.

## Rebuilding it
Distil, do not share your pipeline. I took two pieces from my own edit tool, the snapshot and compare, and the loudness chain, and rewrote them with no dependencies beyond ffmpeg. Put the safety rules in the file the agent reads every session and repeat the three most important in the human guide. Make every tool refuse to overwrite and default to dry run. Tag anything the tools create so cleanup can never touch the editor's own markers. Pre-approve only read operations. Write the guides as plain text with complete sentences. Keep the standards in one place and copy them to both the agent file and the human file when they change.
