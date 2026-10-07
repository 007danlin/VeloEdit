#!/usr/bin/env python3
"""Package the signed app in a branded, drag-to-install Finder window."""
import argparse
import json
from pathlib import Path
import subprocess

import dmgbuild

ROOT = Path(__file__).resolve().parent.parent


def verify_copied_app(mount_point, options):
    # dmgbuild uses ditto internally; verify the actual copy, not only the
    # staging app, before the disk image is sealed and compressed.
    subprocess.run(["codesign", "--verify", "--deep", "--strict",
                    str(Path(mount_point) / "VeloEdit.app")], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("dmg", type=Path)
    parser.add_argument("--volume-name", default="VeloEdit")
    args = parser.parse_args()
    design = ROOT / "Distribution/Installer"
    layout = json.loads((design / "layout.json").read_text())
    for name in (layout["background"], "background@2x.png"):
        if not (design / name).is_file():
            raise SystemExit(f"Missing installer artwork: {name}")
    if not (args.app / "Contents/Resources/Legal/LICENSE.txt").is_file():
        raise SystemExit("The application must contain its licenses before packaging.")

    dmgbuild.build_dmg(str(args.dmg.resolve()), args.volume_name, settings={
        "format": "UDZO",
        "filesystem": "HFS+",
        "files": [(str(args.app.resolve()), "VeloEdit.app")],
        "symlinks": {"Applications": "/Applications"},
        "background": str(design / layout["background"]),
        "window_rect": (tuple(layout["window_origin"]), tuple(layout["window_size"])),
        "icon_locations": {key: tuple(value) for key, value in layout["icon_locations"].items()},
        "icon_size": layout["icon_size"],
        "text_size": layout["text_size"],
        # SetFile -a E adds FinderInfo to the signed bundle and invalidates
        # strict signature verification. Finder handles app names itself.
        "hide_extensions": [],
        "default_view": "icon-view",
        "arrange_by": None,
        "show_toolbar": False,
        "show_status_bar": False,
        "show_sidebar": False,
        "show_pathbar": False,
        "show_tab_view": False,
        "show_icon_preview": False,
        "include_icon_view_settings": True,
        "include_list_view_settings": False,
        "create_hook": verify_copied_app,
    })
    print(f"Branded installer created: {args.dmg}")


if __name__ == "__main__":
    main()
