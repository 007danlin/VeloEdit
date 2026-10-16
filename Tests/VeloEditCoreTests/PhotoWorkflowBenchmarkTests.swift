import Foundation
import Testing
import AVFoundation
import CoreImage
@testable import VeloEditCore

/// Opt-in read-only source benchmark; all generated caches/reports stay in a fresh temporary directory.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_PHOTO_BENCHMARK"] != nil))
func photoWorkflowBenchmark() async throws {
    let input = try #require(ProcessInfo.processInfo.environment["VELOEDIT_PHOTO_BENCHMARK"])
    let project = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
    let draft = try #require(project.filmBuildRecovery?.draft)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-benchmark-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let profile = AIAnalysisProfile.resolve(mode: .fast, thermalState: .nominal)
    let analyzer = AdaptiveLocalAnalyzer(profile: profile)
    let cache = FrameCache(rootURL: root.appendingPathComponent("Frames"))
    let evidence = LocalEditorialEvidenceAnalyzer(cacheURL: root)
    struct Row: Codable { var phase: String; var seconds: Double; var photos: Int; var selectedPhotos: Int; var minimumHold: Double; var duration: Double; var visionCalls: Int; var renderSeconds: Double? = nil; var technicalFailures: [String]? = nil }
    var rows: [Row] = []
    for warm in [false, true] {
        let start = Date()
        var results: [AnalysisResult] = []
        var visionCalls = 0
        for asset in project.assets where asset.kind == .photo {
            let recorder = AnalysisMetricsRecorder(mode: .fast, metadata: asset.metadata)
            var result = try await analyzer.analyze(asset: asset, analysisURL: asset.originalURL, usedProxy: false, frameCache: cache, metrics: recorder)
            visionCalls += await recorder.snapshot().visionCallCount
            for i in result.candidates.indices {
                let measured = try await evidence.analyze(candidate: result.candidates[i], asset: asset)
                result.candidates[i].insights?.editorialEvidence = measured
            }
            results.append(result)
        }
        let analysisSeconds = Date().timeIntervalSince(start)
        for kind in ["photos", "mixed", "video"] {
            let assets = project.assets.filter { kind == "mixed" || ($0.kind == .photo) == (kind == "photos") }
            let ids = Set(assets.map(\.id))
            var timeline = draft.timeline
            timeline.items.removeAll { !ids.contains($0.assetID ?? UUID()) }
            let analyses = results.filter { ids.contains($0.assetID) }
            // Keep original video evidence without issuing another model request.
            let video = draft.analyses.filter { a in assets.contains { $0.id == a.assetID && $0.kind == .video } }
            var assembled = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: draft.plan, analyses: analyses + video, events: draft.events, assets: assets)
            if warm, let data = try? Data(contentsOf: root.appendingPathComponent("false-\(kind).json")) {
                assembled.timeline = try JSONDecoder.veloEdit.decode(Timeline.self, from: data)
            }
            var renderSeconds: Double? = nil
            var failures: [String]? = nil
            if ProcessInfo.processInfo.environment["VELOEDIT_PHOTO_BENCHMARK_RENDER"] == "1" {
                let renderStart = Date()
                let reviewed = try await PhotoTimelineReview.review(assembled.timeline, assets: assets, repairFraming: true, progress: nil)
                assembled.timeline = reviewed.timeline
                // Keep the actual selected soundtrack. No music discovery or downloads.
                let frames = try await LocalEditorialRenderedProber().frames(timeline: assembled.timeline, assets: assets,
                    tracks: draft.tracks, telemetry: [:], cacheURL: root.appendingPathComponent(kind))
                assembled.timeline.editorialReview = EditorialQualityGate().review(timeline: assembled.timeline, plan: assembled.plan,
                    analyses: analyses + video, renderedFrames: frames, requireRenderedEvidence: true)
                failures = AutomaticFilmDelivery.technicalFailures(timeline: assembled.timeline)
                renderSeconds = Date().timeIntervalSince(renderStart)
            }
            try JSONEncoder.veloEdit.encode(assembled.timeline).write(to: root.appendingPathComponent("\(warm)-\(kind).json"))
            let photos = assembled.timeline.items.filter { $0.kind == .photo }
            rows.append(Row(phase: "\(warm ? "warm" : "cold")-\(kind)", seconds: analysisSeconds, photos: results.count, selectedPhotos: photos.count, minimumHold: photos.map(\.timelineDuration).min() ?? 0, duration: assembled.timeline.duration, visionCalls: visionCalls, renderSeconds: renderSeconds, technicalFailures: failures))
        }
    }
    let encoder = JSONEncoder.veloEdit
    try encoder.encode(rows).write(to: root.appendingPathComponent("results.json"))
    print("PHOTO_BENCHMARK \(root.path) \(String(data: try encoder.encode(rows), encoding: .utf8)!)")
}

/// Rechecks previously assembled benchmark timelines using the current render path.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_PHOTO_RECHECK"] != nil))
func photoWorkflowRenderedRecheck() async throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_PHOTO_RECHECK"]))
    let input = try #require(ProcessInfo.processInfo.environment["VELOEDIT_PHOTO_RECHECK_PROJECT"])
    let project = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
    let draft = try #require(project.filmBuildRecovery?.draft)
    let output = ProcessInfo.processInfo.environment["VELOEDIT_PHOTO_RECHECK_CACHE"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("photo-recheck-\(UUID())")
    for kind in ["video", "mixed", "photos"] {
        var timeline = try JSONDecoder.veloEdit.decode(Timeline.self, from: Data(contentsOf: root.appendingPathComponent("false-\(kind).json")))
        let frames = try await LocalEditorialRenderedProber().frames(timeline: timeline, assets: project.assets,
            tracks: draft.tracks, telemetry: [:], cacheURL: output.appendingPathComponent(kind))
        timeline.editorialReview = EditorialQualityGate().review(timeline: timeline, plan: draft.plan,
            analyses: draft.analyses, renderedFrames: frames, requireRenderedEvidence: true)
        let failures = AutomaticFilmDelivery.technicalFailures(timeline: timeline)
        try JSONEncoder.veloEdit.encode(timeline).write(to: output.appendingPathComponent("\(kind).json"))
        print("PHOTO_RECHECK \(kind) \(output.path) failures=\(failures)")
        #expect(failures.isEmpty)
    }
}
