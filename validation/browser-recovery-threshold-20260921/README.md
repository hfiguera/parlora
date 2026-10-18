# Remaining browser recovery gaps — September 21, 16:21 call

Investigated commit: `cdb5032`. The findings below describe that commit; the
implemented correction is documented at the end. The three numeric trace excerpts
come from `/tmp/parlora-call-20260921-1621-traces`, preserved before the rolling
recorder overwrites them. Session: `F7XNAma5zNa0_CMckKU4dU-z`.

## Findings

All three gaps reproduce exactly using production Browser.Media, Playout and
Opus with recorded channel-write/output schedules and synthetic PCM. This rules
in the software timing mechanisms below; it does not establish perception or
recover the original speech samples.

### 1. Polling can miss a playback deadline even when source already exists

For gap 4 (80 ms inserted silence), the next 100 ms provider batch was handled
**1.650 ms before** the first silent output block. The empty-source poll at
-3.162 ms preceded that arrival. The next read was at +7.842 ms, the first frame
reached the channel at +7.899 ms, and output observed it at +9.908 ms.

Thus this gap did not start because no source existed anywhere in Parlora:
4,800 bytes were already waiting in the provider queue at time zero. The empty
pipeline polls roughly every 10 ms (`AudioPipeline.forward/1`) instead of waking
on source availability. With the channel cushion exhausted, its phase relative
to provider arrival and the output clock matters. Prompt writes after the poll
cannot undo an output block already rendered as silence.

For gap 9, the next provider message arrived at +5.571 ms (218.142 ms after the
preceding 100 ms batch). The first channel frame was at +13.069 ms; output saw
source at +21.038 ms. This contains both an upstream arrival shortage and local
poll/output-clock delay.

For gap 14, the interval between 100 ms provider batches was 204.488 ms. The next
batch was handled at +60.079 ms, its first frame reached the channel at +65.992 ms,
and output saw source at +69.990 ms.

Provider timestamps are local handler observations. They cannot distinguish
remote generation, transport jitter, or scheduling before that handler. No
100 ms pipeline execution stall is supported: maximum recorded pipeline work
for gaps 4/9/14 was 737/534/286 microseconds, and tick lateness stayed below 2.1 ms.
There were no blocked transfer ticks or recovery-pressure releases in these gaps.

### 2. Every starvation starts a minimum recovery hold

Once playback has emitted an empty block, `Playout.buffering?/3` requires half
the recovery deadline (60 ms by default), even when the returning batch has
already reached the 100 ms refill target. This turns the brief shortages in gaps
4 and 9 into substantially longer software silence.

Exact monotonic comparisons add output-clock quantization:

- Gap 4: first source at +9.908 ms; the +69.900 ms tick is only **59.992 ms** later,
  so it fails the 60 ms minimum by 8 microseconds. Source resumes at +79.866 ms.
- Gap 9: first source at +21.038 ms; the +79.993 ms tick is **58.955 ms** later,
  so source resumes at +90.966 ms.

The measured recovery waits are consequently 69.958/69.928 ms, rather than exactly
60 ms. This is packet-clock/deadline quantization, not a roughly 70 ms CPU stall.

### 3. The duration threshold retains a conservative second-batch wait

The last fix deliberately preserved more buffering after longer shortages to
avoid reintroducing gaps in older fixtures. In `Playout.cushion_ready?/2`, a
shortage longer than half the deadline doubles the queued target from 100 ms to
200 ms. This is a discrete threshold, and shortage includes local polling and
output-clock delay as well as upstream arrival delay.

Gap 14's measured shortage was **69.990 ms**, so it selected the 200 ms target.
The first 100 ms batch was fully in the channel by +83.995 ms. At +130.002 ms,
the minimum refill wait had elapsed, but only 100 ms was queued. The second batch
arrived at +160.193 ms. At +180.062 ms the channel still held only 8,640 bytes;
source resumed at +190.023 ms with 9,600 bytes available.

At that final tick both the queue condition and the 120 ms refill deadline were
satisfied. The observation reports `queue_ready` because that reason has priority
in the implementation; it does not establish that the deadline was still pending.

The **190 ms** inserted silence is therefore about **70 ms source unavailable at
playout plus 120 ms recovery**. The last fix improved the short-shortage branch;
it did not eliminate the cost of this deliberately retained long-shortage branch.
This is not overflow, dropped PCM, or an old server missing the change.

## Production replay and diagnostic controls

