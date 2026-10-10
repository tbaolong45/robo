# Personal Learning Intelligence

Gathers your university learning materials, deadlines and **Teams channel posts**
from **Moodle** and **Microsoft Teams**, then writes a **fully time-blocked study
week** into a dedicated Outlook calendar — working around your real class
timetable.

It reads all of that by driving a real browser, not an API. That choice is
explained below, because it is the single most consequential thing about how this
tool works.

## Design in one paragraph

An LLM is genuinely useful for three things here: deciding what matters most,
estimating how long something will actually take, and breaking a task into
pieces. It is *unreliable* at satisfying hard constraints. So the split is
explicit: **the model judges, Python schedules.** `planner/score.py` asks the
model for priority and duration; `planner/pack.py` places the sessions with pure
arithmetic. That means a study block can never overlap another, land inside a
lecture, fall outside your study hours, or exceed a daily cap — regardless of how
confused the model gets. It also means a cheap flash-tier model is entirely
sufficient, and an LLM outage degrades the plan rather than breaking it.

The same split governs reading a page. Which text on a calendar row is the start
time is a *judgement*, so it goes to the model; what the datetime is, which day
it falls on, and whether a block fits are arithmetic, and stay in Python where
they are testable.

## Why the browser instead of the API

The obvious way to read Outlook and Teams is **Microsoft Graph**, and an earlier
version of this tool did exactly that. It was abandoned, for two reasons that are
not fixable in code:

- **An app registration is required**, and it has to live in a tenant somebody
  administers. A student does not administer their university's tenant. Signing
  in against the university tenant then hits `AADSTS65001: consent required` if
  that tenant does not permit user consent — an IT policy decision, not a bug.
- **Graph cannot read Teams channel messages** without delegated
  `ChannelMessage.Read.All`, which always needs tenant admin consent. A student
  cannot self-consent it. That is the one place a lecturer writes "the deadline
  moved to Friday".

A browser has neither problem. It reads everything the signed-in user can see,
and needs no registration, no tenant, and nobody's permission but your own.

The trade is real, and it is not in the browser's favour on every axis:

- **Reach** — everything you can see, this can read. That includes Teams posts.
- **Setup** — nothing to register, nothing to consent to. You sign in once, by
  hand, into a Chromium profile the tool reuses.
- **Exactness and stability** — worse, and unavoidably so. Graph was documented
  and versioned; a web page is neither. Microsoft can restyle Outlook tomorrow
  and a selector stops matching. That is not a hypothetical failure mode: it is
  the expected one, and the rest of this section is about making it survivable.
- **Volume and speed** — a browser is slower than a REST call, and it reads what
  is on screen rather than the whole of a mailbox. The planner only needs the
  planning horizon, which is exactly what the Outlook week view shows.

## When a page changes

Two things absorb a redesign, and neither is a code change.

**Selectors are configuration.** Every query against Microsoft's markup lives in
`config/browser.toml`, read by `browser/selectors.py`. When Outlook renames a
button, that file is where the fix goes. Two rules apply to the values:

- Prefer the accessible name — `role=button[name="New event"]` survives a
  restyle, because a screen reader still has to announce it. `data-tid`
  attributes are internal ids Microsoft renames at will, so they are the
  fallback, never the first choice.
- A value is a Playwright selector, not plain CSS, which is what lets the
  accessible-name form live in a string.

**Failures leave evidence.** When a reader cannot make sense of a page, it does
not silently return nothing — an empty week is the one wrong answer this tool
must never give, because the planner would then fill your real timetable with
study blocks. Instead it writes the page to `data/diagnostics/` as four files
`<UTC timestamp>-<label>.html`, `.png` (full page screenshot), `.txt` (the
visible text) and `.url` (the address the browser was actually on), and the error
names the path it saved to. Send those files back and the selectors can be fixed
against the actual markup rather than a guess. The `.url` is there because the
two causes of a reader that stopped matching — a restyled page, and a page that
is not the one we asked for — look identical in the HTML, and only the address
tells them apart.

