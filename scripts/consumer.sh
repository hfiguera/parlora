#!/bin/sh
# Materialize and validate a standalone app against the built source package.
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" = Darwin ]; then
  export ERL_FLAGS="${ERL_FLAGS:-+sbwt none +sbwtdcpu none +sbwtdio none}"
  if [ "$(uname -m)" = arm64 ]; then
    export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.92.0-aarch64-apple-darwin}"
  fi
fi
if [ "$#" -gt 0 ]; then
  # Refuse to overwrite an existing application.
  mkdir "$1"
  parlora_consumer=$(cd "$1" && pwd)
else
  parlora_consumer=$(mktemp -d "${TMPDIR:-/tmp}/parlora-consumer.XXXXXX")
fi
# Copy the canonical example, excluding local builds, databases and recordings.
parlora_sources=$(mktemp "${TMPDIR:-/tmp}/parlora-example.XXXXXX")
trap 'rm -f "$parlora_sources"' EXIT HUP INT TERM
tar -C examples/order_desk \
  --exclude='./_build' --exclude='./deps' --exclude='./vendor' \
  --exclude='./data' --exclude='./priv/browser/test-audio' \
  --exclude='__pycache__' --exclude='./erl_crash.dump' \
  --exclude='./.env' --exclude='./.env.*' --exclude='./.DS_Store' \
  -cf "$parlora_sources" .
tar -xf "$parlora_sources" -C "$parlora_consumer"
rm -f "$parlora_sources"
trap - EXIT HUP INT TERM
mkdir -p "$parlora_consumer/vendor"
MIX_ENV=dev mix hex.build --unpack --output "$parlora_consumer/vendor/parlora"
cd "$parlora_consumer"
export MIX_ENV=test
mix deps.get --check-locked
mix compile --warnings-as-errors
# Formatting is canonical on the pinned development Elixir, not older compilers.
if [ "${PARLORA_CHECK_FORMAT:-1}" = 1 ]; then
  mix format --check-formatted
fi
mix test --warnings-as-errors
export MIX_ENV=prod
mix deps.get --check-locked
mix compile --warnings-as-errors
mix release
# Run from the release, outside the source project, without Mix on its code path.
parlora_release="$parlora_consumer/_build/prod/rel/order_desk"
cd "$parlora_release"
OPENAI_API_KEY=consumer-config-check bin/order_desk eval '
  {:ok, _} = Application.ensure_all_started(:order_desk)
  "consumer-config-check" = Application.fetch_env!(:order_desk, :openai_api_key)
  false = Code.ensure_loaded?(Parlora.TestSupport.MemoryProvider)
  false = Code.ensure_loaded?(Mix)
  expected_sagents = System.get_env("PARLORA_BACKEND") == "sagents"
  ^expected_sagents = Code.ensure_loaded?(Sagents.Agent)
  expected_legion = System.get_env("PARLORA_BACKEND") == "legion"
  ^expected_legion = Code.ensure_loaded?(Legion)
  Application.put_env(:order_desk, :backend, :jido)
  OrderDesk.Smoke.run()
'
printf '\nStandalone consumer ready: %s\n' "$parlora_consumer"
