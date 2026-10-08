#!/usr/bin/env python3
"""Prepare a signed GitHub DMG and Sparkle appcast; never publish automatically."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from urllib.parse import quote
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
NAMESPACE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ACCOUNT = 'app.veloedit.VeloEdit'


def validate_appcast(path, dmg, tag):
    root = ET.parse(path).getroot()
    items = root.findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected exactly one update in this release feed')
    item = items[0]
    enclosure = item.find('enclosure')
    expected = f'https://github.com/007danlin/VeloEdit/releases/download/{quote(tag, safe="")}/{quote(dmg.name, safe="")}'
    if enclosure is None or enclosure.get('url') != expected:
        raise ValueError('Update URL does not match the GitHub release asset')
    if int(enclosure.get('length', '0')) != dmg.stat().st_size:
        raise ValueError('Update length does not match the DMG')
    signature = enclosure.get(f'{{{NAMESPACE}}}edSignature', '')
    if not re.fullmatch(r'[A-Za-z0-9+/]{86}==', signature):
        raise ValueError('Missing or invalid Ed25519 signature')
    version = item.findtext(f'{{{NAMESPACE}}}version') or enclosure.get(f'{{{NAMESPACE}}}version')
    if not version:
        raise ValueError('Missing Sparkle build version')
    return signature, version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dmg', required=True, type=Path)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'v[0-9][A-Za-z0-9._-]*', args.tag):
        parser.error('Use a version tag such as v0.1.1-beta.1')
    if not args.dmg.is_file() or args.dmg.suffix.lower() != '.dmg':
        parser.error('Expected an existing DMG from build-distribution.py')
    if args.output.exists():
        parser.error('Output directory already exists; use a new directory')
    cache = Path(os.environ.get('VELOEDIT_SCRATCH_PATH', str(Path.home() / 'Library/Caches/VeloEditBuild/swift-universal')))
    tools = cache / 'artifacts/sparkle/Sparkle/bin'
    if not (tools / 'generate_appcast').is_file():
        parser.error('Build VeloEdit first to install the pinned Sparkle tools')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.update-', dir=args.output.parent) as scratch:
        directory = Path(scratch)
        dmg = directory / f'VeloEdit_{args.tag.removeprefix("v")}_universal.dmg'
        shutil.copy2(args.dmg, dmg)
        feed = directory / 'appcast.xml'
        subprocess.run([str(tools / 'generate_appcast'), '--account', ACCOUNT,
                        '--maximum-deltas', '0', '--maximum-versions', '1',
                        '--download-url-prefix', f'https://github.com/007danlin/VeloEdit/releases/download/{quote(args.tag, safe="")}/',
                        '--link', 'https://veloedit.ru/',
                        '--full-release-notes-url', f'https://github.com/007danlin/VeloEdit/releases/tag/{quote(args.tag, safe="")}',
                        str(directory)], check=True)
        signature, version = validate_appcast(feed, dmg, args.tag)
        # Sparkle also checks that the signing key matches SUPublicEDKey inside the DMG.
        subprocess.run([str(tools / 'sign_update'), '--account', ACCOUNT, '--verify', str(dmg), signature], check=True)
        checksum = hashlib.file_digest(dmg.open('rb'), 'sha256').hexdigest()
        (directory / 'SHA256SUMS').write_text(f'{checksum}  {dmg.name}\n')
        (directory / 'update.json').write_text(json.dumps({'tag': args.tag, 'build': version,
          'asset': dmg.name, 'bytes': dmg.stat().st_size, 'sha256': checksum,
          'feed': 'https://github.com/007danlin/VeloEdit/releases/latest/download/appcast.xml'}, indent=2) + '\n')
        shutil.copytree(directory, args.output)
    print(f'Ready: {args.output}. Upload the DMG and appcast.xml to the same GitHub release.')


if __name__ == '__main__':
    main()
