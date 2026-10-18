# Optional backend dependency isolation

`scripts/optional_backend_consumer.sh /new/directory` builds the source package
and validates a fresh host with no Jido, Sagents or Legion dependency. CI runs
all four profiles on macOS and Linux for the **1.18/27, 1.19/28 and 1.20/29**
[compatibility pairs](../../docs/beam-compatibility.md).

The fixture compiles with warnings as errors in dev, test and prod; runs the
framework-independent provider/session contract tests; checks that unavailable
built-in adapters return `:unsupported`; builds a release; and runs a custom
backend session from that release without Mix. Package selection is checked
with both module loading and application code-path discovery. Fixture adapters
are explicitly copied into the host, never added to Parlora's package.
The harness copies the root `.tool-versions` so an external consumer defaults to
the development pins rather than the machine's global asdf defaults. CI selects
each compatibility runtime explicitly through PATH. Set `PARLORA_CHECK_FORMAT=0`
when checking an older pair; canonical formatting stays on the development pair.
The root lockfile pins the available package versions; unused lock entries do
not install dependencies and are not treated as evidence of their presence.

The headless fixture disables native device/Opus builds and uses in-memory
audio. The regular root tests and OrderDesk consumer separately exercise native
audio and the framework integrations.

To test each optional framework independently, pass `jido`, `sagents` or `legion`
as the second argument. Each profile installs only that framework, adds its
existing adapter tests, and asserts that the other two remain absent:

```sh
scripts/optional_backend_consumer.sh /tmp/parlora-no-framework none
scripts/optional_backend_consumer.sh /tmp/parlora-only-jido jido
scripts/optional_backend_consumer.sh /tmp/parlora-only-sagents sagents
scripts/optional_backend_consumer.sh /tmp/parlora-only-legion legion
```

Destinations must not already exist. These checks make no model API calls.

The [minimum-runtime validation](../beam-compatibility-20261017/README.md) also
passes all four profiles on Elixir 1.18.5 / OTP 27.3.4.15, including dev/test/prod
compilation and release boot. The earlier measurements below retain their
original toolchain and test counts.

## Validated on 2026-10-17

macOS arm64, Elixir 1.20.4 / OTP 29.0.6:

| Installed frameworks | Consumer tests | Dev/test/prod compilation | Production release smoke |
| --- | ---: | --- | --- |
| None | 11 passed | Passed | Passed |
| Jido only | 12 passed | Passed | Passed |
| Sagents only | 23 passed | Passed | Passed |
| Legion only | 34 passed | Passed | Passed |

Every profile asserted the other frameworks were absent. The isolated consumers
compiled Parlora with warnings as errors; upstream dependency builds still emit
their existing warnings. Each release completed a custom backend request and
session cleanup without Mix on its code path.

The root `mix ci` also passed: 434 checks (428 tests and 6 properties), native
checks, formatting, strict Credo, clone/Unicode checks and Dialyzer. The three
separately tagged stability tests passed with seed 42. The existing
packaged OrderDesk consumer passed 222 tests and its native production release
smoke, retaining the example's explicitly installed Jido default.

Linux execution is configured in CI; these local results cover macOS only.
