---
version: 1
slug: "website-index-html"
primary_target: "website/index.html"
related_targets: ["website/content/introducing-parlora.html","website/assets/site.css","website/assets/site.js"]
---

# Parlora blog

Mode: Read. Scope: website index, announcement, privacy and 404 pages.
The maintainer selected The conversation journal and static HTML/CSS/JavaScript.

## Direction contract

THESIS: A readable journal about building voice AI agents, with genuine explanatory motion rather than a promotional dashboard.

OWN-WORLD: Warm ivory #f6f1e8, forest #183e36, terracotta #b84226, fine warm rules. Fraunces titles and DM Sans reading text preserve the approved sketch. Open article entries, no card grid.

STORY: Understand what Parlora does, read its introduction, then try the documented first session or join the discussion. Only the actual announcement appears.

FIRST VIEWPORT: A 1248px maximum publication rail, Parlora masthead at left and four navigation links at right. A generous two-line serif introduction occupies the left; a restrained voice mark sits right. The announcement begins below one horizontal rule. Article pages use a calm 68ch column and a margin contents list.

FORM: Conversation journal, grounded position 5; seed:5f70b60f7df1e6e4. The selected HTML sketch is .impeccable/mocks/decision/journal.html. Code-led; no image comp. Read in ordinary daylight on laptop or phone: a light ground and strong ink keep long text comfortable.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Interaction and constraints

A reader-controlled session diagram explains audio and application work, with named steps, pause/replay and a static text equivalent. No microphone, API call or synthesized benchmark is implied. Reduced motion avoids transitions. Navigation and articles work without JavaScript.

Use the existing shared hfiguera.github.io Cloudflare Web Analytics property, filtering /parlora/ by path. Production only; previews omit the beacon. No new analytics account, custom events or public deployment is required for this task.
