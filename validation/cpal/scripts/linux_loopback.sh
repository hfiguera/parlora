#!/bin/sh
set -eu
# Run from validation/cpal after mix test, with the pinned tools on PATH.
probe_module=$(pactl load-module module-null-sink sink_name=parlora_cpal_probe \
  sink_properties=device.description=ParloraCpalProbe rate=48000 channels=2)
trap 'pactl unload-module "$probe_module"' EXIT
export MIX_ENV=test CPAL_HOST=PulseAudio
export CPAL_INPUT='Monitor of ParloraCpalProbe' CPAL_OUTPUT=ParloraCpalProbe
CPAL_VIRTUAL_LOOPBACK=1 timeout 25s mix run --no-compile scripts/device_smoke.exs
timeout 25s mix run --no-compile scripts/device_lifecycle.exs
