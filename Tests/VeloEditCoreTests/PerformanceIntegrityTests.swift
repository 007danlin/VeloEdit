import Foundation
import Testing
@testable import VeloEditCore

private func performanceSample(time: Double = 1, value: UInt8 = 128, motion: Double = 0) -> VisualFrameSample {
    VisualFrameSample(timestamp: time, motion: motion, exposure: 0.8, detail: 0.7,
        labels: ["outdoor"], labelConfidence: 0.9, faceCount: 0,
        jpegBase64: Data(repeating: value, count: 4_096).base64EncodedString(),
        histogram: [0.25, 0.75], luminanceFingerprint: [value, value])
}

private actor FrameProducerProbe {
    var calls = 0
    func make() async throws -> VisualFrameSample {
        calls += 1
        try await Task.sleep(for: .milliseconds(100))
        return performanceSample()
    }
}

@Test func simultaneousFrameConsumersShareWorkAndCancellationIsIsolated() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = FrameCache(rootURL: root)
    let probe = FrameProducerProbe()
    let key = FrameCacheKey(sourceFile: "v1", timestamp: 1, resolution: 960, processingPurpose: .vision)
    let first = Task { try await cache.resolve(key) { try await probe.make() } }
    while await probe.calls == 0 { await Task.yield() }
    let second = Task { try await cache.resolve(key) { try await probe.make() } }
    first.cancel()
    let survivor = try await second.value
    #expect(survivor.sample == performanceSample())
    #expect(await probe.calls == 1)
    do { _ = try await first.value; Issue.record("Cancelled consumer returned success") }
    catch { #expect(error is CancellationError) }
    #expect(await cache.value(for: key) == performanceSample())
}

@Test func failedFrameProductionIsRetriedAndNeverCached() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = FrameCache(rootURL: root)
    let key = FrameCacheKey(sourceFile: "v1", timestamp: 1, resolution: 960, processingPurpose: .vision)
    do { _ = try await cache.resolve(key) { throw URLError(.cannotDecodeContentData) }; Issue.record("Expected failure") }
    catch {}
    #expect(await cache.value(for: key) == nil)
    let retry = try await cache.resolve(key) { performanceSample() }
    #expect(retry.origin == .computed)
}

@Test func frameMotionIsRecomputedForEveryTemporalNeighbour() async throws {
    let current = performanceSample(time: 4, value: 144, motion: 0.99)
    let near = performanceSample(time: 3, value: 0)
    let identical = performanceSample(time: 3, value: 144)
    #expect(AdaptiveFrameSampler.contextualSample(current, previous: near).motion == 1)
    #expect(AdaptiveFrameSampler.contextualSample(current, previous: identical).motion == 0)
    #expect(AdaptiveFrameSampler.contextualSample(current, previous: nil).motion == 0)
    #expect(AdaptiveFrameSampler.contextualSample(current, previous: performanceSample(time: 0, value: 0)).motion == 0.25)
    #expect(AdaptiveFrameSampler.contextualSample(current, previous: near).jpegBase64 == current.jpegBase64)
}

@Test func temporalFeatureCacheDependsOnFramesOrderModelAndExactWindow() {
    let frames = [performanceSample(time: 1, value: 10), performanceSample(time: 2, value: 20)]
    let signature = DeepMediaCandidateEnricher.frameEvidenceSignature(frames, context: "model-a")
    #expect(signature == DeepMediaCandidateEnricher.frameEvidenceSignature(frames, context: "model-a"))
    #expect(signature != DeepMediaCandidateEnricher.frameEvidenceSignature(frames.reversed(), context: "model-a"))
    #expect(signature != DeepMediaCandidateEnricher.frameEvidenceSignature(frames, context: "model-b"))
    #expect(signature != DeepMediaCandidateEnricher.frameEvidenceSignature([frames[0], performanceSample(time: 2, value: 21)], context: "model-a"))
    #expect(CachedCandidateDeepEvidence(sourceStart: 1.001, sourceDuration: 3).stableKey
        != CachedCandidateDeepEvidence(sourceStart: 1.002, sourceDuration: 3).stableKey)
}

@Test func persistentFrameCachePreservesPixelsAndPTSAndRejectsCorruption() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = FrameCache(rootURL: root)
    let key = FrameCacheKey(sourceFile: "v1", timestamp: 1, resolution: 960, processingPurpose: .vision)
    var sample = performanceSample()
    sample.actualTimestamp = 1.001001001
    sample.pixelWidth = 960
    sample.pixelHeight = 540
    try await cache.store(sample, for: key)
    let restarted = FrameCache(rootURL: root)
    #expect(await restarted.value(for: key) == sample)
    let path = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
    var bytes = try Data(contentsOf: path)
    bytes[bytes.count / 2] ^= 1
    try bytes.write(to: path, options: .atomic)
    await restarted.removeMemoryEntries()
    #expect(await restarted.value(for: key) == nil)
}

