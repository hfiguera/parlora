# Recovery fix validation

September 21, 2026. Parent revision `7816663`; reports include the modified library
hashes. This supersedes the proposed next step in the adjacent root-cause report,
while preserving that report's original observations.

## Change

- Ordinary shortages no longer incur a mandatory half-shortage wait once the
  refill target is queued. The latest call's 50 ms inserted-silence segment
  replays as 40 ms. The other two retained segments remain 30 ms and 20 ms.
- The refill target retains recent shortage history, decays by 10 ms of audio
  per elapsed second, and increases when shortages recur. It remains bounded by
  queue capacity and twice min(100 ms, configured recovery cap). An absence of
  at least 250 ms discards previous history before recomputing the target; clear
  resets it immediately. Existing queue capacities are unchanged.
- Severe stalls still need a safeguard: the minimum settling interval is now
  min(max(shortage - configured cap, 0), cap / 2). Its onset is continuous, and
  shortages within the cap have no minimum hold. The two existing full-arrival
  recording regressions retain their no-extra-gap assertions.
- Short tails still drain by min(shortage + 20 ms, configured cap); upstream
  pressure and zero-buffer operation retain their existing behavior.

The maximum configured wait remains 120 ms with default LocalAudio/Browser
settings. This is a bounded heuristic, not a promise of uninterrupted speech
from an arbitrarily delayed source. It changes neither playback rate nor samples.

## Evidence

| Check | Result |
| --- | --- |
| macOS `mix ci` | 221 passed, 3 excluded; all required static/native checks pass |
| Linux `mix ci` | Same |
| Deterministic matrix | 180/180 on each platform |
| Latest call and historical recording regressions | Pass; PCM accounting retained |
| Linux browser suite | 7/7 |
| macOS initial browser suite | 6/7; receiver concealment finding preserved below |
| macOS steady-case repeats | 3/3, zero additional concealed samples |
| Linux CPAL/Rubato virtual loopback | Pass; clear 6.543 ms, close 10.120 ms |

The new twenty-second cumulative-delay profile adds 30 ms every ten 100 ms
chunks. Comparing all ten clock phases to the pre-fix policy, starvation counters
fall from 17 to 11–13. These counters include final idle drain and do not measure
heard glitches. Total inserted silence changes from 470–480 ms to 470–510 ms:
some phases trade up to 30 ms more total silence for fewer recovery cycles. All
PCM is retained and queue bounds hold. Sustained source underproduction is an
explicit degraded case; the benchmark does not silently count it as gap-free.

## Preserved receiver finding

The first macOS steady run recorded one receiver concealment event comprising
337 samples at 48 kHz (about 7 ms). It had no interior decoded-signal silence,
no pipeline failure, zero packet loss/discards, and a maximum server tick gap
of 21.684 ms. The observation window includes lead-in and trailing idle audio;
these counters do not pinpoint where concealment occurred. Build/check activity
overlapped parts of initial validation, but that does not prove the cause.

Three subsequent steady runs passed unchanged gates with zero additional
concealment. The original `macos/report.json` remains **failed**; reruns do not
erase it or certify load tolerance. Linux passed all seven receiver cases. No
human listening verdict or live GPT-Live call is claimed by this validation.

Physical Linux audio remains unverified. Broader network/load and perceptual
release evidence remains governed by `docs/audio-readiness.md`.

The WebRTC example was repackaged, recompiled and restarted on localhost:4000
with the current library and bounded numeric call diagnostics. Its application
data was retained. No caller audio was recorded by that diagnostic launcher.
