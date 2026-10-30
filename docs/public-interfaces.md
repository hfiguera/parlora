# Adapter contracts and data reference

This reference describes session options, adapter callbacks, events, task decisions,
and shared data types. Start with [Getting started](using-parlora.md) for installation
and session composition; use this page when implementing an adapter or context policy.

## 1. Application and adapter boundaries

Parlora coordinates channels, full-duplex voice providers, and backend work.
Keep provider wire events, framework structs, and native resources inside their
adapters. Applications own conversation interpretation, authorization, confirmation,
and authoritative business records.

Jido, Sagents, and Legion are optional. Select one explicitly or implement
`Parlora.Backend` without installing a framework. Callback admission, operation
completion, provider acceptance, and playback are separate observations.

## 2. Process ownership and common conventions

Each adapter implements its own supervised process, referenced by a PID. The session supervisor owns adapter processes; the coordinator owns lifecycle, context revisions, and job admission. Dedicated audio processes move frames. Backend jobs and context interpretation never run inside the coordinator's or audio processes' callbacks. Session close applies the configured finish/cancel policy within a finite deadline; external effects may still require application reconciliation.

All three adapter behaviours include these callbacks:

| Callback | Return | Meaning |
| --- | --- | --- |
| `start_link(init, options)` | `{:ok, pid}` or `{:error, error}` | Start the adapter process. Options specific to the adapter configure devices, credentials, or agents. Process startup does not establish media/provider readiness. |
| `capabilities(pid)` | `{:ok, capabilities}` or `{:error, error}` | Return the effective capability struct for that role; return `:not_ready` until discovery/configuration completes. |
| `close(pid, command_id, reason)` | `:ok` or `{:error, error}` | Admit an asynchronous close request. Report completion through a lifecycle event after resource cleanup. |

`init` is `%Parlora.AdapterInit{session_id, adapter_id, generation, event_sink, audio_format, limits}`. IDs are opaque strings; `generation` is a non-negative integer changed when that adapter connection is replaced. `event_sink` is the coordinator PID. `audio_format` is the requested common format for channel/provider adapters and `nil` for a backend. `limits` contains configured queue bounds, bounds on frame size, and operation timeouts. Use `Parlora.Limits` for the current defaults and configure finite bounds for each adapter.

Startup resolves and validates the requested format. A `:ready` event contains effective capabilities and the agreed format. The default is mono PCM16 little-endian at 24 kHz; phone sessions select μ-law at 8 kHz explicitly. Start forwarding audio only after both channel and provider are ready; bound any queues that hold audio before readiness. An unsupported format fails explicitly. LocalAudio keeps native negotiation of device formats and conversion private.

Except for startup and context interpretation, callback calls perform bounded local admission or reads; they never wait for remote acknowledgment, device playback, or completed backend work. Successful admission is `:ok`; failures use `{:error, %Parlora.Error{code, message, details}}`. Initial error codes include `:not_ready`, `:unsupported`, `:invalid_argument`, `:backpressure`, `:closed`, `:timeout`, and `:adapter_failed`. Sanitize messages/details; never include credentials or raw audio.

Adapter startup runs in isolated, supervised owners rather than in the coordinator
or a supervisor callback. One `startup_timeout_ms` budget covers all three starts
and readiness, including the pipelines' initial capture drain; it is not restarted
for each adapter. Session readiness waits until that drain has completed. Status and close requests
remain available while a start is blocked. Timeout, startup failure, or closing
before readiness aborts the owners and their linked OTP descendants, including
initialization callbacks that trap exits, without calling into stalled adapters.
Partially started adapters are cleaned up and late startup cannot make the session
ready. Startup exceptions are reported through sanitized failure events. External
effects remain the responsibility of the application; stopping processes does not undo them.

Command IDs are supplied by the caller. Reusing an ID with the same command must not repeat its effects during the adapter generation; conflicting reuse fails. Retain the bounded command records needed for pending operations and reject new admission when necessary. This is not durable idempotency for business operations. A call timeout leaves admission uncertain; reconcile with that ID rather than issuing a new command automatically.

Adapters send normalized control events as `{:parlora_event, event}`. Monitor adapter processes so crashes are observable even when no final event arrives. Close is idempotent, rejects new work, and settles outstanding commands as completed, failed, or unknown within the configured shutdown deadline. Backend close follows the session's job policy and must not imply that external actions were undone.

Shutdown starts one absolute deadline before teardown. Each adapter owner admits
its close independently; a stalled callback cannot block another role, session
status, or the deadline. Independent watchers force cleanup of adapters and their
linked OTP descendants when the deadline expires or the coordinator dies. Audio
pipelines and policy workers stop independently of stalled application code.
Repeated close requests do not restart the deadline or change the admitted job
policy. Normal provider finalization and backend `:finish` may settle before the
deadline; unfinished external work remains uncertain.

Runtime command callbacks also execute in adapter owners. The coordinator keeps
processing captions, corrections, status, progress deadlines and close while an
admission callback runs. Commands execute serially per owner. Pending commands
are rechecked against their task revision before invocation; cancellation or
shutdown can discard work which has never been invoked. Completion and provider
acknowledgement events may precede the admission reply and remain authoritative.

At most `min(max_records, max_jobs + max_pending_jobs + max_pending_delegations)`
runtime commands may be pending, with at most `max_subscribers` callers waiting
on one repeated command ID. A callback has a 1,100 ms admission deadline, further
limited by a backend request's remaining job deadline. An expired queued command
reports `details.execution: :never_submitted`. A dispatched callback which fails
to return has an unknown admission outcome and initiates bounded session shutdown.
No command is retried automatically. An adapter's explicit admission error keeps
its existing known/unknown outcome semantics.

Crash cleanup also checks the OTP `$ancestors` dictionary entry, which survives
the parent's death. This reaches blocked descendants that trap exits after the
adapter's live links have disappeared. Cleanup is restricted to that owner's
ancestry; unrelated host processes and shared services remain outside its scope.

## 3. Shared data and event envelope

The shared structs below describe session data. Fields documented as optional use `nil` when unavailable; do not fabricate observations.

| Struct | Fields and semantics |
| --- | --- |
| `Parlora.AudioFormat` | `codec`, `sample_rate_hz`, `channels`, `sample_format`. Initial local format is `:pcm`, `24_000`, `1`, `:s16le`; `sample_format` is `nil` for encoded audio. |
| `Parlora.AudioFrame` | `data` (binary), `format`, `stream_id`, `generation`, `sequence`, `duration_us`, `timestamp_us` (optional), `clock` (`:local_monotonic`, `:provider`, or `:unknown`), `discontinuity` (boolean), `playback_epoch` (output only). Sequence and any derived timing must remain distinguishable from provider observations. |
| `Parlora.Event` | `id`, `session_id`, `source` (`:channel`, `:provider`, `:backend`, or `:session`), `adapter_id`, `generation`, `type`, `observed_at_us` (local monotonic time), `command_id` (optional), `request_id` (optional), `payload`, `metadata`. Vendor identifiers may appear as opaque, sanitized metadata. |
| `Parlora.ContextSnapshot` | `session_id`, `provider_generation`, `revision`, `transcripts`, `application_context`, `pending_delegations`, `tasks`. This is an immutable runtime input, not a persistence/export format. |
| `Parlora.BackendRequest` | `id`, `task_id`, `task_revision`, `provider_generation`, `delegation_id`, `input` (map defined by the application), `context` (`ContextSnapshot`), `deadline_at_us` (optional), `metadata`. |
| `Parlora.BackendResult` | `request_id`, `task_id`, `task_revision`, `provider_generation`, `status` (`:completed`, `:failed`, or `:cancelled`), `facts` (map), `summary` (optional concise verified text), `error` (optional), `metadata`. A cancelled computation does not establish that prior side effects were undone. |
| `Parlora.ContextUpdate` | `id`, `kind` (`:quiet`, `:speakable`, or `:instruction`), `content` (string), `delegation_id` (optional), `provider_generation`, `task_id` (optional), `task_revision` (optional). The provider adapter translates kinds into its supported commands. |

Transcript entries retain `speaker`, `delta`, `start_ms`, `end_ms`, `provider_generation`, and local arrival order. Delegation entries retain their opaque `id`, `provider_generation`, `offset_ms`, and handling status. Task entries retain `id`, `revision`, active request IDs, input, status, and references to confirmations and actions controlled by the application. Preserve original transcript spaces, overlaps, and late fragments.

Event IDs identify observations; they do not make events exactly-once or create a total ordering across processes. Match results to request/task revision and provider generation. Keep audio out of payloads of control events and default telemetry. Unknown observations specific to an adapter can use `:extension` with a namespaced payload; core behavior must not depend on them.

### JSON values at adapter boundaries

Parlora uses Elixir's built-in `JSON` module for provider messages, channel
signaling and Telnyx commands. Use maps, lists, strings, numbers, booleans and
`nil` for values sent over these boundaries; `nil` becomes JSON `null`.
Custom structs need a `JSON.Encoder` implementation, or conversion to plain data
before passing them to an adapter. A `Jason.Encoder` implementation alone is not
used. Legion operation results must also be JSON encodable.

