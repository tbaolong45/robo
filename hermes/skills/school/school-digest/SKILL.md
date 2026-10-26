---
name: school-digest
description: "Daily study digest: classes, mail, Teams, deadlines."
version: 1.0.0
author: robo
metadata:
  hermes:
    tags: [School, Digest, Daily]
    requires_toolsets: [browser]
    related_skills: [school-timetable, school-mail, school-teams, school-moodle, study-plan, study-ledger, robo-notes]
---

# School digest

## When to Use
The first wake of the day, or whenever the user asks for the digest or "what's up today".

## Procedure
Load and follow each skill with `skill_view`; the digest only reads and never acts for the
user (it writes no file; a note only if the user asks, with `robo-notes`):
1. `school-timetable`: today's classes only (with start and end, for the plan).
2. `school-moodle`: everything due in the next 7 days, plus anything overdue.
3. `school-mail`: new important mail (unread, school-related).
4. `school-teams`: Teams highlights (unread chats).

5. `study-plan`, unless it is after 20:00: plan today from what steps 1-2 found (do not
   fetch them again). It lists the blocks in the digest (its chat format) and adds nothing to
   the calendar until the user says yes; no plan note is written unless the user asks for one.
6. `study-ledger`, **Exam readiness** (never Moodle course pages here): for the nearest exam
   within 14 days, ONE bullet with its colour and weakest topic. It is the day's one nudge, so
   no second bullet and no reminders. Leave it out outside 08:00-22:00, and while the ledger
   has `snooze nudges until <date>` with today before that date.

If a source fails or is not signed in, still report the others and add one bullet naming the
source that needs `robo signin`.

## Output
It shows in the chat: at most 8 digest bullets, one per item, most urgent first, and
leave out empty sources (after 20:00 there is no plan: leave out the **Plan** line and the
calendar question). Feel `concerned` if anything is overdue, due within 48 h or red for an
exam, otherwise `happy` or `calm`:

```
[[feel:concerned]]
- ⚠ **Lab report 2** overdue since Sun 12 Oct
- **Due Tue 23:59** Problem set 4 (MATH201)
- **Today** 09:00 Calculus (B2.14), 13:00 Physics lab
- **Mail** Prof Lee: Lab 3 feedback
- **Teams** PHYS101 chat: quiz moved to Thursday
- **Ready?** MATH201 midterm in 4 days: amber, last quiz 60%, weakest eigenvalues

**Plan** (2 blocks today):
**10:45-12:15** Lab report 2
**14:00-15:00** MATH201 problem set 4
Put the plan in your Robo Plan calendar?
```
