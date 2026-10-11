---
name: school-mail
description: "Read the Outlook inbox; draft or act when asked."
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
The user asks about new or important mail, the digest needs it, or the user asks to draft,
write or send an email.

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

## Drafting
For "draft/write an email to X about Y":
1. You need X's address. If you only have a name, find it in a mail from them (or ask); never
   guess. Write a short subject and body in the user's voice.
2. `browser_navigate(url="https://outlook.office.com/mail/deeplink/compose?to=<addr>&subject=<subject>&body=<body>")`,
   every value URL-encoded (spaces `%20`, new lines `%0A`). Sign-in pages: steps 2-3 above,
   then open the compose link again.
3. `browser_snapshot()` until the compose form shows (at most 3 times). Check To, Subject and
   body; fix any wrong or empty field with `browser_type`.
4. Leave it as a DRAFT. A form that was only prefilled is NOT saved by Outlook: click into the
   body, type one space (`browser_type` appending " "), wait ~5 s for "Draft saved", then
   close the compose with `browser_press(key="Escape")`. Never click "Discard".
5. Verify before you claim it: `browser_navigate(url="https://outlook.office.com/mail/drafts")`
   and find a row "[Draft] <recipient> <subject>". If it is not there, say so and try once
   more. Then tell the user it is in their university Outlook Drafts (not Gmail), with the
   subject, and offer to send it.

NEVER click Send unless the user's request explicitly says "send" (then check the fields once
more first). For a reply, open the message and use its Reply the same way: draft unless told
to send.

## Acting
Reply, forward, delete, move or flag mail only when the user asked.

## Output
Unread and school-related first (teachers, courses, exams, deadlines, schedule changes); skip
newsletters and promotions. At most 8 bullets:
`- **Prof Lee** · Lab 3 feedback · grades are posted (09:12)`.