## Install

```bash
uv sync --extra dev
cp .env.example .env      # then fill in LLM_API_KEY and TYPESAFE_API_KEY
uv run playwright install chromium
```

Two keys, and only one of them is required to run anything:

- `TYPESAFE_API_KEY` — the judgement layer that reads page content. Get one at
  <https://console.typesafe.ai/keys>. Every reading command needs it, and `pli`
  says so plainly if it is missing rather than failing somewhere inside a page
  read.
- `LLM_API_KEY` — the text model (`LLM_BASE_URL`, `LLM_MODEL`): it scores tasks, and in
  `pli agent` it writes the mail summaries and answers questions. Optional: without it the
  planner falls back to deterministic heuristics and still produces a week, and the agent
  still labels your mail but writes no summaries.

### Signing in

There is no login command, because there is no account to register. `pli` reuses
the persistent Chromium profile at `BROWSER_PROFILE` (`data/browser` by default),
and whatever session already lives there is the session it uses.

- `BROWSER_HEADLESS=true` (the default) — no window. This is the normal mode, and
  the only one a scheduled run can use.
- `BROWSER_HEADLESS=false` — a real window opens. **This is how you sign in**: set
  it, run any reading command, complete the sign-in in the window that appears
  (MFA and all), and the profile keeps that session for every later run. Do it
  once.

Run `pli status` to see which profile is in use and whether it looks signed in. A
profile with no cookies is reported as such; if a read then fails, the error says
the session is not signed in and points back at `BROWSER_HEADLESS=false`.

## Use

```bash
uv run pli status         # what is configured, what is stored
uv run pli sync           # pull courses, deadlines, materials, Teams posts
uv run pli plan           # dry run: print the week, change nothing
uv run pli apply          # commit the week to the Study Plan calendar
uv run pli agent -n 40    # chat: read, sort and summarise your Outlook inbox (read-only)
uv run pli agent --voice  # same, but you can talk instead of type (see Voice below)
uv run pli agent --window # same, with a small status window (see Status window below)
```

`pli agent` is a prompt, not an app. Type `read my mail`, then things like `show the
deadline emails` or `show what you are unsure about`. You can also just ask a question -
`what is the capital of France`, or, after reading the mail, `which of my emails need
action` - and DeepSeek answers in text, on any subject, up to about 250 words (up to 1000 if you ask for a
length, and when you name a word count such as `a 500-word essay` and the first draft comes back
well short, it is sent back once to be lengthened; it is told today's date, so `what day is it` and `open today` mean something; it sees
only the labels and one-line summaries of mail you already fetched, never the raw
messages). A question that needs live information - `what is the weather in Hanoi right
now`, `who won the match last night`, `search the web for ...` - or an address
(`what does https://example.org say`) makes it look on the web instead (see Web lookups
below). So does a question whose answer is a specific fact an authority states - a law, a
rate or fee, a recommended amount, a standard, an official statistic, a software version, a
paper, Act or book it does not recognise - or one that names a source (`according to the CDC`):
it is checked on the web even when the model thinks it remembers (60% of such questions were
looked up before this, 98% and 92% on two sets since; explanations, maths, code, writing help and
facts that never change are still answered directly - 2 of 116 were searched; a checked answer takes
10-25 seconds instead of 2-8). It then
tells you what the pages say, or that it found nothing, rather than asking you to type `search
the web for ...` yourself; an answer that comes back empty or stops in the middle is asked for once more, as plain text. Ask a mail question before reading the mail and it tells you to say `read my mail`
first. Two models, two jobs: **Jev** sorts each
message into deadline, important, security, event, notification, newsletter, promotion,
spam or other - and, because it returns a calibrated confidence, anything it is not sure of
is listed separately for you to look at, never guessed - while **DeepSeek** writes the
one-line summary Jev cannot. Jev also decides which tool your request asks for. The
agent reads the inbox *list* and never opens a message, because Outlook marks a
selected message read - your unread markers stay as they were. The summary therefore
comes from the row (sender, subject and the first words of the body), not the full
message.

