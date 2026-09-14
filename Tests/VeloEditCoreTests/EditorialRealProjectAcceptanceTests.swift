import Foundation
import Testing
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import VeloEditCore

/// Opt-in local acceptance runner; only copies prepared under the workspace
/// are opened. No private paths, project IDs or names enter production logic.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_EDITORIAL_QA_ROOT"] != nil))
func editorialRealProjectAcceptanceOnCopies() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["VELOEDIT_EDITORIAL_QA_ROOT"])
    let root = URL(fileURLWithPath: path)
    struct Input: Decodable { var contract: String; var copy: String }
    struct Result: Codable {
        var contract: String
        var status: String
        var originalDuration: Double?
        var duration: Double?
        var primaryCount: Int?
        var titleCount: Int?
        var originalAudioVolume: Double?
        var seconds: Double
        var review: EditorialReview?
        var reason: String?
    }
    let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: root.appendingPathComponent("inputs.json")))
    let selected = ProcessInfo.processInfo.environment["VELOEDIT_EDITORIAL_QA_CONTRACTS"]
    var results = (try? JSONDecoder.veloEdit.decode([Result].self, from: Data(contentsOf: root.appendingPathComponent("results.json")))) ?? []
    for input in inputs.sorted(by: { $0.contract < $1.contract }) where selected == nil || selected!.split(separator: ",").contains(Substring(input.contract)) {
        results.removeAll { $0.contract == input.contract }
        let package = URL(fileURLWithPath: input.copy).standardizedFileURL
        #expect(package.path.hasPrefix(root.standardizedFileURL.path + "/"))
        guard package.path.hasPrefix(root.standardizedFileURL.path + "/") else { continue }
        let store = try ProjectStore(open: package)
        let initial = await store.manifest
        let started = Date()
        let pipeline = VeloEditPipeline(store: store, renderedProber: RecordingEditorialQAProber(), musicSelectionHistory: LocalMusicSelectionHistoryStore(url: root.appendingPathComponent("music-history.json")), personalTasteStore: LocalPersonalTasteStore(url: root.appendingPathComponent("taste.json")))
        let prompt = initial.workspaceState?.prompt ?? initial.storyPlans.last?.prompt ?? "Создай фильм"
        do {
            let timeline = try await pipeline.createFilm(prompt: prompt, preset: initial.workspaceState?.preset ?? .story, targetDuration: initial.workspaceState?.directorBrief?.requestedDuration, directorBrief: initial.workspaceState?.directorBrief)
            #expect(timeline.editorialReview?.productionEligible == true)
            #expect(timeline.editorialReview?.blockingUnknowns.isEmpty == true)
            if let budget = timeline.editorialReview?.duration?.budget {
                #expect(timeline.duration + 2 / timeline.frameRate >= budget.safeRange.lowerBound)
                #expect(timeline.duration <= budget.absoluteCeiling + 2 / timeline.frameRate)
            }
            if input.contract == "B" || input.contract == "C" {
                #expect(timeline.effectiveOriginalAudioVolume == 0)
                #expect(timeline.effectiveAudioClips.isEmpty)
                #expect(timeline.width * 16 == timeline.height * 9)
            }
            results.append(Result(contract: input.contract, status: "committed", originalDuration: initial.timelines.last?.duration, duration: timeline.duration, primaryCount: timeline.items.filter { $0.overlay == nil && $0.kind != .title }.count, titleCount: timeline.effectiveTitleItems.count, originalAudioVolume: timeline.effectiveOriginalAudioVolume, seconds: Date().timeIntervalSince(started), review: timeline.editorialReview))
        } catch {
            let current = await store.manifest
            #expect(current.timelines.last?.id == initial.timelines.last?.id)
            #expect(current.intentLedger?.hasRecoverableGeneration == true)
            results.append(Result(contract: input.contract, status: "recoverableFailure", originalDuration: initial.timelines.last?.duration, seconds: Date().timeIntervalSince(started), reason: error.localizedDescription))
            Issue.record("Contract \(input.contract) did not create a passing film: \(error.localizedDescription)")
        }
        let encoder = JSONEncoder.veloEdit
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: root.appendingPathComponent("results.json"), options: .atomic)
    }
}

