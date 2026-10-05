import Foundation
import Testing
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import VeloEditCore

/// Opt-in, read-only replay of an existing composition against its actual MP4.
/// Uses the same native frame generator and fingerprint as production review.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_RELIABILITY_PARITY_INPUT"] != nil))
func inspectSavedReliabilityParity() async throws {
    let env = ProcessInfo.processInfo.environment
    let input = try #require(env["VELOEDIT_RELIABILITY_PARITY_INPUT"])
    let root = URL(fileURLWithPath: try #require(env["VELOEDIT_RELIABILITY_PARITY_OUTPUT"]))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    struct Input: Decodable { var timeline: Timeline; var assets: [MediaAsset]; var tracks: [LocalMusicTrack]; var exportURL: URL; var times: [Double] }
    let data = try JSONDecoder.veloEdit.decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
    let timeline = data.timeline
    let playback = try await PlaybackEngine().build(timeline: timeline, assets: data.assets, musicTracks: data.tracks,
        derivedMediaCacheURL: root.appendingPathComponent("DerivedMedia"), forceVideoComposition: true)
    func generator(_ asset: AVAsset, composition: AVVideoComposition? = nil) -> AVAssetImageGenerator {
        let g = AVAssetImageGenerator(asset: asset)
        g.videoComposition = composition; g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 640, height: 640)
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        return g
    }
    func save(_ image: CGImage, _ name: String) throws {
        let d = try #require(CGImageDestinationCreateWithURL(root.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(d, image, nil); #expect(CGImageDestinationFinalize(d))
    }
    struct Probe: Encodable { var timelineTime: Double; var requested: Double; var nativePTS: Double; var exportRequested: Double; var exportPTS: Double; var mae: Double; var luma: Double }
    var probes: [Probe] = []
    let native = generator(playback.composition, composition: playback.videoComposition)
    let encoded = generator(AVURLAsset(url: data.exportURL))
    defer { native.cancelAllCGImageGeneration(); encoded.cancelAllCGImageGeneration() }
    for time in data.times {
        let requested = TimelineTiming.playbackTime(forTimelineTime: time, timeline: timeline)
        let sampleTime = VideoFrameTiming.sampleTime(for: requested, frameRate: timeline.frameRate, duration: playback.duration)
        let frame = try await native.image(at: sampleTime)
        let pixels = PerceptualRenderInspector.lumaFingerprint(frame.image)
        let quality = FrameQualityInspector.assess(image: frame.image)
        try save(frame.image, "native-\(time)")
        for delta in [0.0] {
            let output = try await encoded.image(at: sampleTime)
            let other = PerceptualRenderInspector.lumaFingerprint(output.image)
            let mae = zip(pixels, other).reduce(0.0) { $0 + abs(Double($1.0 - $1.1)) } / Double(pixels.count)
            probes.append(Probe(timelineTime: time, requested: requested, nativePTS: frame.actualTime.seconds,
                exportRequested: requested + delta, exportPTS: output.actualTime.seconds, mae: mae,
                luma: abs(quality.meanLuma - FrameQualityInspector.assess(image: output.image).meanLuma) / 255))
            try save(output.image, "export-\(time)-\(delta)")
        }
    }
    struct Report: Encodable { var duration: Double; var expected: Double; var skipped: [UUID]; var probes: [Probe] }
    try JSONEncoder.veloEdit.encode(Report(duration: playback.duration, expected: AutomaticFilmDurationPolicy.renderedDuration(of: timeline),
        skipped: playback.skippedItemIDs, probes: probes)).write(to: root.appendingPathComponent("parity.json"), options: .atomic)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_RELIABILITY_TITLE_PROJECT"] != nil))
func applySavedTitleAnchorsForRegressionExport() throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_RELIABILITY_TITLE_PROJECT"]))
    try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("study-input.json").path))
    let path = root.appendingPathComponent("project.json")
    var project = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: path))
    let original = try #require(project.timelines.last)
    var repaired = TitleTimelineAnchoring.reconcile(original)
    #expect(repaired.items == original.items && repaired.music == original.music)
    #expect(repaired.adaptiveSoundtrack == original.adaptiveSoundtrack && repaired.originalAudioVolume == original.originalAudioVolume)
    #expect(repaired.effectiveTitleItems.map(\.text) == original.effectiveTitleItems.map(\.text))
    #expect(repaired.effectiveTitleItems.map(\.duration) == original.effectiveTitleItems.map(\.duration))
    #expect(!original.effectiveTitleItems.isEmpty && repaired.effectiveTitleItems.count == original.effectiveTitleItems.count)
    for title in repaired.effectiveTitleItems {
        if let id = title.targetClipID, let clip = repaired.items.first(where: { $0.id == id }) {
            #expect(title.startTime + 0.001 >= clip.timelineStart)
            #expect(title.endTime <= clip.timelineStart + clip.timelineDuration + 0.001)
        }
    }
    struct Change: Encodable { var before: TitleTimelineItem; var after: TitleTimelineItem }
    let changes = zip(original.effectiveTitleItems, repaired.effectiveTitleItems).compactMap { a,b in a == b ? nil : Change(before: a, after: b) }
    #expect(!changes.isEmpty)
    repaired.id = UUID(); repaired.editorialReview = nil; repaired.filmDeliveryReport = nil
    repaired.versionName = "Регрессия привязки титров — сохранённый автоматический монтаж"
    project.timelines.append(repaired)
    try JSONEncoder.veloEdit.encode(project).write(to: path, options: .atomic)
    try JSONEncoder.veloEdit.encode(changes).write(to: root.appendingPathComponent("title-anchor-changes.json"), options: .atomic)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_RELIABILITY_HAND_DIAGNOSTICS"] != nil))
