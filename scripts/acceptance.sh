#!/bin/sh
# Offline by default. --live explicitly enables bounded paid API/browser checks.
set -eu
cd "$(dirname "$0")/.."
exec node validation/acceptance/run.cjs "$@"
