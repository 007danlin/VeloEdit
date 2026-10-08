#!/usr/bin/env python3
"""Build and independently verify an exported film in an isolated project copy."""
import argparse,json,pathlib,shutil,subprocess,time,os
p=argparse.ArgumentParser();p.add_argument('--cli',type=pathlib.Path,required=True);p.add_argument('--analyzed-project',type=pathlib.Path,required=True);p.add_argument('--reference-project',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);args=p.parse_args()
args.output.mkdir(parents=True,exist_ok=False); project=args.output/'film.veloedit';shutil.copytree(args.analyzed_project,project)
reference=json.loads((args.reference_project/'project.json').read_text());manifest=json.loads((project/'project.json').read_text());manifest['workspaceState']=reference.get('workspaceState',{});manifest['workspaceState'].pop('selectedTimelineItemID',None)
(project/'project.json').write_text(json.dumps(manifest,ensure_ascii=False));prompt=reference['storyPlans'][-1]['prompt'];rows=[]
for command in (['film',str(project.resolve()),prompt],['save-video',str(project.resolve())],['verify',str(project.resolve())]):
 stage=command[0];env=dict(os.environ,VELOEDIT_TRACE_DIRECTORY=str((args.output/(stage+'-traces')).resolve()));started=time.monotonic()
 with (args.output/(stage+'.log')).open('w') as log: result=subprocess.run([str(args.cli.resolve()),*command],stdout=log,stderr=subprocess.STDOUT,env=env)
 rows.append({'stage':stage,'seconds':time.monotonic()-started,'exitCode':result.returncode});(args.output/'measurements.json').write_text(json.dumps(rows,indent=2));print(rows[-1],flush=True)
 if result.returncode:raise SystemExit(result.returncode)
