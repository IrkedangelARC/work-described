# Pausing for a human decision through a spreadsheet

| Tool | Status | Stack |
|---|---|---|
| questions sheet (a small script plus a working rule) | working in the field | Python, openpyxl, Excel, JSON sidecars |

## The job

I work with a coding agent across my projects. It reaches points where the next step depends on my judgment. Which of two rules is right, whether a stale record should be overwritten, whether a scheduled time should move. It used to ask in the chat. I would get six questions in a paragraph, each missing the context I needed, while I was loading a truck.

The decisions themselves are small. The cost is in the handoff. A question I cannot answer in the moment has to survive until I can, with everything I need to decide it sitting next to it.

## Why it is hard

- A question without context gets a bad answer. I need to see what the code does today, the evidence, and what each option changes downstream.
- Chat is the wrong medium for more than one question. Answers interleave, half get skipped, and nothing records which question an answer belongs to.
- Approval of one thing must not leak onto another. A cancellation approved because it sat next to an unrelated yes is how a technician loses a day of work.
- An approved plan goes stale. If the code or the record changed after I approved a dry run, the document I approved no longer describes what will happen. Running it anyway is acting without approval.
- A paraphrase hides the problem. When the question is about wording, I need the text as the reader sees it, with the disputed words marked, not a summary of it.
- Excel does not auto-fit row heights for cells a script wrote. A sheet that opens with clipped rows at 100% zoom on a large display does not get read.

## What the machine does now

One row per decision, four columns. Column A states the decision plainly with its options, written so someone who has not seen the code can answer. Column B is the context. Current behavior, the evidence, who decided what and when, and the current default, so an empty answer means keep it. Column C is the implications, one line per option, with the risk each way. Column D is mine.

Every row has an id that stays stable across rounds, kept in a JSON sidecar beside the workbook. The writer wraps every cell, computes row height from the text, scales the columns to fill the window at fixed proportions, and opens the workbook full screen at high zoom. It refuses to overwrite an existing workbook and refuses one that is open. A follow-up round is a new sheet in the same workbook, never a rewrite, so the workbook is an append-only history.

The reader prints each answer, marks empty ones as no answer, writes the answers to a text file and a JSON file beside the workbook, and never modifies the workbook.

Dry runs feed it. Every dry run that touches a live record writes a text document of current and proposed values with the live command, plus a sidecar row. When I answer, the answer is written into the document's decision section. Only an approved document's command runs, and the run appends the result to the same document, which is then filed with the record.

## What still needs a person

Deciding. Also reading. The sheet only works if the context column is honest and complete, and I am the one who notices when it is not. Unanswered rows carry forward with the same id. The record of a decision has to be written into the plan or the rules afterward. The spreadsheet is the input, not the archive.

## Rebuilding it

Keep it small. One script, write and read. Stable ids in a sidecar. Never write to the answer column once it has been answered. New round, new sheet. For questions about wording, use rich text to show the copy as displayed with the disputed part in bold. Tie each approval to one document with a timestamp, and re-issue anything older than the code or record it describes.
