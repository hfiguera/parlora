#!/bin/sh
# Offline by default; --live opts into the fixed paid evaluation batch.
set -eu
cd "$(dirname "$0")/.."
exec node validation/release/run.cjs "$@"
