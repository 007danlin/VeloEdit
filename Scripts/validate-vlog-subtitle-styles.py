#!/usr/bin/env python3
"""Use the real offline pipeline to verify saved per-film caption choices."""
import json
import pathlib
import subprocess
import time

root = pathlib.Path(__file__).resolve().parent.parent
folder = root / 'Build/SpeechValidation'
project = folder / 'OfflineProject.veloedit'
cli = folder / 'Smoke.app/Contents/MacOS/veloedit-cli'
manifest = project / 'project.json'
rows = []
for style in ['vlog', 'travel', 'social']:
    value = json.loads(manifest.read_text())
    brief = value['workspaceState']['directorBrief']
    brief.update(subtitleStyle=style, subtitlePolicy='on', musicPolicy='none')
    manifest.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    start = time.monotonic()
    with (folder / ('style-' + style + '.log')).open('w') as log:
        subprocess.run(['/usr/bin/sandbox-exec', '-p', '(version 1)(allow default)(deny network*)',
                        str(cli), 'film', str(project), 'Стиль: Влог'], stdout=log, stderr=log, check=True, timeout=120)
    timeline = json.loads(manifest.read_text())['timelines'][-1]
    titles = [t for t in timeline['titleItems'] if t.get('speechAnchor')]
    assert titles and all(t['templateID'] == 'caption.' + style + '.v1' for t in titles)
    assert all(t['activeWordHighlighting'] == (style == 'social') for t in titles)
    if style == 'social':
        assert any(t['words'] for t in titles)
    rows.append(dict(style=style, seconds=time.monotonic() - start,
                     captions=len(titles), measuredWords=sum(len(t['words']) for t in titles),
                     warnings=timeline.get('filmDeliveryReport', {}).get('warnings', [])))
    print(json.dumps(rows[-1], ensure_ascii=False), flush=True)
(folder / 'subtitle-style-results.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2))
