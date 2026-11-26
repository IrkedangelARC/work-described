# Sending graphics with alpha into a switcher over one cable

| Tool | Status | Stack |
|---|---|---|
| ARCDeckLink (shared Swift package) | partial | Swift, Objective-C++, Blackmagic DeckLink SDK headers, ScreenCaptureKit |

## The job
Three of my apps make graphics that belong over a camera picture. A keyer, a lower thirds app and a stage timer. Each used to reach the switcher through HDMI outputs, one for fill and one for key, with two converters and two switcher inputs burned per app.

An ATEM Mini Extreme ISO G2 shows up over Thunderbolt as a DeckLink playback device with keying. One cable can carry fill and key straight into the switcher's keyers. I wanted all three apps to use that through the same code.

## Why it is hard
- The DeckLink driver is a COM style interface. On my first attempt I wrote minimal headers by hand. The vtable layout did not match the installed driver, the device iterator came back with a null vtable, and the app crashed at enumeration.
- Linking the driver framework at build time means the app will not launch on a Mac without the driver, or with a different signing team.
- The graphics in two of the apps only exist as on screen windows. There is no frame buffer to hand to a video card.
- Screen capture only delivers frames when content changes. A static graphic produces no frames.
- A video output call that blocks will back up the render thread. A queue that grows will add latency without limit.
- If start fails half way, the device can be left with keying enabled and no fill.

## What the machine does now
- Reports whether the driver is installed and lists playback capable devices with a persistent ID. With no driver it returns an empty list and does not crash.
- Starts an output on a chosen device at a given size and frame rate, with external key, internal key, or none.
- Accepts either one BGRA buffer with alpha, or a fill buffer plus a white on black matte whose blue channel becomes output alpha.
- Never blocks the caller. While one frame is in flight the next is dropped, and sent and dropped counters are kept.
- Captures one of the app's own windows with a clear background at 1080p60, so window transparency becomes the key.
- Always disables the keyer on teardown, including after a partial start.

## What still needs a person
Plugging in the switcher and looking at the result. I have not verified end to end fill and key into the switcher over Thunderbolt on hardware. That is the next step and it is physical. Confirm the device appears, set an upstream or downstream key to linear and premultiplied, and watch edges during an animation. Frame cadence under load is unmeasured.

## Rebuilding it
Two targets. A bridge target in Objective-C++ wraps the maker's SDK headers and exposes a small C interface. A Swift target wraps that and is the only thing apps import.

- Use the official SDK headers. Their interface IDs and vtable layouts are stable across driver releases. Hand written ones drift.
- Load the driver at runtime through the SDK's dispatch file, so there is no link time dependency and a missing driver degrades to "not available".
- Use synchronous frame display with drop while busy instead of scheduled playback. A graphics overlay has bounded latency needs and is not file playback. Scheduled playback is the upgrade if cadence problems show on hardware.
- Capture the real window with alpha instead of an offscreen render. That keeps animation and keeps what the operator sees identical to what goes out.
- Use an unfair lock that is safe across threads for the in flight guard, and protect counters and state.

The SDK headers are the maker's, redistributed under their SDK terms, and are not mine to relicense. A rebuild should fetch them from the maker. The driver has to be installed on the machine. A hardened app does not need to disable library validation for this, because the framework loads from the system frameworks folder.
