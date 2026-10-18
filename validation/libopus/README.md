# Direct libopus validation

**Selected approach: direct libopus for Parlora's browser Opus ↔ mono PCM16/24 kHz bridge.**
Validated on 2026-09-15 using a small, standalone C NIF and `ex_webrtc`. The probe
links directly to libopus.

This validates the codec choice and a possible NIF boundary. It is a feasibility
fixture, not a published binding or Parlora's production audio adapter.

The [Rustler validation](../rustler/README.md) runs this same codec/WebRTC suite
through a Rust NIF and additionally checks panic handling and native abort behavior.

## Versions and results

| Component | Version |
| --- | --- |
| Elixir | `1.20.4-otp-29` |
| Erlang | `29.0.6` |
| libopus | `1.6.1` |
| `ex_webrtc` | `0.17.0` |
| `elixir_make` | `0.10.0` (build tooling) |

The tests assert the full Elixir, OTP, and loaded libopus versions. `mix.lock`
preserves the resolved Elixir dependency graph.

| Environment | Result |
| --- | --- |
| macOS 26.6.2 arm64; Homebrew libopus | 14 tests pass |
| Pop!_OS 24.04 x86_64 through `ssh linux`; libopus built from source | 14 tests pass |
| Same Linux host, AddressSanitizer + UndefinedBehaviorSanitizer on both the NIF and libopus | 14 tests pass, no sanitizer findings |

The NIF compiles with `-Wall -Wextra -Werror` on both platforms. Some upstream
Elixir dependencies emit deprecation and unused-import warnings on the pinned toolchain.
`otool -L` and `ldd` confirm direct linkage to libopus and system libraries.
Leak detection was disabled for the sanitizer run; this is not a leak-free or
memory-safety certification. Erlang itself and the other dependencies were not
sanitizer-instrumented.

## What the tests establish

1. **Sample rates, channels, and frame sizes:** encode/decode mono and stereo at
   8, 12, 16, 24, and 48 kHz, with 2.5, 5, 10, 20, 40, and 60 ms encoder frames.
2. **Browser input conversion:** the independently generated 48 kHz stereo Opus
   fixture decodes directly to mono PCM16 at 24 kHz. The output contains the
   expected 440 Hz and 660 Hz tones, has the expected sample count, and has little
   energy at an unrelated frequency. No external resampling/downmixing step is used.
3. **Provider output conversion:** mono PCM16/24 kHz encodes to Opus and decodes
   at 48 kHz stereo on the receiving side.
4. **WebRTC transport:** two local ExWebRTC peers establish ICE/DTLS/SRTP and
   exchange 20 Opus packets each way. Received payloads and 960-tick RTP timestamp
   increments are checked, then decoded. The incoming stereo fixture and outgoing
   mono packets exercise both directions. These are Elixir peers, not browsers.
5. **Voice controls:** bitrate, complexity, in-band FEC, expected loss percentage,
   and DTX are set and read back. VoIP application mode is verified. With DTX
   enabled, sustained silence produces short packets. Production DTX policy still
   needs to respect each transport's continuous-audio requirements.
6. **Packet-loss concealment (PLC):** a deliberately missing packet generates the
   expected 20 ms of replacement audio, followed by successful normal decoding.
7. **Forward error correction (FEC):** the encoder generates packets containing
   actual redundancy, confirmed with `opus_packet_has_lbrr`. After dropping a
   preceding packet, recovery decoding produces audio distinct from PLC, then the
   same received packet decodes normally. The no-redundancy fallback is also tested.
   This verifies the recovery path, not a perceptual quality improvement.
8. **Native boundary behavior:** invalid arguments, truncated packets, oversized
   input, closed resources, reset, repeated close, and 1,000 bounded randomized
   packet inputs are exercised. Random input may be valid Opus; the test accepts
   bounded successful output or a codec error.
9. **Resource and concurrency behavior:** shared state is exclusively accessed or
   returns `{:error, :busy}`. Separate tasks exercise 1,000 resources released on
   task exit. Reset reproduces the same first encoded packet. This is limited
   lifetime/concurrency testing, not exhaustive race detection.
10. **Concurrent processing:** eight independent streams each encode and decode
    1,000 20 ms frames, totaling 160 seconds of synthetic audio.

### Timing observations

For the unsanitized concurrent-processing test, each timing covers one encode
plus one decode, including NIF scheduling and binary conversion:

| Host | Pair p50 | Pair p95 | Pair p99 | Total test wall time |
| --- | --- | --- | --- | --- |
| macOS | 75 µs | 109 µs | 175 µs | 0.114 s |
| Linux | 149 µs | 227 µs | 381 µs | 0.257 s |

These are individual local runs on synthetic tones, processed as fast as possible.
They are not production latency targets, sustained-call capacity measurements, or
a performance comparison with other codec integrations. Network pacing, browser buffering,
and provider latency are outside these measurements.

## What this means for Parlora

Direct libopus provides the codec boundary selected for Parlora's architecture:
Parlora processes can own RTP ordering, buffering, pacing, and interruption while
calling the codec directly. A decoder configured for 24 kHz mono can consume
stereo Opus; a matching encoder can consume provider PCM directly. Opus RTP still
uses a 48 kHz timestamp clock.

Parlora will use a standalone direct binding for this bridge and own its integration,
native resource lifecycle, packaging, and validation. Arbitrary PCM resampling,
device audio, G.711 conversion, mixing, and echo cancellation need their own
implementations or dependencies. Parlora's jitter-buffer policy decides whether
to wait for the next packet for FEC recovery or conceal a loss immediately.

## Binding design exercised here

