#!/usr/bin/env python3
"""One-shot technical training after all seven development exports are verified.

Does not freeze the final evaluation, inspect holdout edits, enable a model, or
claim artistic improvement. Human review and independent evaluation stay open.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import subprocess
import sys
import time


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, required=True)
    parser.add_argument('--evidence-map', type=pathlib.Path, required=True)
    parser.add_argument('--once', action='store_true', help='Check readiness without waiting')
    args = parser.parse_args()
    root = args.root.resolve()
    split_path = root/'split.json'
    split_bytes = split_path.read_bytes()
    map_bytes = args.evidence_map.read_bytes()
    split = json.loads(split_bytes)
    evidence_map = {int(n): side for n, side in json.loads(map_bytes).items()}
    assert set(evidence_map) == set(split['development'])
    assert not set(evidence_map) & set(split['holdout'])
    assert all(isinstance(s, str) and pathlib.Path(s).name == s and s.startswith('development')
               for s in evidence_map.values())
    output = root/'training'
    assert not output.exists(), 'Existing training artifact preserved; inspect before another run'
    scripts = pathlib.Path(__file__).resolve().parent
    state_path = root/'training-state.json'

    def state(stage, **details):
        value = dict(stage=stage, updatedAt=datetime.datetime.now().astimezone().isoformat(),
                     splitSHA256=hashlib.sha256(split_bytes).hexdigest(),
                     evidenceMapSHA256=hashlib.sha256(map_bytes).hexdigest(), **details)
        temporary = state_path.with_suffix('.tmp')
        temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n')
        temporary.replace(state_path)
        print(json.dumps(value, ensure_ascii=False), flush=True)

    def readiness():
        pending = []
        for n, side in sorted(evidence_map.items()):
            directory = root/side
            paths = [directory/f'project-{n}-run.json',
                     directory/f'project-{n}-verification/technical-report.json',
                     directory/f'project-{n}-examples.json']
            for index, path in enumerate(paths):
                try:
                    record = json.loads(path.read_text())
                except (FileNotFoundError, json.JSONDecodeError):
                    pending.append(n)
                    break
                if index == 0:
                    assert record['exitCode'] == 0 and record['outputExists'], f'Export {n} failed'
                elif index == 1:
                    assert record['fullDecodeCompleted'], f'Full decode {n} failed'
                else:
                    assert record['examples'], f'Empty decision evidence {n}'
        return pending

    try:
        last_pending = None
        while True:
            assert split_path.read_bytes() == split_bytes, 'Split changed during wait'
            assert args.evidence_map.read_bytes() == map_bytes, 'Evidence map changed during wait'
            pending = readiness()
            if pending != last_pending:
                state('waiting-for-complete-development-evidence', pendingProjects=pending)
                last_pending = pending
            if not pending:
                break
            if args.once:
                return
            time.sleep(30)
        state('preparing-development-dataset')
        commands = [
            [sys.executable, str(scripts/'prepare-ranker-dataset.py'), '--root', str(root),
             '--evidence-map', str(args.evidence_map), '--require-all-development', '--output', str(output)],
            [sys.executable, str(scripts/'train-editing-ranker.py'), '--dataset', str(output/'dataset.json'),
             '--split', str(split_path), '--output', str(output)]
        ]
        for index, command in enumerate(commands):
            with (root/'logs'/f'seven-development-training-{index+1}.log').open('w') as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        model = json.loads((output/'model.json').read_text())
        assert model['validatedForDefault'] is False, 'Automatic default promotion refused'
        dataset = json.loads((output/'dataset.json').read_text())
        assert {row['project'] for row in dataset['inputs']} == set(split['development'])
        receipt = dict(commands=commands, modelSHA256=sha(output/'model.json'),
                       datasetSHA256=sha(output/'dataset.json'),
                       preparationScriptSHA256=sha(scripts/'prepare-ranker-dataset.py'),
                       trainingScriptSHA256=sha(scripts/'train-editing-ranker.py'),
                       modelID=model['modelID'], enabledByDefault=False,
                       remaining='Human artistic review, real runtime check of this model, final code/model freeze, independent evaluation of projects4/9')
        (output/'seven-project-training-receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2)+'\n')
        state('technical-model-trained-awaiting-runtime-and-independent-review', **receipt)
    except BaseException as error:
        state('stopped-needs-inspection', error=str(error))
        raise


if __name__ == '__main__':
    main()
