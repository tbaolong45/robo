---
name: robo-notes
description: "Write drafts, plans and text as Obsidian notes."
version: 1.0.0
author: robo
metadata:
  hermes:
    tags: [Obsidian, Notes, Draft, Plan]
    requires_toolsets: [file, terminal]
    related_skills: [robo-make, study-plan, school-mail]
---

# Robo notes (drafts, plans and text in Obsidian)

## When to Use
Your answer is a DRAFT (email, message, essay), a PLAN (study plan, schedule) or TEXT (notes, a
summary, an explanation longer than a few lines). Write it as a note in the user's Obsidian
vault instead of the bubble. A quick answer or one tutoring step stays in the bubble. Things
that need a browser (diagram, chart, web page, slides, flashcards) are `robo-make`; a quiz is
`study-quiz`.

## Where
One note per request, written with `write_file` into the vault `{{VAULT}}`:
- `{{VAULT}}/Drafts/` for drafts, `{{VAULT}}/Plans/` for plans, `{{VAULT}}/Notes/` for
  everything else. Make the folder if it is missing (`terminal`: `mkdir -p`).
- File name `YYYY-MM-DD <short title>.md` with today's date, e.g. `2026-10-12 Lab 3 extension.md`.
  The title never contains `/ : # ^ [ ] | \`, and never the word `hermes` (robo-guard blocks any
  path that contains it).
- Never overwrite: `ls` the folder first and add " 2" if the name exists. Change an older note
  only when the user asks.

## Format
Obsidian Markdown, no HTML. YAML properties first (quote a value that contains `: `), then the
body. No `# Title` line: the file name is the title. Callout lines each start with `> `.
- Plan: a `> [!summary]` line first; one `## <Day>` section per day (`## Mon 12 Oct`) with a
  task checkbox per block in time order; work that did not get a slot goes in a
  `> [!warning] Didn't fit` callout (leave it out if everything fit). `date` is the first day
  planned.
- Draft: a `> [!info] Draft email` callout (or message, essay) carrying To and Subject, then the
  body as plain text, ready to copy. Only a mail draft has `to`, `subject`, `status: unsent` and
  the closing `> [!warning] Not sent` callout; a message or an essay has none of them. Sign with
  the user's name from memory, never a placeholder (the example below shows one).
- Text: a `> [!summary]` first, `##` sections, bullet lists, `> [!tip]` or `> [!example]` where
  they help, `$math$`, code fences with a language, `[[wikilinks]]` sparingly for course codes
  and people (never dates).
- `status` changes later: mail draft `unsent` to `saved in Outlook Drafts` (or `sent` if the
  user sent it), plan `proposed` to `in calendar` (`patch` that one line, only when the skill
  that did it says so).

Plan note (`{{VAULT}}/Plans/2026-10-12 Plan Mon 12 Oct.md`):
```
---
type: plan
created: 2026-10-12
tags: [robo, robo/plan]
source: robo
date: 2026-10-12
status: proposed
---
> [!summary] Two blocks today, problem set 4 first.

## Mon 12 Oct
- [ ] 10:45-12:15 [[MATH201]] problem set 4
- [ ] 14:00-14:45 PHYS101 midterm review

> [!warning] Didn't fit
> CS lab write-up (due Fri): try tomorrow morning.
```

Draft note (`{{VAULT}}/Drafts/2026-10-12 Lab 3 extension.md`):
```
---
type: draft
created: 2026-10-12
tags: [robo, robo/draft]
source: robo
to: prof.lee@uni.edu
subject: Lab 3 extension
status: unsent
---
> [!info] Draft email
> **To:** prof.lee@uni.edu
> **Subject:** Lab 3 extension

Dear Prof Lee,

Could I have until Friday for the Lab 3 report? I was ill on Monday.

Best regards,
<your first name>

> [!warning] Not sent
```

Text note (`{{VAULT}}/Notes/2026-10-12 Derivatives.md`):
```
---
type: note
created: 2026-10-12
tags: [robo, robo/note]
source: robo
---
> [!summary] A derivative is the rate of change of a function at a point.

## Definition
$f'(x) = \lim_{h \to 0} \frac{f(x+h) - f(x)}{h}$

- Geometrically: the slope of the tangent line.

> [!example] $f(x) = x^2$
> $f'(x) = 2x$, so the slope at $x = 3$ is 6.
```

## Reply
After `write_file`, check the file exists (`read_file` or `ls`) before you claim it; if the
write failed, say so. When the request is done, reply after the feeling tag in one or two
sentences: the note's title and the one thing to look at (the first block, the subject line,
the key idea). If another skill gives the reply its own shape (digest, plan), follow that. Do NOT
paste the note into the reply. Robo opens the note in Obsidian by itself when your reply ends,
so do NOT open Obsidian or the file yourself.
