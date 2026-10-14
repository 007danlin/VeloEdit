#!/usr/bin/env python3
"""Explain bundle size and reject accidentally packaged development artifacts.

Read-only; symlinks are recorded without following/counting their targets twice.
Run after build-app.sh, optionally saving a JSON report outside the app seal.
"""
import argparse
import json
import os
from pathlib import Path


DEVELOPMENT_DIRECTORIES = {".git", ".build", ".swiftpm", "node_modules", "__pycache__", "CinematicAcceptance"}
DEVELOPMENT_SUFFIXES = {".o", ".swiftmodule", ".swiftdoc", ".dSYM", ".partial", ".tmp"}


def inspect(app):
    groups, files, unexpected, symlinks = {}, [], [], []
    for directory, directories, names in os.walk(app, followlinks=False):
        for name in directories + names:
            path = Path(directory) / name
            relative = path.relative_to(app).as_posix()
            if name in DEVELOPMENT_DIRECTORIES or name == ".DS_Store" or path.suffix in DEVELOPMENT_SUFFIXES:
                unexpected.append(relative)
            if path.is_symlink():
                symlinks.append(relative)
                continue
            if not path.is_file():
                continue
            size = path.stat().st_size
            parts = path.relative_to(app).parts
            group = "/".join(parts[:3] if len(parts) > 2 and parts[1] == "Resources" else parts[:2])
            groups[group] = groups.get(group, 0) + size
            files.append({"path": relative, "bytes": size})
    return {"app": str(app.resolve()), "logicalBytes": sum(groups.values()), "fileCount": len(files),
            "groups": dict(sorted(groups.items(), key=lambda pair: -pair[1])),
            "largestFiles": sorted(files, key=lambda item: -item["bytes"])[:20],
            "unexpectedDevelopmentArtifacts": sorted(unexpected), "symlinkCount": len(symlinks),
            "note": "Logical file sizes; APFS allocation, Finder decimal units and compression can differ. AI model downloads outside the app are not included."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not (args.app / "Contents/Info.plist").is_file():
        parser.error("Expected a complete .app bundle")
    report = inspect(args.app)
    data = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(data)
    print(f"Total: {report['logicalBytes'] / 1_000_000_000:.3f} GB ({report['logicalBytes'] / 1024 ** 3:.3f} GiB)")
    for group, size in report["groups"].items():
        print(f"{size / 1024 ** 2:9.2f} MiB  {group}")
    print(f"Development artifacts: {len(report['unexpectedDevelopmentArtifacts'])}")
    for path in report["unexpectedDevelopmentArtifacts"]:
        print(path)
    return bool(report["unexpectedDevelopmentArtifacts"])


if __name__ == "__main__":
    raise SystemExit(main())
