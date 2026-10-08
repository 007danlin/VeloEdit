#!/usr/bin/env python3
"""Clone a completed baseline package and reuse measured analysis, never its edit.

Original media stay in place. APFS copy-on-write preserves a complete package.
Analysis reuse makes this a warm-cache edit comparison, not a speed benchmark.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=pathlib.Path, required=True)
    p.add_argument('--side', required=True)
    p.add_argument('--projects', type=int, nargs='+', required=True)
    args = p.parse_args(); root = args.root.resolve()
    split = json.loads((root/'split.json').read_text())
    if args.side == 'development' or args.side.startswith('development-') or args.side == 'model-smoke':
        assert set(args.projects) <= set(split['development']), 'Holdout refused for development'
    elif args.side == 'holdout':
        assert set(args.projects) <= set(split['holdout'])
        assert (root/'artifacts'/'final-freeze.json').is_file(), 'Freeze code/model before holdout'
    else:
        raise SystemExit('Use development, model-smoke or holdout')
    (root/args.side).mkdir(exist_ok=True)
    for n in args.projects:
        source = root/'baseline'/f'project-{n}.veloedit'
        destination = root/args.side/source.name
        receipt = json.loads((root/'baseline'/f'project-{n}-run.json').read_text())
        assert receipt['exitCode'] == 0 and receipt['outputExists'], 'Completed baseline required'
        assert not destination.exists(), f'Existing experiment preserved: {destination}'
        initial = json.loads((source/'study-manifest-before.json').read_text())
        measured_bytes = (source/'project.json').read_bytes()
        measured = json.loads(measured_bytes)
        for key in ('assets', 'analyses', 'telemetrySources'):
            initial[key] = measured[key]
        subprocess.run(['/bin/cp', '-cR', str(source), str(destination)], check=True)
        provenance = destination/'BaselineProvenance'; provenance.mkdir()
        for name in ('study-result.json', 'study-manifest-before.json', 'study-music-history.json', 'study-taste.json'):
            file = destination/name
            if file.exists(): file.rename(provenance/name)
        (provenance/'project.json').write_bytes(measured_bytes)
        (destination/'project.json').write_text(json.dumps(initial, ensure_ascii=False, indent=2))
        marker = dict(project=n, side=args.side, sourceMode='balanced',
            music='offline bundled/local', taste='empty isolated profile',
            analysisReuse='completed frozen baseline; warm cache; timing not directly comparable',
            baselineManifestSHA256=hashlib.sha256(measured_bytes).hexdigest())
        (destination/'study-input.json').write_text(json.dumps(marker, ensure_ascii=False, indent=2))
        print(destination)


if __name__ == '__main__': main()
