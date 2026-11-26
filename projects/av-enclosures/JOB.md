# Printing cases for the small boxes that get crushed in a road case

| Tool | Status | Stack |
|---|---|---|
| AV Enclosures | partial | Python, CadQuery, OrcaSlicer command line, a networked FDM printer |

## The job
A video kit is full of small converters and interfaces that ship in a cardboard sleeve. SDI to HDMI converters, a scaler with a screen and buttons, a USB microphone interface. Loose in a bin they get scratched, their connectors take the load, and three of them that belong together never stay together.

The fix is a printed shell. By hand that means callipers, a CAD program, an hour per case, an export, a slicer, a memory stick, and a second print when the HDMI plug does not clear the wall.

## Why it is hard
- The box is easy. The cutouts are the job. Each connector needs an opening at the right height and offset, big enough for the plug's overmould as well as the socket. A BNC needs room for fingers to twist it.
- Converters run warm. A sealed shell cooks them. Vents have to land where the device's own vents are.
- Some devices have a screen and buttons that must stay usable through the case.
- Printed parts are not their nominal size. Clearance that is right in CAD is tight in plastic. I settled on 3 millimetres of clearance around the device, 2.5 millimetre walls and a 3 millimetre fillet.
- Mesh tools are the wrong level. I first tried writing STL triangles directly, then repairing meshes, then subtracting a box by hand. Each gave non manifold parts or slicer errors.
- A case for three devices together multiplies every tolerance.
- Slicing from the command line depends on printer and filament profiles that the slicer normally hides in its GUI state.

## What the machine does now
- Keeps a small database of devices with outer dimensions and a list of connector cutouts per face.
- Builds parametric solid models in CadQuery for a 12G micro converter, a scaler with an LCD window and button holes, a USB microphone interface, and a triple enclosure.
- Generates all models in one run and exports STL, with ventilation slots and a screw down lid in the model.
- Slices from the command line with stored profiles.
- Prints the address to upload to. The upload itself is one command or a drag into the printer's web page.

## What still needs a person
Measuring a new device, including plug bodies. Checking the first print against the real unit with cables in. Choosing material. PLA is the default profile, and PETG is the better choice for a case that sits on a warm converter in a truck. Removing supports. Fitting the lid screws.

The repo carries the abandoned approaches beside the working one, and I have not test fitted several models. I count it as a working generator with unproven parts.

## Rebuilding it
A device table, one model function per case style, a batch script, and a slice and send script.

- Use a solid modelling kernel instead of mesh code. Boolean cuts and fillets are then reliable and the output is watertight by construction.
- Drive everything from the device table. A new converter is a new row and maybe a new cutout type.
- Define cutouts by connector type with a standard opening per type, placed by offset from a device corner, so one measurement convention covers every device.
- Keep clearance, wall and fillet as named parameters at the top, and change them per printer, never per model.
- Name the slicer's printer, filament and process presets explicitly in the script.

Fillet after the cutouts and the kernel may fail on small edges, so fillet the shell first. Measure the plug and not the jack. Leave the cable side open or slotted if the device is ever used while cased. Do not hardcode the printer's address in scripts, which mine do.
