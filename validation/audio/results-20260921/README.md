# Audio baseline — September 21, 2026

**The defined local gates pass. This is not a production certification.**
Production library code was unchanged from `96ba195`; this work adds measurement,
fixtures, regression tests and CI gates. See [the contract and commands](../../../docs/audio-readiness.md).

## Final evidence

| Check | macOS arm64 | Linux x86_64 |
| --- | --- | --- |
| Full `mix ci`, pinned Elixir 1.20.4 / OTP 29.0.6 | 215 passed, 3 excluded; all static/native checks pass | Same |
| Deterministic PCM matrix | 160/160 | 160/160 |
| Browser: steady, jitter, burst, variable, interruption, disconnect, reconnect | 7/7 | 7/7 |
| Analyzer regression/negative controls | 9/9 | 9/9 |
| Three-minute browser jitter run | Pass | Not run |
| CPAL/Rubato virtual loopback | Not part of this run | Pass |

Final reports: [macOS](macos/report.json), [Linux](linux/report.json),
[three-minute run](macos-soak/analysis.json), [check logs](checks/).
Five uninterrupted ten-second receiver scenarios per OS had zero internal
low-signal milliseconds and zero additional concealed samples. Both interruption
captures contained a 500 ms intentional low-signal interval, accepted clear,
rejected old-epoch audio, resumed, and cleaned up. Startup across the browser cases
was 68–204 ms at the **decoded track**, not at a speaker.

The three-minute run delivered a 180,020 ms active signal, with zero internal
silence and zero additional concealment; decoded startup was 186.3 ms. Receiver
time adjustment was retained rather than mistaken for missing source PCM.
This single bounded run is not a clock-drift or capacity qualification.

A separate [synthetic speech capture](speech/browser.json) delivered all 647,676
source bytes and cleaned up without a pipeline failure. No human listening verdict
is claimed; its natural silence is not evaluated by the chirp detector.

The Linux native loopback measured clear at 6.8 ms and close at 10.123 ms, with an
approximately 80 ms capture tail, silence after stopping, and restored tone after
resume. Physical Linux audio remains unverified.

Two concurrent 30-second macOS captures also passed the earlier Worklet-based
checks, one with four CPU workers. They are retained under `diagnostics/` as
supplemental observations, not pooled with the final direct-track baseline.
Linux Chromium used Playwright's Ubuntu 24.04 fallback build on an unsupported
distribution. CI should establish its own baseline on its declared platforms.

## Failures preserved and measurement fixes

Reports named `analysis-before-edge-fix.json` and `report-before-edge-fix.json`
retain the earlier decisions. `diagnostics/` retains earlier Worklet and soak
findings. They are not extra production failures or extra independent passes.

1. **WebAudio capture branch:** repeated Linux CPU-load captures showed 9–10 ms
   holes in the AudioWorklet sidecar while simultaneous MediaRecorder captures
   stayed continuous. Direct decoded-track capture avoided those holes. The
   final primary boundary uses `MediaStreamTrackProcessor`; Worklet and WebM
   remain diagnostic sidecars. This does not prove physical speaker continuity.
2. **Codec transition edges:** coarse 10 ms active bounds applied inconsistent
   edge exclusion. A 1 ms quiet interval in an Opus tail and a 1 ms quiet interval
   immediately after interruption recovery incorrectly failed continuity.
   The analyzer now applies its explicit 10 ms codec-edge guard at 1 ms precision,
   including intentional interruption edges. Negative controls still reject a
   5 ms interior gap and a separate gap beyond that guard. The 40 ms duration
   budget independently bounds truncation; this is not sample-exact Opus audio.
3. **Receiver time adjustment:** the initial duration check ignored NetEq
   acceleration/deceleration. Final duration accounting uses those recorded
   counters, with their documented observation-window limitation.
4. **Soak fixture:** the first attempt hit a signaling idle timeout. Five-second
   heartbeats corrected that fixture. The next run generated its entire signal
   after starting the timer, reporting 511 ms startup. Precomputing before listener
   readiness removed that measurement error; the final run passed at 186.3 ms.

No queue budget, buffering policy or production audio behavior was relaxed to
produce these results. Original observations remain available even where the
measurement method was corrected.

## Reproducibility and limits

Reports identify platform, library and harness hashes. Linux is an rsync mirror,
so its Git revision/dirty fields may be unknown; matching source hashes identify
the library. Final summaries were regenerated with the corrected analyzer from
the same recordings, rather than presenting reanalysis as new calls. The initial
macOS/Linux suites briefly overlapped their respective `mix ci` runs; they were
not idle-machine latency measurements.

Raw WAV/WebM captures are synthetic and remain in the local `/tmp` directories
identified by `local-capture-manifest.json`; these paths are temporary, not a
durable artifact store. Committed JSON/logs preserve outcomes. CI uploads the full
capture directory, including failures. The committed speech fixture can reproduce
the speech probe; listening to it is a separate human assessment.

Still needed before broader release claims:

- Controlled network loss, reordering and latency, distinct from provider jitter.
- Longer soaks, memory trends and a measured concurrent-call capacity envelope.
- Physical macOS playback/listening and received speech comparisons.
- Twilio/Telnyx receive-side recordings and interruption latency.
- Per-environment end-to-end latency distributions and agreed release SLOs.

The fixtures do not exercise a live GPT-Live session, interpretation/backend work,
or production session admission. Existing functional suites remain separate.
