# Changelog

## 0.1.0

First public release of Parlora, an Elixir framework for building real-time voice
AI agents with speech-to-speech providers and application-owned backend work.

- Voice providers: OpenAI GPT-Live-1, Gemini Live, and Grok Voice.
- Audio channels: browser WebRTC, local microphones and speakers, Twilio, and Telnyx.
- Optional Jido, Sagents, and Legion backends, plus contracts for custom adapters.
- Application policies for task delegation, corrections, cancellation, clarifications,
  and filtering outdated results.
- Bounded audio queues, adaptive playback buffering, playback controls, session
  lifecycle deadlines, cleanup, and observable session events.
- A complete first-session tutorial, integration guides, and the OrderDesk example.

Requires Elixir 1.18 or later (1.x) and Erlang/OTP 27 or later. Native bindings
require the documented Rust toolchain and system libraries for the selected
channels. Released under the MIT License.
