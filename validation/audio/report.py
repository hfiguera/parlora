"""Aggregate explicit audio gates without equating them to production readiness."""
import hashlib
import json
import pathlib
import os
import platform
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
rows = []
for name in ['steady', 'jitter', 'burst', 'variable', 'interrupt', 'disconnect', 'reconnect']:
    path = root / name / ('browser.json' if name == 'disconnect' else 'analysis.json')
    result = json.loads(path.read_text()) if path.exists() else {'passed':False,'error':'Missing report'}
    rows.append({'name':name,'passed':result.get('passed',False),'report':str(path.relative_to(root))})
matrix_path = root / 'matrix.json'
matrix = json.loads(matrix_path.read_text()) if matrix_path.exists() else {'passed':False,'cases':[]}
files = sorted([*pathlib.Path('test/support/audio_benchmark').glob('*.ex'),
                *pathlib.Path('validation/audio').glob('*.*'),
                *pathlib.Path('scripts/support/audio_benchmark').glob('*.ex'),
                pathlib.Path('scripts/audio_benchmark_server.exs'),pathlib.Path('scripts/audio_benchmark.sh')])
def git_value(args):
    result = subprocess.run(['git',*args],text=True,capture_output=True)
    return result.stdout.strip() if result.returncode==0 else None

report = {'schema':1,'production_ready':False,'passed':matrix['passed'] and all(r['passed'] for r in rows),
    'revision':git_value(['rev-parse','HEAD']) or os.environ.get('PARLORA_SOURCE_REVISION'),
    'dirty':(bool(git_value(['status','--porcelain'])) if git_value(['rev-parse','HEAD']) else None),
    'platform':platform.platform(),'matrix_cases':len(matrix['cases']),'receiver_cases':rows,
    'library_sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(pathlib.Path('lib').rglob('*.ex'))},
    'harness_sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.is_file()},
    'remaining_evidence':['controlled network loss/reordering','long soak and capacity SLOs',
                          'physical speaker listening','telephony receiver recordings']}
(root / 'report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='harness_sha256'},indent=2))
sys.exit(0 if report['passed'] else 1)
