# Work, described

I run a small live event production company. Talks, symposia, conferences, hybrid events, and the recording and editing after. I have done this for about twenty five years. The job is to put a person with an idea in a room where they can be seen and heard, and then keep a record of it.

Over the last few years I built software for nearly every part of that job. I kept all of it private because I thought I would sell it. I understand now that as soon as a job can be articulated it can be copied. The description is the valuable part, and anyone who reads it has it. So I am leaning into that and publishing the descriptions.

## How to read this

Every folder under [`projects/`](projects) is one job I do at work. Each one starts with a `JOB.md`, and each `JOB.md` has the same five parts.

- **The job** is what a person did by hand before the tool existed.
- **Why it is hard** is what goes wrong in a real room. This part took the years.
- **What the machine does now** is only what works.
- **What still needs a person** is judgment, approvals, physical work, and the problems I have not solved.
- **Rebuilding it** is enough of the design and the traps for someone else, or a coding agent, to start.

Where the source code is clean enough to publish, it sits beside the write-up in `src/`. A `SOURCE.md` says what I removed. The code is a copy for reading. The write-up is the point.

## Why it is organized this way

The shape comes from Robert Anton Wilson's RICH Economy. He proposed a society that stops organizing itself around jobs. Step one is a prize for any worker who can design the machine that replaces their own work. The person who has done a job is the one who can define it, describe it and recreate it. The rest of his scheme is how everyone displaced gets paid. The longer version, with sources, is in [docs/the-rich-economy.md](docs/the-rich-economy.md).

Nobody is paying that prize. I am doing step one anyway because it is the only step one worker can do alone. If one of these descriptions saves you from learning something the hard way, the Sponsor button at the top of this page is the tip jar.

## The jobs

<!-- index:start -->
### Running the show

Slides, playback and the show file. Getting other people's decks onto a screen without surprises.

