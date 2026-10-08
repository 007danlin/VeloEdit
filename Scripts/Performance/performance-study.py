#!/usr/bin/env python3
"""Isolated, monotonic real-project measurements. Never opens the input for writing.

Example: python3 Scripts/Performance/performance-study.py --cli Build/veloedit-cli \
  --project Build/RequestFulfillment/test9.veloedit --label after --modes fast balanced
The OS file cache is not purged and models are not unloaded or downloaded.
"""
import argparse
import copy
import json
import pathlib
import os
import plistlib
import shutil
import subprocess
import time
import urllib.request

def ollama(endpoint):
    try:
        with urllib.request.urlopen('http://127.0.0.1:11434/api/' + endpoint, timeout=3) as response:
            return json.load(response)
    except Exception as error:
        return {'unavailable': str(error)}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cli', type=pathlib.Path, required=True)
    parser.add_argument('--project', type=pathlib.Path, required=True)
    parser.add_argument('--label', required=True)
    parser.add_argument('--modes', nargs='+', default=['fast', 'balanced', 'quality', 'maximum'])
    parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path('Build/Performance'))
    args = parser.parse_args()
    root = args.root.resolve() / args.label
    root.mkdir(parents=True, exist_ok=True)
    # Speech authorization requires a real bundle usage description. A naked
    # SwiftPM executable is killed by TCC before it can return an ASR result.
    bundle = root / 'PerformanceRunner.app'
    executable = bundle / 'Contents/MacOS/veloedit-cli'
    executable.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(args.cli.resolve(), executable)
    info = plistlib.loads(pathlib.Path('Resources/Info.plist').read_bytes())
    info['CFBundleExecutable'] = 'veloedit-cli'
    info['CFBundleIdentifier'] = 'app.veloedit.performance-runner'
    info['CFBundleName'] = 'VeloEdit Performance Runner'
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True)
    source = json.loads((args.project / 'project.json').read_text())
    for mode in args.modes:
        package = root / (mode + '.veloedit')
        package.mkdir()  # Never overwrite an earlier run, or a user's cache.
        manifest = copy.deepcopy(source)
        manifest['preferences']['aiPowerMode'] = mode
        for key in ['analyses', 'analysisQueue', 'timelines', 'storyPlans', 'timelineCheckpoints', 'renderJobs', 'events']:
            manifest[key] = []
        for key in ['sourceMap', 'filmBuildDraft', 'autonomousJob', 'workspaceState']:
            manifest.pop(key, None)
        (package / 'project.json').write_text(json.dumps(manifest, ensure_ascii=False))
        for cache in ['cold', 'warm']:
            # Repeat the same analysis, keeping only validated disk cache from the first run.
            if cache == 'warm':
                manifest = json.loads((package / 'project.json').read_text())
                manifest['analyses'] = []
                manifest['analysisQueue'] = []
                (package / 'project.json').write_text(json.dumps(manifest, ensure_ascii=False))
            row = dict(mode=mode, cache=cache, label=args.label, osCache='uncontrolled; paired order must be disclosed',
                       startedAt=time.time(), installedModels=ollama('tags'), loadedModelsBefore=ollama('ps'))
            start = time.monotonic()
            env = dict(os.environ, VELOEDIT_TRACE_DIRECTORY=str(root / (mode + '-' + cache + '-traces')))
            with (root / (mode + '-' + cache + '.log')).open('w') as log:
                run = subprocess.run([str(executable), 'analyze', str(package)], stdout=log, stderr=subprocess.STDOUT, env=env)
            row['wallSeconds'] = time.monotonic() - start
            row['exitCode'] = run.returncode
            row['loadedModelsAfter'] = ollama('ps')
            measured = json.loads((package / 'project.json').read_text())
            row['analyses'] = measured.get('analyses', [])
            (root / (mode + '-' + cache + '.json')).write_text(json.dumps(row, ensure_ascii=False, indent=2))
            print(json.dumps({k:row[k] for k in ['mode', 'cache', 'wallSeconds', 'exitCode']}), flush=True)
            if run.returncode:
                raise SystemExit(run.returncode)

if __name__ == '__main__':
    main()
