#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
: "${TWILIO_PUBLIC_URL:?Set TWILIO_PUBLIC_URL to the HTTPS ngrok origin for port 4100}"
: "${ORDER_DESK_DATABASE:?Set ORDER_DESK_DATABASE to an isolated demonstration SQLite path}"
export ORDER_DESK_TYPESAFE=1 ORDER_DESK_TWILIO=incoming
if [ "$(uname -s)" = Darwin ]; then
  export ERL_FLAGS="${ERL_FLAGS:-+sbwt none +sbwtdcpu none +sbwtdio none}"
  if [ "$(uname -m)" = arm64 ]; then
    export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.92.0-aarch64-apple-darwin}"
  fi
  exec python3 scripts/with_keychain.py mix run -e 'OrderDesk.TwilioServer.run()'
fi
exec mix run -e 'OrderDesk.TwilioServer.run()'
