import Foundation

/// Exact saved artifact, embedded so app and CLI have the same default without
/// a developer-machine path. No retraining or artistic-preference labels.
/// SHA-256 of UTF-8 payload: 8086cdaea539838a53668cd4a6cd1c56f75a9379f5d4128c85edc6b0020da355
/// validatedForDefault remains the original training metadata; activation is
/// an explicit product policy, not a new validation or training claim.
enum BundledEditingDecisionModel {
    static let data = Data(snapshot.utf8)
    private static let snapshot = #"""
{
  "schemaVersion": 2,
  "modelID": "technical-pairwise-balanced-features2-211f051b90e5",
  "featureNames": [
    "chronologyErrors",
    "repeatedSourceShare",
    "incompleteActionShare",
    "incompleteSpeechShare",
    "invalidRangeShare",
    "shortShotShare",
    "longShotShare",
    "durationVariation",
    "sourceCoverage",
    "meanSourceQuality",
    "speechEvidenceShare"
  ],
  "weights": [
    -2.3326879423916256,
    -0.6106654197700725,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0
  ],
  "trainingDataSHA256": "211f051b90e52ae3c24058c8acfb756dc650f2887c7c35ab51773649ec461b04",
  "labelProvenance": "automatic-technical-dominance",
  "validatedForDefault": false
}
"""#
}
