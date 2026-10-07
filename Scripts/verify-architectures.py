#!/usr/bin/env python3
"""Reject incomplete universal apps, external dylibs and incompatible OS targets."""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
REQUIRED = ["MacOS/VeloEdit", "MacOS/VeloEditOVRLEY", "MacOS/VeloEditSpeechWorker",
            "Helpers/ffmpeg", "Helpers/ffprobe", "Resources/Ollama/ollama",
            "Resources/Ollama/llama-server", "Resources/Ollama/llama-quantize"]
OPTIONAL_NEWER_BACKENDS = "Contents/Resources/Ollama/mlx_metal_v4/"


def version(value):
    return tuple((list(map(int, value.split("."))) + [0, 0])[:3])


def inspect_slice(path, arch):
    output = subprocess.check_output(["otool", "-arch", arch, "-l", str(path)], text=True)
    minimum = re.search(r"\bminos\s+(\d+(?:\.\d+)+)", output)
    if not minimum:
        minimum = re.search(r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\S+)", output)
    dependencies, rpaths = [], []
    for command in re.split(r"Load command \d+\n", output)[1:]:
        if re.search(r"cmd LC_(?:LOAD|LOAD_WEAK|REEXPORT)_DYLIB\b", command):
            name = re.search(r"\bname (.+?) \(offset", command)
            if name:
                dependencies.append(name[1])
        if "cmd LC_RPATH" in command:
            path_match = re.search(r"\bpath (.+?) \(offset", command)
            if path_match:
                rpaths.append(path_match[1])
    return {"minimum_macos": minimum[1] if minimum else None, "dependencies": dependencies, "rpaths": rpaths}


def resolve_dependency(name, path, app, rpaths):
    if name.startswith(("/usr/lib/", "/System/Library/", "@rpath/libswift")):
        return None
    def expand(value):
        return value.replace("@loader_path", str(path.parent)).replace("@executable_path", str(path.parent))
    candidates = [Path(expand(name))]
    if name.startswith("@rpath/"):
        suffix = name.removeprefix("@rpath/")
        candidates = [Path(expand(root)) / suffix for root in rpaths]
        candidates += [path.parent / suffix, app / "Contents/Frameworks" / suffix]
    for candidate in candidates:
        resolved = candidate.resolve()
        if resolved.is_relative_to(app.resolve()) and resolved.is_file():
            return resolved
    raise ValueError(f"Unresolved/external dependency: {name} in {path}")


def verify(app, architectures):
    spec = importlib.util.spec_from_file_location("signing", ROOT / "Scripts/sign-app.py")
    signing = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(signing)
    inventory = {}
    minimum = plistlib.loads((app / "Contents/Info.plist").read_bytes())["LSMinimumSystemVersion"]
    for path in signing.code_files(app):
        archs = subprocess.check_output(["lipo", "-archs", str(path)], text=True).split()
        slices = {arch: inspect_slice(path, arch) for arch in archs}
        for arch, details in slices.items():
            optional = str(path.relative_to(app)).startswith(OPTIONAL_NEWER_BACKENDS)
            if not optional and details["minimum_macos"] and version(details["minimum_macos"]) > version(minimum):
                raise ValueError(f"{path} ({arch}) requires macOS {details['minimum_macos']}, advertised {minimum}")
        inventory[str(path.relative_to(app))] = {"architectures": archs, "slices": slices}
    for relative in REQUIRED:
        item = inventory.get("Contents/" + relative)
        if not item or not set(architectures).issubset(item["architectures"]):
            raise ValueError(f"Missing required architectures {architectures}: {relative}")
    for relative, item in inventory.items():
        path = app / relative
        for arch, details in item["slices"].items():
            for name in details["dependencies"]:
                target = resolve_dependency(name, path, app, details["rpaths"])
                if target is None:
                    continue
                other = inventory.get(str(target.relative_to(app.resolve())))
                if not other or arch not in other["architectures"]:
                    raise ValueError(f"Dependency {name} lacks {arch}, required by {relative}")
                required_os = other["slices"][arch]["minimum_macos"] or minimum
                supported_os = max(version(minimum), version(details["minimum_macos"] or minimum))
                if version(required_os) > supported_os:
                    raise ValueError(f"Dependency {name} requires newer macOS than {relative} supports")
    # Ollama selects these optional backends at runtime; each must retain its
    # real architecture, rather than pretending every plugin is universal.
    for pattern, arch in [("Resources/Ollama/libggml-cpu-*.so", "x86_64"),
                          ("Resources/Ollama/mlx_metal_v3/*.dylib", "arm64"),
                          ("Resources/Ollama/mlx_metal_v4/*.dylib", "arm64")]:
        backends = list((app / "Contents").glob(pattern))
        if arch in architectures and not backends:
            raise ValueError(f"Missing Ollama backend group for {arch}")
        for backend in backends:
            if arch not in inventory[str(backend.relative_to(app))]["architectures"]:
                raise ValueError(f"Invalid Ollama backend architecture: {backend}")
    return {"architectures": architectures, "minimum_macos": minimum, "binaries": inventory}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--architectures", nargs="+", default=["arm64", "x86_64"])
    parser.add_argument("--write-report", action="store_true")
    args = parser.parse_args()
    report = verify(args.app, args.architectures)
    if args.write_report:
        (args.app / "Contents/Resources/ArchitectureReport.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Verified {len(report['binaries'])} Mach-O files for {', '.join(args.architectures)} and macOS {report['minimum_macos']}+.")


if __name__ == "__main__":
    main()
