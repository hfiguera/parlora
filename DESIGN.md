---
name: Parlora publication
description: A warm conversation journal about building voice AI agents with Elixir.
colors:
  paper: "#f6f1e8"
  ink: "#183e36"
  soft: "#526155"
  accent: "#b84226"
  accent-hover: "#8b2e19"
  line: "#d8cbb7"
  wash: "#ece6da"
  code: "#18352f"
  selection: "#e5c9b6"
typography:
  display:
    fontFamily: "Fraunces, Georgia, serif"
    fontSize: "clamp(48px, 6vw, 86px)"
    fontWeight: 400
    lineHeight: 1.08
    letterSpacing: "-.035em"
  headline:
    fontFamily: "Fraunces, Georgia, serif"
    fontSize: "clamp(40px, 4.4vw, 62px)"
    fontWeight: 400
    lineHeight: 1.12
    letterSpacing: "-.03em"
  title:
    fontFamily: "Fraunces, Georgia, serif"
    fontSize: "clamp(32px, 3vw, 42px)"
    fontWeight: 500
    lineHeight: 1.2
    letterSpacing: "-.025em"
  section:
    fontFamily: "Fraunces, Georgia, serif"
    fontSize: "32px"
    fontWeight: 500
    lineHeight: 1.25
    letterSpacing: "-.02em"
  body:
    fontFamily: '"DM Sans", sans-serif'
    fontSize: "18px"
    fontWeight: 400
    lineHeight: 1.7
  reading:
    fontFamily: '"DM Sans", sans-serif'
    fontSize: "19px"
    fontWeight: 400
    lineHeight: 1.8
  label:
    fontFamily: '"DM Sans", sans-serif'
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.7
  code:
    fontFamily: "ui-monospace, SFMono-Regular, Consolas, monospace"
    fontSize: ".86em"
rounded:
  inline-code: "3px"
  control: "5px"
  inset: "12px"
spacing:
  xs: "8px"
  sm: "12px"
  md: "18px"
  lg: "24px"
  xl: "28px"
  section: "32px"
  wide: "48px"
  rail-gap: "60px"
components:
  walkthrough-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    rounded: "{rounded.control}"
    padding: "8px 14px"
    typography: "{typography.label}"
  walkthrough-secondary:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "8px 14px"
    typography: "{typography.label}"
  walkthrough-hover:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.paper}"
  copy-code:
    backgroundColor: "transparent"
    textColor: "{colors.paper}"
    rounded: "{rounded.control}"
    padding: "4px 14px"
    typography: "{typography.label}"
  project-navigation:
    textColor: "{colors.ink}"
    padding: "12px 0"
  post-entry:
    textColor: "{colors.ink}"
    padding: "34px 0 48px"
  session-figure:
    backgroundColor: "{colors.wash}"
    textColor: "{colors.ink}"
    rounded: "{rounded.inset}"
    padding: "28px"
  contents:
    textColor: "{colors.soft}"
    typography: "{typography.label}"
---

# Design System: Parlora publication

## Overview

**Creative North Star: "The conversation journal"**

Parlora is an open, readable publication for developers building voice applications. Warm paper, forest ink and terracotta links give the technical material a human editorial character. Articles use generous leading, a narrow reading measure and quiet rules rather than a grid of promotional cards.

The maintainer explicitly selected the warm ivory, forest and terracotta palette and the Fraunces/DM Sans pairing from the approved journal preview. These are confirmed identity choices. Preserve their roles when extending the publication. Self-hosted fonts, ordinary HTML navigation and explanatory SVG geometry keep the experience independent of a frontend framework or external font service.

The source of truth is `website/assets/site.css`, with behavior in `website/assets/site.js` and shared markup in `website/templates/layout.html`. This record captures the finished static build in `website/_site/`; it is not a proposal. The direction contract lives in `.impeccable/surfaces/website-index-html.md`.

**Key Characteristics:**

- Light paper, strong forest text, restrained terracotta emphasis.
- Expressive serif titles with steady sans-serif reading text.
- Open article entries, fine rules and a separate contents margin.
- Reader-controlled explanatory motion with a useful static equivalent.

## Colors

The palette feels warm and quiet while retaining strong distinction between text, actions and inset technical material. The frontmatter records the actual CSS values.

### Primary

- **Forest ink** (`ink`): body text, masthead, titles, primary walkthrough control and the coordinating node in the session diagram.
- **Terracotta** (`accent`): text links, emphasized introduction text, the voice mark, focus outlines and moving diagram signals.
- **Deep terracotta** (`accent-hover`): ordinary link hover feedback.

### Neutral

