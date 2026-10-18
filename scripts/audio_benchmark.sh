#!/bin/sh
# Local deterministic/browser gate runner. No API keys or microphone required.
set -eu
cd "$(dirname "$0")/.."
export MIX_ENV=test
if [ "$(uname -s)" = Darwin ]; then
  export ERL_FLAGS="${ERL_FLAGS:-+sbwt none +sbwtdcpu none +sbwtdio none}"
  export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.92.0}"
fi
command -v node >/dev/null || { echo "Node.js is required" >&2; exit 1; }
parlora_audio_output=${1:-/tmp/parlora-audio-benchmark}
mkdir -p "$parlora_audio_output"
mix parlora.audio_benchmark --seeds 20 --output "$parlora_audio_output/matrix.json"
python3 validation/audio/test_analyze.py
python3 - <<'PYCODE'
import socket
with socket.socket() as listener:
    try:listener.bind(('127.0.0.1',4002))
    except OSError:raise SystemExit('Port 4002 is occupied; refusing to test against another server')
PYCODE
mix run scripts/audio_benchmark_server.exs > "$parlora_audio_output/server.log" 2>&1 &
parlora_audio_server=$!
trap 'kill "$parlora_audio_server" 2>/dev/null || true' EXIT HUP INT TERM
python3 - <<'PY'
import time,urllib.request
for _ in range(100):
    try:
        urllib.request.urlopen('http://127.0.0.1:4002/health',timeout=1)
        break
    except OSError:time.sleep(.1)
else:raise SystemExit('Benchmark server did not start')
PY
kill -0 "$parlora_audio_server"
parlora_audio_failed=0
for parlora_audio_scenario in steady jitter burst variable; do
  node validation/audio/receiver.cjs "$parlora_audio_output/$parlora_audio_scenario" "$parlora_audio_scenario" || parlora_audio_failed=1
  python3 validation/audio/analyze.py "$parlora_audio_output/$parlora_audio_scenario" > "$parlora_audio_output/$parlora_audio_scenario/analysis.log" || parlora_audio_failed=1
done
node validation/audio/receiver.cjs "$parlora_audio_output/interrupt" steady interrupt || parlora_audio_failed=1
python3 validation/audio/analyze.py "$parlora_audio_output/interrupt" > "$parlora_audio_output/interrupt/analysis.log" || parlora_audio_failed=1
node validation/audio/receiver.cjs "$parlora_audio_output/disconnect" steady disconnect || parlora_audio_failed=1
node validation/audio/receiver.cjs "$parlora_audio_output/reconnect" steady || parlora_audio_failed=1
python3 validation/audio/analyze.py "$parlora_audio_output/reconnect" > "$parlora_audio_output/reconnect/analysis.log" || parlora_audio_failed=1
python3 validation/audio/report.py "$parlora_audio_output" > "$parlora_audio_output/report.log" || parlora_audio_failed=1
exit "$parlora_audio_failed"