**Your mail text is sent to two services:** TypeSafe (the label) and the model in
`LLM_BASE_URL` (the summary; DeepSeek, directly or through OpenRouter), one request per
message to each. Raw messages are never sent together, so a hostile one cannot reach the
rest; the summary prompt wraps each as untrusted data. **Every line you type or say goes
to Jev** to choose the tool (the line before it too, so `and yesterday?` works as a
follow-up), and a question you ask sends the last few exchanges plus the label and
one-line summary of each fetched mail to the text model - a summary can repeat what its
mail said. Nothing either model says causes an action - the agent has no write tool for
your mailbox or calendar. If the summariser is down you still get the labels, with a note that the
summaries are missing; if Jev is down the read fails rather than showing a digest of
"unsure" rows.

The categories and the 0.7 confidence floor were set on one inbox and have not been
checked against mail you labelled, so treat the labels as a first pass.

### Web lookups

When a question needs live information, or you name a web address, the agent reads a few
public pages and answers from them, naming its sources: `[1]`, `[2]` in the answer and the
addresses under it. Jev decides this from the line you typed, like every other tool.

1. **Finding pages.** DeepSeek turns what you typed (and the three lines before it, so `look it up`
   and `and tomorrow?` work) into a short search query, which is printed first so you can
   see what is sent. OpenRouter's web-search plugin (Exa, "instant" mode) returns the
   addresses. That is why this needs `LLM_BASE_URL` to be OpenRouter; opening an address you
   typed works with any endpoint. The search costs about $0.007 on your OpenRouter credit,
   plus the (small) tokens.
