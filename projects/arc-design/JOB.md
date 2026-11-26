# Making show graphics from brand data, not from a blank timeline

| Tool | Status | Stack |
|---|---|---|
| ARC Design (arc_studio) | partial | Python, DaVinci Resolve Fusion templates, ffmpeg, Pillow |

## The job
Every show needs a small set of motion graphics. An opener, a name bar, a holding slide, a logo loop for the switcher's media player, a matte version for a keyer. A designer builds each in a compositing app, renders it, and then re-renders the lot when the client's colour or logo changes, or when the next client arrives.

I also need app icons for a dozen tools, each at ten sizes.

## Why it is hard
- The same graphic is needed in several delivery forms. An editor wants a movie with alpha. A switcher's media pool wants a numbered image sequence at exact frame size. A luma keyer wants white on black.
- Alpha has to be real. I tried generative video for an opener. It garbled the text and returned an opaque frame. The procedural render took 1.28 seconds and had a true alpha channel.
- Text in motion graphics must be exact. A logo is geometry.
- Fusion templates are plain text, which makes them generatable, but the format is unforgiving. One node type I used for motion paths stopped the render at 14 percent with no useful error.
- Resolve adds its own frame number suffix to rendered files, so output names are not what you asked for.
- An icon drawn once and scaled down is mud at 16 pixels. A label that reads at 512 is noise at 32.
- Layout mistakes are cheap to see in a still and expensive to see after a render.

## What the machine does now
- Reads a brand file (colours, fonts, logo paths) and writes Fusion template files for lower thirds and title cards as text.
- Mocks each layout as a still image first, so alignment is judged before anything renders.
- Derives delivery variants from one master with alpha. Lower third movies, an image sequence for a switcher's media player, and luma matte versions for a keyer.
- Builds staff name cards from a list.
- Composes app icons per size. Large sizes get glyph, label and badge. Small sizes get the glyph alone, redrawn, not scaled.

## What still needs a person
Design. The tool repeats a decision and never makes one. Someone still chooses the layout, the motion and the type, and looks at the render on a real screen.

Rendering is not hands off. A person opens the templates and renders them in Resolve. The package is uneven. The template generator and icon builder work. Other parts are scaffolding. One module reads my private event records to fill in show names, and would have to be replaced with a plain input file. One client brand file is not mine to share and is not published.

## Rebuilding it
A brand file. A template generator. A deriver. An icon builder. Each is a script that reads data and writes files.

Decisions.
- One master per graphic, rendered once with alpha in a 4444 codec. Every other form is derived from it with ffmpeg. Never render variants separately, because they drift.
- Generate the compositing template as text from the brand file. A colour change is then a data change and a re-render.
- Still mock first. It takes a second and catches most layout errors.
- Left justify text to a common margin shared with the logo. Centred stacks of mixed length lines look accidental.
- Compose each icon size on its own. Decide what survives at each size.
- Procedural over generative for anything with text or a logo.

Traps. In Fusion, drive motion with an XY path made of two splines, not the single path node, which killed my renders. Expect the frame suffix in output names and glob for it. Check the alpha channel of every master by compositing it over a bright colour, since a black matte hides an opaque frame.
