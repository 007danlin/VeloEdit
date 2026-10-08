"""Validate completed real runs. No model calls or source-project writes."""
import collections
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
report_dir = root / "Local/Reports/Validation/AIModeFixes"
report_dir.mkdir(parents=True, exist_ok=True)
rows = []
for label in sys.argv[1:] or ["short", "maximum", "calm", "first-original"]:
    folder = root / "Build/AIModeFixes" / label
    paths = sorted(folder.glob("*.json"))
    assert paths, f"No recorded runs in {folder}"
    for path in paths:
        run = json.loads(path.read_text())
        events = [json.loads(line) for trace in (folder / (path.stem + "-traces")).glob("*.jsonl")
                  for line in trace.read_text().splitlines()]
        analyses = run["analyses"]
        assert run["exitCode"] == 0, path
        assert analyses, path
        for analysis in analyses:
            evidence = analysis["aiExecution"]
            assert evidence["visualAnalysisCompleted"] and evidence["audioAnalysisCompleted"], (path, evidence)
            assert evidence["modelAvailable"], (path, evidence)
            assert evidence["plannedScenes"] > 0, (path, evidence)
            assert evidence["evaluatedScenes"] == evidence["plannedScenes"], (path, evidence)
            assert evidence["evaluatedRechecks"] == evidence["plannedRechecks"], (path, evidence)
            if run["mode"] == "maximum":
                assert evidence["plannedRechecks"] > 0, (path, evidence)
            assert analysis["analysisModelDigest"], path
        failures = [event for event in events if event["event"] == "vlm.failed"]
        assert not failures, (path, failures)
        if run["cache"] == "cold" or run["mode"] == "maximum":
            assert any(e["event"] == "vlm.runtime" for e in events), path
        if run["mode"] == "maximum":
            assert any(e["event"] == "vlm.recheck-completed" for e in events), path
        row = {
            "label": label, "mode": run["mode"], "cache": run["cache"], "seconds": run["wallSeconds"],
            "eventCounts": dict(collections.Counter(e["event"] for e in events)),
            "modelsResponded": sorted({e["fields"]["model"] for e in events if e["event"] == "vlm.runtime"}),
            "failures": failures,
            "sampledFrames": sum(a.get("sampledFrameCount", 0) for a in analyses),
            "decodedFrames": sum(a["metrics"]["decodedFrameCount"] for a in analyses),
            "vlmAttempts": sum(a["metrics"]["vlmCallCount"] for a in analyses),
            "vlmCacheHits": sum(a["metrics"].get("vlmCacheHitCount", 0) for a in analyses),
            "evidence": [a["aiExecution"] for a in analyses],
            "thermal": sorted({t for a in analyses for t in a["metrics"]["thermalStates"]}),
            "warnings": [w for a in analyses for w in a["warnings"]],
            "speechStages": [stage for a in analyses for stage in a.get("deepMediaDiagnostics", {}).get("stages", [])
                             if stage["stage"] == "asr"],
        }
        rows.append(row)
        print(label, run["mode"], run["cache"], round(run["wallSeconds"], 3),
              "attempts", row["vlmAttempts"], "cache", row["vlmCacheHits"],
              "judgements", sum(e["evaluatedScenes"] for e in row["evidence"]),
              "rechecks", sum(e["evaluatedRechecks"] for e in row["evidence"]))
(report_dir / "live-summary.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")
