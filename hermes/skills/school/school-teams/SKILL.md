---
name: school-teams
description: "Scan Teams web chats for course news, read-only."
version: 1.0.0
author: robo
metadata:
  hermes:
    tags: [School, Teams, Chat]
    requires_toolsets: [browser]
    related_skills: [school-digest]
---

# School Teams (chat list, read-only)

## When to Use
The user asks about Teams messages or announcements, or the digest needs Teams highlights.
Course announcements live in CHATS, not in teams or channels.

## Procedure
1. `browser_navigate(url="https://teams.microsoft.com/")`. Read the page snapshot it returns.
2. Not signed in? If the page is `login.microsoftonline.com`, or shows "Sign in" or "Pick an
   account", stop and reply: "I'm not signed in to Teams. Please run `robo signin` and sign
   in, then ask me again." Never try to sign in.
3. Teams takes 10-30 s to start. If the snapshot shows a splash screen, call
   `browser_snapshot()` again (at most 3 times).
4. If the chat list is not visible, click the "Chat" item in the left rail ONCE. Teams then
   opens the most recent chat by itself, which marks that one chat read; this is known and
   accepted. Never click any chat in the list.
5. Read the chat LIST only. Each row gives chat name, last message preview, time and unread
   state. Report what is visible.

## Do Not
Click a chat, type anywhere, send, reply, react, like, post, start a call, join a meeting, or
change any setting or status. Do not press keys.

## Output
Unread chats first, then the rest with news from today, at most 6 bullets:
`- **PHYS101 class chat** (10:05): quiz moved to Thursday`.
