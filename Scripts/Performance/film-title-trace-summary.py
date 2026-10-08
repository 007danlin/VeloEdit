#!/usr/bin/env python3
"""Summarize elapsed intervals without adding parallel work to wall time."""
import argparse, collections, json, pathlib, statistics
p=argparse.ArgumentParser();p.add_argument('directory',type=pathlib.Path);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
operations=[]
for path in sorted(a.directory.rglob('*.jsonl')):
    try: rows=[json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    except (ValueError,UnicodeError): continue
    if not rows or 'elapsed' not in rows[0]:continue
    starts={};stages=collections.defaultdict(list);pending={};caches=collections.Counter();events=collections.Counter()
    for row in rows:
        event=row.get('event','');f=row.get('fields',{});events[event]+=1
        if event=='span.begin':starts[f['span']]=row;pending[f['span']]=row
        elif event=='span.end' and f.get('span') in starts:
            begin=starts[f['span']];duration=row['elapsed']-begin['elapsed'];pending.pop(f['span'],None)
            stages[f.get('stage',begin['fields']['stage'])].append(duration)
        elif event=='cache.result':caches[(f.get('cache',''),f.get('result',''),f.get('reason',''))]+=1
    end=next((r for r in reversed(rows) if r.get('event')=='operation.end'),None)
    operations.append({'trace':str(path),'wallSeconds':end['elapsed'] if end else None,'status':end.get('fields',{}).get('status') if end else 'incomplete',
        'intervals':{k:{'count':len(v),'sumExecutionSecondsNotWallTime':sum(v),'medianSeconds':statistics.median(v),'maximumSeconds':max(v)} for k,v in stages.items()},
        'unclosedSpans':[r['fields'] for r in pending.values()], 'events':dict(events),
        'cache':[{'cache':k[0],'result':k[1],'reason':k[2],'count':v} for k,v in caches.items()]})
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(operations,ensure_ascii=False,indent=2))
