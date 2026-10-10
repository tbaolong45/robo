---
name: school-digest
description: "Daily study digest: classes, mail, Teams, deadlines."
version: 1.0.0
author: robo
metadata:
  hermes:
    tags: [School, Digest, Daily]
    requires_toolsets: [browser]
    related_skills: [school-timetable, school-mail, school-teams, school-moodle]
---

# School digest

## When to Use
The first wake of the day, or whenever the user asks for the digest or "what's up today".

## Procedure
Load and follow each skill with `skill_view`, read-only as they say:
1. `school-timetable`: today's classes only.
2. `school-moodle`: everything due in the next 7 days, plus anything overdue.
3. `school-mail`: new important mail (unread, school-related).
4. `school-teams`: Teams highlights (unread chats).

If a source fails or is not signed in, still report the others and name the source that needs
the user to sign in in Brave.

## Output
Short and scannable, at most about 12 lines, sections without a heading when empty. Feel
`concerned` if anything is overdue or due within 48 h, otherwise `happy` or `calm`:

```
[[feel:concerned]]**Today** · 09:00 Calculus (B2.14) · 13:00 Physics lab
**Due** · ⚠ Lab report 2, overdue since Sun 12 Oct · Problem set 4, Tue 14 Oct 23:59
**Mail** · Prof Lee: Lab 3 feedback
**Teams** · PHYS101 chat: quiz moved to Thursday
```
