#!/usr/bin/env python3
"""Summarize recorded samples without excluding fallbacks or censoring timeouts.

Model-only latency is separate from latency of all user-visible outcomes.
This script does not score groundedness, naturalness, UI latency or playback.
"""
import argparse
import json
import math
import random
from pathlib import Path


def distribution(values):
    values = sorted(values)
    if not values:
        return None
    return {"n": len(values), "p50": values[math.ceil(len(values) * .50) - 1],
            "p95": values[math.ceil(len(values) * .95) - 1], "max": values[-1]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("samples", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    rows = json.loads(args.samples.read_text())
    report = {"source": str(args.samples), "quantileMethod": "nearest rank", "variants": {}}
    for name in sorted({row.get("variant", "baseline") for row in rows}):
        group = [row for row in rows if row.get("variant", "baseline") == name]
        model = [row for row in group if not row.get("fallback", False) and "Qwen" in row["runtime"]]
        report["variants"][name] = {"attempts": len(group), "modelSuccesses": len(model),
            "fallbacks": len(group) - len(model),
            "limitedWithoutGeneration": sum(row.get("fallback", False) and row["runtime"] == "Готовые данные · без модели" for row in group),
            "noEvidenceFallbacks": sum(row.get("fallback", False) and row.get("evidenceCount", 1) == 0 for row in group),
            "deadlineFallbacks": sum(row.get("fallback", False) and row["runtime"] == "Ограниченный ответ · модель не ответила" for row in group),
            "rejectedOrUnavailableFallbacks": sum(row.get("fallback", False) and row["runtime"] == "Ограниченный ответ · готовые данные" for row in group),
            "allOutcomeSeconds": distribution([row["seconds"] for row in group]),
            "modelSuccessSeconds": distribution([row["seconds"] for row in model]),
            "contextSeconds": distribution([row["contextSeconds"] for row in group if "contextSeconds" in row]),
            "atMost45Words": sum(len(row["reply"].split()) <= 45 for row in group),
            "commandsReturned": sum(row["commands"] for row in group)}
    report["limitations"] = ["Runtime study, not end-to-end UI or playback measurement.",
        "Fallbacks are included in allOutcomeSeconds, never counted as model successes.",
        "No human quality scores inferred from response length, citations or latency.",
        "Cold/warm designation must come from the run protocol, not the first sample index."]
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    pairs = {}
    for row in rows:
        pairs.setdefault((row.get("repetition", 0), row["index"]), {})[row.get("variant", "baseline")] = row
    randomizer = random.Random(6102026)
    blind, key = [], []
    for (repetition, index), pair in sorted(pairs.items()):
        if "baseline" not in pair or "new" not in pair:
            continue
        order = ["baseline", "new"]
        randomizer.shuffle(order)
        identifier = f"pair-{repetition}-{index}"
        def unrated():
            return {"momentSpecific": None, "grounded": None, "natural": None,
                    "concise": None, "factualErrors": None, "notes": ""}
        blind.append({"id": identifier, "scenario": index, "request": pair["new"]["request"],
            "A": pair[order[0]]["reply"], "B": pair[order[1]]["reply"],
            "ratings": {"A": unrated(), "B": unrated(), "preference": None}})
        key.append({"id": identifier, "A": order[0], "B": order[1]})
    if blind:
        args.output.with_name("blind-pairs.json").write_text(json.dumps(blind, ensure_ascii=False, indent=2) + "\n")
        args.output.with_name("blind-key.json").write_text(json.dumps(key, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
