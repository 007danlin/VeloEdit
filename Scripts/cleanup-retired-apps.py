#!/usr/bin/env python3
"""Remove old build bundles only after all processes release their files."""
import argparse
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
