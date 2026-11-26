# Seeing the mixer from the camera operator's chair

| Tool | Status | Stack |
|---|---|---|
| ARC XAIR | partial | Kotlin, Compose Multiplatform (desktop), OSC over UDP |

## The job
On a small show one person runs cameras, switching and sound. The mixer is a stage box with no surface, a Behringer X AIR (XR12, XR16 or XR18), and the only way to see it is the maker's editor app on another screen or a tablet. So the operator is looking at camera previews while the answer to whether the lectern mic is open and program audio is leaving the desk lives in a different window. The usual failure is a muted mic on a live camera.

I wanted a narrow strip beside the camera console. It shows the show mics with meters, faders and ON or MUTED, the main output level, and a marker on the mic that belongs to the camera currently on air.

## Why it is hard
- The mixer speaks OSC over UDP port 10024 in the X32 dialect, and the documentation does not match the box. I mapped the meters by measurement. Mute a channel, move a fader, pan it, watch which slots move.
- The mixer only pushes parameter changes to a client that has sent a keepalive in the last 10 seconds or so. The meter subscription expires on its own clock. Miss either and the display freezes with stale, plausible values.
- Meter blobs are a little-endian int32 count followed by little-endian int16 values in 1/256 dB, inside a big-endian OSC packet.
- Pre-fader and post-fader meters are different subscriptions. One meter set carries channels 1 to 16 pre-fader and the main pair post-fader in slots 37 and 38. Another carries the channels post-fader and the main pair pre-fader. Show the wrong one and a muted mic looks alive.
- Fader values are 0 to 1 on a segmented taper, not dB.
- Sends are fire and forget. The truth is the echo that comes back through the subscription about 50 ms later.

## What the machine does now
A small desktop app, about 1,150 lines. The client finds the desk at a configured address, reads its name, model and firmware, keeps both subscriptions alive, and holds channel names, colours, faders, on state, the main fader and three meter sets as observable state. The page shows a program audio confidence strip, channel strips with meters, faders and ON or MUTED, mute groups, snapshot state and the USB recorder state, with a button that hands off to the maker's editor. It can set faders, mutes, names, mute groups and load a snapshot. If my camera console is running, it reads the program tally from that app's HTTP API and marks the on air mic.

The client and meter map were proven against an XR16 while this lived inside the camera console. It was split out when that console's audio moved to the video switcher's built in mixer. Since the split it builds, and it has not been run against the desk.

## What still needs a person
Mixing. This is a confidence surface only. A person sets gain, EQ and routing in the editor app, decides which channels are the show mics, and maps each mic to a switcher input in a properties file. Seven of the meter sets are still unmapped.

## Rebuilding it
One UDP socket, one receive loop, one keepalive loop that re-sends the remote subscription and each meter subscription every few seconds. Parse OSC by hand. It is a small format. Model the desk as state flows that the UI collects. On a user action, send the message and update local state optimistically, then let the echo overwrite it.

Map the meters yourself on your firmware before trusting anyone's table, including mine. Convert fader position to dB with the published X32 taper. Keep configuration in a plain properties file in the home folder. It holds the desk address, show channels, mic to switcher input pairs, and the URL and token of the tally source. Re-send subscriptions every 8 seconds, and after 12 seconds with no reply show disconnected, never the last good meter.
