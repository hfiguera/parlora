# Phonic provider

`Parlora.Providers.Phonic` is an experimental Phonic-1 speech-to-speech adapter.
It connects directly to `wss://api.phonic.ai/v1/sts/ws`; applications continue
to own their channels, context policies, backend execution, and task revisions.
No Phonic SDK or persistent hosted agent is required.

## Integration status

Phonic-1 is accepted into Parlora as an **experimental speech-to-speech provider**.
The adapter has offline regression coverage, successful live-service probes,
and a successful manual OrderDesk workflow. OrderDesk is a separate example
application used to exercise the integration.

The longer automated OrderDesk workflow now passes repeated live runs after
Phonic continuation and reply-coordination fixes. The [stall investigation](https://github.com/hfiguera/parlora/blob/646313a9c92759aad1cb6c527847ddd8648e36c4/validation/interpretation-scheduling/stall-investigation.md)
and [reply-coordination follow-up](https://github.com/hfiguera/parlora/blob/646313a9c92759aad1cb6c527847ddd8648e36c4/validation/interpretation-scheduling/reply-coordination.md)
record the reproduced causes, regressions, cross-provider checks, and evidence
limits. This qualifies that workflow; experimental acceptance does not establish
general production readiness. See also the
[acceptance evidence](https://github.com/hfiguera/parlora/blob/646313a9c92759aad1cb6c527847ddd8648e36c4/validation/phonic/README.md#acceptance-decision).

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
Assistant audio text shares a locally assigned `segment_id` for each utterance.
Neither transcript establishes that the caller heard the audio.

## Tools, context, and corrections

Tool chaining is disabled (`allow_tool_chaining: false`) to avoid the repeated-call
bursts observed in validation. This also restricts autonomous sequences of tool
calls by the voice model.

Phonic tools run asynchronously with `wait_for_response: false`, allowing further
caller corrections and tool calls while backend work is pending. The alternative
busy mode suppresses other tools, so the adapter does not select it.
`forbid_speech_after_tool_call: true` suppresses automatic post-tool speech;
the adapter requests the result reply explicitly. Pre-tool acknowledgments remain
optional, and new caller input can still initiate unrelated work or corrections.

The adapter exposes client calls as `delegation_requested`; the normal Parlora
context policy decides whether and how to admit work. Provider arguments are
context, not execution authority. Call and command IDs have bounded, retained
deduplication records. Conflicting duplicates and superseded results are rejected.

- `:speakable` context is admitted to a bounded local queue. Once caller speech,
  the automatic/current response, and the receive queue settle, the adapter
  completes the tool call or injects a system message and requests one explicit
  reply. Keeping the facts out of the earlier turn avoids an automatic answer
  followed by a second announcement. Multiple pending updates can share a reply.
  `context_submitted` is emitted only when the queued command is actually written
  to the socket. This does not wait for physical playback.
- `:quiet` and `:instruction` inject a system message without scheduling speech.
  A delegation ID is supported only for speakable context.
- If a clarification already completed a call, later verified results use a new
  system message. Expired calls also use new context; their old tool outputs are
  never resent.
- `resolve_delegation/3` closes associated or superseded calls without scheduling
  a duplicate response for an already covered result. A result reply that yields
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
| `tool_timeout_ms` | `30_000` | Between 1,000 and 180,000 ms. Align with backend deadlines. |
| `acknowledgment_timeout_ms` | `5_000` | Between 1 and 60,000 ms; missing tool-output acknowledgment remains unknown. |
| `response_timeout_ms` | `15_000` | Between 1 and 60,000 ms; missing response lifecycle progress closes explicitly. |
| `early_delegation` | `false` | Requests tool calls during caller speech; requires organization enablement. |
| `zero_data_retention` | `false` | When true, explicitly requests ZDR; rejection never falls back to retention. |

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
