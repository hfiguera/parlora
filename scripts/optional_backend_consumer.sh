#!/bin/sh
# Verify a packaged consumer with no framework, or exactly one selected framework.
set -eu
cd "$(dirname "$0")/.."
. scripts/support/consumer_cache.sh
if [ "$#" -gt 2 ]; then
  printf 'Usage: %s [new-directory] [none|jido|sagents|legion]\n' "$0" >&2
  exit 1
fi
export PARLORA_OPTIONAL_BACKEND="${2:-none}"
case "$PARLORA_OPTIONAL_BACKEND" in
  none|jido|sagents|legion) ;;
  *) printf 'Unknown optional backend\n' >&2; exit 1 ;;
esac
if [ "$(uname -s)" = Darwin ]; then
  export ERL_FLAGS="${ERL_FLAGS:-+sbwt none +sbwtdcpu none +sbwtdio none}"
fi
if [ "$#" -gt 0 ]; then
  mkdir "$1"
  parlora_consumer=$(cd "$1" && pwd)
else
  parlora_consumer=$(mktemp -d "${TMPDIR:-/tmp}/parlora-optional.XXXXXX")
fi
cp -R validation/optional-backends/consumer/. "$parlora_consumer/"
cp .tool-versions "$parlora_consumer/.tool-versions"
cp mix.lock "$parlora_consumer/mix.lock"
mkdir -p "$parlora_consumer/vendor" "$parlora_consumer/lib/adapters" "$parlora_consumer/test/support"
# These fixture adapters belong to the host, not the packaged library.
for parlora_fixture in memory_audio memory_channel contract_provider fake_backend order_policy; do
  cp "test/support/$parlora_fixture.ex" "$parlora_consumer/lib/adapters/"
done
cp test/provider_contract_test.exs "$parlora_consumer/test/"
case "$PARLORA_OPTIONAL_BACKEND" in
  jido)
    cp test/jido_test.exs "$parlora_consumer/test/"
    cp test/support/jido_agent.ex "$parlora_consumer/test/support/"
    ;;
  sagents|legion)
    cp "test/${PARLORA_OPTIONAL_BACKEND}_test.exs" "$parlora_consumer/test/"
    cp "test/support/${PARLORA_OPTIONAL_BACKEND}_model.ex" "$parlora_consumer/test/support/"
    ;;
esac
MIX_ENV=dev mix hex.build --unpack --output "$parlora_consumer/vendor/parlora"
parlora_restore_consumer_cache
cd "$parlora_consumer"
case "${PARLORA_CONSUMER_MODE:-full}" in
  full) parlora_environments='dev test prod' ;;
  ci) parlora_environments='test prod' ;;
  smoke) parlora_environments=prod ;;
esac
parlora_formatted=0
for parlora_environment in $parlora_environments; do
  export MIX_ENV="$parlora_environment"
  mix deps.get --check-locked
  mix compile --warnings-as-errors
  if [ "${PARLORA_CHECK_FORMAT:-1}" = 1 ] && [ "$parlora_formatted" = 0 ]; then
    mix format --check-formatted
    parlora_formatted=1
  fi
  if [ "$parlora_environment" = test ]; then
    mix test --warnings-as-errors
  fi
done
mix release
cd "$parlora_consumer/_build/prod/rel/optional_backend_consumer"
bin/optional_backend_consumer eval '
  {:ok, _} = Application.ensure_all_started(:optional_backend_consumer)
  false = Code.ensure_loaded?(Mix)
  OptionalBackendConsumer.smoke()
'
parlora_save_consumer_cache
printf '\nOptional backend consumer (%s) ready: %s\n' "$PARLORA_OPTIONAL_BACKEND" "$parlora_consumer"
