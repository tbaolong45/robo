---
name: school-teams
description: "Read Teams web chats for course news; post when asked."
version: 1.0.0
author: robo
metadata:
  hermes:
    tags: [School, Teams, Chat]
    requires_toolsets: [browser]
    related_skills: [school-digest]
---

# School Teams (chats)

## When to Use
The user asks about Teams messages or announcements, or the digest needs Teams highlights.
Course announcements live in CHATS, not in teams or channels.

## Procedure
1. `browser_navigate(url="https://teams.microsoft.com/")`. Read the page snapshot it returns.
2. Signing in passes through `login.microsoftonline.com` for a few seconds by itself. Only if
   a snapshot (take up to 3) still shows a "Sign in", "Pick an account" or password form, stop
   and reply: "I'm not signed in to Teams. Please run `robo signin` and sign in, then ask me
   again." Never try to sign in or pick an account.
3. Teams takes 10-60 s to start. While the snapshot shows a spinner, "We're setting things up
   for you" or no app bar, call `browser_snapshot()` again (at most 6 times). Clicks made
   before that are lost.
4. When it is ready, `browser_press(key="Control+Shift+2")` ONCE (Teams' shortcut for Chat;
   clicking the app bar is unreliable), then `browser_snapshot()` until the chat list shows
   (at most 3 times). Teams opens the most recent chat by itself, which marks that one chat
   read; this is known and accepted.
5. Read the chat LIST. Each row gives chat name, last message preview, time and unread state.
   Report what is visible. Opening a chat marks it read: open one only when the user asks
   about it, and say so.

## Acting
Post, reply, react, call or change the user's status only when the user asked for exactly
that.

## Output
Unread chats first, then the rest with news from today, at most 6 bullets:
`- **PHYS101 class chat** (10:05): quiz moved to Thursday`.
