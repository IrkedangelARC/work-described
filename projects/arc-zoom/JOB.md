# Being the room's Zoom participant without fighting the Zoom client

| Tool | Status | Stack |
|---|---|---|
| ARC Zoom | working on the bench | Swift, SwiftUI, Zoom Meeting SDK for macOS, xcodegen |

## The job
At a hybrid event one laptop at the tech table is "the room" in the Zoom meeting, and a tech sits on it all show. They share the slides, spotlight whichever remote speaker is talking, drag the gallery onto the display that feeds the switcher, admit people from the waiting room, and keep room and far end audio from looping. All of it is mouse work inside the Zoom client, done while also running slides and cameras.

I wanted remote speakers as clean named pictures I could cut to like cameras, and the Zoom chores as buttons and HTTP calls.

## Why it is hard
- The stock client is not a video source. On every share start its main window collapses off screen and a window capture of it freezes. Pin and spotlight only bite in Speaker view. Share sound hijacks the default output.
- Two earlier attempts died on paper. NDI failed because the standard client does not emit it. A spotlight bot stalled on Zoom's March 2026 rule that an SDK app joining a meeting hosted by an external account needs a consent token from that host, every show.
- The SDK allows one meeting per process and one live meeting per hosting account.
- The SDK is 83 items. 38 frameworks, 28 bundles, 11 loose dylibs, 6 helper apps. Embed only the frameworks and the app dies in dyld before main.
- Raw video needs raw data mode set before init, a raw recording started, and a renderer made by the raw data controller. A plain renderer gives nothing.
- The SDK delegates are mostly silent, so roster, spotlight and settings have to be polled and read back.
- Resolution is an account property. On a Pro plan I measured every endpoint capped at 640x360 both ways with all HD toggles on. The same laptop in a meeting hosted on an enterprise account ran 1920x1080.

## What the machine does now
Version 0.11.1 joins as host through the Meeting SDK with an OAuth sign in and a ZAK token kept in the login keychain. No Zoom client runs. It draws participants into PROGRAM, GALLERY and STRIP layouts as named windows the slide player takes as sources, or full screen on assigned displays, and paints black instead of the desktop when an output closes. It creates and ends meetings, admits from the waiting room, spotlights, pins, mutes, renames, chats, starts transcription, and shares a window, a camera or a file. Pre-flight plays a tone on the chosen speaker and loops the mic back. Every control is also an HTTP route on port 8766. A fake engine lets the console be rehearsed with no meeting.

## What still needs a person
Deciding who is on screen. Signing in once per Mac. Ending the meeting on purpose, because a meeting left running blocks the next start. Open problems. The field checklist has never been run at a real show. Cloud recording is refused upstream. One webcam model stops sending frames after about 30 seconds under the SDK. Error text sticks after the cause clears. 1080p needs a higher plan plus a request to Zoom support. Meetings hosted by a client's account still need that host's consent.

## Rebuilding it
One process, three layers. An engine protocol with a fake and an SDK implementation, a sidecar model that polls the engine and owns the truth, and a small HTTP server with a route table. Host meetings on the account that owns the Marketplace app (a General App with Meeting SDK enabled) so no consent step exists. Copy every SDK item into the bundle and budget a day for signing. Output through ordinary named windows, because they can be debugged with a screenshot. When another app captures your window, rotate through a ring of three pixel buffers, since a reused buffer is invisible to the capturer. Coalesce frames to the latest per participant before the main thread.
