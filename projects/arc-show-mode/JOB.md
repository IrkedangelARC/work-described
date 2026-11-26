# Keeping a show computer quiet while it is on the big screen

| Tool | Status | Stack |
|---|---|---|
| ARC Show Mode | working on the bench | Swift, AppKit (menu bar app), IOKit power assertions, macOS Shortcuts, launchd login item |

## The job
Before doors, a technician is supposed to go through the show Mac and close everything that can interrupt. Mail, messages, calendar, chat apps, cloud sync clients. Turn on Do Not Disturb. Mute the alert sound, which otherwise goes out the show audio. Make sure the machine will not sleep. After strike, put it all back. Nobody does every step every time.

I built this after a popup from a cloud sync client appeared over a film playing to an audience.

## Why it is hard
- Do Not Disturb does not stop it. Sync clients and some chat apps draw their own windows, not system notifications. The only sure fix is to close those apps and keep them closed.
- The cause was not obvious. The video switcher's control software autosaves a file every minute and prunes old ones. The Documents folder was mirrored to cloud storage. The sync client announced every mirrored deletion.
- A polite quit of a sync client asks about uploads in progress, which is itself a popup. Those need a force quit. Mail and chat apps get a normal quit so nothing unsaved is lost.
- Apps relaunch themselves. Closing once is not enough.
- macOS has no API for Focus. The only route is a signed Shortcut run through the command line tool, and that tool can block forever waiting for a click.
- A crash or reboot while engaged must not leave the Mac half restored. And a session forgotten for days must not keep killing someone's mail at every login.
- A tool that closes apps is dangerous to test. An early test run started closing apps on my own workstation.

## What the machine does now
One menu bar switch, Engage and Release.

Engage force quits the sync clients, quits a fixed list of mail, message, call, calendar and chat apps, and closes any of them again if they relaunch, with retries. It turns on Do Not Disturb through a bundled Shortcut, sets alert volume to zero, and holds the display and system awake with a power assertion plus a user activity declaration every 30 seconds so the screen saver cannot start. Show apps are never touched. That means browsers, presentation apps, conferencing and media players.

Release relaunches what it closed, hidden, restores the alert volume and turns Do Not Disturb off.

The session is written to disk at Engage. After a crash or reboot the next launch re-arms with the same restore data. A session older than 18 hours is released instead. A blocked Shortcut is killed after 20 seconds and reported as a failed step. The menu bar icon shows off, engaged, engaged with a failed step, or Do Not Disturb not set up. It can be driven by a URL scheme, including over ssh. Per machine lists add or exempt apps. Every action is logged.

## What still needs a person
- First run setup on each Mac. Add the two Shortcuts, set Do Not Disturb to allow no people and no apps, and turn off time sensitive notifications and cross-device sharing, or the owner's phone goes silent too.
- Turning off automatic OS updates and plugging in. Update, battery and password dialogs are system windows and nothing can suppress them.
- Fixing the real fault. A show Mac should not mirror Documents and Desktop to cloud storage. The tool only closes the messenger.
- A field test on a Mac that has never seen the tool is still owed.

## Rebuilding it
A menu bar app with no window. Four parts. A quit policy (which bundle IDs, polite or forced, a pure function with unit tests), system guards (power assertion, alert volume, activity timer), a Focus wrapper around the Shortcuts command line with a timeout, and a session file.

Decisions. Close apps and do not try to hide their windows. Keep a deny list, not an allow list, so show apps are safe by default. Persist the session so restore survives a crash. The test host must never touch the machine it runs on, so tests exercise the policy types only.

Traps. Shortcuts must be signed, and re-signed after any edit. The power assertion dies with the process.
