#!/usr/bin/env python3
"""Contact sheets from actual MP4s, labelled as sampled visual evidence."""
import argparse
import json
import pathlib
import subprocess
from PIL import Image, ImageDraw

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('video',type=pathlib.Path)
p.add_argument('project',type=pathlib.Path)
p.add_argument('output',type=pathlib.Path)
args=p.parse_args();args.output.mkdir(parents=True,exist_ok=True)
project=json.loads((args.project/'project.json').read_text());timeline=project['timelines'][-1]
items=sorted([i for i in timeline['items'] if not i.get('overlay') and i['kind']!='title'],key=lambda i:i['timelineStart'])
duration=max(i['timelineStart']+i['timelineDuration'] for i in items)
times={0.1,max(0,duration-0.1),max(0,duration-3.5)}
for item in items:
    start=item['timelineStart'];end=start+item['timelineDuration']
    times|={min(duration-.05,start+.15),(start+end)/2,max(0,end-.15)}
times=sorted(t for t in times if 0<=t<duration)
for page in range((len(times)+23)//24):
    selected=times[page*24:(page+1)*24]
    sheet=Image.new('RGB',(1280,((len(selected)+3)//4)*206),'#121212');draw=ImageDraw.Draw(sheet)
    for index,t in enumerate(selected):
        path=args.output/f'frame-{t:.3f}.jpg'
        subprocess.run(['ffmpeg','-v','error','-ss',str(t),'-i',str(args.video),'-frames:v','1',
                        '-vf','scale=320:180:force_original_aspect_ratio=decrease,pad=320:180:(ow-iw)/2:(oh-ih)/2',
                        '-y',str(path)],check=True)
        x,y=(index%4)*320,(index//4)*206;sheet.paste(Image.open(path),(x,y))
        item=next((i for i in reversed(items) if i['timelineStart']<=t),items[0])
        asset=next((a for a in project['assets'] if a['id']==item.get('assetID')),None)
        text=f"{t:.2f}s | {asset['displayName'] if asset else '?'}"
        draw.text((x+4,y+183),text,fill='white')
    sheet.save(args.output/f'samples-{page+1}.jpg')
(args.output/'sampling.json').write_text(json.dumps(dict(video=str(args.video.resolve()),times=times,
    type='sampled visual review of actual export; not full-film viewing'),indent=2))
print(f'{len(times)} sampled frames; {(len(times)+23)//24} pages')
