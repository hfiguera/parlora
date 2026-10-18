# Rubato through Rustler: validation

Validated on 2026-09-15. **Selected approach: Rubato through Rustler for Parlora's
PCM resampling**, including 44.1/48 kHz microphone input to 24 kHz and the reverse
conversion for playback. It complements the selected libopus binding; browser
Opus decoding already produces PCM24k directly.

This fixture validates a possible implementation, not a production adapter or a
decision to adopt a device-capture library.

## Versions and build

| Component | Version |
| --- | --- |
| Elixir / Erlang | `1.20.4-otp-29` / `29.0.6` |
| Rust | `1.92.0` |
| Rustler, Hex package and Rust crate | `0.38.0` |
| Rubato | `5.0.0` |
| `audioadapter-buffers` | `5.2.0` |

Mix and Cargo lockfiles preserve the full resolved dependency graphs. Rubato's
default features are disabled: this probe uses the asynchronous sinc resampler,
not its optional FFT implementation. No extra C resampling library is needed.
`otool -L` on macOS and `ldd` on Linux show only system runtime dependencies.

| Environment | Result |
| --- | --- |
| macOS 26.6.2 arm64 | 11 tests pass |
| Pop!_OS 24.04 x86_64 via `ssh linux` | 11 tests pass |
| Both platforms | Rustfmt, Clippy with `-D warnings`, and Elixir formatting pass |

## Configuration exercised

- `Async<f32>::new_sinc` with fixed input blocks and retained state between calls.
- 256-tap filter, Blackman-Harris-squared window, cubic interpolation, 128-fold
  sinc-table oversampling, and automatic cutoff (Rubato 5.0.0 defaults).
- Normally 10 ms input blocks: 441 frames at 44.1 kHz, 480 at 48 kHz, 240 at 24 kHz.
- PCM16 little-endian interleaved input/output. The wrapper converts through f32
  scratch buffers and rounds/saturates output to PCM16.
- The wrapper averages stereo channels for mono output, duplicates mono for
  stereo output, or preserves channels. **Channel mixing is wrapper code, not
  Rubato's resampling responsibility.**
- Rate adjustments are limited by the wrapper to ±1,000 parts per million (ppm)
  and ramp to the new ratio. Tests exercise ±500 ppm during an ongoing stream.

## What the tests establish

1. The exact Elixir and Erlang versions match the development pins.
2. 44.1→24, 48→24, 24→44.1, and 24→48 kHz conversions retain the requested duration
   after startup-delay removal and end-of-stream draining. Irregular final input
   lengths exercise padding rather than ending on a convenient block boundary.
3. Downsampling retains 100 Hz, 1 kHz, and 8 kHz tone amplitude within 1%. At 15 kHz
   and 18 kHz, frequencies above the 24 kHz output's 12 kHz limit, residual RMS is
   below the required −60 dB relative to input. In these runs the steady output
   quantizes to PCM16 zero. This is not a claim of unlimited filter attenuation;
   the measurement is limited by PCM16 resolution and the tested frequencies.
4. Independent stereo tones remain on their respective channels. Stereo-to-mono
   output contains both tones at half amplitude; duplicated mono channels match.
5. Processing the same waveform in 147-frame and 882-frame blocks produces output
   differing by at most one PCM16 unit after delay alignment. State is preserved
   across block boundaries.
6. A near-end impulse survives draining and lands within two output samples of
   its expected position after delay compensation.
7. Reset clears prior filter history and restores the initial ratio, reproducing
   the initial output exactly.
8. A 10-second synthetic stream changes ratio after its first second. −500 ppm
   produces 239,891 frames, +500 ppm produces 240,106; both match duration accounting
   within four samples, including ramp/rounding. A tone remains continuous across
   the adjustment. This tests the actuator, not a device-clock feedback controller.
9. Silence remains zero; full-scale step overshoot saturates rather than wrapping
   to the opposite sign during PCM16 conversion.
10. Invalid formats, rates, resource terms, block lengths, and drift settings are
    rejected without advancing state. Repeated close is safe; closed state errors.
