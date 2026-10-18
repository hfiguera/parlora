#!/bin/sh
# Offline browser isolation, fault containment, and admission pilot.
set -eu
if [ "$#" -ne 2 ]; then
  echo 'Usage: scripts/concurrency_check.sh CONSUMER NEW_OUTPUT' >&2
  exit 2
fi
parlora_concurrency_consumer=$(cd "$1" && pwd)
case "$2" in
  /*) parlora_concurrency_output=$2 ;;
  *) parlora_concurrency_output="$PWD/$2" ;;
esac
cd "$(dirname "$0")/.."
parlora_concurrency_root=$PWD
python3 -m unittest discover -s validation/concurrency -p 'test_*.py'
(
  cd "$parlora_concurrency_consumer"
  MIX_ENV=dev mix run --no-start "$parlora_concurrency_root/validation/concurrency/shutdown_test.exs"
)
exec node validation/concurrency/run.cjs "$parlora_concurrency_consumer" "$parlora_concurrency_output"
