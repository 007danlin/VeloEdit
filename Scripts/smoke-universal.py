#!/usr/bin/env python3
"""Run both native slices, model selection, speech loading and media conversion."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def run(arch, executable, *arguments):
    return subprocess.run(["/usr/bin/arch", "-" + arch, str(executable), *map(str, arguments)],
                          capture_output=True, text=True, check=True, timeout=90)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    results = {}
    with tempfile.TemporaryDirectory(prefix="veloedit-universal-smoke-") as temporary:
        for arch in ("arm64", "x86_64"):
            info = json.loads(run(arch, app / "Contents/MacOS/VeloEdit", "--self-check").stdout)
            assert info["architecture"] == arch, info
            assert info["directorModel"] == "qwen3:4b-instruct", info
            speech = json.loads(run(arch, app / "Contents/MacOS/VeloEditSpeechWorker", "--self-check").stdout)
            assert speech["architecture"] == arch, speech
            bridge = json.loads(run(arch, app / "Contents/MacOS/VeloEditOVRLEY", "health").stdout)
            assert bridge["ok"] and bridge["result"]["ready"], bridge
            runtime = run(arch, app / "Contents/Resources/Ollama/ollama", "--version")
            video = Path(temporary) / f"{arch}.mp4"
            run(arch, app / "Contents/Helpers/ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=12", "-f", "lavfi", "-i", "sine=frequency=440",
                "-t", "1", "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-movflags", "+faststart", video)
            media = json.loads(run(arch, app / "Contents/Helpers/ffprobe", "-v", "error", "-show_streams",
                                   "-of", "json", video).stdout)
            codecs = [stream["codec_name"] for stream in media["streams"]]
            assert "h264" in codecs and "aac" in codecs, media
            run(arch, app / "Contents/Helpers/ffmpeg", "-v", "error", "-i", video, "-f", "null", "-")
            results[arch] = {"application": info, "speech": speech, "ovrley": "ready",
                             "ollama": (runtime.stdout + runtime.stderr).strip(), "video_codecs": codecs}
            print(f"{arch}: app, Qwen configuration, speech, OVRLEY, Ollama, H.264/AAC encode+decode passed.", flush=True)
    results["coverage"] = "Intel slice executed through Rosetta on Apple silicon; physical Intel GPU and model inference require an Intel Mac."
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
