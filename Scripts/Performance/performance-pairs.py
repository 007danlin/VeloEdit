#!/usr/bin/env python3
"""Alternate baseline/current warm-cache analyses; preserve the supplied projects."""
import argparse, copy, json, os, pathlib, shutil, subprocess, time, urllib.request

def models():
    try:
        with urllib.request.urlopen('http://127.0.0.1:11434/api/ps', timeout=2) as r: return json.load(r)
    except Exception as e: return {'error': str(e)}

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--before-cli', type=pathlib.Path, required=True)
    p.add_argument('--after-cli', type=pathlib.Path, required=True)
    p.add_argument('--before-project', type=pathlib.Path, required=True)
    p.add_argument('--after-project', type=pathlib.Path, required=True)
    p.add_argument('--output', type=pathlib.Path, required=True)
    p.add_argument('--pairs', type=int, default=5)
    p.add_argument('--warm-model', help='Preload an already-installed model outside each timed warm run')
    args=p.parse_args(); args.output.mkdir(parents=True, exist_ok=False)
    projects={}
    for name in ('before','after'):
        package=args.output/(name+'.veloedit')
        shutil.copytree(getattr(args,name+'_project'),package)
        projects[name]=package
    rows=[]
    for pair in range(args.pairs):
        for label in (('before','after') if pair%2==0 else ('after','before')):
            project=projects[label]; manifest=json.loads((project/'project.json').read_text())
            manifest['analyses']=[]; manifest['analysisQueue']=[]
            (project/'project.json').write_text(json.dumps(manifest,ensure_ascii=False))
            warm_seconds=None
            if args.warm_model:
                started=time.monotonic()
                request=urllib.request.Request('http://127.0.0.1:11434/api/generate',data=json.dumps({'model':args.warm_model,'prompt':'','stream':False,'keep_alive':'10m'}).encode(),headers={'Content-Type':'application/json'})
                with urllib.request.urlopen(request,timeout=120) as response:
                    ready=json.load(response)
                    if ready.get('error'): raise RuntimeError(ready['error'])
                warm_seconds=time.monotonic()-started
            run_id=f'{pair+1}-{label}'; row={'pair':pair+1,'label':label,'modelsBefore':models(),'modelWarmupOutsideTimerSeconds':warm_seconds}
            row['power']=subprocess.run(['pmset','-g','batt'],capture_output=True,text=True).stdout
            row['thermal']=subprocess.run(['pmset','-g','therm'],capture_output=True,text=True).stdout
            env=dict(os.environ,VELOEDIT_TRACE_DIRECTORY=str((args.output/(run_id+'-traces')).resolve()))
            started=time.monotonic()
            with (args.output/(run_id+'.log')).open('w') as log:
                result=subprocess.run([str(getattr(args,label+'_cli').resolve()),'analyze',str(project.resolve())],stdout=log,stderr=subprocess.STDOUT,env=env)
            row.update(seconds=time.monotonic()-started,exitCode=result.returncode,modelsAfter=models(),analyses=json.loads((project/'project.json').read_text()).get('analyses',[]))
            rows.append(row); (args.output/'results.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
            print(json.dumps({k:row[k] for k in ('pair','label','seconds','exitCode')}),flush=True)
            if result.returncode: raise SystemExit(result.returncode)
if __name__=='__main__': main()
