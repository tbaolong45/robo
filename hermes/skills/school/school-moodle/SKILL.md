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
Use the Moodle base URL saved in your memory (for example `https://moodle.example.edu`). If
memory has none, ask the user once ("What is your Moodle address?"), save it with the `memory`
tool as "Moodle base URL: <url>", then continue. Never guess it.

## Procedure
1. `browser_navigate(url="<base>/calendar/view.php?view=upcoming")` for upcoming assignments,
   quizzes and events with due dates.
2. Not signed in? If the URL contains `/login/`, or the page shows a "Log in" form, stop and
   reply: "I'm not signed in to Moodle. Please sign in in Brave, then ask me again." Never try
   to sign in.
3. `browser_snapshot(full=true)` and read each item: name, course, type, due date and time.
4. For overdue work and submission status, `browser_navigate(url="<base>/my/")` and read the
   Timeline. Opening an activity page (assignment or quiz view) to read its status is fine.

## Do Not
Click Add submission, Edit submission, Submit, Upload, Remove, Save changes, Attempt quiz,
Continue attempt, Mark as done, Reply or Post. Never start or continue a quiz attempt.

## Output
Overdue first, then by due date, one line each, with dates:
`• ⚠ Overdue · Sun 12 Oct 23:59 · Lab report 2 (PHYS101) · not submitted`
`• Tue 14 Oct 23:59 · Problem set 4 (MATH201) · assignment`.
