#!/usr/bin/env python3
"""Fresh automatic films on local, already analyzed archives; never edits originals.
Usage: validate-autopilot.py SOURCE.veloedit OUTPUT_DIRECTORY SECONDS [dynamic|cinematic]
Each invocation creates a new project with no timeline/plan/reference labels, runs
ordinary CLI film + render, and writes an independently checked JSON report.
"""
import hashlib, json, os, pathlib, shutil, subprocess, sys, time

source = pathlib.Path(sys.argv[1]).resolve()
out = pathlib.Path(sys.argv[2]).resolve()
seconds = float(sys.argv[3])
mood = sys.argv[4] if len(sys.argv) > 4 else 'dynamic'
assert mood in ('dynamic', 'cinematic') and seconds >= 10
assert not out.exists(), 'Choose a new output directory to preserve earlier evidence'
assert source != out and source not in out.parents
repo = pathlib.Path(__file__).resolve().parents[1]
cli = pathlib.Path(os.environ.get('VELOEDIT_VALIDATION_CLI', repo / 'Build/veloedit-cli')).resolve()
original = (source / 'project.json').read_bytes()
manifest = json.loads(original)
out.mkdir(parents=True)
package = out / 'automatic.veloedit'
package.mkdir()
for name in ('Analysis', 'EditorialEvidence', 'EditorialFrames', 'Proxies'):
    previous = source / 'Cache' / name
    if previous.exists():
        (package / 'Cache').mkdir(exist_ok=True)
        # APFS copy-on-write clones: no mutable symlinks into the source project.
        subprocess.run(['/bin/cp', '-cR', str(previous), str(package / 'Cache' / name)], check=True)
manifest['name'] = 'Automatic validation'
for key in ('timelines', 'storyPlans', 'renderJobs', 'events', 'timelineCheckpoints', 'preferenceSignals', 'musicCredits'):
    manifest[key] = []
for key in ('sourceMap', 'intentLedger', 'filmBuildRecovery', 'personalTasteProfile'):
    manifest.pop(key, None)
manifest['preferences'].pop('chapterTitleReference', None)
brief = dict(manifest.get('workspaceState', {}).get('directorBrief', {}))
brief.update(requestedDuration=seconds, mood=mood, musicPolicy='match-video', titlePolicy='key-only', sourceAudioPolicy='duck')
brief.pop('musicTrackID', None)
prompt = f'Сделай фильм на {seconds:g} секунд. Настроение: {"динамичное" if mood == "dynamic" else "киношное"}. Музыка: подобрать под видео. Звук исходников приглушить. Титры: названия каждой части и ключевых событий.'
manifest['workspaceState'] = dict(prompt=prompt, preset='adventure', directorBrief=brief, targetMinutes=seconds / 60, hasPendingFilmChanges=False, feedbackDraft='', directorDraft='', directorMessages=[], pendingDirectorInstructions=[])
(package / 'project.json').write_text(json.dumps(manifest, ensure_ascii=False))
report = dict(source=str(source), sourceSHA256=hashlib.sha256(original).hexdigest(), assets=len(manifest['assets']), analyzedCandidates=sum(len(a['candidates']) for a in manifest['analyses']), requestedSeconds=seconds, mood=mood, inputTimelineCount=0, sourceAnalysisReused=True, approvedChapterLabelsUsed=False, manualTimelineEdits=False, prompt=prompt, stages=[])
report['cli'] = str(cli)
report['cliSHA256'] = hashlib.sha256(cli.read_bytes()).hexdigest()
started = time.monotonic()

def save():
    report['elapsedSeconds'] = time.monotonic() - started
    report['originalUnchanged'] = (source / 'project.json').read_bytes() == original
    (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))

def run(stage, args):
    print(stage, flush=True)
    begin = time.monotonic()
    with (out / (stage + '.log')).open('w') as log:
        result = subprocess.run([str(cli), *args], stdout=log, stderr=subprocess.STDOUT)
    report['stages'].append(dict(name=stage, exitCode=result.returncode, seconds=time.monotonic() - begin))
    save()
    if result.returncode:
        raise RuntimeError(f'{stage} failed, see {out / (stage + ".log")}')

try:
    save()
    run('film', ['film', str(package), prompt])
    final = json.loads((package / 'project.json').read_text())
    timeline = final['timelines'][-1]
    primary = sorted([i for i in timeline['items'] if not i.get('overlay') and i['kind'] != 'title'], key=lambda i:i['timelineStart'])
    entries = final.get('sourceMap', {}).get('entries', [])
    ranks = {e['assetID']:n for n,e in enumerate(entries)}
    keys = [(ranks.get(i.get('assetID'), -1), i['sourceStart']) for i in primary]
    overlaps = []
    for n,left in enumerate(primary):
        for right in primary[n+1:]:
            if left.get('assetID') == right.get('assetID') and min(left['sourceStart'] + left['sourceDuration'], right['sourceStart'] + right['sourceDuration']) - max(left['sourceStart'], right['sourceStart']) > 2/30:
                overlaps.append([left['id'],right['id']])
    titles = [t for t in timeline.get('titleItems', []) if t.get('enabled',True)]
    selected_assets = {i.get('assetID') for i in primary}
    available_assets = {a['assetID'] for a in final['analyses'] if any(not c.get('excluded', False) and c['sourceDuration'] >= 1.5 and c['scores']['quality'] >= 0.55 for c in a['candidates'])}
    groups = [g for g in final.get('sourceMap', {}).get('activityGroups', []) if available_assets.intersection(g['assetIDs'])]
    report['activityCoverage'] = [dict(title=g['title'], order=g['order'], represented=bool(selected_assets.intersection(g['assetIDs']))) for g in groups]
    review = timeline.get('editorialReview', {})
    report.update(primaryCount=len(primary), titles=[dict(text=t['text'], start=t['startTime'], duration=t['duration'], font=t['style']['fontFamily'], size=t['style']['fontSize']) for t in titles], chronological=all(a<=b for a,b in zip(keys,keys[1:])), allSourcesRanked=all(k[0]>=0 for k in keys), overlappingSourceRanges=overlaps, neutralColor=all(i.get('videoAdjustments',{}).get('filter','none')=='none' for i in primary), telemetryCount=len(timeline.get('telemetryItems',[])), review=review, music=timeline.get('music'), adaptiveSoundtrack=timeline.get('adaptiveSoundtrack'))
    report['shots'] = [dict(file=next((a['displayName'] for a in final['assets'] if a['id']==i.get('assetID')),None), start=i['timelineStart'], sourceStart=i['sourceStart'], sourceDuration=i['sourceDuration'], duration=i['timelineDuration']) for i in primary]
    save()
    assert report['chronological'] and report['allSourcesRanked'], 'Source chronology failed'
    if seconds >= 12 * len(groups):
        assert all(g['represented'] for g in report['activityCoverage']), 'Usable later activities disappeared from a sufficiently long film'
    assert not overlaps, 'Repeated source footage'
    assert report['neutralColor'] and report['telemetryCount']==0
    assert titles and all(t['style']['fontFamily']=='Avenir Next' for t in titles)
    run('render', ['render', str(package), str(out / 'film.mp4')])
    report['status'] = 'rendered-awaiting-visual-review'
except Exception as error:
    report['status'] = 'failed'
    report['error'] = str(error)
    raise
finally:
    save()
