---
name: school-timetable
description: "Read this week's classes from the Outlook web calendar."
version: 1.0.0
author: robo
metadata:
  hermes:
    tags: [School, Outlook, Calendar]
    requires_toolsets: [browser]
    related_skills: [school-digest]
---

# School timetable (Outlook calendar)

## When to Use
The user asks about classes today or this week, or the digest needs today's classes.

## Procedure
1. `browser_navigate(url="https://outlook.office.com/calendar/view/week")`. Read the page
   snapshot it returns.
2. Signing in passes through `login.microsoftonline.com` for a few seconds by itself. Only if
   a snapshot (take up to 3) shows "Pick an account" with the user's school address on it,
   navigate ONCE to `https://outlook.office.com/calendar/view/week?login_hint=<that address>`; this
   picks the already signed-in account without typing anything. If a snapshot still shows a
   "Sign in", "Pick an account" or password form, stop
   and reply: "I'm not signed in to Outlook. Please run `robo signin` and sign in, then ask me
   again." Never try to sign in or pick an account.
3. Outlook can take up to a minute to load. If the snapshot shows no calendar yet, call
   `browser_snapshot()` again (at most 3 times).
4. Read the events: title, day, start and end time, location. If they are missing from the
   text, use `browser_vision(question="List every event with day, time, title and room")`.
5. To see another week, click the calendar's previous or next week button.

## Acting
Accept, decline, create or delete events only when the user asked. Writes bring up an
approval prompt for the user; if they deny, stop.

## Output
Today first, then the remaining days, one bullet per class in time order:
`- Mon 13 Oct · 09:00-10:30 Calculus (B2.14)`. Mark cancelled events as cancelled.
