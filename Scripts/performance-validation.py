#!/usr/bin/env python3
"""Serial acceptance measurements after performance-study.py has completed."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

p = argparse.ArgumentParser()
p.add_argument('--wait-pid', type=int)
p.add_argument('--skip-high', action='store_true', help='Disclose and skip high modes blocked by TCC/model availability')
args = p.parse_args()
root = Path.cwd()
reports = root / 'Docs/Validation/Performance'
if args.wait_pid:
    while subprocess.run(['ps', '-p', str(args.wait_pid)], stdout=subprocess.DEVNULL).returncode == 0:
        time.sleep(5)
required = root / ('Build/Performance/after-current/balanced-warm.json' if args.skip_high else 'Build/Performance/after-current/maximum-warm.json')
if not required.exists() or json.loads(required.read_text())['exitCode']:
    raise SystemExit('The required current-build run did not finish successfully.')

rows = []
def run(name, command, extra_env=None):
    started = time.monotonic()
    env = dict(os.environ, **(extra_env or {}))
    with (reports / (name + '.log')).open('w') as log:
        result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT)
    row = dict(stage=name, seconds=time.monotonic()-started, exitCode=result.returncode)
    rows.append(row)
    (reports / 'validation-stages.json').write_text(json.dumps(rows, indent=2))
    print(json.dumps(row), flush=True)
    return result.returncode

baseline = 'Build/Performance/baseline-swift/out/Products/Release/veloedit-cli'
current = 'Build/veloedit-cli'
if not args.skip_high:
    run('baseline-high-fixed', ['python3', 'Scripts/performance-study.py', '--cli', baseline,
        '--project', 'Build/RequestFulfillment/test9.veloedit', '--label', 'before-high-fixed',
        '--modes', 'quality', 'maximum'])
for mode, model in [('fast', 'qwen3-vl:2b-instruct'), ('balanced', 'qwen3-vl:4b-instruct')]:
    run('paired-' + mode, ['python3', 'Scripts/performance-pairs.py', '--before-cli', baseline,
        '--after-cli', current, '--before-project', f'Build/Performance/before-valid/{mode}.veloedit',
        '--after-project', f'Build/Performance/after-current/{mode}.veloedit',
        '--output', f'Build/Performance/paired-{mode}', '--pairs', '5', '--warm-model', model])

helper = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper'
test_env = dict(
    DYLD_FRAMEWORK_PATH='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks',
    DYLD_LIBRARY_PATH='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib',
    VELOEDIT_OVRLEY_BRIDGE=str(root / 'Build/VeloEdit.app/Contents/MacOS/VeloEditOVRLEY'))
request = urllib.request.Request('http://127.0.0.1:11434/api/generate',
    data=json.dumps(dict(model='qwen3:4b-instruct', prompt='', stream=False, keep_alive='15m')).encode(),
    headers={'Content-Type': 'application/json'})
try:
    with urllib.request.urlopen(request, timeout=120) as response:
        (reports / 'director-preload.json').write_bytes(response.read())
except Exception as error:
    (reports / 'director-preload-error.txt').write_text(str(error))
for label, scratch in [('before', 'Build/Performance/baseline-swift'), ('after', 'Build/Cache/swift')]:
    env = dict(test_env, VELOEDIT_DIRECTOR_STUDY_OUTPUT=str(reports / f'director-{label}.json'))
    bundle = str(root / scratch / 'out/Products/Debug/VeloEditAppTests.xctest/Contents/MacOS/VeloEditAppTests')
    run('director-' + label, [helper, '--test-bundle-path', bundle, '--testing-library', 'swift-testing',
        '--filter', 'measureExactDirectorCommandLatencyAndAccuracy'], env)
    run('apply-save-' + label, ['python3', 'Scripts/performance-comments.py', '--cli', baseline if label == 'before' else current,
        '--project', 'Build/RequestFulfillment/test9.veloedit', '--output', f'Build/Performance/apply-save-{label}'])

env = dict(test_env, VELOEDIT_SEQUENCE_STUDY=str(root / 'Build/RequestFulfillment/test9.veloedit/project.json'),
    VELOEDIT_SEQUENCE_STUDY_OUTPUT=str(reports / 'sequence-pairs.json'))
run('sequence-pairs', [helper, '--test-bundle-path', str(root / 'Build/Cache/swift/out/Products/Debug/VeloEditCoreTests.xctest/Contents/MacOS/VeloEditCoreTests'),
    '--testing-library', 'swift-testing', '--filter', 'measureRealSequenceSearchAgainstOriginalAlgorithm'], env)
run('real-film', ['python3', 'Scripts/performance-film.py', '--cli', current,
    '--analyzed-project', 'Build/Performance/after-current/balanced.veloedit',
    '--reference-project', 'Build/RequestFulfillment/test9.veloedit', '--output', 'Build/Performance/real-film'])
