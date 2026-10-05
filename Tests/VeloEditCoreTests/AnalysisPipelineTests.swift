import Foundation
import Testing
@testable import VeloEditCore

@Test func powerModesChangeTheAnalysisAlgorithm() {
    let fast = AIAnalysisProfile.resolve(mode: .fast, physicalMemory: 32 * 1_073_741_824, thermalState: .nominal)
    let balance = AIAnalysisProfile.resolve(mode: .balanced, physicalMemory: 32 * 1_073_741_824, thermalState: .nominal)
    let quality = AIAnalysisProfile.resolve(mode: .quality, physicalMemory: 32 * 1_073_741_824, thermalState: .nominal)
    let maximum = AIAnalysisProfile.resolve(mode: .maximum, physicalMemory: 32 * 1_073_741_824, thermalState: .nominal)

    #expect(fast.targetDepth < balance.targetDepth)
    #expect(balance.targetDepth < quality.targetDepth)
    #expect(quality.targetDepth < maximum.targetDepth)
    #expect(fast.proxyPolicy == .avoidFullEncode)
    #expect(balance.proxyPolicy == .whenNeeded)
    #expect(quality.proxyPolicy == .required)
    #expect(maximum.proxyPolicy == .highQuality)
    #expect(fast.audioAnalysisLevel == .none)
    #expect(fast.maximumVLMScenes == 2)
    #expect(maximum.audioAnalysisLevel == .deep)
    #expect(maximum.rechecksImportantScenes)
    #expect(maximum.comparesAcrossVideos)
}

@Test func audioReaderUsesAVFoundationSupportedSampleRates() {
    #expect(LocalAudioAnalyzer.sampleRate(for: .none) == nil)
    #expect(LocalAudioAnalyzer.sampleRate(for: .basic) == 8_000)
    #expect(LocalAudioAnalyzer.sampleRate(for: .deep) == 16_000)
}

@Test func proxyPlannerAvoidsFastFullEncodeAndLimitsBalanceToExpensiveSources() {
    let planner = AnalysisProxyPlanner()
    let regular = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/regular.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "regular",
        metadata: MediaMetadata(duration: 60, width: 1_920, height: 1_080, codec: "h264")
    )
    let goPro4K = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/gopro.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "gopro",
        metadata: MediaMetadata(duration: 60, width: 3_840, height: 2_160, codec: "hevc")
    )
    let fast = AIAnalysisProfile.resolve(mode: .fast, thermalState: .nominal)
    let balance = AIAnalysisProfile.resolve(mode: .balanced, thermalState: .nominal)
    let quality = AIAnalysisProfile.resolve(mode: .quality, thermalState: .nominal)

    #expect(!planner.shouldGenerateProxy(for: goPro4K, profile: fast))
    #expect(!planner.shouldGenerateProxy(for: regular, profile: balance))
    #expect(planner.shouldGenerateProxy(for: goPro4K, profile: balance))
    #expect(planner.shouldGenerateProxy(for: regular, profile: quality))
}

@Test func frameCacheReusesOneDecodeAcrossProcessingPurposes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = FrameCache(rootURL: root)
    let sample = VisualFrameSample(
        timestamp: 1.25,
        motion: 0.4,
        exposure: 0.8,
        detail: 0.7,
        labels: ["outdoor"],
        labelConfidence: 0.9,
        faceCount: 0,
        jpegBase64: "frame",
        histogram: [0.25, 0.75],
        luminanceFingerprint: [10, 20]
    )
    let decodeKey = FrameCacheKey(sourceFile: "source", timestamp: 1.25, resolution: 960, processingPurpose: .sceneDetection)
    let vlmKey = FrameCacheKey(sourceFile: "source", timestamp: 1.25, resolution: 960, processingPurpose: .vlm)

    try await cache.store(sample, for: decodeKey)
    #expect(await cache.value(for: vlmKey) == sample.withMotion(0))
    await cache.removeMemoryEntries()
    #expect(await cache.value(for: vlmKey) == sample.withMotion(0))
}

