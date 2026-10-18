# Live browser call at 17:48 — remaining short playback gaps

September 21, 2026; library revision `7816663`. Investigation only: no production
behavior changed. The order correction, item lookup, delivery draft/save and spoken
save acknowledgment worked. The application disconnected with zero active sessions.

## Findings

Three retained gaps had substantial nonquiet PCM immediately before and after
inserted silence. These are server-side observations, not proof of audibility.

| Gap | Previous-to-next provider chunk interval | Provider arrival after queue exhaustion | First playback tick seeing new audio | Playback resumed |
| --- | --- | --- | --- | --- |
| 11 | 130.13 ms | 14.72 ms | 19.95 ms | 30.03 ms |
| 12 | 126.94 ms | 8.04 ms | 10.20 ms | 19.85 ms |
| 19 | 130.34 ms | 23.91 ms | 30.98 ms | 50.92 ms |

Each provider chunk contained 4,800 bytes, or 100 ms of mono 24 kHz s16 PCM.
Playback had only about 10–20 ms of headroom beyond the preceding chunk's
duration. The longer interval therefore exhausted both source and playback queues.
All three arriving packets had zero dropped bytes. Their first provider reads
occurred within 0.1 ms of arrival. Maximum pipeline tick lateness in their retained
windows was 2.4–3.6 ms; there is no evidence here of a large stalled transfer.

**Trigger:** delayed upstream availability exceeded the remaining playback cushion.
`audio_received` is measured after the provider event is decoded in the Elixir
adapter. These traces cannot separate model generation, network/WebSocket delivery,
and scheduling before that observation. Calling this an OpenAI service defect
would go beyond the evidence.

**Local amplification:** `Parlora.Playout.buffering?/3` requires a minimum recovery
wait of half the preceding shortage, bounded by half the configured recovery cap.
The playback clock rounds that wait to a later tick. Gap 19 had 90 ms queued at
41.04 ms after exhaustion, but its roughly 15.5 ms minimum wait from first seeing
new audio had not expired. It emitted another silent frame and resumed at 50.92 ms.
Thus available audio was deliberately withheld. The rule reacts to the current
shortage; it does not estimate recent provider arrival variation or maintain an
adaptive headroom target across recoveries.

`source_unavailable_us` is recorded at the first playback tick observing queued
audio, not the actual network/provider arrival. In gap 19 it was 30.98 ms, while
the provider packet arrived at 23.91 ms. Treating the entire reported value as
upstream delay would incorrectly include transfer and tick alignment.

## Reproduction

Run from the repository with the pinned toolchain and normal macOS scheduler/Rust
environment:

```sh
MIX_ENV=test mix run validation/browser-gap-20260921/call-1748/recovery_floor.exs
MIX_ENV=test mix run validation/browser-gap-20260921/call-1748/correlated_arrivals.exs
```

The direct production-Playout probe shows:

- At 31 ms: 40 ms queued, silence returned.
- At 41 ms: 90 ms queued, silence still returned.
- At 51 ms: source audio returned.

The second probe uses production pipeline/queue/playout through the existing
virtual-clock harness. It is a synthetic sensitivity test, **not an exact replay
of the whole call**. Over 20 seconds, 100 ms chunks arriving every 100 ms produce
zero gaps at all ten output-clock phases. Adding 30 ms of cumulative delay every
ten chunks produces 470–480 ms of inserted silence, including 160 ms while source
audio is queued, at all ten phases. PCM integrity and finite queue bounds pass.

That profile intentionally has a slightly slower average source rate. No finite
buffer can preserve indefinite real-time output from a persistently slower source.
The result demonstrates exposure and the recovery contribution, not that every
inserted millisecond can or should be removed without another tradeoff.

## Why the new benchmark did not catch this

Its normal jitter profile adds a bounded 0–60 ms offset to an ideal audio timeline;
it does not accumulate lateness. Its existing slower-source control intentionally
allows gaps. The three-minute test also uses bounded offsets. Those gates passed
their declared envelope; they did not establish gap-free live-provider behavior.

The next fix should evaluate an arrival-history-based, bounded cushion and remove
unnecessary recovery delay when adequate audio is already queued. Validate repeated
late arrivals, idle-to-speech transitions, interruption and cleanup, while retaining
explicit degraded outcomes for sustained underproduction. Do not simply enlarge
queues, suppress diagnostics, or claim a zero-gap guarantee from these counters.

Numeric trace excerpts and both probe results are retained alongside this report.
No raw caller audio or credentials were recorded by this investigation.
