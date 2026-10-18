# Requirements and native builds

Parlora requires **Elixir 1.18 or later (1.x)** and **Erlang/OTP 27 or later**.
Use a compatible Elixir/OTP pair and a current patch release. Suitable pairings
include Elixir 1.18/OTP 27, Elixir 1.19/OTP 28, and Elixir 1.20/OTP 29.

## Choose native bindings before compiling

**Both native features are enabled by default, regardless of the channel you
select at runtime.** A default build needs prerequisites for local audio devices and
**libopus 1.6.1**, even if you only intend to use local audio or telephony.

In your host application's `config/config.exs`, select the bindings you need
before running `mix compile` or `mix run`:

| Application channels | Configuration used when compiling | Parlora native prerequisites |
| --- | --- | --- |
| Local and browser (default; OrderDesk) | Both flags default to `true` | Rust, libraries for local audio devices, libopus 1.6.1 |
| Local only | `config :parlora, native_audio: true, native_opus: false` | Rust and libraries for local audio devices; no libopus required |
| Browser only | `config :parlora, native_audio: false, native_opus: true` | Rust and libopus 1.6.1; no ALSA/PulseAudio headers required |
| Phone or custom channels only | `config :parlora, native_audio: false, native_opus: false` | No Parlora Rustler bindings |

Begin `config/config.exs` with `import Config`. These flags only disable Parlora's
bindings; WebRTC dependencies still build their transport bindings and need a C
build toolchain and OpenSSL development files. Native settings belong in the host
application, not runtime configuration or the dependency's config.

Parlora's native bindings use **Rust 1.92.0**. Install it with rustup for your
machine's architecture. The Opus installer and example launchers also need Python 3.
OrderDesk enables both bindings because it supports local and browser calls.
The [tutorial for your first session](first-session.md) selects local audio only.

## macOS

Install Xcode command-line tools, then the system libraries:

```sh
xcode-select --install
brew install pkgconf srtp
# Also install Opus for a default or browser-enabled build:
brew install opus
```

For a default build or a build with browser audio enabled, check `pkg-config --modversion opus`: it
must report `1.6.1`. If your package manager supplies a different version, use the
instructions for a custom prefix below.
In the **host application's** `config/config.exs`, select system SRTP:

```elixir
import Config

if :os.type() == {:unix, :darwin} do
  config :bundlex, :disable_precompiled_os_deps, apps: [:ex_libsrtp]
end
```

After changing an existing build, run `mix deps.compile ex_libsrtp --force` in each
Mix environment you use. Your release host also needs the SRTP/OpenSSL libraries.
Local audio requires microphone permission; headphones help prevent feedback.

## Linux

For a default build on systems compatible with Ubuntu:

```sh
sudo apt-get install build-essential pkg-config libasound2-dev libpulse-dev libssl-dev curl python3
```

Local audio also needs a running service compatible with PulseAudio, such as PipeWire.
Default builds and builds with browser audio enabled also need libopus 1.6.1. Run the build
script below if your distribution does not provide that exact development version.
Builds for browser audio only or phone audio only can omit `libasound2-dev` and `libpulse-dev`.

## Install libopus in a custom prefix

From the Parlora source directory:

```sh
scripts/install_opus.sh "$HOME/.local/parlora-opus"
export PKG_CONFIG_PATH="$HOME/.local/parlora-opus/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export OPUS_LIB_DIR="$HOME/.local/parlora-opus/lib"
export LD_LIBRARY_PATH="$HOME/.local/parlora-opus/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

Keep the prefix available when building and running the application. On macOS,
use the platform's search configuration for shared libraries if your deployment requires
it. Verify discovery with `pkg-config --modversion opus` before compiling Parlora.

## Rebuild and deploy

After changing native flags in an existing host build, run
`mix deps.compile parlora --force` in each Mix environment you use. Do not disable
a binding for a channel you will select: LocalAudio requires `native_audio`, and
Browser requires `native_opus`.

Build releases for the target OS/architecture and provide their shared libraries
at runtime. The assembled release includes the compiled NIFs and does not need
Rust or Mix on the target host. When switching Elixir/OTP versions, use separate
build directories or rebuild dependencies.
