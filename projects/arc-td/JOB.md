# Turning a gear list and a room into a signal plan

| Tool | Status | Stack |
|---|---|---|
| ARC Tech Director (arc-td) | partial | Python, Graphviz and Mermaid diagrams, SVG, TouchDesigner (one interactive piece) |

## The job
A technical director takes a request ("panel of four, slides, a recording, some colour on the walls") and turns it into paperwork. Which device feeds which. Which cable type and how many. Which lighting fixtures, at which DMX addresses. Where each one stands in the room. What gets pulled from the shelf.

I did this in my head and on a legal pad, then redrew it as a diagram the night before so the crew could build without me. The knowledge is real and the drawing is clerical work.

## Why it is hard
- Signal flow is a compatibility problem. A camera with SDI out and a switcher with HDMI in need a converter between them, and the plan has to name it or the show stops at load in.
- DMX addressing is arithmetic with a hard edge. Each fixture takes a block of channels that depends on its mode. Blocks must not overlap. A universe ends at 512. Fixtures of a type should sit together so a console patch reads cleanly.
- Placement depends on the room. Uplights need wall. Powered fixtures need an outlet within cable reach. A floor plan arrives as a PDF drawn by an architect, with no coordinates.
- A pull list that misses one adapter costs a drive back to the shop.
- The plan is only as good as the equipment data. Port counts and channel modes have to be right per model.

## What the machine does now
- Designs a show from a gear list or a preset. It looks up each device's inputs and outputs, finds a compatible connection by signal type (SDI, HDMI, XLR and others), names the cable, and explains each connection in a sentence.
- Exports the design as a connection list and as diagrams in two text diagram formats.
- Chooses lighting fixtures from scope keywords, assigns DMX start addresses in group order inside one universe, describes the wireless and wired chain, and writes a patch sheet.
- Places fixtures in a room model measured in feet from a fixed origin, warns when a fixture is more than 30 feet from a power drop, and draws the room as SVG.
- Reads a PDF floor plan into a room model using a vision model, as a first draft.
- Generates a pull list from a design.
- Separately, a TouchDesigner helper calculates DMX addresses, universe capacity and multi display window layouts.

## What still needs a person
Whether the design suits the show. Whether the room model from a floor plan is right, which it often is not. Sight lines, rigging, safety and what the venue allows are not modelled at all.

I do not use it regularly on shows. It has tests but few field hours. The equipment data inside it is my own inventory and venue notes, and has to be replaced with a neutral sample before the code is useful to anyone else. The one interactive installation project in this area is not mine to publish.

## Rebuilding it
A device database, a set of designers, and exporters.

- Describe every device as ports with a direction and a signal type. Connection finding is then matching, and a missing converter is a failed match that can be reported.
- Keep designs as plain data. Diagrams, patch sheets and pull lists are all views of one design.
- Emit diagrams as text and let a layout engine draw them. Hand placed diagrams go stale.
- Address DMX in group order and leave gaps between groups for a fixture added on site.
- Treat machine read floor plans as drafts that a person confirms.

Fuzzy matching of device names picks the wrong model. Channel counts change with fixture mode. Separate the database from the code on day one.
