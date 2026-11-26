# Live captions that spell the graduates' names right

| Tool | Status | Stack |
|---|---|---|
| ARC Live Captions | partial | Python, faster-whisper, sounddevice, Ollama (local LLM), YouTube caption ingestion |

## The job
A graduation or a named lecture goes out as a live stream and needs captions. The reliable way is to hire a human captioner (CART) who types along with a prepared name list. The cheap way is the platform's automatic captions, which mangle every name read from the stage. At a graduation the names are the whole point.

## Why it is hard
- Speech models guess at proper nouns. A list of several hundred graduate names does not fit in the model's prompt. Whisper's prompt budget is about 224 tokens, roughly 800 characters, perhaps 100 names.
- Live captioning is a latency problem. The model wants several seconds of audio to be accurate, and a caption more than about 5 seconds late is useless to a viewer.
- Re-transcribing a sliding buffer returns the same words with small changes. Something has to decide what is finished and send only that.
- Silence, applause and walk on music make the model hallucinate. A buffer that only grows during a long pause eventually falls behind real time.
- A correction pass by a language model adds delay and can fail. If it hangs, the captions stop.
- The audio has to be clean program sound from the mixer. A room mic gives the model the reverb and the crowd.

## What the machine does now
It is a scaffold of about 480 lines that works for offline testing. It captures audio at 16 kHz in half second chunks from a chosen input, keeps a rolling buffer, and runs faster-whisper every 1.5 seconds once 3 seconds are buffered. All segments but the last are committed and the buffer is cut at the start of the last one. At 30 seconds it is forced. The name list biases the model through the initial prompt, capped at about 800 characters with the most likely misheard names first. An optional second stage sends each line with the full name list to a local language model on another machine and asks it to fix misheard names only. That call has a hard 2 second timeout and falls back to the uncorrected line. Captions print to the terminal and, when enabled, are posted to the stream's closed caption ingestion URL with sequence numbers. A test command posts one caption to prove the URL before the show.

## What still needs a person
Everything about trust. It has never run at a live event. End to end latency is unmeasured. The first real use has to be in parallel with a paid human captioner, not instead of one. A person builds and locks the name list about 48 hours before the show, orders it by risk, routes clean program audio to the input, and stands by with a kill switch and a fallback to the platform's automatic captions. Nothing yet guards against the language model turning a correct word into a name.

## Rebuilding it
Six small modules. Config loader, audio capture into a queue, a transcriber wrapper, a corrector, an ingestion client and a pipeline loop that ties them together.

Decisions. Keep both name stages optional so it runs on one machine. Put the acoustic model on the fastest CPU available (the library I used has no Apple GPU backend) and the language model somewhere else so they do not compete. Use voice activity filtering. Give the corrector a strict timeout and a narrow instruction. Change only tokens that are plausible mishearings of a listed name. Return the line otherwise unchanged. Keep the caption transport dumb and separate so another destination, such as a meeting's caption API or an on screen overlay, can be added later.

Traps. The prompt is capped, so the order of the list matters. A shorter hop costs CPU quickly. Test against a recording of last year's ceremony before trusting any number.