func inspectNaturalCoverEvidence() async throws {
    let env = ProcessInfo.processInfo.environment
    let input = URL(fileURLWithPath: try #require(env["VELOEDIT_NATURAL_TRANSITION_PROJECT"]))
    let root = URL(fileURLWithPath: try #require(env["VELOEDIT_RELIABILITY_HAND_DIAGNOSTICS"]))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let project = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: input))
    let timeline = try #require(project.timelines.last)
    let items = timeline.items.sorted { $0.timelineStart < $1.timelineStart }
    let left = items[0], right = items[1], fps = timeline.frameRate
    let assetA = try #require(project.assets.first { $0.id == left.assetID })
    let assetB = try #require(project.assets.first { $0.id == right.assetID })
    let edge = left.sourceStart + left.sourceDuration - 1/fps
    func rounded(_ t: Double) -> Double { (t * fps).rounded() / fps }
    let aTimes = (-26...0).map { rounded(edge + Double($0)/10) }
    let bTimes = (-12...18).map { rounded(right.sourceStart + Double($0)/10) }
    let prober = LocalNaturalTransitionFrameProber()
    let a = try await prober.frames(asset: assetA, times: aTimes, frameRate: fps)
    let b = try await prober.frames(asset: assetB, times: bTimes, frameRate: fps)
    struct Row: Encodable { var end: Double; var begin: Double; var step: Double; var cover: Bool; var stable: Bool; var spatial: Bool; var color: Double; var kind: String; var darkA: [Double]; var darkB: [Double]; var detailA: Double; var detailB: Double }
    var rows: [Row] = []
    for end in aTimes.suffix(13) { for start in bTimes.prefix(25) { for step in [0.1, 0.2] {
        let tail = (0..<4).compactMap { i in a.first { abs($0.time - (end + Double(i-3)*step)) < 0.001 } }
        let head = (0..<4).compactMap { i in b.first { abs($0.time - (start + Double(i)*step)) < 0.001 } }
        let context = (0..<8).compactMap { i in a.first { abs($0.time - (end - 3*step + Double(i-8)*0.1)) < 0.001 } }
        guard tail.count == 4, head.count == 4, context.count == 8 else { continue }
        rows.append(.init(end: end, begin: start, step: step,
            cover: NaturalTransitionVision.coveredReveal(tail: tail, head: head), stable: NaturalTransitionVision.composedBeforeCover(context),
            spatial: NaturalTransitionVision.hasSpatialCover(tail, background: context.last),
            color: NaturalTransitionVision.distance(tail[3].meanColor, head[0].meanColor),
            kind: NaturalTransitionVision.match(tail: tail, head: head, outgoingContext: context)?.kind.rawValue ?? "none",
            darkA: tail.map(NaturalTransitionVision.darkCoverage), darkB: head.map(NaturalTransitionVision.darkCoverage),
            detailA: NaturalTransitionVision.detail(tail[0].luma), detailB: NaturalTransitionVision.detail(head[3].luma)))
    } } }
    try JSONEncoder.veloEdit.encode(rows).write(to: root.appendingPathComponent("windows.json"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_RELIABILITY_TITLE_INPUT"] != nil))
func inspectSavedExportTitleVisibility() async throws {
    let env = ProcessInfo.processInfo.environment
    let path = URL(fileURLWithPath: try #require(env["VELOEDIT_RELIABILITY_TITLE_INPUT"]))
    let root = URL(fileURLWithPath: try #require(env["VELOEDIT_RELIABILITY_TITLE_OUTPUT"]))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    struct Input: Decodable { var timeline: Timeline; var exportURL: URL }
    let input = try JSONDecoder.veloEdit.decode(Input.self, from: Data(contentsOf: path))
    var results: [TitleReadabilityEvidence] = []
    for title in input.timeline.effectiveTitleItems where title.enabled {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: input.exportURL))
        g.maximumSize = TitleReadabilityInspector.maximumSize; g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        defer { g.cancelAllCGImageGeneration() }
        for t in TitleReadabilityInspector.times(title, frameRate: input.timeline.frameRate) {
            let time = VideoFrameTiming.sampleTime(for: t, frameRate: input.timeline.frameRate, duration: input.timeline.duration)
            let frame = try await g.image(at: time)
            let row = TitleReadabilityInspector.inspect(image: frame.image, title: title, timeline: input.timeline,
                time: t, actualPTS: frame.actualTime.seconds, source: "export")
            results.append(row)
            let target = root.appendingPathComponent("\(title.id)-\(t).png")
            let d = try #require(CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(d, frame.image, nil); #expect(CGImageDestinationFinalize(d))
        }
    }
    try JSONEncoder.veloEdit.encode(results).write(to: root.appendingPathComponent("titles.json"))
    #expect(results.allSatisfy { $0.passed }, "Failed title probes: \(results.filter { !$0.passed }.map { "\($0.expectedText) @ \($0.timelineTime): \($0.failure ?? "unknown")" })")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_RELIABILITY_RECOVERY_PROJECT"] != nil))
func recoverActualFilmAfterUnavailableSelectedSource() async throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_RELIABILITY_RECOVERY_PROJECT"]))
    try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("study-input.json").path))
    let store = try ProjectStore(open: root, recoveryDirectory: root.appendingPathComponent("StudyRecovery"))
    let original = await store.manifest
    let selected = try #require(original.timelines.last)
    let plan = try #require(original.storyPlans.first { $0.id == selected.storyPlanID })
    let library = LocalMusicLibrary(rootURL: root.appendingPathComponent("MusicLibrary"))
    let tracks = try await library.tracks()
    let removedID = try #require(selected.items.last?.assetID)
    try JSONEncoder.veloEdit.encode(selected).write(to: root.appendingPathComponent("selection-before-interruption.json"))
    // The source file stays untouched. Only the disposable project manifest
    // loses one selected asset, reproducing an unavailable composition input.
    try await store.update { p in
        p.timelines = []; p.autonomousJob = nil
        p.assets.removeAll { $0.id == removedID }
        p.filmBuildRecovery = nil
    }
    let request = FilmBuildRequest(kind: .create, prompt: plan.prompt, preset: plan.preset)
    _ = try await store.beginEditorialGeneration(prompt: request.prompt, brief: nil)
    _ = try await store.beginFilmBuildRecovery(request)
    let draft = FilmBuildDraft(phase: .readyForPlayback, timeline: selected, plan: plan, analyses: original.analyses,
        tracks: tracks, sourceMap: original.sourceMap ?? .empty, events: original.events,
        personalTaste: original.personalTasteProfile ?? PersonalTasteProfile(), checkpointReason: "Reproducible recovery regression")
    try await store.checkpointFilmBuild(draft, ifRevision: await store.snapshot().revision)
    func pipeline(_ store: ProjectStore) -> VeloEditPipeline {
        VeloEditPipeline(store: store, musicLibrary: library,
            musicSystem: MusicLibrary(localLibrary: library, providers: [BundledMusicProvider(library: library), LocalMusicProvider(library: library)]),
            musicSelectionHistory: LocalMusicSelectionHistoryStore(url: root.appendingPathComponent("study-music-history.json")),
            personalTasteStore: LocalPersonalTasteStore(url: root.appendingPathComponent("study-taste.json")))
    }
    let failed = try ProjectStore(open: root, recoveryDirectory: root.appendingPathComponent("StudyRecovery"))
    var failure = ""
    do { _ = try await pipeline(failed).resumeFilmBuild(); Issue.record("Missing real selected source must fail") }
    catch { failure = error.localizedDescription; #expect(failure.contains("Выбранный монтаж сохранён")) }
    let afterFailure = await failed.manifest
    #expect(afterFailure.timelines.isEmpty && afterFailure.autonomousJob?.state == .failed)
    #expect(afterFailure.filmBuildRecovery?.draft?.timeline.items == selected.items)
    #expect(afterFailure.filmBuildRecovery?.draft?.timeline.music == selected.music)
    #expect(afterFailure.filmBuildRecovery?.draft?.timeline.titleItems == selected.titleItems)
    try Data(failure.utf8).write(to: root.appendingPathComponent("reproduced-composition-failure.txt"))
    try await failed.updateAnalysisProgress { $0.assets = original.assets }
    try await failed.rebindRecoveredMediaInputs()
    let reopened = try ProjectStore(open: root, recoveryDirectory: root.appendingPathComponent("StudyRecovery"))
    let result = try await pipeline(reopened).resumeFilmBuild { progress in
        print("Recovery regression: \(progress.stage) \(progress.completed ?? 0)/\(progress.total ?? 0)")
    }
    #expect(result.items == selected.items)
    #expect(result.music == selected.music && result.adaptiveSoundtrack == selected.adaptiveSoundtrack)
    #expect(result.titleItems == selected.titleItems && result.originalAudioVolume == selected.originalAudioVolume)
    #expect(await reopened.manifest.events == original.events)
    #expect(await reopened.manifest.sourceMap == original.sourceMap)
    let chronology = EditorialChronologyReport.inspect(timeline: result, assets: original.assets, sourceMap: original.sourceMap)
    #expect(chronology.confirmedErrorCount == 0)
    struct Receipt: Encodable { var failure: String; var items: Int; var sources: Int; var titles: Int; var itemsPreserved: Bool; var musicPreserved: Bool; var titlesPreserved: Bool; var chronology: EditorialChronologyReport; var export: EditorialExportVerification? }
    let receipt = Receipt(failure: failure, items: result.items.count, sources: Set(result.items.compactMap(\.assetID)).count,
        titles: result.effectiveTitleItems.count, itemsPreserved: result.items == selected.items, musicPreserved: result.music == selected.music,
        titlesPreserved: result.titleItems == selected.titleItems, chronology: chronology, export: result.filmDeliveryReport?.exportVerification)
    try JSONEncoder.veloEdit.encode(receipt).write(to: root.appendingPathComponent("recovery-verification.json"))
}
