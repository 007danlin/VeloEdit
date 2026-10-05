#!/usr/bin/env python3
"""Compare persisted frame unions and exact JPEGs; not a complete adaptive-plan proof."""
import argparse,pathlib,json,plistlib,hashlib,base64,math
p=argparse.ArgumentParser();p.add_argument('--before',type=pathlib.Path,required=True);p.add_argument('--after',type=pathlib.Path,required=True);p.add_argument('--size',type=int,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
assets=json.loads((a.before/'project.json').read_text())['assets']; hashes=[x['contentHash'] for x in assets]
def fnv(s):
 v=14695981039346656037
 for b in s.encode():v=((v^b)*1099511628211)&((1<<64)-1)
 return format(v,'x')
def ms(t):return math.floor(t*1000+0.5)
def sha(b):return hashlib.sha256(b).hexdigest()
old={};new={}
for path in (a.before/'Cache/Frames').glob('*.frame.json'):
 s=json.loads(path.read_text())['sample']
 for h in hashes:
  key=(h,ms(s['timestamp']))
  if path.name==fnv(f'{h}|{key[1]}|{a.size}')+'.frame.json': old[key]=sha(base64.b64decode(s['jpegBase64']))
for path in (a.after/'Cache/Frames').glob('*.frame-v2.bin'):
 raw=path.read_bytes();assert hashlib.sha256(raw[32:]).digest()==raw[:32]
 d=plistlib.loads(raw[32:]);s=d['sample']
 for h in hashes:
  if h in d['identity'] and d['identity'].endswith(f'|{a.size}|preferred-transform|tol=150/600|jpeg=.68|vision-v2'):
   new.setdefault((h,ms(s['timestamp'])),set()).add(sha(d.get('jpeg') or base64.b64decode(s['jpegBase64'])))
common=old.keys() & new.keys()
report={'kind':'Persisted frame union at legacy millisecond keys; does not assert full adaptive-plan equivalence','oldUnion':len(old),'newUnion':len(new),'common':len(common),'commonExactJPEG':sum(old[k] in new[k] for k in common),'missingOriginalTimes':[list(k) for k in old.keys()-new.keys()],'additionalTimes':[list(k) for k in new.keys()-old.keys()],'changedJPEGs':[list(k) for k in common if old[k] not in new[k]]}
a.output.write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if not isinstance(v,list)}))