11. Eight independent streams process 8,000 blocks total, and simultaneous use/close
    of shared state returns success, `:busy`, or `:closed` without crashing.

### Latency and processing cost

Reported filter delay, confirmed by the impulse test:

| Conversion | Output delay | Time |
| --- | --- | --- |
| 44.1→24 kHz | 69 samples | 2.875 ms |
| 48→24 kHz | 64 samples | 2.667 ms |
| 24→48 kHz | 256 samples | 5.333 ms |

This is **filter delay only**. Collecting an input block, NIF scheduling, output
queueing, and the capture/playback hardware add latency. The usual probe block is
10 ms. A live adapter must not discard this delay on every block.

For eight concurrent stereo44.1k→mono24k streams processing 1,000 blocks each:

| Host | NIF call p50 | p95 | p99 | Maximum | Test wall time |
| --- | --- | --- | --- | --- | --- |
| macOS | 33 µs | 49 µs | 62 µs | 278 µs | 0.037 s |
| Linux | 44 µs | 61 µs | 66 µs | 1,644 µs | 0.054 s |

Each call processes 10 ms of synthetic audio and includes scheduler round-trip,
PCM conversion, resampling, and the result binary. These are individual runs
processed as fast as possible, representing 80 seconds of audio across streams.
They are not paced-device tests, production capacity estimates, or latency guarantees.

## Integration recommendation and limits

**Selected implementation:** use this as the starting point for Parlora's
local-device resampling. The tested sinc configuration provides filtering and
adjustable ratios without adding FFmpeg or another C audio dependency. Our wrapper
forbids locally written unsafe Rust; dependencies still contain native/unsafe code,
so this is not a guarantee against VM crashes.

The NIF uses Rustler resources, a nonblocking mutex, and dirty CPU schedulers.
Rubato processing reuses allocated float buffers through `process_into_buffer`.
The Elixir boundary still allocates an output binary each call; the complete NIF
path is not allocation-free. Inputs are bounded to mono/stereo, rates from 8 to
96 kHz, and blocks from 16 frames to 100 ms. Only the conversion pairs above were
validated for signal quality.

Parlora must retain one state per stream, assemble exact input blocks from device
callbacks, and buffer the variable number of output frames for downstream pacing.
For a finite stream, the test helper pads the last block, drains filter history,
removes startup delay once, and trims to the intended duration. Live interruption,
drift-aware duration accounting, and shutdown need explicit adapter policies.

Remaining work includes actual microphone/speaker capture, device clock-drift
measurement and feedback control, float/device-specific sample formats, long calls,
overload, resource/leak testing, packaging, and end-to-end integration with the
selected codec/provider. No sanitizer, Miri, or perceptual speech-quality study was
performed for this probe. It tests Rubato independently of the libopus NIF.

## Reproduce

Run from this directory with the pinned Elixir/OTP and Rust toolchains. On this
Apple Silicon laptop, explicitly select native Rust because the existing rustup
installation defaults to Intel:

```sh
export RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin
mix deps.get
mix test
cargo fmt --manifest-path native/rubato_probe/Cargo.toml --check
cargo clippy --locked --manifest-path native/rubato_probe/Cargo.toml -- -D warnings
mix format --check-formatted mix.exs lib/*.ex test/*.exs
otool -L priv/native/rubato_probe.so
```

The native Rust installation procedure is in the
[Rustler probe instructions](../rustler/README.md#macos-arm64). On Linux, use Rust
1.92.0 for the Linux host, omit the macOS `RUSTUP_TOOLCHAIN` override, run the same
Mix/Cargo commands, and use `ldd priv/native/rubato_probe.so` for linkage inspection.
The recorded Linux run used isolated tools in a temporary directory; no global
toolchain replacement was required. Build outputs and fetched dependencies are ignored.

## References

- [Rubato upstream](https://github.com/HEnquist/rubato/)
- [Rubato 5.0.0 API and streaming guidance](https://docs.rs/rubato/5.0.0/rubato/)
- [Rubato resampler interface](https://docs.rs/rubato/5.0.0/rubato/trait.Resampler.html)
- [Rustler validation and native crash limits](../rustler/README.md)
