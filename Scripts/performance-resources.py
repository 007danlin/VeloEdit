#!/usr/bin/env python3
"""Read-only one-second process sampling; estimates, not GPU/peak-memory proof."""
import argparse
import json
import subprocess
import time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--until-pid', type=int, required=True)
p.add_argument('--output', type=Path, required=True)
args = p.parse_args()
with args.output.open('x') as stream:
    index = 0
    while subprocess.run(['ps', '-p', str(args.until_pid)], stdout=subprocess.DEVNULL).returncode == 0:
        records = []
        snapshot = subprocess.run(['ps', '-axo', 'pid=,pcpu=,rss=,comm='], capture_output=True, text=True).stdout
        for line in snapshot.splitlines():
            fields = line.strip().split(None, 3)
            if len(fields) == 4 and ('ollama' in fields[3].lower() or fields[3].endswith('/veloedit-cli')):
                records.append(dict(pid=int(fields[0]), cpuPercent=float(fields[1]), rssKiB=int(fields[2]), process=fields[3]))
        row = dict(epoch=time.time(), monotonic=time.monotonic(), processes=records)
        if index % 10 == 0:
            for key, command in [('vm', ['vm_stat']), ('thermal', ['pmset', '-g', 'therm'])]:
                row[key] = subprocess.run(command, capture_output=True, text=True).stdout
        stream.write(json.dumps(row) + '\n')
        stream.flush()
        index += 1
        time.sleep(1)
