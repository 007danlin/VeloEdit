import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('update_feed', ROOT / 'Scripts/validate-update-feed.py')
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)
URL = 'https://github.com/007danlin/VeloEdit/releases/download/v1.0.0/VeloEdit.dmg'
SIGNATURE = base64.b64encode(bytes(64)).decode()


class UpdateFeedTests(unittest.TestCase):
    def check(self, url=URL, size=100, signature=SIGNATURE, version='5', prerelease=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'appcast.xml'
            path.write_text(f'<rss xmlns:sparkle="{feed.NS[1:-1]}"><channel><item><sparkle:version>{version}</sparkle:version><enclosure url="{url}" length="{size}" sparkle:edSignature="{signature}"/></item></channel></rss>')
            feed.validate(path, {'prerelease':prerelease,'assets':[{'name':'VeloEdit.dmg','size':100,'browser_download_url':URL}]})

    def test_release_matches_exact_installer(self):
        self.check()

    def test_rejects_wrong_host_or_changed_archive(self):
        for overrides in ({'url':'https://example.com/VeloEdit.dmg'}, {'size':99}, {'signature':''}, {'version':''}, {'prerelease':True}):
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                self.check(**overrides)
