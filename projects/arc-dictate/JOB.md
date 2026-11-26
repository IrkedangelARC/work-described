# Dictating from one channel of a multi input interface

| Tool | Status | Stack |
|---|---|---|
| ARC Dictate | working in the field | Swift, AppKit, Core Audio, whisper.cpp (Metal), Silero VAD |

## The job
I write a lot of show notes, gear lists and replies, and I talk faster than I type. My desk mic is plugged into channel 1 of a four input audio interface. Before this tool I used the built in dictation or a browser's speech to text, pressed the key, talked, and got silence, half sentences, or invented words.

## Why it is hard
- System dictation asks Core Audio for one channel of the default microphone. On a multi input interface that is a downmix of all inputs. With the mic on channel 1 and three idle channels, the voice arrives about 12 dB down. I measured 13.5 dB on my rig. That is enough to sit under a voice activity threshold. Then the recogniser returns nothing or hallucinates.
- Whisper guesses at proper nouns unless it has just seen them. In my trade "lav" comes back as "lab", "Tentacle Sync" as "Tentacle sink", "mix-minus" as "mix minus".
- Whisper also loops. Carrying decoded text forward as context makes it repeat a phrase across silence. The standard cure is a zero text context. But whisper.cpp only builds a prompt when the context is above zero, so the cure silently throws the vocabulary away. The two settings conflict and nothing warns you.
- A list of proper nouns runs about 2.6 characters per token, not the 3 to 4 of prose, so guessing the prompt size is wrong.
- The audio tap is a real time thread. Any allocation, lock or file write there drops samples.
- Dictation that finishes silently is dangerous. A result I cannot see is a result I overwrite without noticing.

## What the machine does now
It lives in the menu bar. A hotkey starts a take and the same hotkey ends it. It records one named channel of one named device and never downmixes. A panel at the top of the screen shows a live level meter while I talk, then the words it heard and whether they were pasted or only copied. The text goes to the clipboard and, with Accessibility permission, is pasted into the front app. A mic test reports peak and RMS for every channel and offers to switch to the loudest. A vocabulary file, one term per line, is fed to the model before every take. Transcription is fully local. It is large-v3-turbo on Metal with VAD, about 11 times real time on a desktop Apple Silicon machine (6.2 s of speech in 0.55 s). A take past ten minutes stops itself. If the device is unplugged mid take, it abandons the take and says so.

## What still needs a person
Reading the result before sending it anywhere. Keeping the vocabulary list current. Setting the interface gain. If the last peak reads under about -30 dBFS, turn it up. It does not stream text as I talk. The model is a separate download of about 550 MB per machine.

## Rebuilding it
Tap the device, extract the chosen channel into preallocated buffers, convert to 16 kHz mono, and push into a lock free ring. A writer queue drains the ring to a WAV on its own time. On stop, run the whisper.cpp command line tool on the file and clean the output.

The key decision is the context budget. The initial prompt and the rolling decoded text share one budget, and the prompt is taken first. Set the budget to exactly prompt tokens plus one. The vocabulary gets full weight and the rolling context comes out at zero, so there is no loop reinforcement. Measure the token count by asking the model once against 0.2 s of silence, and cache it.

I reuse the engine binary and model that ship with my downloader app instead of bundling a second copy. Verify model files by hash, because a truncated model looks like a missing one. Check that the audio input entitlement survives export, or the permission dialog never appears.
