#!/usr/bin/env python3
"""Bundle relocatable native FFmpeg/ffprobe slices with matching dependencies."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def dependencies(path):
    lines = subprocess.check_output(["otool", "-L", str(path)], text=True).splitlines()[1:]
    return [line.strip().split(" (", 1)[0] for line in lines]


def stage_slice(prefix, destination, notices):
    manifest = json.loads((prefix / "build.json").read_text())
    packages = {key: Path(value) for key, value in manifest["packages"].items()}
    known = {path.name: path.resolve() for package in packages.values() for path in (package / "lib").glob("*.dylib")}
    pending = [(prefix / "bin" / name, destination / name) for name in ("ffmpeg", "ffprobe")]
    seen = set()
    while pending:
        original, copied = pending.pop()
        if copied in seen:
            continue
        seen.add(copied)
        copied.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original, copied)
        copied.chmod(0o755)
        subprocess.run(["codesign", "--remove-signature", str(copied)], capture_output=True)
        for dependency in dependencies(original):
            if dependency.startswith(("/usr/lib/", "/System/Library/")):
                continue
            name = Path(dependency).name
            if name not in known:
                raise ValueError(f"Unpinned dependency {dependency} in {original}")
            rewritten = ("@loader_path/lib/" if copied.parent == destination else "@loader_path/") + name
            subprocess.run(["install_name_tool", "-change", dependency, rewritten, str(copied)], check=True)
            if known[name] != original.resolve():
                pending.append((known[name], destination / "lib" / name))
        if copied.suffix == ".dylib":
            subprocess.run(["install_name_tool", "-id", "@loader_path/" + copied.name, str(copied)], check=True)
    notices.mkdir(parents=True, exist_ok=True)
    shutil.copy2(prefix / "build.json", notices / "build.json")
    shutil.copytree(prefix / "notices", notices / "FFmpeg", dirs_exist_ok=True)
    for name, package in packages.items():
        target = notices / name
        target.mkdir(exist_ok=True)
        for path in package.iterdir():
            if path.is_file() and (path.name.upper().startswith(("LICENSE", "COPYING", "NOTICE")) or path.name in ("INSTALL_RECEIPT.json", "sbom.spdx.json")):
                shutil.copyfile(path, target / path.name)
    return {path.relative_to(destination) for path in seen}


def main():
    app = Path(sys.argv[1])
    architectures = os.environ.get("VELOEDIT_ARCHS", "arm64 x86_64").split()
    subprocess.run([sys.executable, str(ROOT / "Scripts/prepare-native.py"), "--architectures", *architectures], check=True)
    helpers = app / "Contents/Helpers"
    notices = app / "Contents/Resources/FFmpeg-Licenses"
    helpers.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="veloedit-ffmpeg-") as temporary:
        root = Path(temporary)
        inventories = [stage_slice(ROOT / "Build/NativeDependencies/ffmpeg" / arch, root / arch, notices / arch) for arch in architectures]
        if any(inventory != inventories[0] for inventory in inventories):
            raise ValueError("FFmpeg architecture slices have different dependency sets")
        for relative in sorted(inventories[0]):
            destination = helpers / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["lipo", "-create", *[str(root / arch / relative) for arch in architectures], "-output", str(destination)], check=True)
            destination.chmod(0o755)
            subprocess.run(["codesign", "--force", "--sign", "-", str(destination)], check=True, capture_output=True)
    configuration = subprocess.check_output([str(helpers / "ffmpeg"), "-version"], text=True)
    (notices / "build-configuration.txt").write_text(configuration)
    shutil.copy2(ROOT / "Distribution/native-dependencies.json", notices / "dependencies.json")
    shutil.copy2(ROOT / "Scripts/prepare-native.py", notices / "build-recipe.txt")
    (notices / "README.txt").write_text("FFmpeg https://ffmpeg.org/ — built from pinned source for macOS 14+.\n"
        "Each architecture includes exact configure options, dependency origins, checksums, and license notices.\n"
        "H.264, AV1 and Opus libraries are pinned Homebrew bottles; VideoToolbox and AudioToolbox remain enabled.\n")


if __name__ == "__main__":
    main()
