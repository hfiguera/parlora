# OrderDesk UI review

## Scope

Impeccable audit and polish of the existing browser application on September 16,
2026. Preserve the sage/green palette, system typography, vanilla HTML/CSS/JS,
voice transport, and explicit browser confirmation of delivery changes. The
primary audience and workflow defaults are recorded in [PRODUCT.md](../../examples/order_desk/PRODUCT.md) and
[the design configuration](../../examples/order_desk/.impeccable/config.json).

## Audit findings

Implementation integrity: the existing interface was a coherent working demo,
with real order content and safe text rendering. The bundled Impeccable detector
reported no findings for `priv/browser/index.html`. Rendered inspection and source
review exposed usability issues the detector did not identify.

The initial qualitative audit score was **12/20** (significant refinement needed):

| Dimension | Initial score | Evidence |
| --- | --- | --- |
| Accessibility | 2/4 | Mute had no programmatic pressed state; draft replacement could lose keyboard focus |
| Performance | 3/4 | Lightweight assets and bounded transcript, but every fragment rebuilt the caption DOM |
| Responsive design | 3/4 | 375px layout fit and buttons met 44px height; conversation came after all orders and history |
| Theming | 1/4 | Consistent palette, repeated literal values without semantic tokens |
| Implementation integrity | 3/4 | Real data and confirmation boundary; missing local feedback and recovery states |

These scores are review judgments, not accessibility certification. No blocking
issue was found. Six P2 findings were addressed:

| Finding | Location / category | Impact and resolution |
| --- | --- | --- |
| Conversation below the entire workflow | `index.html`, hierarchy | Callers had to scroll past all records to follow captions. Conversation now sits beside order work on desktop and first on mobile; drafts precede orders. |
| Competing call and technical controls | `index.html`, interaction | Seven top-level controls obscured the main action. Connect/disconnect/mute remain visible; audio controls and diagnostics have separate native disclosures. |
| Draft feedback far from the action; focus lost after replacement | `orders.js`, accessibility | Feedback now appears beside creation or review, progress labels identify pending requests, and focus moves to the result after confirmation. Polling preserves focused controls and does not replace an in-flight action. |
| Missing connection and recovery feedback | `voice.js`, `orders.js`, interaction | Mute has pressed state and visible microphone status. Audio control replies are displayed. A failed order refresh marks displayed records as potentially stale and exposes a retry button. Unknown mutation outcomes instruct retrying the same action. |
| Entire caption log rebuilt for each fragment | `voice.js`, performance/accessibility | Existing caption nodes are retained and updated; scrolling follows new text only when already near the bottom. The transcript remains bounded. |
| Scattered styling and incomplete focus coverage | `style.css`, theming/accessibility | Semantic color tokens, shared focus treatment, control states, and a keyboard skip link now cover the interface. |

The first post-change responsive inspection additionally found long headings and
control labels overflowing at 320px with 200% text sizing. Wrapping was corrected
and the regression check passes.

Positive practices retained: native buttons and forms, labeled instruction
fields, `textContent` for application data, bounded diagnostics, server-side keys,
immutable confirmation IDs, and no voice-authorized database writes. The shared
styling and disclosure patterns address recurring issues without adding a UI
framework or changing the product's visual identity.

## Verification

- Chrome UI workflow: create, confirm, reload, reject, and duplicate confirmation
  passed. Added coverage checks confirmation focus, failed confirmation retry,
  refresh failure/recovery, preservation of unfinished edits, and keyboard entry.
- Browser transport smoke: three WebRTC connection cycles, microphone denial,
  Origin rejection, mute, stop/clear/resume, and disconnect/page-close/signaling-loss
  cleanup passed against the offline provider. The harness opens the new control
  disclosures before exercising their existing actions.
- Desktop/mobile screenshots inspected with a pending draft and long instructions.
  Layout checks passed at 1280, 768, 375, and 320 pixels, including 200% text at
  320 pixels. Visible buttons, inputs, and summaries met 44px minimum height.
- Measured palette contrast: body 13.33:1, secondary text 5.66:1, primary button
  text 8.10:1, error text 6.84:1, and focus outline against white 4.96:1.
- JavaScript syntax checks and `git diff --check` passed; the UI workflow emitted
  no page JavaScript errors.

Reproduce with an isolated database and offline provider using the commands in
`APPLICATION.md`, then run `validation/browser/order_ui.cjs` and
`validation/browser/smoke.cjs` from the Parlora checkout. Set `BROWSER_URL` when
using a non-default port and `BROWSER_CHANNEL=chrome` for installed Chrome.

This pass made no paid model calls and did not repeat human listening, Linux,
external-network, screen-reader, or other-browser validation. It does not claim
full WCAG conformance. Dark mode is outside this refinement's scope. Actual spoken
intent and order-result correlation retain the documented application limitations;
the UI does not infer the current order by scraping transcript text.
