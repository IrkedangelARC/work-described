# Picking wireless mic frequencies that will not step on each other

| Tool | Status | Stack |
|---|---|---|
| ARC RF Tools (wireless mic frequency finder) | partial | Python, pandas, numpy, openpyxl |

## The job
A show needs eight wireless microphones in a building that already has its own. The venue hands over a spreadsheet of the frequencies its installed systems use, or I scan the room and write down what I see. Then someone has to choose eight more frequencies that sit clear of all of them and clear of each other. By hand that is a column of numbers and a calculator, usually an hour before doors. The maker's coordination software does this well, but it has no scripting interface and assumes its own brand of receiver.

## Why it is hard
- Spacing is not enough. Two transmitters at f1 and f2 create third order intermodulation products at 2f1 minus f2 and 2f2 minus f1. Those land on other channels as if a third transmitter were there. Three transmitters add f1 plus f2 minus f3, and the count grows fast.
- Transmit power changes the answer. A 20 mW pack needs more room around it than a 10 mW pack, and makes stronger products.
- The legal band moved. In the US the 600 MHz range was sold to mobile carriers. Wireless mics are confined to roughly 470 to 608 MHz plus narrow slivers above. Old tools still assume 470 to 698.
- The occupied list is never complete. It has the venue's systems. It does not have the TV stations, the event next door or the presenter's own pack.
- Receivers tune in steps, commonly 25 kHz, inside a model specific band. A mathematically clean frequency a receiver cannot tune is useless.

## What the machine does now
A command line script of about 300 lines. It reads an Excel file with a `Frequency (MHz)` column and sorts the occupied frequencies. It finds every gap wider than the minimum spacing (default 0.6 MHz), ranks gaps by size, and proposes the centre of each gap of at least 1 MHz as a candidate for a 10 mW transmitter. For 20 mW it keeps only candidates more than 2 MHz from every occupied frequency. It then checks pairs of proposed frequencies for one third order product and warns when that product falls within 0.5 MHz of an occupied frequency or on another proposal. Output is a text report and, optionally, an Excel workbook.

It sits inside a larger package of older utilities that are not part of this job. A later browser port of the RF logic lives in my field tools and adds fifth order and three transmitter products and a 25 kHz grid.

## What still needs a person
Nearly all of the judgment. The script is a first pass. It computes only one of the two third order products per pair, ignores products that involve occupied frequencies, does not snap to a tuning grid, does not know receiver bands, and has no legal exclusions, so it will propose frequencies in the carrier owned 600 MHz range if the occupied list spans it. A person must scan the room, check each proposal against the receiver's band, and walk test with all transmitters on.

## Rebuilding it
Do it properly in four steps.

1. Build the candidate set. Take every tunable step inside the receiver's band, minus hard legal exclusions, minus anything within a guard of an occupied frequency or a local TV channel.
2. Choose frequencies greedily or by search. After each choice compute all two transmitter third order and fifth order products and all three transmitter third order products among chosen and occupied frequencies. Reject a candidate if any product lands within the guard of any chosen frequency, or if the candidate lands on an existing product.
3. Score what remains by distance to the nearest neighbour and product.
4. Export in a format the receivers' own software can import, such as a plain CSV of frequency in MHz.

Keep band plans, legal exclusions and guard values in data tables, with a date on the legal table. Verify the current rules before hard coding them.