- **Warm ivory** (`paper`): the page ground and reversed text on forest surfaces.
- **Muted leaf** (`soft`): secondary prose, metadata, captions and contents links.
- **Warm rule** (`line`): the thin separators that organize the publication.
- **Paper wash** (`wash`): inline code and the explanatory figure's inset ground.
- **Deep code green** (`code`): code block ground.
- **Peach selection** (`selection`): selected text and tap feedback.

**The Ink and Action Rule.** Forest carries reading and identity; terracotta identifies links, focus and purposeful emphasis.

The diagram also uses observed local state colors: pale leaf for listening, backend work and result states; pale peach for delegation; muted green route strokes and node rules. These stay local to the explanatory figure. Sidecar tonal ramps are generated preview aids, not additional shipping colors.

## Typography

**Display Font:** Fraunces, with Georgia and serif fallbacks.

**Body Font:** DM Sans, with a sans-serif fallback.

**Code Font:** the platform monospace stack recorded in the frontmatter.

**Character:** Fraunces gives titles a conversational editorial voice. DM Sans supports long technical passages, compact metadata and navigation without competing with those titles. Both named faces are self-hosted variable fonts with `font-display: swap`; synthetic font styles are disabled.

### Hierarchy

- **Display:** the introduction's balanced heading; its exact desktop ramp is in the frontmatter. At the middle breakpoint it becomes `clamp(42px, 7.2vw, 58px)`; on small phones, `clamp(33px, 9vw, 43px)`.
- **Headline:** article titles; on small phones the title is fixed at (40px).
- **Title:** article entry titles; middle layouts use (36px), small phones (32px).
- **Section:** article section headings; small phones use (29px). The index section heading instead uses DM Sans (23px, weight 500), becoming (20px) on small phones.
- **Body / Reading:** the base page role and the more generous article role are separate. Article reading text becomes (18px) on small phones while keeping its leading. Article decks use (21px/1.6), becoming (19px) on small phones.
- **Label:** bylines, footer text and controls. Post metadata starts at (15px), becoming (13px) in the stacked layout. Navigation uses (16px), becoming (14px) on small phones. Labels retain natural sentence case.

**The Two Voices Rule.** Fraunces carries titles and the wordmark; DM Sans carries explanations, navigation and controls. Use the platform monospace stack only for code.

## Layout

The publication rail is `min(1248px, calc(100% - 96px))`. Article text uses `min(68ch, 720px)`. These are different measures: preserve the broad publication frame and the calm reading column inside it.

The desktop article and article-entry grids use a (220px) metadata/contents column, a flexible content column and a (60px) gap. Article headers and the closing reading prompt align to that content column with a (280px) left offset. Contents are sticky (32px from the top). Open entries and the header/footer are separated by one-pixel warm rules; they are not enclosed cards.

Spacing is a set of observed working intervals rather than a strict arithmetic scale. Small component gaps use (8–18px); paragraph and component spacing commonly use (24–32px); broader page spacing uses (48–64px). Preserve source-specific optical spacing rather than forcing every interval onto a new scale.

Responsive behavior follows the actual `max-width` queries:

- **1100px:** grids tighten to a (190px) margin column and (36px) gap; aligned article offsets become (226px).
- **800px:** the rail uses (24px) side gutters; entries and articles become one column, metadata becomes a wrapping row, contents stop sticking and use two columns, and footer/start prompts stack. The article heading returns to the rail's left edge.
- **480px:** side gutters become (20px); the header wraps navigation beneath the wordmark, contents become one column, the large decorative voice mark disappears and the diagram compacts its nodes and routes. The diagram caption reserves more height for readable wrapping.

Privacy and error pages use a simple centered reading layout. Code blocks may scroll horizontally without forcing the page wider.

## Elevation & Depth

The system is flat and uses no box shadows. Hierarchy comes from whitespace, thin rules, forest reversal and tonal insets. Code blocks and the explanatory figure sit on different grounds; article entries remain on the page ground. The focus outline is an interaction affordance, not surface elevation.

**The Paper Plane Rule.** Use spacing, rules and tonal insets to establish hierarchy; preserve the built system's flat treatment.

## Shapes

Most publication structure is open and square. Small controls use a gentle corner (5px); inline code uses a smaller corner (3px); code blocks and the explanatory figure use the shared inset corner (12px). Diagram signal dots are circular, while diagram nodes use fine horizontal rules rather than card outlines.

The masthead and larger voice mark are inline SVG line geometry with rounded stroke caps. Utility arrows are inline stroked SVGs. Shipping visual assets consist of these SVG forms and the self-hosted fonts; there are no shipping raster images requiring provenance records.

## Components

### Buttons