### In-memory sessions and application persistence

Parlora keeps session state in memory and retains live lifecycle events plus history and application context supplied at startup. Applications can subscribe to events, store relevant facts in their own format, and seed a fresh session with selected history and verified prior outcomes. These inputs do not resume old jobs, restore adapter resources, or replay a saved runtime snapshot.

`ContextSnapshot` and `Event` are runtime structures. A built-in durable store, serialization format, schema migration, and restoration API are not provided. Live event delivery is not a durable log; applications/backend systems own authoritative business records and reconcile uncertain actions before retrying. Process restarts do not automatically recover lost session state.

## 4. `Parlora.Channel`

In addition to the common callbacks:

| Callback | Return | Meaning |
| --- | --- | --- |
| `read_audio(pid, max_bytes)` | `{:ok, [AudioFrame]}` or `{:error, error}` | Drain complete captured frames within the requested byte budget. An empty list means no frames currently available, not end of stream. |
| `write_audio(pid, frame)` | `:ok` or `{:error, error}` | Admit a complete output frame to a bounded queue; acceptance does not confirm playback. |
| `control(pid, command_id, control)` | `:ok` or `{:error, error}` | Accept `{:suppress_output, boolean}` or `{:clear_output, next_epoch}` when supported. Report effect/completion separately. |

The dedicated audio pipeline pulls input only when it has capacity and submits output with bounded admission. `max_bytes` must accommodate at least one allowed frame; otherwise return `:invalid_argument`. The public write operation accepts a whole frame or rejects it. The LocalAudio implementation handles partial native writes internally without duplicating samples. Polling/pacing intervals are implementation settings, not device callbacks into BEAM.

`playback_epoch` starts at zero. The output pipeline serializes writes and clear requests. Clearing advances the epoch, invalidates older pending output and conversion state, and rejects late writes with an older epoch. Report `:control_completed` only after buffers owned by Parlora and native state covered by the operation have adopted the new epoch. Samples already handed to the OS remain outside that guarantee. Epochs cover local buffering; they cannot identify whether future provider audio still contains an outdated answer.

`%Parlora.Channel.Capabilities{input_formats, output_formats, full_duplex?, output_suppression?, clear_scope, playback_evidence, output_pacing}` declares supported pipeline formats and controls. `clear_scope` is `:none`, `:parlora_buffers`, or `:remote_buffer`; `playback_evidence` is a list drawn from `:queue`, `:handoff`, `:estimated_device_time`, and `:device_report`. Evidence describes its source, not proof of human hearing.

`output_pacing` defaults to `:pipeline`: the session forwards output at media rate.
A channel with its own bounded queue and playback clock may declare `:channel`;
the pipeline then admits at most 20 frames per turn, stopping on empty source or
backpressure. It yields between bursts rather than inserting a timer between
every fragment of one received packet. Hints that source audio or output space is available wake
it promptly; bounded periodic polling remains the fallback. LocalAudio and Browser use this
mode so delayed provider batches can refill their playback queues promptly. The
channel must pace actual device/transport output. Input and telephony retain
pipeline pacing. Queue capacities, bounds on pending batches, clear/suppression and
deadlines for sustained backpressure still apply.

LocalAudio supports full duplex, suppression, clearing buffers owned by Parlora, and queue/handoff observations. Device selection is an adapter option, not a requirement of network channels.

Initial channel events:

- `:ready`, `:disconnected`, `:failed`, `:closed`: effective format/capabilities or sanitized reason.
- `:control_completed`, `:control_failed`: command ID, requested control, applied scope/epoch, and error if applicable.
- `:playback_observed`: stream/epoch, sequence or sample range, stage (`:queued`, `:handed_off`, `:cleared`, `:estimated_playback`, `:device_reported_playback`, or `:unknown`), and evidence source.
- `:audio_discontinuity`: stream, cause, and dropped duration/count when known. Queue overflow and device underrun must be observable.

## 5. `Parlora.Provider`

### Scope of the current provider contract

This interface supports a **continuous full-duplex voice provider with client
delegation and speakable context injection**. Built-in providers are
[OpenAI GPT-Live-1](openai-provider.md), [Gemini 3.8 Live](gemini-provider.md),
[Grok Voice 3.0](grok-provider.md), and experimental [Phonic-1](phonic-provider.md). Callback compatibility is necessary but does
not make arbitrary voice architectures interchangeable.

Before starting either audio pipeline, the coordinator requires:

| Requirement | Capability check |
| --- | --- |
| Selected pipeline format supported | Session `audio_format` appears in provider `audio_formats` and both channel format lists. |
| Concurrent participant input and generated output | Provider and channel advertise `full_duplex?: true`. |
| Delegated work executed by the application | Provider `delegation_modes` includes `:client`. |
| Results/questions can enter the ongoing conversation | Provider `context_update_kinds` includes `:speakable`. |

A provider announces effective capabilities in its normalized `:ready` event.
`start_session/1` returns asynchronously; incompatible capabilities cause a session
`:failed` event with `Error.code == :unsupported`, followed by bounded cleanup.
They do not produce session readiness or start audio pipelines.

`transcripts`, quiet/instruction context kinds, `input_mute?`, `usage?` and the
optional `output_buffer_status/1` callback are **not** startup requirements.
Applications must choose a policy that can interpret the available transcript and
application context. Passing readiness without transcripts is not evidence that a
policy that depends on transcripts will work. An absent mute or context kind must be
rejected by the adapter when requested; readiness does not imply support for it.

The session uses one selected pipeline format in both directions. A false
`same_format_both_directions?` says the provider does not impose that restriction;
it does not make Parlora negotiate different input/output formats. Internal
provider conversions and transport details remain the responsibility of the adapter.

A standalone speech recognizer, synthesizer, text-only model, turn-based pipeline,
or tool executor managed by the server does not satisfy this contract merely by emitting
audio or tool calls. An adapter/composition would need to establish the required
continuous audio, client delegation, context acknowledgment and lifecycle semantics.
Those compositions are not implemented. The built-in [Gemini](gemini-provider.md)
and [Grok](grok-provider.md) adapters translate their client functions into this
contract with the capability differences documented in their guides.

### Callbacks and observations

In addition to the common callbacks:

| Callback | Return | Meaning |
| --- | --- | --- |
| `read_audio(pid, max_bytes)` | `{:ok, [AudioFrame]}` or `{:error, error}` | Drain generated audio under the same limits on reads as the channel. |
| `write_audio(pid, frame)` | `:ok` or `{:error, error}` | Admit participant audio for paced transmission. This does not mean remote acceptance. |
| `append_context(pid, update)` | `:ok` or `{:error, error}` | Admit a `ContextUpdate`; its ID correlates subsequent acknowledgment or error. |
| `control(pid, command_id, control)` | `:ok` or `{:error, error}` | Initially `{:input_muted, boolean}`; reject unsupported controls. |

`%Parlora.Provider.Capabilities{audio_formats, same_format_both_directions?, full_duplex?, transcripts, delegation_modes, context_update_kinds, input_mute?, usage?}` declares supported formats, transcript speakers, delegation modes, and controls. The OpenAI adapter supplies the documented Live capabilities and startup limits. Validate the configured mode (`:client`) separately from other modes the service may offer; advertise only implemented behavior.

OpenAI owns Mint/WebSocket state, wire encoding, provider authentication, and protocol acknowledgment correlation. A provider adapter buffers inbound audio within limits; the audio pipeline drains it independently of backend work. Sustained overload must produce an explicit discontinuity or failure according to policy, never unbounded queues or a growing audio mailbox. The pipeline assigns output playback epochs when admitting provider frames toward the channel.

The receive budget for generated audio is `limits.provider_audio_queue_bytes`, separate
from `limits.audio_queue_bytes` for capture, playback, and provider uplink. Providers
must permit a single bounded read up to their receive budget so output clearing can
drain retained frames. `Provider.audio_limits(format)` optionally supplies storage
and age defaults; explicit session limits override them. GPT Live uses 2 seconds
of capacity and 3 seconds of local residence, Gemini 10/11 seconds, and Grok
20/21 seconds. The generic fallback remains 700 ms / 750 ms.

GPT Live rejects a whole chunk that cannot fit, clears affected output and emits
`:audio_discontinuity` plus `:output_recovery_requested` with a correlated token.
The coordinator clears pending/channel playback through an epoch barrier, then
calls optional `Provider.recover_output(pid, token, snapshot)`. GPT Live replaces
only its transport; the adapter process, logical generation, channel, backend,
tasks and request identities remain intact. It emits `:output_recovered` after a
fresh handshake. Backend result delivery waits for fresh caller speech and policy
interpretation; recovery never resubmits backend actions. Failed reconnection has
a five-second deadline. See [the recovery contract and limitations](output-recovery.md).

Generated frame timestamps use `clock: :local_monotonic` for receipt, not provider
generation time. Increasing storage adds no initial playback wait.

