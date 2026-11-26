# The arithmetic a tech does on the back of a cable tag

| Tool | Status | Stack |
|---|---|---|
| ARC Field Tools | partial | HTML, CSS, vanilla JavaScript (offline PWA), Python helpers (numpy, soundfile, Flask) |

## The job
Load in is full of small sums done under pressure with no signal. How many LED pars can go on this 20 amp circuit with the amp rack. What DMX values make battery pars match the room's 3200 K house lights. Which wireless frequencies are safe next to the ones the venue already uses. Each is easy at a desk and easy to get wrong in a ballroom basement. Techs carry these in their heads or in four different phone apps.

## Why it is hard
- Venues often have no phone signal backstage, so a web calculator is useless when I need it.
- A 20 amp circuit is not 20 amps of load. Continuous loads are derated to 80 percent.
- Colour temperature is not one RGB value. A fixture with amber, white and UV emitters reaches 3200 K differently from an RGB fixture, and each mode has its own channel order.
- Cable limits depend on signal and format. HDMI, each SDI rate, analog audio, DMX and Cat6 all have different distances.
- RF coordination has legal edges. In the US, wireless mics lost most of the 600 MHz band. A tool that still treats 470 to 698 MHz as open will hand out illegal frequencies.
- Intermodulation products between transmitters grow fast with channel count.
- Multitrack recordings come back with some tracks far under the others. Peak normalising is wrong, because one clap sets the gain.

## What the machine does now
One web page that installs to a phone home screen and works offline through a service worker. Four tabs. Color Temp has a Kelvin slider with presets, a swatch, and DMX values per fixture, with amber and white blending. Power builds circuits with voltage, breaker size and an 80 percent derate switch, adds gear from a wattage table, and shows the load per circuit. Cables is a reference of maximum runs by signal type. RF takes occupied frequencies, snaps them to a 25 kHz grid, and gives open frequencies with a minimum spacing of 600 kHz and a 250 kHz guard around intermodulation products, with saved venue presets in local storage.

Beside it sit two Python scripts. One RMS normalises a folder of multitrack WAV files to a target (default -18 dBFS) with a hard limiter at -1 dBFS, and can preview the first five minutes. The other serves a real time spectrum from a USB interface to any browser on the network at about 30 frames a second, but depends on an analyzer module from another of my folders.

## What still needs a person
Knowing what else is on the circuit. Scanning the room for RF, because the tool only knows the frequencies someone types in. A known bug is open. The RF tab uses the pre-repack band limits and treats the 617 to 652 MHz carrier block as soft interference to route around, when it is a hard legal exclusion. Do not trust its answers above 608 MHz. The fixture and equipment tables are my inventory.

## Rebuilding it
No framework and no build step. One HTML file, one script per tool, data tables as plain JavaScript files, a manifest and a service worker that caches everything on first load. Keep data apart from logic so a new fixture or band plan is a table edit.

For colour, convert Kelvin to RGB with a standard approximation, then add amber below 4000 K and white above 5000 K in proportion. For power, compare summed watts to volts times breaker amps times 0.8. For RF, generate candidates on the channel grid inside the legal band, reject any within the spacing of an occupied or chosen frequency, compute two transmitter third order (2A minus B) and fifth order (3A minus 2B) products and three transmitter products (A plus B minus C), and rank candidates clean first, then by spacing. Make legal exclusions a hard filter. I ported the RF logic from an older Python script and the old band limits came with it.
