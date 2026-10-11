---
name: school-digest
description: "Daily study digest: classes, mail, Teams, deadlines."
version: 1.0.0
author: robo
metadata:
  hermes:
    tags: [School, Digest, Daily]
    requires_toolsets: [browser]
    related_skills: [school-timetable, school-mail, school-teams, school-moodle, study-plan]
---

# School digest

## When to Use
The first wake of the day, or whenever the user asks for the digest or "what's up today".

## Procedure
Load and follow each skill with `skill_view`; the digest only reads, never acts:
1. `school-timetable`: today's classes only (with start and end, for the plan).
2. `school-moodle`: everything due in the next 7 days, plus anything overdue.
3. `school-mail`: new important mail (unread, school-related).
4. `school-teams`: Teams highlights (unread chats).

5. `study-plan`, unless it is after 20:00: plan today from what steps 1-2 found (do not
   fetch them again), and end with its bullets and its calendar question. It adds nothing to
   the calendar until the user says yes.

If a source fails or is not signed in, still report the others and add one bullet naming the
source that needs `robo signin`.

## Output
It shows in a small bubble: at most 8 digest bullets, one per item, most urgent first, and
leave out empty sources. Feel `concerned` if anything is overdue or due within 48 h, otherwise
`happy` or `calm`:

```
[[feel:concerned]]
- ⚠ **Lab report 2** overdue since Sun 12 Oct
- **Due Tue 23:59** Problem set 4 (MATH201)
- **Today** 09:00 Calculus (B2.14), 13:00 Physics lab
- **Mail** Prof Lee: Lab 3 feedback
- **Teams** PHYS101 chat: quiz moved to Thursday

**Plan for today**
- 10:45-12:15 Lab report 2
- 14:30-15:15 MATH201 problem set 4
Put these in your Robo Plan calendar?
```
