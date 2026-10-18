# Elixir 1.18 / OTP 27 compatibility — October 17, 2026

Local checks ran on macOS **27.0.1 arm64**, using independent source, dependency,
build and native-target directories for the older runtimes. The running manual
voice server was not restarted. Development pins remain Elixir **1.20.4-otp-29**,
OTP **29.1.2**, Rust **1.92.0** and libopus **1.6.1**. Dependency versions and
lockfiles are unchanged.

## Changes

- Root, OrderDesk and the maintained optional-backend consumer require Elixir
  `~> 1.18`. The root Mix project rejects OTP below 27 before compilation.
- The native-version test retains the exact libopus requirement and checks the
  supported BEAM minimums instead of the development patch versions.
- CI selects 1.18.5/27.3.4.15, 1.19.5/28.5 and 1.20.4/29.1.2 on both Ubuntu
  24.04 and macOS 15. Artifact names include the runtime pair. Jobs do not share
  build artifacts or Dialyzer PLTs.
- Every pair runs compile-cycle, compilation, ExUnit, stability, native,
  browser/audio/release and consumer checks. Each pair validates no framework and
  Jido, Sagents and Legion separately, through dev/test/prod and release boot.
- The pinned pair owns formatting and static analysis. Consumer compatibility
  runs use `PARLORA_CHECK_FORMAT=0`; default consumer validation still checks
  formatting. Older formatters disagree with the canonical layout in existing
  source files, so those differences are not runtime compatibility failures.
- The new compatibility guide is included in the source package. Historical
  validation projects and their measured version pins remain historical.

No library runtime module, adapter, audio algorithm, native binding or dependency
implementation changed.

## Local results

| Pair | Root checks | Stability | Native checks | OrderDesk tests and release |
| --- | --- | --- | --- | --- |
| Elixir 1.18.5 / OTP 27.3.4.15 | 522 passed; no compile cycles | 3 passed | Passed | 230 passed; release smoke passed |
| Elixir 1.19.5 / OTP 28.5 | 522 passed; no compile cycles | 3 passed | Passed | 230 passed; release smoke passed |
| Elixir 1.20.4 / OTP 29.1.2 | `mix ci` passed, including 522 checks and all quality tools | 3 passed | Passed | 230 passed; release smoke passed |

The default root suites exclude the three separately tagged stability tests;
those run explicitly with `--include stability --seed 42`. Final older-runtime
suites used seed **46494**, eight async cases, and `--warnings-as-errors --raise`.
The deterministic audio benchmark passed **200/200** gates on each older pair.
The existing browser JavaScript tests passed **18/18** on the local Node runtime.
Elixir **1.17.3** was rejected by Mix with the declared `~> 1.18` requirement.

OrderDesk was built from the unpacked source package, not a dependency pointing
back to the checkout. Its release booted without Mix and exercised native audio,
order 123 to 124 correction, stale-result suppression, provider acknowledgment,
finalization and cleanup, using an offline provider and synthetic devices.

The packaged dependency-isolation profiles also passed on the minimum pair:

| Installed framework | Tests | Dev/test/prod compilation | Release smoke without Mix |
| --- | --- | --- | --- |
| None | 11 passed | Passed | Passed |
| Jido only | 33 passed | Passed | Passed |
| Sagents only | 24 passed | Passed | Passed |
| Legion only | 35 passed | Passed | Passed |

Every profile asserted that the unselected frameworks were absent. These fixtures
disable native device/Opus bindings and use memory audio; the root tests and
OrderDesk release checks above separately exercise the native paths.

## Test assumptions exposed by the matrix

Concurrent validation exposed three existing timing/ordering assumptions:

1. The policy-failure fixture allowed the default five-second shutdown deadline
   but asserted closure within one second. It now supplies a 200 ms deadline,
   preserving the one-second assertions and the production defaults.
2. A correction-queue test checked process liveness immediately after receiving
   `:closed`. That event is sent before the coordinator exits. It now monitors
   the coordinator and requires its normal `:DOWN` notification.
3. A Grok correction test treated `:stale_result` as confirmation that a queued
   provider-resolution command had finished. It now waits for the provider's
   existing `:superseded` state before checking the replacement route.

The final full suites passed after these changes. Legion's generated tests also
compute their constant close-mode membership at module compilation, avoiding
Elixir 1.18 type warnings while preserving the same close assertions.

## Reproduction and limits

Select each matching Elixir and OTP installation explicitly through PATH, with
its own build directory. Run the commands in `.github/workflows/ci.yml`; on the
development pair use `mix ci`. Packaged checks use `scripts/consumer.sh` and
`scripts/optional_backend_consumer.sh` with a fresh destination per profile.