| The job | Tool | Status | Source |
|---|---|---|---|
| [Playing back other people's slides without surprises](projects/arc-presenter/JOB.md) | ARC Presenter | working in the field | [src](projects/arc-presenter/src) |
| [Showing a PDF on the room screen with nothing that can break](projects/arc-presenter-basic/JOB.md) | ARC Presenter Basic | working in the field | [src](projects/arc-presenter-basic/src) |
| [Turning a presenter's deck into something that cannot surprise me](projects/arc-capture/JOB.md) | ARC Capture | working on the bench | [src](projects/arc-capture/src) |
| [Flattening a deck's builds into pages, the first attempt](projects/arc-preso-capture/JOB.md) | ARC Preso Capture | retired | [src](projects/arc-preso-capture/src) |
| [Writing down what "a show" is so two programs agree](projects/arc-show-format/JOB.md) | ARCShowFormat | working in the field | [src](projects/arc-show-format/src) |
| [Collecting everyone's slides into one numbered show folder](projects/arc-deck-intake/JOB.md) | ARC Deck Intake and ARC Deck | partial | write-up only |
| [Knowing which slide was on screen, and when, after the show is over](projects/arc-slide-log/JOB.md) | ARC Slide Log | working on the bench | [src](projects/arc-slide-log/src) |
| [Keeping a show computer quiet while it is on the big screen](projects/arc-show-mode/JOB.md) | ARC Show Mode | working on the bench | [src](projects/arc-show-mode/src) |
| [Keeping a day of talks on schedule from the back of the room](projects/arc-stage-timer/JOB.md) | ARC Stage Timer | working in the field | [src](projects/arc-stage-timer/src) |
| [One place to see and drive every tool running a show](projects/arc-show-hub/JOB.md) | ARC Show Hub | plan only | write-up only |
| [Playing twenty decks in a row without merging them into one file](projects/cuestack/JOB.md) | CueStack | working on the bench | [src](projects/cuestack/src) |
| [Building test shows that have the shape of real ones and none of their content](projects/arc-test-shows/JOB.md) | ARC Test Shows | working on the bench | write-up only |
| [One app to catalog, convert and assemble a whole show's decks, and why I retired it](projects/arc-assimilator/JOB.md) | ARC Presentation Assimilator | retired | write-up only |

### Cameras, switching and graphics

Pointing cameras, cutting between them, and putting names and clocks on screen.

| The job | Tool | Status | Source |
|---|---|---|---|
| [Keeping a walking speaker in frame without a camera operator](projects/arc-follow/JOB.md) | ARC Follow (module inside ARC Camera OP) | partial | [src](projects/arc-follow/src) |
| [Making a multi camera rig show up as one webcam and one microphone](projects/arc-quad-virtual-camera/JOB.md) | ARC QUAD Camera and ARC QUAD Mic | working on the bench | [src](projects/arc-quad-virtual-camera/src) |
| [Switching between presentation apps on one Mac without showing the desktop](projects/arc-switcher/JOB.md) | ARC Switcher | partial | [src](projects/arc-switcher/src) |
| [Turning any laptop screen into fill and key for a switcher](projects/arc-keyer/JOB.md) | ARC Keyer | working in the field | [src](projects/arc-keyer/src) |
| [Putting names on screen from a speaker list](projects/arc-lower-thirds/JOB.md) | ARC Lower Thirds | working on the bench | [src](projects/arc-lower-thirds/src) |
| [Sending graphics with alpha into a switcher over one cable](projects/arc-decklink-output/JOB.md) | ARCDeckLink (shared Swift package) | partial | [src](projects/arc-decklink-output/src) |
| [Never putting a window on the screen the audience is watching](projects/arc-display-kit/JOB.md) | ArcDisplayKit (shared Swift package) | working in the field | [src](projects/arc-display-kit/src) |
| [Proving a video path at load in with a handheld](projects/arc-signal/JOB.md) | ARC Signal | working on the bench | [src](projects/arc-signal/src) |
| [Correcting an LED wall from the laptop when the processor is locked](projects/arc-led-profiles/JOB.md) | ARC LED Profiles | working on the bench | [src](projects/arc-led-profiles/src) |
| [Designing a one operator switching rack that survives the road](projects/arc-constellation-flypack/JOB.md) | ARC Constellation Flypack (a rack design, documents and config scripts) | partial | write-up only |
| [Turning a gear list and a room into a signal plan](projects/arc-td/JOB.md) | ARC Tech Director (arc-td) | partial | write-up only |
| [Marking gear so it comes home](projects/arc-laser/JOB.md) | ARC Laser (scripts and settings for a desktop CO2 laser) | working on the bench | write-up only |
| [Printing cases for the small boxes that get crushed in a road case](projects/av-enclosures/JOB.md) | AV Enclosures | partial | [src](projects/av-enclosures/src) |
| [Keeping one look across a dozen apps in four languages](projects/arc-style/JOB.md) | ARC Style | working in the field | [src](projects/arc-style/src) |
| [Making show graphics from brand data, not from a blank timeline](projects/arc-design/JOB.md) | ARC Design (arc_studio) | partial | [src](projects/arc-design/src) |

### Audio and the remote audience

Sound in the room, sound on the call, and the people who are not in the room.

| The job | Tool | Status | Source |
|---|---|---|---|
| [Being the room's Zoom participant without fighting the Zoom client](projects/arc-zoom/JOB.md) | ARC Zoom | working on the bench | [src](projects/arc-zoom/src) |
| [Watching six breakout rooms from one chair](projects/arc-zoom-wall/JOB.md) | ARC Zoom Wall | plan only | write-up only |
| [Finding the frequency that is about to feed back](projects/arc-audio-scope/JOB.md) | ARC Audio Scope | working on the bench | [src](projects/arc-audio-scope/src) |
| [Spotting feedback from a phone in my pocket](projects/FeedbackHunter/JOB.md) | FeedbackHunter | partial | [src](projects/FeedbackHunter/src) |
| [Seeing the mixer from the camera operator's chair](projects/arc-xair/JOB.md) | ARC XAIR | partial | [src](projects/arc-xair/src) |
| [Setting a USB mic preamp without installing the maker's audio driver](projects/mvx-gain/JOB.md) | MVX Gain | working on the bench | [src](projects/mvx-gain/src) |
| [Picking wireless mic frequencies that will not step on each other](projects/arc-rf-tools/JOB.md) | ARC RF Tools (wireless mic frequency finder) | partial | [src](projects/arc-rf-tools/src) |
| [Keeping a two hour multitrack in sync with the picture](projects/arc-audio-sync/JOB.md) | ARC Audio Sync (a written procedure, no software) | plan only | write-up only |
| [Live captions that spell the graduates' names right](projects/arc-live-captions/JOB.md) | ARC Live Captions | partial | [src](projects/arc-live-captions/src) |
| [Dictating from one channel of a multi input interface](projects/arc-dictate/JOB.md) | ARC Dictate | working in the field | [src](projects/arc-dictate/src) |
| [Getting the video a client embedded on a web page](projects/arc-grab/JOB.md) | ARC Grab | working in the field | [src](projects/arc-grab/src) |
| [Turning a recorded talk into a transcript someone can read](projects/arc-transcription/JOB.md) | ARC Transcription (batch script, plus a small voice to clipboard helper) | working in the field | [src](projects/arc-transcription/src) |
| [The arithmetic a tech does on the back of a cable tag](projects/arc-field-tools/JOB.md) | ARC Field Tools | partial | [src](projects/arc-field-tools/src) |
| [Finding out whether the venue network will carry the stream](projects/arc-netcheck/JOB.md) | ARC Netcheck (with ARC Mesh as a companion radio monitor) | working in the field | [src](projects/arc-netcheck/src) |

### After the show

Turning a recording into something a client can watch, and keeping it.

| The job | Tool | Status | Source |
|---|---|---|---|
| [Turning a recorded talk into a finished edit, from drives to delivery](projects/arc-talk-edit/JOB.md) | ARC Edit (arc-talk-edit) | partial | [src](projects/arc-talk-edit/src) |
| [Matching three cameras that were never matched in the room](projects/arc-color-grade/JOB.md) | ARC Color Grade | working in the field | [src](projects/arc-color-grade/src) |
| [Handing a freelance editor a scripted assistant for Resolve, with guard rails](projects/arc-video-editing-kit/JOB.md) | ARC Video Editing kit | working on the bench | [src](projects/arc-video-editing-kit/src) |
| [Showing a client what each level of recording actually buys](projects/arc-video-tiers/JOB.md) | ARC Video Tiers reel builder | partial | write-up only |
| [Keeping years of show recordings without keeping every raw byte](projects/arc-archive/JOB.md) | ARC Archive (archive encode, verified moves, Drive uploader, client viewer) | working in the field | write-up only |
| [Rescuing a broken recording, grabbing a video, numbering the decks](projects/media-tools/JOB.md) | ARC media tools (ProRes Rescue, ARC Video Grabber, Presentation Renamer, PowerPoint Combiner, conversion presets) | working in the field | [src](projects/media-tools/src) |

### How the work gets built

The rules for the coding agents, how decisions get made, and the terminal I work in.

| The job | Tool | Status | Source |
|---|---|---|---|
| [Pausing for a human decision through a spreadsheet](projects/decision-sheets/JOB.md) | questions sheet (a small script plus a working rule) | working in the field | write-up only |
| [Keeping a coding agent from sending, deleting or writing where it should not](projects/agent-guardrails/JOB.md) | Agent guardrails (rules file, hooks, gated message tool) | working in the field | [src](projects/agent-guardrails/src) |
| [Watching several agent sessions from one terminal](projects/terminal-setup/JOB.md) | Terminal setup (Ghostty, tmux, agent status line and activity feed) | working in the field | [src](projects/terminal-setup/src) |
<!-- index:end -->

## What is not here

The office tools are not published. That is intake, estimates, scheduling, payroll and the books. Two write-ups, the agent guardrails and the decision sheets, describe the rules I work by around them. The tools themselves are not here. Everywhere else I removed client names, the people I work with, job records, prices, calendars, email, venue files, credentials and network details. They are not in this repository's history either. The history starts clean. Placeholders such as `192.0.2.x`, `user@example.com` and `JOB-0000` mark where something real used to be. I do not redistribute third party SDKs. If you find something that looks like it should not be public, please open an issue.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

## Status

This is work in progress. Some of these tools run every week at real events. Some have only run on a bench. Some are plans. Each `JOB.md` says which.
