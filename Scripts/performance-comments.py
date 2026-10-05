#!/usr/bin/env python3
"""CLI apply+durable-save latency, deliberately not UI preview or model latency."""
import argparse,json,pathlib,shutil,subprocess,time,os
def canonical_analysis(value, key=None):
    # These fields are Swift Sets; enum-keyed roleScores is encoded as an
    # alternating key/value array. Their serialized order is not semantic.
    if isinstance(value, dict):
        return {k:canonical_analysis(v,k) for k,v in value.items()}
    if isinstance(value, list):
        if key in ('tags','sceneTags','streams') and all(isinstance(x,str) for x in value):
            return sorted(value)
        if key == 'roleScores':
            return {value[i]:value[i+1] for i in range(0,len(value),2)}
        return [canonical_analysis(x) for x in value]
    return value
p=argparse.ArgumentParser(); p.add_argument('--cli',type=pathlib.Path,required=True); p.add_argument('--project',type=pathlib.Path,required=True); p.add_argument('--output',type=pathlib.Path,required=True); p.add_argument('--count',type=int,default=30); args=p.parse_args()
args.output.mkdir(parents=True,exist_ok=False); package=args.output/'comments.veloedit'; package.mkdir()
shutil.copy2(args.project/'project.json',package/'project.json'); initial=json.loads((package/'project.json').read_text())
rows=[]
for index in range(args.count):
    percent=20+index%2; prompt=f'громкость музыки {percent}%'; start=time.monotonic()
    with (args.output/f'{index+1}.log').open('w') as log:
        result=subprocess.run([str(args.cli.resolve()),'edit',str(package.resolve()),prompt],stdout=log,stderr=subprocess.STDOUT)
    elapsed=time.monotonic()-start; saved=json.loads((package/'project.json').read_text())
    row={'index':index+1,'prompt':prompt,'applyAndSaveIncludingCLILaunchSeconds':elapsed,'exitCode':result.returncode,'sourceAnalysisPreserved':canonical_analysis(saved.get('analyses'))==canonical_analysis(initial.get('analyses')),'rawJSONAnalysisEqual':saved.get('analyses')==initial.get('analyses'),'savedMusic':saved['timelines'][-1].get('music')}; rows.append(row)
    (args.output/'results.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
    if result.returncode: raise SystemExit(result.returncode)
print(json.dumps({'samples':len(rows),'seconds':[r['applyAndSaveIncludingCLILaunchSeconds'] for r in rows]}))