- Opaque NIF resources hold separate stateful encoders and decoders.
- A native mutex with nonblocking acquisition prevents simultaneous mutation and
  close; callers receive `:busy` instead of occupying a scheduler waiting on it.
  The intended production model is one owning process per codec state.
- Explicit close is idempotent, and the resource destructor releases remaining
  codec allocations when references become unreachable.
- Codec calls use dirty CPU schedulers. This separates codec execution from normal
  BEAM scheduling; it does not isolate native crashes from the Erlang VM.
- Input frame sizes are checked before accessing PCM. Decoder output capacity is
  bounded to 120 ms and two channels. The probe limits compressed input to 8,192
  bytes and allocates 4,000 bytes for an encoded packet.
- PCM bytes are converted explicitly to/from signed 16-bit little-endian values,
  avoiding assumptions about the alignment of Erlang binaries.
- `OPUS_PROBE_NIF` can select an instrumented native library for testing. The normal
  path loads the library built into this fixture's `priv` directory.

This deliberately small probe has numeric native controls and limited errors;
those are not proposed public Elixir APIs. It does not implement hot NIF upgrades,
precompiled artifact distribution, adaptive bitrate, or application lifecycle policy.

## Reproduce

### macOS

From this directory, using the repository's pinned toolchain:

```sh
brew install opus pkgconf
pkg-config --modversion opus  # must be 1.6.1 for this recorded validation
mix deps.get
mix test
mix format --check-formatted mix.exs lib/*.ex test/*.exs
otool -L priv/opus_probe.so
```

### Linux

Provide the pinned Elixir/OTP toolchain, C compiler, Make, pkg-config, libopus 1.6.1
development files, and the OpenSSL development files required by ExWebRTC's native
dependencies. For libopus in a custom prefix:

```sh
export PARLORA_OPUS_PREFIX=/path/to/libopus-1.6.1
export PKG_CONFIG_PATH="$PARLORA_OPUS_PREFIX/lib/pkgconfig"
export LD_LIBRARY_PATH="$PARLORA_OPUS_PREFIX/lib"
mix deps.get
mix test
ldd priv/opus_probe.so
```

The validation used an isolated temporary installation of the exact toolchain and
libopus on `ssh linux`; it did not replace the remote machine's existing tools.

### Linux native sanitizers

Build a separate libopus 1.6.1 source tree with these configuration options, then
run `make -j8` and `make install`:

```sh
export PARLORA_OPUS_SANITIZED_PREFIX=/path/to/libopus-sanitized
./configure --prefix="$PARLORA_OPUS_SANITIZED_PREFIX" \
  --disable-doc --disable-extra-programs \
  CFLAGS='-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer' \
  LDFLAGS='-fsanitize=address,undefined'
```

From this fixture's directory, after a normal `MIX_ENV=test mix compile`, compile
an instrumented NIF and load it into the same test suite:

```sh
export PARLORA_ERTS_INCLUDE="$(erl +S 1 -noshell -eval \
  'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().')"
cc -O1 -g -std=c11 -Wall -Wextra -Werror -fPIC -shared \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I"$PARLORA_ERTS_INCLUDE" -I"$PARLORA_OPUS_SANITIZED_PREFIX/include/opus" \
  c_src/opus_probe.c -o priv/opus_probe_sanitized.so \
  -L"$PARLORA_OPUS_SANITIZED_PREFIX/lib" -lopus
OPUS_PROBE_NIF="$PWD/priv/opus_probe_sanitized" \
  LD_LIBRARY_PATH="$PARLORA_OPUS_SANITIZED_PREFIX/lib" \
  LD_PRELOAD="$(cc -print-file-name=libasan.so)" \
  ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 \
  UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
  mix test --no-compile
```

## Stereo input fixture

`test/fixtures/stereo-opus.bin` contains 20 raw Opus packets, each prefixed by an
unsigned 32-bit big-endian byte length. The synthetic input contains a 440 Hz tone
on the left and a 660 Hz tone on the right, encoded independently of this NIF.
The fixture contains no recorded speech or personal data.

The source was generated with FFmpeg 7.1.5/libopus 1.6.1 using:

```sh
ffmpeg -v error -f lavfi \
  -i 'aevalsrc=0.25*sin(2*PI*440*t)|0.25*sin(2*PI*660*t):s=48000:d=0.4' \
  -c:a libopus -frame_duration 20 stereo.opus
```

The fixture retains the first 20 audio packets after removing Ogg framing,
`OpusHead`, and `OpusTags`. Container trimming metadata is absent, matching raw
Opus RTP payloads. Running the tests uses the checked-in binary directly.

## Remaining production work

- Harden the standalone binding from this validated starting point, with a reviewed
  public API and error contract, and integrate it into Parlora's owning processes.
- Review the native boundary; extend fuzzing, resource-race and leak testing, and
  test overload and scheduler responsiveness on realistic speech workloads.
- Package native builds and updates for the supported machines.
- Exercise real browsers and GPT-Live, varied packet durations, network loss and
  reordering, long calls, interruption, and shutdown. Keep codec state and RTP
  timelines consistent across these events.
- Validate any additional conversions required by local devices and telephony.

## References

- [libopus 1.6 encoder API](https://opus-codec.org/docs/opus_api-1.6/group__opus__encoder.html)
- [libopus 1.6 decoder API, PLC, and FEC](https://opus-codec.org/docs/opus_api-1.6/group__opus__decoder.html)
- [Encoder controls](https://opus-codec.org/docs/opus_api-1.6/group__opus__encoderctls.html)
- [Erlang NIF resources, scheduling, and native-code limitations](https://www.erlang.org/doc/apps/erts/erl_nif.html)
- [Opus RTP timestamp clock](https://www.rfc-editor.org/rfc/rfc7587.html#section-4)
