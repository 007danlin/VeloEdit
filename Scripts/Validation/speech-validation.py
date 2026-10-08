#!/usr/bin/env python3
"""Local batch run; the worker is native. This development harness uploads nothing."""
import argparse, hashlib, json, pathlib, subprocess, time, re
p=argparse.ArgumentParser(); p.add_argument('folder',type=pathlib.Path); p.add_argument('--worker',type=pathlib.Path,default=pathlib.Path('.build/debug/VeloEditSpeechWorker')); p.add_argument('--output',type=pathlib.Path,default=pathlib.Path('Build/SpeechValidation/corpus')); args=p.parse_args()
args.output.mkdir(parents=True,exist_ok=True)
results=[]
for source in sorted(args.folder.iterdir()):
    if source.suffix.lower() not in ['.mov','.mp4','.wav','.m4a']:continue
    h=hashlib.sha256()
    with source.open('rb') as f:
        for block in iter(lambda:f.read(1048576),b''):h.update(block)
    dest=args.output/source.stem; dest.mkdir(exist_ok=True)
    req=dict(sourceURL=source.resolve().as_uri(),packageURL=pathlib.Path('Build/SpeechPackage').resolve().as_uri(),cacheURL=(dest/'chunks').resolve().as_uri(),outputURL=(dest/'transcript.json').resolve().as_uri(),locale='ru',sourceHash=h.hexdigest())
    request=dest/'request.json';request.write_text(json.dumps(req))
    start=time.monotonic()
    with (dest/'worker.log').open('w') as log:r=subprocess.run([str(args.worker.resolve()),str(request.resolve())],stdout=log,stderr=log)
    report=dict(source=source.name,sha256=h.hexdigest(),seconds=time.monotonic()-start,exitCode=r.returncode)
    if r.returncode==0:
        t=json.loads((dest/'transcript.json').read_text());report.update(status=t.get('status'),words=len(t['words']),sentences=len(t['sentences']),warnings=t.get('warnings',[]))
        (dest/'transcript.txt').write_text('\n'.join(f"[{s['startTime']:.2f}–{s['endTime']:.2f}] {s['text']}" for s in t['sentences'])+'\n')
    results.append(report); (args.output/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2));print(json.dumps(report,ensure_ascii=False),flush=True)
