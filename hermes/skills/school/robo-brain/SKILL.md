---
name: robo-brain
description: "Save things to the user's second brain on request."
version: 1.0.0
author: robo
metadata:
  hermes:
    tags: [Obsidian, SecondBrain, Notes, Learning]
    requires_toolsets: [file, terminal]
    related_skills: [robo-notes, study-quiz, school-posts]
---

# Robo brain (the user's second brain in Obsidian)

## When to Use
ONLY when the user asks you to keep something: "save this to my brain", "add this to my notes",
"make a reading note for this paper", "put this in my inbox", "log this for my career". Never
file anything on your own, and never as a side effect of another request: a digest, a plan, a
quiz and an answer stay as they are. The brain holds what the user learned, in their words. A
draft, a plan or a long text for them to use is `robo-notes`.

## Where
The brain is `{{VAULT}}/Brain/`, and its layout is the user's: `ls` it first.
- `Inbox/`: a quick capture, one note per item, `Inbox/YYYY-MM-DD <short title>.md`. An idea is
  an inbox note too (`Templates/Idea.md`).
- `Reading/`: one note per paper, article or book, `Reading/<title>.md`, from `Templates/Reading.md`.
- `Courses/`: one note per course, `Courses/<course>.md`. When it exists, ADD a dated `##` section
  at its end; when it does not, make it from `Templates/Course.md`.
- `Projects/`: one note per project, `Projects/<project>.md`, from `Templates/Project.md`.
- `Career/Career.md`: ONE line added under the matching heading (Skills I am building, What I did
  that counts, Opportunities I am watching).

When `Templates/<kind>.md` exists, read it and copy its shape: its date and title placeholders (in
double curly braces) become today's date and the title. Make a missing folder with `terminal`
(`mkdir -p`).
- Never overwrite. A new note: `ls` the folder first and add " 2" if the name exists. An existing
  note: append only (a section at the end, or one line) with `patch`, after you have read it:
  robo-guard records `write_file` and `patch` calls, so the card can show the filing is real (not
  a terminal `>>`). Never rewrite, reorder or delete what is there, never move, rename or delete a
  file in `Brain/`, and never touch the course files (slides, PDFs) beside the notes.
- A name never contains `/ : # ^ [ ] | \`, and never the word `hermes` (robo-guard blocks any
  path that contains it).

## Format
Obsidian Markdown, no HTML and no remote images. YAML properties first: `type` (`reading`,
`course`, `project`, `idea` or `note`), `created`, `tags: [brain, brain/<kind>]`, `source: robo`.
Then a `> [!summary]` line, and no `# Title` line: the file name is the title.
- Learning comes first. What you write is a short, plain draft of what the user gave you or what
  the source says, under `> [!note] Draft by Robo: rewrite it in your own words.` The sections
  that are the user's thinking (`A question I still have`, `My notes and questions`, `Test
  myself`, `Why it matters to me`) stay empty for them to fill.
- Never put the answers to graded work (an assignment, a quiz, an exam question) in the brain,
  and never make a note that does a graded task for the user.
- Write only what the user said or what a source says. Never invent a source, a date or a
  quotation; a field you do not know stays blank.
- `[[wikilinks]]` only to notes that exist (check with `ls`), never to dates.

## Reply
After the write or the append, check the file (`read_file` or `ls`) before you claim it; if it
failed, say so. When it is done, reply after the feeling tag in one or two sentences: where it
went (the folder and the title) and the ONE thing for the user to fill in or check. Robo opens
the note in Obsidian by itself when your reply ends, so do NOT open Obsidian or the file.
