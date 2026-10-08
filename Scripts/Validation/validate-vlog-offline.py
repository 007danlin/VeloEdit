#!/usr/bin/env python3
"""Exercise the actual CLI/pipeline against bundled native speech assets offline."""
import json,pathlib,subprocess,time
root=pathlib.Path(__file__).resolve().parents[2]
folder=root/'Build/SpeechValidation';project=folder/'OfflineProject.veloedit';cli=folder/'Smoke.app/Contents/MacOS/veloedit-cli';manifest=project/'project.json'
results=[]
# Keep only one heavy inference process active during the long-file experiment.
deadline=time.monotonic()+1800
while True:
 p=folder/'offline/results.json'
 data=json.loads(p.read_text()) if p.exists() else []
 if any(x['source']=='repeated-voice-60min.m4a' for x in data):break
 if time.monotonic()>deadline:raise RuntimeError('Long-file experiment did not finish; refusing parallel inference')
 time.sleep(1)
def call(name,*args):
 start=time.monotonic()
 with (folder/(name+'.log')).open('w') as log:
  r=subprocess.run(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(cli),*map(str,args)],stdout=log,stderr=log)
 if r.returncode:raise RuntimeError(name+' failed: '+str(r.returncode))
 return time.monotonic()-start
for mode in ['none','match-video','specific-track']:
 m=json.loads(manifest.read_text());brief=m['workspaceState']['directorBrief'];brief['musicPolicy']=mode
 if mode=='specific-track':
  call('import-local-track','import',project,folder/'fixtures/local-music.m4a')
  # Read the project-local music library, not a global user collection.
  candidates=list((project/'Music').rglob('*.json'))+list((project/'MusicLibrary').rglob('*.json'))
  tracks=[]
  for f in candidates:
   try:
    value=json.loads(f.read_text());tracks.extend(value if isinstance(value,list) else value.get('tracks',[]))
   except (ValueError,AttributeError):pass
  if not tracks:raise RuntimeError('Imported local soundtrack not found')
  brief['musicTrackID']=tracks[-1]['id']
 m['workspaceState']['directorBrief']=brief;manifest.write_text(json.dumps(m,ensure_ascii=False,indent=2))
 seconds=call('film-'+mode,'film',project,'Стиль: Влог')
 result=json.loads(manifest.read_text());timeline=result['timelines'][-1]
 results.append(dict(musicPolicy=mode,seconds=seconds,clips=len(timeline['items']),captions=len(timeline.get('titleItems',[])),speechSources=len(timeline.get('speechRecords',[])),music=timeline.get('music'),warnings=timeline.get('filmDeliveryReport',{}).get('warnings')))
 (folder/'offline-pipeline-results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2));print(json.dumps({k:v for k,v in results[-1].items() if k!='music'},ensure_ascii=False),flush=True)
