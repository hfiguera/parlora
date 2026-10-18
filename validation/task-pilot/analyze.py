"""Summarize immutable task-pilot runs without API calls or relabeling failures."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def summarize(paths):
    attempts, review, provenance = [], [], []
    for directory in paths:
        report = json.loads((directory / 'report.json').read_text())
        if report.get('error'):
            raise ValueError(f'Incomplete worker {directory}: {report["error"]}')
        planned = len(report['cases']) * report['repetitions']
        if len(report['results']) != planned:
            raise ValueError(f'Incomplete worker: {directory}')
        provenance.append({'run': directory.name, 'report_sha256': digest(directory/'report.json'),
                           'sources': report['sources'], 'git_revision': report['git_revision'],
                           'audio_sha256': report['audio_sha256'], 'cleanup': report.get('cleanup')})
        for result in report['results']:
            evidence_path = directory / result['evidence']
            evidence = json.loads(evidence_path.read_text())
            checkpoints = evidence['checkpoints']
            final = next((c for c in reversed(checkpoints) if c['kind'] == 'final'), {})
            transcript = [(e['observed_at_ms'], e['payload']['speaker'], e['payload']['delta'])
                          for e in evidence['events'] if e['type'] == 'transcript']
            dialogue = []
            for at, speaker, text in transcript:
                if dialogue and dialogue[-1]['speaker'] == speaker:
                    dialogue[-1]['text'] += text
                else:
                    dialogue.append({'speaker': speaker, 'text': text, 'at_ms': at})
            latency = []
            for c in checkpoints:
                if c['kind'] == 'outcome':
                    before = [p for p in checkpoints if p['kind'] == 'input-end' and p['at_ms'] <= c['at_ms']]
                    if before:
                        latency.append(c['at_ms'] - before[-1]['at_ms'])
            case = result['name'].rsplit('-r', 1)[0]
            jobs = list((final.get('state') or {}).get('jobs', {}).values())
            attempt = {'case': case, 'trial': result['name'], 'run': directory.name,
                       'status': result['status'], 'error': result.get('error'),
                       'duration_ms': result['duration_ms'], 'reply_check_latency_from_clip_end_ms': latency,
                       'backend_requests': [{'order': j['input']['order'], 'operation': j['input']['operation']} for j in jobs],
                       'clarifications': sum(e.get('event') == 'clarification_requested' for e in evidence['events']),
                       'interpretation_stats': evidence.get('interpretation', {}).get('stats'),
                       'evidence_sha256': digest(evidence_path)}
            attempts.append(attempt)
            review.append({'trial': result['name'], 'status': result['status'], 'error': result.get('error'),
                           'dialogue': dialogue, 'state': final.get('state'), 'dashboard': final.get('dashboard')})
    ids = [a['trial'] for a in attempts]
    if len(ids) != len(set(ids)):
        raise ValueError('Duplicate trial IDs across workers')
    grouped = defaultdict(Counter)
    for a in attempts:
        grouped[a['case']][a['status']] += 1
    latencies = sorted(v for a in attempts if a['status'] == 'passed' for v in a['reply_check_latency_from_clip_end_ms'])
    summary = {'attempts': len(attempts), 'outcomes': dict(Counter(a['status'] for a in attempts)),
               'per_case': {k: dict(v) for k, v in sorted(grouped.items())},
               'passed_reply_checks': len(latencies),
               'reply_check_latency_ms': {str(q): latencies[max(0, math.ceil(len(latencies)*q)-1)] if latencies else None for q in (.5, .95)},
               'latency_note': 'Only passed explicit reply checks; wall time from WAV completion to backend+caption assertion. Not speech endpoint, first audio, or human-perceived latency.',
               'provenance': provenance, 'trials': attempts}
    return summary, review


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('runs', type=Path, nargs='+')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    summary, review = summarize(args.runs)
    args.output.mkdir(mode=0o700)
    (args.output/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    (args.output/'review.json').write_text(json.dumps(review, indent=2)+'\n')
    print(json.dumps({k:v for k,v in summary.items() if k not in ('provenance','trials')}, indent=2))
