import Foundation
import Testing
@testable import VeloEditCore

@Suite struct EditorialBoundaryEvidenceTests {
    @Test func motionAndVisiblePersonDoNotConfirmAnAction() {
        let signals = (0..<8).map { i in
            MomentSignal(timestamp: Double(i), motion: i == 4 ? 1 : 0.25,
                         interest: 0.8, semantic: 0.8, telemetry: i == 4 ? 0.95 : 0,
                         subject: 0.95, vlm: 0.9)
        }
        let boundary = MomentBoundaryRefiner().refine(around: 4, signals: signals, sourceDuration: 12, nominalDuration: 6)
        #expect(boundary.confidence > 0.65) // Strong activity remains recorded.
        #expect(boundary.confirmedActionConfidence == 0)
        #expect(!boundary.containsProtectedCut(boundary.peakTime))
        #expect(boundary.doNotCutRanges == nil || boundary.doNotCutRanges?.isEmpty == true)
    }

    @Test func savedGenericPeakIsNotGroundTruthAndSpeechKeepsProtection() throws {
        let data = Data(#"{"anticipationStart":1,"peakTime":3,"completionEnd":5,"confidence":0.91,"evidence":["peak activity 90%","subject-tracking-confirmed action"]}"#.utf8)
        let boundary = try JSONDecoder().decode(MomentBoundary.self, from: data)
        #expect(boundary.confirmedActionConfidence == 0)
        var candidate = Candidate(assetID: UUID(), sourceStart: 0, sourceDuration: 8,
                                  scores: .init(quality: 0.9, interest: 0.8, action: 0.9, stability: 0.8),
                                  momentBoundary: boundary)
        #expect(EditorialMomentPolicy.protectedRange(EditorialUnit(candidate: candidate)) == nil)
        candidate.insights = .init(speech: .init(text: "Полная реплика", phraseStart: 0.5, phraseEnd: 7.5,
            confidence: 0.9, startsAtPhraseBoundary: true, endsAtPhraseBoundary: true))
        let protected = try #require(EditorialMomentPolicy.protectedRange(EditorialUnit(candidate: candidate)))
        #expect(protected.start == 0.5 && protected.end == 7.5)
        let explicit = MomentBoundary(anticipationStart: 1, peakTime: 3, completionEnd: 5, confidence: 0.9)
        #expect(explicit.confirmedActionConfidence == 0.9)
    }

    @Test func sharpOccludedFramesCannotBridgeAUsableRange() {
        let evidence = EditorialEvidence(samples: (0..<12).map { i in
            EditorialTemporalSample(sourceTime: Double(i), motionEnergy: 0.8, quality: 0.95,
                                    accidentalOcclusion: (4...6).contains(i) ? 0.7 : 0, confidence: 0.9)
        }, usableRange: .init(start: 0, end: 12), confidence: 0.8)
        let range = evidence.continuousUsableRange
        #expect(range.start == 7)
        #expect(range.end <= 11.05)
        #expect(range.start > 6 || range.end < 4)
    }

    @Test func usefulFastMovementAndUnknownOcclusionAreNotDiscarded() {
        var evidence = EditorialEvidence(samples: (0..<12).map {
            EditorialTemporalSample(sourceTime: Double($0), motionEnergy: 1, quality: 0.9, confidence: 0.9)
        }, usableRange: .init(start: 0, end: 12), atmosphereValue: 0.9, confidence: 0.8)
        #expect(evidence.continuousUsableRange == evidence.usableRange)
        evidence.samples[4].accidentalOcclusion = 0.9
        evidence.samples[4].confidence = 0.2
        #expect(evidence.continuousUsableRange == evidence.usableRange)
        evidence.samples[4].confidence = 0.9
        evidence.intentionalReveal = true
        #expect(evidence.continuousUsableRange == evidence.usableRange)
    }

    @Test func oldFeatureSemanticsCannotSilentlyEnableTheRanker() {
        var model = EditingDecisionRanker(schemaVersion: 1, modelID: "legacy-activity-labels",
            featureNames: EditingDecisionFeatures.names,
            weights: Array(repeating: 0, count: EditingDecisionFeatures.names.count),
            trainingDataSHA256: "fixture", labelProvenance: "test-only", validatedForDefault: false)
        #expect(!model.isValid)
        #expect(model.utility(.init(values: model.weights)) == nil)
        model.schemaVersion = EditingDecisionFeatures.schemaVersion
        #expect(model.isValid)
    }
}
