# Watching six breakout rooms from one chair

| Tool | Status | Stack |
|---|---|---|
| ARC Zoom Wall | plan only | Swift, ScreenCaptureKit, Core Audio process taps, Chrome (all planned) |

## The job
A multi room event puts each breakout room in its own Zoom meeting. Somebody has to know every room still has picture and sound. Today that is a person with several laptops or browser tabs, clicking between them, listening to one at a time, and finding out a room went silent when the client texts. With six rooms, five are always unheard.

I want one screen with all six meetings, a selector for which one I hear, and alarms when a room goes quiet or its picture stops.

## Why it is hard
- The Zoom Meeting SDK cannot do it. The SDK object is a per process singleton with one meeting service. A hosting account runs one meeting at a time. Joining a meeting hosted by someone else's account through the SDK needs a consent token from that host.
- The browser web client has none of those limits, and a guest can join with only a display name. But six meetings in one browser share cookies, so they share one sign in.
- Audio is the real problem. macOS mixes all of one application's sound together. To hear room 3 alone, each meeting must be its own audio process, and the tap must mute that process at the speakers. Grouping by bundle ID merges all six. It has to be by owning process ID.
- Window IDs change on every relaunch, so assignments cannot be stored by window.
- Browsers throttle hidden content. Whether a covered Chrome window keeps delivering frames is not measured yet.
- A monitor that clicks in the meeting is a liability. If the wall ever drives the page, one day it unmutes itself into a client's session.

## What the machine does now
Nothing. There is a plan and a gate test, no code, and the gate has no recorded result. The gate is nine measurements in one sitting. Two, then six, separate Chrome instances joined to different meetings, whether each shows up as a distinct audio process, whether a per process tap silences it at the speakers while still delivering signal, whether window capture keeps flowing when covered, and CPU, GPU and Wi-Fi load with six galleries up for ten minutes. Each line has a kill or fallback rule. Ship at four if six fails. Fall back to six different browsers if the instances share one audio process.

## What still needs a person
Joining each meeting by hand, muted, camera off, with a display name the host will recognise in the waiting room. Deciding which room deserves the ears. Acting on an alarm, which usually means calling the room tech.

## Rebuilding it
The rule is that the wall watches and listens and never drives the page. No clicks, no keystrokes, no DevTools.

One Chrome instance per meeting, launched with its own user data directory, so each has its own cookie jar and, expected but unproven, its own process. Store assignments by data directory name.

Video is one ScreenCaptureKit stream per window, cropped to drop browser chrome and the Zoom toolbar, captured at tile size except the big tile. Layouts are 2x3, quad, 1+5, 1+3 and single. An empty slot draws a labelled NO SOURCE tile, never black. Output is a borderless named window other apps can take as a source, plus full screen on a display chosen by UUID. Use a ring of three pixel buffers for output.

Audio is one process tap per source, muted when tapped. Two modes, audio follows the selected tile, or audio locked to one source while the picture moves. Separate program and headphone outputs. A meter in each tile.

Alarms. SILENCE after N seconds under a threshold, FROZEN after N seconds with no picture change. A red border marks the tile being heard.

Control is an HTTP API on its own port with a route table. Run it on a desktop workstation, not a show laptop.
