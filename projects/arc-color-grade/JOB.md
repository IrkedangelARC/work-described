# Matching three cameras that were never matched in the room

| Tool | Status | Stack |
|---|---|---|
| ARC Color Grade | working in the field | Python (OpenCV, NumPy, matplotlib), ffmpeg, ImageMagick, DaVinci Resolve |

## The job
I record conferences with a mixed PTZ rig, typically one Sony BRC-AM7 and two SRG-A40, into an Atomos Sumo 19 as ProRes ISOs. Three cameras, three slightly different pictures. One reads warm, one is half a stop down, one is richer in the wood paneling. In the room there is no time to chart them. In post I used to sit in the Resolve Color page with the parade scope and nudge each camera until a cut between them stopped jumping. That is an evening per show, and the result depended on which frame I parked on.

## Why it is hard
- Full frame statistics are content dependent. A tight shot of a dark suit and a wide shot of a bright room have different means even when the cameras agree. Matching means makes it worse.
- Matching on a warm object (wood, skin) with a standard deviation stretch bends skin tones.
- White is the only objective anchor, R equals G equals B. But automatic white picking fails on tight shots. It picked khaki trousers once and pushed that camera blue.
- Every camera in a match must measure the same physical object. One camera on audience shirts and the others on a lectern plate is not a match.
- A reference smaller than about 200 px is noise. Brushed metal reflects the room and reads warm. Projector spill contaminates anything near the screen.
- An exposure lift computed from white is wrong when one camera's white is already clipped.
- Saturation correction must come after white balance.
- In Resolve, a multicam has two grading scopes. A grade on the angle follows the camera everywhere. A grade on a switched segment stays at that timeline position. Confuse them and the work appears to vanish.

## What the machine does now
One script takes a folder of camera ISOs. It probes codec and colour tags, pulls stills across the whole show, finds should-be-white pixels (bright, low saturation) in safe regions, and writes a check image with the picked pixels in magenta. A `--white-ref` option pins an explicit box per camera at a given time. It computes per channel gains so the white is neutral with green as pivot, lifts each camera to the brightest camera's white level, and optionally matches saturation on a constant warm element (full match, split the difference, or none). A luma mode does a two point slope and offset match on black and white anchors. Output is an ASC CDL and a 33 point .cube LUT per camera, contact sheets, and generated parade, waveform, vectorscope and histogram panels.

A reference document gives the verified steps for grading multicam angles in Resolve Studio 21 (Open in Timeline, Unmix, grade each angle once).

## What still needs a person
I look at the white pick check before trusting any slope. I choose the shared reference object. I decide how much of a camera's character to keep, which is a taste call. Final sign off is on a reference monitor, not the GUI viewer. The tool does not protect skin, so a face close up before and after is mandatory. Later jobs showed its limits, and a measured finish (neutral patch, black from frames, soft shoulder) plus local skin hue curves now live in the edit pipeline, not here.

## Rebuilding it
Extract stills with ffmpeg at fixed minutes. In HSV, threshold V high and S low for white. Erode a hue range mask for the warm element. Gains are simple per channel ratios, kept linear so they export as CDL slope. Write the CDL as XML by hand and the LUT as a 33 cubed grid. Apply as a Group Pre-Clip correction so it lands before any creative grade. Traps. Decode with the clean aperture crop disabled when measuring pixel boxes. Never use full frame means. Check for clipped whites before computing a lift. Re-verify Resolve menu steps against the current manual because they move between point releases.
