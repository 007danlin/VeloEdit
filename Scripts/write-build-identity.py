#!/usr/bin/env python3
"""Record the exact source/resource identity of a staged app before signing."""
import datetime
import hashlib
import json
import pathlib
import plistlib
import sys

source, app = map(pathlib.Path, sys.argv[1:])
digest = hashlib.sha256()
paths = [source / "Package.swift"] + list((source / "Sources").rglob("*.swift"))
paths += [p for p in (source / "Resources").rglob("*") if p.is_file()]
for path in sorted(paths):
    digest.update(str(path.relative_to(source)).encode() + b"\0")
    with path.open("rb") as stream:
        digest.update(hashlib.file_digest(stream, "sha256").digest())
now = datetime.datetime.now(datetime.timezone.utc)
identity = {"builtAt": now.isoformat(), "sourceSHA256": digest.hexdigest(),
            "build": now.strftime("%Y.%j.%H%M%S"), "runtime": "Ollama 0.32.14"}
plist_path = app / "Contents/Info.plist"
with plist_path.open("rb") as stream:
    info = plistlib.load(stream)
info["CFBundleVersion"] = identity["build"]
info["VeloEditSourceSHA256"] = identity["sourceSHA256"]
info["VeloEditBuildDate"] = identity["builtAt"]
with plist_path.open("wb") as stream:
    plistlib.dump(info, stream)
(app / "Contents/Resources/BuildInfo.json").write_text(json.dumps(identity, indent=2) + "\n")
