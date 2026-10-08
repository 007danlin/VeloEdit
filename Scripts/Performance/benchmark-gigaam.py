#!/usr/bin/env python3
"""Research only. Local recordings never leave the machine; no pyannote/token.
Install the pinned upstream checkout separately. Production uses the Swift worker.
"""
import argparse, dataclasses, hashlib, json, pathlib, subprocess, time
import gigaam, torch
p=argparse.ArgumentParser();p.add_argument('source',type=pathlib.Path);p.add_argument('--start',type=float,default=0);p.add_argument('--duration',type=float,default=40);p.add_argument('--output',type=pathlib.Path,default=pathlib.Path('Build/GigaAMComparison'));args=p.parse_args()
args.output.mkdir(parents=True,exist_ok=True)
torch.set_num_threads(4)
start=time.monotonic();model=gigaam.load_model('v3_e2e_rnnt',device='cpu',download_root=str(args.output/'models'));load=time.monotonic()-start
results=[]
for offset in range(0,int(args.duration),20):
    audio=args.output/f'chunk-{offset:03}.wav';length=min(20,args.duration-offset)
    subprocess.run(['/opt/homebrew/bin/ffmpeg','-v','error','-y','-ss',str(args.start+offset),'-t',str(length),'-i',str(args.source),'-vn','-ac','1','-ar','16000',str(audio)],check=True)
    start=time.monotonic();value=model.transcribe(str(audio),word_timestamps=True)
    record=dict(offset=args.start+offset,text=value.text,words=[dict(text=w.text,start=w.start+args.start+offset,end=w.end+args.start+offset) for w in value.words or []],seconds=time.monotonic()-start)
    results.append(record);print(json.dumps(record,ensure_ascii=False),flush=True)
weights=[]
for file in (args.output/'models').iterdir():
    h=hashlib.sha256()
    with file.open('rb') as f:
        for block in iter(lambda:f.read(1048576),b''):h.update(block)
    weights.append(dict(name=file.name,sha256=h.hexdigest()))
(args.output/'result.json').write_text(json.dumps(dict(model='v3_e2e_rnnt',loadSeconds=load,weights=weights,results=results,torch=torch.__version__),ensure_ascii=False,indent=2))
