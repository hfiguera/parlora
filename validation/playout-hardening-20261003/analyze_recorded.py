"""Bound a decoded chirp replay with known source shortages; not an audibility test."""
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'audio'))
from analyze import analyze  # noqa: E402

directory = pathlib.Path(sys.argv[1])
capture = json.loads(pathlib.Path(sys.argv[2]).read_text())
normal = analyze(directory)
browser = json.loads((directory / 'browser.json').read_text())
server = browser.get('finished', {})
bytes_before = 0
deficit_us = 0
for arrival in capture['arrivals']:
    deficit_us = max(deficit_us, arrival['at_us'] - bytes_before * 1_000_000 / 48_000)
    bytes_before += arrival['bytes']

gaps = [event['data'] for event in browser['events']
        if event['type'] == 'observation' and event['data']['cause'] == 'source_resumed']
local_silence_us = sum(gap['inserted_silence_us'] for gap in gaps)
accelerated = normal['receiver_accelerated_samples'] * 1000 / browser['trackSampleRate']
decelerated = normal['receiver_decelerated_samples'] * 1000 / browser['trackSampleRate']
# Opus/NetEq may fill a locally silent interval with nonzero decay or comfort
# noise. RMS thresholding therefore cannot account for the source timeline.
expected = normal['expected_duration_ms'] + local_silence_us / 1000

checks = {key: normal['checks'][key] for key in [
    'cleanup', 'decoded_start_under_300ms', 'track_capture', 'no_pipeline_failure',
    'receiver_statistics', 'no_steady_concealment']}
checks.update({
    'all_source_packetized': server.get('rendered_source_bytes') == capture['received_bytes'],
    'tail_drained': server.get('output_bytes') == 0,
    'no_partial_padding': server.get('rendered_padding_bytes') == 0,
    'local_silence_bounded': local_silence_us <= deficit_us + 130_000,
    'each_recovery_bounded': all(gap['recovery_wait_us'] <= 130_000 for gap in gaps),
    # Conservative because receiver start also includes codec/transport delay.
    'decoded_silence_bounded': normal['internal_silence_ms'] <= deficit_us / 1000 + 150,
    'decoded_duration_accounting':
        expected - accelerated - 50 <= normal['signal_duration_ms'] <= expected + decelerated + 50,
})
report = {
    'passed': all(checks.values()), 'checks': checks,
    'boundary': normal['boundary'], 'source_bytes': capture['received_bytes'],
    'receipt_deficit_us': deficit_us, 'local_inserted_silence_us': local_silence_us,
    'local_gap_count': len(gaps), 'decoded_silence_ms': normal['internal_silence_ms'],
    'longest_decoded_gap_ms': normal['longest_silence_ms'],
    'decoded_start_ms': normal['decoded_start_ms'],
    'steady_concealed_samples': normal['steady_concealed_samples'],
    'continuous_signal_gate_passed': normal['passed'],
    'explanation': 'Known source shortages allow bounded gaps. The ordinary no-gap gate is retained separately as analysis.json. Queue byte integrity is checked independently before lossy Opus.',
}
(directory / 'recorded-analysis.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
sys.exit(0 if report['passed'] else 1)
