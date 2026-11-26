# Switching between presentation apps on one Mac without showing the desktop

| Tool | Status | Stack |
|---|---|---|
| ARC Switcher | partial | Swift, SwiftUI, AppleScript, Accessibility and CGEvent, OBS over obs-websocket, Node (Bitfocus Companion module) |

## The job
One show laptop holds everything the day needs. A PowerPoint deck, a Keynote deck, a PDF, a browser tab with a video, a movie file. Between speakers the operator has to leave one app and bring up the next on the projector. Done by hand, the room sees the desktop, a dock, an edit window, or presenter view on the wrong screen.

The safe old answer was a hardware switcher and two laptops. I wanted one Mac to behave like a switcher whose inputs are apps.

## Why it is hard
- Every app starts a slideshow differently and puts it on a display of its own choosing. PowerPoint opens presenter view on whichever screen it likes.
- Next and previous are not the same key in every app, and a keystroke goes to whatever is frontmost.
- The audience output must never show the transition. Something has to hold black or the last picture while windows move.
- An app left in slideshow mode behind the next one comes back as a ghost later.
- OBS can be scripted, but it crashes on bad input. An application capture source created without a display UUID made OBS read a null string and die. One property query crashed a specific OBS version every time.

## What the machine does now
- Keeps a list of sources. Each source is a running app with a profile.
- Profiles exist for PowerPoint, Keynote, Google Slides, Acrobat, PDF Expert, Preview, QuickTime and VLC, plus a generic one. A profile says which commands the app supports and how to send each. AppleScript where the app has it, a synthetic key event where it does not.
- Creates one OBS scene per source, prefixed so it cannot collide with the user's own scenes, plus a black scene. Switching a source switches the scene. OBS's full screen projector feeds the output display.
- On a switch, stops the previous source's slideshow, activates the new app, and fills the target display with its window.
- For PowerPoint, briefly captures every display that is not the output, so PowerPoint sees one screen and starts full screen with no presenter view, then releases them after two seconds.
- Has a show mode that prevents sleep and blocks hot corners.
- Serves an HTTP API on port 9090 and ships a Companion module, so sources and next and previous sit on a button deck.

## What still needs a person
Granting accessibility, automation and screen recording permissions the first time. Checking each source on the real output before doors. Knowing which deck comes next.

Known open problems. Keynote's presenter view still appears, because capturing the other displays blacks Keynote out. Arrow keys do not reach PowerPoint while displays are captured, so navigation there is AppleScript only. At the end of the last test session the OBS app captures were showing black, and I have not gone back to prove a full round trip through every app and black. It has no logged field hours in this form.

## Rebuilding it
An engine holds sources, the active source, and a black flag. A window manager moves and sizes app windows through the accessibility API and can capture and release displays. A profile registry maps bundle identifiers to profiles. A websocket client speaks to OBS. An HTTP server exposes the engine.

Decisions. Use OBS as the compositor and output, not my own renderer, because it already captures apps and drives a full screen projector. Put all app specific knowledge in profiles behind one protocol, so adding an app is one file. Prefer AppleScript for slideshow start and navigation, because it addresses the app and not the front window.

Traps. Application capture in OBS needs the display UUID of the screen the app's windows are on, which is the operator's screen, not the output. Keynote has two bundle identifiers across versions. Always reposition the window on a switch, because display capture cycles change window state.
