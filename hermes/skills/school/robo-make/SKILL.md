---
name: robo-make
description: "Make diagrams, web pages, docs, charts and slides."
version: 1.0.0
author: robo
metadata:
  hermes:
    tags: [Create, Diagram, HTML, Document, Chart]
    requires_toolsets: [file]
    related_skills: [study-plan]
---

# Make things (diagrams, web pages, documents, charts, slides)

## When to Use
The user asks you to create, draw, design, write up or visualise something: a diagram or mind
map, a web page or HTML design, notes or a summary sheet, a chart of their data or results,
slides, flashcards, a quiz.

## Where
Write ONE self-contained file in `~/Robo/` (create the folder if needed), named
`YYYY-MM-DD-<short-slug>.<ext>`, e.g. `~/Robo/2026-10-11-water-cycle.html`. Robo opens every
file you write there automatically when your reply ends, so do NOT open it yourself and do not
write scratch files there (use /tmp for those). Make a new file each time; never overwrite an
older one unless the user asks to change it.

## How (all single-file, no build step, works offline except the CDN scripts)
- Diagram, flowchart, mind map, timeline, sequence: an `.html` page with Mermaid
  (`<script type="module">import mermaid from
  "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs"; mermaid.initialize({startOnLoad:true});</script>`
  and `<pre class="mermaid">...</pre>`), or hand-written inline SVG for simple shapes.
- Web page / UI design: one `.html` with inline `<style>` (and inline `<script>` if it needs to
  do something). Clean, modern, readable; responsive.
- Chart of numbers (grades, study time from `robo activity`): `.html` with Chart.js from
  `https://cdn.jsdelivr.net/npm/chart.js@4`.
- Notes, summary sheet, study guide, essay draft: a styled `.html` (prints well) or `.md` if
  the user asks for Markdown.
- Slides: one `.html` where each `<section>` fills the screen and arrow keys move between them.
- Flashcards / quiz: one `.html` with click-to-flip cards or a self-checking quiz.
- Code the user asked for: the right extension (`.py`, ...), runnable as is.
Check the file is complete (closing tags, no placeholders) before you finish.

## Reply
One or two sentences: what you made and its file name. Keep the long content in the file, not
in the bubble.