These recovery rules for generated audio apply during the active conversation. On
explicit close, OpenAI releases both audio queues and ignores subsequent output
audio because session pipelines have stopped. It keeps processing the socket for
acknowledgments and `session.closed` with final usage until the existing finite
shutdown deadline. Tail audio cannot cause an audio buffer failure during a normal close; timeout or connection loss still leaves finalization unconfirmed.

Initial provider events:

- `:ready`: only after the provider confirms session startup; include effective configuration and capabilities.
- `:transcript_delta`: speaker, original delta, provider start/end timestamps.
- Optional `:provider_speech`: `:speaking` or `:idle` for provider utterances, independently of background interaction, job completion and playback. Status is `:unknown` for providers without this observation.
- `:delegation_requested`: opaque delegation ID, target, and provider offset. No fabricated task text or tool arguments.
- `:context_acknowledged`, `:context_rejected`: update ID and error where applicable. Acknowledgment is not completion or playback.
- `:control_completed`, `:control_failed`: command ID and the scope established by provider acknowledgment.
- `:usage_updated`, `:usage_final`: cumulative values with explicit units and finality; never sum cumulative duration samples.
- `:audio_discontinuity`, `:failed`, `:closed`: affected stream/reason; closed reports whether provider finalization was observed.

The OpenAI adapter translates quiet/speakable/instruction updates to the three documented Live append types and preserves nullable delegation IDs. The coordinator checks current task revisions before appending; the adapter validates structure, supported fields, and limits on message counts locally. Provider acceptance/rejection is authoritative for token limits; Parlora does not promise exact local token counting. Local `:ok` admission is not validation of the token budget or provider acceptance. Report rejected appends through `:context_rejected`, correlating update IDs where available; surface uncorrelated provider errors without guessing which command failed. Do not silently truncate or automatically split/retry updates. Missing acknowledgment at shutdown remains an unknown outcome. Do not introduce a mandatory voice-turn-completed event or infer playback from transcripts.

## 6. `Parlora.Backend`

In addition to the common callbacks:

| Callback | Return | Meaning |
| --- | --- | --- |
| `submit(pid, request)` | `:ok` or `{:error, error}` | Admit a `BackendRequest` using its ID for correlation and duplicate handling. |
| `update(pid, command_id, request_id, replacement)` | `:ok` or `{:error, error}` | Request a newer revision of an active request; `replacement` is a full `BackendRequest` with the same request/task IDs and a higher task revision. |
| `cancel(pid, command_id, request_id, reason)` | `:ok` or `{:error, error}` | Request cancellation; acceptance is not confirmation. |

`%Parlora.Backend.Capabilities{updates?, cancellation, progress?, clarification?}` declares actual adapter support. `cancellation` is `:unsupported` or `:advisory`. Advertise updates/progress/clarification only when the configured agent integration can produce them. Capabilities may depend on adapter options and the chosen agent.

Initial backend events:

- `:ready`, `:failed`, `:closed`: adapter lifecycle, distinct from individual job outcomes.
- `:request_started`: request ID and task revision once execution starts, if observable.
- `:request_progress`: request ID, revision, verified facts/summary. Keep private reasoning internal.
- `:request_clarification`: request ID, revision, and the information needed.
- `:request_completed`, `:request_failed`, `:request_cancelled`: a `BackendResult` with matching identity and status.
- `:update_applied`, `:update_rejected`, `:cancellation_requested`, `:cancellation_rejected`: command/request IDs, affected revision, and supported outcome or error. A sent cancel request is not a terminal event.

Jido signals, action routes, result extraction, and completion observation belong inside `Parlora.Backends.Jido`. Configure the agent and mapping there; generic Parlora code must not assume Jido's state field names. A return from `AgentServer.call/3` does not establish that asynchronous directives finished. Run any blocking await operation in a supervised job observer, never in the session or audio loop.

Jido cancellation is advisory and depends on the configured agent's handling. Confirm the corresponding terminal outcome before emitting `:request_cancelled`; a generic failed status alone is insufficient. Associate completion with a specific request and revision. An agent's previously completed state must not complete a new request, and one completion field on the agent must not be used to correlate multiple concurrent jobs without an explicit mapping.

The optional Jido `:cancel_signal` function runs in an isolated worker with the
session's `cancellation_timeout_ms` deadline. `cancel/4` returns local admission;
`:cancellation_requested` reports signal admission to Jido and
`:cancellation_rejected` reports mapping or admission failure. Neither confirms
that business work stopped. At most one mapping per request and `max_jobs`
mappings may run concurrently. Duplicate command IDs never rerun the hook.
Exceptions, invalid signals and mapping timeouts leave the original jobs observed.
Finished requests and shutdown stop pending mappings before they can send a late
signal. Formatted Jido adapter diagnostics redact configuration and request data.

Jido validates each result mapping before it reaches the adapter process: status
must be `:completed`, `:failed`, or explicitly `:cancelled`; facts must be a map
(default `%{}`), and the optional summary must be a string. The mapped result
must fit 64 KiB. Invalid output or a mapping exception emits a correlated
`:request_uncertain` with `reason: :invalid_result`, without stopping other jobs
or retrying the operation. The backend's close event retains that request as
uncertain. Sagents and Legion continue to map only completed or failed outcomes.

If updates are unsupported, the coordinator may supersede a request and submit a replacement with a new request ID under application policy. Stale results remain recorded but are not appended as current answers. Backend/application code still checks authorization, confirmation, and current task state before side effects.

A replacement may retain the original provider delegation ID until a new call
arrives. Discarding an obsolete result preserves that provider response route
while a current request that has not been cancelled still uses it, including a queued
replacement. An obsolete request with an unshared route resolves as superseded.

## 7. `Parlora.ContextPolicy`

Backend uncertainty and expiry of the deadline for a running job retain `:uncertain` job and
task status. After context interpretation settles, the session submits one
speakable uncertainty notice for the current task revision and provider
generation. This explains the missing verified outcome without asserting
completion, cancellation, reversal, or continued execution. Obsolete notices
are suppressed; there is no automatic retry. Later verified results remain
admissible. `Parlora.status/1` exposes bounded `uncertainty_reason` and separate
`uncertainty_delivery` observations, including provider acknowledgment; these
do not establish that the notice was heard.

Queued result appends recheck task revision, provider generation, and delegation
cancellation immediately before dispatch. Cancellation applies through the
delegation's recorded task revision; a newer correction can still deliver its
result without reusing that cancelled provider route. Queued uncertainty notices
also require the job to remain uncertain. A verified terminal result arriving
before dispatch suppresses the notice and records its `uncertainty_delivery` as
`:superseded`; the terminal result follows the normal delivery checks. Updates
already dispatched retain their actual admission and acknowledgment observations.

Queued clarifications require the same current context, question command, and
active target at dispatch. New context or provider speech invalidates the queued
question; if its target still needs clarification, a bounded context recheck asks
the policy to reconsider it. Claiming or cancelling its delegation, replacing the
question, or advancing the task revision suppresses the old question. Queued
association replies rebuild the summary, task status, and delivery observation
from the current job immediately before dispatch. Cancelled or superseded
associations are not sent; association never resubmits backend work.

This application hook interprets conversation state; it is not another agent framework. Configure it as `{module, options}` alongside the adapters.

```elixir
@callback interpret(
            snapshot :: Parlora.ContextSnapshot.t(),
            trigger :: Parlora.ContextTrigger.t(),
            options :: keyword()
          ) :: {:ok, [Parlora.ContextDecision.t()]} | {:error, Parlora.Error.t()}
```

`ContextTrigger` contains `kind` (`:delegation`, `:delegation_cancelled`,
`:transcript_updated`, `:application_context_updated`, `:backend_clarification`,
or `:context_wait_expired`), `delegation_id`, `request_id`, and `task_id` (optional).
The `:delegation_cancelled` trigger requests interpretation after the provider's
cancellation is recorded in the snapshot. Supply the entire snapshot with active
tasks and pending delegations, not just the latest transcript fragment.

`ContextDecision` contains `kind`, `delegation_id` (optional), `task_id` (required when targeting a task), `expected_task_revision` (required when targeting an existing task), `anchor_task_id` / `expected_anchor_revision` (only for follow-up admission with `:start_task`), `input` (task data or clarification state owned by the application, when applicable), `message` (clarification/reason, when applicable), `recheck_after_ms` / `recheck_key` (optional for `:wait_for_context`), and `clarification_key` (optional for `:request_clarification`).

