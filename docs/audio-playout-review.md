# Source starvation and playback policy review

Reviewed September 21, 2026, against Parlora `78b1192` and the browser call
`qwG2z6uev34tB36d9VeK1mZl` (20:15:58–20:18:59 local time).
This is a source review and trace analysis, not a tested replacement playback
policy or a performance comparison of running frameworks.

Follow-up: the [whole-stream policy comparison](../validation/playout-policy-20260921/README.md)
tested immediate recovery and bounded startup/refill candidates. None was adopted:
shorter individual pauses can create later gaps, and larger refill cushions can
worsen another recording. Production playback remains unchanged; the comparison
and a regression test preserve this tradeoff.

## Who inserts the silence?

`Parlora.Playout.silence/2` produces 240 zero-valued s16 samples: 10 ms of
24 kHz mono PCM. It runs when the source queue is empty and when initial or
recovery buffering deliberately holds available audio. Browser `Media.output/2`
encodes that PCM through libopus and sends it as ordinary RTP, advancing the
sequence number and timestamp. The browser therefore receives valid audio
packets containing silence.

These observations are different from silence present in the provider's PCM,
loss concealment at the receiver, intentional stop/clear, or final-frame padding.
The browser cannot infer the missing speech from our valid zero-filled packets.
A zero packet-loss count therefore does not establish uninterrupted speech.

## What the last call establishes

The retained event log contains 30 completed queue-empty/recovery intervals.
Six have boundary peaks greater than one s16 unit on both sides. Those six last
approximately 10, 30, 40, 90, 100 and 100 ms. Boundary amplitude is evidence of
nonquiet samples, not a speech classifier or proof of an audible defect.

The recorder retains detailed timing for only the latest 16 completed intervals.
Selected excerpts and their analyzer are in
[the validation directory](../validation/audio-playout-review-20260921/).
All values below are milliseconds:

| Gap | Spacing between adjacent 100 ms provider packets | First new packet after empty | First channel admission after receipt | Empty to first playback tick seeing source | Additional recovery wait | Total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 18, nonquiet boundaries | 196.265 | 67.538 | 0.313 | 69.922 | 19.997 | 89.919 |
| 21, nonquiet boundaries | 187.683 | 73.960 | 0.526 | 79.048 | 21.013 | 100.061 |
| 22, zero boundaries | 214.703 | 104.192 | 0.072 | 109.992 | 129.982 | 239.974 |

In gaps 18 and 21, two 100 ms packets arrive close together after the shortage.
This supports late/bunched receipt as a contributor. Maximum pipeline tick
lateness in the retained windows is 2.165 and 2.073 ms respectively. It does not
support a 70–80 ms transfer stall as the main explanation. First-frame admission
does not measure the time to transfer an entire packet or burst.

There are two distinct contributors:

1. Playback exhausts its available cushion before more provider audio arrives.
   The trace cannot separate provider generation timing from network delivery
   or upstream scheduling before the receipt observation.
2. Parlora then deliberately holds returned audio to rebuild a cushion. Its
   target depends on the current shortage plus 20 ms, bounded by queue capacity,
   with a separate wait deadline. In gap 22, about 100 ms of returned PCM remains
   below the roughly 130 ms target; playback waits until the deadline. A 10 ms
   polling boundary and scheduling jitter can extend the observed wait beyond
   the nominal 120 ms cap. The boundary samples are zero, so this is not evidence
   of a 240 ms speech dropout.

The diagnostic field `recovery_target_us` currently reports the configured wait
cap, not the actual queue-duration target calculated by `cushion_ready?/2`.
Future measurements should report both quantities explicitly.

## What the other implementations do

The repositories were cloned into `/tmp/parlora-audio-review-20260921` and read
at these revisions. Links are pinned so the comparison can be checked later.

### Pipecat: SmallWebRTC output

Revision: `06cc27c0754561530f1e3c73d01768f74c1ea206`.

