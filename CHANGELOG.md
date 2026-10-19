# Changelog

## 0.2.0

Adds a public observability contract while keeping monitoring configuration in
the host application. Existing session and adapter APIs remain compatible.

- Telemetry events for session startup and shutdown, policy evaluation, backend
  queue and execution times, result delivery, recovery, and interruption handling.
- Operational events with bounded categories and selected metadata, without
  copying transcripts, application payloads, or credentials into the new events.
- Provider audio queue duration and age measurements, plus audio pipeline blocked
  duration measurements.
- A metrics, traces and logs guide covering event definitions, units, timing
  boundaries, and application control of reporters, exporters, and logging.
- An optional development example using VictoriaMetrics, VictoriaTraces, and an
  OpenTelemetry Collector, with repeatable workloads and export verification.
- Regression coverage for duplicate, outdated, and late recovery completion
  notifications, including notifications received during shutdown.

No monitoring SDK or service is required by the library. Elixir, Erlang/OTP,
and native build requirements are unchanged.

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
