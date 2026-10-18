"""Summarize private timeout diagnostics without copying requests, headers or credentials."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def percentile(values, q):
    values = sorted(values)
    return values[math.ceil(len(values) * q) - 1] if values else None


def summarize(directory):
    trace = directory / 'interpretation-phases.jsonl'
    records = [json.loads(line) for line in trace.read_text().splitlines()]
    samples = [r for r in records if r['event'] == 'sample']
    stops = [r for r in records if r['event'] == 'stop']
    requests = []
    for stop in stops:
        observations = [(row, request) for row in samples for request in row.get('requests', [])
                        if request['id'] == stop['request']]
        requests.append({
            'request': stop['request'], 'outcome': stop['outcome'],
            'at_ms': stop['at_ms'], 'duration_ms': stop['measurements']['duration'],
            'samples': len(observations),
            'last_observed_phase': observations[-1][1] if observations else None,
            'connections': sorted({row['connection'] for row, _ in observations if row.get('connection') is not None}),
            'max_client_mailbox': max((row.get('mailbox', 0) for row, _ in observations), default=None),
            'upload_completed_observed': any(r['phase'] == 'inflight' and r['upload_remaining'] is None for _, r in observations),
        })
    duration = [r['duration_ms'] for r in requests]
    return {
        'trace_sha256': digest(trace), 'records': len(records),
        'outcomes': dict(Counter(r['outcome'] for r in requests)),
        'duration_ms': {'p50': percentile(duration, .5), 'p95': percentile(duration, .95), 'max': max(duration, default=None)},
        'max_sample_gap_ms': max((s.get('sample_gap_ms', 0) for s in samples), default=None),
        'sample_timeouts': sum(bool(s.get('sample_timeout')) for s in samples),
        'sample_errors': sum(bool(s.get('sample_error')) for s in samples),
        'max_observed_queue': max((s.get('queue', 0) for s in samples), default=None),
        'requests': requests,
        'limitations': ['Phase observations are sampled, not packet or remote-server traces.',
                        'A missing response does not identify its remote or network cause.',
                        'Transport state is diagnostic-only and specific to typesafe_ai 0.1.0.'],
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = summarize(args.run)
    with args.output.open('x') as output:
        json.dump(result, output, indent=2)
        output.write('\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'requests'}, indent=2))
