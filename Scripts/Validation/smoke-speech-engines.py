#!/usr/bin/env python3
"""Offline inference/resume check for both bundled speech engines.

Pass a short, clearly spoken fixture. The x86_64 run on Apple silicon uses
Rosetta and does not establish physical Intel/macOS 15 hardware coverage.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--app", type=Path, default=Path("Build/VeloEdit.app"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-arm64", type=Path)
    parser.add_argument("--maximum-cpu-alignment-drift", type=float)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    app = args.app.resolve()
    worker = app / "Contents/MacOS/VeloEditSpeechWorker"
    package = app / "Contents/Resources/Speech/ModelsPackage"
    source = args.fixture.resolve()
    results = {}
    for arch, engine in (("x86_64", "whisper.cpp-1.8.3-cpu-q5_0-v1"), ("arm64", "whisperkit-f4e5d6b-coreml-v4")):
        folder = (args.output / arch).resolve()
        folder.mkdir()
        transcript_file = folder / "transcript.json"
        request = dict(sourceURL=source.as_uri(), packageURL=package.as_uri(),
                       cacheURL=(folder / "chunks").as_uri(), outputURL=transcript_file.as_uri(),
                       locale="ru", sourceHash=hashlib.sha256(source.read_bytes()).hexdigest())
        request_file = folder / "request.json"
        request_file.write_text(json.dumps(request))
        command = ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
                   "/usr/bin/arch", "-" + arch, str(worker), str(request_file)]
        start = time.monotonic()
        for resumed in (False, True):
            log_file = folder / ("resume.log" if resumed else "worker.log")
            with log_file.open("w") as log:
                subprocess.run(command, stdout=log, stderr=log, check=True, timeout=900)
            raw = transcript_file.read_bytes()
            assert hashlib.sha256(raw).hexdigest() == transcript_file.with_suffix(".json.sha256").read_text()
            transcript = json.loads(raw)
            assert transcript["status"] == "ready", transcript["status"]
            assert transcript["words"] and transcript["sentences"], "No accepted speech"
            assert transcript["provenance"]["runtime"] == engine, transcript["provenance"]
            assert bool(transcript["runtimeMetrics"]["resumedChunks"]) == resumed
            assert all(w["startTime"] >= 0 and w["duration"] > 0 for w in transcript["words"])
            if resumed:
                assert first["words"] == transcript["words"], "Resume changed words/times"
            else:
                first = transcript
                results[arch] = dict(words=len(first["words"]), runtime=engine,
                                     metrics=first["runtimeMetrics"], text=first["rawText"])
            if arch == "x86_64":
                assert "Loading whisper.cpp CPU model" in log_file.read_text()
                assert "Loading WhisperKit models" not in log_file.read_text()
                assert first["provenance"]["alignment"] == "whisper.cpp-dtw-word-v1"
        results[arch]["totalSecondsWithResume"] = round(time.monotonic() - start, 2)
        if arch == "arm64" and args.baseline_arm64:
            baseline = json.loads(args.baseline_arm64.read_text())
            assert baseline["words"] == first["words"], "ARM word/timestamp regression"
            results[arch]["baselineMatches"] = True
        if arch == "x86_64" and args.maximum_cpu_alignment_drift is not None:
            assert args.baseline_arm64, "Alignment comparison needs a matching reference transcript"
            reference = json.loads(args.baseline_arm64.read_text())["words"]
            normalize = lambda word: word["text"].strip(".,!?…").casefold()
            assert list(map(normalize, reference)) == list(map(normalize, first["words"])), "Fixture words differ"
            drift = max(abs(actual["startTime"] - expected["startTime"])
                        for actual, expected in zip(first["words"], reference))
            assert drift <= args.maximum_cpu_alignment_drift, ("Word alignment drift", drift)
            results[arch]["maximumStartDriftSeconds"] = drift
        print(arch, json.dumps(results[arch], ensure_ascii=False), flush=True)
    results["coverage"] = "Real offline inference and resume; x86_64 via Rosetta, physical Intel still requires verification."
    (args.output / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
