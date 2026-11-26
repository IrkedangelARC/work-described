# Collecting everyone's slides into one numbered show folder

| Tool | Status | Stack |
|---|---|---|
| ARC Deck Intake and ARC Deck | partial | Python (Gmail and Drive APIs, pypdf, reportlab, click, YAML), Google Sheets |

## The job
A week before a symposium the organizer starts forwarding slides. Some come as attachments, some as links to a shared folder. The same talk arrives three times. The agenda changes twice. I download everything, work out which file belongs to which agenda slot, rename each to a run order number so the folder sorts in show order, and chase the missing ones.

For shows that run from one merged PDF, the decks are then spliced between title slides in agenda order, and the operator needs a cue sheet of which slide number each talk starts on. I did this in a file browser and a PDF editor, usually the night before.

## Why it is hard
- The order that matters is agenda order. Files arrive in their own order, named by the presenter, for the presenter.
- A merged deck that is rebuilt after the operator has loaded it must not replace the file under them. Every rebuild is a new version.
- A missing talk still needs its place held, or every slide number after it shifts and the cue sheet is wrong.
- PowerPoint files cannot be merged into a PDF without losing builds and video. Auto-converting them silently is the worst option. The honest move is a hold slide that says "switch to PowerPoint here" and a flag on the cue sheet.
- Presenters paste a whole appendix into a deck. A 90 page file in a 15 minute slot is worth a question before the build.
- Mail access is dangerous. A tool that can read a show inbox must not be able to send from it.

## What the machine does now
Two tools.

The intake tool scans one dedicated mailbox for messages that carry attachments or cloud folder links. For a chosen message it downloads the attachments and everything behind the links, recursively, exporting cloud native slides to PowerPoint and documents to PDF. It sorts files into `Presentations/`, `agenda/` and `review/`, writes a report of what came from where, and labels the message as processed. It executes a rename map only after approval, dry run by default. Its token can read and label mail and read files. It has no send scope at all.

The merge tool reads an event file and a spreadsheet with one row per title slide, talk or break in agenda order. It reports which talks are in hand and which are missing, fuzzy matching file names by last name. It prints a merge plan, then builds a PDF per partition, as a long day is split into parts. Each gets title pages from a title PDF, presenter PDFs in order, a generated placeholder page for each missing talk, and a hold slide for each PowerPoint file. Rebuilds write `_v2`, `_v3`. It writes page counts and start and end slide numbers back to the spreadsheet, makes a cue sheet, and uploads the result.

The live chain test passed on a synthetic show package. The merge tool has built decks for real two day events.

## What still needs a person
- Deciding which file is the right one for a slot. The numbering map is proposed by a language model agent reading the agenda, and a person approves it.
- Chasing missing decks. Talking to the organizer.
- Not built. Numbering from the agenda without an agent, links from other file transfer services, a packaged version for fleet laptops.

## Rebuilding it
Intake is one Python file with five commands, auth, scan, fetch, rename and mark. Merge is a small package with a config loader, spreadsheet reader and writer, merger, placeholder generator, cue sheet writer and uploader.

Mechanics go in code and judgment goes in a reviewed proposal. Never rename without approval. No send scope by construction. The spreadsheet is the single source of order. Never overwrite a built deck. Never convert a PowerPoint file silently.

Keep the mailbox token out of version control. A scan capped at 15 messages once hid real candidates behind unrelated mail, so filter by label.