Run the original diagnostic replay from commit `cdb5032` with these fixtures
and the pinned toolchain (its exact baseline assertions intentionally describe
the old implementation):

```sh
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin \
  mix run validation/browser-recovery-threshold-20260921/replay.exs
```

The replay asserts the actual elapsed duration, inserted-silence count, source
unavailability, recovery wait and resume occupancy for the current policy. All
supplied source bytes are consumed after draining. Results are in
`replay-results.json`.

| Recorded gap | Current inserted silence | Half-target diagnostic | Disabled-recovery diagnostic |
| --- | ---: | ---: | ---: |
| 4 | 80 ms | 80 ms | 10 ms |
| 9 | 90 ms | 90 ms | 20 ms |
| 14 | 190 ms | 130 ms | 70 ms |

The half-target control changes only the internal base target (50 ms, doubled
to 100 ms for the long gap). It retains the minimum wait. It therefore isolates
the target's contribution to gap 14 and demonstrates that reducing the target
alone cannot improve gaps 4/9: their binding constraint is the minimum wait.
Disabled recovery isolates the full hold but is not a recommended fix.

These controls reuse recorded downstream transfer times. They do not simulate
source-ready wakeups, predict future arrivals beyond the retained window, or
validate a replacement recovery strategy. Earlier fixtures already showed that
always reducing the target or removing refill waiting can cause repeated gaps.

## Consequence for the next fix

Another blanket buffer reduction would address only part of the mechanism.
Evaluate source-availability-driven refill (with bounded/coalesced wakeups) and
a recovery decision that distinguishes a missed transfer deadline from sustained
upstream jitter. Any change must retain the recorded older repeated-gap and
overflow cases, bounds, ordering, short tails, clear/epoch handling, and fresh
listening validation. Absolute timer checks and a duration-only doubling rule
should not be treated as proof that the selected cushion is necessary for the
actual arrival pattern.

## Implemented correction

Empty channel-paced output reads now optionally arm one provider-ready hint.
OpenAI sends it once when audio is available, including arrival before arming.
The pipeline replaces its timer and ignores obsolete hints/timers. This removes
the intentional polling delay without adding a second media clock or unbounded
notifications. Clear/suppression invalidate hints; providers without the callback
retain polling. Queue capacities and backpressure deadlines are unchanged.

Recovery now uses the observed shortage continuously. At defaults the PCM target
is shortage + 20 ms, bounded to 20–200 ms and channel capacity. Minimum hold is
half the shortage, capped at 60 ms. Deadline is shortage + 20 ms, capped at 120 ms.
Short tails and pressure release remain supported. These are measured heuristics,
not a guarantee of future arrivals or freedom from gaps.

Run `mix run validation/browser-recovery-threshold-20260921/fixed_replay.exs`
using the same toolchain environment above. `fixed-replay-results.json` retains
results with the original downstream transfer times:

| Gap | Before | Fixed inserted silence | Fixed recovery wait |
| --- | ---: | ---: | ---: |
| 4 | 80 ms | 20 ms | 9.929 ms |
| 9 | 90 ms | 40 ms | 19.012 ms |
| 14 | 190 ms | 110 ms | 39.999 ms |

All supplied source bytes are consumed in order. This replay isolates recovery:
it does not model the new readiness wakeup or establish what a listener hears.
It cannot remove time when source is actually unavailable. New recorded-gap
regressions retain those shortages and assert the improved silence counts.
Older short/long repeated-gap and burst/overflow fixtures remain unchanged.
Readiness tests cover actual WebSocket arrival, arrival-before-arm, one-shot
coalescing, arm replacement, timer replacement, stale/wrong-source hints,
clear/suppression and close.

### Verification and server

- macOS and Linux, Elixir 1.20.4 / OTP 29.0.6: root `mix ci` passed, **212 tests,
  3 excluded**, native checks, Credo/ExSlop, ExDNA zero-clone budget, Credence,
  and Dialyzer. Hardware/live/stability exclusions remain explicit.
- Rebuilt the source package and refreshed the example's vendored dependency.
  Example format, warnings-as-errors compilation and **143 tests passed** on
  each platform. Logs are retained alongside this report.
- The idle browser server restarted at 16:42:37 MDT with this package on
  `http://localhost:4000/`; health reported zero active sessions. New trace
  directory: `/tmp/parlora-browser-audio-trace-ready-fixed`.
- No fresh live listening call has been evaluated after this correction.
  Audible continuity still requires that evidence; replay counters alone do
  not certify call quality. Physical Linux audio remains unverified.
