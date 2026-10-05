#!/usr/bin/env python3
"""Sign nested Mach-O code inside out, then seal the app. Never use --deep to sign."""
import argparse
import os
from pathlib import Path
import re
import subprocess

MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def code_files(app):
    for path in sorted(app.rglob("*"), key=lambda p: (-len(p.parts), str(p))):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) in MACHO_MAGICS:
                yield path


def developer_identity(identity):
    result = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                            text=True, capture_output=True, check=True)
    for fingerprint, name in re.findall(r'([0-9A-Fa-f]{40}) "([^"]+)"', result.stdout):
        if name.startswith("Developer ID Application:") and identity in (name, fingerprint):
            return fingerprint
    raise ValueError("A valid Developer ID Application certificate with its private key is required; none matches VELOEDIT_CODESIGN_IDENTITY.")


def verify(app, release=False):
    requirement = 'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    team = None
    for path in [*code_files(app), app]:
        command = ["codesign", "--verify", "--strict", "--verbose=1"]
        if path == app:
            command.append("--deep")
        if release:
            command += ["-R", requirement]
        subprocess.run(command + [str(path)], check=True)
        if release:
            result = subprocess.run(["codesign", "-d", "--verbose=4", str(path)],
                                    capture_output=True, text=True, check=True)
            details = result.stderr
            current = re.search(r"^TeamIdentifier=(.+)$", details, re.MULTILINE)
            if not current or current[1] == "not set" or "Timestamp=" not in details or "runtime" not in details:
                raise ValueError(f"Missing Developer ID team, secure timestamp or hardened runtime: {path}")
            if team and team != current[1]:
                raise ValueError(f"Mixed signing teams: {path}")
            team = current[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--release", action="store_true")
    args = parser.parse_args()
    if not args.app.is_dir() or not (args.app / "Contents/Info.plist").is_file():
        parser.error("Expected an application bundle")
    identity = os.environ.get("VELOEDIT_CODESIGN_IDENTITY", "").strip() or "-"
    if not args.verify_only:
        if args.release or identity != "-":
            identity = developer_identity(identity)
        flags = ["--force", "--sign", identity]
        if identity != "-":
            flags += ["--options", "runtime", "--timestamp"]
        for path in code_files(args.app):
            subprocess.run(["codesign", *flags, str(path)], check=True)
        subprocess.run(["codesign", *flags, str(args.app)], check=True)
    verify(args.app, release=args.release or (not args.verify_only and identity != "-"))
    print("Developer ID signatures verified." if args.release or identity != "-" else "Local ad-hoc signatures verified; not a Developer ID release.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
