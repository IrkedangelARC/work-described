# Keeping one look across a dozen apps in four languages

| Tool | Status | Stack |
|---|---|---|
| ARC Style | working in the field | Swift package (SwiftUI), JSON tokens, Python |

## The job
I build show tools in Swift, Kotlin, plain web pages and Python. Each one needs the same things. A dark console ground, one red that means on air, a type scale that reads at arm's length, and buttons that behave the same everywhere. For years each app got its colours typed in by hand, copied from the last app, by eye.

On a show an operator moves between five of these in a minute. If red means "live" in one and "delete" in another, somebody takes the wrong thing to air.

## Why it is hard
- Constants drift. I found three different reds in use, each one copied from a slightly wrong copy. Nobody chose any of them.
- There is no shared runtime. A Swift package cannot be imported by a Kotlin app, a stylesheet or an SVG icon. A single source of truth can only be shared as data.
- Colour on a console carries meaning. If colour is chosen per app, it stops carrying information.
- Layout order matters as much as colour. An operator reads a console the way signal flows. Panels placed by whoever added them last break that.
- A style system that only lives in a document is ignored within a month.

## What the machine does now
- Holds every colour, type and chrome token in one JSON file. One red replaced the three.
- Provides a small Python resolver that reads the tokens, so scripts that make icons, graphics and documents use the same values.
- Provides a Swift package with a theme (colours, fonts, spacing) and shared controls, imported by the Mac and iPad apps.
- Runs a sync check that knows where 55 hand held constants live across Swift, Kotlin, CSS and SVG files, compares each to the token file, prints every mismatch, and exits non zero on drift.
- Defines section colours by signal stage. Blue for inputs, orange for what hands operate, green for what eyes monitor, crimson for outputs, and the one red reserved for on air.
- States the layout rule. Modules run in signal order, in to out.

## What still needs a person
Taste. Deciding that a new token is needed, not a one off. Running the check before a release, since nothing forces it. Fixing a drifted constant by hand in the app that owns it, because the check reports and does not rewrite.

The Swift package only covers the Swift apps. The Kotlin and web apps hold copies that the check watches. The check's file list is hand maintained, so a new app is invisible until I add it.

## Rebuilding it
Three parts. A token file. Per language consumers. A checker.

Decisions.
- Tokens are JSON, because every language I use can read it or be compared against it.
- Do not generate code into other projects. Let each project keep hand written constants in its own idiom, and verify them from outside. That keeps every app buildable alone and makes drift a failing check, not a silent one.
- The checker is a table of file, a pattern that finds the constant, and the token it must equal. Adding an app is adding rows.
- Colour roles are named for what they mean on a show (on air, input, output), never for the hue. Then a brand change is one edit.
- Controls live in the package only when two apps need them.

Traps. The logo artwork and the review screenshots in my repo are not part of the system and should not travel with it. The checker's paths point at sibling folders, so it only works in my layout until the paths are made relative. A check that is not wired into a release script gets skipped.