@Test func frameCacheUsesBytesAndExactDependencyKeys() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = FrameCache(rootURL: root, maximumMemoryEntries: 384, maximumMemoryBytes: 8_000)
    for index in 0..<4 {
        try await cache.store(performanceSample(time: Double(index)), for: FrameCacheKey(sourceFile: "v1", timestamp: Double(index), resolution: 960, processingPurpose: .vision))
    }
    #expect(await cache.memoryByteCount() <= 8_000)
    #expect(await cache.memoryEntryCount() == 1)
    let a = FrameCacheKey(sourceFile: "v1", timestamp: 1.0001, resolution: 960, processingPurpose: .vision)
    let b = FrameCacheKey(sourceFile: "v1", timestamp: 1.0002, resolution: 960, processingPurpose: .vlm)
    #expect(a.canonicalIdentity != b.canonicalIdentity)
    var c = a; c.representation = "different-color-transform"
    #expect(c.canonicalIdentity != a.canonicalIdentity)
    c = a; c.sourceFile = "v2"
    #expect(c.canonicalIdentity != a.canonicalIdentity)
}

@Test func sourceReplacementAtSamePathInvalidatesEvenWithSameSizeAndModificationDate() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let date = Date(timeIntervalSince1970: 1_700_000_000.123456)
    try Data([1, 2, 3]).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    let first = FrameCacheKey.sourceIdentity(url: url, contentHash: "imported")
    #expect(FrameCacheKey.sourceIdentity(url: url, contentHash: "imported") == first)
    try Data([4, 5, 6]).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    #expect(FrameCacheKey.sourceIdentity(url: url, contentHash: "imported") != first)
}

@Test func thermalAndBatteryPressurePreserveEveryEvaluationTask() {
    for mode in AIPowerMode.allCases {
        let cool = AIAnalysisProfile.resolve(mode: mode, thermalState: .nominal, lowPowerMode: false)
        for state in [ProcessInfo.ThermalState.serious, .critical] {
            let hot = AIAnalysisProfile.resolve(mode: mode, thermalState: state, lowPowerMode: true)
            #expect(hot.proxyLongEdge == cool.proxyLongEdge)
            #expect(hot.framesPerCandidate == cool.framesPerCandidate)
            #expect(hot.maximumDeepCandidates == cool.maximumDeepCandidates)
            #expect(hot.maximumVLMScenes == cool.maximumVLMScenes)
            #expect(hot.modelID == cool.modelID)
            #expect(hot.quantization == cool.quantization)
            #expect(hot.thinkingEnabled == cool.thinkingEnabled)
            for duration in [5.0, 304.0, 14_400.0] {
                let before = AdaptiveSamplingPlan(duration: duration, profile: cool)
                let after = AdaptiveSamplingPlan(duration: duration, profile: hot)
                #expect(before == after)
                #expect(before.denseTimestamps(around: [1, 3, 9], duration: duration, interval: cool.denseInterval, framesPerCandidate: cool.framesPerCandidate)
                    == after.denseTimestamps(around: [1, 3, 9], duration: duration, interval: hot.denseInterval, framesPerCandidate: hot.framesPerCandidate))
            }
        }
    }
}

@Test func exactCommentRoutingRequiresTheWholeRequestAndSelection() {
    let parser = EditorCommandParser()
    #expect(parser.parseComplete("громкость музыки 20%", hasSelection: false) == [.setMusicVolume(0.2)])
    #expect(parser.parseComplete("убери звук выделенного клипа", hasSelection: true) == [.setClipMuted(true, .selected)])
    #expect(parser.parseComplete("убери звук выделенного клипа", hasSelection: false) == nil)
    #expect(parser.parseComplete("поставь титр “Утро”", hasSelection: false) == [.addTitle("Утро", .beginning)])
    #expect(parser.parse("поставь титр «Убери звук и все титры» в конце") == [.addTitle("Убери звук и все титры", .end)])
    for text in ["громкость музыки 20% и сделай напряжённее", "не ставь громкость музыки 20%", "громкость музыки 120%", "сделай напряжённее", "убери звук выделенного клипа и замени плохой дубль", "поставь титр “Утро” и добавь музыку"] {
        #expect(parser.parseComplete(text, hasSelection: true) == nil)
    }
}

private let validVisionResponse = #"{"scenes":[{"index":3,"interest":0.7,"action":0.6,"quality":0.8,"stability":0.9,"storyValue":0.7,"scene":"A cyclist","tags":["bicycle"],"reason":"Clear action"}]}"#