Local logs use the `/tmp/parlora-beam-support-*-20261017` prefix. The source
package was checked to contain the relaxed requirement and compatibility guide.
Fresh upstream dependency builds retain their existing warnings; Parlora and
consumer compilation, and compatibility test compilation, use warnings as errors.

The results above are macOS observations. The Linux follow-up below uses the same
source revision and runtime pairs. Hosted execution of the six-job workflow still
requires a push. Full browser receiver/recovery, concurrency and release-evaluator
runs on each pair are configured in CI, not claimed as locally rerun here. No paid
APIs or physical audio devices were used. Compatibility does not establish
subjective voice quality or every possible Elixir/OTP combination.

## Linux follow-up over SSH

The `linux` host runs **Pop!_OS 24.04 x86_64**. Validation uses an archive of commit
`81e521e8f2ad8e506285f4f4353ac474484407ba`, with the test-only initialization and
replay-budget changes described below. Runtime installations were selected through
PATH; the project's development pins, dependency locks and running manual server
were not changed. The actual installed versions were checked, including each
`OTP_VERSION` file: **1.18.5/27.3.4.15**, **1.19.5/28.5** and **1.20.4/29.1.2**.

Linux native checks used Rust **1.92.0**, a checksum-verified libopus **1.6.1** build,
and ALSA/PulseAudio development files extracted into a private temporary prefix.
No sudo access or system package installation was needed. Builds used two BEAM
schedulers and two Cargo jobs. Final root runs used Linux's normal scheduler
busy-wait settings after removing macOS-specific flags from the initial runs.

### Linux results

| Pair | Root checks | Stability | Native checks | Audio gates | Packaged OrderDesk |
| --- | --- | --- | --- | --- | --- |
| Elixir 1.18.5 / OTP 27.3.4.15 | 522 passed | 3 passed | Passed | 200/200 | 230 passed; release smoke passed |
| Elixir 1.19.5 / OTP 28.5 | 522 passed | 3 passed | Passed | 200/200 | 230 passed; release smoke passed |
| Elixir 1.20.4 / OTP 29.1.2 | 522 passed; `mix ci` passed | 3 passed | Passed | 200/200 | 230 passed; release smoke passed |

The development pair's full quality gate passed formatting, compile-cycle checks,
strict Credo, clone detection, Credence and Dialyzer (**zero errors**). The minimum
pair also passed all four packaged dependency-isolation profiles: **11** tests
without a framework, **33** with Jido, **24** with Sagents and **35** with Legion.
Every profile compiled in dev/test/prod and passed its release smoke without Mix.

After the builds finished, the final root suites ran sequentially with seed
**46494**, four async cases and `--warnings-as-errors --raise`. They passed in
**83.6 s**, **59.6 s** and **57.7 s**, respectively. The updated consumer helper
was then rechecked in all four isolated profiles, with the same **11/33/24/35**
passing totals. This final pass avoids the CPU contention from concurrent native
builds and repeat suites. The full development-pair quality gate ran before the
last helper readiness adjustment; the final helpers were subsequently validated
by these Linux suites and the macOS checks below.

### Test setup findings

1. Legion's first mocked request lazily decoded the shared model catalog. Cold
   initialization took approximately **5.5–10.5 seconds**, exceeding the fixture's
   request/receive deadlines. The root and Legion-only consumer test helpers now
   resolve the existing fixture model before ExUnit starts. The catalog is reused
   rather than forcibly replaced during concurrent tests.
2. Jido starts discovery asynchronously. It was still loading approximately
   **900 modules** during the stability suite's bounded warmup, changing the
   shared code footprint. Root and Jido-only consumer helpers now wait for the
   public discovery readiness result, with a **60-second** bound, before starting
   ExUnit. Stability warmup and memory assertions remain unchanged.
3. Three complete-call replay cases run multiple virtual render phases inside
   one ExUnit test. They now have a **180-second overall test budget**. Individual
   replay timeouts, sample-integrity, virtual playback, recovery, shutdown and
   command-deadline assertions remain unchanged.

These changes affect test setup and test wall-clock budgets only. No library
runtime, adapter, audio algorithm, native binding or dependency implementation
changed. A subsequent macOS development-pair run passed **522 checks**; formatting
and strict Credo also passed.

Linux source trees, runtime logs, native prefixes and audio reports are under
`/tmp/parlora-beam-linux-81e521e*-20261017` on the SSH host. Packaged consumers use
separate directories and dependency/build artifacts for each runtime pair.
