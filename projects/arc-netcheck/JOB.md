# Finding out whether the venue network will carry the stream

| Tool | Status | Stack |
|---|---|---|
| ARC Netcheck (with ARC Mesh as a companion radio monitor) | working in the field | Python 3 standard library only. ARC Mesh: Python, Meshtastic, launchd |

## The job
I arrive at a venue to stream a talk to YouTube or run a Zoom webinar. Someone from venue IT points at a wall jack and says it is fine. The old check was a speed test in a browser, a big number, and a thumbs up. Then at showtime the encoder cannot connect, or connects and drops, or Zoom audio falls apart once the room fills with phones.

I need an answer in the first 30 seconds, while they are still standing next to me, and a piece of paper I can hand them that says exactly what to open.

## Why it is hard
- An open port is not a working path. Proxies accept the TCP connection on 1935 and then eat the RTMP stream. Only a real handshake proves it.
- Campus networks inspect TLS. That breaks RTMPS outright and degrades Zoom, and a browser speed test never notices.
- A speed test opens many parallel connections. RTMP gets exactly one. Plenty of venue networks show 300 Mbps and shape any single connection to 20.
- Zoom lives on latency, jitter and loss, not bandwidth. If UDP is blocked it falls back to TCP and audio falls apart under load.
- Captive portals silently log you out mid show. Filtering resolvers hijack failed lookups and break ingest hostnames.
- An empty room at 9 am and a full room at 1 pm are different networks.

## What the machine does now
One file, standard library only, runs on any machine with Python 3.9 or later. Three modes. `quick` takes about 30 seconds. `check` takes about 90 and is for the record. `soak` repeats for a set number of minutes to catch the network degrading during setup. It tests for a captive portal, DNS and NXDOMAIN hijack, TCP reach to the YouTube RTMP and RTMPS ingest hosts, a real RTMP handshake (C0, C1, S0, S1, C2, S2) in clear and inside TLS, the TLS certificate issuer to detect inspection, STUN binding for UDP egress including port 3478, latency, jitter and loss by ping with a TCP fallback, single stream and multi stream upload, and Wi-Fi signal, band and channel on Windows. It gives GO, CAUTION or NO-GO. Bandwidth verdicts require 1.5 times the encode bitrate, so a 9 Mbps 1080p60 stream needs 13.7 Mbps measured on one connection. Realtime limits are 100 and 200 ms round trip, 20 and 40 ms jitter, 1 and 3 percent loss. Every run writes a JSON file and a Markdown report that ends with a concrete firewall request list.

ARC Mesh is separate and small. A daemon owns the serial link to a Meshtastic LoRa node, logs text, node info and traceroutes, queues outgoing messages through a file outbox, and reports how far the mesh reaches per hop from measured data. It is my out of band text path when a venue has no usable network at all.

## What still needs a person
Plugging into the exact port the encoder will use. Results from a different jack are worthless. Deciding what CAUTION means for this show. The Zoom media ports (UDP 8801 to 8810) cannot be positively tested without a live session, so a real test call is still required. Throughput depends on one public speed test host.

## Rebuilding it
Write each probe as a function that returns a dictionary and never raises. Run independent probes in a thread pool. Keep targets and thresholds in tables at the top. Do the RTMP handshake by hand. Send the version byte 3 and 1536 bytes, read 1537 back, echo the server's block, read 1536 more. For inspection, read the certificate issuer. Render the report from the same dictionary that goes to JSON, and end it with the firewall request. No dependencies and no config. One file on a USB stick.