private actor VisionProducerProbe {
    var calls = 0
    func make() async throws -> String {
        calls += 1
        try await Task.sleep(for: .milliseconds(100))
        return validVisionResponse
    }
}

@Test func visionCacheCoalescesOnlyIdenticalRequestsAndSurvivesRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = DeepAnalysisCache(rootURL: root)
    let probe = VisionProducerProbe()
    let first = Task { try await cache.visionResponse(identity: "same-model-input-window", indices: [3]) { try await probe.make() } }
    while await probe.calls == 0 { await Task.yield() }
    let second = Task { try await cache.visionResponse(identity: "same-model-input-window", indices: [3]) { try await probe.make() } }
    let deadline = ContinuousClock.now + .seconds(2)
    while await cache.visionConsumerCount(identity: "same-model-input-window") < 2, ContinuousClock.now < deadline { await Task.yield() }
    first.cancel()
    let surviving = try await second.value
    #expect(surviving.content == validVisionResponse)
    #expect(await probe.calls == 1)
    do { _ = try await first.value; Issue.record("Cancelled consumer succeeded") }
    catch { #expect(error is CancellationError) }
    let restarted = DeepAnalysisCache(rootURL: root)
    let stored = try await restarted.visionResponse(identity: "same-model-input-window", indices: [3]) { throw URLError(.unknown) }
    #expect(stored.reused)
    #expect(stored.content == validVisionResponse)
    let changed = try await restarted.visionResponse(identity: "different-model-input-window", indices: [3]) { try await probe.make() }
    #expect(!changed.reused)
    #expect(await probe.calls == 2)
    // Syntactically valid corruption also invalidates evidence.
    let url = root.appendingPathComponent("same-model-input-window.vision-v1.json")
    let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "0.7", with: "0.2")
    try Data(text.utf8).write(to: url, options: .atomic)
    let repaired = try await restarted.visionResponse(identity: "same-model-input-window", indices: [3]) { try await probe.make() }
    #expect(!repaired.reused)
    #expect(repaired.content == validVisionResponse)
}

@Test func partialAndFailedVisionResponsesCannotPopulateTheCache() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = DeepAnalysisCache(rootURL: root)
    do {
        _ = try await cache.visionResponse(identity: "request", indices: [3, 4]) { validVisionResponse }
        Issue.record("Missing scene accepted")
    } catch {}
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("request.vision-v1.json").path))
    let retried = try await cache.visionResponse(identity: "request", indices: [3]) { validVisionResponse }
    #expect(!retried.reused)
}

private actor DecodeConcurrencyProbe {
    var active = 0
    var peak = 0
    func produce() async throws -> VisualFrameSample {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(20))
        return performanceSample()
    }
}

@Test func distinctFrameRequestsRespectDecodeMemoryReservations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = FrameCache(rootURL: root, maximumMemoryBytes: 1_000_000)
    let probe = DecodeConcurrencyProbe()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<8 {
            group.addTask {
                let key = FrameCacheKey(sourceFile: "source", timestamp: Double(index), resolution: 960, processingPurpose: .vision)
                _ = try await cache.resolve(key) { try await probe.produce() }
            }
        }
        try await group.waitForAll()
    }
    #expect(await probe.peak == 1)
    #expect(await cache.memoryByteCount() <= 1_000_000)
}

@Test func identicalDecoderTimesShareFramesWithoutRoundingDistinctRequestsTogether() {
    let a = FrameCacheKey(sourceFile: "source", timestamp: 1.0001, resolution: 960, processingPurpose: .vision, decodeTimeScale: 600)
    let b = FrameCacheKey(sourceFile: "source", timestamp: 1.0002, resolution: 960, processingPurpose: .vlm, decodeTimeScale: 600)
    let c = FrameCacheKey(sourceFile: "source", timestamp: 1.002, resolution: 960, processingPurpose: .vision, decodeTimeScale: 600)
    #expect(a.canonicalIdentity == b.canonicalIdentity)
    #expect(a.canonicalIdentity != c.canonicalIdentity)
    #expect(a.requestedTimestamp != b.requestedTimestamp)
}

private actor CountingIndependentAnalyzer: VisionModelProtocol {
    var calls = 0
    func analyze(asset: MediaAsset) async throws -> AnalysisResult {
        calls += 1
        return AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash,
            sceneTags: ["outdoor"], candidates: [Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 2,
                scores: ClipScores(quality: 0.8, interest: 0.8, action: 0.5, stability: 0.8, uniqueness: 0.8), tags: ["outdoor"])])
    }
}