2. **Reading pages.** The search sends five results; DeepSeek picks the three most worth reading
   from their titles and addresses alone (no excerpt or page text) - the body that publishes the
   facts itself (a government, regulator, standards body, university, or a project's or
   company's own site) before references, and those before blogs, agencies and forums - and if
   that fails the search's own order is used. Judged blind against the search's own order on 60
   fact questions (300 sources, two independent labellers who agreed on 297), 73% of the sources
   read were primary before and 80% are now (a perfect pick of the five would be 82%), and the
   weak ones (SEO, agencies, forums) fell from 20 to 15 of 180. The three are read at the same time,
   each in its own throwaway
   headless Chromium, which takes the main text (navigation, scripts and hidden elements
   are dropped; about 650 words are kept) and closes. It is **never** your signed-in
   `data/browser` profile: no cookies, no downloads, no service workers. The agent only opens
   pages - it never clicks, signs in or fills anything in (a page's own scripts do run). A page
   that will not open, or opens to almost nothing (many sites refuse a headless browser, or show
   a cookie wall), falls back to the excerpt the search gave for it.
3. **Following links.** The pages come with a numbered list of their links, navigation menus
   included. If the answer is not on them, or you asked it to find a particular page ("go to
   python.org and find the downloads page"), DeepSeek can ask for up to two of those links to be
   opened, for at most two rounds, and then answers from everything read. It can only choose from
   the list: the addresses come from the page, never from the model, and a link already read, or
   one that gave nothing, is not opened again. Each link opened is shown as `Following: ...`.
   Opening a link is reading an address.

   It can also use a site's own search: pages list their search boxes, and the model may ask for
   some text to be typed into one (`Searching the site: Search the library - machine learning`),
   after which Enter is pressed and the page that comes back is read. Only a visible plain text or
   search box that submits as a GET qualifies - never a password, e-mail, card, code or login field
   (judged by its name, label and hints), a form that posts or goes to a login or payment page, or
   a file, hidden or invisible input - and at most one search per round. While it types, the
   browser refuses every request that is not a GET or HEAD, whatever the page's own script or
   buttons try, so nothing is submitted that could change something; a site whose search works
   only by POST is therefore not supported. The agent still never clicks a button, fills in any
   other form or signs in: those can do things (buy, post, sign in) and this agent only reads.
4. **Answering.** DeepSeek gets the page text inside `<web_pages>` tags, told to treat it as
   data and never follow instructions in it, and to answer from its own knowledge **combined**
   with the pages: exact or current facts (a figure, a date, a rule in force) from the pages with
   their numbers, background and anything the pages do not cover from what it knows, said to be
   general knowledge. Official and primary sources (a government, regulator, standards body,
   university, or a project's or company's own site) count for more than blogs, agencies and
   forums, judged by the address; where pages disagree it goes with the more official and more
   recent, says they differ, and says so when only an unofficial page contradicts what it
   remembers. Mail and activity counts are not part of the request, and the answer is not
   remembered for later questions.

**What leaves this machine:** your typed question (as a search query) to OpenRouter and Exa;
requests from the throwaway browser to the sites it opens, including the search words the model
typed into a site's search box (the model chooses them, from your question and the pages); the
question and the page text to DeepSeek, which also gets the titles and addresses (no excerpts)
of the search results to pick from. Set `WEB_ENABLED=false` to turn lookups off (the agent then says web browsing is not
available).

**Only public websites are reached.** The browser has one way out: a small proxy the agent runs on
127.0.0.1 for the length of the lookup. For every connection - the page, each redirect, every
image, script and WebSocket - the proxy looks the name up itself, refuses unless *every* address
it resolves to is public (not `localhost`, your router, other computers on your network, carrier
NAT, multicast, or an IPv6 form wrapping an IPv4 address), and then connects to the address it
checked, not to the name, so a name cannot point somewhere else a moment later. An address you
type, or a search result, that is plainly not public is turned away before a browser is even
started. (A check inside the browser cannot do this: Chromium follows an HTTP redirect without
asking, so a public page could still make the browser send a request to `localhost`.) The
sources shown are printed by the code from the pages actually read, not by the model.

**Limits.** The check that decides which boxes are plain search boxes runs inside the page, so a
hostile page can lie to it; the GET-only rule above is what actually keeps typing harmless, and
the text typed is only ever search words the model chose. One question can start up to nine
browsers (three for the first lookup, then up to two links and one search in each of two rounds).
Search engines' own result pages are not used: they ask automated browsers for a
CAPTCHA, and getting round that is not something this agent does. A site can still block the
browser (w3.org answers it with a challenge page, for one), ask for a login or take longer than 10
seconds - it is then skipped, and if you gave the address the agent says that page did not load or
may not allow automated browsers. An address whose name does not exist is reported as such (check
the spelling), apart from a private or local one, which is refused as "not a public website". A page whose own
script never finishes is given up on after about 25 seconds, and its tab keeps spinning until you
quit the agent. A lookup takes roughly 5 to 30 seconds (the search is the variable part). The
answer is only as good and as current as the pages.

### Voice

`pli agent --voice` lets you talk to the same prompt. **Typing still works** - a line you
type is used exactly as typed. **Press Enter on an empty line to start listening, and
Enter again to stop**; what was heard is printed (`Heard: "..."`) and then handled like a
typed line. There is no wake word and the microphone is never open between the two
presses; it needs the terminal in focus.

Speech-to-text runs **on this machine** (faster-whisper, model `STT_MODEL`, default
`base.en`, ~145 MB downloaded on first use). Your voice is never uploaded and never
written to disk; only the resulting text goes on to the agent. A recording that is too
quiet or too short is dropped before the model sees it, because Whisper answers silence
with fluent nonsense. Spoken replies are not implemented: answers are printed.

One-time setup (the system library needs `sudo`, so it is not done for you):

```bash
sudo apt install libportaudio2
uv sync --extra voice
```

Measured here on `base.en`, CPU, int8: about 0.8 s to transcribe a 3-11 s clip once the
model is loaded (about 20 s the first time, including the download), 400 MB of RAM. The
silence threshold (`SILENCE_RMS` in `src/pli/voice.py`) is a starting value that has not
yet been calibrated against your microphone.

The first press after the microphone has been idle takes a couple of seconds ("Opening the
microphone..."); `Listening` appears once audio is flowing, or after at most 1.5 s, so wait
for it. A recording keeps at most the first 15 seconds.

**Anything the microphone hears between the two presses reaches the agent as text** - other
people, a video - and the agent acts on it like a typed line. A spoken "read my mail" in the
room would start a read. The agent only reads, the `Heard:` line shows what it took, and
Ctrl-C stops it.

**Check your input gain.** On the machine this was built on, the internal microphone had
both its capture level and its mic boost at maximum (about +60 dB), which saturates the
input: the noise level read 0.44-0.65 of full scale in a quiet room, far above the silence
threshold, so silence is not recognised and speech is distorted. If you see the same
(`amixer -c <card> sget Capture` and `sget 'Internal Mic Boost'`), lower them, for example
`amixer -c 2 sset 'Internal Mic Boost' 1` and `wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 0.5`.
Browsers and call apps with automatic gain can raise the level again. When a recording
looks overdriven (1% or more of it clipped, or a level above 0.4), the agent says so before
transcribing it: at that gain 3 seconds of room sound came back as fluent text, so treat a
`Heard:` line you did not say with suspicion.

### Deadlines (your weekly goal)

A goal here is **"everything due this week is handled"**. Each time you `read my mail`, the
agent looks for the three notices your LMS sends - `Due on Friday, 9 October 2026, 10:15 AM:
Lab 6 Submission`, `Overdue: ...` and `You have submitted your assignment submission for ...` -
and keeps them in `data/deadlines.db` (mode 0600). Then:

- `what is due this week`, `show the deadlines`, `what is overdue`: a numbered list, overdue
  first, with this week's progress ("This week: 1 of 3 handled").
- `mark 2 done` ticks an item off; `undo 2` reopens it. A submission **receipt** from the LMS
  closes an assignment on its own and cannot be undone: it is evidence, not an opinion.

Marking is deliberately strict, because a wrong tick would spoil the progress count. The
number must name an item of the list you were last shown (`mark 2 done`, `undo 3`, `tick off
number one`); "I finished lab 6" does **not** mark item 6, and "mark 2 and 3 done" is refused -
one at a time; a negation ("I haven't finished 3") never marks. Say `what is due` first, so
you and the agent mean the same item 2. No model reads the deadline list and nothing is
written to your mailbox or the planner: these items are not fed to `pli plan`, which would
schedule study blocks for every row it holds.

Only the exact LMS templates count, and only when the mail comes from `DEADLINE_SENDER`
(default `LMS`, the sender name exactly as your inbox shows it) and the notice opens the
subject: a teacher's sentence containing "due on Friday", or the same words in a message
preview, is not a notice. If your LMS words them differently or sends under another name,
nothing is tracked rather than something guessed. The inbox list carries the sender's
*display name*, not the address, so a mail that copies that name could still add or close an
item - which is why the list is only a note on this computer. Assignments not mentioned for
60 days are forgotten, unless they are still due ahead. A title ends where the inbox's
received-time begins, so a title that itself contains a time ("closes 5:00 PM") is cut there.

### Status window

`pli agent --window` (with or without `--voice`) opens a small window that follows the
conversation: a circle that is blue while listening, teal when it has heard you, amber
while it works and green with the reply, plus the line it heard and the reply text. It
is a separate process that only receives short text messages from the terminal - what you
said, the reply and status lines, never a mail row - so closing it, or it failing to open (no desktop session, no Tk), never
affects the agent: you get one note and carry on in the terminal. It needs no extra
install; Tk comes with the project's Python.

On GNOME under Wayland a plain app cannot choose its position or keep itself on top, so
place the window once by hand, and pin it from its title-bar menu if you want it to
stay above other windows.

### Activity watching (opt-in)

`uv run pli watch` counts what you do on this machine, so you can ask the agent "what did I
work on this week?". It is **off until you run it**, it prints what it does before it
starts, and it stops with Ctrl-C. Every minute it notes whether you were active, and every
5 minutes it counts the last 24 hours of git commits, edited files and visits to a short list
of sites.

- **Counted:** active minutes (keyboard or mouse input in the last 2 minutes with the screen
  unlocked - *not* time spent studying), commits per repository folder, files edited, and
  visits to the sites in `ACTIVITY_DOMAINS`.
- **Never stored:** page titles, URLs, search terms, file names, commit messages, shell
  commands, screenshots. The only text in the database is a repository folder name or an
  allowlisted domain; everything else in your browser history is discarded.
- **Where:** `data/activity.db`, mode 0600, one table of `(day, hour, kind, key, n)`; rows
  older than `ACTIVITY_RETENTION_DAYS` (30) are deleted every cycle while `pli watch` runs,
  even paused. Your browser's history file is never opened in place: a private copy is read
  and deleted straight away (one left by a killed scan is removed by the next).
- **Pause:** `uv run pli watch --pause` (and `--resume`) works on a running watcher;
  `--status` shows the state, as does `pli status`.
- **Asking the agent:** `what did I work on today` sends a per-day summary to the language
  model (`LLM_BASE_URL`): the counts, plus the repository folder and site names (chosen by
  other people, so sent as untrusted data). It is sent only for a question about your
  activity, and an activity answer is never sent along with a later mail or general question.
- **Where it looks:** repositories and edited files under `ACTIVITY_ROOTS` (default
  `~/logrian`); the history file is Brave's default profile unless `ACTIVITY_HISTORY_PATH`
  names another Chromium-style `History` file. Each sample is one minute, so the sampling
  interval is not a setting.

What it cannot tell you: what you worked *on*, only how much and where (commits, files,
sites). Brave's per-visit durations are not used because they measure how long a tab was
open, not attention. Idle time comes only from the GNOME idle monitor; other desktops give
none. Visit counts need a Chromium-style history file (Brave by default). Nothing is installed to run it
all day. To keep it running, use `tmux`, or a systemd user service. This unit text passes
`systemd-analyze --user verify`, and the idle-time call was checked from a transient user
service; enabling it as a permanent service was not tried:

```ini
# ~/.config/systemd/user/pli-watch.service
[Service]
WorkingDirectory=/path/to/personal_learning_intelligence
ExecStart=/home/you/.local/bin/uv run pli watch
Restart=on-failure
[Install]
WantedBy=default.target
```

then `systemctl --user enable --now pli-watch`.

`pli plan` never touches your calendar. Only `pli apply` writes, only into the
dedicated `Study Plan` calendar, so a regeneration cannot damage your real
timetable.

`pli sync --source stub` limits the sync to the hand-written deadline file and
keeps the browser closed. A plain `pli sync` also reads the Teams channels.

The first Teams read reaches back 14 days; every later one resumes from the
newest post the previous sync saw. If a read went wrong and you want the window
re-read, drop the cursor first:

```bash
uv run pli clear-state --source teams   # next sync reaches back the full 14 days again
```

Re-reading is always safe — messages are keyed by their own id, so a post seen
twice is stored once, and a post edited in place is corrected rather than
duplicated.

## Configuration

- `.env` — secrets and machine-local paths (gitignored). See `.env.example`.
- `config/study.toml` — study preferences: session lengths, daily caps, study
  hours, per-course weights. These are the constraints the packer obeys.
- `config/browser.toml` — the selectors every reader uses. See "When a page
  changes" above; this is the file to edit when Microsoft moves something.
- `config/stub_deadlines.toml` — placeholder deadlines. Replace with your real
  upcoming work, or let the Moodle source fill this in.

## Status

| Phase | Scope | State |
|---|---|---|
| 1 | Walking skeleton: browser session, free/busy, scoring, packing, calendar write | built |
| 2 | Moodle ingestion (courses, assignments, action events, files) | not started |
| 3 | Teams channel messages: read through the browser and stored verbatim | built |
| 3b | Teams channel files and pinned tabs | not started |
| 4 | Enrichment: text extraction, summaries, local semantic search | not started |
| 5 | systemd user timers for the daily sync and weekly plan | not started |
| agent | `pli agent`: read-only inbox digest (Jev labels, DeepSeek summaries and answers on any subject), web lookups, voice input, status window, deadline tracker | built |
| watch | `pli watch`: opt-in local activity counts, asked about through the agent | built |

### What this cannot do, and why

**A restyled page breaks a read, and only a config edit fixes it.** This is the
price of reading the web UI, and it is paid knowingly: the alternative was not
reading Teams channel posts at all. Diagnostics exist to make the repair quick -
see "When a page changes".

**Teams posts are stored, not interpreted.** A channel message is kept verbatim
in SQLite, because a lecturer's own wording is the evidence for why a deadline
moved. It is deliberately *not* parsed into a deadline automatically: a wrong
guess there would invent work that does not exist, and a missed one is recoverable
by reading the message. What is on the channel is context the planner can use;
what is on Moodle (Phase 2) is the deadline.

**Moodle student tokens may be disabled.** `/user/managetoken.php` renders empty
for students on a default site, because `moodle/webservice:createtoken` is
granted to `manager` only. The Moodle source is being replaced by the browser for
the same reason as everything else here, and until Phase 2 lands the planner
keeps running on already-cached deadlines.

**Phase 1 has no ingestion, so every task estimates the same.** Until Phase 4
attaches `estimated_hours` to real materials, the planner falls back to one
session ceiling per task and the week looks uniform. The *scheduling* is correct
and complete — class times, daily caps, breaks and front-loading all apply — but
durations only become meaningful once there is something to estimate from.

## Layout

```
config/
  study.toml           study preferences - the constraints the packer obeys
  browser.toml         every selector the readers use (edit this on a redesign)
  stub_deadlines.toml  placeholder deadlines for `pli sync --source stub`
src/pli/
  config.py            settings (.env) + study preferences (study.toml)
  models.py            domain models - the frozen contract
  db.py                SQLite: dedupe ledger, sync cursors, block ledger, messages
  backend.py           the calendar I/O seam: 4 calls, no knowledge of the surface
  judge.py             typed judgements (TypeSafe/Jev) about captured page content
  agent/
    repl.py            `pli agent`: the prompt loop, tool routing, answers
    triage.py          Jev labels + DeepSeek summaries for inbox rows
  voice.py             push-to-talk speech-to-text (local faster-whisper)
  display.py           the small Tk status window (separate process)
  activity.py          `pli watch`: local activity counts, never what they were
  deadlines.py         LMS deadline notices found in mail, ticked off by number
  web.py               web lookups: throwaway Chromium reader, page text, typed addresses
  webguard.py          the public-address rule and the proxy every web connection goes through
  browser/
    session.py         owns the Chromium profile - the one place a session lives
    selectors.py       loads config/browser.toml; queries are data
    capture.py         page -> candidates, visible text, diagnostics dump
    outlook.py         OutlookBackend: CalendarBackend over the Outlook web UI
    teams.py           reads Teams channels through the same browser session
    mail.py            reads the Outlook inbox list (never opens a message)
    text.py            characters stripped from page text (shared by mail and web)
  sources/             base contract, Phase 1 stub, (Phase 2) moodle
  llm/client.py        provider-agnostic OpenAI-compatible adapter
  planner/
    freebusy.py        events -> genuinely free windows
    tasks.py           deadlines + materials -> scorable tasks
    score.py           LLM judgement, with a deterministic fallback
    pack.py            the scheduler: all hard constraints live here
    apply.py           reconcile blocks <-> calendar events, through the backend
  report.py            rich + markdown output
  cli.py               typer entry point
```
