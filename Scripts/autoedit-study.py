#!/usr/bin/env python3
"""Sequential production runs on explicitly marked copies; never overwrite exports.

python3 Scripts/autoedit-study.py --root Build/AutoEditStudy-2026-09-30 \
  --cli Build/AutoEditStudy-2026-09-30/artifacts/baseline-cli --side baseline
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import subprocess
import time


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=pathlib.Path, required=True)
    p.add_argument('--cli', type=pathlib.Path, required=True)
    p.add_argument('--side', required=True)
    p.add_argument('--projects', type=int, nargs='+', default=list(range(1, 10)))
    args = p.parse_args()
    root, cli = args.root.resolve(), args.cli.resolve()
    binary_hash = hashlib.sha256(cli.read_bytes()).hexdigest()
    for n in args.projects:
        package = root / args.side / f'project-{n}.veloedit'
        marker = package / 'study-input.json'
        if not marker.is_file():
            raise SystemExit(f'Unmarked input refused: {package}')
        output = root / args.side / f'project-{n}-{args.side}.mp4'
        receipt = root / args.side / f'project-{n}-run.json'
        if output.exists() or receipt.exists():
            print(f'{args.side} {n}: existing attempt preserved', flush=True)
            continue
        before = (package / 'project.json').read_bytes()
        (package / 'study-manifest-before.json').write_bytes(before)
        start = time.monotonic()
        record = dict(project=n, side=args.side, cliSHA256=binary_hash,
                      manifestSHA256=hashlib.sha256(before).hexdigest(),
                      startedAt=datetime.datetime.now().astimezone().isoformat(),
                      command=[str(cli), 'study-film', str(package), str(output)])
        print(f'{args.side} {n}: started', flush=True)
        env = dict(os.environ, NSUnbufferedIO='YES',
                   VELOEDIT_TRACE_DIRECTORY=str(root / args.side / f'project-{n}-traces'))
        if args.side == 'development' or args.side.startswith('development-'):
            split = json.loads((root / 'split.json').read_text())
            assert n in split['development'], 'Holdout variant tracing refused'
            env['VELOEDIT_VARIANT_TRACE_DIRECTORY'] = str(root / args.side / f'project-{n}-variants')
        record['rankerPath'] = env.get('VELOEDIT_EDIT_RANKER')
        record['coherenceExperiment'] = env.get('VELOEDIT_COHERENCE_EXPERIMENT')
        if record['rankerPath']:
            record['rankerSHA256'] = hashlib.sha256(pathlib.Path(record['rankerPath']).read_bytes()).hexdigest()
        with (root / 'logs' / f'{args.side}-{n}.log').open('w') as log:
            result = subprocess.run(record['command'], env=env, stdout=log, stderr=subprocess.STDOUT)
        record.update(exitCode=result.returncode, elapsedSeconds=time.monotonic()-start,
                      outputExists=output.is_file(),
                      finishedAt=datetime.datetime.now().astimezone().isoformat())
        receipt.write_text(json.dumps(record, ensure_ascii=False, indent=2))
        print(json.dumps(record, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
