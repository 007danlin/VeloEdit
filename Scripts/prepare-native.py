#!/usr/bin/env python3
"""Build pinned FFmpeg for both Macs and prepare an isolated Rust cross sysroot."""
import argparse
import fcntl
import hashlib
import inspect
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "Distribution/native-dependencies.json"
CACHE = ROOT / "Build/NativeDependencies"


def run(*args, **kwargs):
    print("→ " + " ".join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def download(url, checksum):
    destination = CACHE / "downloads" / checksum
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and hashlib.sha256(destination.read_bytes()).hexdigest() == checksum:
        return destination
    headers = {}
    if url.startswith("https://ghcr.io/v2/homebrew/core/"):
        repository = url.split("/v2/", 1)[1].split("/blobs/", 1)[0]
        query = urllib.parse.urlencode({"service": "ghcr.io", "scope": f"repository:{repository}:pull"})
        with urllib.request.urlopen("https://ghcr.io/token?" + query) as response:
            token = json.load(response)["token"]
        headers["Authorization"] = "Bearer " + token
    print(f"Download {url}", flush=True)
    temporary = destination.with_suffix(".partial")
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers)) as source, temporary.open("wb") as output:
        shutil.copyfileobj(source, output)
    if hashlib.sha256(temporary.read_bytes()).hexdigest() != checksum:
        temporary.unlink()
        raise ValueError(f"Checksum mismatch: {url}")
    temporary.replace(destination)
    return destination


def bottle(name, entry, arch):
    package = entry["bottles"][arch]
    destination = CACHE / "bottles" / arch / name / package["sha256"]
    marker = destination / ".ready"
    if not marker.exists():
        destination.mkdir(parents=True, exist_ok=True)
        with tarfile.open(download(package["url"], package["sha256"])) as archive:
            archive.extractall(destination, filter="data")
        marker.touch()
    roots = list((destination / name).iterdir())
    roots = [path for path in roots if path.is_dir()]
    if len(roots) != 1:
        raise ValueError(f"Unexpected bottle layout: {destination}")
    return roots[0]


def prepare_rust(lock):
    details = subprocess.check_output(["rustc", "-vV"], text=True)
    sysroot = Path(subprocess.check_output(["rustc", "--print", "sysroot"], text=True).strip())
    target = "x86_64-apple-darwin"
    if (sysroot / "lib/rustlib" / target / "lib").is_dir():
        return sysroot
    pin = lock["rust"]
    if f"commit-hash: {pin['commit']}" not in details:
        raise ValueError("Install the x86_64-apple-darwin target for your Rust compiler, or use Rust " + pin["version"])
    # Homebrew's compiler has a different metadata identity from rust-lang's
    # std even at the same commit. Keep compiler and both std slices together.
    destination = CACHE / "rust-toolchain" / pin["version"]
    marker = destination / ".ready"
    if not marker.exists():
        components = dict(pin["components"])
        components["rust-std-intel"] = {"url": pin["intel_std_url"], "sha256": pin["intel_std_sha256"]}
        for name, component in components.items():
            unpacked = CACHE / "rust-components" / pin["version"] / name
            unpacked.mkdir(parents=True, exist_ok=True)
            with tarfile.open(download(component["url"], component["sha256"])) as archive:
                archive.extractall(unpacked, filter="data")
            roots = [path for path in unpacked.iterdir() if path.is_dir()]
            if len(roots) != 1:
                raise ValueError("Unexpected Rust component archive")
            run("sh", roots[0] / "install.sh", "--prefix=" + str(destination), "--disable-ldconfig")
        marker.touch()
    llvm_link = destination / "lib/rustlib/aarch64-apple-darwin/lib/libLLVM.dylib"
    if not llvm_link.exists():
        llvm_link.symlink_to("../../../libLLVM.dylib")
    return destination


