# Turning a recorded talk into a transcript someone can read

| Tool | Status | Stack |
|---|---|---|
| ARC Transcription (batch script, plus a small voice to clipboard helper) | working in the field | Python, ffmpeg, faster-whisper, Silero VAD, mlx-whisper |

## The job
After a talk or a day of panels, the client wants the audio and a transcript. The recordings are 32 bit float WAV files from the recorder, one per session, each an hour or two long. The manual way is to open each in an editor, normalise it, export an MP3, upload it to a transcription service, download a wall of text with no paragraphs, and fix it by hand. For a day of sessions that is an evening.

## Why it is hard
- Whisper hallucinates on silence, applause and walk on music. The classic failure is one phrase repeated hundreds or thousands of times across a quiet stretch. The cause is the model being fed its own previous output as context, so one bad segment poisons the rest.
- Without voice activity detection the model is asked to transcribe room tone.
- Float recordings arrive at any level. A quiet file transcribes worse, and delivered MP3s should all sit at one loudness.
- Subtitle segments are not paragraphs. Raw output is either one block or a line every few seconds. Neither is readable.
- Paragraph breaks have to come from the speaker, not from a character count. A pause means something. But a speaker who never pauses still needs a break somewhere.
- A batch has to be restartable, or a crash at file six costs the first five.
- I do not want to send client recordings to a cloud service.

## What the machine does now
Point the script at a folder of WAV files, or at one file. For each it does three steps and skips any whose output already exists. First, ffmpeg loudness normalises to EBU R128 (integrated -16 LUFS, true peak -1.5 dBTP, loudness range 11) and writes a 192 kbps MP3. Second, faster-whisper large-v3 on CPU with int8 weights transcribes the MP3 with the voice activity filter on (500 ms minimum silence), beam size 5, temperature fallback from 0 to 1, and conditioning on previous text turned off. That last setting is the one that stops the loops. It writes an .srt. Third, it reflows the segments into paragraphs and writes a .txt with a header naming the source, engine and loudness settings. Flags allow MP3 only, transcript only, a forced redo, a language and an output folder. Everything runs locally.

Paragraphs break on a pause of 2 seconds or more. Break on a pause of 0.8 seconds if the paragraph is past 200 characters and the segment ends a sentence. Past 500 characters, break at a sentence end with a 0.3 second gap. Past 800, break at any sentence end or any 0.3 second gap. Past 1,500, break regardless.

A second small pair of scripts is a voice to clipboard helper for the terminal. It records from a mic, sends the WAV to a whisper server on another machine on my network, and puts the text on the clipboard. A menu bar dictation app has replaced it for daily use.

## What still needs a person
Reading the result. Names, acronyms and technical terms are still guessed, and this script has no vocabulary list. There is no speaker labelling, so a panel comes out as one voice. A person fixes the names and decides whether it is good enough to send.

## Rebuilding it
One file, three functions, one loop. Shell out to ffmpeg for loudness and encoding. Call the transcription library directly and write the subtitle file yourself. Parse that file back for the reflow step, so the paragrapher can rerun on any .srt.

Four decisions matter. Turn off conditioning on previous text, keep voice activity filtering on, normalise before transcribing, and make every step idempotent by checking for its output file. Put the engine and settings in the header of the text file. The same recipe ports directly to whisper.cpp, where the equivalent settings are a zero text context and the Silero VAD model.
