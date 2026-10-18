# Deterministic browser diagnostic regressions; no devices, credentials, or network.
# Run from the repository root: mix run validation/browser/media_diagnostics.exs
ExUnit.start()
Code.require_file("../../test/browser_diagnostics_test.exs", __DIR__)
