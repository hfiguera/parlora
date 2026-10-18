#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" = Darwin ]; then
  # Measured on the development Mac: avoid one-second idle timer stalls.
  export ERL_FLAGS="${ERL_FLAGS:-+sbwt none +sbwtdcpu none +sbwtdio none}"
  if [ "$(uname -m)" = arm64 ]; then
    export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.92.0-aarch64-apple-darwin}"
  fi
  exec python3 scripts/with_keychain.py mix run examples/local_voice.exs
fi
exec mix run examples/local_voice.exs
