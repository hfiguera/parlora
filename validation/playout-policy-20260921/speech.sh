#!/bin/sh
# Decode identical generated speech and recorded arrivals under two policies.
set -eu
cd "$(dirname "$0")/../.."
: "${AUDIO_REFERENCE_PCM:?Set the path to the generated reference PCM}"
: "${AUDIO_ARRIVAL_SCHEDULE:?Set the matching recorded arrival schedule}"
export MIX_ENV=test
export AUDIO_SECONDS=25
parlora_speech_output=${1:-/tmp/parlora-policy-speech}
mkdir -p "$parlora_speech_output"
python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 4002))
PY
parlora_speech_pid=
trap '[ -z "$parlora_speech_pid" ] || kill "$parlora_speech_pid" 2>/dev/null || true' EXIT HUP INT TERM
for AUDIO_POLICY in current immediate; do
  export AUDIO_POLICY
  mix run validation/playout-policy-20260921/browser_server.exs > "$parlora_speech_output/$AUDIO_POLICY-server.log" 2>&1 &
  parlora_speech_pid=$!
  python3 - <<'PY'
import time, urllib.request
for _ in range(100):
    try:
        urllib.request.urlopen('http://127.0.0.1:4002/health', timeout=1)
        break
    except OSError:
        time.sleep(.1)
else:
    raise SystemExit('Speech benchmark server did not start')
PY
  kill -0 "$parlora_speech_pid"
  node validation/audio/receiver.cjs "$parlora_speech_output/$AUDIO_POLICY" steady
  kill "$parlora_speech_pid"
  wait "$parlora_speech_pid" || true
  parlora_speech_pid=
done
