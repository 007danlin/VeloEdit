"""Training-contract checks, independent of Swift and media processing."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ranker", ROOT / "Scripts/Studies/train-editing-ranker.py")
ranker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ranker)


def pair(project, defect):
    preferred = [0.0] * len(ranker.FEATURES)
    other = preferred.copy()
    other[defect] = 1.0
    return dict(project=project, preferred=preferred, other=other)


class TrainingContractTests(unittest.TestCase):
    def test_large_project_cannot_dominate_by_repeating_its_pairs(self):
        first, second = pair(1, 0), pair(2, 1)
        balanced = ranker.fit([first, second])
        repeated = ranker.fit([first] + [second] * 100)
        for a, b in zip(balanced, repeated):
            self.assertAlmostEqual(a, b, places=10)

    def test_later_production_comparisons_are_not_discarded(self):
        weights = ranker.fit([pair(1, 0), pair(2, 0), pair(2, 2)])
        self.assertLess(weights[2], -0.1)

    def test_technical_labels_cannot_fit_incidental_taste_correlations(self):
        row = pair(1, 0)
        row['preferred'][5:] = [1.0] * 6
        weights = ranker.fit([row])
        self.assertLess(weights[0], 0)
        self.assertEqual(weights[5:], [0.0] * 6)

    def test_training_is_reproducible(self):
        rows = [pair(1, 0), pair(2, 1), pair(2, 2)]
        self.assertEqual(ranker.fit(rows), ranker.fit(rows))


if __name__ == '__main__':
    unittest.main()
