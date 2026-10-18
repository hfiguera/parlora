# Erlang/OTP 29.1.2 upgrade — October 17, 2026

Validated on macOS arm64 with Elixir **1.20.4-otp-29**, Erlang/OTP **29.1.2**,
Rust **1.92.0** and libopus **1.6.1**. The installed `OTP_VERSION` file was
checked directly. Linux CI now selects 29.1.2; Linux was not run locally.

The root and OrderDesk pins, CI, setup documentation and four exact-version
assertions agree. Historical measurement reports retain their original runtime
versions. No dependency versions or application runtime logic changed.

| Check | Result |
| --- | --- |
| Root `mix ci` | 434 passed: 428 tests and 6 properties; 3 tagged stability exclusions |
| Native Rust checks | 5 tests passed; Rustfmt and strict Clippy passed |
| Root static checks | Formatting, strict Credo, clone/Unicode checks and Dialyzer passed; zero Dialyzer errors |
| Explicit stability suite, seed 42 | 3 passed |
| CPAL synthetic probe | 7 passed |
| Rubato probe | 11 passed |
| Direct libopus probe | 14 passed |
| Rustler/libopus probe | 16 passed |
| Fresh packaged OrderDesk | 222 passed; native prod compilation, release assembly and Jido correction smoke passed without Mix |
| Fresh consumer with no agent framework | 11 passed; dev/test/prod compilation with warnings as errors, release assembly and custom-backend session smoke passed without Mix |

The consumer harness now copies `.tool-versions` into its destination. This
prevents its asdf shims from silently selecting the machine's global OTP version
after leaving the repository. The final no-framework consumer selected 29.1.2
from its copied pin; an earlier run using the global 29.0.6 was not counted as
upgrade evidence.

The first direct libopus and Rustler probe runs passed their version/codec
checks but failed their WebRTC test while loading an old precompiled SRTP NIF
whose OpenSSL library path was unavailable. Rebuilding SRTP with the repository's
existing macOS system-SRTP configuration made both complete suites pass. Their
logs were retained separately from the successful runs. The root and packaged
consumer checks already use that configuration. Upstream dependency builds can
still emit existing warnings; Parlora's warnings-as-errors checks passed.

## Reproduction

Use the native prerequisites and macOS environment flags in the root README.
Fresh consumer destinations must not already exist.

```sh
mix ci
mix test test/stability_test.exs --include stability --seed 42
scripts/consumer.sh /tmp/parlora-otp2912-order-desk
scripts/optional_backend_consumer.sh /tmp/parlora-otp2912-no-framework none
(cd validation/cpal && mix deps.get --check-locked && mix test)
(cd validation/rubato && mix deps.get --check-locked && mix test)
# Apply the same system-SRTP configuration as the root project on macOS:
(cd validation/libopus && MIX_ENV=test mix do loadconfig ../../config/config.exs, deps.compile ex_libsrtp --force, test)
(cd validation/rustler && MIX_ENV=test mix do loadconfig ../../config/config.exs, deps.compile ex_libsrtp --force, test)
```

These checks use fixtures and local peers. No paid provider calls or physical
audio-device acceptance runs were performed for this toolchain upgrade.
