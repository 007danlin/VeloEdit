#!/usr/bin/env python3
"""Decode every exported video frame and audio sample; log technical flags.

Flags require review (a photograph can legitimately be still, a fade black).
This is not a human full-film review or a claim of artistic quality.
"""
import argparse
import json
import pathlib
import re
import subprocess
import time


def inspect(video, destination):
    destination.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    probe = subprocess.run(['ffprobe', '-v', 'error', '-show_format', '-show_streams',
                            '-of', 'json', str(video)], capture_output=True, text=True)
    if probe.returncode:
        raise RuntimeError(probe.stderr)
    info = json.loads(probe.stdout)
    command = ['ffmpeg', '-hide_banner', '-nostdin', '-nostats', '-xerror', '-v', 'info', '-i', str(video),
               '-map', '0:v:0', '-map', '0:a:0?',
               '-vf', 'scale=320:-2,blackdetect=d=0.15:pic_th=0.98:pix_th=0.03,freezedetect=n=-50dB:d=2',
               '-af', 'ebur128=peak=true', '-progress', 'pipe:1', '-f', 'null', '-']
    with (destination/'full-decode.log').open('w') as log:
        run = subprocess.run(command, stdout=subprocess.PIPE, stderr=log, text=True)
    (destination/'decode-progress.txt').write_text(run.stdout)
    log = (destination/'full-decode.log').read_text()
    black = [dict(start=float(a), end=float(b), duration=float(c)) for a,b,c in
             re.findall(r'black_start:([\d.]+) black_end:([\d.]+) black_duration:([\d.]+)', log)]
    freezes = [dict(event=a, time=float(b)) for a,b in re.findall(r'(freeze_start|freeze_duration|freeze_end): ([\d.]+)', log)]
    frames = re.findall(r'^frame=(\d+)', run.stdout, flags=re.M)
    audio = re.findall(r'I:\s+(-?[\d.]+) LUFS.*?LRA:\s+([\d.]+) LU.*?Peak:\s+(-?[\d.]+) dBFS', log.rsplit('Summary:',1)[-1], flags=re.S)
    result = dict(file=str(video.resolve()), elapsedSeconds=time.monotonic()-started,
                  command=command, exitCode=run.returncode, streams=info['streams'], format=info['format'],
                  decodedVideoFrames=int(frames[-1]) if frames else None,
                  fullDecodeCompleted=run.returncode==0 and 'progress=end' in run.stdout,
                  blackIntervals=black, freezeEvents=freezes,
                  loudness=dict(zip(['integratedLUFS','rangeLU','truePeakDBFS'],map(float,audio[-1]))) if audio else None,
                  scope='All frames and audio decoded automatically; perceptual and semantic review separate.',
                  humanFullPlaybackReview=False)
    (destination/'technical-report.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    return result


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('video',type=pathlib.Path)
    p.add_argument('output',type=pathlib.Path)
    args=p.parse_args()
    result=inspect(args.video,args.output)
    print(json.dumps({k:result[k] for k in ['file','fullDecodeCompleted','decodedVideoFrames','blackIntervals','freezeEvents','loudness']},ensure_ascii=False))
