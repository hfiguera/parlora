# Phonic provider

`Parlora.Providers.Phonic` is a supported Phonic-1 speech-to-speech adapter.
It connects directly to `wss://api.phonic.ai/v1/sts/ws`; applications continue
to own their channels, context policies, backend execution, and task revisions.
No Phonic SDK or persistent hosted agent is required.

## Integration status

Phonic-1 is a **supported speech-to-speech provider** in Parlora.
The adapter has offline regression coverage, successful live-service probes,
and successful manual OrderDesk calls through the browser, Twilio, and Telnyx.
OrderDesk is a separate example application used to exercise the integration.

Promotion follows fixes for stalled result announcements, duplicate replies,
and abnormal session shutdown. Linux validation passed the full library CI,
native binding checks, stability tests, standalone OrderDesk production release
checks, and strict documentation generation.

The longer automated OrderDesk workflow now passes repeated live runs after
Phonic continuation and reply-coordination fixes. The [stall investigation](https://github.com/hfiguera/parlora/blob/646313a9c92759aad1cb6c527847ddd8648e36c4/validation/interpretation-scheduling/stall-investigation.md)
and [reply-coordination follow-up](https://github.com/hfiguera/parlora/blob/646313a9c92759aad1cb6c527847ddd8648e36c4/validation/interpretation-scheduling/reply-coordination.md)
record the reproduced causes, regressions, cross-provider checks, and evidence
limits. Support covers the documented adapter capabilities and tested workflows.
See also the
[initial acceptance evidence](https://github.com/hfiguera/parlora/blob/646313a9c92759aad1cb6c527847ddd8648e36c4/validation/phonic/README.md#acceptance-decision).

## Usage

```elixir
provider =
  {Parlora.Providers.Phonic,
   api_key: System.fetch_env!("PHONIC_API_KEY"),
   voice: "sabrina"}

{:ok, session} =
  Parlora.start_session(
    channel: channel,
    provider: provider,
    backend: backend,
    context_policy: context_policy,
    event_sink: self()
  )
```

The other adapter tuples above are supplied by your application. OrderDesk is
a separate example application, not a requirement or part of the library.

## Audio and readiness

The pipeline supports mono PCM16LE at 24 kHz and mu-law at 8 kHz. The Phonic
connection uses **PCM24 in both directions**. For mu-law channels, the adapter
uses the shared G.711 codec and bounded native streaming resamplers. PCM channels
do not allocate resamplers. Input is sent in approximately 20 ms chunks, below
Phonic's 40 ms per-message limit. Local input mute clears queued capture and
resampler state and sends PCM silence; it does not enable push-to-talk mode.

The native `mulaw_8000` wire format accepted configuration but produced no caller
speech detection in two synthetic probes, including one at the lowest documented
VAD threshold. The conversion path was subsequently verified using the actual
Elixir adapter. This is evidence about these probes, not a claim that every
Phonic mu-law connection fails.

Startup explicitly requests `model: "phonic-1"`, defines an inline strict
`delegate_to_backend` function, and waits for `ready_to_start_conversation` before
announcing readiness. This event confirms accepted configuration; Phonic does not
echo a model identifier for independent verification. `conversation_created`
may arrive after readiness.

Generated speech has a separate 20-second receive capacity and a 21-second
maximum local residence, scaled to the pipeline codec. Channel playback storage
remains independent. Continuous idle wire audio is discarded; speech is admitted
between assistant speech events. Overflow and stale audio fail explicitly rather
than silently dropping speech. These limits can be overridden through the
session's `limits:` option.

Caller `input_text` messages were observed as word fragments. The adapter adds a
word separator and emits `transcript_delta` with unavailable timestamps.
Punctuation-only input does not become caller dialogue. It remains observable as
an `extension` event with `kind: :transcript_discarded` and
`cause: :no_lexical_content`. A Unicode letter or number is sufficient for
admission, including one-word interruptions and phone digits in other scripts.
Assistant audio text shares a locally assigned `segment_id` for each utterance.
Caller fragments share a `segment_id` delimited by native caller speech events.
Assistant speech starting during that turn carries `overlaps_user_segment_id`.
This reports wire ordering, not a semantic classification of the words. Native
backchannels do not complete the caller's pending response or release queued
facts. Applications assembling dialogue can keep that caller turn intact while
retaining the overlapping assistant words separately, as BookingDesk does.
Neither transcript establishes that the caller heard the audio.

Native caller boundaries are observable as `extension` events with
`kind: :caller_speech`, a `segment_id`, and `state: :started | :finished | :cancelled`.
These report speech detection independently of transcript admission. In
particular, a rejected punctuation transcript does not undo an earlier audio
interruption. Phonic's explicit `input_cancelled` event clears the caller-speaking
gate and an outstanding automatic-response watchdog, allowing queued verified
results to resume. A watchdog for an already-submitted result reply is preserved.
Cancellation does not create caller text, consent or backend work.

## Tools, context, and corrections

Tool chaining is disabled (`allow_tool_chaining: false`) to avoid the repeated-call
bursts observed in validation. This also restricts autonomous sequences of tool
calls by the voice model.

Phonic tools run asynchronously. The default `wait_for_response: true` selects
Phonic's native busy mode: the model can converse and report progress while waiting,
but Phonic holds other voice tools until the call completes. Phonic owns that
call's result reply; the adapter sends its output without `generate_reply`.
This prevents a native answer followed by a second application-triggered answer.
When a later native call associates with completed work, its output still carries
the current verified facts, together with an instruction against repeating work
or an already announced answer. A prior acknowledgment finishing does not prove
that the result was spoken. Manual-mode duplicate routes keep the original reply
owner. Neither mode repeats backend execution to repair speech.
Set `wait_for_response: false` when your application needs concurrent voice tool
calls. Parlora then requests each result reply explicitly. Busy mode changes
voice-tool admission; application policies still own corrections and execution.

`forbid_speech_after_tool_call: true` remains the default, following Phonic's
[background-task combination](https://docs.phonic.ai/docs/build/tools/how_tools_execute).
With busy mode enabled, this skips immediate tool narration while preserving
native progress and result speech. It can be set to `false` in busy mode.
Manual response mode rejects that combination because it would introduce a
second result-reply owner. Pre-tool acknowledgments are required by default.
`require_speech_before_tool_call` and `wait_for_speech_before_tool_call` are
configurable independently. For example, requiring speech without waiting for
its completion lets Phonic choose its own acknowledgment while backend work
overlaps it. This does not grant the model execution authority.

The adapter exposes client calls as `delegation_requested`; the normal Parlora
context policy decides whether and how to admit work. Provider arguments are
context, not execution authority. Call and command IDs have bounded, retained
deduplication records. Conflicting duplicates and superseded results are rejected.

- `:speakable` context is admitted to a bounded local queue. Once caller speech,
  the automatic/current response, and the receive queue settle, the adapter
  completes the call using its selected response owner. Busy-mode call outputs
  receive a native reply, with no manual reply request. Uncorrelated application
  updates use one explicit reply, including clarifications while a native call
  is still pending. Their speech and receive queue settle before the native
  result is published. Keeping facts out of earlier turns avoids duplicate
  announcements. Multiple uncorrelated updates can share a manual reply.
  `context_submitted` is emitted only when the queued command is actually written
  to the socket. This does not wait for physical playback.
- `:quiet` and `:instruction` inject a system message without scheduling speech.
  A delegation ID is supported only for speakable context.
- If a clarification already completed a call, later verified results use a new
  system message. Expired calls also use new context; their old tool outputs are
  never resent.
- `resolve_delegation/3` closes associated or superseded calls without scheduling
  a duplicate manual response. Manual bookkeeping outputs remove already covered
  facts; native associated outputs retain their current verified facts. Both carry
  an instruction against repetition. Busy mode owns any native response to those
  terminal outputs. A manual result reply that yields
  to a new tool call before producing output can resume once on association.
  Cancellation removes queued correlated updates, and newer queued task revisions
  replace obsolete ones. Cancellation events preserve backend-outcome uncertainty.

Tool outputs are limited to 16,000 **JSON-encoded bytes**, conservatively below
the service's 16,000-character truncation boundary. The adapter rejects oversized
output rather than truncating or splitting it. Context text is bounded to 16,000
UTF-8 bytes.

## Submission, acknowledgment, and interruption

Successful socket writes emit `context_submitted` with `outcome: :unconfirmed`.
A matching `tool_call_output_processed` can upgrade a correlated result to
`context_acknowledged` with `acceptance: :provider_processed`. An error, timeout,
cancellation, or disconnect preserves an unknown outcome. A late acknowledgment
after the local acknowledgment deadline does not change that outcome.

Arbitrary system messages have no correlated acknowledgment, so
`context_acknowledgment?` is **false** for the overall provider capability.
Applications must observe each command's events rather than treat socket writes
or generated captions as acceptance or playback evidence.

`interrupted_response` and `user_started_speaking` establish one interruption
barrier even when they arrive in either order. Old queued audio and resampler
history are cleared. Audio before a fresh assistant speech boundary is ignored;
new speech waits behind the coordinator's matching `resume_output/2` token until
the channel has cleared its previous playback epoch. Missing clear completion
has the configured cancellation deadline. Phonic supplies no response ID on
audio messages, so boundary ordering remains part of the upstream wire contract.

## Options and limitations

| Option | Default | Behavior |
| --- | --- | --- |
| `api_key` | required | Explicit nonempty credential. |
| `model` | `"phonic-1"` | Other models are rejected. |
| `voice` | `"sabrina"` | A Phonic voice ID. |
| `instructions` | `"Keep replies brief."` | Application instructions plus delegation guidance. |
| `tool_timeout_ms` | `60_000` | Between 1,000 and 180,000 ms. Align with backend deadlines; this does not extend the backend job deadline. |
| `acknowledgment_timeout_ms` | `5_000` | Between 1 and 60,000 ms; missing tool-output acknowledgment remains unknown. |
| `response_timeout_ms` | `15_000` | Between 1 and 60,000 ms; missing response lifecycle progress closes explicitly. |
| `early_delegation` | `false` | Requests tool calls during caller speech; requires organization enablement. |
| `zero_data_retention` | `false` | When true, explicitly requests ZDR; rejection never falls back to retention. |

### Native conversation controls

These are keyword options in the provider tuple. Parlora supplies the following
defaults, based on the BookingDesk conversation and café-input validation:

| Option | Parlora default |
| --- | --- |
| `enable_assistant_backchannel` | `true` |
| `assistant_backchannel_aggressiveness` | `0.3` |
| `audio_speed` | `1.05` |
| `vad_threshold` | `0.7` |
| `vad_min_speech_duration_ms` | `120` |
| `vad_min_silence_duration_ms` | `600` |
| `min_words_to_interrupt` | `1` |
| `background_noise` / `background_noise_level` | `nil` / `0` |
| `require_speech_before_tool_call` | `true` |
| `wait_for_speech_before_tool_call` | `false` |
| `wait_for_response` | `true` |
| `forbid_speech_after_tool_call` | `true` |
| `no_input_end_conversation_sec` | `600` |

`Parlora.Providers.Phonic.default_options/0` returns the defaults without
credentials or application data. Pass only your overrides in the provider tuple;
explicit `false`, zero and supported `nil` values take precedence. Unknown names
and duplicates are rejected before merging. Invalid types, out-of-range values
and incompatible effective combinations return a startup error before connecting.

Setting `enable_assistant_backchannel: false` removes inherited aggressiveness.
Explicitly supplying aggressiveness while disabling backchannels is an error.
An aggressiveness override alone uses the default enabled backchannels.
Remaining omitted settings use Phonic's service defaults. Clinic keywords,
pronunciation dictionaries, languages and business instructions belong to the app.
The listening profile was validated with the bundled café track and tested English
voices. Validate quiet speech, accents and short interruptions for your own input;
speech detection does not identify the foreground speaker in every environment.

| Option | Accepted values |
| --- | --- |
| `enable_assistant_backchannel` | Boolean; native listening acknowledgments while the caller speaks. |
| `assistant_backchannel_aggressiveness` | Number 0–1; requires enabled backchannels. |
| `audio_speed` | Number 0.5–1.5. |
| `background_noise` / `background_noise_level` | `nil`, `"office"`, `"call-center"`, or `"coffee-shop"`; level 0–0.25. |
| `vad_prebuffer_duration_ms` | Integer 0–2,000. |
| `vad_min_speech_duration_ms` / `vad_min_silence_duration_ms` | Integer 0–1,500. |
| `vad_threshold` | Number 0.2–0.8. |
| `min_words_to_interrupt` | Integer 1–10. Raising this can delay short caller interruptions. |
| `boosted_keywords` | Unique nonempty strings, at most 50 characters each. |
| `pronunciation_dictionary` | Maps with exactly `word` and `pronunciation`; unique words, at most 30 and 50 characters respectively. Atom or string keys are accepted. |
| `intelligence_level` | `"standard"` or `"high"`; provider latency/reasoning tradeoff. |
| `default_language` / `additional_languages` | ISO 639-1 codes; additional languages must exclude the default (`"en"` if omitted). |
| `multilingual_mode` | `"request"`, `"initial"`, or `"auto"`; auto supports at most two additional languages. |
| `generate_no_input_poke_text` | Boolean; native generation of the silence prompt. |
| `no_input_poke_sec` / `no_input_poke_text` | `nil` or integer 1–120 seconds; optional nonempty text, at most 1,000 characters locally. Generated poke text takes precedence. |
| `no_input_end_conversation_sec` | Integer 30–600; adapter default 600. |
| `require_speech_before_tool_call` | Boolean; adapter default `true`. Set `false` for optional pre-tool speech. |
| `wait_for_speech_before_tool_call` | Boolean; adapter default `false`. |
| `wait_for_response` | Boolean; adapter default `true`. Set `false` for concurrent voice tools and manual result replies. |
| `forbid_speech_after_tool_call` | Boolean; default `true`. `false` requires busy mode. |

Keyword and pronunciation lists have a local capacity of 256 entries; language
lists have the same local capacity. These are adapter memory bounds. Numeric
limits and pronunciation lengths above follow the
[official WebSocket schema](https://docs.phonic.ai/api-reference/conversations/conversations)
and [official SDK types](https://github.com/Phonic-Co/phonic-python/blob/main/src/phonic/types/config_options.py).
Native backchannels acknowledge listening; they are not timed backend progress
messages and do not guarantee a shorter response delay.

```elixir
provider =
  {Parlora.Providers.Phonic,
   api_key: System.fetch_env!("PHONIC_API_KEY"),
   audio_speed: 1.0,
   wait_for_response: false,
   boosted_keywords: ["My Company", "My Product"]}
```

Execution remains async and application-owned. Changing `execution_mode` or
`allow_tool_chaining` away from `"async"` and `false` returns `:unsupported`.
Raw `tools`, transport formats, hosted-agent configuration, and arbitrary
additional parameters cannot override the adapter contract. Native speech
settings never authorize a backend action or retry an uncertain write.

Busy mode admits one pending native call. An unexpected simultaneous call fails
before delegation; duplicate IDs cannot execute twice. A queued newer task
revision can replace an unsent output on its existing call. Cancellation removes
queued correlated facts. A missing local busy-tool deadline closes explicitly
with uncertainty instead of inventing a result or retrying work. Missing native
response progress after output uses the existing response timeout.

Caller speech during a pending busy call does not arm an ordinary-response
deadline: Phonic may wait for the tool result before answering a correction.
The tool deadline remains active. A pending association to existing backend work
also stays busy until its verified result or an application clarification.
The coordinator supplies task identity, revision and provider generation through
the optional `resolve_delegation/4` callback; adapters implementing only `/3`
keep their existing behavior. Phonic keeps that metadata local, binds queued and
future updates to the active call, and rejects older revisions. It does not send
task identity as model instructions or execute another backend request.

Native tool handoffs retire the current speech generation even after audio has
started, following the [LiveKit Phonic adapter](https://github.com/livekit/agents/blob/main/livekit-plugins/livekit-plugins-phonic/livekit/plugins/phonic/realtime/realtime_model.py).
An unfinished result can resume once through its associated call. Native result
outputs contain the verified result, keeping application bookkeeping out of that
speech path. Text audio without a new speech-start marker is admitted only at a
native handoff within the same uninterrupted output epoch. After caller
interruption, a fresh native speech boundary is still required.
Native acknowledgments and result replies can have overlapping speech boundaries.
An earlier finish does not close a later reply: output stays open until every
outstanding speech end arrives. Caller interruption resets this accounting, and
unmatched starts are bounded by `limits.max_records`.
Local handoff retirement preserves those native boundaries even while local
output is idle. Late-caption recovery reuses an outstanding boundary, and an
acknowledgment ending before the result starts leaves the result watchdog intact.
Local speech state changes alone do not consume provider speech ends.

Applications must account for busy mode holding further voice tools. BookingDesk
allows only validated availability read corrections to revise an existing
correlated task without a fresh voice call. Its patient, insurance, date and
clinician checks still apply. Proposals, bookings and reminder writes retain
fresh delegation and consent requirements. The library's normal task-revision
checks reject obsolete backend results. A live wire probe also confirmed that
application clarification speech during a pending call preserves its eventual
native result response.

BookingDesk inherits the library defaults and adds clinic recognition keywords.
Use its normal recorder to exercise the profile:

```sh
cd examples/booking_desk
PARLORA_PROVIDER=phonic BOOKING_DATABASE=:memory: \
  mix run run.exs runs/phonic-native clips/reminders \
  --ambience priv/ambience/cafe/manifest.json
```

The report records library defaults in `provider_defaults` and app overrides in
`provider_options`. Use `provider_options` in `BookingDesk.start/2` or
`BookingDesk.Run.run/3` to override individual settings. Credentials are loaded
from the environment and are not included in those fields.
Its 60-second tool budget covers the example's 35-second backend deadline plus
policy processing and speech settling before output publication.

With `zero_data_retention: false`, no retention override is sent: **Phonic's
provider/workspace defaults apply**, documented as indefinite transcript and audio
retention unless configured otherwise. The development account rejected explicit
retention configuration with `data_retention_not_allowed`. Enable the required
organization feature before requesting ZDR. Synthetic probes used provider
defaults and no private caller content.

Initial history, usage reporting, and transparent reconnect are not implemented.
Transport loss closes the session explicitly and does not replay tools or
context. Although Phonic's resume protocol was verified in a wire probe, its SDK
wrappers skip outgoing messages during reconnect, including tool results; that
does not provide the delivery guarantees needed for automatic Parlora resumption.
Provider silence policies also apply: the adapter requests the documented
600-second no-input conversation limit.

## Shutdown

Application close and normal adapter termination send WebSocket close code 1000.
The adapter waits at most 250 ms (or the smaller configured session shutdown
budget) for the peer, then shuts down the transport and releases TLS state.
Writes share that short timeout. This avoids both Phonic's approximately
30-second abnormal-disconnect recovery window and OTP's default TLS close wait.
Failure paths preserve their failure classification and immediate abort behavior.
The shared WebSocket helper and other providers are unchanged.

Transport closure still emits `finalized?: false`: a WebSocket acknowledgment
does not establish that Phonic saved its conversation record. The
[shutdown validation](https://github.com/hfiguera/parlora/blob/646313a9c92759aad1cb6c527847ddd8648e36c4/validation/phonic/shutdown.md) independently checks the
saved provider records for PCM and mu-law sessions.

## Credentials and validation

On macOS, save the development credential without placing it in shell history:

```sh
security add-generic-password -U -s parlora-phonic-development -a api_key -w
```

Keep `-w` last to receive a password prompt. `scripts/with_keychain.py` supports
`PARLORA_PROVIDER=phonic` and injects `PHONIC_API_KEY` only into the child process
environment.

See [Phonic validation](https://github.com/hfiguera/parlora/blob/646313a9c92759aad1cb6c527847ddd8648e36c4/validation/phonic/README.md) for bounded synthetic
wire probes, real-adapter smoke commands, and the intentional limitations of
that evidence. The offline suite covers configuration, codec conversion,
correction and stale-result handling through real session coordination,
interruptions, acknowledgment uncertainty, deadlines, malformed input, and
process cleanup.

Official references: [WebSocket API](https://docs.phonic.ai/api-reference/conversations/conversations),
[tool execution](https://docs.phonic.ai/docs/build/tools/how_tools_execute), and
[retention](https://docs.phonic.ai/docs/platform/retention). The downloaded
documentation snapshot is preserved separately under `docs/phonic-1/`.
