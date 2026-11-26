# Making a multi camera rig show up as one webcam and one microphone

| Tool | Status | Stack |
|---|---|---|
| ARC QUAD Camera and ARC QUAD Mic | working on the bench | Swift (CoreMediaIO camera extension), C (Core Audio HAL plug in), Kotlin console side |

## The job
A hybrid talk needs the room's cameras to reach the remote audience through the client's meeting app. On a small job with no switcher, the remote side gets a laptop webcam pointed at the stage.

I wanted my camera console's program picture to appear on a Mac as an ordinary camera named ARC QUAD, with a matching microphone, so any app can pick it.

## Why it is hard
- macOS only takes a virtual camera from a signed native app that carries a system extension. My console runs on the JVM, so a separate Swift host app has to own the extension.
- Updates are brutal. A first install is clean. Every update leaves the old extension waiting to uninstall on reboot, the new one never launches, and the camera vanishes from every app until the Mac restarts.
- The source runs at about 30.2 frames a second. Publishing on my own 30.00 clock repeated a frame and then skipped one about twice a second, which reads as judder on any pan.
- The output must never go black. If the source stops, the remote audience must see a slate.
- Camera extensions carry no audio. Sound needs its own device, and a virtual audio device is a driver inside the system audio server. Installing it restarts all audio on that Mac for a few seconds, network audio included. Never during a show.
- The picture arrives about 260 ms behind the room microphone.

## What the machine does now
The console has a soft program bus that also drives tally. One key per camera puts it on program and lights its lamp. The console serves the program camera's JPEG frames untouched as a multipart MJPEG stream on port 8779. A cut changes the picture in one frame with no mixed frames, because every frame is a full image.

The camera extension pulls that stream and publishes each frame on arrival as ARC QUAD at 1280 by 720, with an upscaled 1080 format for apps that ask. A timer repeats the last frame only when the source goes quiet, then shows a slate. It drops any part that is not a clean JPEG, because a truncated one still decodes and shows a grey band. I measured 300 of 300 unique frames, and a meeting app showed it live.

ARC QUAD Mic is about 500 lines of my own C. It is one device with two sides. The console plays into the feed side and apps record from the mic side, joined by a ring of samples at 48 kHz stereo. The console plays one camera's audio into it, chosen by a key, with a delay setting from 0 to 2000 ms. A self test runs 750 checks before install. A loop test after install measured 21 ms through the device.

## What still needs a person
Approving the extension once per Mac. Installing the audio driver, between shows only. Rebooting after any camera extension update. Measuring lip sync and setting the delay, which I have not done. Still open. The extension reads only from the same Mac, so pulling over the LAN is untested. The build is development signed and not notarized. Nobody has heard the microphone in a real meeting.

## Rebuilding it
Three pieces. A stream endpoint in the camera console. A tiny native host app that activates the extension and reports status, including reboot required. The extension itself.

Forward JPEG frames without decoding on the console side, so a cut costs nothing. Serve from a raw socket, because a stock HTTP server chunk encodes the stream and tears frames. Publish on arrival and keep the timer only as a keepalive. Never block the audio feed thread. Drop the block and count it.

The extension needs a system extension usage description or activation fails. Plan every update as install, then reboot.
