#!/usr/bin/env python3
"""Explicit, preparation-only Melies audit. Never invoked by VeloEdit at runtime.

Fetches text only (no illustrations/video). The scratch extraction is input to
human/agent curation, not the distributable knowledge base. No generated prompts,
advertising, navigation or full HTML are retained. Run explicitly to update.
"""
import argparse
import concurrent.futures
import hashlib
import html
import json
import re
import subprocess
from pathlib import Path

BASE = "https://melies.co"


def fetch(path):
    return subprocess.check_output([
        "curl", "-sSL", "--fail", "--retry", "2", "--max-time", "45",
        "-A", "Mozilla/5.0", BASE + path,
    ]).decode("utf-8")


def plain(value):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", value))).strip()


def extract(entry):
    path, name = entry
    body = fetch(path)
    content = body[body.index("<h1"):]
    sections = {}
    pieces = re.split(r"<h2\b[^>]*>(.*?)</h2>", content, flags=re.S)
    for i in range(1, len(pieces), 2):
        heading = plain(pieces[i])
        if heading in ["Narrative function", "How it works", "When to use it",
                       "Compared with similar shots", "What usually goes wrong"]:
            paragraphs = re.findall(r"<p\b[^>]*>(.*?)</p>", pieces[i + 1], re.S)
            # Prompt instructions embedded in prose are not editorial knowledge.
            sections[heading] = [plain(p) for p in paragraphs if not re.search(
                r"\b(prompt|generate|generator)\b", plain(p), re.I)]
    return {"id": path.rsplit("/", 1)[-1], "name": name,
            "category": path.split("/")[2], "source": BASE + path,
            "retrievedOn": "2026-10-09", "sha256": hashlib.sha256(body.encode()).hexdigest(),
            "sections": sections}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    index = fetch("/cinematic-techniques")
    entries = dict((u, plain(n)) for u, n in re.findall(
        r'<a[^>]*href="(/cinematic-techniques/[^"?]+/[^"?]+)"[^>]*>(.*?)</a>', index, re.S))
    existing = {e["source"].removeprefix(BASE): e for e in json.loads(args.output.read_text())} if args.output.exists() else {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        pending = {pool.submit(extract, e): e for e in entries.items() if e[0] not in existing}
        for future in concurrent.futures.as_completed(pending):
            result = future.result()
            existing[result["source"].removeprefix(BASE)] = result
            args.output.write_text(json.dumps(list(existing.values()), ensure_ascii=False, indent=2))
            if len(existing) % 40 == 0:
                print(f"Read {len(existing)}/{len(entries)}", flush=True)
    assert set(entries) == set(existing), "Incomplete source audit"
    print(f"All {len(existing)} cards read. Curate before distributing.")


if __name__ == "__main__":
    main()