@Test func independentAnalyzerCacheDoesNotDependOnInstalledOllamaModels() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("fixture.jpg")
    try Data([1, 2, 3]).write(to: source)
    let asset = MediaAsset(originalURL: source, kind: .photo, byteSize: 3, contentHash: "fixed-source", metadata: MediaMetadata(duration: 2))
    let store = try ProjectStore(createAt: root.appendingPathComponent("project.veloedit"), name: "Independent analyzer")
    try await store.update { $0.assets = [asset] }
    let analyzer = CountingIndependentAnalyzer()
    let pipeline = VeloEditPipeline(store: store, analyzer: analyzer)
    #expect(try await pipeline.analyzeMissing() == 1)
    #expect(try await pipeline.analyzeMissing() == 0)
    #expect(await analyzer.calls == 1)
}

@Test func portableAnalysisSurvivesMovingWithoutReanalysisButRejectsChangedMedia() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("fixture.jpg")
    try Data([1, 2, 3]).write(to: source)
    let modificationDate = Date(timeIntervalSince1970: 1_700_000_000.123)
    let asset = MediaAsset(originalURL: source, kind: .photo, byteSize: 3,
        contentHash: try MediaImporter.quickFingerprint(url: source, byteSize: 3, modificationDate: modificationDate),
        metadata: MediaMetadata(duration: 2, modificationDate: modificationDate))
    let package = root.appendingPathComponent("project.veloedit")
    let store = try ProjectStore(createAt: package, name: "Portable analysis")
    try await store.update { $0.assets = [asset] }
    let analyzer = CountingIndependentAnalyzer()
    let pipeline = VeloEditPipeline(store: store, analyzer: analyzer)
    #expect(try await pipeline.analyzeMissing() == 1)
    let originalAnalysis = try JSONDecoder.veloEdit.decode([AnalysisResult].self,
        from: JSONEncoder.veloEdit.encode(await store.manifest.analyses))
    let copy = root.appendingPathComponent("copy.veloedit")
    _ = try await pipeline.collectProjectCopy(to: copy)
    let moved = root.appendingPathComponent("another-computer.veloedit")
    try FileManager.default.moveItem(at: copy, to: moved)
    try FileManager.default.removeItem(at: source)
    try FileManager.default.removeItem(at: package)

    let reopened = try ProjectStore(open: moved, recoveryDirectory: root.appendingPathComponent("FreshRecovery"))
    #expect(await reopened.manifest.analyses == originalAnalysis)
    let restoredPipeline = VeloEditPipeline(store: reopened, analyzer: analyzer)
    #expect(try await restoredPipeline.analyzeMissing() == 0)
    #expect(await analyzer.calls == 1)
    let restored = await reopened.manifest
    let embedded = try #require(restored.assets.first)
    #expect(embedded.fullContentHash == (try MediaImporter.sha256(url: embedded.originalURL)))
    #expect(restored.analyses.first?.analyzedSourceIdentity == FrameCacheKey.sourceIdentity(
        url: embedded.originalURL, contentHash: embedded.contentHash))

    // The new identity is durable; another open also reuses the analysis.
    let again = try ProjectStore(open: moved)
    #expect(try await VeloEditPipeline(store: again, analyzer: analyzer).analyzeMissing() == 0)
    #expect(await analyzer.calls == 1)
    try Data([4, 5, 6]).write(to: embedded.originalURL, options: .atomic)
    #expect(try await VeloEditPipeline(store: again, analyzer: analyzer).analyzeMissing() == 1)
    #expect(await analyzer.calls == 2)
}

@Test func portableCopyDoesNotRevalidateAnalysisOfAnAlreadyChangedSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("fixture.jpg")
    try Data([1, 2, 3]).write(to: source)
    let asset = MediaAsset(originalURL: source, kind: .photo, byteSize: 3,
        contentHash: try MediaImporter.quickFingerprint(url: source, byteSize: 3, modificationDate: nil),
        metadata: MediaMetadata(duration: 2))
    let store = try ProjectStore(createAt: root.appendingPathComponent("project.veloedit"), name: "Changed source")
    try await store.update { $0.assets = [asset] }
    let analyzer = CountingIndependentAnalyzer()
    let pipeline = VeloEditPipeline(store: store, analyzer: analyzer)
    #expect(try await pipeline.analyzeMissing() == 1)
    try Data([4, 5, 6]).write(to: source, options: .atomic)
    let copy = root.appendingPathComponent("copy.veloedit")
    _ = try await pipeline.collectProjectCopy(to: copy)
    let reopened = try ProjectStore(open: copy)
    #expect(await reopened.manifest.analyses.first?.analyzedSourceIdentity == nil)
    #expect(try await VeloEditPipeline(store: reopened, analyzer: analyzer).analyzeMissing() == 1)
    #expect(await analyzer.calls == 2)
}
