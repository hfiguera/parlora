# Quiet coffeehouse ambience

Source: [0105coffeehouse.wav](https://freesound.org/people/moxobna/sounds/46310/) by **moxobna**.
The source page lists [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/).
This asset uses the publicly available HQ MP3 preview, not the login-only original WAV download.

The accompanying manifest retains the download URL/hash, excerpt and loop processing,
caller reference, gain and final PCM hash. `cafe.pcm` is a 24kHz mono signed 16-bit
little-endian loop. The original first 30 seconds are skipped; the next 60 seconds
are joined with a 500ms equal-power crossfade and scaled to 20 dB below active
caller speech, producing a 59.5-second loop. No ducking is applied.

Use the bundled manifest with the replay runner’s `--ambience` option.
This simulates the caller's acoustic environment during live model input.
