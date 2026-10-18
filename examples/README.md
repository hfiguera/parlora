# Parlora examples

- **[Local voice](local_voice.exs):** a small in-repository order-lookup example.
  Run `scripts/local_voice.sh` from the repository root; its application helpers
  live in `examples/support/`.
- **[OrderDesk](order_desk/README.md):** a complete, separate Mix application with
  local audio, browser, Twilio and Telnyx entry points, a database, business
  policies, UI and its own tests. This directory is its authoritative source.

To validate the packaged library in isolation, run `scripts/consumer.sh` from the
repository root. It copies OrderDesk into a new directory, installs the built Hex
source package, runs its tests, builds a release and exercises that release.
External copies such as `parlora_consumer` are generated installations; maintain
application code in `examples/order_desk` and regenerate copies as needed.

The library's checks cover its own source and the small local example. OrderDesk
uses its own Mix project and test/format checks, exercised by `scripts/consumer.sh`
in CI. Root formatting delegates to OrderDesk's formatter without traversing its
build or dependency directories. Recorded results and cross-project validation
harnesses remain in `validation/`.
