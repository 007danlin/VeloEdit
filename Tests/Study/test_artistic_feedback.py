import copy
import importlib.util
import json
import pathlib
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("feedback", pathlib.Path(__file__).parents[2] / "Scripts/prepare-artistic-feedback.py")
feedback = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feedback)


class FeedbackContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.raw = self.root / "rating.json"
        self.raw.write_text(json.dumps(dict(project=3, preferred="B", other="A", verbatim="B лучше")))
        artifacts = []
        for label in ["A", "B"]:
            path = self.root / (label + ".mp4")
            path.write_bytes(label.encode())
            artifacts.append(dict(variant=label, path=path.name, sha256=feedback.digest(path)))
        self.entry = dict(record=self.raw.name, recordSHA256=feedback.digest(self.raw),
                          sourceProjects=[3], kind="pairwise-preference", controlledSound=True,
                          artifacts=artifacts)
        self.split = dict(development=[1, 2, 3, 5, 6, 7, 8], holdout=[4, 9])

    def prepare(self, entry=None):
        return feedback.prepare(self.root, dict(records=[entry or self.entry]), self.split)

    def test_only_explicit_controlled_comparison_is_pairwise(self):
        self.assertEqual(self.prepare()["explicitControlledPairs"], 1)
        for kind in ["accept-revision", "accept-transition", "reject-both", "conditional-preference"]:
            entry = dict(self.entry, kind=kind)
            self.assertIsNone(self.prepare(entry)["records"][0]["pairwiseLabel"])
        self.assertEqual(self.prepare(dict(self.entry, controlledSound=False))["explicitControlledPairs"], 0)

    def test_media_and_record_versions_are_immutable(self):
        (self.root / "B.mp4").write_bytes(b"new edit")
        with self.assertRaisesRegex(AssertionError, "media changed"):
            self.prepare()
        self.raw.write_text("{}")
        with self.assertRaisesRegex(AssertionError, "Feedback version changed"):
            self.prepare()

    def test_cross_project_pair_cannot_hide_holdout(self):
        with self.assertRaisesRegex(AssertionError, "Holdout"):
            self.prepare(dict(self.entry, sourceProjects=[3, 9]))

    def test_saved_label_does_not_claim_training_or_model_benefit(self):
        result = self.prepare()
        self.assertFalse(result["fitReady"])
        self.assertEqual(result["humanLabelsUsedInTraining"], 0)
        self.assertFalse(result["records"][0]["usedInTraining"])


if __name__ == "__main__":
    unittest.main()
