#!/usr/bin/env python3
"""Render four review candidates through the same native app compositor.

Requires the imported Base.veloedit demo and the measured 32–72 s timeline.
Does not change the user's project or the automatic subtitle default.
"""
import copy
import datetime
import json
import pathlib
import shutil
import subprocess
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'output/VlogStyles'
BASE = json.loads((OUT / 'Base.veloedit/project.json').read_text())
TIMELINE = json.loads((ROOT / 'Build/SpeechValidation/IMG_3747.sample.timeline.json').read_text())
SOURCE_START = 32.0
STYLES = [
    ('01-cinematic', 'Киношный', 'cinematic', 42, .48, '#F5F2EC'),
    ('02-vlog', 'Влог', 'vlog', 62, .84, '#FFFFFF'),
    ('03-travel', 'Путешествие', 'travel', 50, .58, '#FFF6E5'),
    ('04-social', 'Соцсети', 'social', 72, .92, '#FFFFFF'),
]


def remap(value, old, new):
    if isinstance(value, dict):
        return {k: remap(v, old, new) for k, v in value.items()}
    if isinstance(value, list):
        return [remap(v, old, new) for v in value]
    if isinstance(value, str):
        return value.replace(old, new)
    return value


def main():
    asset_id = BASE['assets'][0]['id']
    original_id = TIMELINE['items'][0]['assetID']
    reference = [(t['text'], t['startTime'], t['duration']) for t in TIMELINE['titleItems']]
    entries = []
    for slug, name, template, size, weight, color in STYLES:
        project = copy.deepcopy(BASE)
        project['id'] = str(uuid.uuid4()).upper()
        project['name'] = 'Субтитры — ' + name
        timeline = remap(copy.deepcopy(TIMELINE), original_id, asset_id)
        # The worker's diagnostic JSON uses Foundation's reference epoch;
        # persisted project manifests use ISO-8601.
        timeline['createdAt'] = datetime.datetime.fromtimestamp(
            timeline['createdAt'] + 978307200, datetime.timezone.utc
        ).strftime('%Y-%m-%dT%H:%M:%SZ')
        for title in timeline['titleItems']:
            title['templateID'] = 'caption.' + template + '.v1'
            title['kind'] = 'word-level-captions' if template == 'social' else 'automatic-subtitles'
            title['activeWordHighlighting'] = template == 'social'
            title['style'].update(fontSize=size, fontWeight=weight, fontFamily='Avenir Next',
                                  textColorHex=color, xPosition=.5, yPosition=.825,
                                  shadow=.5, strokeWidth=.6 if template == 'cinematic' else 0,
                                  lineSpacing=1.08, activeWordColorHex='#FFE269')
            title['animation'].update(entrance='scale' if template == 'social' else 'fade', exit='fade')
            title['words'] = []
            if template == 'social':
                for word in title['speechAnchor']['words']:
                    start = max(0, word['startTime'] - SOURCE_START - title['startTime'])
                    end = min(title['duration'], word['startTime'] + word['duration'] - SOURCE_START - title['startTime'])
                    if end > start:
                        title['words'].append(dict(id=str(uuid.uuid4()).upper(), word=word['text'], start=start, end=end))
        assert [(t['text'], t['startTime'], t['duration']) for t in timeline['titleItems']] == reference
        project['timelines'] = [timeline]
        package = OUT / (slug + '.veloedit')
        package.mkdir(exist_ok=True)
        (package / 'project.json').write_text(json.dumps(project, ensure_ascii=False, indent=2))
        video = OUT / (slug + '.mp4')
        if not video.exists():
            with (OUT / (slug + '.log')).open('w') as log:
                subprocess.run([str(ROOT / '.build/debug/veloedit-cli'), 'render', str(package), str(video)],
                               stdout=log, stderr=subprocess.STDOUT, check=True)
        entries.append(dict(name=name, video=str(video), project=str(package), templateID='caption.' + template + '.v1'))
        print(name + ': ' + str(video), flush=True)
    shutil.copyfile(ROOT / 'output/VlogSample/IMG_3747_00-32_01-12.srt', OUT / 'IMG_3747_00-32_01-12.srt')
    (OUT / 'comparison.json').write_text(json.dumps(dict(
        source=BASE['assets'][0]['originalURL'], sourceStart=32, sourceEnd=72, duration=40,
        automaticTextUnedited=True, timingIdentical=True, defaultSelected=False, styles=entries
    ), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
