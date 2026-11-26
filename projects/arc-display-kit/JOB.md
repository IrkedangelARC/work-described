# Never putting a window on the screen the audience is watching

| Tool | Status | Stack |
|---|---|---|
| ArcDisplayKit (shared Swift package) | working in the field | Swift, AppKit, CoreGraphics |

## The job
A show Mac has three or four displays. The operator's screen, a program output to the projector, maybe a confidence monitor, maybe a spare. Several apps want a display each. Before a show I open system settings, work out which display is which, drag windows, and hope nothing moves.

Then a cable gets reseated and the numbering changes. An app that remembered "display 2" now opens its test pattern on the projector in front of a full room.

## Why it is hard
- Display indexes are not stable. They change on replug, reboot and sleep. Only the hardware UUID survives.
- The operating system cannot tell you which display is the projector. Only a person looking at the room can.
- A layout a person verified is only true for that exact set of displays. One added or removed display makes it a guess again.
- Some tools need a display to work on. A slide capture tool, for one, has to run a slideshow full screen somewhere. That somewhere must never be an output that is live.
- "Is something playing on that display" is harder than it looks. Window manager utilities park invisible overlay windows the size of every display. One of them made every display read as occupied.
- Changing resolution on a capture surface is fine. Changing it on a house projector mid show is unforgivable.

## What the machine does now
- Enumerates displays into plain value snapshots with UUID, name, bounds and whether it is the main display.
- Gives every display one of three roles, stored by UUID. The roles are Auto, Capture and LIVE OUT. A LIVE OUT is never captured, never resized, never handed a window.
- Decides which display may host a capture, in order. An unverified monitor map blocks all windowed routing. LIVE OUT is never eligible. The main display is never a capture surface. An explicit Capture display wins, unless something is playing on it, which aborts with a warning. Otherwise exactly one free Auto external is chosen. Two or more is ambiguity, and it refuses to pick.
- Detects occupancy by looking for a full screen sized window from another app in content layers only. Those are normal windows and the shielding level that players use. The utility band between is ignored.
- Keeps a per machine inventory of displays and an operator verified flag tied to a fingerprint of the current topology. Any display change clears the flag.
- Puts up identify slates and test cards in its own windows, with take and clear, and closes them when done.
- Produces a preflight report of the display decision and every permission state, without triggering a prompt.

## What still needs a person
Looking at the room and confirming which physical screen is which. Marking the projector as LIVE OUT. Choosing between two candidate displays when the kit refuses to guess. It refuses by design.

So far one app uses it. The presentation player, keyer, timer and lower thirds apps each still carry their own display code with their own bugs. The standalone menu bar manager I planned around it is not built.

## Rebuilding it
Three files. A policy type with pure decision functions. An inventory that persists roles and verification to a small file in application support. A test output controller that owns its windows.

Decisions.
- Keep the decision logic pure. It takes an array of snapshots and returns a choice or a reason. That makes it unit testable with no hardware, which matters because the failure cases are exactly the ones you cannot stage safely.
- Identify by UUID everywhere. Never store an index.
- Bind human verification to a topology fingerprint, so trust expires by itself.
- Refuse on ambiguity. I take a warning and no action over a wrong window.

Traps. The focused screen is not the main screen. Hiding a test window is not closing it, and a hidden one comes back.
