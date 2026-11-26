# Marking gear so it comes home

| Tool | Status | Stack |
|---|---|---|
| ARC Laser (scripts and settings for a desktop CO2 laser) | working on the bench | Python, SVG, Inkscape command line |

## The job
A production company owns hundreds of small black objects. Converters, cases, cable ends, adapters, rack ears. They leave in bins, mix with the venue's gear and other vendors' gear, and some do not come back. Labels peel. Paint pen wears off. Tape leaves glue.

Engraving the logo is permanent. By hand I open the logo in a drawing app, scale it to fit the flat spot on each item, guess power and speed, and ruin one.

## Why it is hard
- One logo does not work at every size. Mine has a mark, a wordmark and a small tagline. At 60 millimetres all of it engraves. At 20 the tagline is a smear. At 6 only heavy letters survive.
- The beam has a spot size, about 0.10 to 0.15 millimetres. Any stroke or gap near that closes up or vanishes. I have to thicken thin strokes before I scale them down.
- A CO2 laser does not mark bare metal. It ablates anodising and paint, which works well on black aluminium. Bare steel or aluminium needs a marking spray.
- Some plastics must never be cut or engraved. PVC releases chlorine. ABS and polycarbonate burn, melt and smell. Many black gear housings are exactly those.
- Raster engraving of a tiny mark is slow and soft at the edges. A vector line pass is sharper.
- Settings are per material and per machine. A number from a forum is a starting point.

## What the machine does now
- Builds a family of logo variants from one source SVG by selecting paths by ID. Full, compact, mark only, micro, and wordmark only, each with a stated size range.
- Thickens strokes for the small variants through the Inkscape command line, so they survive the spot size.
- Lays the variants out on a proof sheet at true size, to be engraved once on scrap and kept as a reference.
- Produces a one page settings sheet as a PDF with material, operation, power, speed, passes, resolution, air assist and notes.
- Holds written rules for materials. What marks, what needs spray, what is forbidden.

The same folder holds personal art projects cut on the same machine. They are not part of this job.

## What still needs a person
Nearly all of the physical work. Identifying the material. Finding a flat spot. Focusing. Fixturing the part so it does not move. Running a test on scrap or on a hidden face. Choosing the variant that fits. Watching the burn, because this is a fire in a box.

There is no link to my inventory. Nothing records which items are marked. The laser's own software still does the final placement and sends the job. The scripts stop at files.

## Rebuilding it
A source logo with named paths. A variant script. A proof sheet script. A notebook of settings.

- Name every path in the logo SVG. Variants are then a filter instead of a redraw, and they stay in step when the logo changes.
- Define each variant by the smallest size at which it is still legible, measured on a real burn and never on screen.
- Thicken before scaling. A stroke that is right at full size is below the spot size at a quarter.
- Use vector engraving for anything under about 20 millimetres.
- Keep a physical proof plate per material next to the machine. It answers "will this fit" faster than any preview.
- Write the forbidden materials list first and put it on the lid.

Check the plastic before every job. A recycling code or a burn test on an offcut is the only sure way. Anodising varies between makers, so the same settings give a white mark on one case and a grey one on the next. Masking tape over painted surfaces cuts down smoke staining. A logo exported with strokes not converted to paths will scale its line width differently from its shapes.