| Decision kind | Coordinator behavior |
| --- | --- |
| `:start_task` | Allocate a task/request identity and submit input defined by the application. Target either an understood pending `delegation_id`, or an existing `anchor_task_id` with `expected_anchor_revision` and no delegation for a follow-up recognized by the application. Leave `task_id` / `expected_task_revision` nil; the coordinator owns the new identity. |
| `:associate_delegation` | Claim a pending delegation as related to an existing task at `expected_task_revision`; record the association without starting work or replaying a result. |
| `:update_task` | Advance the targeted task revision and request a supported backend update; unsupported update is reported for policy to resolve. |
| `:supersede_task` | Mark the prior revision obsolete, invalidate affected confirmation, and submit a replacement request subject to admission and application policy. An optional pending `delegation_id` is validated and claimed atomically for the replacement; otherwise the existing ID is retained. Cancellation is a separate request where supported. |
| `:wait_for_context` | Keep the delegation pending or hold a task's result; reevaluate on context changes. Optional `recheck_after_ms` schedules one recheck for this target/revision; changing `recheck_key` replaces that wait. |
| `:request_clarification` | Send a concise question through the provider's path for speakable context and retain the pending task/delegation. |
| `:no_action` | Leave work unchanged; do not mark a delegation completed merely because no work starts. |

Run interpretation in a supervised task outside the coordinator. The runner records the input snapshot revision/provider generation. Apply decisions only against matching current state; discard stale interpretations and reevaluate against a fresh snapshot. Validate a decision batch before applying it; conflicting decisions for the same task are errors. Allocate IDs/revisions and enforce admission in the coordinator, not inside the policy. An empty decision list means no action.

If interpretation times out, crashes, or returns an error, emit `:policy_failed`
with `attempt: 1` and `retry?: true`, then retry interpretation once against the
latest snapshot and trigger. This retries no backend operation and releases no
held result. A successfully applied decision batch restores the retry budget;
new context arriving during failed attempts does not. A second consecutive
failure emits `:policy_failed` with `attempt: 2`, `retry?: false`, then session
`:failed` with `cause: :policy_failed` and bounded shutdown. Unfinished external
work remains uncertain. Each attempt has its own `policy_timeout_ms` deadline.
Rejected decision batches remain `:policy_rejected` admission errors.

Initial work starts from a pending delegation, which admission claims. A policy may admit a confidently interpreted follow-up without waiting for another provider delegation by setting `anchor_task_id` and `expected_anchor_revision` on `:start_task`. This creates a separate task, preserves the earlier task, and leaves the new request/result delegation ID nil. Supplying both targets or a missing/stale anchor is rejected. Existing job/record limits and validation of the snapshot revision apply. The application policy must deduplicate repeated interpretation and associate later matching delegations with the new task; association never resubmits work. Unanchored speculative initial work is unsupported. Deduplicate clarification requests by delegation/task revision and optional application clarification key so repeated decisions do not repeat the same question. Policy errors must not silently start work or interrupt the audio loop.

### Starting a follow-up versus changing a task

Use separate fields for **admission evidence** and **the task a decision affects**:

| Intent | Decision fields | Effect |
| --- | --- | --- |
| Start from a provider request | `:start_task`, `delegation_id` | Claim the pending delegation and allocate a new task/request. |
| Start a separate follow-up | `:start_task`, `anchor_task_id`, `expected_anchor_revision` | Check an existing task's revision and allocate a new task/request with nil delegation ID. |
| Correct existing work | `:supersede_task`, `task_id`, `expected_task_revision` | Advance that task's revision and allocate a replacement request. |
| Associate a late delegation | `:associate_delegation`, `delegation_id`, `task_id`, `expected_task_revision` | Associate it with the actual new task without another job or result replay. |

For example, a policy first recognizes a pending request to check order 124:

```elixir
%Parlora.ContextDecision{
  kind: :start_task,
  delegation_id: delegation.id,
  input: %{order: "124", operation: :status}
}
```

After that task exists, “What items are in that order?” can start separate work
without waiting for another delegation. Read the anchor from the current snapshot:

```elixir
%Parlora.ContextDecision{
  kind: :start_task,
  anchor_task_id: status_task.id,
  expected_anchor_revision: status_task.revision,
  input: %{order: "124", operation: :items}
}
```

Parlora allocates a **new task ID**, revision 1, and a **new request ID**. The
status task remains unchanged. The resulting request's `task_id` identifies the
new items task, not the anchor. Use the emitted `:task_submitted` request or a
subsequent snapshot to obtain that identity; do not supply it in the decision.

By contrast, “Actually, check order 123” corrects the existing task:

```elixir
%Parlora.ContextDecision{
  kind: :supersede_task,
  task_id: status_task.id,
  expected_task_revision: status_task.revision,
  input: %{order: "123", operation: :status}
}
```

The anchor is a revision precondition, not a stored parent/child relationship,
a business authorization, or an idempotency key. It may reference a task in the
current session that has completed or is still running. The usual checks for
context revisions, capacity, and conflicts within the batch still apply.
Two starts sharing an anchor, or starting
from and revising that anchor in the same batch, are rejected before admission.
The policy remains responsible for avoiding repeated starts and associating a
later matching delegation with the new task.

**Pre-release migration:** anchored starts previously overloaded `task_id` and
`expected_task_revision`. Move those values to `anchor_task_id` and
`expected_anchor_revision` only for `:start_task`. Other decisions keep their
existing fields that identify the target task. Legacy start targets, mixed delegation/anchor
references, incomplete or stale anchors, and anchor fields on other decision
kinds return a policy rejection with `:invalid_argument`; there is no silent
compatibility alias. Decisions about existing tasks and delegated initial starts retain
their behavior.

Policy implementations may use application logic or an agent/model. Parlora supplies context and enforces lifecycle/identity rules; it does not infer a universally correct task from arbitrary speech. Interpretation does not authorize business actions or prove that an earlier side effect was cancelled.

Context rechecks accept 1–60,000 ms. Omit the delay to wait only for context changes.
Repeated decisions with the same `recheck_key` do not reset the timer, including
after expiry. The optional key is an opaque 1–128 byte binary chosen by the
application. Changing it cancels the old timer and schedules a fresh recheck;
late messages from the replaced timer are ignored. Omit the key to retain the
original behavior of one recheck per target/revision. Omit the delay for no timer
mutation. Each target has at most one timer, bounded by existing delegation/task limits. Claiming or revising the target
cancels its timer; closing the session ends its ownership. The snapshot entry gains
`context_wait: %{due_at_us, expired?, recheck_key}` so a coalesced trigger cannot lose expiry.
Clarification attempts record `clarification: %{command_id, context_revision, message, input}`
on the target. The message is the submitted question, not a transcript of what the
provider actually said. `input` defaults to `%{}` and retains a map supplied by the application of at most 4,096 bytes measured with `:erlang.external_size/1`. Parlora does not
interpret it. A policy can use it to retain known fields and the purpose of its
question; this prevents a number reply from being mistaken for an answer about
which operation to perform. `context_revision` lets the policy distinguish later reply fragments
using their `arrival_order`. It is not a conversation turn boundary. Attempts are
deduplicated even after rejection or uncertain admission; they are not retried
automatically. An optional `clarification_key` (1–128 byte binary) identifies a distinct
question attempt, such as recovery for a newer caller reply. Omitting it retains
one attempt per delegation/task revision. Reusing any previous key stays deduplicated;
a new key permits a new attempt. Total attempts are bounded by `max_records`;
exceeding it rejects the decision batch with backpressure. Provider acknowledgment remains a separate event.

Provider receive failures include numeric diagnostics: queue/incoming/discarded
byte counts, capacity, oldest retained audio age, and a rolling trace of the last
64 receive/read events with relative microsecond timestamps. These contain no PCM,
transcripts or credentials. Browser signaling retains this allowlisted data and
the event source before session closure. The trace is per provider and bounded;
absence of reads shows delayed draining, but does not alone identify whether the
scheduler or downstream consumer caused it. Overflow capacity and age limits,
including their explicit failure behavior, are unchanged.

The order example chooses a two-second wait, then asks for a three-digit number
when its bounded parser cannot identify one. It accepts clarification replies containing only a number. Waiting/clarifying an existing task leaves interpretation unresolved and
holds completed results until a subsequent policy decision settles relevance.
Common status follow-ups preserve the prior order request rather than treating
every mention of “order” as a replacement. An unresolved correction remains
unresolved if a status question follows it.
The application owns order parsing, timing choices, and question wording.

OrderDesk's TypeSafe policy uses keys derived from the newest caller fragment's
`arrival_order` and its recovery phase. Unresolved input waits 1,500 ms, then
receives a 600 ms verification window before a fresh classifier check. New caller
input replaces that wait; assistant captions do not. A resolved request can proceed
immediately. Once a clarification has been sent, this policy requires newer caller
input before resolving it. New unresolved replies restart the bounded settle/verify
cycle; questions are keyed by caller revision, so each unresolved reply can receive
one question without an indefinite retry loop.

OrderDesk retains `known_order`, `known_operation`, and `missing` fields in that
clarification input. Both the submitted question and partial request reach TypeSafe.
A complete number-only reply to a question about a missing operation updates the target
and asks what to check; it does not borrow the last completed task's operation.
An unfinished initial request retains its caller text (at most 2,048 bytes) with
`number_pending?`, so a later number can complete that request before any task
exists. A leading incomplete number suffix can be rejoined with an unfinished prefix
across a segment or clarification boundary, preserving any following operation text; a complete replacement number, conflicting IDs, negation,
and new requests are never concatenated. When the operation is known and only its
order is missing, the classifier receives that operation with the parsed reply. Retained orders remain offered candidates
even after older captions disappear. Equivalent repeated forms such as “one hundred
twenty four, one two four” resolve to 124; conflicting complete IDs remain distinct.
An uncertain operation is retained as `candidate_operation` solely for a targeted
confirmation question. It is never executable without a subsequent confident
judgment. Target uncertainty asks to confirm the target instead of asking which
operation is wanted. The 0.8 classifier confidence threshold and explicit page
confirmation for writes are unchanged.