@Test func sceneDetectorUsesVisualBoundariesAndAlwaysCoversTheClip() {
    func sample(_ time: Double, histogram: [Double], labels: Set<String>) -> VisualFrameSample {
        VisualFrameSample(
            timestamp: time,
            motion: 0.1,
            exposure: 0.8,
            detail: 0.7,
            labels: labels,
            labelConfidence: 0.9,
            faceCount: 0,
            jpegBase64: "",
            histogram: histogram,
            luminanceFingerprint: []
        )
    }
    let samples = [
        sample(1, histogram: [1, 0], labels: ["mountain"]),
        sample(5, histogram: [0.9, 0.1], labels: ["mountain"]),
        sample(9, histogram: [0, 1], labels: ["city"]),
        sample(13, histogram: [0.1, 0.9], labels: ["city"])
    ]
    let scenes = SceneDetector().detect(samples: samples, duration: 16, sensitivity: 0.42)

    #expect(scenes.count == 2)
    #expect(scenes.first?.startTime == 0)
    #expect(scenes.last?.endTime == 16)
    #expect((scenes[1].boundaryConfidence) > 0.42)
}

@Test func analysisQueuePrioritizesSelectedAssetAndPersistsCancellation() async {
    func asset(_ name: String) -> MediaAsset {
        MediaAsset(
            originalURL: URL(fileURLWithPath: "/tmp/\(name).mov"),
            displayName: name,
            kind: .video,
            byteSize: 1,
            contentHash: name,
            metadata: MediaMetadata(duration: 1)
        )
    }
    let first = asset("first")
    let selected = asset("selected")
    let last = asset("last")
    let queue = AnalysisBackgroundQueue()
    _ = await queue.replace(with: [first, selected, last], preferredAssetID: selected.id)

    #expect(await queue.next()?.assetID == selected.id)
    await queue.cancel(assetID: first.id)
    #expect(await queue.isCancelled(assetID: first.id))
    #expect(await queue.next()?.assetID == last.id)
}

@Test func etaDoesNotPretendToKnowTheAnswerFromMetadataMilliseconds() async {
    let eta = AnalysisETAEngine()
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    await eta.startFile(now: start)
    let estimate = await eta.estimate(
        fileFraction: 0.05,
        fileIndex: 0,
        totalFiles: 1,
        fallbackSecondsPerFile: 12,
        now: start.addingTimeInterval(0.1)
    )
    #expect(estimate != nil)
    #expect((estimate ?? 0) > 10)
}

@Test func etaForThreeVideosDoesNotExplodeOrCountUpDuringSparseStages() async {
    let eta = AnalysisETAEngine()
    let start = Date(timeIntervalSinceReferenceDate: 2_000)
    await eta.startFile(now: start)

    let calibrated = await eta.estimate(
        fileFraction: 0.334,
        fileIndex: 0,
        totalFiles: 3,
        fallbackSecondsPerFile: 120,
        queuedFallbackSeconds: 240,
        now: start.addingTimeInterval(240)
    )
    let later = await eta.estimate(
        fileFraction: 0.56,
        fileIndex: 0,
        totalFiles: 3,
        fallbackSecondsPerFile: 120,
        queuedFallbackSeconds: 240,
        now: start.addingTimeInterval(300)
    )

    #expect((calibrated ?? .infinity) < 15 * 60)
    #expect((later ?? .infinity) <= (calibrated ?? 0))
}

@Test func thermalSchedulerUsesHysteresisBeforeRestoringLoad() async {
    let scheduler = ThermalAwareScheduler()
    let start = Date()
    #expect(await scheduler.refresh(thermalState: .critical, now: start) == .hot)
    #expect(await scheduler.refresh(thermalState: .nominal, now: start.addingTimeInterval(9)) == .hot)
    #expect(await scheduler.refresh(thermalState: .nominal, now: start.addingTimeInterval(10)) == .hot)
    #expect(await scheduler.refresh(thermalState: .nominal, now: start.addingTimeInterval(11)) == .cool)
}

