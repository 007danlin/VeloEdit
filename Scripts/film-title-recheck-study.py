#!/usr/bin/env python3
"""Recheck a fixed saved timeline without replacing its plan or model answers.

Functional/repeat measurements only. This is not a create-film or GUI benchmark.
"""
import argparse,json,os,pathlib,subprocess,time,statistics
p=argparse.ArgumentParser();p.add_argument('--cli',type=pathlib.Path,required=True);p.add_argument('--project',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--count',type=int,default=1);a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=False);rows=[]
for index in range(a.count):
    env=dict(os.environ,VELOEDIT_TRACE_DIRECTORY=str((a.output/f'trace-{index}').resolve()))
    started=time.monotonic()
    with (a.output/f'run-{index}.log').open('w') as log:
        result=subprocess.run([str(a.cli.resolve()),'verify-film',str(a.project.resolve())],stdout=log,stderr=subprocess.STDOUT,env=env)
    elapsed=time.monotonic()-started
    manifest=json.loads((a.project/'project.json').read_text());timeline=manifest['timelines'][-1]
    report=timeline.get('filmDeliveryReport',{});checks=report.get('requirements',[])
    rows.append({'index':index,'seconds':elapsed,'exitCode':result.returncode,'passed':sum(x['passed'] for x in checks),'total':len(checks),
                 'requirements':checks,'signature':report.get('renderSignature'),'titleEvidence':report.get('exportVerification',{}).get('titleEvidence',[])})
    (a.output/'measurements.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
    print(index,round(elapsed,3),result.returncode,rows[-1]['passed'],rows[-1]['total'],flush=True)
    if result.returncode:raise SystemExit(result.returncode)