Before a task exists, the consumer assigns recovery to the pending delegation
with the newest clarification/wait revision, then clarification revision, receipt
time and ID as deterministic tie-breakers. A new delegation cannot displace an
outstanding question just by arriving. After admission, one bounded recheck per
remaining delegation associates duplicate requests against the admitted task.

For a complete application policy, see the [OrderDesk workflows](../examples/order_desk/APPLICATION.md).

## 8. Limits and persistence

Configure queue capacities, job bounds, record limits, and deadlines using
`Parlora.Limits`. Exhaustion is explicit; do not treat an admission timeout as a
verified failure of external work. See
[In-memory sessions and application persistence](#in-memory-sessions-and-application-persistence)
for persistence responsibilities and restoration limits.

## 9. Session options and behavior

- `Parlora.start_session/1` accepts `channel:`, `provider:`, `backend:`, and
  `context_policy:` tuples, plus `instructions:`, `history:`, `context:`,
  `event_sink:`, `audio_format:`, and `limits:`. The format defaults to mono
  PCM16LE/24 kHz; `Parlora.AudioFormat.pcmu()` selects mono μ-law/8 kHz. Default
  byte bounds are derived from that format; explicit byte limits remain overrides.
  It returns a coordinator PID before readiness.
  `subscribe/2`, `snapshot/1`, `status/1`, `expect_progress/4`, `resolve_progress/3`, `update_context/2`, `append_context/2`, `control/3`,
  `cancel/4`, and `close/2` form the application API. See the runnable example.
- Transcript lists are ordered from the most recent arrival to the earliest; reverse them to reconstruct arrival
  order. Timing intervals can overlap and do not establish a complete turn.
- Policy workers belong to the session's task supervisor. Jido observers belong
  to a supervisor linked to their backend. Unexpected owner death cleans these
  processes; session/adapter restart never replays jobs. Built-in Jido supports
  bounded `:finish` or `:cancel` close policies, not detached background work.
- Results arriving during context interpretation remain pending until a successful
  current policy decision settles their relevance. Policy failure leaves them
  held, while audio continues; a later context update can resolve the hold.
- Superseding work advances the current revision immediately, even if the new
  request waits for capacity. Old/uncertain jobs still occupy running capacity.
  An exhausted correction queue closes the session to avoid announcing an
  obsolete answer. A queued request's deadline can expire without executing it.
- Supported updates advance the task revision but retain the old request record
  until correlated `:update_applied`. Rejection never makes an old answer current
  again. `:update_uncertain` reports uncertain local admission. Jido advertises
  updates as unsupported; the fake adapter verifies update correlation.
- `:request_uncertain` preserves job occupancy after a deadline/observer failure.
  The final session `:closed` payload also reports previously submitted jobs with
  no terminal result as `:uncertain`; session cleanup does not establish cancellation
  or completion of their external work.
  Locally canceled queued work emits a `BackendResult` with
  `metadata.execution: :never_submitted`; this says nothing about other actions.
  Backend progress is retained on the task. Backend clarification reaches the
  policy through `:backend_clarification` with its request and current revision.
- `control(session, {:clear_output, :next}, id)` allocates a fresh playback epoch.
  Channel adapters receive the integer epoch. The pipeline, converter, Elixir
  queues, and native queue are cleared together. The native callback observes the
  epoch before completion (at most 200 ms wait); OS buffers are outside the scope.
  Repeated controls retain both identity and their original local result.
- Clear drains the full provider receive budget as well as pending pipeline frames.
  During output suppression the pipeline discards received audio on each poll, and
  drains again when resuming. Audio still in flight from the provider can arrive
  after a clear/resume boundary; these local controls do not retract remote audio.
- LocalAudio and Browser default to `playback_buffering: :adaptive`. The initial
  `playback_buffer_ms: 120` is the lower bound; the learned upper bound is
  min(200 ms, queue duration). `:fixed` selects a constant initial target.
  Local receipt timestamps and source durations supply bounded recent lateness
  history; targets increase promptly and decrease by at most 10 ms per five seconds
  of qualifying stable media. Only startup/recovery boundaries latch a new target.
  Startup starts when the target is queued or its deadline expires for a short tail.
  `playback_recovery_ms: 120` independently caps recovery waiting (0–200 ms),
  further bounded by queue duration. The actual deadline after source returns is
  min(shortage + 20 ms, cap). Adaptive recovery adds the learned increase above
  the floor to the shortage + 20 ms cushion, capped by the latched target and capacity.
  Fixed recovery caps that cushion at twice min(100 ms, initial cushion, queue duration).
  Severe stalls retain a settling interval of min(max(shortage - cap, 0), cap / 2),
  preserving headroom without an abrupt threshold jump. Short tails release at
  the deadline regardless of the target; upstream pressure can release sooner.
  Zero disables buffering. No frame is dropped or stretched by this controller.
  This is a bounded jitter heuristic, not a guarantee of future arrivals.
  Clear/suppression restart timing while preserving the learned target. Idle,
  stream changes and incompatible clocks restart the measurement baseline. The native
  target remains 30 ms. Software silence is separately observable via source/silence
  byte counters and LocalAudio's `:playback_starved` events (epoch and suppression
  state included), since feeding zeros successfully to CPAL does not increment
  native underruns. Browser instead emits `:audio_observed` measurements for
  `:source_queue_empty`, `:source_resumed`, `:cleared`, and `:closed`; these do not
  claim speech loss. See [browser diagnostics](browser-channel.md#audio-settings-and-controls).
- Capture, playback, and provider uplink queues default to 200 ms of PCM; the
  separate provider receive budget uses the selected provider profile. One bounded frame batch
  may be held by a pipeline. Sustained destination backpressure for 500 ms closes
  that pipeline/session instead of retaining arbitrarily old audio. Overflow is
  explicit. These are admission bounds, not guaranteed device latency.
  At session readiness, the input pipeline drains capture buffered during provider
  startup and emits `:audio_discontinuity` with `cause: :startup_buffer_discard`,
  frame count, and duration. It then forwards fresh capture. Output is not discarded
  by this startup operation. Applications should wait for session readiness before
  inviting speech; pre-ready capture is not promised as conversation input.
  Browser discards incoming RTP before its first valid `read_audio/2` call (the
  input pipeline's startup drain). It retains only packet/sample counts and emits
  one `:audio_observed` summary with `cause: :startup_capture_discard` when capture
  becomes active, if any packets were discarded. It does not generate or enqueue
  startup PCM. Invalid reads and status inspection do not activate capture.
  Subsequent capture overflow remains `:audio_discontinuity`.
- Live subscriptions are bounded: 32 subscribers, a 2,048-message mailbox
  threshold. A slow subscriber is detached and receives
  `{:parlora_unsubscribed, session_id, :slow_consumer}`. The threshold observes the
  subscriber's whole mailbox, so unrelated traffic can also trigger detachment.
  Applications own durable event handling. This is not a reliable event log.
- Adapter calls use a fixed one-second admission timeout. Runtime queue/job and
  policy/startup/cancellation/shutdown limits are configurable; see
  `Parlora.Limits` for defaults. NIF failures, including
  Rustler's error tuples, are normalized before reporting successful controls.
- Native builds can be disabled with compile-time `:native_audio` configuration.
  No adapter opens a device or reads a credential merely because Parlora starts.

## 10. Operational observations

`Parlora.status(session)` returns a current map, separate from the policy's context
snapshot. Its shape is `Parlora.Status.t()`. It omits transcript history, full task
inputs and backend result contents. Optional clarification records retain the
submitted question and clarification input supplied by the application, or a backend's
question payload. These may contain sensitive application data; status is not an
automatically redacted telemetry export:

- `status`, `session_id`, and local monotonic `observed_at_us`.
- `interpretation`: `:running`, `:settled`, or `:unresolved`. Settled means the last
  interpretation resolved and no delegation remains pending. A successful policy
  invocation that leaves a delegation waiting or awaiting clarification is still
  unresolved. Backend work can remain running after interpretation settles.
- `delegations`, keyed by ID: pending/claimed status, reception time, optional
  associated task/revision, and wait/clarification metadata.
- `jobs`, keyed by request ID: task/revision/delegation identity, `current?`,
  deadline, backend `status`, optional `started_at_us`/`completed_at_us`, and delivery
  observations. `:submitted` reserves a running slot; optional `admission` tracks
  the adapter callback as `:pending`, dispatched (`:started`), or replied
  (`:settled`). The `:task_submitted` event carries the actual admission reply.
  `started_at_us` is separate evidence of backend execution. An uncertain job may
  still be running.
- `playback`: the latest observation per supported stage, with evidence, epoch,
  sequence or sample range when available, and observation time. Storage is bounded
  to the six contract stages, independently of the number of frames.

Result delivery is distinct from backend completion: `:awaiting_interpretation`,
`:awaiting_provider`, `:accepted`, `:rejected`, `:unknown`, `:stale`, or
`:not_applicable` (no speakable summary). `result_command_id` correlates a result
append with provider acknowledgment. `delivery_updated_at_us` exposes how long
the observation has remained unchanged. Missing acknowledgment stays pending;
uncertain admission or evidence that the provider closed can make it unknown. There are no
automatic result retries. A later correction cannot retract an already accepted
append; inspect `current?` independently.

New session events are `:delegation_pending`, `:context_wait_started`,
`:delegation_associated` (delegation ID, task ID, and revision),
`:clarification_requested` (local admission only), and `:result_delivery`.
The last carries its `stage`, request ID, and the append command ID when present.
Existing backend, provider, and channel events remain available unchanged.

Playback observations cover the whole session and may include silence. No result ID is
inferred from audio timing. A provider acceptance event, assistant caption, or
device handoff is never treated as confirmation that the caller heard a result.
The example prints work/context transitions and displays playback details through
`/status`, avoiding a console line for every audio frame.


LocalAudio native events for capture overflow and output underrun also carry
`poll_gap_us`, `last_capture_us`, `last_playback_us`, native input/output sample
rates, and queue depths sampled after that poll's service. The telemetry from local audio polling provides wall times for the current cycle alongside historical maxima, with
session/adapter identifiers in metadata. These observations help distinguish a
long polling interval from slow work; they do not establish the cause of an OS or
BEAM scheduling delay or identify interrupted speech.

## 11. Browser channel

The browser channel reuses the same `Parlora.Channel`, PCM format, session,
provider, backend and ContextPolicy contracts. Shared callback signatures and
context semantics are unchanged. Negotiation details stay in the adapter.

`Parlora.Channels.Browser` takes a `signaling: pid` option and sends that owner
`{:parlora_browser, channel, :attached}` followed by
`{:parlora_browser, channel, {:signal, json_map}}`. The owner uses
`Browser.signal(channel, json_map)` to admit one audio offer and ICE candidates.
Only that process can submit signaling; its death fails the channel. A fresh
session is required to reconnect or renegotiate. An offer must negotiate one
bidirectional Opus audio track. Readiness follows ICE/DTLS connection, then the
existing session waits for all adapters before moving audio to the provider.

`ice_servers` configures STUN/TURN endpoints and credentials. Optional
`ice_transport_policy: :relay` requires relayed candidates on the Elixir peer;
the default `:all` permits direct or relayed candidates. Configure the browser's
ICE settings separately in the host application. To require relaying, set both peers to relay-only. Credential
issuance and operating the TURN service remain host/deployment responsibilities.

The reusable `Browser.Signaling` WebSock handler wraps this protocol. Its host
supplies a session factory, optional greeting callback, and channel options after
authentication and Origin validation. The host owns the HTTP listener, TLS, routes,
maximum simultaneous sessions and session duration. There is no library listener
or application business logic hidden in signaling.
See the [JSON handshake and minimal JavaScript client](browser-channel.md#signaling-messages)
for message shapes, offer/candidate ordering, and `attached` versus session `ready`.

Browser capabilities are mono PCM16LE/24 kHz in both directions, full duplex,
output suppression, `clear_scope: :parlora_buffers`, and `[:queue, :handoff]`
playback evidence. Handoff events identify `boundary: :ex_webrtc_admission`:
acceptance by the transport process, not remote playback or hearing. Clear resets
local encoder/output state and advances the playback epoch; previously sent RTP,
browser jitter buffers and OS buffers are outside its guarantee. Browser track
mute is independent of suppression, backend cancellation and session closure.

`Browser.observations/1` exposes bounded queue depths, RTP counters, maximum local
tick interval, source/silence playback byte counts, and discontinuity counts.
Repeated discontinuities retain cumulative counts but emit at most once per cause
per 250 ms. Neither counters nor silence identify a specific result as heard.
See [the browser guide](browser-channel.md) for configuration and bounds.


## 12. Twilio channel

`Parlora.Channels.Twilio` implements the existing channel behaviour. Start the
session with `audio_format: Parlora.AudioFormat.pcmu()` and pass authenticated
`:transport`, `:account_sid` and `:call_sid` channel options. The host owns its
listeners, routing, admission, credentials and application identity. Mount
`Parlora.Channels.Twilio.Endpoint.voice/2` and `upgrade/2` on separate POST/GET
routes. The form route's `public_url:` uses HTTPS; the upgrade's uses the exact
WSS URL Twilio received in `<Stream>`. Neither route trusts forwarded headers.

`AudioFrame.new/5` handles either supported pipeline format. μ-law has one byte
per 8 kHz sample; odd byte counts are valid and silence is `0xFF`. Frame durations,
byte budgets, provider fragments and pacing follow the chosen format. PCM local
and browser sessions keep their existing defaults. The shared pacing clock
retains microseconds, including μ-law durations that include fractions of a millisecond.

Twilio advertises clearing of remote buffers, local output suppression, and
evidence from queues, handoff, and device reports. Its 20 ms wire packets can combine several
provider frames; packet mark metadata identifies the first constituent frame.
Playback events add numeric `queued_bytes`, `inflight_bytes`, `queue_age_us` and
`ack_latency_us` where applicable. Mark latency includes network and remote
buffer time; it is not mouth-to-ear latency or a guarantee that a result was heard.
Marks outstanding at a clear become unknown even if echoed afterward. New
output waits for a fresh barrier mark. Closure reports only `scope: :stream`
and `call_ended?: :unknown`; TwiML that ends the call remains application policy.

Local queues default to 200 ms, outstanding playback to 500 ms and mark timeout
to 2,000 ms. Queue capacity, residence and settings for outstanding playback must
remain bounded. Unsent output exceeding local residence is discarded and emits
`:audio_discontinuity` with `cause: :output_stale`, `dropped_bytes`,
`dropped_frames`, and `dropped_duration_us`; temporary queue expiry does not close
the stream. Missing marks still fail at their deadline with timeout details
`reason: :playback_ack_timeout`, `inflight_bytes`, and `pending_marks`. No discard
is reported as successful playback. Queue capacity and residence must
permit at least one 20 ms packet. The WebSocket transport bounds frames to 16 KiB,
buffering before attachment to 16 messages/16 KiB and idle timeout to 30 seconds.
A normal server close awaits the peer's WebSocket close acknowledgment; session
resources are torn down independently while that bounded handshake completes.
See [Twilio integration](twilio-channel.md).

## 13. Telnyx channel

`Parlora.Channels.Telnyx` implements the existing channel callbacks using
`audio_format: Parlora.AudioFormat.pcmu()`. Its host supplies the authenticated
`:transport`, `:call_control_id` and `:call_session_id`. No session, provider or
backend callback changes are required. Shared internal media ownership, pacing,
packet assembly and mark accounting now serve both telephony adapters; each
adapter retains its own wire protocol and authentication.

Mount `Telnyx.Endpoint.webhook/2` before any JSON body parser. Its `:public_key`
is the Base64 Ed25519 verification key, and `:on_event` must perform bounded,
atomic application admission/deduplication before returning `:ok`. Only verified
raw bodies reach that callback. No network commands belong in the callback.
Use `Telnyx.Endpoint.upgrade/2` with `:authorize` to atomically compare and consume
an expiring stream token for each call before returning socket/session options.
Signed HTTP events and the media authentication header are separate boundaries.

`Telnyx.Commands.execute/5` uses explicit host credentials and stable command IDs.
Run it in supervised command workers: it is bounded blocking I/O, not a channel
callback. Its success means API acceptance; signed events establish lifecycle.
The host decides whether to answer or hang up, retains terminal identities,
prevents delayed events from restarting calls and owns the public listener.

The channel uses bounded chunk reordering (40 ms default). Missing chunks yield
a discontinuity; timestamps are not assumed to be milliseconds. Playback marks
identify `boundary: :telnyx_mark`, not human hearing. Old marks become unknown
at clear, and a fresh barrier gates resumed output. Closing reports stream scope
with `call_ended?: :unknown`. See [Telnyx integration](telnyx-channel.md).

## Output recovery pressure

Two optional adapter callbacks coordinate bounded PCM recovery without exposing
details specific to a provider to channels:

- `Provider.output_buffer_status(pid)` returns
  `{:ok, %{queued_bytes: non_neg_integer, capacity_bytes: positive_integer}}`
  for generated audio still waiting to be read by the output pipeline, or an error.
  It is a read-only snapshot; it must not consume audio or include credentials.
- `Channel.release_output_recovery(pid, epoch)` returns `:ok` or an error.
  It releases an active recovery hold for that epoch. It neither clears samples
  nor changes the playback rate. Repeated hints are harmless, mismatched epochs
  are ignored, and hints outside recovery do not change initial buffering.

For output paced by the channel only, after a backpressured write the pipeline queries
this snapshot. It requests release when provider bytes plus retained pipeline
bytes reach `min(provider_capacity / 2, channel_capacity)`. With default PCM
limits this is 200 ms upstream of the channel, including the pending batch.
This releases optional holds before the selected provider storage ceiling is approached.
At lower pressure, the recovery deadline remains capped at 200 ms and the configured
initial cushion/queue duration. The refill target is the current shortage duration
plus 20 ms, bounded by twice the smaller of 100 ms, the initial cushion and the
queue duration, and by queue capacity. Earlier shortages do not accumulate into
later targets. The channel releases when that target is available and any
settling interval for a severe stall has elapsed. Ordinary shortages within the
configured cap impose no minimum recovery time. The finite deadline drains short
tails even if they cannot meet the target.
There is no extra queue, dropping, or increase in existing capacities.

OpenAI implements the snapshot; LocalAudio and Browser implement recovery release.
Adapters without either optional callback keep their existing behavior, as do
input pipelines and channels paced by the pipeline. Unavailable snapshots do not
release recovery. Provider capacity/age errors and the backpressure deadline remain
explicit failures; this policy cannot accommodate unlimited bursts or stalls.

Telemetry `[:parlora, :audio, :recovery_pressure]` carries `queued_bytes`,
`capacity_bytes`, `pending_bytes`, and `threshold_bytes`, with `epoch` and
`accepted` metadata. Acceptance means the channel accepted an idempotent hint,
not that it changed state or that sound was heard. Clear advances the epoch and
resets recovery, preventing a late old hint from starting a new playback run.

## 14. Supported data shapes

The public structs have Elixir types for each field. These describe valid exchanged
values, not arbitrary partially constructed structs; `%ContextDecision{}` alone
is not a valid decision. Types do not introduce runtime schema validation. Decision
kind/target rules and format compatibility still apply as described above.

Only documented fields and their semantics are supported application contracts.
Private coordinator state, adapter process state, timer references, queue records and
other `@moduledoc false` modules are internal. Do not access them through
`:sys.get_state/1` in application code. Public snapshots are values, not handles
for modifying session state. No persistence schema or restoration promise follows
from these types.

### Shared conventions

- IDs are opaque strings. A nullable correlation ID means no identified target;
  do not substitute an invented provider delegation ID.
- Generations, snapshot revisions and audio sequences are non-negative integers;
  task revisions start at one.
- `*_at_us`, `observed_at_us`, `due_at_us` and deadlines use **signed local
  monotonic microseconds**. Negative values are valid. Compare them only within
  the same VM lifetime. Audio timestamps additionally use `AudioFrame.clock`;
  transcript/provider offsets use milliseconds and may be unavailable (`nil`).
- Required nullable keys are present even when their value is nil. Optional map
  keys are absent until observed. Absence does not mean failure, zero or completion.
- `input`, `facts`, `application_context` and `metadata` remain maps defined by
  the application. The application owns their contents. Open adapter payload maps
  permit extra fields; those extras do not become guarantees shared by all adapters.
- Consumers should match the fields they need and tolerate additional fields and
  unhandled events. Struct field types do not promise exhaustive error codes or
  adapter diagnostic causes.

### Context snapshots

`Parlora.ContextSnapshot.t()` exports these nested types:

| Type | Supported fields and interpretation |
| --- | --- |
| `transcript()` | `speaker` (`:user` or `:assistant`), original `delta`, `start_ms`, `end_ms`, `provider_generation`, `arrival_order`. Ordered from the most recent arrival to the earliest; `arrival_order` records a context revision, not a turn. |
| `delegation()` | `id`, `target: :client`, nullable `offset_ms`, generation, `status: :pending`, `:claimed`, or `:cancelled`, `received_at_us`; optional associated `task_id`/`task_revision`, `context_wait`, `clarification`. The map named `pending_delegations` retains claimed and cancelled entries too. |
| `task()` | `id`, `revision`, application `input`, `status`, `request_ids`, nullable `delegation_id`, `confirmation`; optional `progress`, `clarification`, `context_wait`. Request IDs are listed with the newest first and include earlier revisions. |
| `context_wait()` | `due_at_us`, `expired?`, nullable `recheck_key`. Expiry is a request to reinterpret, not proof a question was asked. |
| `policy_clarification()` | `context_revision`, `command_id`, `message`, `delivery: :unconfirmed`, application `input`. Records a policy question attempt, not confirmed delivery or playback. |
| `backend_clarification()` | Required `task_revision`; optional `question` and fields defined by the adapter to describe the information needed. Distinguish it from policy clarification by its shape. |
| `progress()` | Required `task_revision`; optional verified `facts`, `summary` and adapter additions. No private model reasoning. |

A policy clarification marker is recorded before provider command admission.
An admission error removes the matching marker and its deduplication key, allowing
the policy to reconsider the question. Successful local admission retains the marker.

Delegation status becomes `:cancelled` when the provider cancels that delegation.
The retained entry is no longer eligible to start new work. This does not confirm
that backend work stopped or that external effects were undone.

Task status is `:submitted`, `:uncertain`, `:completed`, `:failed`, or `:cancelled`.
It describes the coordinator's current task revision, not every request's execution state.
For example, a task may remain submitted while its request is queued or its result
is waiting for interpretation. Use status jobs for those distinctions.

A current task becomes `:uncertain` when its backend reports an uncertain outcome
or its running request reaches the job deadline without a verified terminal result.
This does not establish completion, failure, cancellation, or continued execution.
A later verified result may settle the task.

`confirmation` is reserved and currently nil; Parlora does not authorize or persist
business confirmations. A late delegation association is recorded on the delegation;
it does not rewrite the original request's nil delegation ID.

### Operational status

`Parlora.Status` is a module that defines only types; `status/1` still returns a map. Its required
top-level keys are `session_id`, `status`, `observed_at_us`, `interpretation`, `health`,
`delegations`, `jobs` and `playback`.

- `lifecycle()` is `:starting | :ready | :closing`. Closure is a terminal event,
  not a guaranteed pollable `:closed` status; a stopped session returns an error.
- `interpretation()` is `:running | :settled | :unresolved`. Settled does not
  mean jobs completed or a result was heard.
- `delegation()` is a projection of snapshot delegation state: required status and
  receipt time, with optional association, wait and clarification fields.
- `job()` always includes `status`, `task_id`, `task_revision`, nullable
  `delegation_id`, nullable `deadline_at_us`, and `current?`. Jobs are keyed by
  request ID. States are `:queued | :submitted | :uncertain | :completed |
  :failed | :cancelled`. Execution is separately observed through optional
  `started_at_us`; optional `completed_at_us` requires a terminal observation.
  Optional `admission: :pending | :started | :settled` describes the adapter
  command's lifecycle, independently of backend execution and its outcome.
- Optional `delivery` is `:awaiting_interpretation | :awaiting_provider | :accepted |
  :unconfirmed | :rejected | :unknown | :stale | :not_applicable`. `:unconfirmed`
  records local socket submission without provider acknowledgment; `:accepted`
  records provider acknowledgment. Neither confirms playback. Missing delivery
  means no delivery observation. `result_command_id` can be nil and
  `delivery_updated_at_us` records the latest transition. `:accepted` does not
  imply `current?`; a later correction can obsolete an accepted result.
- A current job may include task `context_wait` and either clarification shape.
  These are observations about the task, not independent job execution states.
- `playback()` includes `stage` and `observed_at_us`; evidence, stream, sequence,
  epoch and sample range are optional. The map retains the latest observation
  per stage: queued, handed off, cleared, estimated playback, device-reported
  playback or unknown. It does not correlate sound with individual job results.

### Event payloads

`Parlora.Event.t()` describes the event union. `Event.t(type, payload)` allows a
narrowed event spec. Always match both source and type before using the payload.
The envelope has nullable `command_id` and `request_id`; absent correlation must
not be guessed. Named payload types are defined in `Parlora.Event` unless another
module is specified below.

| Event | Supported payload type / minimum contract |
| --- | --- |
| Provider `:transcript_delta` | `transcript()`; snapshot generation/arrival fields are added by the coordinator. |
| Provider `:delegation_requested` | `delegation()` with ID, target and nullable offset. |
| Session `:delegation_pending` / `:delegation_associated` | Delegation ID / `delegation_associated()` containing `id`, task ID and revision. |
| Session `:task_submitted` / `:task_queued` | `task_submission()` with complete request and admission outcome / `task_identity()`. |
| Backend `:request_started` | `request_started()` with task revision; request ID is in the envelope. |
| Backend progress / clarification | `ContextSnapshot.progress()` / `ContextSnapshot.backend_clarification()`. |
| Request completed / failed / cancelled | `BackendResult.t()` directly, including correlated identity and terminal status. Terminal events emitted by the session also cover locally cancelled/expired queued requests. |
| Session `:stale_result` | `%{result: BackendResult.t()}`. |
| Session `:result_delivery` | `result_delivery()`; stage is required. The initial event emitted while awaiting interpretation has only stage; later transitions also include task/revision/delegation identity. Request ID remains in the envelope. |
| Session `:context_wait_started` | `context_wait()` with delegation or task/revision target and recheck delay. |
| Session `:clarification_requested` | `clarification()` with nullable target identifiers; command ID correlates the submission. |
| Context acknowledged / rejected | `context_outcome()`; command ID when known, optional error/unknown outcome, adapter acknowledgment detail. |
| Channel `:playback_observed` | `playback()`; required stage/evidence plus observed identifiers and adapter details. Status adds local observation time and projects only common fields. |
| `:audio_discontinuity` | `discontinuity()`; cause plus observed loss counts/durations where available. Causes and additional diagnostics are adapter-specific. |
| Failure / policy rejection / admission rejection | `error_payload()`; required `Parlora.Error`, optional contextual fields. |
| Session `:closed` | `session_closed()`; `finalized?`, nullable usage map, map from request IDs to job outcomes. Submitted work without terminal evidence becomes uncertain. |

Ready/closed events have branches for each source: `session_ready()` supplies
all three capabilities; `adapter_ready()` supplies that adapter's capabilities
(and the audio format for channel/provider). Session closure uses `session_closed()`;
`adapter_closed()` allows the adapter's supported cleanup/finalization fields.
Usage, controls, cancellation/update outcomes and `:extension` retain open map
types rather than claiming identical adapter behavior. In particular,
channel closure can establish only stream closure, not telephone call termination.
Usage is defined by the provider; OpenAI currently supplies cumulative `seconds` and
`final?` (seconds can be nil when unavailable), with optional data about the context window.
Control outcomes must be interpreted using the command, source and declared
capabilities; optional details are not universal device guarantees.

All event payloads and snapshots may carry application data. They are live
observations, not a redacted public feed or a durable event log. Status excludes
full transcripts/results but retains clarification data as described above.

## Optional provider output readiness

`Provider.arm_output_ready(pid, reader, reference)` is optional and returns `:ok`
or `{:error, Parlora.Error.t()}`. It arms at most one notification:
`{:parlora_audio_ready, provider_pid, reference}` to `reader`. Already queued audio
must trigger it too, closing the race between an empty read and arming. A new arm
replaces the previous one; notification, a nonempty read, or close retires it.
The message is a scheduling hint, not audio or playback evidence.

For output paced by the channel, the coordinator's audio pipeline arms after an empty
read. A matching hint replaces its pending timer and triggers a read promptly.
Stale references, wrong sources and obsolete timer messages are ignored. Clear
and suppression invalidate pending hints. OpenAI, Gemini and Grok implement this callback;
providers that omit it continue to work using bounded periodic polling. It is
not a startup capability requirement and does not change audio ownership, queue
limits, epochs, or backpressure deadlines.

## Optional channel output-space readiness

`Channel.arm_output_space(pid, writer, reference, bytes, epoch)` arms one
`{:parlora_output_space, channel_pid, reference}` notification when the requested
number of bytes fits the channel's output queue. It returns `:ok` or an error.
Space already available must notify too, closing the race between a failed write and arming a notification.
A new arm replaces the previous waiter. Notification, clear and suppression
retire it; an obsolete epoch cannot register a new waiter. Browser and LocalAudio
implement this optional callback. Other channels retain periodic polling.

For output paced by the channel, a matching notification replaces the pending timer and
retries retained PCM. Duplicate references, wrong channels, stale timers, and
notifications from before the clear are ignored. A blockage timeout carries its epoch and
blocked interval; a clear or successful transfer invalidates that timeout.
Readiness changes scheduling, not the playback clock, frame order, queue bounds,
the configured startup buffer, or device playback evidence.

## Provider audio timeline telemetry

See [audio measurements](observability.md#audio-measurements) for provider receipt,
queue and read events, their units, and how to correlate them with pipeline and
playback observations.

## 15. Session health and opt-in progress deadlines

`Parlora.status(session).health` exposes bounded observations without conversation content:

- `input_forwarded` / `output_forwarded`: frame and byte counts plus `last_at_us`
  for successful pipeline writes to the provider/channel adapter. Silence counts.
  These do not establish network receipt, speech or human audibility.
- `observations`: counts and last monotonic microsecond timestamps for provider
  events, nonblank user/assistant captions, delegation and channel playback events.
  These count coordinator observations, not every provider wire message.
- `expectation`: nil, or the current/latest deadline armed by the host and its outcome.

Counters are sampled concurrently, not a transaction across audio directions.
Unobserved audio has a nil timestamp. No PCM or caption text is added to health.
Opaque expectation IDs remain visible. Final session `:closed` payloads retain
health; progress timeout `:failed` payloads include it as well.

```elixir
id = Parlora.ID.new()
:ok = Parlora.expect_progress(session, id, 30_000,
  until: :assistant_caption, on_timeout: :close)
# Submit the operation only after arming. Cancel if it is rejected/interrupted:
:ok = Parlora.resolve_progress(session, id, :cancelled)
```

Timeouts are 1–300,000 ms. `until:` accepts `:assistant_caption` (default),
`:user_caption`, `:delegation`, `:conversation` (any of those), or `:explicit`.
An automatic match must be observed after arming and processed before the deadline.
Acknowledgments, silence and audio byte activity cannot satisfy the deadline.
A caption or delegation proves activity, not a correct answer to a specific task.
To verify success for a specific task, use `until: :explicit` and have the application call
`resolve_progress(session, id, :completed)` after verifying its own condition.

Every transition emits `:progress_changed` with the expectation metadata and
`status: :pending | :observed | :completed | :cancelled | :timed_out`.
`on_timeout: :notify` (default) leaves the session ready. `:close` also emits
`:failed` with `cause: :progress_timeout`, then uses existing bounded cancellation
and cleanup. It does not replay work or reconnect; submitted backend work can
remain uncertain. Hosts decide how to explain that uncertainty before retrying.

No deadline is armed automatically by Parlora. One can be pending per session;
concurrent admission returns backpressure. Identical ID/settings reuse is a no-op,
including after resolution. Conflicting reuse is rejected. Retained IDs are bounded
by `max_records`; exhaustion rejects new expectations. Closing cancels a pending
expectation; late timer messages cannot close a subsequent session/expectation.
Deadlines depend on local process scheduling, not a hard real-time guarantee.

OrderDesk opts into a 30-second opening deadline (`:conversation`, `:close`).
Recognized caller input also satisfies it, allowing callers to interrupt the
opening. It does not arm a deadline after every utterance or impose a general
turn boundary. The existing provider command acknowledgment deadline remains
independent. Public type definitions are in `Parlora.SessionHealth`.


## Gemini contract additions

Providers declare `context_acknowledgment?` (default false). OpenAI declares true;
Gemini reports `context_submitted` with `outcome: :unconfirmed` and evidence of a socket write. Status exposes this capability and distinguishes unconfirmed submission
from acknowledgment, unknown delivery, backend completion and playback.

`provider_activity` reports independent background `:in_progress` / `:idle` state.
`provider_connection` reports reconnecting/resumed transport state without emitting
a second event reporting session readiness. `delegation_cancelled` retains the cancelled call and
bound task revision; it does not prove cancellation of business effects.

Optional provider callbacks `resume_output(pid, interruption_token)` and
`resolve_delegation(pid, call_id, outcome)` support the coordinated interruption
barrier and terminal function responses for results without speakable content.
`output_interrupted` initiates the provider/pipeline/channel clear barrier. These
callbacks are optional for existing providers. See the [Gemini guide](gemini-provider.md)
for the mapping and limitations.

## Grok contract additions

Grok uses the same required capabilities, interruption barrier, and callback for completing function calls as Gemini. It supports direct PCM24 and PCMU8, both transcript speakers,
speakable updates, and a local input mute gate. It does not advertise quiet or
instruction updates, usage, individual context acknowledgments, or transparent
resumption. `session.updated` establishes configuration readiness. Explicit
continuations have a finite deadline based on the startup limit while awaiting response creation.

Caller transcription candidates are cumulative, including pre-commit `completed`
events observed with `grok-transcribe`. The adapter emits one finalized caller
entry per item after commitment; it does not concatenate those candidates or
invent timing. Generated response IDs identify discarded interrupted audio and
captions independently of backend call IDs. Function calls remain the responsibility of the application
and can outlive a spoken acknowledgment. See [Grok delivery semantics](grok-provider.md)
for configuration and delivery semantics.


## Phonic contract additions

Phonic uses asynchronous client tools with explicit reply continuation. It
supports PCM24 pipelines and converts PCMU8 internally over a PCM24 connection.
Caller word fragments and assistant utterance captions have unavailable timing.
Quiet/instruction updates submit context; speakable updates schedule a response.
Only correlated tool-output processing can acknowledge a result; arbitrary
context remains unconfirmed, so the overall acknowledgment capability is false.
Interruption events use the existing clear/resume barrier. Network loss closes
explicitly; initial history, usage reporting and transparent resumption are not
implemented. See the [Phonic guide](phonic-provider.md) for limits and retention.
