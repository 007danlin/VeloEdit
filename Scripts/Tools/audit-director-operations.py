#!/usr/bin/env python3
"""Export actual typed signatures and guards; does not infer render support."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[2]
source = root / "Sources/VeloEditCore/AIDirectorEngine.swift"
text = source.read_text()
vocabulary = text.split("public enum DirectorToolCall:", 1)[1].split("public var tool:", 1)[0]
execution = text.split("for call in calls {", 1)[1].split("public struct DirectorReview", 1)[0]
branches = list(re.finditer(r"^            case \.(\w+)[^\n]*:", execution, re.M))
guards = {}
for i, match in enumerate(branches):
    body = execution[match.end():branches[i + 1].start() if i + 1 < len(branches) else len(execution)]
    guards[match[1]] = [re.sub(r"\s+", " ", g).strip() for g in re.findall(r"guard (.*?) else \{", body, re.S)]
rows = []
cards = json.loads((root / "Resources/CinematicKnowledge/cards.json").read_text())["cards"]
permitted = {command for card in cards for command in card["allowedCommands"]}
evidence_path = root / "Docs/CinematicKnowledge/typed-operation-results.json"
evidence = {row["id"]: row for row in json.loads(evidence_path.read_text())} if evidence_path.exists() else {}
for signature in re.findall(r"^    case ([^\n]+)", vocabulary, re.M):
    name = signature.split("(")[0]
    offset = text.index("    case " + signature)
    result = evidence.get(name)
    verified = result is not None and result["executed"] and isinstance(result.get("previewExportPixelError"), (float, int)) and result["previewExportPixelError"] < 0.09
    knowledge_id = "addTransition" if name == "addTransitionObject" else name
    rows.append({"id": name, "signature": signature, "source": "Sources/VeloEditCore/AIDirectorEngine.swift",
                 "line": text[:offset].count("\n") + 1, "executionGuards": guards.get(name, []),
                 "applicationAIAvailable": True, "knowledgeAIAvailable": knowledge_id in permitted,
                 "status": "execution/preview/export verified for recorded example" if verified else "registered; render/execution evidence must be checked separately",
                 "verification": result,
                 "notes": "Associated value constructors may constrain values further. Knowledge permission is a separate allowlist."})
output = root / "Docs/CinematicKnowledge/application-operations.json"
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")
print(f"Exported {len(rows)} actual typed operations")
