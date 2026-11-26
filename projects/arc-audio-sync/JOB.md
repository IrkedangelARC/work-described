# Keeping a two hour multitrack in sync with the picture

| Tool | Status | Stack |
|---|---|---|
| ARC Audio Sync (a written procedure, no software) | plan only | Tentacle Sync MKII timecode generators, LTC, DaVinci Resolve |

## The job
At a talk I record two things on two machines. A video recorder (an Atomos Sumo 19) takes the camera or program picture with a stereo mix embedded. The mixer records a multitrack, one file per microphone, to a USB drive. In the edit I want the picture from one and the clean isolated mics from the other. The traditional method is a clap at the start, lined up in the editor, and trust.

I trusted it once on a two hour show. The mixer multitrack and the recorder had drifted about 17 seconds apart within 30 minutes. It looked in sync at the top because both shared a transient near the start. Fixing it meant hours of resyncing segment by segment.

## Why it is hard
- Every recorder runs on its own crystal. Independent clocks drift, and over a two hour event the error is seconds to tens of seconds. A sync point at the head tells you nothing about the tail.
- Automatic waveform sync needs the two recordings to sound alike. An isolated lavalier track and a camera feed of the full mix do not. Different mics, EQ, compression and room noise give failed or false matches.
- Timecode frame rate has to match exactly across devices. 59.94 drop frame, 29.97 drop frame and 60 non drop are three different things, and a mismatch drifts silently.
- LTC is an audio signal. Recorded through a channel with a high pass filter, EQ or compression, it stops decoding. Routed to the main mix, the audience hears it.
- Mixer direct outs tapped post fader bake the live fader moves and mutes into the "isolated" tracks.

## What the machine does now
There is no program here. The repo is the method, written so that a tech or an agent can follow it. It is a methodology document with settings tables for the recorder and for three mixer families (Allen & Heath QU, Allen & Heath SQ, Yamaha DM3), and a shoot day checklist.

Two timecode generators are jammed together the night before at the camera frame rate. One feeds the recorder's timecode input over BNC. The other feeds a spare line input on the mixer, where LTC is recorded as one more track of the multitrack. Both recordings now carry the same clock, so alignment in post is a lookup, not a search. Universal settings are 48 kHz, 24 bit, free run timecode, and direct outs tapped before EQ, fader and mute. The LTC channel is line level with peaks near -12 dBFS, EQ flat, high pass off, muted from the main mix and all sends, and enabled on the USB send.

## What still needs a person
All of it. Charging and jamming the generators, patching, setting the LTC gain by meter, muting that channel from the room, confirming the recorder shows external timecode counting, and checking both units still agree before doors. In post a person reads timecode from the video file and decodes LTC from the mixer track to place the audio. I have not automated that step, and the repo has no evidence yet of a full show run this way.

## Rebuilding it
Buy two jam syncable LTC generators and two cables. 3.5 mm TRS to BNC for the recorder, 3.5 mm TRS to quarter inch TRS for the mixer. Write down, per mixer model, where sample rate, direct out tap point and USB send live in the menus, and save the setup as a scene.

The obvious next piece of software is small. Read the LTC track from the multitrack with a decoder, read the start timecode from the video file's metadata, compute the offset in samples, and write either trimmed WAV files or an edit list that places every track. Check the offset again at the tail of the recording. If head and tail disagree, a device was not locked.
