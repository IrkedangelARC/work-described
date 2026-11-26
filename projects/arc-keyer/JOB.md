# Turning any laptop screen into fill and key for a switcher

| Tool | Status | Stack |
|---|---|---|
| ARC Keyer | working in the field | Swift, SwiftUI, ScreenCaptureKit, Metal, DeckLink (through a shared package), NDI by runtime loading |

## The job
A graduation or awards show wants names and titles over the camera picture. The names usually live in a slide deck somebody built the night before, white text on black. The old way was to feed that laptop into the switcher and luma key it there. Anything dark in the graphic went transparent, soft edges turned grey, and I had to tune the switcher's one key control by eye on the program monitor while the room watched.

The clean way is a fill signal and a separate key signal, which normally means a dedicated graphics machine. I wanted any Mac running any app to become that machine.

## Why it is hard
- A switcher's linear key wants two frame locked signals. The picture, and a matte where white is opaque. A laptop gives you one screen.
- Screen capture stops sending frames when nothing changes. A static title reads as a stalled capture, and frame rate numbers lie.
- Displays sleep. At one ceremony a screensaver took a live output mid show. Any app that feeds program has to hold a display sleep assertion for as long as it is capturing, and release it on every exit path.
- The DeckLink driver is a COM interface. My first attempt used hand written headers. The vtable layout did not match the installed driver and the app crashed during device enumeration. Linking the framework directly made the app refuse to launch on a Mac without the driver.
- Fill rendered over black is premultiplied. If the switcher's key is set to straight, edges get a dark fringe during animation.

## What the machine does now
- Captures a chosen display with ScreenCaptureKit as BGRA at the capture rate I set.
- Runs a Metal compute kernel on every frame. Rec. 709 luma, a linear ramp between a clip level and a gain level, optional invert for graphics on white. It writes two textures, the untouched fill and a grey matte.
- Sends fill and key to two displays, each a full screen Metal layer on its own output, or to a DeckLink device as fill plus key over one cable, or as two NDI senders.
- Puts up an animated test pattern so I can check the chain before the graphics laptop arrives, and so capture keeps delivering frames.
- Holds a display sleep assertion while capturing. Detects a lost display and tries to reconnect before giving up.

## What still needs a person
Setting clip and gain by eye for each deck. Checking edges on the program monitor, not the preview. Setting the switcher's key to premultiplied. The DeckLink path builds and enumerates, but fill and key into a switcher over Thunderbolt has not been checked end to end on hardware. NDI needs the vendor's runtime installed. Virtual camera and Syphon outputs are stubs.

## Rebuilding it
Three stages joined by a small bus. A capture engine owns the screen stream and the sleep assertion. A key engine owns the Metal pipeline and turns one pixel buffer into two. An output bus fans both buffers to adapters that share one protocol. Display, hardware, network. New outputs are new adapters.

Decisions. Key on the GPU with a compute kernel, because the math is three lines and it has to run at 60 frames a second at 1080p. Use a linear clip and gain ramp, not a threshold with softness, so gradients in the graphic stay linear in the matte. Back each output window with a view whose layer is created as a Metal layer. Swapping a layer onto an existing view crashed.

For DeckLink, use the maker's official headers and load the driver at runtime, so a Mac without it shows "not available" and does not crash. For NDI, declare the few C types inline and load the library at runtime the same way. Do not enumerate hardware during a view layout pass.
