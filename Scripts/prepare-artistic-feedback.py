#!/usr/bin/env python3
"""Validate version-bound human feedback without inventing preference labels.

The registry is a reviewed interpretation of the user's answers, separate
from automatic media observations. Acceptance of one revision is not a vote
against every other edit. This script prepares evidence, never trains a model.
"""
import argparse
import hashlib
import json
from pathlib import Path


KINDS = {"pairwise-preference", "conditional-preference", "reject-both",
         "accept-revision", "accept-transition"}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def prepare(root, registry, split):
    rows = []
    for entry in registry["records"]:
        assert entry["kind"] in KINDS
        record_path = root / entry["record"]
        assert digest(record_path) == entry["recordSHA256"], "Feedback version changed"
        raw = json.loads(record_path.read_text())
        projects = set(entry["sourceProjects"])
        assert projects and projects <= set(split["development"]), "Holdout feedback refused"
        assert not projects.intersection(split["holdout"]), "Holdout overlap refused"
        assert raw["project"] in projects
        assert not raw.get("usedInTraining", False), "Already-used evidence requires its training ledger"
        for media in entry["artifacts"]:
            assert digest(root / media["path"]) == media["sha256"], "Compared media changed"
        label = None
        # Only an explicit comparison under controlled conditions supplies
        # the sign of a pairwise loss. Rejections are neither ties nor wins.
        if entry["kind"] == "pairwise-preference" and entry["controlledSound"]:
            assert isinstance(raw.get("preferred"), str) and isinstance(raw.get("other"), str)
            assert raw["preferred"] != raw["other"]
            assert {raw["preferred"], raw["other"]} <= {a["variant"] for a in entry["artifacts"]}
            label = {"preferred": raw["preferred"], "other": raw["other"]}
        rows.append(dict(entry, verbatim=raw.get("verbatim", raw.get("answer")),
                         pairwiseLabel=label, usedInTraining=False))
    return dict(schemaVersion=1, records=rows,
                explicitControlledPairs=sum(r["pairwiseLabel"] is not None for r in rows),
                savedHumanRecords=len(rows), humanLabelsUsedInTraining=0,
                fitReady=False,
                missing="Content-grounded runtime features for action readability, useful route movement and composed cover/reveal. Missing is not zero quality.",
                rule="No technical auto-labels, implicit edit signals, binary acceptance or both-bad judgments converted into artistic pairwise targets.")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", type=Path, required=True)
    p.add_argument("--registry", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    a = p.parse_args()
    assert not a.output.exists(), "Keep previous evidence snapshots"
    result = prepare(a.root, json.loads(a.registry.read_text()), json.loads((a.root / "split.json").read_text()))
    result["registrySHA256"] = digest(a.registry)
    result["splitSHA256"] = digest(a.root / "split.json")
    a.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "records"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
