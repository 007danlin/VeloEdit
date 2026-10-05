#!/usr/bin/env python3
"""Bundle the installed converter and its non-system dylibs relocatably."""
from pathlib import Path
import shutil
import subprocess
import sys

app = Path(sys.argv[1])
source = shutil.which("ffmpeg") or next((p for p in (
    "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg") if Path(p).exists()), None)
if source is None:
    raise SystemExit("Install ffmpeg before building: brew install ffmpeg")
helpers = app / "Contents/Helpers"
libs = helpers / "lib"
notices = app / "Contents/Resources/FFmpeg-Licenses"
libs.mkdir(parents=True, exist_ok=True)
notices.mkdir(parents=True, exist_ok=True)
pending = [(Path(source).resolve(), helpers / "ffmpeg")]
seen = set()
packages = set()
while pending:
    original, destination = pending.pop()
    if destination in seen:
        continue
    seen.add(destination)
    shutil.copy2(original, destination)
    destination.chmod(0o755)
    subprocess.run(["codesign", "--remove-signature", str(destination)], capture_output=True)
    parts = original.parts
    if "Cellar" in parts:
        index = parts.index("Cellar")
        packages.add(Path(*parts[:index + 3]))
    dependencies = subprocess.check_output(["otool", "-L", str(original)], text=True).splitlines()[1:]
    for line in dependencies:
        dependency = line.strip().split(" (", 1)[0]
        if dependency.startswith(("/usr/lib/", "/System/Library/")):
            continue
        path = Path(dependency)
        if not path.is_absolute():
            raise SystemExit(f"Unresolved dependency: {dependency} in {original}")
        target = libs / path.name
        new_name = ("@loader_path/lib/" if destination.name == "ffmpeg" else "@loader_path/") + path.name
        subprocess.run(["install_name_tool", "-change", dependency, new_name, str(destination)], check=True)
        if path.resolve() != original:
            pending.append((path.resolve(), target))
    if destination.suffix == ".dylib":
        subprocess.run(["install_name_tool", "-id", "@loader_path/" + destination.name, str(destination)], check=True)
    # Temporary ad-hoc signature allows the relocation smoke check. The app
    # signer subsequently signs every binary with the final identity/runtime.
    subprocess.run(["codesign", "--force", "--sign", "-", str(destination)], check=True, capture_output=True)
for package in packages:
    dest = notices / package.parent.name
    dest.mkdir(exist_ok=True)
    for file in package.iterdir():
        if file.is_file() and (file.name.upper().startswith(("LICENSE", "COPYING")) or file.name in ("INSTALL_RECEIPT.json", "sbom.spdx.json")):
            shutil.copy2(file, dest / file.name)
(notices / "README.txt").write_text(
    "FFmpeg: https://ffmpeg.org/ — source https://ffmpeg.org/releases/\n"
    "Built with Homebrew. Package versions, source URLs and license texts are included.\n"
    "Converter is a separate executable; originals are never modified.\n")
configuration = subprocess.check_output([str(helpers / "ffmpeg"), "-version"], text=True)
(notices / "build-configuration.txt").write_text(configuration)
