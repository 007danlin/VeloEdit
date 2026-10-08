#!/usr/bin/env python3
"""Run prepared development cases sequentially, retaining failures and exports.

Requires prebuilt Swift test bundles. This is not a speed benchmark: UI checks,
other builds and thermal load may run concurrently. Never rewrites a used input.
"""
import argparse, datetime, json, os, pathlib, subprocess, time

root = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--side', choices=['before', 'after'], required=True)
parser.add_argument('--cases', nargs='*')
args = parser.parse_args()
corpus = root / 'Build/EditorialQuality/corpus'
manifest = json.loads((corpus / 'manifest.json').read_text())
package = root if args.side == 'after' else root / 'Build/EditorialQuality/baseline-runner'
scratch = '/tmp/veloedit-editorial-quality-swift' if args.side == 'after' else '/tmp/veloedit-editorial-baseline-swift'
for case in manifest['cases']:
    case_id = case['id']
    if args.cases and case_id not in args.cases:
        continue
    project = corpus / case_id / (args.side + '.veloedit')
    report = project / 'quality-result.json'
    if report.exists():
        print(case_id, args.side, 'existing result preserved', flush=True)
        continue
    initial = json.loads((project / 'project.json').read_text())
    if initial.get('timelines') or initial.get('storyPlans') or initial.get('filmBuildRecovery'):
        print(case_id, args.side, 'used input preserved; inspect failed run', flush=True)
        continue
    started = time.monotonic()
    log_path = corpus / case_id / (args.side + '.log')
    env = dict(os.environ, VELOEDIT_EDITORIAL_CORPUS_PROJECT=str(project))
    command = ['swift', 'test', '--package-path', str(package), '--scratch-path', scratch,
               '--disable-sandbox', '--skip-build', '--filter', 'editorialQualityRealCorpusCase']
    print(case_id, args.side, 'started', flush=True)
    with log_path.open('w') as log:
        try:
            result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=3600)
            code = result.returncode
        except subprocess.TimeoutExpired:
            code = 'timeout-3600s'
    record = {'case': case_id, 'side': args.side, 'returnCode': code,
              'elapsedSeconds': time.monotonic() - started,
              'completedAt': datetime.datetime.now().astimezone().isoformat(),
              'isPerformanceAcceptance': False, 'humanReview': 'not-performed'}
    (corpus / case_id / (args.side + '-run.json')).write_text(json.dumps(record, indent=2))
    print(case_id, args.side, code, round(record['elapsedSeconds'], 2), flush=True)
