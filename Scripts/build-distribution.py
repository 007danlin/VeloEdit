#!/usr/bin/env python3
"""Create a local DMG, or explicitly request a Developer ID notarized release."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
REVIEWS = ("gpl_integration", "corresponding_source", "dependency_and_model_notices")


def run(*command, **kwargs):
    print("→ " + " ".join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def signer():
    spec = importlib.util.spec_from_file_location("veloedit_signing", ROOT / "Scripts/sign-app.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def release_blockers(env):
    blockers = []
    publisher = json.loads((ROOT / "Resources/Legal/publisher.json").read_text())
    if not publisher.get("copyright_holder", "").strip():
        blockers.append("Укажите правообладателя в Resources/Legal/publisher.json.")
    try:
        signer().developer_identity(env.get("VELOEDIT_CODESIGN_IDENTITY", ""))
    except (ValueError, subprocess.CalledProcessError) as error:
        blockers.append(str(error))
    if not env.get("VELOEDIT_NOTARY_PROFILE", "").strip():
        blockers.append("Задайте VELOEDIT_NOTARY_PROFILE — имя профиля notarytool в Keychain.")
    reviews = json.loads((ROOT / "Distribution/legal-review.json").read_text())
    for key in REVIEWS:
        review = reviews.get(key, {})
        evidence = review.get("evidence", "")
        path = (ROOT / evidence).resolve()
        if (review.get("status") != "approved" or not evidence or not path.is_relative_to(ROOT)
                or not path.is_file() or path.stat().st_size == 0):
            blockers.append(f"Лицензионная проверка {key}: {review.get('reason', 'нужно заключение и подтверждающие материалы')}")
    return blockers


def validate_payload(app):
    resources = app / "Contents/Resources"
    for relative in ("Legal/LICENSE.txt", "Legal/THIRD_PARTY.txt", "Legal/publisher.json",
                     "Legal/Licenses/ONNX-Runtime-LICENSE.txt", "Legal/RustDependencies.json",
                     "OVRLEY-Source/LICENSE.md", "FFmpeg-Licenses/build-configuration.txt"):
        if not (resources / relative).is_file():
            raise ValueError(f"Missing distribution resource: {relative}. Rebuild the complete app.")
    if "{{" in (resources / "Legal/LICENSE.txt").read_text():
        raise ValueError("Unresolved license template in app.")
    for path in app.rglob("*"):
        if path.is_symlink():
            if not path.resolve().is_relative_to(app.resolve()):
                raise ValueError(f"App contains an external symlink: {path}")
            continue
        if not path.is_file():
            continue
        if path.suffix.lower() in (".p12", ".p8", ".key") or path.name in (".env",):
            raise ValueError(f"Credential-like file must not be shipped: {path}")
        if path.suffix.lower() in (".swift", ".rs", ".py", ".ts", ".js", ".c", ".h", ".sh"):
            relative = path.relative_to(resources) if path.is_relative_to(resources) else path.relative_to(app)
            if relative.parts[0] not in ("OVRLEY-Source", "ArgmaxOSS-Source"):
                raise ValueError(f"Unexpected source code in distribution: {relative}")


def notarize(path, profile, log_directory):
    # Authentication stays in Keychain, never in this script or output metadata.
    try:
        response = run("xcrun", "notarytool", "submit", path, "--keychain-profile", profile,
                       "--wait", "--timeout", "30m", "--output-format", "json", capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        (log_directory / f"{path.name}.notary-error.txt").write_text((error.stdout or "") + "\n" + (error.stderr or ""))
        raise ValueError(f"Apple submission failed or timed out. Logs: {log_directory}") from error
    try:
        result = json.loads(response.stdout)
    except json.JSONDecodeError as error:
        (log_directory / f"{path.name}.notary-response.txt").write_text(response.stdout)
        raise ValueError(f"Unrecognized Apple response. Logs: {log_directory}") from error
    (log_directory / f"{path.name}.notary.json").write_text(json.dumps(result, indent=2) + "\n")
    if result.get("status") != "Accepted":
        if result.get("id"):
            run("xcrun", "notarytool", "log", result["id"], "--keychain-profile", profile,
                log_directory / f"{path.name}.notary-log.json")
        raise ValueError(f"Apple notarization not accepted: {result.get('status')}. No release published.")
    return result["id"]


def build(args):
    env = dict(os.environ)
    if args.check or args.release:
        blockers = release_blockers(env)
        if blockers:
            print("Публичный подписанный выпуск пока недоступен:")
            for blocker in blockers:
                print("- " + blocker)
            return 1
        if args.check:
            print("Local release prerequisites found. Apple authentication and notarization are checked during release.")
            return 0
    if args.release and args.skip_build:
        raise ValueError("A public release must rebuild the complete app; --skip-build is for local packaging only.")
    packaging_python = ROOT / "Build/PackagingPython/bin/python3"
    if not packaging_python.is_file():
        raise ValueError("Install DMG build tools first: python3 -m venv Build/PackagingPython && "
                         "Build/PackagingPython/bin/python3 -m pip install -r Distribution/requirements.txt")
    run(packaging_python, "-c", "import dmgbuild, ds_store, mac_alias")
    if not args.release:
        env.pop("VELOEDIT_CODESIGN_IDENTITY", None)
    env["CONFIGURATION"] = "release"
    env["VELOEDIT_ARCHS"] = "arm64 x86_64"
    if not args.skip_build:
        run(ROOT / "Scripts/build-app.sh", env=env, cwd=ROOT)
    original = ROOT / "Build/VeloEdit.app"
    info = plistlib.loads((original / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    build_id = info["CFBundleVersion"]
    label = "" if args.release else "-local"
    architectures = subprocess.check_output(["lipo", "-archs", str(original / "Contents/MacOS/VeloEdit")], text=True).split()
    if set(architectures) != {"arm64", "x86_64"}:
        raise ValueError("The installer requires both arm64 and x86_64. Rebuild with ./Scripts/build-app.sh.")
    run("python3", ROOT / "Scripts/verify-architectures.py", original)
    architecture = "universal"
    name = f"VeloEdit-{version}-{build_id}-{architecture}{label}"
    if not re.fullmatch(r"[A-Za-z0-9._-]+", name):
        raise ValueError("Unsafe distribution filename")
    output_root = ROOT / "Build/Distribution"
    output_root.mkdir(parents=True, exist_ok=True)
    final = output_root / name
    if final.exists():
        raise ValueError(f"Artifact already exists: {final}. Rebuild for a new build number.")
    notary_logs = output_root / "NotarizationLogs" / name
    if args.release:
        # Keep diagnostics even when a failed submission discards the staging
        # directory. This directory never contains a purported release DMG.
        notary_logs.mkdir(parents=True, exist_ok=True)

    # Stage beside the destination for an atomic directory publish only after
    # all requested checks pass. A failed upload never produces a release DMG.
    with tempfile.TemporaryDirectory(prefix=".staging-", dir=output_root) as scratch:
        stage = Path(scratch)
        payload = stage / "payload"
        payload.mkdir()
        app = payload / "VeloEdit.app"
        artifacts = stage / "artifacts"
        artifacts.mkdir()
        run("ditto", original, app)
        validate_payload(app)
        run("python3", ROOT / "Scripts/sign-app.py", app,
            *(["--release"] if args.release else []), env=env)
        submissions = []
        if args.release:
            profile = env["VELOEDIT_NOTARY_PROFILE"]
            archive = stage / "VeloEdit.zip"
            run("ditto", "-c", "-k", "--keepParent", app, archive)
            submissions.append(notarize(archive, profile, notary_logs))
            run("xcrun", "stapler", "staple", app)
            run("xcrun", "stapler", "validate", app)
            run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
        instructions = (
            "Установка VeloEdit\n\n"
            "1. Перетащите VeloEdit.app на ярлык Applications.\n"
            "2. Дождитесь окончания копирования и извлеките образ диска.\n"
            "3. Откройте VeloEdit из папки «Программы».\n\n"
            f"Требования: macOS {info['LSMinimumSystemVersion']} или новее; {architecture}.\n"
            "Лицензия и сведения о сторонних компонентах: меню VeloEdit → Лицензия и компоненты.\n"
            "Удаление: удалите VeloEdit.app из «Программ». Проекты пользователя не удаляются.\n"
        )
        if not args.release:
            instructions += (
                "\nЛОКАЛЬНАЯ ТЕСТОВАЯ СБОРКА\n"
                "Приложение имеет техническую подпись ad-hoc; сертификата Developer ID и нотариализации Apple нет.\n"
                "macOS может блокировать запуск на другом компьютере. Это не готовый публичный релиз.\n"
                "Проверка условий распространения GPL/LGPL-компонентов и полного набора лицензий ещё не завершена.\n"
            )
        # Keep supplementary instructions next to the downloadable DMG. The
        # Finder window itself only contains the app and its install target;
        # all legal documents remain in the signed application bundle.
        (artifacts / "Install.txt").write_text(instructions)
        dmg = artifacts / f"VeloEdit_{version}.dmg"
        run(packaging_python, ROOT / "Scripts/package-dmg.py", app, dmg,
            "--volume-name", "VeloEdit" + (" Local" if not args.release else ""))
        run("hdiutil", "verify", dmg)
        if args.release:
            identity = env["VELOEDIT_CODESIGN_IDENTITY"]
            run("codesign", "--sign", identity, "--timestamp", dmg)
            run("codesign", "--verify", "--strict", dmg)
            submissions.append(notarize(dmg, profile, notary_logs))
            run("xcrun", "stapler", "staple", dmg)
            run("xcrun", "stapler", "validate", dmg)
            run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", dmg)
            shutil.copytree(notary_logs, artifacts / "Notarization")
        with dmg.open("rb") as stream:
            checksum = hashlib.file_digest(stream, "sha256").hexdigest()
        (artifacts / "SHA256SUMS.txt").write_text(f"{checksum}  {dmg.name}\n")
        (artifacts / "distribution.json").write_text(json.dumps({
            "version": version, "build": build_id, "architectures": architectures,
            "minimum_macos": info["LSMinimumSystemVersion"], "source_sha256": info.get("VeloEditSourceSHA256"),
            "director_model": json.loads((app / "Contents/Resources/BuildInfo.json").read_text()).get("directorModel"),
            "mode": "release" if args.release else "local",
            "application_signature": "Developer ID" if args.release else "ad-hoc",
            "disk_image_signed": args.release, "notarized": args.release,
            "notary_submissions": submissions, "sha256": checksum,
            "installer_design": json.loads((ROOT / "Distribution/Installer/layout.json").read_text()),
            "legal_review": json.loads((ROOT / "Distribution/legal-review.json").read_text()),
        }, ensure_ascii=False, indent=2) + "\n")
        artifacts.rename(final)
    print(f"Created: {final / dmg.name}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", action="store_true", help="Require Developer ID, legal review and Apple notarization")
    parser.add_argument("--check", action="store_true", help="Read-only check of release prerequisites")
    parser.add_argument("--skip-build", action="store_true", help="Package an already rebuilt app in local mode only")
    return build(parser.parse_args())


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
