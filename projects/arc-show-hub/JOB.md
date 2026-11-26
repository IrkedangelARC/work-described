# One place to see and drive every tool running a show

| Tool | Status | Stack |
|---|---|---|
| ARC Show Hub | plan only | planned Rust (tokio, axum, reqwest, serde), launchd. Nothing is built. |

## The job
A show laptop runs several of my tools at once. The slide player, a stage timer, lower thirds, a camera console, a conferencing sidecar, a switcher helper. The operator keeps them all in their head. After the show, when someone asks what happened at 2:14, there is no single record.

Today that integration is a person looking at six windows, and a control surface with buttons wired one by one to six different ports.

## Why it is hard
- Every tool grew its own control surface on its own port with its own state shape. A client that wants to drive the show must know every port and every vocabulary, and poll each one.
- The written spec and the code disagree. I measured the code. Two apps default to the same port, 8080, so the second one fails to bind on the same machine. Another sits on a port the spec reserved for something else. Three apps listen on every interface with no authentication, against a localhost-only rule, and their tablet remote views may depend on that.
- Two different server implementations exist across the apps, returning different shapes.
- Nothing records what was fired and when. Nothing notices when an app dies mid show.
- A hub that hides these faults in its own config would make them permanent. I have to fix the apps first.
- A daemon on a show machine must not creep in memory or crash, and must deploy as one file with no runtime.

## What the machine does now
Nothing. There is a plan document and no code. The toolchain is not installed on the build machine.

## What still needs a person
Everything, starting with decisions.
- Bind policy for the three apps that listen on all interfaces. Tightening it may break their remote views.
- Final port assignments, and updating the control surface module that points at the old ones.
- Whether commands should go through the hub at all, or whether it stays read-only.
- And then, at a show, the operator still decides what to fire. The hub only routes.

## Rebuilding it
The plan, in order.

Step 0 comes before any new code. Fix the apps. Give every app a unique port, a state endpoint and a help endpoint returning the same `{ok, state}` shape, and rewrite the spec from the code.

Then one headless binary per show machine, run under launchd, bound to 127.0.0.1 by default, with network bind only behind a flag and a token.
- Adapters, one file per app or device, each implementing poll and command.
- A combined state document with change detection and a broadcast channel.
- Read-only API first. Combined state, adapter list with up or down and last error, a WebSocket of state diffs, a log tail.
- Then commands. A passthrough to each app's own verbs, and a cue endpoint that fires a list of steps in order with optional delays.
- Polling at 4 Hz, 250 ms timeout, down after 3 misses, up on the next good reply.
- A show log as one JSON line per command (who, what, result, latency) and per up or down transition. That file is the after-show record.

The hub is a client of the apps and never replaces their own control servers, so each app still works alone. I chose a compiled static binary because it is a long running process on a machine where a crash costs a show, and because one file fits the fleet deploy. Read-only before commands, so the first release cannot hurt a show. Fix faults in the code that produced them and never in a layer above.

I can already see the traps. A port that is free on a show laptop can be taken on the office workstation by an unrelated service. Moving an app's port means updating every client that hardcodes it, including a handheld remote app. An aggregator makes it tempting to add logic. Keep it a bus.
