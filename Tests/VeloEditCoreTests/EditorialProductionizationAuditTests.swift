import Foundation
import Testing
@testable import VeloEditCore

/// A negative audit of previously accepted QA copies. It is deliberately not
/// positive production acceptance: every independent domain is reported, and
/// known low-duration/quiet-output defects must be detected without relying on
/// the previous gate's own productionEligible flag.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_EDITORIAL_V2_AUDIT_ROOT"] != nil))
func editorialProductionizationAudit() async throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_EDITORIAL_V2_AUDIT_ROOT"]))
    struct Input: Decodable { var contract: String; var copy: String }
    struct Audit: Codable {
        var contract: String
        var duration: Double
        var shotCount: Int
        var lowerBound: Double?
        var upperBound: Double?
        var seconds: Double
        var review: EditorialReview
        var humanReviewPerformed: Bool = false
        var originalsModified: Bool = false
    }
    let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: root.appendingPathComponent("inputs.json")))
    var results: [Audit] = []
    for input in inputs.sorted(by: { $0.contract < $1.contract }) {
        let package = URL(fileURLWithPath: input.copy).resolvingSymlinksInPath()
        try #require(package.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"))
        let data = try Data(contentsOf: package.appendingPathComponent("project.json"))
        let manifest = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: data)
        var timeline = try #require(manifest.timelines.last)
        let plan = try #require(manifest.storyPlans.last { $0.id == timeline.storyPlanID })
        let started = Date()
        let tracks = try await LocalMusicLibrary(rootURL: package.appendingPathComponent("MusicLibrary")).tracks()
        let telemetry = Dictionary(uniqueKeysWithValues: manifest.analyses.compactMap { analysis in analysis.telemetry.map { (analysis.assetID, $0) } })
        timeline.editorialReview = nil
        let frames = try await LocalEditorialRenderedProber().frames(timeline: timeline, assets: manifest.assets, tracks: tracks, telemetry: telemetry, cacheURL: package.appendingPathComponent("Cache/V2Audit"))
        let review = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: manifest.analyses, renderedFrames: frames, requireRenderedEvidence: true, musicTracks: tracks)
        #expect(!review.productionEligible)
        #expect(!review.blockingUnknowns.isEmpty)
        if let minimum = plan.contentBudget?.budget.safeRange.lowerBound, timeline.duration + 0.1 < minimum {
            #expect(review.findings.contains { $0.kind == .durationUnderflow })
            #expect(review.duration?.requiresExpandedMining == true)
        }
        let loudness = frames.compactMap(\.exportVerification).first?.encodedAudio?.outputLUFS
        let truePeak = frames.compactMap(\.exportVerification).first?.encodedAudio?.outputTruePeakDBTP
        if let loudness, !EditorialLoudnessPolicy.accepts(lufs: loudness, truePeak: truePeak) {
            #expect(review.evidenceDomains?.first { $0.domain == .integratedLoudness }?.status == .failed)
        }
        #expect(try Data(contentsOf: package.appendingPathComponent("project.json")) == data)
        results.append(.init(contract: input.contract, duration: timeline.duration, shotCount: timeline.items.filter { $0.overlay == nil && $0.kind != .title }.count, lowerBound: plan.contentBudget?.budget.safeRange.lowerBound, upperBound: plan.contentBudget?.budget.safeRange.upperBound, seconds: Date().timeIntervalSince(started), review: review))
        let encoder = JSONEncoder.veloEdit
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: root.appendingPathComponent("v2-negative-audit.json"), options: .atomic)
    }
}
