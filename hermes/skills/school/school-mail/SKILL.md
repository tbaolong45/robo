---
name: school-mail
description: "Scan the Outlook web inbox list without opening mail."
version: 1.0.0
author: robo
metadata:
  hermes:
    tags: [School, Outlook, Mail]
    requires_toolsets: [browser]
    related_skills: [school-digest]
---

# School mail (Outlook inbox list, read-only)

## When to Use
The user asks about new or important mail, or the digest needs it.

## Procedure
1. `browser_navigate(url="https://outlook.office.com/mail/inbox")`. Read the page snapshot it
   returns.
2. Not signed in? If the page is `login.microsoftonline.com`, or shows "Sign in" or "Pick an
   account", stop and reply: "I'm not signed in to Outlook. Please run `robo signin` and sign
   in, then ask me again." Never try to sign in.
3. Outlook can take up to a minute to load. If the snapshot shows no message list yet, call
   `browser_snapshot()` again (at most 3 times).
4. Read the message LIST only. Each row gives sender, subject, preview, time and whether it is
   unread. The list is virtual: report what is visible and say so if there may be more.
5. Opening a message marks it read. Never open one unless the user explicitly asks for that
   message, and then tell them it will now show as read.

## Do Not
Click Reply, Reply all, Forward, Delete, Archive, Move, Flag, Pin, Mark as read or unread,
Sweep, Report or New mail. Do not type anywhere or press letter shortcuts.

## Output
Unread and school-related first (teachers, courses, exams, deadlines, schedule changes); skip
newsletters and promotions. At most 8 bullets:
`- **Prof Lee** · Lab 3 feedback · grades are posted (09:12)`.
