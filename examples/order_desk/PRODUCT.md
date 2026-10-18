# OrderDesk

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

The main interface serves the person checking their demo orders and reviewing
delivery-instruction changes. Prioritize completing those tasks and understanding
what is happening during a voice conversation.

Developers evaluating Parlora are a secondary audience. Keep connection, job,
interpretation, and audio diagnostics available in expandable sections.

This audience priority was selected at the user's request to resolve Impeccable's
setup choices from the established project and example-application purpose.

## Product Purpose

OrderDesk demonstrates Parlora used from a separate Mix application, with an
application-owned ContextPolicy, Jido actions, TypeSafe-assisted interpretation,
and persistent SQLite records. Parlora is the reusable voice library; OrderDesk
owns the order workflow, business decisions, persistence, and browser interface.

Success means a caller can check an order, correct the number, ask about its
items, and propose delivery instructions while understanding which work is
current and which changes have actually been saved.

## Operating Context

This is a local, single-customer development application. Run `scripts/browser.sh`
and open `http://localhost:4000` in Chrome. Headphones are recommended. The browser
uses microphone and speaker audio through Parlora's WebRTC channel and GPT-Live-1.

The UI supports both voice-created delivery drafts and directly typed drafts.
Review and confirmation happen in the browser. The existing terminal voice
example remains a separate, simpler status-lookup workflow.

The authoritative application source lives in `examples/order_desk` in the Parlora
repository. `parlora_consumer` is a generated installation for package testing,
not a second maintained source. Make application changes here, then generate a
fresh standalone installation with `scripts/consumer.sh` from the repository root.

## Capabilities and Constraints

- Look up order status, tracking details, items, and saved delivery instructions.
- Correct the active order and prevent outdated work from replacing current results.
- Create a delivery draft without changing the saved order.
- Confirm the exact displayed order and instruction text with an explicit browser
  action, or reject the draft. Spoken approval never authorizes a saved update.
- Distinguish pending drafts, applied changes, rejected or expired drafts, and
  conflicting updates. Drafts expire after five minutes.
- A spoken correction or refusal does not remove an existing draft. Saved changes
  are not undone by ending or interrupting a conversation.
- Persist orders and saved changes in SQLite. Parlora voice sessions stay in memory.
- Clarify uncertain requests and communicate service failures without inventing
  order results or implying an update was saved.
- Keep API credentials on the server. The browser never receives provider keys.
- This is a loopback demo without account login or a live retailer integration.
  Public deployment and account authentication are outside its current scope.

## Evidence on Hand

The order records are fictional demo data; database reads and confirmed writes
are real. Orders 123, 124, and 825 are seeded only when absent. Do not portray the
example as connected to a shipping carrier or retailer.

`APPLICATION.md` documents the implemented workflow, ownership boundaries,
validation, and limitations. Historical observations live in
`validation/order-desk/application-results.json` in the Parlora repository. The browser implementation is in `priv/browser/`.

Captions, provider acknowledgements, and audio transmission are distinct
observations. None independently proves that the caller heard a particular result.

## Product Principles

1. Make the conversation and the current order easy to follow.
2. Make the difference between a proposed change and a saved change explicit.
3. Require review of the exact order and text before saving delivery instructions.
4. Explain uncertainty and offer a useful next action instead of leaving the caller waiting.
5. Keep developer diagnostics accessible without letting them dominate ordinary tasks.

## Open Decisions

No new brand direction or product-specific accessibility standard has been
selected. Future UI work should preserve existing functionality and improve
keyboard access, labels, feedback, and responsive usability as appropriate.
