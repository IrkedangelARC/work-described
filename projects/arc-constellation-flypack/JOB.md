# Designing a one operator switching rack that survives the road

| Tool | Status | Stack |
|---|---|---|
| ARC Constellation Flypack (a rack design, documents and config scripts) | partial | Markdown, Graphviz, Python, RouterOS scripts, PowerShell |

## The job
Corporate shows outgrow a small desktop switcher. Too many sources, not enough outputs, no way to send a different picture to the projector, the confidence monitor and the stream. The step up is a 2 M/E switcher with SDI everywhere, and that means a rack. Converters, a patch bay, a network, a control computer, monitors, power.

I design that rack on paper and in my head. What goes in which rack unit, which cable lands where, what address each box has, what order to power on. Then the same person has to rebuild it from memory at 6 am in a ballroom.

## Why it is hard
- One operator. Every control has to be reachable from one seat. A button deck, a touchscreen, a multiview.
- Every destination needs its own bus. Projector, confidence and program monitor each get an aux output, or a routing change for one changes all.
- Re-cabling on site is where shows fail. If every SDI path passes through a normalled patch bay, a change is a patch cord.
- Bidirectional SDI and HDMI converters have a trap. With no valid HDMI input, the SDI output falls back to looping the SDI input. I had multiview returns landing on the SDI inputs of units whose outputs fed switcher inputs. Two minutes before doors a presenter laptop input showed the multiview. A sleeping laptop or a resolution change can trigger it.
- Heat. The pocket behind rack monitors is the hottest place in the case. A switch exhausting into a computer's intake cooks it.
- A network with no fixed addresses means hunting for devices at every load in. A switch on DHCP with no server present sits at a factory fallback address.

## What the machine does now
This is mostly a design, kept as text so it can be diffed.
- A bill of materials, a rack layout, a signal flow document, and a cable schedule with one line per connection.
- Six diagrams generated from source. Master signal flow, rack layout, network topology, audio flow, display modes, and the remote meeting return loop.
- A router configuration script for a LAN only show network, with a fixed address plan and reservations for the switcher, computers, button decks and cameras.
- A script that reads and sets a smart PoE switch through its web interface, reaches it by IPv6 link local address so it works whatever IPv4 address it holds, and can turn PoE on and off per port.
- A show day checklist, including a test for the converter fallback loop.

## What still needs a person
Building it. Buying the rest of the parts. Deciding per job whether the front of house run is SDI or a point to point IP link. Running the checklist. The rack exists in part and has done shows, but the design is still in its first phase with one rendering computer. The second, for separate presentation and key and fill machines, is not built.

## Rebuilding it
Start from destinations, not sources. List every screen and stream that needs its own picture and give each an output bus. Then sources, then conversion, then the patch bay between them.

Decisions.
- All conversion in the rack is one way. HDMI to SDI units feeding the switcher have no SDI input, so there is nothing to fall back to. SDI to HDMI units for multiview only pass SDI onward.
- Power all small converters from one multi port charger with retained cables.
- Control software runs on a separate fanless PC, not on the rendering computer.
- Wire every fixed device to a reserved address.

One test matters. With the show patched, pull the HDMI from each converter that feeds the switcher. That input must go black. Any picture means a bidirectional unit with something on its SDI input is in the path. If one must be used, cap its SDI input and label it.
