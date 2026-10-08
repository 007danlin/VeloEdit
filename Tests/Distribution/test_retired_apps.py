"""Keep running code addressable by macOS after publishing a new build."""
import ctypes
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("retired_apps", ROOT / "Scripts/cleanup-retired-apps.py")
retired_apps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retired_apps)


class RetiredAppTests(unittest.TestCase):
    def test_uncertain_process_scan_preserves_previous_bundle(self):
        for result in (
            subprocess.CompletedProcess([], 1, "", "permission denied"),
            subprocess.CompletedProcess([], 2, "", ""),
            subprocess.CompletedProcess([], 0, "123\n", ""),
        ):
            with self.subTest(result=result), tempfile.TemporaryDirectory() as scratch:
                app = Path(scratch) / ".VeloEdit.app.previous-123"
                app.mkdir()
                with patch.object(retired_apps.subprocess, "run", return_value=result):
                    self.assertFalse(retired_apps.remove_if_unused(app))
                self.assertTrue(app.is_dir())

    def test_scan_timeout_preserves_previous_bundle(self):
        with tempfile.TemporaryDirectory() as scratch:
            app = Path(scratch) / ".VeloEdit.app.previous-123"
            app.mkdir()
            with patch.object(retired_apps.subprocess, "run", side_effect=subprocess.TimeoutExpired("lsof", 30)):
                self.assertFalse(retired_apps.remove_if_unused(app))
            self.assertTrue(app.is_dir())

    def test_current_bundle_and_symlinks_are_never_removed(self):
        with tempfile.TemporaryDirectory() as scratch:
            app = Path(scratch) / "VeloEdit.app"
            app.mkdir()
            link = Path(scratch) / ".VeloEdit.app.previous-123"
            link.symlink_to(app, target_is_directory=True)
            with patch.object(retired_apps.subprocess, "run") as scan:
                self.assertFalse(retired_apps.remove_if_unused(app))
                self.assertFalse(retired_apps.remove_if_unused(link))
                scan.assert_not_called()
            self.assertTrue(app.is_dir())

    @unittest.skipUnless(sys.platform == "darwin", "macOS process identity regression")
    def test_running_executable_survives_publish_until_process_exits(self):
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)

        def executable_path(pid):
            buffer = ctypes.create_string_buffer(4096)
            return buffer.value.decode() if libproc.proc_pidpath(pid, buffer, len(buffer)) > 0 else ""

        with tempfile.TemporaryDirectory() as scratch:
            app = Path(scratch).resolve() / "VeloEdit.app"
            binary = app / "Contents/MacOS/VeloEdit"
            binary.parent.mkdir(parents=True)
            subprocess.run(["/usr/bin/clang", "-x", "c", "-", "-o", str(binary)],
                           input="#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n",
                           text=True, check=True, capture_output=True)
            process = subprocess.Popen([str(binary)])
            try:
                for _ in range(100):
                    if executable_path(process.pid) == str(binary):
                        break
                    time.sleep(0.01)
                self.assertEqual(executable_path(process.pid), str(binary))
                retired = app.with_name(".VeloEdit.app.previous-123")
                app.rename(retired)
                self.assertFalse(retired_apps.remove_if_unused(retired))
                running_binary = executable_path(process.pid)
                self.assertTrue(Path(running_binary).is_file(), running_binary)
            finally:
                process.terminate()
                process.wait()
            self.assertTrue(retired_apps.remove_if_unused(retired))
            self.assertFalse(retired.exists())

    @unittest.skipUnless(sys.platform == "darwin", "macOS lsof regression")
    def test_open_resource_also_keeps_bundle_alive(self):
        with tempfile.TemporaryDirectory() as scratch:
            app = Path(scratch) / ".VeloEdit.app.previous-123"
            app.mkdir()
            with (app / "resource").open("w"):
                self.assertFalse(retired_apps.remove_if_unused(app))
            self.assertTrue(retired_apps.remove_if_unused(app))


if __name__ == "__main__":
    unittest.main()
