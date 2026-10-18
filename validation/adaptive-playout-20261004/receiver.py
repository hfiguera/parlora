"""Compare decoded synthetic PCM on identical recorded GPT arrival schedules."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.request

root = Path(__file__).resolve().parents[2]
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
capture = root / 'validation/playout-hardening-20261003/gpt-live-arrivals.json'
reference = output / 'reference.pcm'
env = os.environ.copy()
env.update(MIX_ENV='test', AUDIO_SECONDS='45',
           AUDIO_ARRIVAL_SCHEDULE=str(capture), AUDIO_REFERENCE_PCM=str(reference))
env.setdefault('ERL_FLAGS', '+sbwt none +sbwtdcpu none +sbwtdio none')
env.setdefault('RUSTUP_TOOLCHAIN', '1.92.0-aarch64-apple-darwin')
subprocess.run(['mix', 'run', '-e',
                'File.write!(System.fetch_env!("AUDIO_REFERENCE_PCM"), '
                'Parlora.TestSupport.AudioBenchmark.Signal.pcm(43_800))'],
               env=env, cwd=root, check=True)

results = []
for name, mode, target in [('fixed-120', 'fixed', '120'),
                           ('fixed-200', 'fixed', '200'),
                           ('adaptive', 'adaptive', '120')]:
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 4002))
    directory = output / name
    directory.mkdir(exist_ok=True)
    run_env = dict(env, AUDIO_BUFFERING=mode, AUDIO_BUFFER_MS=target,
                   AUDIO_RECOVERY_MS='120', AUDIO_TIMELINE='1',
                   AUDIO_TRACE_DIRECTORY=str(directory / 'timeline'))
    with (directory / 'server.log').open('w') as log:
        server = subprocess.Popen(['mix', 'run', 'scripts/audio_benchmark_server.exs'],
                                  env=run_env, cwd=root, stdout=log, stderr=log)
        try:
            for _ in range(100):
                if server.poll() is not None:
                    raise RuntimeError(f'{name} server exited')
                try:
                    urllib.request.urlopen('http://127.0.0.1:4002/health', timeout=1)
                    break
                except OSError:
                    time.sleep(.1)
            else:
                raise RuntimeError(f'{name} server did not start')
            receiver = subprocess.run(['node', 'validation/audio/receiver.cjs', str(directory), 'steady'],
                                      cwd=root, env=run_env)
            analyzer = subprocess.run(['python3', 'validation/playout-hardening-20261003/analyze_recorded.py',
                                      str(directory), str(capture)], cwd=root, env=run_env)
            report = json.loads((directory / 'recorded-analysis.json').read_text())
            browser = json.loads((directory / 'browser.json').read_text())
            results.append(dict(policy=name, receiver_exit=receiver.returncode,
                                analyzer_exit=analyzer.returncode, report=report,
                                buffering={k: v for k, v in browser['finished'].items()
                                           if k.startswith('playback_') or k == 'recovery_buffer_ms'}))
            print(json.dumps(results[-1]), flush=True)
        finally:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()

report = dict(passed=all(r['report']['passed'] and r['receiver_exit'] == 0 for r in results),
              boundary='Chromium decoded track; synthetic chirp on recorded local receipts, no speakers',
              results=results)
(root / 'validation/adaptive-playout-20261004/receiver-results.json').write_text(
    json.dumps(report, indent=2) + '\n')
sys.exit(0 if report['passed'] else 1)
