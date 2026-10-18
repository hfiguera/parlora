# GPT Live output overload recovery

The generation reservoir and the playback cushion have separate purposes. GPT
Live defaults to 2 seconds of received audio (96,000 bytes PCM16/24 kHz mono,
16,000 bytes PCMU/8 kHz) with a 3-second local residence deadline. Browser and
LocalAudio keep their adaptive 120 ms floor and 200 ms ceiling. This storage
change adds no initial wait and does not change playback rate or samples.

`Parlora.start_session/1` merges optional `Provider.audio_limits/1` defaults with
explicit application limits. Gemini and Grok retain their respective 10/11- and
20/21-second capacity/age profiles. Other providers retain generic 700 ms / 750 ms
limits. Direct adapter consumers must pass an appropriate `AdapterInit.limits`.

## Hard-limit recovery

An OpenAI `:output_overflow` or `:output_stale` is a recoverable media condition.
The adapter clears its receive queue, quarantines old output/events and emits
`:audio_discontinuity` with evidence of dropped bytes and `:output_recovery_requested`
with a monotonic transport token. Invalid audio remains a fatal protocol error.

The coordinator clears the pipeline's pending output and the channel through
its existing playback-epoch barrier. User suppression remains active. It calls
optional `Provider.recover_output/3` with a bounded snapshot of caller context and
current task facts. Clearing cannot retract audio beyond the channel's declared
clear scope, such as audio already transmitted to a browser or carrier.

The OpenAI adapter asynchronously creates a passive Mint connection, transfers
socket ownership, completes a fresh GPT Live handshake and emits
`:output_recovered`. There is at most one replacement worker; stale tokens,
sockets and pacing timers cannot revive old output. Close cancels the worker and
still has a finite deadline. Reconnection, including its playback barrier, must
complete within five seconds; a dead/unavailable replacement transport is still
fatal. Ordinary successful recovery leaves the caller's channel connected.

The adapter process and logical provider generation remain unchanged. A transport
epoch identifies the new upstream conversation. Existing job IDs, revisions,
backend processes and backend execution remain intact. Old upstream delegation
IDs are retained locally, but their context deliveries become updates for the
session as a whole on the new voice connection. Commands interrupted before acknowledgment
are reported as unknown; they are not blindly replayed. New application context
can be admitted during reconnect within the existing limit on command records.

## Conversation and input safety

Recovery restores original application instructions, a bounded portion of supplied
history, recent caller text and bounded current task facts/verified results.
Generated assistant captions are not seeded as heard messages. A fresh instruction
requests a short notice about audio recovery and asks the caller to repeat.

Microphone frames during the unavailable voice interval are explicitly discarded
and counted in one input `:audio_discontinuity` with cause
`:voice_transport_recovery`. This avoids a permanently delayed microphone or
sending buffered speech faster than the provider's documented pace for live input.
Audio during that short interval is not promised as recognized caller speech.

The coordinator holds backend results through reconnection and until fresh caller
speech has been interpreted. Thus a correction can supersede the old result before
it is announced. New speakable application updates also wait for caller resumption.
No backend submission or action retry is part of recovery. Ordinary application
policy still owns delegation association, handling of repeated requests and permission
for business actions; reconnect is never authorization to execute them again.

GPT Live can delegate before its caller caption arrives. During resumption those
calls are bounded by `max_pending_delegations` and wait for the first fresh caller
interval. Calls timestamped before that interval are not dispatched as new work.
This admission boundary is based on the timeline; it does not guarantee that speech was recognized.

Transcript and delegation timestamps are rebased onto the retained logical timeline.
The browser starts a fresh caption grouping epoch on recovery. Old fragments cannot
merge into a repaired reply solely because their timestamps are adjacent.

The latest observed usage from interrupted transports contributes to subsequent
observed totals, but missing finalization is retained: `complete?: false` and session
`finalized?: false` remain false even if the final replacement closes gracefully.
These are observed totals, not a confirmed final billing statement.

`Parlora.status/1` includes `output_recovery`, either nil or a map containing token,
cause, started time and stage (`:reconnecting` or `:awaiting_user`). The session can
remain `:ready` while the voice path is being recovered. Readiness alone therefore
does not promise uninterrupted audio.

## Application behavior

Recovery cannot recreate audio that the provider did not supply or prove that a
caller heard an earlier result. Monitor session failure/closure, offer a clear reconnect
path, and reconcile uncertain business operations before retrying them.
