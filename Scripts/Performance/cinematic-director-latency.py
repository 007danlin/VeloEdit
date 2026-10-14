#!/usr/bin/env python3
"""Measure local director model prefill with actual compact knowledge samples.

Requires an already installed/running local Ollama; never pulls models. Run
after CinematicPerformanceTests with --samples pointing at its JSON report.
This measures prompt latency, not artistic response quality or full analysis.
"""
import argparse
import json
from pathlib import Path
import statistics
import time
import urllib.request


ROOT = Path(__file__).resolve().parents[2]


def request(path, body=None):
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode()
    with urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:11434" + path, data=data,
            headers={"Content-Type": "application/json"}), timeout=60) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    samples = json.loads(args.samples.read_text())["modelContextSamples"]
    model = "qwen3:4b-instruct"
    tags = request("/api/tags")["models"]
    tag = next((item for item in tags if item["name"] == model), None)
    if tag is None:
        raise SystemExit("The application's director model is not installed; no download attempted")
    source = (ROOT / "Sources/VeloEdit/DirectorAdviceRequest.swift").read_text()
    system = source.split('static let instructions = """', 1)[1].split('"""', 1)[0].strip()
    schema = {"type": "object", "properties": {
        "stance": {"type": "string", "enum": ["keep", "trim", "compare", "reorder", "clarify", "insufficientEvidence"]},
        "targetID": {"type": "string"}, "evidenceIDs": {"type": "array", "items": {"type": "string"}, "maxItems": 6},
        "reply": {"type": "string"}}, "required": ["stance", "targetID", "evidenceIDs", "reply"], "additionalProperties": False}

    def run(user):
        return request("/api/chat", {"model": model, "messages": [{"role": "system", "content": system},
            {"role": "user", "content": user}], "stream": False, "think": False, "keep_alive": "15m",
            "format": schema, "options": {"temperature": 0.2, "num_predict": 64}})

    # Exclude model loading/JIT from the paired prefill comparison; retain the
    # warm-up measurement explicitly. Unique first user tokens defeat reuse of
    # a complete previous user prompt while keeping the real system identical.
    warmup = run("Контрольный прогрев. Объясни, каких локальных наблюдений не хватает для оценки склейки.")
    rows = []
    queries = ["Хочу плёночное зерно", "Примени Rule of Thirds", "Добавь наплыв между клипами"]
    for index, name in enumerate(["baseline", "knowledge", "knowledge", "baseline", "baseline", "knowledge"]):
        query = queries[index // 2]
        context = samples.get(query)
        if context is None and query == "Хочу плёночное зерно":
            context = next(value for key, value in samples.items() if "зерно" in key)
        user = f"Проверка {index}. Запрос: {query}. Данные: локального анализа кадров нет. Это только совет."
        if name == "knowledge":
            user += "\n" + context
        start = time.monotonic()
        result = run(user)
        rows.append({"case": name, "query": query, "contextBytes": len(context.encode()) if name == "knowledge" else 0,
            "wallSeconds": time.monotonic() - start, "promptTokens": result.get("prompt_eval_count"),
            "promptSeconds": result.get("prompt_eval_duration", 0) / 1e9,
            "generationSeconds": result.get("eval_duration", 0) / 1e9, "generatedTokens": result.get("eval_count"),
            "loadSeconds": result.get("load_duration", 0) / 1e9})
    medians = {name: statistics.median(row["promptSeconds"] for row in rows if row["case"] == name)
        for name in ("baseline", "knowledge")}
    report = {"model": model, "digest": tag["digest"], "scope": "Actual app advisory system/schema and compact knowledge samples; 64 output tokens; latency only, not response-quality evaluation",
        "warmupLoadSeconds": warmup.get("load_duration", 0) / 1e9, "runs": rows, "medianPromptSeconds": medians,
        "additionalMedianPromptSeconds": medians["knowledge"] - medians["baseline"]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"medianPromptSeconds": medians, "additionalMedianPromptSeconds": report["additionalMedianPromptSeconds"]}))


if __name__ == "__main__":
    main()
