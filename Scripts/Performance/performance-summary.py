#!/usr/bin/env python3
"""Summarize completed rows without treating missing/error runs as successes."""
import collections
import json
import math
from pathlib import Path
import statistics

root = Path.cwd()
reports = root / 'Local/Reports/Validation/Performance'
def read(path):
    return json.loads(path.read_text()) if path.exists() else None
def stats(values, allow_p95=False):
    if not values:
        return {'n': 0}
    result = dict(n=len(values), median=statistics.median(values), minimum=min(values), maximum=max(values), values=values)
    if allow_p95 and len(values) >= 30:
        result['p95NearestRank'] = sorted(values)[math.ceil(.95 * len(values)) - 1]
    return result

summary = dict(coldWarm={}, paired={}, director={}, applySave={}, resources={})
for mode in ['fast', 'balanced', 'quality', 'maximum']:
    summary['coldWarm'][mode] = {}
    for label in ['before-valid', 'after-current']:
        for cache in ['cold', 'warm']:
            d = read(root / f'Build/Performance/{label}/{mode}-{cache}.json')
            if d:
                summary['coldWarm'][mode][label + '-' + cache] = {
                    'seconds': d['wallSeconds'], 'exitCode': d['exitCode'],
                    'validCompletedRun': d['exitCode'] == 0,
                    'modelsBefore': [m.get('name') for m in d.get('loadedModelsBefore', {}).get('models', [])],
                    'sampledFrames': sum(a.get('sampledFrameCount', 0) for a in d.get('analyses', [])),
                    'candidates': sum(len(a.get('candidates', [])) for a in d.get('analyses', []))}
    rows = read(root / f'Build/Performance/paired-{mode}/results.json') or []
    if rows:
        summary['paired'][mode] = {label: stats([r['seconds'] for r in rows if r['label'] == label and r['exitCode'] == 0]) for label in ['before', 'after']}
for label in ['before', 'after']:
    d = read(reports / f'director-{label}.json') or []
    summary['director'][label] = dict(stats([r['seconds'] for r in d], True),
        correct=sum(r['correct'] for r in d), runtimes=dict(collections.Counter(r['runtime'] for r in d)))
    semantic = root / f'Build/Performance/apply-save-semantic-{label}/results.json'
    d = read(semantic if semantic.exists() else root / f'Build/Performance/apply-save-{label}/results.json') or []
    summary['applySave'][label] = dict(stats([r['applyAndSaveIncludingCLILaunchSeconds'] for r in d if r['exitCode'] == 0], True),
        comparisonKind='canonical unordered Swift collection fields' if semantic.exists() else 'raw JSON; unordered fields can differ',
        analysesPreserved=all(r['sourceAnalysisPreserved'] for r in d) if d else None,
        savedVolumesCorrect=all(r['savedMusic']['volume'] == (20 + i % 2) / 100 for i, r in enumerate(d)) if d else None,
        exitCodes=dict(collections.Counter(r['exitCode'] for r in d)))
for path in sorted(reports.glob('runtime-resources*.jsonl')):
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    max_cli = max((sum(p['rssKiB'] for p in r['processes'] if p['process'].endswith('/veloedit-cli')) for r in rows), default=0)
    max_model = max((sum(p['rssKiB'] for p in r['processes'] if 'ollama' in p['process']) for r in rows), default=0)
    summary['resources'][path.name] = dict(samples=len(rows), observedCLIMaxMiB=max_cli/1024, observedCombinedOllamaMaxGiB=max_model/1048576)
summary['sequence'] = read(reports / 'sequence-pairs.json')
summary['film'] = read(root / 'Build/Performance/real-film/measurements.json')
summary['baselineFilm'] = read(root / 'Build/Performance/baseline-film/measurements.json')
(reports / 'measurements-summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
print(json.dumps({k: v for k, v in summary.items() if k in ['paired', 'director', 'applySave', 'film']}, ensure_ascii=False, indent=2))
