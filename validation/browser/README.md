# Browser validation

`mix run validation/browser/media_diagnostics.exs` (from the repository root)
checks startup discard and the playback observations at normal
clip endings and genuine source gaps. It uses native Opus without devices or
network access. See the [diagnostic investigation](../../docs/browser-audio-diagnostics-investigation.md).

Run `npm ci` here. For automated CI, `npx playwright install --with-deps chromium`
installs the test browser; on the development Mac use `BROWSER_CHANNEL=chrome`
to exercise installed Chrome. Microphone checks default to full Chromium's
headless mode (`channel: 'chromium'`). On Linux, the pinned default headless shell
returns `NotSupportedError` for microphone capture, including when permission is
denied. Playwright is validation tooling, not a Parlora or
consumer runtime dependency.

For caption grouping regressions, run from the repository root:

```sh
node --test validation/browser/*_test.cjs
BROWSER_CHANNEL=chromium node validation/browser/caption_layout.cjs /tmp/new-caption-layout
```

The layout check uses canonical HTML/CSS and the actual caption callback with
synthetic fragments, without microphone, provider requests or database writes.
It asserts separate draft, trailing reminder and save rows (including a reminder
and save in one delta), and no horizontal overflow at 1280 and 375
pixels, retaining screenshots and a report. Both checks run in CI. The
[October 3 fix qualification](caption-grouping-20261003/README.md) also includes
a real GPT Live 1/Sagents browser-confirmation test.
The [sentence grouping follow-up](caption-sentences-20261003/README.md) covers the
remaining manual-call edge case and stronger caption assertions.

`guide_test.cjs` executes the exact JavaScript in the public browser guide. It
checks offer/candidate ordering, async answer application, readiness, keepalives,
permission denial, and cleanup across late permission/offer completions.
Against a dedicated offline consumer, run the copied HTML in real Chromium:

```sh
PARLORA_BROWSER_OFFLINE=1 BROWSER_CHANNEL=chrome node validation/browser/guide_client.cjs
```

Run from the repository root; `BROWSER_URL` defaults to `http://localhost:4000`.
This checks bidirectional RTP and decoded audio energy through real signaling,
native Opus, reconnect, and cleanup after Disconnect and page closure. It runs
in CI alongside the existing browser smoke test, without provider credentials.

Start the separate consumer with `PARLORA_BROWSER_OFFLINE=1 scripts/browser.sh`,
then run `BROWSER_CHANNEL=chrome npm test`. `BROWSER_URL` defaults to
`http://localhost:4000`. The script waits up to 60 seconds for the listener.
It checks microphone denial, rejected Origin, three full connections, decoded
audio energy, RTP in both directions, finite queue depths, controls, and cleanup
following disconnect and page closure. A fourth connection loses signaling through
Chrome network emulation and must clean up within the 30-second inactivity budget
plus observation margin. The microphone is synthetic. One-second
warmup and three-second steady intervals keep receiver concealment distinct from
server source starvation. Output is one numeric JSON report; no audio is recorded.

With the [coturn setup](../turn/README.md), set `EXPECT_RELAY=1` to require both
selected candidates to be relays and test wrong credentials without direct
fallback. `turn_failure.cjs` separately stops/restarts the dedicated Linux test
service when explicitly enabled with `PARLORA_TURN_FAILURE_TEST=1`. Do not run it
alongside other TURN calls. Both probes record selected path metadata without
logging TURN credentials. The live harness also supports `EXPECT_RELAY=1`.

For the explicitly authorized **live** check, start `scripts/browser.sh` without
the offline flag, then run on macOS:

```sh
PARLORA_BROWSER_LIVE=1 node live_order.cjs
# Against a Linux server reached through the documented SSH tunnel:
PARLORA_BROWSER_LIVE=1 BROWSER_URL=http://localhost:4001 node live_order.cjs
```

This opens installed Chrome with actual microphone access and uses macOS `say`
as an acoustic caller through the speakers. It suppresses output while each caller
utterance plays to avoid overlapping synthetic speech, then resumes. It checks
order 123 → 124, accepted current delivery and stale old work. It logs the scripted
catalog conversation and numeric WebRTC observations, without recording audio or
retrieving credentials itself. The host launcher owns credential retrieval. The
script closes the browser in `finally`; individual waits and the host's call
lifetime are bounded. This is a paid-provider integration test, not ordinary CI.

Captions, decoded energy, RTP counters and a configured physical speaker path do
not establish that a human heard a specific answer. The controlled suppression
is not proof of acoustic echo cancellation quality or automatic barge-in.

## Consolidated application acceptance

The six conversation scenarios now have a single runner. From the checkout:

```sh
scripts/acceptance.sh /absolute/path/to/consumer
# Paid macOS browser/API run, in addition to deterministic checks:
scripts/acceptance.sh /absolute/path/to/consumer --live
```

See [acceptance instructions](../acceptance/README.md). Reports distinguish
fixture-classifier CI coverage from real GPT-Live/TypeSafe behavior. Existing
browser transport and UI checks remain separate; the new suite adds assertions
about task ownership, accepted results, persistent records, and reconnection.
