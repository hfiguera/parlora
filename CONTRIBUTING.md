# Development

Use the versions in `.tool-versions` and `rust-toolchain.toml`: Elixir
1.20.4-otp-29, OTP 29.1.2, and Rust 1.92.0. Native setup is described in
[requirements](docs/beam-compatibility.md). Keep the supported minimums separate
from these development pins.

```sh
mix deps.get --check-locked
mix ci
mix docs --warnings-as-errors
python3 -m unittest discover -s examples/order_desk/test -p '*_test.py'
python3 -m unittest discover -s scripts/tests -p '*_test.py'
mix test test/stability_test.exs --include stability --seed 42
```

`mix ci` checks compilation, compile-connected cycles, formatting, tests, native
code, strict Credo/ExSlop, duplicate code, Credence, and Dialyzer. Hardware and paid
provider checks are separate. macOS launchers set scheduler flags for the local
runtime; do not copy those flags into Linux configuration.

Audio replays, codec stress tests and tests that measure shutdown deadlines run
outside the async suite. Keep timing assertions separate from unrelated CPU load.
Wait for native callbacks and adapter polls before measuring their progress;
resource readiness alone does not establish that a callback has already run.
Session process exit and adapter cleanup are separate observations; tests that
need complete teardown must monitor the owned adapter processes too.

## Compatibility and packaged consumers

The workflow in `.github/workflows/ci.yml` checks compilation and the full library
test suite on Linux with Elixir/OTP 1.18/27, 1.19/28 and 1.20/29. One macOS job
uses 1.20/29 for library tests, native checks and a packaged release smoke check.
Formatting, documentation, Dialyzer, static analysis and JavaScript/Python unit
tests run once on the Linux development pair. Rust checks run there and on macOS.

Routine pushes to `main` and pull requests run OrderDesk's full tests, stability,
browser, audio and concurrency checks once on the Linux development pair. Four
parallel jobs verify `none`, `jido`, `sagents` and `legion` consumers in `test` and
`prod`, including release smoke checks. Branch pushes with an open PR do not
start a second copy of the workflow. Newer pushes cancel obsolete runs.

The nightly schedule, `v*` tags and the manual **full** option also run integration
and offline release checks on all three Linux pairs. Isolated backend consumers
then cover `dev`, `test` and `prod` on every Linux pair, and macOS runs OrderDesk's
full tests. These checks use offline fixtures and do not call paid providers.

Dependency caches include downloads, compiled BEAM dependencies, Cargo builds,
Opus and Dialyzer PLTs. Keys separate runner images, architectures and toolchain
versions and native compiler/library versions; consumer caches additionally
separate backend profiles and modes.
Consumer scripts always unpack the current package into a new directory. Their
caches contain only third-party sources and compiled dependencies, excluding
Parlora, the host application, releases and application data. The library's own
cached BEAM output is removed before compiling its current source. PLTs are
updated by Dialyzer as dependencies change; tests always run after cache restores.

Reports are retained for seven days. Full generated audio recordings are uploaded
only when a job fails. A cache miss falls back to a normal build.

```sh
scripts/consumer.sh /absolute/path/to/new/order_desk
scripts/optional_backend_consumer.sh /absolute/path/to/new/consumer none
```

The consumer script materializes the canonical example, runs tests, assembles a
release and checks it without Mix. Use a new destination each time. The optional
profiles are `none`, `jido`, `sagents`, and `legion`.

Standalone scripts retain their full checks by default. CI uses
`PARLORA_CONSUMER_MODE=ci` for backend consumers (`test` and `prod`) and
`PARLORA_CONSUMER_MODE=smoke` for the routine macOS OrderDesk release check
(`prod` only). `PARLORA_CONSUMER_CACHE=/absolute/cache` optionally reuses consumer
dependencies. Cargo shares `CARGO_TARGET_DIR` within each CI job, including fresh
packaged consumers, so native dependencies are not rebuilt for each environment.
Consumer caching uses `rsync`, which CI installs on Linux and macOS provides.

## Audio, browser and release checks

Development reports, qualification attempts, measured limits and retained failures
belong in `validation/` or the development investigation pages. Start with
[implementation status](docs/implementation-status.md),
[audio criteria](docs/audio-readiness.md), and [release tooling](validation/release/README.md).
These are not user-facing usage guides.

```sh
scripts/audio_benchmark.sh /tmp/parlora-audio-gates
scripts/release_check.sh /absolute/consumer --output /absolute/new-report
scripts/concurrency_check.sh /absolute/consumer /absolute/new-concurrency-report
```

Live provider runs need explicit credentials and may incur charges. Keep raw
transcripts, audio and secrets out of general logs and reports.

## Documentation

`mix docs --warnings-as-errors` builds HTML and EPUB under `doc/`. Public extras
and package files are explicitly listed in `mix.exs`; investigation reports and
numeric result files must stay outside those lists. Keep README focused on setup
and usage, and document adapter options and limitations in their respective guides.
Use the generated pages to check navigation and links before publishing.

`mix hex.build` builds a local source archive; it does not publish it. Packaging
metadata must be completed before a public release.
