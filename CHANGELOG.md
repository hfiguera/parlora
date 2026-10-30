# Changelog

## Unreleased

- Add Phonic-1 as an accepted experimental speech-to-speech provider, with
  asynchronous client delegation and PCM24 streaming, including conversion for
  mu-law channels. See the [Phonic guide](docs/phonic-provider.md) for capabilities
  and remaining qualification limits.

- Resume Phonic result announcements after completed late tool associations,
  suppress duplicate association continuations, and treat tool-only automatic
  turns as progress so they cannot strand a queued result behind a speech wait.
- Hold Phonic speakable updates until their explicit result reply can begin,
  preventing an automatic answer followed by a duplicate continuation. Preserve
  tool-only recovery, corrections, cancellation, and bounded context admission.
- End normal Phonic sessions with WebSocket close code 1000 and bounded TLS
  cleanup, avoiding the abnormal-disconnect recovery delay after callers hang up.

- Use Elixir's built-in `JSON` module and remove the direct Jason dependency.
  Minimum runtime requirements remain Elixir 1.18 and OTP 27. Dependencies may
  still install Jason for their own use. Custom structs passed across JSON
  adapter boundaries now need `JSON.Encoder` instead of `Jason.Encoder`, or
  conversion to plain data. Development reports use compact JSON.

- Allow compatible Hex dependency updates while retaining the current minimum
  versions. Optional backends stay within their current minor releases.
- Add a scheduled Linux check that resolves the latest allowed dependencies and
  runs the library suite. Routine CI continues using the committed lockfile.

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
