#!/usr/bin/env python3
"""Remove old build bundles only after all processes release their files."""
import argparse
import ctypes
import errno
from pathlib import Path
import re
import shutil
import subprocess


RETIRED_NAME = re.compile(r"\.VeloEdit\.app\.previous-[0-9A-Fa-f-]+")


def remove_if_unused(app: Path) -> bool:
    if app.is_symlink() or not app.is_dir() or not RETIRED_NAME.fullmatch(app.name):
        return False
    try:
        result = subprocess.run(
            ["/usr/sbin/lsof", "-nP", "-t", "+D", str(app)],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    # lsof exits 1 with no diagnostics when nothing is open. Errors (including
    # insufficient permission) must retain the bundle, as must mapped helpers
    # and resources, not just the main application executable.
    if result.returncode != 1 or result.stdout.strip() or result.stderr.strip():
        return False
    # A just-launched executable can already have a process identity before
    # lsof reports its mapped text. ps can keep the pre-rename executable path,
    # so retain retired bundles while either that path or the retired path is
    # running. An incomplete process scan is not evidence that deletion is safe.
    try:
        processes = subprocess.run(
            ["/bin/ps", "-axww", "-o", "pid=,comm="], capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    if processes.returncode != 0 or processes.stderr.strip() or not processes.stdout.strip():
        return False
    prefixes = (str(app.resolve()) + "/", str(app.resolve().with_name("VeloEdit.app")) + "/")
    # macOS ps can spell /private/var as /var; compare canonical paths.
    entries = [line.strip().split(maxsplit=1) for line in processes.stdout.splitlines() if line.strip()]
    if any(str(Path(entry[-1]).resolve()).startswith(prefixes) for entry in entries):
        return False
    if any(len(entry) != 2 or not entry[0].isdigit() for entry in entries):
        return False
    # Immediately after exec, ps may still return only the process basename,
    # while lsof has not observed its text mapping yet. The kernel executable
    # identity is already available then; consult it before deleting any code.
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        libproc.proc_pidpath.restype = ctypes.c_int
        executable_names = {"VeloEdit"}
        executable_names.update(path.name for path in app.rglob("*")
                                if path.is_file() and path.stat().st_mode & 0o111)
        for entry in entries:
            # Absolute paths have already been checked. Only unresolved names
            # of this bundle's executables need the additional kernel lookup;
            # an unrelated application's deleted executable is not our bundle.
            if entry[1].startswith("/") or Path(entry[1]).name not in executable_names:
                continue
            pid = int(entry[0])
            if pid == 0:
                continue  # kernel_task cannot execute a bundle from this directory.
            buffer = ctypes.create_string_buffer(4096)
            ctypes.set_errno(0)
            if libproc.proc_pidpath(pid, buffer, len(buffer)) <= 0:
                if ctypes.get_errno() == errno.ESRCH:
                    continue  # Process exited after the snapshot.
                return False
            if str(Path(buffer.value.decode()).resolve()).startswith(prefixes):
                return False
    except (OSError, ValueError, UnicodeError):
        return False
    shutil.rmtree(app)
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_dir", type=Path)
    args = parser.parse_args()
    for app in sorted(args.build_dir.glob(".VeloEdit.app.previous-*")):
        if not remove_if_unused(app):
            print(f"Retaining previous application while in use or unverifiable: {app}")


if __name__ == "__main__":
    main()