Walkthrough controls are compact and readable, with a minimum target height (44px). The primary control reverses paper text onto forest; the secondary control is transparent with a forest border. Both use the shared control radius and padding from the frontmatter. Hover changes the ground and border to terracotta and the text to paper. The global keyboard focus treatment is a terracotta outline (3px) offset by (5px).

The code-copy control is a smaller reversed-text outline control inside the code block, with minimum height (36px). It appears only when the Clipboard API is available. Feedback reads “Copied” or “Code selected,” announces status, then resets after (2500ms). Clipboard failure selects the code for the browser's ordinary copy command. Without enhancement, the code remains readable and selectable.

### Navigation

The masthead places the wordmark left and four ordinary links right: Blog, Docs, Hex and GitHub. Links use forest text at rest; hover and the current-page state use terracotta with an underline. The phone layout moves the same links onto a full-width row, without a hidden menu. A keyboard-revealed skip link moves directly to the main content. Footer links wrap and retain their ordinary link behavior.

### Article Entries

Article headers separate author identity from publication metadata. The author
row pairs the name with inline SVG X and GitHub profile links, each with a visible
handle and an accessible platform label. The date, reading time and article's
library version sit below in muted text. Author groups wrap together on phones;
the profile icons inherit the link color and require no icon font.

An entry pairs publication metadata with a serif linked title, a short muted summary and a clear text link. It is an open editorial row rather than an enclosed card. Hover adds terracotta and an underline to the title. The index renders only authored article metadata; adding entries must not require changing the layout model.

### Contents

The article uses native `details` and `summary`, a simple list of section anchors and quiet rules. The desktop contents margin is sticky; the stacked layout makes it a static block above the article. Its disclosure and anchor links work without JavaScript.

### Code Blocks

Deep green blocks reverse paper text and use the inset radius with (28px) padding, becoming (24px 16px) on small phones. Enhanced blocks reserve upper space for the copy control. Inline code uses the paper wash and may wrap long tokens.

Elixir blocks use self-hosted Prism core and grammar, loaded only where needed.
Syntax colors apply only inside block code: atoms `#e9b4a4`, strings `#dfd69b`,
keywords and modules `#b5d5cf`, functions and numbers `#ecc18c`, variables and
operators `#d2c4e1`, comments `#a3b3aa`, punctuation `#c7d2c8`. All retain at least
4.5:1 contrast against the code ground. Copy actions read the original text;
without JavaScript the same code remains readable in the base paper color.

### Session Walkthrough

The signature figure shows Audio channel → Parlora → Voice provider, with backend application work connected beneath Parlora. A permanent caption states that the sequence is illustrative rather than a live session or measured timing. The initial static overview explains the same relationship before JavaScript runs, and controls are hidden until initialized.

The reader starts playback, pauses or continues it, replays it, or advances individual steps. The five stages are listening, delegation, backend work, result and speech. Automatic advances use (3400ms) per step; moving signal loops use (1500ms); node color transitions use (300ms) with the source easing `cubic-bezier(.16, 1, .3, 1)`. These durations describe explanation pacing and never represent provider latency or application performance. The sequence stops at its last step and pauses when the figure leaves view or the document is hidden.

Reduced motion disables CSS animations and transitions and smooth scrolling. Playback omits moving signals; enabling reduced motion while a sequence runs pauses it. Captions and manually advanced named states remain available. On small phones horizontal signal dots are hidden, retaining route geometry and readable node labels.

### Static Delivery and Analytics

Reading, navigation, contents and static diagram meaning work without JavaScript. The static GitHub Pages build uses ordinary directory routes. Cloudflare Web Analytics uses the existing shared `hfiguera.github.io` public browser property, filtered by `/parlora/`; the identifier lives in `website/site.json`. The build includes a beacon only with the explicit `--analytics` flag used for production. Default local builds omit it. Copy and walkthrough controls emit no custom analytics events.

## Do's and Don'ts

### Do:

- **Do** preserve the maintainer-selected warm ivory, forest and terracotta palette and Fraunces/DM Sans roles.
- **Do** keep the wide publication rail separate from the `min(68ch, 720px)` reading measure.
- **Do** use open article rows, thin warm rules and tonal insets to organize reading.
- **Do** retain visible keyboard focus, native links and disclosure, static explanations and reduced-motion behavior.
- **Do** label explanatory motion as illustrative and keep its pacing separate from performance claims.

### Don't:

- **Don't** turn article entries into a promotional card grid.
- **Don't** make navigation, articles or the diagram's meaning depend on JavaScript.
- **Don't** imply the walkthrough records audio, calls a provider or measures a real session.
- **Don't** add copy or walkthrough analytics events or enable the beacon in default local previews.

Not canonized or repaired: none identified by the completed finish review. The selected type pairing and palette are explicit maintainer decisions; no generic style preference overrides them.
