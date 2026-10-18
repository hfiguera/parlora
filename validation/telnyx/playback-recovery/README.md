# Playback acknowledgment delay recovery — 2026-09-18

## Change

The shared Twilio/Telnyx MediaStream runtime no longer closes a call merely
because unsent local audio exceeds the 200 ms age limit. It discards expired
frames, reports exact dropped bytes/frames/duration, and preserves fresh frames.
Pruning runs on admission, output pulls and the periodic watchdog. Queues and
remote playback capacity retain their existing byte bounds; no timers or
unbounded buffers are added.

Pending remote marks are not retired, acknowledged, or refreshed by local drops.
The existing finite mark deadline (2 seconds by default) still fails a stalled
stream with unknown playback outcomes. Failures identify `playback_ack_timeout`
and pending mark/byte counts. Clear barriers, epochs and pacing remain in force.
The private OrderDesk observer retains these allowlisted diagnostics without
copying arbitrary error messages or details.

## Reproduction and evidence

The manual call reached 4,000 unacknowledged PCMU bytes (500 ms), then closed with
a channel timeout. The original observer retained only its code; it cannot prove
why acknowledgments paused or distinguish the two old timeout branches.

A controlled real-adapter probe (`before.log`) withheld acknowledgments, filled
that same window, and queued another frame. It closed after 717 ms despite the
2,000 ms mark deadline. The control with acknowledgments stayed ready.

The same probe after the change (`check.exs`, `after.log`) stays ready at 717 ms,
then acknowledges the pending marks and verifies fresh byte-exact audio resumes
with a 20 ms pacing delay. It runs locally with synthetic PCMU; no provider call
or key is required. It does not demonstrate handset audio quality.

- macOS and Linux: `mix ci` passed, **168 tests passed, 3 excluded**, plus native
  checks, Credo/ex_slop, zero-clone ex_dna, Credence and Dialyzer.
- Both consumer suites: **95 tests passed**.
- New Telnyx regressions cover the default window, bounded full-queue admission,
  stale frame removal, resumed fresh audio and pacing, a delayed clear barrier,
  and permanently missing marks still failing at the deadline.
- The existing Twilio stale-output test now checks recoverable discard. Its
  missing-mark and clear tests continue to enforce finite failure and evidence.
- The observer regression checks preserved diagnostic fields and redaction.

## Limits

Discarded stale speech can produce an audible gap during congestion. This change
keeps latency and memory bounded and avoids an unnecessary hangup; it does not
promise lossless playback through an arbitrary network pause. A genuinely stalled
connection still ends at its mark deadline. No new live handset test is claimed.