private struct RecordingEditorialQAProber: EditorialRenderedProbing {
    func frames(timeline: Timeline, assets: [MediaAsset], tracks: [LocalMusicTrack], telemetry: [UUID: TelemetrySummary], cacheURL: URL) async throws -> [PerceptualRenderedFrameEvidence] {
        let directory = cacheURL.appendingPathComponent("QACompositions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder.veloEdit.encode(timeline).write(to: directory.appendingPathComponent("\(timeline.id).json"), options: .atomic)
        return try await LocalEditorialRenderedProber().frames(timeline: timeline, assets: assets, tracks: tracks, telemetry: telemetry, cacheURL: cacheURL)
    }
}

/// Visual QA is deliberately separate from acceptance assertions. These sheets
/// display real compositor output; they are not semantic fixtures or ratings.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_EDITORIAL_QA_ROOT"] != nil))
func editorialRealProjectContactSheetsOnCopies() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["VELOEDIT_EDITORIAL_QA_ROOT"])
    let root = URL(fileURLWithPath: path)
    struct Input: Decodable { var contract: String; var copy: String }
    let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: root.appendingPathComponent("inputs.json")))
    for input in inputs {
        let package = URL(fileURLWithPath: input.copy).standardizedFileURL
        try #require(package.path.hasPrefix(root.standardizedFileURL.path + "/"))
        let manifest = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: package.appendingPathComponent("project.json")))
        guard var timeline = manifest.timelines.last, timeline.editorialReview != nil else { continue }
        let ratio = Double(timeline.width) / Double(timeline.height)
        timeline.height = ratio < 1 ? 640 : 360
        timeline.width = Int(Double(timeline.height) * ratio / 2) * 2
        let tracks = try await LocalMusicLibrary(rootURL: package.appendingPathComponent("MusicLibrary")).tracks()
        let telemetry = Dictionary(uniqueKeysWithValues: manifest.analyses.compactMap { result in result.telemetry.map { (result.assetID, $0) } })
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: manifest.assets, musicTracks: tracks, telemetry: telemetry, derivedMediaCacheURL: package.appendingPathComponent("Cache/Preview/DerivedMedia"), forceVideoComposition: true)
        let generator = AVAssetImageGenerator(asset: playback.composition)
        generator.videoComposition = playback.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let times = (timeline.items.filter { $0.overlay == nil && $0.kind != .title }.map { $0.timelineStart + $0.timelineDuration / 2 } + timeline.effectiveTitleItems.map { $0.startTime + $0.duration / 2 }).sorted()
        let cellWidth = 360, cellHeight = ratio < 1 ? 640 : 220, columns = 3
        let rows = (times.count + columns - 1) / columns
        let context = try #require(CGContext(data: nil, width: columns * cellWidth, height: rows * cellHeight, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: columns * cellWidth, height: rows * cellHeight))
        for (index, time) in times.enumerated() {
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let height = min(Double(cellHeight), Double(cellWidth) / ratio)
            let width = height * ratio
            context.draw(image, in: CGRect(x: Double(index % columns * cellWidth) + (Double(cellWidth) - width) / 2, y: Double((rows - 1 - index / columns) * cellHeight) + (Double(cellHeight) - height) / 2, width: width, height: height))
        }
        let image = try #require(context.makeImage())
        let output = root.appendingPathComponent("\(input.contract)-contact-sheet.png")
        let destination = try #require(CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        try JSONEncoder().encode(times).write(to: root.appendingPathComponent("\(input.contract)-probe-times.json"), options: .atomic)
    }
}
