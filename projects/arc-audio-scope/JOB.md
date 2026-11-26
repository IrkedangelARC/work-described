# Finding the frequency that is about to feed back

| Tool | Status | Stack |
|---|---|---|
| ARC Audio Scope | working on the bench | Swift, SwiftUI, Metal, Accelerate (vDSP), AVAudioEngine, Swift Package (ScopeKit) |

## The job
Before doors, the sound tech rings out the room. Open a mic, push the gain until the system starts to ring, find the frequency, cut it on the graphic EQ, repeat. I use a measurement mic, a two input USB interface and an analyzer on a laptop. I find a ring on a waterfall. I make a sharp sound, watch the main impulse, and look for a thin trailing line that keeps going after everything else has stopped. That line is the ring. It is not a rising tone.

## Why it is hard
- Frequency resolution and time resolution fight. A 32768 point FFT at 48 kHz resolves bass but smears a short tail. A 512 point FFT is fast but useless below a few kHz.
- A 1/3 octave display should read like the console's graphic EQ. That takes a real filter bank to the ANSI S1.11 / IEC 61260 class 1 limits, not FFT bins added up.
- A ring detector that looks for "loud and steady" flags every held note and every hum. The signature is decay. The neighbours fall and one band does not.
- The decay tail only reveals feedback in the last 1 to 2 dB of margin. A loop M dB short of feedback with loop delay T takes about 20 x T / M seconds to fall 20 dB. A room with 0.6 s reverb falls 20 dB in about 200 ms by itself, so anything further from feedback hides inside the room.
- Audio taps deliver 100 ms blocks, too coarse for a meter. When the chosen interface is unplugged the OS quietly hands you a different input.

## What the machine does now
It is a Mac app with three layouts. The iPad target compiles but is untested. RING OUT shows RTA bars over a Metal waterfall on the same frequency axis, at 1/3, 1/6, 1/12 or 1/24 octave. The fine bands come from a multi window FFT with 32768 points below 200 Hz, 8192 below 1 kHz, 2048 below 4 kHz, 512 above, one slice every 20 ms. The 1/3 view is an order 3 Butterworth bank that passes class 1 in a swept test. I pull the floor handle up until only tails stay lit. It keeps about 82 seconds of history and scrubs back. The detector waits for a hit (neighbours half an octave each side falling 15 dB within 1.5 s), then flags a band that stands 12 dB above its neighbours for 150 ms or more, and logs frequency, nearest EQ band, tail length and decay per 20 dB. Clipped blocks are sat out. SPL gives Fast, Slow, Leq and peak with A, C and Z weighting. ALIGN gives a transfer function, delay finder and generator. A local HTTP API on port 8767 exposes every reading and a screenshot, so I can test the app without a person watching it. A built in test signal has a known 2.4 kHz tail.

## What still needs a person
I make the cuts. There is no mixer control, by design. I place the mic and judge whether a flagged line is a ring, a room mode or a note. Calibration, the iPad and any run on a real PA are still open. A tone gated on with a click is still flagged as a ring.

## Rebuilding it
Keep DSP in a package with no UI and no microphone so it can be tested with synthetic signals. Take input through a sink node on the engine's input, not a tap. Hand samples to a lock free single producer ring that drops and counts when full. Pin the interface as both input and output, force 48 kHz on every start, and when the chosen device disappears, stop and say NOT CONNECTED. Use one level convention everywhere (dBFS RMS, a full scale sine reads -3.01) so bands sum to the broadband level.
