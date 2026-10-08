#!/usr/bin/env python3
"""Reproduce naming-only checks on a disposable copy; never edits source projects."""
import argparse
import copy
import json
import pathlib
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('project', type=pathlib.Path)
parser.add_argument('--cli', type=pathlib.Path, default=pathlib.Path('Build/veloedit-cli'))
parser.add_argument('--repeats', type=int, default=5)
args = parser.parse_args()
project = args.project.resolve()
root = pathlib.Path('Build/SmartChapterTitles').resolve()
if root not in project.parents:
    raise SystemExit('Use a disposable project copy inside Build/SmartChapterTitles/')
report = pathlib.Path('Local/Reports/Validation/SmartChapterTitles')
report.mkdir(parents=True, exist_ok=True)
file = project / 'project.json'
baseline = json.loads(file.read_text())
timeline = baseline['timelines'][-1]
# This driver measures the first naming call independently of previous trials.
timeline.pop('filmParts', None)
timeline.pop('chapterTitleDecisions', None)
rows = []
latest = None


def run(scenario, iteration, previous=None):
    started = time.monotonic()
    process = subprocess.run([str(args.cli.resolve()), 'refresh-chapter-titles', str(project)], capture_output=True, text=True, check=True)
    elapsed = time.monotonic() - started
    decisions = json.loads(process.stdout)
    result = json.loads(file.read_text())
    current = result['timelines'][-1]
    prior = {x['partID']: x for x in previous or []}
    changed = [x for x in decisions if x['partID'] not in prior or x['inputSignature'] != prior[x['partID']]['inputSignature']]
    row = {'scenario': scenario, 'iteration': iteration, 'wallSeconds': elapsed,
           'newModelCalls': sum(x['modelCalls'] for x in changed),
           'additionalDecodedFrames': 0, 'decisions': decisions}
    rows.append(row)
    (report / (project.stem + '-timings.json')).write_text(json.dumps(rows, ensure_ascii=False, indent=2))
    print(scenario, iteration, round(elapsed, 3), 'seconds;', row['newModelCalls'], 'new calls', flush=True)
    return result, current, decisions

for iteration in range(1, args.repeats + 1):
    file.write_text(json.dumps(baseline, ensure_ascii=False))
    result, named, decisions = run('empty-title-cache-model-may-be-warm', iteration)
    assert named['items'] == timeline['items'], 'Naming changed the montage'
    for key in ['music', 'adaptiveSoundtrack', 'originalAudioVolume', 'transitionItems', 'audioClips', 'width', 'height']:
        assert named.get(key) == timeline.get(key), 'Naming changed ' + key
    latest = copy.deepcopy(result)
    _, cached, cached_decisions = run('valid-title-cache', iteration, decisions)
    assert cached_decisions == decisions, 'Cache changed saved decision'
    assert rows[-1]['newModelCalls'] == 0
    # One source interval changes on the throwaway copy. Keep output timing fixed.
    edited = copy.deepcopy(result)
    item = edited['timelines'][-1]['items'][-1]
    item['sourceDuration'] = max(0.1, item['sourceDuration'] - 1 / named['frameRate'])
    item['speed'] = item['sourceDuration'] / item['timelineDuration']
    file.write_text(json.dumps(edited, ensure_ascii=False))
    _, changed, changed_decisions = run('one-part-source-interval-changed', iteration, decisions)
    affected = next(p['id'] for p in named['filmParts'] if item['id'] in p['itemIDs'])
    for decision in changed_decisions:
        if decision['partID'] != affected:
            assert decision == next(x for x in decisions if x['partID'] == decision['partID'])
# Leave the final unmodified montage with its cached titles for export and UI QA.
if latest is not None:
    file.write_text(json.dumps(latest, ensure_ascii=False))
