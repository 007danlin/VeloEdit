#!/usr/bin/env python3
"""Finish development exports as frozen baseline runs become available.

This is one local process, not a scheduled automation. It never opens holdout
material, trains a model, changes originals or silently retries failed edits.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import subprocess
import sys
import time


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, required=True)
    parser.add_argument('--freeze', type=pathlib.Path, required=True)
    parser.add_argument('--side', default='development-r2')
    parser.add_argument('--projects', type=int, nargs='+')
    args = parser.parse_args()
    root = args.root.resolve()
    freeze = json.loads(args.freeze.read_text())
    cli = pathlib.Path(freeze['cli'])
    assert freeze['fullAppBuildSucceeded'] and freeze['sourceStableDuringBuild']
    assert digest(cli) == freeze['cliSHA256'], 'Frozen CLI changed'
    assert args.side.startswith('development-'), 'Use a fresh development round'
    split = json.loads((root/'split.json').read_text())
    projects = args.projects or split['development']
    assert set(projects) <= set(split['development']), 'Holdout refused'
    scripts = pathlib.Path(__file__).resolve().parent
    state_file = root/f'{args.side}-state.json'
    completed = []

    def state(stage, project=None):
        result = dict(stage=stage, project=project, completed=completed,
                      cli=str(cli), cliSHA256=freeze['cliSHA256'],
                      updatedAt=datetime.datetime.now().astimezone().isoformat())
        temporary = state_file.with_suffix('.tmp')
        temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2))
        temporary.replace(state_file)
        print(json.dumps(result, ensure_ascii=False), flush=True)

    def run(command, log):
        with log.open('w') as output:
            subprocess.run([str(x) for x in command], stdout=output,
                           stderr=subprocess.STDOUT, check=True)

    try:
        for n in projects:
            baseline_receipt = root/'baseline'/f'project-{n}-run.json'
            state('waiting-for-baseline', n)
            while True:
                try:
                    baseline = json.loads(baseline_receipt.read_text())
                    break
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
                time.sleep(30)
            assert baseline['exitCode'] == 0 and baseline['outputExists'], f'Baseline {n} failed'
            directory = root/args.side
            package = directory/f'project-{n}.veloedit'
            video = directory/f'project-{n}-{args.side}.mp4'
            receipt = directory/f'project-{n}-run.json'
            if not package.exists():
                state('copying-complete-project', n)
                run([sys.executable, scripts/'prepare-study-copy.py', '--root', root,
                     '--side', args.side, '--projects', n], root/'logs'/f'{args.side}-{n}-copy.log')
            if not receipt.exists():
                assert not video.exists(), 'Unfinished export preserved; inspect before retrying'
                state('creating-and-rendering-film', n)
                run([sys.executable, scripts/'autoedit-study.py', '--root', root, '--cli', cli,
                     '--side', args.side, '--projects', n], root/'logs'/f'{args.side}-{n}-runner.log')
            recorded = json.loads(receipt.read_text())
            assert recorded['exitCode'] == 0 and recorded['outputExists']
            assert recorded['cliSHA256'] == freeze['cliSHA256'], 'Mixed executable versions refused'
            state('verifying-export', n)
            checks = directory/f'project-{n}-verification'
            report = checks/'technical-report.json'
            if not report.exists():
                run([sys.executable, scripts/'verify-study-export.py', video, checks],
                    root/'logs'/f'{args.side}-{n}-verify.log')
            assert json.loads(report.read_text())['fullDecodeCompleted'], 'Export decode failed'
            chronology = directory/f'project-{n}-chronology.json'
            if not chronology.exists():
                run([cli, 'audit-chronology', package, chronology], root/'logs'/f'{args.side}-{n}-chronology.log')
            examples = directory/f'project-{n}-examples.json'
            if not examples.exists():
                run([cli, 'decision-examples', package, examples], root/'logs'/f'{args.side}-{n}-examples.log')
            completed.append(n)
            state('export-ready-for-review', n)
        state('development-exports-ready-for-review-and-training' if set(completed) == set(split['development']) else 'partial-development-exports-ready-for-review')
    except BaseException:
        state('stopped-needs-inspection', n if 'n' in locals() else None)
        raise


if __name__ == '__main__':
    main()