Its [base output transport](https://github.com/pipecat-ai/pipecat/blob/06cc27c0754561530f1e3c73d01768f74c1ea206/src/pipecat/transports/base_output.py)
assembles ordered PCM into output chunks, flushes partial tails, and handles
interruptions. The [default chunk size](https://github.com/pipecat-ai/pipecat/blob/06cc27c0754561530f1e3c73d01768f74c1ea206/src/pipecat/transports/base_transport.py)
is four 10 ms chunks.

The [SmallWebRTC track](https://github.com/pipecat-ai/pipecat/blob/06cc27c0754561530f1e3c73d01768f74c1ea206/src/pipecat/transports/smallwebrtc/transport.py#L76-L162)
splits them into 10 ms frames and schedules output against its clock. With the
default `audio_out_auto_silence=true`, an empty queue produces zeros. When data
returns, it resumes without a separate recovery-cushion gate. The producer awaits
a future completed when its chunk is consumed. Disabling auto-silence makes the
track wait for data; that does not create the unavailable audio or establish
continuous receiver playback.

This observation concerns SmallWebRTC, not every Pipecat transport. Also, its
[upstream FrameQueue](https://github.com/pipecat-ai/pipecat/blob/06cc27c0754561530f1e3c73d01768f74c1ea206/src/pipecat/utils/frame_queue.py)
has no configured capacity. Awaiting transport consumption does not by itself
bound the entire upstream pipeline. Preserve Parlora's explicit storage bounds.

### LiveKit: Agents and native audio source

Agents revision: `d896c075a250f4891ca1888dab31435d219e16f8`.
Rust SDK revision: `46ba5a0ea6aee66c9ec1b7a4f9bcad0c83b6aa87`.

[Agents output](https://github.com/livekit/agents/blob/d896c075a250f4891ca1888dab31435d219e16f8/livekit-agents/livekit/agents/voice/room_io/_output.py)
uses a 200 ms AudioSource setting plus application staging. It assembles 50 ms
frames, flushes short tails before the source runs dry, awaits source admission,
and tracks drain/interruption progress separately.

The [native source](https://github.com/livekit/rust-sdks/blob/46ba5a0ea6aee66c9ec1b7a4f9bcad0c83b6aa87/webrtc-sys/src/audio_track.cpp#L132-L234)
has a 10 ms consumption clock. It sends source samples when at least one frame
is available, otherwise zeros, and resumes on the next available frame. Its
capture callback delays producer completion when occupancy exceeds the
notification threshold. This revision permits native storage up to twice the
configured queue duration; 200 ms is neither mandatory startup delay nor an
end-to-end storage bound. These layers also have no Parlora-style refill wait.

### Receiver jitter buffering is another stage

[WebRTC NetEq](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_coding/neteq/g3doc/index.md)
estimates arrival variation, adapts target delay, accelerates/decelerates decoded
audio, and conceals unavailable packets. It also exposes replay tools and
statistics. This is receiver-side processing of RTP timing and loss. Our inference:
source PCM replaced with zeros before encoding becomes valid received content;
receiver loss concealment cannot reconstruct the intended words from it.

## Recommended engineering direction

Keep the current architecture's bounded queues, explicit clears/epochs and
single channel playback clock. The part needing a controlled comparison is the
source buffering/recovery policy. A constant copied from another framework is
not an evidence-based fix.

1. **Establish a simple reference policy:** bounded initial prebuffer, then
   resume at the next output frame as soon as source data returns. This matches
   the inspected sources' consumption behavior. Compare it against the existing
   policy; do not assume removing refill waits improves an entire call.
2. **Measure the source timeline:** retain bounded observations of receipt time,
   cumulative sample position/duration, channel admission and consumption.
   Count source silence as source media. Our provider fragments currently share
   their packet's receipt timestamp, which is not a source sample timestamp.
   Preserve packet grouping so splitting a packet does not invent arrival jitter.
3. **Evaluate bounded playout delay against those arrivals:** compare fixed delay
   candidates first. If adaptation is justified, use recent arrival variation
   relative to media duration, explicit min/max latency, and reset/discontinuity
   handling. Do not accumulate each historic starvation into future recovery
   waits. Any increase after playback starts costs delay, rebuffering, or a
   controlled change in playback rate; a target variable alone cannot refill
   an empty queue.
4. **Keep completion and interruption explicit:** flush final partial samples,
   prevent stale audio after clear, and distinguish idle media from a suspected
   mid-speech shortage. Quiet boundary samples alone must not authorize deleting
   source audio or moving conversational timing.
5. **Only consider time stretching if measured buffering cannot meet both
   continuity and latency budgets.** Use a separately evaluated, pitch-preserving
   implementation. Sample-rate conversion alone is not a transparent substitute.
   Receiver NetEq does not automatically provide this for pre-RTP source gaps.

The first experiment should therefore be a whole-stream comparison of the
current policy, immediate resumption, and bounded initial-delay candidates.
Adopt the simplest candidate that meets the agreed operating envelope. This
review does not establish a new buffer size or justify another native dependency.

## Validation required before adopting a replacement

- Capture complete bounded-duration arrival schedules, not only windows around
  already-observed failures. Changing earlier playback changes later occupancy.
  The current 16-gap ring cannot reconstruct the whole call.
- Replay identical arrivals through all candidate policies and preserve the
  input, seed, parameters and results. Include the 188–215 ms separations above,
  consecutive late packets, catch-up bursts, variable sizes, partial tails,
  continuous quiet PCM, clock phase, and sustained source underproduction.
- Measure exact source integrity, queue/age limits, startup delay, added recovery
  silence, longest internal gap, complete-stream latency and interruption tail.
  Keep latency gates fixed; making a call smoother by silently adding seconds
  of delay is not a pass.
- Retain the existing property tests and decoded-browser gates. Add received
  speech captures and listening against a known source recording; tone tests
  and boundary peaks cannot establish intelligibility or natural cadence.
- Run macOS/Linux, CPU load, long sessions and the declared concurrent-call
  capacity. Exercise network jitter/loss separately from provider arrival delay.
  Validate local audio and 8 kHz telephone paths separately from browser PCM.

There is a standard engineering approach, but no finite buffer can guarantee
gap-free real-time playback under arbitrarily late or persistently slower-than-
real-time production. A release claim must specify the supported arrival/load
envelope and latency budget, with explicit behavior outside it.
