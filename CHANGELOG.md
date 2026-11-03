# Changelog

## Unreleased

### Changed

- Phonic now defaults to native busy-mode result delivery, listening backchannels
  at aggressiveness `0.3`, required pre-tool speech with overlapping backend work,
  speed `1.05`, speech threshold `0.7`, minimum speech `120 ms`, end-of-turn silence
  `600 ms`, one-word interruptions and a 60-second tool-output timeout. Artificial
  background noise remains disabled. App overrides take precedence and are
  validated after defaults are resolved. Disabling backchannels removes inherited
  aggressiveness. `Parlora.Providers.Phonic.default_options/0` exposes the defaults.
- **Phonic upgrade:** native busy mode holds other voice tool calls while a
  result is pending. Apps requiring the previous concurrent voice-tool behavior
  should set `wait_for_response: false`. Set `require_speech_before_tool_call: false`
  and `enable_assistant_backchannel: false` to disable the new speech behaviors.
  Backend job deadlines and application-owned validation and consent are unchanged.
- BookingDesk inherits Phonic conversation defaults from Parlora and retains only
  its clinic keywords. Apps override individual settings through `provider_options`;
  the combined example-only conversation toggle has been removed.

### Fixed

- Raise Phonic's default VAD threshold to `0.7` to reduce false interruptions from
  café activity while retaining one-word interruptions and native conversation.
  Explicit app overrides still take precedence. Handle provider-cancelled input
  without leaving verified results queued or timing out a cancelled automatic
  response. Expose caller speech boundaries for audits; BookingDesk now rejects
  false speech starts even when their punctuation transcripts were discarded.
- Preserve native Phonic result audio when its speech starts before an earlier
  acknowledgment finishes. Track outstanding speech ends until all open speech
  boundaries settle; interruptions reset them. Punctuation-only input remains
  available as a discarded-transcript diagnostic rather than a caller turn.
- Keep current verified facts in native Phonic tool outputs when a later call
  associates with completed work. Previously, an acknowledgment ending the prior
  reply could cause deduplication to remove the result and strand the conversation.
  Native response ownership and the instruction against repeated announcements
  are preserved; no backend work is repeated.

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
