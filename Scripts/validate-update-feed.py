#!/usr/bin/env python3
"""Validate a release appcast before deploying it to GitHub Pages."""
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET
from urllib.parse import urlparse

NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def validate(feed, release):
    items = ET.parse(feed).findall('./channel/item')
    if len(items) != 1 or release.get('draft') or release.get('prerelease'):
        raise ValueError('Expected one signed update for a published release')
    item = items[0]
    enclosure = item.find('enclosure')
    if enclosure is None:
        raise ValueError('Missing update enclosure')
    url = enclosure.get('url', '')
    parsed = urlparse(url)
    if parsed.scheme != 'https' or parsed.netloc != 'github.com' or not parsed.path.startswith('/007danlin/VeloEdit/releases/download/'):
        raise ValueError('Unexpected update host or repository')
    asset = next((a for a in release.get('assets', []) if a.get('browser_download_url') == url and a.get('name', '').lower().endswith('.dmg')), None)
    if not asset or int(enclosure.get('length', '0')) != asset.get('size') or not asset.get('size'):
        raise ValueError('Appcast must describe the exact DMG attached to this release')
    if not re.fullmatch(r'[A-Za-z0-9+/]{86}==', enclosure.get(NS + 'edSignature', '')):
        raise ValueError('Missing Ed25519 update signature')
    if not (item.findtext(NS + 'version') or enclosure.get(NS + 'version')):
        raise ValueError('Missing build version')


if __name__ == '__main__':
    validate(Path(sys.argv[1]), json.loads(Path(sys.argv[2]).read_text()))
    print('Release feed matches its signed GitHub DMG.')
