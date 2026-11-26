# Putting names on screen from a speaker list

| Tool | Status | Stack |
|---|---|---|
| ARC Lower Thirds | working on the bench | Swift, SwiftUI, SwiftData, Network framework, ScreenCaptureKit, Node (Bitfocus Companion module) |

## The job
Every panel and keynote has a name graphic. Who is talking, their title, their organisation. Someone gets the speaker list by email the day before, usually as a document or a spreadsheet, and types each name into a slide or a graphics package. During the show an operator finds the right one and takes it to air when the speaker starts, then clears it a few seconds later.

On a small crew that operator is also switching cameras. The graphic has to be one button.

## Why it is hard
- The list is never final. Names change at the door. Editing a title has to take seconds, and the fix has to be on air next time without a re-render.
- Spelling is the whole job. A typo in a name is the one mistake the client remembers.
- A switcher has two ways to take a graphic. A luma key on a single output is simple, but any dark or translucent panel in the design keys out. Fill plus key is clean, but needs two outputs into two inputs, or a card that carries both.
- Animation only looks right inside the real compositor. Rendering a graphic offscreen drops the implicit animation that makes it slide and fade.

## What the machine does now
- Holds shows, each an ordered list of graphics, stored locally.
- Imports a show from JSON, from pasted text, or from a document, with name, title and organisation lines.
- Ships a set of templates (bar, box, glass panel, side stripe, stacked, underline and others) and a canvas editor for custom ones, with design, position and animation presets.
- Runs an operator view with a list, hot buttons, a preview, and fire, clear, next, previous, cut.
- Outputs a stage window in one of two key modes. Luma key puts the graphic on black. Fill and key opens a second window with a white matte of the same animation.
- Sends fill and key to a DeckLink device by capturing its own transparent stage window, so window alpha becomes the key.
- Serves an HTTP API on port 8080 with routes for status, fire, clear, clear all, layers, next, previous, goto, select and cut. All routes are GET so a button deck can call them.
- Includes a Companion module with actions, feedbacks and presets.

## What still needs a person
Checking every name against the source list. Choosing a template that reads on the room's screens. Timing the take. Setting the switcher's key to premultiplied and checking edges during the animation.

Not done. The DeckLink path has never been run into a real switcher. If hardware output and a full screen fill window are both on, the desktop shows through, and there is no interlock yet. The API port collides with another of my apps. No field show stands behind this version.

## Rebuilding it
One engine object holds state. The current show, what is on air on each layer, what is selected next. Views read it. The HTTP server and the button deck write to it.

Decisions. Draw the graphic as ordinary views in a window, not as rendered video, so a text edit is live at once. Make the key output a second view of the same state that draws every opaque thing white, so fill and key cannot drift apart. For hardware output, capture the app's own window with a clear background and send that buffer as fill with alpha. It keeps what the operator sees and what goes out identical, and it keeps compositor animation.

Keep the import format a flat list with line1, line2, line3, a template name and an accent colour, so a spreadsheet export can produce it.

Traps. Screen capture of your own window still needs the screen recording permission. The window must be on screen and non opaque. Pick a control port that nothing else on a show laptop uses.
