"""Regression checks for distribution failures that must not be called releases."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("distribution", ROOT / "Scripts/build-distribution.py")
distribution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribution)
signing = distribution.signer()


class DistributionTests(unittest.TestCase):
    def test_apple_development_certificate_is_not_a_developer_id(self):
        fingerprint = "A" * 40
        result = subprocess.CompletedProcess([], 0, f'1) {fingerprint} "Apple Development: Example"\n', "")
        with patch.object(signing.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(ValueError, "Developer ID Application"):
                signing.developer_identity(fingerprint)

    def test_matching_developer_id_can_be_selected_by_exact_name(self):
        fingerprint = "A" * 40
        name = "Developer ID Application: Example (TEAMID)"
        result = subprocess.CompletedProcess([], 0, f'1) {fingerprint} "{name}"\n', "")
        with patch.object(signing.subprocess, "run", return_value=result):
            self.assertEqual(signing.developer_identity(name), fingerprint)
            with self.assertRaises(ValueError):
                signing.developer_identity("Example")

    def test_notary_rejection_raises_and_retains_diagnostics(self):
        response = subprocess.CompletedProcess([], 0, json.dumps({"id": "test-id", "status": "Invalid"}), "")
        with tempfile.TemporaryDirectory() as scratch, patch.object(distribution, "run", return_value=response) as run:
            logs = Path(scratch)
            with self.assertRaisesRegex(ValueError, "No release published"):
                distribution.notarize(Path("VeloEdit.dmg"), "test-profile", logs)
            self.assertEqual(json.loads((logs / "VeloEdit.dmg.notary.json").read_text())["status"], "Invalid")
            self.assertEqual(run.call_args_list[1].args[:3], ("xcrun", "notarytool", "log"))

    def test_notary_timeout_is_not_acceptance(self):
        failure = subprocess.CalledProcessError(1, ["notarytool"], output='{"id":"pending"}', stderr="timeout")
        with tempfile.TemporaryDirectory() as scratch, patch.object(distribution, "run", side_effect=failure):
            logs = Path(scratch)
            with self.assertRaisesRegex(ValueError, "timed out"):
                distribution.notarize(Path("VeloEdit.zip"), "test-profile", logs)
            self.assertIn("pending", (logs / "VeloEdit.zip.notary-error.txt").read_text())

    def test_nested_code_in_resources_is_discovered_without_following_symlinks(self):
        with tempfile.TemporaryDirectory() as scratch:
            app = Path(scratch)
            nested = app / "Contents/Resources/Engine/runtime"
            nested.parent.mkdir(parents=True)
            nested.write_bytes(bytes.fromhex("cffaedfe") + b"test")
            (nested.parent / "alias").symlink_to(nested.name)
            (nested.parent / "data").write_bytes(b"not code")
            self.assertEqual(list(signing.code_files(app)), [nested])

    def test_review_flags_without_evidence_do_not_allow_a_release(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / "Resources/Legal").mkdir(parents=True)
            (root / "Resources/Legal/publisher.json").write_text('{"copyright_holder":"Example"}')
            (root / "Distribution").mkdir()
            (root / "Distribution/legal-review.json").write_text(json.dumps({
                key: {"status": "approved", "evidence": "missing.md"} for key in distribution.REVIEWS
            }))
            with patch.object(distribution, "ROOT", root), patch.object(distribution, "signer") as signer:
                signer.return_value.developer_identity.return_value = "A" * 40
                blockers = distribution.release_blockers({"VELOEDIT_NOTARY_PROFILE": "test"})
            self.assertEqual(len(blockers), 3)


if __name__ == "__main__":
    unittest.main()
