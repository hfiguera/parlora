# Standalone consumer validation — September 16, 2026

The current development and CI quality pin is Erlang/OTP **29.1.2**. The
[compatibility matrix](beam-compatibility.md) also covers 1.18/27 and 1.19/28;
the original results
below retain their measured versions. See the
[upgrade regression checks](../validation/otp-2912-20261017/README.md) for a fresh
packaged consumer run on the new toolchain.

## Setup

Created `/Users/humberto/Projects/parlora_consumer`, a separate Mix application
named `order_desk`. It owns its supervision tree, Jido agent/action, context
policy, voice runner, runtime configuration, and lockfile. It consumes an
**unpacked `mix hex.build` source package** from `vendor/parlora`, rather than a
path dependency pointing back to this checkout. No example/test-support files
are loaded at runtime from Parlora.

The authoritative example source is `examples/order_desk`; the external app is a generated installation. Running
`scripts/consumer.sh [new-directory]` builds the package and creates a fresh
consumer outside the checkout by default, runs its checks, and retains the app
for inspection. CI now runs this script on macOS and Linux. Hosted CI results
remain pending a push; the results below are local/SSH observations.

Toolchain: Elixir 1.20.4-otp-29, Erlang 29.0.6, Rust 1.92.0. macOS uses native
Apple Silicon Rust and the measured `+sbwt none +sbwtdcpu none +sbwtdio none`
BEAM flags. Linux checks ran over `ssh linux` with the previously validated
native headers/toolchain and PulseAudio-compatible service.

## Results

| Check | macOS | Linux |
| --- | --- | --- |
| Separate dependency resolution and locked install | Passed | Passed |
| Native-enabled compilation from packaged CPAL/Rubato sources | Passed | Passed |
| Consumer ExUnit tests | 2 passed | 2 passed |
| Production release assembly and public-API scenario without Mix | Passed | Passed |
| Host `runtime.exs` reads an environment value at release boot | Passed with a non-secret sentinel | Passed with a non-secret sentinel |
| Native capture, output handoff, clear/resume into epoch 1, and cleanup | Synthetic devices passed | Synthetic devices and PulseAudio virtual device passed |
| Real local device + GPT-Live startup and shutdown | 12-second launcher run, finalized usage 9 seconds | Not run |

The offline scenario uses the actual Jido adapter and application agent. It
starts order 123, corrects to 124, injects a duplicate delegation notice, and
checks that exactly two jobs exist. Order 123 becomes stale; order 124's verified
summary is appended and acknowledged. The test also checks application context,
captured PCM reaching the application-defined provider, native output handoff,
suppression/clear/resume, finalization, coordinator exit, and provider cleanup.
The release runs the same scenario. These are assertions, not just printed
status summaries.

The macOS live run used the standalone application's own runtime configuration
and Keychain launcher. CoreAudio opened `MacBook Pro Microphone` and `MacBook Pro
Speakers`; GPT-Live acknowledged the greeting instruction, emitted greeting
captions, and finalized its session. No credential was displayed or written.
This short run did not retest the entire spoken order-correction conversation or
establish subjective audio quality. That remains available through the consumer's
`scripts/voice.sh`.

Parlora's existing `mix ci` also passed: 74 ExUnit tests, native checks, strict
Credo/ExSlop, zero ExDNA clones, Credence, and Dialyzer. Consumer formatting,
compilation with warnings as errors, and release execution passed separately.
Fresh dependency compilation still emits the existing upstream warnings in
Crontab, Multigraph, and optional Jido Lua/PubSub/HTTP dispatch code. Neither
Parlora nor the consumer emits compilation warnings; no warning checks were
weakened and no unrelated optional integrations were added to silence them.

## Findings and changes

- **Host configuration needs an explicit recipe.** Dependency `config/runtime.exs`
  does not configure the host. Added a [consumer guide](using-parlora.md) covering
  application-owned environment configuration and explicit `api_key:` options.
- **Application ownership needs a complete example.** The separate app supervises
  its own named Jido instance and defines its policy/agent as compiled modules.
  It does not rely on the repository example's `Code.require_file` setup.
- **The host needs its own lockfile.** The consumer resolved its own runtime
  dependency graph and records it independently; Parlora's lockfile is not inherited.
- **Package documentation was incomplete.** The source package now includes the
  consumer guide and public interface contract alongside the README.
- **Cleanup is asynchronous.** A repeated consumer run exposed a race in the
  fixture's immediate supervisor-count assertion. The coordinator/provider can
  exit before OTP removes their session supervisor. The test now requires removal
  within five seconds; it does not treat coordinator exit as complete cleanup.
- **Native and release packaging worked in the exercised path.** Both Rust crates
  build from the package; both native libraries work in the assembled releases.
  No library callback or runtime behavior change was needed for this consumer.

## Limits

This validates local source-package consumption, not installation from a published
Hex registry. The package remains unpublished; license/project-link metadata
still needs a separate decision. No public release was made.

Synthetic and Linux virtual-device checks do not establish physical Linux device
compatibility or audible quality. Physical Linux audio remains unverified.
Releases were run on their build platforms, not a fresh deployment image; target
OS/architecture and system audio libraries still must match. Playback handoff
and provider acknowledgment do not prove that a person heard a particular result.
