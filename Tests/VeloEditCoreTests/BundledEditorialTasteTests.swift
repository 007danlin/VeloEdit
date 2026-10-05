import Foundation
import Testing
@testable import VeloEditCore

@Suite struct BundledEditorialTasteTests {
    @Test func freshInstallHasBaseButNoFabricatedPersonalHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("taste.json")
        let store = LocalPersonalTasteStore(url: url)
        let raw = await store.profile()
        #expect(raw.totalSignalCount == 0 && raw.preferences.isEmpty)
        let effective = BundledEditorialTaste.resolving(raw)
        #expect(effective.adaptiveConfidence > 0)
        #expect(effective.estimate(for: "transitionIntensity").mean == BundledEditorialTaste.profile.estimate(for: "transitionIntensity").mean)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let update = try await store.record([.init(feature: "transitionIntensity", value: 1, confidence: 1, source: .manualEdit)])
        #expect(update.totalSignalCount == 1)
        #expect(update.preferences.count == 1)
        let learned = BundledEditorialTaste.resolving(update)
        #expect(learned.adaptiveEstimate(for: "transitionPreference")!.value > 0)
        #expect(effective.adaptiveEstimate(for: "transitionPreference")!.value < 0)
        let persisted = try JSONDecoder.veloEdit.decode(PersonalTasteProfile.self, from: Data(contentsOf: url))
        #expect(persisted.totalSignalCount == 1)
        let reset = try await store.reset()
        #expect(reset.totalSignalCount == 0)
        #expect(BundledEditorialTaste.resolving(reset).preferences == effective.preferences)
    }

    @Test func localAndLegacyFeaturesOverrideOnlyTheirOwnBaselineFields() {
        var local = PersonalTasteProfile(preferences: ["transitionIntensity": .init(mean: 0.9, evidenceWeight: 1, confidence: 0.5)], totalSignalCount: 1)
        local.musicTaste = MusicTasteProfile(energy: .init(value: -0.5, confidence: 0.8, sampleCount: 1))
        let result = BundledEditorialTaste.resolving(local)
        #expect(result.adaptiveEstimate(for: "transitionPreference")?.value == 0.9)
        #expect(result.musicTaste?.energy?.value == -0.5)
        #expect(result.musicTaste?.beatSync == BundledEditorialTaste.profile.musicTaste?.beatSync)
        #expect(result.estimate(for: "titleAnimation") == BundledEditorialTaste.profile.estimate(for: "titleAnimation"))
        #expect(BundledEditorialTaste.resolving(result) == result)
        #expect(local.preferences.count == 1 && local.totalSignalCount == 1)
    }

    @Test func baseActuallyChangesDirectorDefaultsAndRespectsExplicitDuration() {
        let assets = (0..<20).map { index in
            MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/base-test-\(index).mp4"), kind: .video,
                byteSize: 1, contentHash: "test-\(index)", metadata: .init(duration: 30, frameRate: 30))
        }
        let analyses = assets.enumerated().map { index, asset in
            AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [
                Candidate(assetID: asset.id, sourceStart: 2, sourceDuration: 10,
                    scores: .init(quality: 0.9, interest: 0.9, action: 0.4, stability: 0.9, uniqueness: 0.95),
                    tags: ["scene-\(index)"], insights: .init(storyValue: 0.9, semanticEventID: "event-\(index)"),
                    momentBoundary: .init(anticipationStart: 2, peakTime: 6, completionEnd: 12, confidence: 0.9))
            ])
        }
        let decision = AutonomousDirectorEngine().decide(prompt: "Поездка", fallbackPreset: .story,
            requestedDuration: 75, assets: assets, analyses: analyses, personalProfile: PersonalTasteProfile(), requestIsExplicit: true)
        #expect(decision.duration.seconds == 75)
        #expect((decision.personalSignalAdjustments?["transitionIntensity"] ?? 0) < 0)
        #expect(decision.explanations.contains { $0.contains(BundledEditorialTaste.version) && $0.contains("личных сигналов: 0") })
    }

    @Test func shippedBaseContainsOnlyAggregateStyle() throws {
        let base = BundledEditorialTaste.profile
        #expect(base.contextualPreferences.isEmpty)
        #expect(base.embeddingTaste == nil && base.regressionSamples == nil)
        #expect(base.approvedReferenceFingerprints == nil && base.structurePatterns == nil)
        let encoded = String(decoding: try JSONEncoder.veloEdit.encode(base), as: UTF8.self)
        #expect(!encoded.contains("/Users/") && !encoded.contains(".MP4") && !encoded.contains(".veloedit"))
    }
}
