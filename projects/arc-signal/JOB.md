# Proving a video path at load in with a handheld

| Tool | Status | Stack |
|---|---|---|
| ARC Signal | working on the bench | Kotlin, Jetpack Compose, Android (SDK 33), AudioTrack, MediaExtractor |

## The job
At load in, before the rack is even powered, somebody has to prove each video path. This cable run, this distribution amp, this scaler, this house input. The old way was a laptop on a ladder or the stage lip, running a 23 slide deck of test patterns, with an adapter hanging off it.

I wanted a battery handheld with a gamepad that outputs broadcast test patterns over HDMI and tells me what the display at the far end says about itself.

## Why it is hard
- On my handheld (an AYN Thor Max), the internal screens go dark the moment HDMI is attached. Android still reports them on. The backlight is held off in hardware and cannot be changed without root. So the operator cannot see the device while using it.
- The output timing cannot be commanded. The system stores a preferred mode and ignores it. You get the sink's native mode. A "choose 1080p59.94" feature cannot work.
- The output is not always 1920 by 1080. Mine was 1920 by 1280. A scaled bitmap makes a one pixel grid line ambiguous, which destroys the only thing a geometry chart is for.
- Raw EDID is readable from sysfs by an ordinary app on this device. On stock Android it normally is not.
- Saturated colours are not code exact on the wire. The compositor runs the external display in a wide gamut mode, so pure red leaves as (234, 51, 35). Greys are exact. Fine for eyeballing a projector, not for a scope.
- 29.97 and 30 frames a second are 0.1 percent apart. Frame count over duration was off by 0.8 percent.

## What the machine does now
- Draws 39 patterns at the real output resolution. Flat fields, ramps, step wedges, PLUGE, SMPTE and EBU bars, grids, one and eight pixel checkerboards, circle geometry, a colour chart, four bitmap charts.
- Navigates entirely by gamepad, by feel. D-pad for pattern and category, one button each for the info overlay, a one pixel edge frame, the EDID page, and moving the overlay to another corner.
- Decodes EDID fully. Maker, product, serial, week and year, physical size, detailed timings with pixel clock and totals, and the extension block. Falls back to the system display API when the raw file is not readable, and badges which path it used.
- Generates audio tests at runtime. 1 kHz at minus 20 dBFS, left and right idents, in phase and out of phase, pink noise, a sweep.
- Plays motion clips at six frame rates from a memory card, and labels each by its measured rate.

## What still needs a person
Looking at the display. The tool puts a known signal in. Judging geometry, black level, sync and motion at the far end is eyes. It has been checked against one sink on the bench, not carried through a show.

## Rebuilding it
One fully immersive activity, one drawing surface. A pattern library drawn in device pixels. An EDID decoder with a two path resolver. A tone generator. A clip library that reads a folder. Identify displays by unique ID, because logical IDs change on every replug.

Decisions. Draw patterns, do not ship images, so they are pixel exact at any size. Generate audio, do not ship music. Locate the display connector by scanning for "connected", never by a fixed name. Measure frame rate from the median gap between container sample timestamps, and snap to the nearest standard rate, never the first one within tolerance.

Traps. A one pixel checkerboard drawn as a million rectangles never finishes a frame. Build a bitmap once and blit it. An overlay and the pattern must share one parent or closing the overlay leaves its pixels behind. UI inspection tools return nothing while HDMI is attached, so verify by framebuffer capture. The four bitmap charts are third party images and are not mine to publish.
