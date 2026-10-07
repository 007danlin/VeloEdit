#!/usr/bin/env python3
"""Assemble readable notices and an inventory; this is not a legal clearance."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys


def main():
    source, app, swift_cache = map(Path, sys.argv[1:])
    resources = app / "Contents/Resources"
    legal = resources / "Legal"
    shutil.copytree(source / "Resources/Legal", legal)
    publisher = json.loads((legal / "publisher.json").read_text())
    owner = publisher["copyright_holder"].strip()
    year = str(publisher["copyright_year"])
    text = (legal / "LICENSE.txt").read_text()
    for key, value in {
        "YEAR": year, "COPYRIGHT_HOLDER": owner or "правообладатель не указан",
        "CONTACT": publisher.get("contact", "").strip() or "не указан",
    }.items():
        text = text.replace("{{" + key + "}}", value)
    if not owner:
        text = "ЧЕРНОВИК — необходимо указать правообладателя перед распространением.\n\n" + text
    (legal / "LICENSE.txt").write_text(text)
    plist_path = app / "Contents/Info.plist"
    info = plistlib.loads(plist_path.read_bytes())
    info["NSHumanReadableCopyright"] = f"Copyright © {year} {owner or 'VeloEdit'}"
    plist_path.write_bytes(plistlib.dumps(info))

    licenses = legal / "Licenses"
    licenses.mkdir()
    required = {
        "ArgmaxOSS-LICENSE.txt": source / "ThirdParty/ArgmaxOSS/LICENSE",
        "OVRLEY-LICENSE.txt": source / "ThirdParty/OVRLEY/LICENSE.md",
        "Ollama-LICENSE.txt": resources / "Ollama/LICENSE",
        "Music-LICENSE.txt": resources / "Music/LICENSE.md",
        "ONNX-Runtime-LICENSE.txt": swift_cache / "checkouts/onnxruntime-swift-package-manager/LICENSE",
    }
    for name, path in required.items():
        if not path.is_file():
            raise SystemExit(f"Required third-party license is missing: {path}")
        shutil.copy2(path, licenses / name)
    shutil.copytree(resources / "FFmpeg-Licenses", licenses / "FFmpeg")
    speech_notices = resources / "Speech/ModelsPackage/notices"
    if speech_notices.is_dir():
        shutil.copytree(speech_notices, licenses / "SpeechModels")

    # Inventory the union of both shipped target dependency graphs.
    targets = [("aarch64" if arch == "arm64" else arch) + "-apple-darwin"
               for arch in os.environ.get("VELOEDIT_ARCHS", "arm64 x86_64").split()]
    env = dict(os.environ)
    cache_root = Path(env.get("VELOEDIT_BUILD_CACHE_ROOT", Path.home() / "Library/Caches/VeloEditBuild"))
    env["CARGO_HOME"] = env.get("VELOEDIT_CARGO_HOME", str(cache_root / "cargo-home"))
    target_packages = {}
    for target in targets:
        metadata = json.loads(subprocess.check_output([
            "cargo", "metadata", "--offline", "--locked", "--filter-platform", target,
            "--format-version", "1", "--manifest-path",
            str(source / "ThirdParty/OVRLEY/src-tauri/ovrley_core/Cargo.toml"),
        ], env=env, text=True))
        for package in metadata["packages"]:
            target_packages[package["id"]] = package
    packages = []
    for package in sorted(target_packages.values(), key=lambda p: (p["name"], p["version"])):
        root = Path(package["manifest_path"]).parent
        candidates = [p for p in root.iterdir() if p.is_file()
                      and p.name.upper().startswith(("LICENSE", "COPYING", "NOTICE", "COPYRIGHT"))]
        if package.get("license_file"):
            candidates.append(root / package["license_file"])
        copied = []
        for path in sorted(set(candidates)):
            if not path.is_file():
                continue
            dest = licenses / "Rust" / f"{package['name']}-{package['version']}" / path.name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest)
            copied.append(str(dest.relative_to(legal)))
        packages.append({"name": package["name"], "version": package["version"],
                         "license": package.get("license"), "source": package.get("source"),
                         "repository": package.get("repository"), "notice_files": copied})
    (legal / "RustDependencies.json").write_text(json.dumps({
        "targets": targets, "scope": "Cargo metadata; includes build dependencies, not a complete transitive native-code audit",
        "packages": packages,
    }, ensure_ascii=False, indent=2) + "\n")
    # SwiftPM checkouts may contain read-only notices. The bundle's copies
    # must be writable so xattr cleanup and signing can process them.
    for path in legal.rglob("*"):
        if path.is_file() and not path.is_symlink():
            path.chmod(path.stat().st_mode | 0o200)
    print(f"Legal documents bundled; {len(packages)} Rust packages inventoried.")


if __name__ == "__main__":
    main()
