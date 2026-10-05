#!/usr/bin/env python3
"""Offline native-worker checks; generated fixture audio never leaves the Mac."""
import argparse,hashlib,json,pathlib,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--worker',type=pathlib.Path,required=True);p.add_argument('--package',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,default=pathlib.Path('Build/SpeechValidation/offline'));p.add_argument('sources',type=pathlib.Path,nargs='+');args=p.parse_args()
args.output.mkdir(parents=True,exist_ok=True);reports=[]
for source in args.sources:
 folder=args.output/source.stem;folder.mkdir(exist_ok=True)
 h=hashlib.sha256()
 with source.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 request=dict(sourceURL=source.resolve().as_uri(),packageURL=args.package.resolve().as_uri(),cacheURL=(folder/'chunks').resolve().as_uri(),outputURL=(folder/'transcript.json').resolve().as_uri(),locale='ru',sourceHash=h.hexdigest())
 file=folder/'request.json';file.write_text(json.dumps(request))
 command=['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(args.worker.resolve()),str(file.resolve())]
 start=time.monotonic()
 with (folder/'worker.log').open('w') as log:
  process=subprocess.Popen(command,stdout=log,stderr=log)
  # The long-file test deliberately stops after completed chunks, then resumes.
  if '60min' in source.name:
   deadline=time.monotonic()+300
   while process.poll() is None and time.monotonic()<deadline and len(list((folder/'chunks').glob('*.sha256')))<3:time.sleep(.25)
   completed=len(list((folder/'chunks').glob('*.sha256')))
   if process.poll() is None:
    cancel=time.monotonic();process.terminate()
    try:process.wait(timeout=4)
    except subprocess.TimeoutExpired:process.kill();process.wait()
    (folder/'cancel.json').write_text(json.dumps(dict(seconds=time.monotonic()-cancel,completedChunks=completed)))
    process=subprocess.Popen(command,stdout=log,stderr=log)
  code=process.wait()
 report=dict(source=source.name,exitCode=code,seconds=time.monotonic()-start,network='deny network*')
 if code==0:
  t=json.loads((folder/'transcript.json').read_text());report.update(status=t.get('status'),words=len(t['words']),sentences=len(t['sentences']),metrics=t.get('runtimeMetrics'),warnings=len(t.get('warnings',[])))
 reports.append(report);(args.output/'results.json').write_text(json.dumps(reports,ensure_ascii=False,indent=2));print(json.dumps(report,ensure_ascii=False),flush=True)