@Test func deeperAnalysisCanSatisfyALighterModeWithoutRerun() {
    let assetID = UUID()
    var result = AnalysisResult(
        assetID: assetID,
        analyzedContentHash: "hash",
        candidates: [],
        completedDepth: .deep
    )
    result.aiExecution = AIExecutionEvidence(visualAnalysisCompleted: true, plannedScenes: 12, evaluatedScenes: 12, modelAvailable: true)
    let fast = AIAnalysisProfile.resolve(mode: .fast, thermalState: .nominal)
    let balance = AIAnalysisProfile.resolve(mode: .balanced, thermalState: .nominal)
    let maximum = AIAnalysisProfile.resolve(mode: .maximum, thermalState: .nominal)

    #expect(result.satisfies(fast))
    #expect(result.satisfies(balance))
    #expect(!result.satisfies(maximum))
}

@Test func maximumCrossVideoPassPenalizesDuplicateMoments() {
    let firstAsset = UUID()
    let secondAsset = UUID()
    let scores = ClipScores(quality: 0.9, interest: 0.8, action: 0.7, stability: 0.8)
    let firstCandidate = Candidate(assetID: firstAsset, sourceStart: 1, sourceDuration: 3, scores: scores, tags: ["bike", "forest"])
    let duplicate = Candidate(assetID: secondAsset, sourceStart: 2, sourceDuration: 3, scores: scores, tags: ["bike", "forest"])
    let analyses = [
        AnalysisResult(assetID: firstAsset, analyzedContentHash: "one", candidates: [firstCandidate]),
        AnalysisResult(assetID: secondAsset, analyzedContentHash: "two", candidates: [duplicate])
    ]

    let refined = CrossVideoRelationshipAnalyzer().refine(analyses)
    #expect(refined[1].candidates[0].scores.uniqueness <= 0.22)
    #expect(refined[1].candidates[0].explanation.contains { $0.contains("другом ролике") })
}

@Test func aiDirectorProjectsCanonicalSceneEvidenceOntoCandidates() {
    let assetID = UUID()
    let candidate = Candidate(
        assetID: assetID,
        sourceStart: 4,
        sourceDuration: 3,
        scores: ClipScores(quality: 0.2, interest: 0.2, action: 0.2, stability: 0.2)
    )
    let scene = SceneAnalysis(
        startTime: 3,
        endTime: 8,
        semanticDescription: "Быстрый спуск по горной тропе",
        qualityScore: 0.9,
        actionScore: 1,
        beautyScore: 0.8,
        stabilityScore: 0.7,
        objects: ["bike"],
        recommendedUses: ["climax"]
    )
    let result = AnalysisResult(
        assetID: assetID,
        analyzedContentHash: "hash",
        candidates: [candidate],
        scenes: [scene]
    )

    let projected = result.directorCandidates[0]
    #expect(projected.scores.action > candidate.scores.action)
    #expect(projected.tags.contains("bike"))
    #expect(projected.tags.contains("climax"))
    #expect(projected.explanation.contains("Быстрый спуск по горной тропе"))
}

@Test func momentBoundaryIncludesAnticipationPeakAndCompletion() {
    let signals = [
        MomentSignal(timestamp: 2, motion: 0.08, interest: 0.20, semantic: 0.30),
        MomentSignal(timestamp: 3, motion: 0.26, interest: 0.42, semantic: 0.46),
        MomentSignal(timestamp: 4, motion: 0.72, interest: 0.70, semantic: 0.66),
        MomentSignal(timestamp: 5, motion: 0.98, interest: 0.92, semantic: 0.78, audioOnset: 0.82, telemetry: 0.91),
        MomentSignal(timestamp: 6, motion: 0.64, interest: 0.68, semantic: 0.62),
        MomentSignal(timestamp: 7, motion: 0.18, interest: 0.52, semantic: 0.58),
        MomentSignal(timestamp: 8, motion: 0.07, interest: 0.22, semantic: 0.30)
    ]
    let boundary = MomentBoundaryRefiner().refine(around: 4.7, signals: signals, sourceDuration: 12, nominalDuration: 6)
    #expect(boundary.anticipationStart <= 3)
    #expect(boundary.peakTime == 5)
    #expect(boundary.completionEnd >= 7)
    #expect(boundary.confidence > 0.65)
    #expect(boundary.evidence.contains("telemetry-confirmed peak"))
}
