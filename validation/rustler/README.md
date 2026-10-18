# Rustler libopus validation

**Selected implementation: a Rustler NIF using `opusic-c` to call libopus.**

Validated on 2026-09-15: Rustler works for Parlora's selected direct libopus
bridge on the pinned Elixir/OTP toolchain, on both macOS and Linux. It reduces
manual native-boundary code and catches ordinary unwinding Rust panics. It does
**not** isolate native crashes from the BEAM.

This is an implementation feasibility fixture, not the production audio adapter.
It reuses the [direct libopus suite and stereo fixture](../libopus/README.md#what-the-tests-establish)
through Mix's `test_paths`, with two additional Rustler boundary tests.

## Versions

| Component | Version |
| --- | --- |
| Elixir / Erlang | `1.20.4-otp-29` / `29.0.6` |
| Rust toolchain | `1.92.0` |
| Rustler, Hex and Rust crate | `0.38.0` |
| Rust libopus wrapper, `opusic-c` | `1.6.1`, bundled build disabled |
| Transitive native bindings, `opusic-sys` | `0.7.5` |
| System libopus | `1.6.1` |
| `ex_webrtc` | `0.17.0` |

`mix.lock`, `Cargo.lock`, and `rust-toolchain.toml` preserve the probe's versions.
The build script requires libopus 1.6.1 through pkg-config; tests also assert the
loaded codec version. `otool -L` and `ldd` confirm dynamic system libopus linkage.
The project brief adopts this validated Rust version for the native build toolchain.

## Results

| Environment | Codec, WebRTC, and boundary suite | Isolated fault probes |
| --- | --- | --- |
| macOS 26.6.2 arm64 | 16 pass | 3 pass |
| Pop!_OS 24.04 x86_64 through `ssh linux` | 16 pass | 3 pass |
| Same Linux host, libopus instrumented with ASan and UBSan | 16 pass, no findings | Not run under sanitizers |

The shared suite exercises PCM24k/mono conversion from stereo Opus, both RTP
directions between local ExWebRTC peers, codec controls, PLC and confirmed FEC,
malformed input, state cleanup, concurrency, and eight streams processing 8,000
encode/decode pairs. Additional tests reject invalid Elixir terms and check that
fault hooks are disabled during ordinary use. Rustfmt, Clippy with `-D warnings`,
and Elixir formatting checks pass on macOS.

Only **libopus** was sanitizer-instrumented for the Rustler run. The Rust NIF,
BEAM, and other dependencies were not; leak detection was disabled. These results
are bounded tests, not a memory-safety or leak-free certification.

### What happens on failure

Each fault probe runs in a separate, disposable BEAM process with core dumps
disabled and a timeout. Fault injection requires `PARLORA_ISOLATED_FAULT_PROBE=1`.

| Injected failure | Observed behavior on both platforms |
| --- | --- |
| Ordinary Rust panic | Rustler raises `:nif_panicked`; after catching it, the same BEAM successfully creates and uses another codec. |
| Panic while holding codec state | The mutex becomes poisoned; later codec use returns `{:error, :poisoned}`. Explicit close still releases the state and repeated close succeeds. |
| Native process abort | The disposable BEAM terminates with `SIGABRT` (child exit `-6`). Rustler cannot contain it. |

The abort is deliberately injected, **not an observed libopus defect**. Rustler's
panic handling depends on unwinding; this fixture explicitly builds with
`panic = "unwind"`. It cannot turn segmentation faults, native memory corruption,
or aborting failures into ordinary Elixir errors. An Elixir supervisor cannot
restart a codec process after its entire VM has crashed. Crash isolation requires
an external worker process, for example through a Port.

## Implementation and recommendation

- Rustler decodes Elixir arguments and manages `ResourceArc` native resources.
- Rust-owned encoder/decoder state is protected by a nonblocking mutex. Contention
  returns `:busy`; poisoned state is rejected and can still be closed.
- Codec work runs on dirty CPU schedulers. This protects normal scheduler
  availability from codec execution, not the VM from native crashes.
- Input sizes and frame durations are bounded before allocation and codec calls.
  PCM conversion uses explicit little-endian values and owned buffers.
- `opusic-c` wraps libopus allocation, calls, and destruction. It still uses unsafe
  FFI internally. This fixture also contains a small documented unsafe block for
  packet metadata calls; libopus remains native C code in the VM process.

**Selected approach:** use Rustler for the in-process libopus binding. Its resource
and argument handling reduce the manual C NIF code Parlora must maintain, and the
required codec operations work on both development platforms. The tradeoff is
adding Rust tooling and Rust dependencies while retaining the native crash risk.
This validation does not establish a speed advantage over the C NIF.

Production work still includes API/error design, reviewing unsafe boundaries,
packaging, fuzzing, leak/race and overload testing, and real browser/GPT-Live calls.
Fault-injection exports belong only to this fixture and must not ship in the
production binding. After a caught panic involving state, discard that codec and
let the owning process establish fresh state according to the audio lifecycle.

## Reproduce

Use the repository's pinned Elixir/OTP, Rust 1.92.0, a native C toolchain,
pkg-config, and libopus 1.6.1 development files. Run from this directory.

### macOS arm64

On a laptop whose existing rustup installation defaults to Intel, install and
explicitly select the native toolchain without changing the global default:

```sh
rustup toolchain install 1.92.0-aarch64-apple-darwin --force-non-host \
  --profile minimal --component rustfmt --component clippy
export RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin
export PKG_CONFIG_PATH=/opt/homebrew/opt/opus/lib/pkgconfig
export OPUS_LIB_DIR=/opt/homebrew/opt/opus/lib
pkg-config --modversion opus  # must be 1.6.1
mix deps.get
mix test
python3 scripts/verify_faults.py
cargo fmt --manifest-path native/opus_rustler_probe/Cargo.toml --check
cargo clippy --locked --manifest-path native/opus_rustler_probe/Cargo.toml -- -D warnings
mix format --check-formatted mix.exs lib/*.ex test/*.exs scripts/*.exs
otool -L priv/native/opus_rustler_probe.so
```

### Linux

Provide the same pinned toolchain and the native prerequisites for ExWebRTC,
including OpenSSL development files. For libopus installed in a custom prefix:

```sh
export PARLORA_OPUS_PREFIX=/path/to/libopus-1.6.1
export PKG_CONFIG_PATH="$PARLORA_OPUS_PREFIX/lib/pkgconfig"
export OPUS_LIB_DIR="$PARLORA_OPUS_PREFIX/lib"
export LD_LIBRARY_PATH="$PARLORA_OPUS_PREFIX/lib"
mix deps.get
mix test
python3 scripts/verify_faults.py
ldd priv/native/opus_rustler_probe.so
```

The recorded Linux run used isolated tool installations in a temporary directory.

### Linux libopus sanitizers

Build an instrumented libopus as described in the
[native sanitizer instructions](../libopus/README.md#linux-native-sanitizers).
After the normal Rustler suite has compiled, use that library at runtime:

```sh
LD_LIBRARY_PATH="$PARLORA_OPUS_SANITIZED_PREFIX/lib" \
  LD_PRELOAD="$(cc -print-file-name=libasan.so)" \
  ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 \
  UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
  mix test --no-compile
```

This instruments the C codec only; it does not rebuild the Rust NIF with sanitizers.

## References

- [Rustler](https://github.com/rusterlium/rustler)
- [Rustler ResourceArc](https://docs.rs/rustler/0.38.0/rustler/struct.ResourceArc.html)
- [opusic-c API](https://docs.rs/opusic-c/1.6.1/opusic_c/)
- [Rust panic containment and its limits](https://doc.rust-lang.org/std/panic/fn.catch_unwind.html)
- [Erlang NIF execution and VM safety](https://www.erlang.org/doc/apps/erts/erl_nif.html)
