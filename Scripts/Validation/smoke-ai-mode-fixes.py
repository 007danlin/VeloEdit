"""Verify the final CLI on isolated copies, including absent-model recovery."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

root = Path(__file__).resolve().parents[2]
report_dir = root / "Local/Reports/Validation/AIModeFixes"
report_dir.mkdir(parents=True, exist_ok=True)
output = root / "Build/AIModeFixes/final-smoke"
output.mkdir(exist_ok=False)
rows = []
for case in ["fast", "balanced", "quality", "legacy-mlx", "missing-model"]:
    mode = case if case in ["fast", "balanced", "quality"] else "fast"
    source = root / "Build/AIModeFixes/short" / (mode + ".veloedit")
    package = output / (case + ".veloedit")
    package.mkdir()
    shutil.copytree(source / "Cache", package / "Cache")
    manifest = json.loads((source / "project.json").read_text())
    manifest["analyses"] = []
    manifest["analysisQueue"] = []
    if case == "legacy-mlx":
        manifest["preferences"]["advancedAISettings"] = {
            "enabled": True, "runtime": "mlx", "quantization": "8-bit",
            "modelID": "mlx-community/Qwen3-VL-2B-Instruct-8bit"}
    elif case == "missing-model":
        manifest["preferences"]["advancedAISettings"] = {
            "enabled": True, "runtime": "ollama", "quantization": "4-bit",
            "modelID": "qwen3-vl:missing-validation-model"}
    (package / "project.json").write_text(json.dumps(manifest, ensure_ascii=False))
    for attempt in range(2 if case == "missing-model" else 1):
        trace = output / f"{case}-{attempt}-traces"
        log = output / f"{case}-{attempt}.log"
        started = time.monotonic()
        with log.open("w") as stream:
            run = subprocess.run([str(root / "Build/veloedit-cli"), "analyze", str(package)],
                stdout=stream, stderr=subprocess.STDOUT,
                env=dict(os.environ, VELOEDIT_TRACE_DIRECTORY=str(trace)))
        assert run.returncode == 0, log
        result = json.loads((package / "project.json").read_text())["analyses"][0]
        evidence = result["aiExecution"]
        if case == "missing-model":
            assert not evidence["modelAvailable"], evidence
            assert evidence["plannedScenes"] > 0 and evidence["evaluatedScenes"] == 0, evidence
            assert "Проанализировано новых файлов: 1" in log.read_text(), log.read_text()
            assert "Частичный" in log.read_text() or "повтор" in log.read_text(), log.read_text()
        else:
            assert evidence["modelAvailable"], evidence
            assert evidence["evaluatedScenes"] == evidence["plannedScenes"] > 0, evidence
            assert evidence["modelQuantization"] == "Q4_K_M", evidence
            assert result["metrics"]["vlmCallCount"] == 0, result["metrics"]
            assert result["metrics"]["vlmCacheHitCount"] > 0, result["metrics"]
        row = dict(case=case, attempt=attempt + 1, seconds=time.monotonic() - started,
                   evidence=evidence, warnings=result["warnings"],
                   modelDigest=result.get("analysisModelDigest"),
                   profile=result["analysisProfileKey"], metrics=result["metrics"])
        rows.append(row)
        print(case, attempt + 1, round(row["seconds"], 3), evidence, flush=True)
(report_dir / "final-smoke.json").write_text(
    json.dumps(rows, ensure_ascii=False, indent=2) + "\n")
