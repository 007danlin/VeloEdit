"""Summarize saved integration evidence without invoking or downloading models."""
import collections
import datetime
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
RUN = ROOT / "Build/AIModeAudit/live-20260919"
OUT = Path(__file__).resolve().parent
rows = []
for mode in ("fast", "balanced"):
    for cache in ("cold", "warm"):
        path = RUN / f"{mode}-{cache}.json"
        if not path.exists():
            continue
        raw = json.loads(path.read_text())
        events = [json.loads(line)
                  for trace in (RUN / f"{mode}-{cache}-traces").glob("*.jsonl")
                  for line in trace.read_text().splitlines()]
        analysis = raw["analyses"]
        metrics = [item["metrics"] for item in analysis]
        evaluations = [event["fields"] for event in events if event["event"] == "vlm.evaluated"]
        parse_date = lambda value: datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        date_envelope = ((max(parse_date(m["endedAt"]) for m in metrics)
                          - min(parse_date(m["startedAt"]) for m in metrics)).total_seconds())
        row = {
            "mode": mode, "cache": cache, "exitCode": raw["exitCode"],
            "monotonicSecondsExcludingMacSleep": raw["wallSeconds"],
            "analysisDateEnvelopeSeconds": date_envelope,
            "suspendOrClockDifferenceSeconds": date_envelope - sum(m["totalDuration"] for m in metrics),
            "eventCounts": dict(collections.Counter(e["event"] for e in events)),
            "modelsResponded": sorted({e["fields"]["model"] for e in events if e["event"] == "vlm.runtime"}),
            "batchResults": evaluations,
            "decodedFrames": sum(m["decodedFrameCount"] for m in metrics),
            "frameCacheHits": sum(m["frameCacheHitCount"] for m in metrics),
            "visionCalls": sum(m["visionCallCount"] for m in metrics),
            "vlmCallsIncludingFailures": sum(m["vlmCallCount"] for m in metrics),
            "vlmCacheHits": sum(m.get("vlmCacheHitCount", 0) for m in metrics),
            "appliedJudgements": sum(a.get("deepAnalyzedCandidateCount", 0) for a in analysis),
            "assets": [{
                "id": a["assetID"], "sampledFrames": a.get("sampledFrameCount"),
                "judgedCandidates": a.get("deepAnalyzedCandidateCount"),
                "proxy": a.get("usedProxy"), "audioAnalyzed": a.get("audioAnalysis") is not None,
                "runtime": a.get("aiRuntimeLabel"), "warnings": a.get("warnings"),
                "modelDigest": a.get("analysisModelDigest"),
                "transcribedCandidates": a.get("deepMediaDiagnostics", {}).get("transcribedCandidateCount"),
            } for a in analysis],
        }
        rows.append(row)
for mode in ("fast", "balanced"):
    pair = [row for row in rows if row["mode"] == mode]
    if len(pair) == 2:
        cold, warm = pair
        identities = lambda row: sorted(result["inputSHA256"] for result in row["batchResults"])
        warm["sameValidatedBatchInputsAsCold"] = identities(cold) == identities(warm)
(OUT / "analysis-summary.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")
for row in rows:
    print(json.dumps({key: row[key] for key in (
        "mode", "cache", "monotonicSecondsExcludingMacSleep", "analysisDateEnvelopeSeconds",
        "modelsResponded", "decodedFrames", "vlmCallsIncludingFailures", "vlmCacheHits", "appliedJudgements"
    )}, ensure_ascii=False))
