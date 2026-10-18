# CPAL through Rustler: evaluation

Evaluated on 2026-09-15. **Selected approach: CPAL through Rustler for Parlora's
macOS/Linux local-device adapter.** It provides device discovery, capture, and
playback while Rubato handles resampling and libopus handles the Opus boundary.
This fixture is the starting point for the selected binding; production integration
remains. Initially, physical-device testing uses macOS and Linux tests use virtual
loopback. Physical Linux audio remains unverified until hardware testing is performed.

## Versions and results

| Component | Version |
| --- | --- |
| Elixir / Erlang | `1.20.4-otp-29` / `29.0.6` |
| Rust | `1.92.0` |
| Rustler (Hex and Rust crate) | `0.38.0` |
| CPAL | `0.18.2` |
| `crossbeam-queue` | `0.3.14` |

Mix and Cargo lockfiles preserve the resolved graph. Linux enables CPAL's
`pulseaudio` feature; the ALSA backend also compiles. macOS uses CoreAudio.

| Check | macOS 26.6.2 arm64 | Pop!_OS 24.04 x86_64 |
| --- | --- | --- |
| Synthetic lifecycle/queue tests | 7 ExUnit + 2 Rust tests pass | 7 ExUnit + 2 Rust tests pass |
| Device discovery | Built-in microphone/speakers and virtual devices | HDMI output/monitor and temporary virtual sink/monitor |
| Concurrent input/output | Built-in microphone capture and silent speaker output | Synthetic tone recovered through a virtual sink's monitor |
| Device lifecycle script | Pass | Pass |
| Rustfmt, Clippy `-D warnings`, Mix format | Pass | Pass |

The Linux device test used CPAL's PulseAudio backend against PipeWire 1.6.8's
PulseAudio service. The host has no physical microphone. **This validates Linux
virtual-device I/O, not a physical Linux microphone or audible speaker playback.**
macOS playback sent silence; no audible/acoustic loopback test was performed.
Captured microphone PCM stayed in memory and was not written to disk.

## What the automated tests establish

- The BEAM versions match the exact development pins.
- Native capture and playback queues are bounded by frames; overflow is counted
  and playback starvation emits silence. Stereo channels remain paired.
- Elixir can read PCM16LE capture and enqueue PCM16LE playback without calling
  into BEAM from a device callback.
- Malformed buffers, invalid resources, invalid capacities, unknown hosts, and
  missing devices return errors instead of killing the caller's VM.
- Explicit close is idempotent; callback counters stop advancing after cleanup.
- The native resource monitors its Elixir owner. Killing that process stops the
  native worker even while another Elixir process retains the resource.
- Repeated sessions and concurrent read/write/clear/close complete without crashes.

Synthetic tests use the same queue/callback processing functions as device I/O,
but run from a timer-driven test worker. Device scripts separately exercise CPAL.
The real-device lifecycle script checks three open/close cycles, missing-device
errors, and owner-death cleanup on both tested backends.

## Device run observations

The probe requests a **10 ms device buffer** and maintains approximately **50 ms
of queued playback**, with capture/playback queue capacity of 4,800 frames (100 ms
at 48 kHz). Elixir refills by queue depth and polls capture approximately every
5 ms. Those values are test settings, not adopted product latency targets.

| Final smoke run | macOS | Linux virtual loopback |
| --- | --- | --- |
| Native input/output format | f32, 48 kHz; mono input/stereo output | f32, 48 kHz; stereo input/output |
| Input/output callback counts | 247 / 247 | 251 / 236 |
| Captured PCM bytes read by Elixir | 236,160 | 480,000 |
| Capture frames dropped | 0 | 0 |
| Playback frames replaced by silence after warmup | 0 | 0 |
| CPAL error callbacks | 0 | 0 |
| Explicit close time | 32.611 ms | 4.388 ms |

Linux emitted 960 frames of startup silence before playback data became available;
the starvation counter did not increase afterward. The loopback recovered the
generated 440 Hz tone at amplitude approximately 1,000 PCM16 units, matching its
input. Each run lasted roughly 2.5 seconds. This is functional validation, not a
long-call stability or latency guarantee.

