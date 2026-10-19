# Parlora publication

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

Static HTML, CSS and JavaScript for GitHub Pages, explicitly selected by the
maintainer. The blog lives in `website/`, separately from the Elixir library and
generated ExDoc. No frontend framework or application server is required.

## Users

Developers exploring voice AI, especially those building with Elixir. Readers
need to understand what Parlora does, why they might use it, and how to start.

## Product Purpose

Introduce Parlora and publish useful articles about building voice applications.
The first article is the project announcement developed with the maintainer in
this conversation. Readers can continue to the working tutorial, Hex, or GitHub.

## Positioning

Parlora is an MIT licensed Elixir framework for voice AI agents. It coordinates
speech to speech providers, audio channels, application policies and backend work.
Application code retains responsibility for authorization, business rules,
confirmations and storage. All audio passes through Parlora.

## Operating Context

The library is published as 0.1.0 on Hex. Public documentation is on HexDocs.
The website is a publication, not a live voice client or an authenticated app.
Its explanatory interactions must be clearly illustrative and require no keys.

## Capabilities and Constraints

Supported voice providers: OpenAI GPT-Live-1, Gemini Live and Grok Voice.
Supported channels: browser WebRTC, local audio, Twilio and Telnyx.
Optional backend integrations: Jido, Sagents, Legion, or a custom backend.
Do not claim guaranteed audio quality, latency, exactly once execution, or that
cancellation reverses external effects. Do not invent usage statistics,
testimonials, additional articles, benchmarks or customer deployments.

## Brand Commitments

Use the Smolbox publication at https://hfiguera.github.io/smolbox/ as a reference
for reading quality, navigation and explanatory motion. Create a distinct
Parlora identity with different colors, rather than copying the site. Writing
should be clear and natural, with unnecessary compound words avoided.
The maintainer selected the conversation journal direction: warm ivory,
forest green, terracotta, and the typography shown in the approved preview.

## Evidence on Hand

README.md, the public guides, published HexDocs, and the announcement text agreed
in the conversation. The name is inspired by Italian parlare and ora. The blog's
finished visual system is recorded in DESIGN.md. There are no supplied customer
testimonials or adoption statistics.

## Product Principles

- Explain the framework before discussing examples tied to a particular domain.
- Keep articles useful and easy to read on phones and larger screens.
- Use motion to explain the interaction, with a static explanation available.
- Direct readers to real documentation and invite useful community feedback.
- Keep the blog independent from the library runtime and release package.
