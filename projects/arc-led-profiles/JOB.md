# Correcting an LED wall from the laptop when the processor is locked

| Tool | Status | Stack |
|---|---|---|
| ARC LED Profiles | working on the bench | Python (standard library only), Swift command line tool, ICC v4 profiles |

## The job
A rented or house LED wall often looks wrong for slides and video. Too blue, too saturated, shadows crushed, or simply too bright for the cameras. The fix belongs in the wall processor. At many venues the processor is locked, or in a rack nobody will open, or the person with the password went home.

The only thing I control is the Mac feeding the wall. The old fix was to open each video and each deck and grade it for that wall, or to live with it.

## Why it is hard
- The correction has to hit slides, video players and browsers on that output, not one app at a time.
- It must not touch the laptop's own screen, which the operator is reading.
- It has to switch in seconds, during a rehearsal, while someone stands in the house and says warmer or cooler.
- A display profile has two different mechanisms. A per channel curve loaded into the graphics card applies to every pixel. A colour matrix applies only to colour managed content. White balance, gamma, lift and dimming can live in the curve. Saturation cannot. It has to be done by widening the primaries in the matrix so the system pulls colour toward grey.
- Apps that bypass colour management skip the saturation change and keep the rest.
- Dimming in the curve costs bit depth. It is the wrong tool and sometimes the only tool.
- LED walls at low brightness crush near black. One to four percent merge into zero.

## What the machine does now
- Builds eighteen ICC v4 display profiles. A neutral baseline, three warm steps, two cool, less green, less magenta, two shadow lifts, more contrast, two desaturation levels, three dim levels, and two combined "typical LED" presets.
- Builds a custom profile from the command line with red, green and blue gains, saturation, gamma, black lift and brightness, and installs it.
- Writes each profile from scratch with the standard library. Header, sRGB primaries adapted to D50, tone curves, and the video card gamma table.
- Ships a small command line tool that lists displays and their current profile, sets a profile on the first external display by any part of its name, or on a chosen display, and resets to the display's factory profile.

## What still needs a person
Standing in the audience and looking. The procedure is on one page. Grey row neutral, or pick warm or cool. Two percent visible against zero, or lift shadows. Ninety seven to one hundred separate, or dim. Then skin tones and the actual show video make the final call, not the bars.

It does not measure anything. There is no probe and no closed loop. It has not been through a range of walls.

## Rebuilding it
Two programs and a folder of generated files.

The generator composes a correction as two stages. Stage one is a per channel output curve. Gain per channel for white balance, a gamma exponent, a black lift, an overall brightness scale. That goes in the profile's video card gamma tag. Stage two is saturation. Scale the RGB primaries away from the luma axis by one over the saturation factor, so a colour managed system desaturates content to compensate. Then write a valid ICC v4 file by hand with struct packing. No colour library is needed.

The switcher is a short Swift program against the system colour sync calls.

Decisions. Presets are named in the words a person in the house uses, warm, cool, less green. Profiles are per display, so the operator's screen is never changed. Standard library only, so it runs on any field Mac.

Traps. The gamma table is undone by anything that resets display colour, including some full screen video paths. Check on the real playback app, not a still image.
