"""Real Mach-O fixtures guard against shipping an ARM-only universal installer."""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("architectures", ROOT / "Scripts/verify-architectures.py")
architectures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(architectures)


@unittest.skipUnless(sys.platform == "darwin", "requires Apple's Mach-O toolchain")
class ArchitectureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Fixture.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"LSMinimumSystemVersion": "14.0"}))
        self.source = self.root / "main.c"
        self.source.write_text("int main(void) { return 0; }\n")
        self.entry = self.app / "Contents/MacOS/VeloEdit"
        self.required = patch.object(architectures, "REQUIRED", ["MacOS/VeloEdit"])
        self.required.start()
        self.addCleanup(self.required.stop)

    def compile(self, output, arch="arm64", minimum="14.0", extra=()):
        subprocess.run(["xcrun", "clang", "-arch", arch, "-mmacosx-version-min=" + minimum,
                        str(self.source), *extra, "-o", str(output)], check=True, capture_output=True)

    def test_arm_only_application_is_rejected(self):
        self.compile(self.entry)
        with self.assertRaisesRegex(ValueError, "Missing required architectures"):
            architectures.verify(self.app, ["arm64", "x86_64"])

    def test_newer_deployment_target_is_rejected(self):
        self.compile(self.entry, minimum="26.0")
        with self.assertRaisesRegex(ValueError, "requires macOS 26"):
            architectures.verify(self.app, ["arm64"])

    def test_missing_intel_slice_in_dependency_is_rejected(self):
        library = self.entry.parent / "sample.dylib"
        self.compile(library, arch="x86_64", extra=["-dynamiclib", "-install_name", "@loader_path/sample.dylib"])
        self.compile(self.entry, arch="x86_64", extra=[str(library)])
        self.compile(library, arch="arm64", extra=["-dynamiclib", "-install_name", "@loader_path/sample.dylib"])
        with self.assertRaisesRegex(ValueError, "lacks x86_64"):
            architectures.verify(self.app, ["x86_64"])

    def test_dependency_outside_bundle_is_rejected(self):
        library = self.root / "external.dylib"
        self.compile(library, extra=["-dynamiclib", "-install_name", str(library)])
        self.compile(self.entry, extra=[str(library)])
        with self.assertRaisesRegex(ValueError, "Unresolved/external"):
            architectures.verify(self.app, ["arm64"])


if __name__ == "__main__":
    unittest.main()