**Buffer negotiation matters.** An earlier run using backend-default buffers
observed a two-second initial Linux playback request and oversized capture blocks.
Explicit buffer requests and queue-aware feeding resolved the tested behavior.
Production code needs to inspect supported buffer ranges, negotiate a supported
size, and handle backend rounding; requesting 10 ms does not guarantee exactly
10 ms callbacks on every device.

## Binding design and remaining work

- A dedicated native owner thread creates, runs, and destroys each input/output
  stream pair. A resource destructor or owner-monitor callback requests shutdown
  without joining a thread on a normal BEAM scheduler. Explicit open/close waits
  run on dirty I/O schedulers and have bounded waits in the probe.
- Device callbacks move frames through preallocated `ArrayQueue` buffers and
  update atomic counters. They do not send BEAM messages, allocate result binaries,
  log, resample, or wait for Elixir. The read/write NIFs perform PCM conversion and
  binary allocation on dirty CPU schedulers.
- Queue capacity and whole-frame writes prevent unbounded native audio buffering.
  Overflow drops incoming frames; a partial playback write reports how many frames
  were accepted. These probe policies need a reviewed production API.
- `clear` discards audio in the application's queue only. It cannot recall audio
  already handed to the OS. `rendered` counts frames supplied to the device callback,
  **not audio confirmed to have reached the listener**. Production interruption and
  playback evidence must account for downstream buffering and device timestamps.
- The probe uses device default sample rate/channel layout, supports f32/i16/i32
  native formats and mono/stereo, and exchanges PCM16LE with Elixir. Actual device
  tests used f32. Integration with Rubato and libopus remains; these fixtures have
  been tested separately.
- The wrapper forbids locally written unsafe Rust. CPAL and platform dependencies
  still use native/unsafe interfaces. Rustler's NIF panic handling does not provide
  native crash isolation or automatically contain failures in device callback threads.

Still needed: device removal/reconnection, permission denial, Bluetooth changes,
other Linux backends, physical Linux hardware, supported-buffer fallback, device
clock feedback, startup priming, shutdown drain policy, echo cancellation, long
calls and overload, packaging, and combined provider/codec/resampler integration.
The callback error path currently counts errors; production code must notify the
owning process and choose recovery behavior. No sanitizer or leak certification
was performed. CPAL provides audio I/O, not acoustic echo cancellation.

## Reproduce

Run from this directory with the pinned Elixir/OTP and Rust tools.

### Build and hardware-independent tests

On this Apple Silicon laptop, explicitly select native Rust:

```sh
export RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin
mix deps.get
mix test
cargo test --locked --manifest-path native/cpal_probe/Cargo.toml
cargo clippy --locked --manifest-path native/cpal_probe/Cargo.toml -- -D warnings
cargo fmt --manifest-path native/cpal_probe/Cargo.toml --check
mix format --check-formatted mix.exs lib/*.ex test/*.exs scripts/*.exs
```

Linux uses its native Rust 1.92.0 toolchain, without the macOS override. Provide
pkg-config, ALSA development files (`libasound2-dev` on Ubuntu), and PulseAudio
development files (`libpulse-dev`) for this fixture's enabled backend. The recorded
run extracted those development packages into a temporary prefix and linked the
existing runtime libraries without installing system packages. Then run the same
Mix/Cargo checks.

### macOS devices

```sh
export MIX_ENV=test CPAL_HOST=CoreAudio
mix run --no-compile scripts/devices.exs
export CPAL_INPUT='MacBook Pro Microphone'
export CPAL_OUTPUT='MacBook Pro Speakers'
mix run --no-compile scripts/device_smoke.exs
mix run --no-compile scripts/device_lifecycle.exs
```

Select names returned by discovery. Microphone access requires the OS permission
for the host process. The hardware smoke test writes silence to speakers.

### Linux virtual loopback

With a running PulseAudio-compatible service and `pactl`, after `mix test`:

```sh
sh scripts/linux_loopback.sh
```

The script creates a named temporary null sink, directs CPAL explicitly to it and
its monitor, checks the tone, and unloads the module on exit. It does not change
the user's default devices. The evaluation's temporary sink was also removed.

## References

- [CPAL 0.18.2 API](https://docs.rs/cpal/0.18.2/cpal/)
- [CPAL platforms, backends, and build prerequisites](https://github.com/RustAudio/cpal)
- [Rustler native-boundary validation](../rustler/README.md)
- [Rubato resampling validation](../rubato/README.md)
