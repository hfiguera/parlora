"""Summarize private diagnostic artifacts without copying PCM or caller text."""
import argparse
from array import array
from collections import Counter
import hashlib
import json
from pathlib import Path
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def summarize(directory):
    report_path = directory / 'report.json'
    report = json.loads(report_path.read_text())
    rows = []
    for result in report['results']:
        evidence_path = directory / result['evidence']
        evidence = json.loads(evidence_path.read_text())
        identity = evidence['provider_diagnostics']['identity']['session_id']
        provider_path = directory / 'provider' / (identity + '.json')
        provider = json.loads(provider_path.read_text())
        pcm_path = provider_path.with_suffix('.pcm')
        samples = array('h', pcm_path.read_bytes())
        if sys.byteorder != 'little':
            samples.byteswap()
        if not provider['audio_truncated']:
            assert digest(pcm_path) == provider['sent_audio_sha256']
        events = provider['events']
        sent = next((e for e in events if e['direction'] == 'send' and e['type'] == 'session.instructions.append'), None)
        ack = next((e for e in events if e['direction'] == 'receive' and e['type'] == 'session.instructions.appended'), None)
        inputs = []
        for checkpoint in evidence['checkpoints']:
            if checkpoint['kind'] == 'input-end':
                inputs.append({'clip': checkpoint['clip'], 'media': checkpoint.get('media')})
        rows.append({
            **result, 'evidence_sha256': digest(evidence_path),
            'provider_report_sha256': digest(provider_path),
            'sent_pcm_sha256': digest(pcm_path),
            'accepted_audio_bytes': provider['accepted_audio_bytes'],
            'sent_audio_bytes': provider['sent_audio_bytes'],
            'captured_audio_bytes': provider['captured_audio_bytes'],
            'audio_truncated': provider['audio_truncated'],
            'omitted_events': provider['omitted_events'],
            'captured_pcm_peak': max(map(abs, samples), default=0),
            'captured_nonzero_samples': sum(s != 0 for s in samples),
            'received_event_counts': provider['received_event_counts'],
            'greeting_ack_ms': (ack['at_us'] - sent['at_us']) / 1000 if sent and ack else None,
            'input_media': inputs,
        })
    return {'run': directory.name, 'report_sha256': digest(report_path),
            'outcomes': dict(Counter(r['status'] for r in rows)),
            'cleanup': report['cleanup'], 'trials': rows}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('runs', nargs='+', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    data = {'runs': [summarize(p) for p in args.runs],
            'limits': ['No caller text or PCM included.',
                       'Transport-sent bytes do not prove remote receipt.',
                       'PCM peak proves nonzero local input, not recognition or intelligibility.',
                       'Greeting delay matches the single greeting instruction by event type; other commands are not correlated.',
                       'Raw outcomes are retained; later trials do not replace old failures.']}
    with args.output.open('x') as output:
        json.dump(data, output, indent=2)
        output.write('\n')
