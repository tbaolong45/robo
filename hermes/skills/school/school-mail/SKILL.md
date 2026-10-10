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
1. `browser_navigate(url="https://outlook.office.com/mail/inbox")`.
2. Not signed in? If the page is `login.microsoftonline.com`, or shows "Sign in" or "Pick an
   account", stop and reply: "I'm not signed in to Outlook. Please sign in in Brave (passkey),
   then ask me again." Never try to sign in.
3. Read the message LIST only: `browser_snapshot(full=true)`. Each row gives sender, subject,
   preview, time and whether it is unread. `browser_scroll(direction="down")` once or twice
   for more.
4. Opening a message marks it read. Open one only when the user explicitly asks for that
   message; otherwise answer from the list.

## Do Not
Click Reply, Reply all, Forward, Delete, Archive, Move, Flag, Pin, Mark as read or unread,
Sweep, Report or New mail. Do not press letter shortcuts or type anywhere except Search.

## Output
Unread and school-related first (teachers, courses, exams, deadlines, schedule changes); skip
newsletters and promotions. At most 8 lines:
`• **Prof Lee** · Lab 3 feedback · grades are posted (09:12)`.
