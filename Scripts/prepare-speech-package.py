#!/usr/bin/env python3
"""Developer-only fetch of pinned speech assets; no Python runs in VeloEdit."""
import hashlib, json, pathlib, urllib.request, shutil, sys
root = pathlib.Path(__file__).resolve().parent.parent
manifest = json.loads((pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else root / 'Resources/Speech/package.json').read_text())
output = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'Build/SpeechPackage'
output.mkdir(parents=True, exist_ok=True)
for item in manifest['files']:
    dest = output / item['path']
    dest.parent.mkdir(parents=True, exist_ok=True)
    def digest(path):
        h = hashlib.sha256()
        with path.open('rb') as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b''): h.update(chunk)
        return h.hexdigest()
    if dest.exists() and digest(dest) == item['sha256']: continue
    partial = dest.with_suffix(dest.suffix + '.partial')
    offset = partial.stat().st_size if partial.exists() else 0
    request = urllib.request.Request(item['url'], headers={'Range': f'bytes={offset}-'} if offset else {})
    with urllib.request.urlopen(request, timeout=180) as response:
        mode = 'ab' if response.status == 206 and offset else 'wb'
        with partial.open(mode) as f: shutil.copyfileobj(response, f, 1024 * 1024)
    if partial.stat().st_size != item['bytes'] or digest(partial) != item['sha256']:
        partial.unlink(missing_ok=True)
        raise RuntimeError('Integrity failed: ' + item['path'])
    partial.replace(dest)
    print(item['path'], item['bytes'], flush=True)
(output / 'package.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('Verified', sum(f['bytes'] for f in manifest['files']), 'bytes', flush=True)