def prepare_ffmpeg(lock, arch):
    # The fingerprint includes this build recipe, not just the upstream version.
    recipe = json.dumps({key: lock[key] for key in ("minimum_macos", "ffmpeg", "libraries", "tools")}, sort_keys=True)
    fingerprint = hashlib.sha256((recipe + inspect.getsource(prepare_ffmpeg) + inspect.getsource(bottle)).encode()).hexdigest()
    destination = CACHE / "ffmpeg" / arch
    marker = destination / "build.json"
    if marker.is_file() and json.loads(marker.read_text()).get("fingerprint") == fingerprint:
        return destination
    packages = {name: bottle(name, entry, arch) for name, entry in lock["libraries"].items()}
    nasm = bottle("nasm", lock["tools"]["nasm"], platform.machine())
    pkgconfig = CACHE / "pkgconfig" / arch
    pkgconfig.mkdir(parents=True, exist_ok=True)
    for package in packages.values():
        for pc in (package / "lib/pkgconfig").glob("*.pc"):
            lines = pc.read_text().splitlines()
            lines = [f"prefix={package}" if line.startswith("prefix=") else line for line in lines]
            lines = [line.replace("@@HOMEBREW_CELLAR@@/" + package.parent.name + "/" + package.name, str(package)) for line in lines]
            (pkgconfig / pc.name).write_text("\n".join(lines) + "\n")
    pin = lock["ffmpeg"]
    sources = CACHE / "sources"
    source = sources / ("ffmpeg-" + pin["version"])
    if not source.exists():
        sources.mkdir(parents=True, exist_ok=True)
        with tarfile.open(download(pin["url"], pin["sha256"])) as archive:
            archive.extractall(sources, filter="data")
    work = CACHE / "ffmpeg-build" / arch
    work.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    env = dict(os.environ, PKG_CONFIG_LIBDIR=str(pkgconfig), PKG_CONFIG_PATH="",
               MACOSX_DEPLOYMENT_TARGET=lock["minimum_macos"],
               PATH=str(nasm / "bin") + os.pathsep + os.environ["PATH"])
    flags = f"-arch {arch} -mmacosx-version-min={lock['minimum_macos']} -isysroot {sdk}"
    arguments = [str(source / "configure"), "--prefix=" + str(destination),
                 "--arch=" + ("aarch64" if arch == "arm64" else arch), "--target-os=darwin",
                 "--enable-cross-compile", "--cc=clang", "--cxx=clang++", "--disable-autodetect",
                 "--disable-doc", "--disable-ffplay", "--disable-debug", "--disable-shared", "--enable-static",
                 "--enable-gpl", "--enable-version3", "--enable-libx264", "--enable-libdav1d",
                 "--enable-libopus", "--enable-libsvtav1", "--enable-videotoolbox", "--enable-audiotoolbox",
                 "--enable-securetransport", "--enable-zlib", "--enable-bzlib",
                 "--extra-cflags=" + flags, "--extra-ldflags=" + flags + " -Wl,-headerpad_max_install_names"]
    run(*arguments, cwd=work, env=env)
    run("make", "-j" + os.environ.get("VELOEDIT_BUILD_JOBS", "2"), cwd=work, env=env)
    run("make", "install", cwd=work, env=env)
    notices = destination / "notices"
    notices.mkdir(exist_ok=True)
    for name in ("COPYING.GPLv2", "COPYING.GPLv3", "COPYING.LGPLv2.1", "COPYING.LGPLv3", "LICENSE.md"):
        if (source / name).exists():
            shutil.copy2(source / name, notices / name)
    marker.write_text(json.dumps({"fingerprint": fingerprint, "architecture": arch,
                                 "minimum_macos": lock["minimum_macos"], "configure": arguments,
                                 "packages": {name: str(path) for name, path in packages.items()},
                                 "dependencies": lock}, indent=2) + "\n")
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architectures", nargs="+", default=["arm64", "x86_64"], choices=["arm64", "x86_64"])
    parser.add_argument("--rust-only", action="store_true")
    args = parser.parse_args()
    CACHE.mkdir(parents=True, exist_ok=True)
    lock = json.loads(LOCK.read_text())
    with (CACHE / ".rust.lock").open("w") as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        if "x86_64" in args.architectures:
            sysroot = prepare_rust(lock)
            (CACHE / "rust-sysroot-path.txt").write_text(str(sysroot) + "\n")
    if not args.rust_only:
        with (CACHE / ".prepare.lock").open("w") as guard:
            fcntl.flock(guard, fcntl.LOCK_EX)
            for arch in args.architectures:
                prepare_ffmpeg(lock, arch)


if __name__ == "__main__":
    main()
