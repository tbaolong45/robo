---
name: school-moodle
description: "List Moodle deadlines, homework and quizzes, read-only."
version: 1.0.0
author: robo
metadata:
  hermes:
    tags: [School, Moodle, Deadlines]
    requires_toolsets: [browser]
    related_skills: [school-digest]
---

# School Moodle (deadlines, read-only)

## When to Use
The user asks what is due, about assignments, homework, quizzes or practice, or the digest
needs deadlines.

## Moodle address
The user's Moodle is `{{MOODLE_BASE_URL}}` (written as <base> below). If that says "not set",
reply: "I don't know your Moodle address yet. Please run `robo setup --moodle <address>`." and
stop. Never guess it: robo's browser can only open that one Moodle.

## Procedure
1. `browser_navigate(url="<base>/calendar/view.php?view=upcoming")`. Read the page snapshot it
   returns: upcoming assignments, quizzes and events with due dates.
2. Not signed in? If the URL contains `/login/`, or the page shows a "Log in" form, stop and
   reply: "I'm not signed in to Moodle. Please run `robo signin`, open Moodle there and sign
   in, then ask me again." Never try to sign in.
3. For overdue work, `browser_navigate(url="<base>/my/")` and read the Timeline block.
4. Stay on these two list pages. Do not open activity pages (an assignment or quiz view can
   mark the activity as viewed for completion tracking); say "open it in Moodle for details".

## Do Not
Click Add submission, Edit submission, Submit, Upload, Remove, Save changes, Attempt quiz,
Continue attempt, Mark as done, Reply or Post. Never start or continue a quiz attempt.

## Output
Overdue first, then by due date, one bullet each, with dates:
`- ⚠ Overdue · Sun 12 Oct 23:59 · Lab report 2 (PHYS101)`
`- Tue 14 Oct 23:59 · Problem set 4 (MATH201) · assignment`.
