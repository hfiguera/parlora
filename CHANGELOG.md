# Changelog

## 0.5.0

Adds rolling transcript retention and more controls for Phonic, Gemini and Grok.
Session startup validates options earlier, and shutdown tracks owned processes
directly. The minimum requirements are Elixir 1.18 and Erlang/OTP 27.

### Session and provider upgrade notes

- **Transcript retention.** Sessions now keep a rolling window of recent
  transcript entries, bounded by `max_transcripts` (8,192 entries) and
  `max_transcript_bytes` (1 MiB of encoded entries) by default. Keep durable facts
  in application context or storage. Set `transcript_retention: :close` in the
  session options if your app relies on closing at capacity. The lifetime
  `max_records` budget still applies to request and command identity, and provider
  context and duration limits apply independently.
- **Phonic.** Native busy mode holds other voice-tool calls while a result is
  pending. Set `wait_for_response: false` in the provider options to restore
  concurrent voice tools with explicit result replies. Pre-tool speech and
  listening backchannels are enabled by default. Set
  `require_speech_before_tool_call: false` and
  `enable_assistant_backchannel: false` to disable those requirements and
  backchannels. The [Phonic guide](docs/phonic-provider.md) lists the defaults and
  overrides.
- **Gemini and Grok.** Gemini defaults to automatic speech detection with 700 ms
  of end-of-turn silence, native interruptions and verbatim input transcription.
  Apps can override individual nested settings. Grok defaults to normal synthesis
  speed, high reasoning and automatic idle prompts disabled. See the
  [Gemini guide](docs/gemini-provider.md) and [Grok guide](docs/grok-provider.md)
  for override options.

### Added

- Report retained and dropped transcript entries in session status and snapshots,
  and emit a compaction event and telemetry when older entries are dropped.
- Expose Phonic's native speech, listening and tool timing settings, including
  backchannels, one-word interruptions and overlapping pre-tool speech.
- Expose Gemini speech detection, activity handling and transcription settings,
  including language hints, vocabulary and optional interim timestamps. Merge
  nested overrides one field at a time.
- Expose Grok synthesis speed, pronunciation replacements, transcription hints
  and keyterms, idle prompts and optional interruptible verbatim speech.

### Changed

- Support optional Sagents `~> 0.20.0` alongside `~> 0.19.2`. The development
  lockfile, OrderDesk and isolated Sagents consumer use `0.20.1`. Update the
  WebSock Adapter locks to `0.7.1`.
- Separate session startup, shutdown, recovery and task handling into focused
  modules. Track session-owned process trees for cleanup instead of scanning
  every process in the VM.
- Improve BookingDesk's recovery across uncertain turns, date and slot selection,
  recording, spoken confirmation readbacks and reminder consent. Refresh the
  example article's clean and café recordings, captions and charts.

### Fixed

- Return an argument error for invalid startup audio formats and limits before
  computing provider limits.
- Preserve verified Phonic result audio and facts across overlapping
  acknowledgments, provider cancellations and native tool handoffs.
- Update the example apps to Finch 0.24 to avoid HTTP/1 connection reuse failures
  after timed-out requests.

### Security

- Update the repository's development and example lockfiles to Ecto `3.14.3`
  and JSV `0.26.2` for [CVE-2026-118391](https://cna.erlef.org/cves/CVE-2026-118391.html)
  and [CVE-2026-117680](https://cna.erlef.org/cves/CVE-2026-117680.html).
  Apps that resolve either package through their own dependencies should check
  their lockfiles, update affected versions and run `mix hex.audit`.

## 0.4.0

Adds opt-in local audio capture for diagnostics and recording, fixes Gemini and
Grok continuations during backend work, and adds the BookingDesk example.
Existing session and adapter APIs remain compatible. Elixir, Erlang/OTP, Rust
and native library requirements are unchanged; no configuration changes are
required when upgrading from 0.3.x.

### Added

- An optional `:audio_observer` on `Parlora.Channels.LocalAudio` for converted
  caller PCM and assistant software playout PCM before device conversion.
  Delivery is bounded to 256 messages with dropped-packet accounting. Capture is
  disabled by default; these observations do not establish physical playback.
- A separate BookingDesk example using Jido, JEV, structured extraction and
  deterministic record matching and booking approval. It includes microphone
  and scripted replay modes, insurance review, simulated text reminders,
  call-boundary guardrails, and offline tests and quality checks.
- A booking conversation article with clean and café recordings for four
  providers, synchronized transcripts and waveforms, backend activity, and
  recorded metrics and traces. The example and publication remain in the
  repository; their application code and media are not included in the Hex package.

### Fixed

- Close superseded Gemini function calls silently without sending internal
  control outcomes to the model. Reject late context for those obsolete calls
  and preserve existing reply monitoring and provider activity.
- Wait for pending function outputs from Grok's latest response before requesting
  a queued clarification. This prevents an unacknowledged continuation from
  stranding a backend result after interrupted caller speech.

## 0.3.0

Adds Phonic-1 as a supported speech-to-speech provider and uses Elixir's built-in
JSON module. Minimum runtime requirements remain Elixir 1.18 and Erlang/OTP 27.

### Upgrade notes: custom JSON encoders

**Custom structs crossing JSON boundaries must implement `JSON.Encoder` instead
of `Jason.Encoder`, or be converted to plain maps and lists.** This applies to
provider messages, channel signaling, Telnyx commands, and Legion operation
results. A `Jason.Encoder` implementation alone is no longer used by Parlora.

For example, replace `@derive {Jason.Encoder, only: [:value]}` with:

```elixir
defmodule MyApp.Result do
  @derive {JSON.Encoder, only: [:value]}
  defstruct [:value, :private]
end
```

Preserve the fields your application intends to expose. Plain maps, lists,
strings, numbers, booleans, and `nil` need no encoder migration. Dependencies may
still install Jason for their own use; Parlora no longer depends on it directly.

### Added

- Phonic-1 support with asynchronous client delegation, PCM24 streaming, and
  conversion for mu-law channels. The adapter coordinates result replies,
  corrections, interruption, cancellation, and bounded context admission.
  See the [Phonic guide](docs/phonic-provider.md) for capabilities and limitations.
- Phonic selection in the separate OrderDesk example for browser, local audio,
  Twilio, and Telnyx sessions. OrderDesk remains an example application, not part
  of the library.
- A scheduled Linux check that resolves the latest allowed dependencies and runs
  the library suite. Routine CI continues using the committed lockfile.

### Changed

- Use Elixir's built-in `JSON` module at JSON boundaries and compact JSON for
  development reports. See the encoder migration above before upgrading.
- Upgrade Bandit to 1.14.1, ExWebRTC to 0.18.0, WebSockAdapter to 0.7.0, and
  optional Sagents to 0.19.2. Update the required DTLS, LangChain, ReqLLM, and
  model-catalog dependencies. Allow compatible Hex dependency updates while
  retaining minimum versions; optional backends stay within their minor releases.

### Fixed

- Resume Phonic result announcements after completed late tool associations,
  suppress duplicate association continuations, and treat tool-only automatic
  turns as progress so they cannot strand a queued result behind a speech wait.
- Hold Phonic speakable updates until their explicit result reply can begin,
  preventing an automatic answer followed by a duplicate continuation.
- End normal Phonic sessions with WebSocket close code 1000 and bounded TLS
  cleanup, avoiding the abnormal-disconnect recovery delay after callers hang up.
- Reduce redundant interpretation in OrderDesk and recognize quoted save
  confirmations without treating them as a new request to save.
- Include Plug.Crypto 2.2.1's secret-redaction security fix.

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
