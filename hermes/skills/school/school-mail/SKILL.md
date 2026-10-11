---
name: school-mail
description: "Read the Outlook web inbox; reply or act when asked."
version: 1.0.0
author: robo
metadata:
  hermes:
    tags: [School, Outlook, Mail]
    requires_toolsets: [browser]
    related_skills: [school-digest]
---

# School mail (Outlook inbox)

## When to Use
The user asks about new or important mail, or the digest needs it.

## Procedure
1. `browser_navigate(url="https://outlook.office.com/mail/inbox")`. Read the page snapshot it
   returns.
2. Signing in passes through `login.microsoftonline.com` for a few seconds by itself. Only if
   a snapshot (take up to 3) shows "Pick an account" with the user's school address on it,
   navigate ONCE to `https://outlook.office.com/mail/inbox?login_hint=<that address>`; this
   picks the already signed-in account without typing anything. If a snapshot still shows a
   "Sign in", "Pick an account" or password form, stop
   and reply: "I'm not signed in to Outlook. Please run `robo signin` and sign in, then ask me
   again." Never try to sign in or pick an account.
3. Outlook can take up to a minute to load. If the snapshot shows no message list yet, call
   `browser_snapshot()` again (at most 3 times).
4. Read the message LIST only. Each row gives sender, subject, preview, time and whether it is
   unread. The list is virtual: report what is visible and say so if there may be more.
5. Opening a message marks it read: open one only when the user needs its content, and tell
   them it now shows as read.

## Acting
Reply, forward, delete, move or flag mail only when the user asked. Writes (typing a
message, Send, Delete...) bring up an approval prompt for the user; if they deny, stop.

## Output
Unread and school-related first (teachers, courses, exams, deadlines, schedule changes); skip
newsletters and promotions. At most 8 bullets:
`- **Prof Lee** · Lab 3 feedback · grades are posted (09:12)`.
