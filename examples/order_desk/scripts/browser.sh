#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export ORDER_DESK_TYPESAFE=1
if [ "$(uname -s)" = Darwin ]; then
  # Measured on the development Mac: avoid one-second idle timer stalls.
  export ERL_FLAGS="${ERL_FLAGS:-+sbwt none +sbwtdcpu none +sbwtdio none}"
  if [ "$(uname -m)" = arm64 ]; then
    export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.92.0-aarch64-apple-darwin}"
  fi
  if [ "${PARLORA_BROWSER_OFFLINE:-0}" = 1 ]; then
    exec mix run -e 'OrderDesk.BrowserServer.run()'
  fi
  exec python3 scripts/with_keychain.py mix run -e 'OrderDesk.BrowserServer.run()'
fi
exec mix run -e 'OrderDesk.BrowserServer.run()'
