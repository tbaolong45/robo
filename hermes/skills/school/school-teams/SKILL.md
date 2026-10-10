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
1. `browser_navigate(url="https://teams.microsoft.com/")`.
2. Not signed in? If the page is `login.microsoftonline.com`, or shows "Sign in" or "Pick an
   account", stop and reply: "I'm not signed in to Teams. Please sign in in Brave (passkey),
   then ask me again." Never try to sign in.
3. If the chat list is not visible, `browser_click` the "Chat" item in the left rail.
4. Read the chat LIST only: `browser_snapshot(full=true)`. Each row gives chat name, last
   message preview, time and unread state. Use `browser_scroll(direction="down")` for more.
5. Opening a chat marks it read. Open one only when the user explicitly asks for that chat.

## Do Not
Type in a message box, send, reply, react, like, post, start a call, join a meeting, or change
any setting or status. Do not press keys other than Tab, Escape or Enter.

## Output
Unread chats first, then the rest with news from today, at most 6 lines:
`• **PHYS101 class chat** (10:05): quiz moved to Thursday`.
