#!/bin/sh
set -eu
parlora_module=$(pactl load-module module-null-sink sink_name=parlora_v1_validation \
  sink_properties=device.description=ParloraV1Validation rate=48000 channels=2)
trap 'pactl unload-module "$parlora_module"' EXIT
export CPAL_HOST=PulseAudio CPAL_INPUT='Monitor of ParloraV1Validation' CPAL_OUTPUT=ParloraV1Validation
export CPAL_VIRTUAL_LOOPBACK=1
timeout "${PARLORA_AUDIO_TIMEOUT_SECONDS:-60}s" mix run "${1:-scripts/audio_validation.exs}"
