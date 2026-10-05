import Foundation
import Testing
@testable import VeloEditCore

@Suite struct AIModeReliabilityTests {
    @Test func calmScenesReachEveryModeAndHigherModesKeepTheirFrameContext() {
        let asset = UUID()
        let candidates = (0..<18).map { index in
            Candidate(assetID: asset, sourceStart: Double(index * 4), sourceDuration: 3,
                scores: ClipScores(quality: 0.8, interest: 0.1, action: 0.01, stability: 0.9), tags: ["landscape"])
        }
        let frames = (0..<24).map { index in
            VisualFrameSample(timestamp: Double(index), motion: 0, exposure: 0.8, detail: 0.7,
                labels: ["outdoor"], labelConfidence: 0.9, faceCount: 0, jpegBase64: "frame",
                histogram: [0.25, 0.75], luminanceFingerprint: [128])
        }
        for (mode, scenes, images) in [(AIPowerMode.fast, 2, 3), (.balanced, 6, 5), (.quality, 12, 8), (.maximum, 18, 12)] {
            let profile = AIAnalysisProfile.resolve(mode: mode, thermalState: .nominal)
            let analyzer = AdaptiveLocalAnalyzer(profile: profile)
            #expect(analyzer.selectedVLMIndices(in: candidates).count == scenes)
            #expect(analyzer.nearbyFrames(for: candidates[0], in: frames).count == images)
            #expect(profile.scenesPerVLMRequest * images <= 18)
            #expect(profile.comparesAcrossVideos)
            #expect(profile.vlmPrefillTimeout(imageCount: images) > 45)
        }
    }

    @Test func legacyMLXAndQuantizationSettingsResolveToAnHonestRuntime() throws {
        #expect(!LocalAIRuntime.allCases.contains(.mlx))
        #expect(AIQuantization.allCases == [.modelProvided])
        let legacy = try JSONDecoder().decode(AdvancedAISettings.self,
            from: Data(#"{"enabled":true,"runtime":"mlx","modelID":"mlx-community/Qwen3-VL-8B-Instruct-8bit","quantization":"8-bit"}"#.utf8))
        let profile = AIAnalysisProfile.resolve(mode: .quality, advanced: legacy, thermalState: .nominal)
        #expect(profile.runtime == .ollama)
        #expect(profile.modelID == "qwen3-vl:8b-instruct")
        #expect(!profile.summary.contains("MLX"))
        #expect(!profile.summary.contains("8-bit"))
        let model = try JSONDecoder().decode(InstalledAIModel.self,
            from: Data(#"{"name":"custom:latest","digest":"abc","details":{"quantization_level":"Q8_0","parameter_size":"8B"}}"#.utf8))
        #expect(model.quantization == "Q8_0")
    }

    @Test func requestedDepthCannotHideMissingOrPartialInference() throws {
        let profile = AIAnalysisProfile.resolve(mode: .maximum, thermalState: .nominal)
        var result = AnalysisResult(assetID: UUID(), analyzedContentHash: "source", candidates: [], completedDepth: .maximum)
        #expect(!result.satisfies(profile))
        result.aiExecution = AIExecutionEvidence(visualAnalysisCompleted: true, plannedScenes: 3, evaluatedScenes: 2,
            plannedRechecks: 2, evaluatedRechecks: 0, modelAvailable: true)
        #expect(!result.satisfies(profile))
        result.aiExecution?.evaluatedScenes = 3
        #expect(!result.satisfies(profile))
        result.aiExecution?.evaluatedRechecks = 2
        #expect(result.satisfies(profile))
        result.aiExecution?.audioAnalysisCompleted = false
        #expect(!result.satisfies(profile))
        result.aiExecution?.audioAnalysisCompleted = true
        let restored = try JSONDecoder().decode(AnalysisResult.self, from: JSONEncoder().encode(result))
        #expect(restored.satisfies(profile))
        result.aiExecution?.modelAvailable = false
        #expect(!result.satisfies(profile))
    }

    @Test func metadataFallbackDoesNotClaimFullDepth() async throws {
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/no-duration.mov"), kind: .video,
            byteSize: 0, contentHash: "unknown", metadata: MediaMetadata())
        let profile = AIAnalysisProfile.resolve(mode: .maximum, thermalState: .nominal)
        let result = try await AdaptiveLocalAnalyzer(profile: profile).analyze(asset: asset, analysisURL: asset.originalURL, usedProxy: false)
        #expect(result.completedDepth == .metadata)
        #expect(!result.satisfies(profile))
    }

    @Test func benchmarkCountsSuccessfulJudgementsRatherThanAttempts() async throws {
        for mode in [AIPowerMode.fast, .balanced, .maximum] {
            let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/fixture.mov"), kind: .video,
                byteSize: 1, contentHash: "fixture", metadata: MediaMetadata(duration: 10))
            let metrics = AnalysisMetricsRecorder(mode: mode, metadata: asset.metadata)
            await metrics.recordFrames(total: 3, decoded: 3, analyzed: 3, cacheHits: 0)
            await metrics.recordVLMCall(latency: 1)
            var result = AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [],
                completedDepth: .maximum, metrics: await metrics.snapshot())
            result.aiExecution = AIExecutionEvidence(visualAnalysisCompleted: true, plannedScenes: 2, modelAvailable: true)
            var row = try #require(AnalysisBenchmarkRow(mode: mode, assets: [asset], analyses: [result]))
            #expect(row.semanticRuntimeStatus == "vlm-failed")
            result.aiExecution?.evaluatedScenes = 1
            row = try #require(AnalysisBenchmarkRow(mode: mode, assets: [asset], analyses: [result]))
            #expect(row.semanticRuntimeStatus == "partial-vlm")
            result.aiExecution?.evaluatedScenes = 2
            row = try #require(AnalysisBenchmarkRow(mode: mode, assets: [asset], analyses: [result]))
            #expect(row.semanticRuntimeStatus == "valid-vlm")
            #expect(row.successfulVLMScenes == 2)
            let unmeasured = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/other.mov"), kind: .video,
                byteSize: 1, contentHash: "other", metadata: MediaMetadata(duration: 20))
            row = try #require(AnalysisBenchmarkRow(mode: mode, assets: [asset, unmeasured], analyses: [result]))
            #expect(row.fileCount == 1)
            #expect(row.fallbackFileCount == 0)
            #expect(row.semanticRuntimeStatus == "valid-vlm")
        }
    }

    @Test func streamingRequiresTerminalEventAndKeepsAllContent() throws {
        var stream = OllamaVisionStream(expectedModel: "test")
        try stream.append(#"{"model":"test","message":{"role":"assistant","content":"first"},"done":false}"#)
        #expect(throws: (any Error).self) { try stream.completedContent() }
        try stream.append(#"{"model":"test","message":{"role":"assistant","content":" second"},"done":true,"eval_count":12}"#)
        #expect(try stream.completedContent() == "first second")
        #expect(stream.measurements["generatedTokens"] == 12)
        #expect(throws: (any Error).self) { try stream.append(#"{"done":true}"#) }
        var wrong = OllamaVisionStream(expectedModel: "test")
        #expect(throws: (any Error).self) { try wrong.append(#"{"model":"different","done":true}"#) }
        var failed = OllamaVisionStream(expectedModel: "test")
        #expect(throws: (any Error).self) { try failed.append(#"{"error":"out of memory"}"#) }
        var truncated = OllamaVisionStream(expectedModel: "test")
        #expect(throws: (any Error).self) { try truncated.append(#"{"done":true,"done_reason":"length"}"#) }
    }

    @Test func timeoutDoesNotStartAnotherExpensiveInference() async {
        let calls = RetryCount()
        await #expect(throws: URLError.self) {
            try await LocalAIModelManager.recoveringRequest(retryTimeouts: false) {
                await calls.increment()
                throw URLError(.timedOut)
            } as Void
        }
        #expect(await calls.value == 1)
    }

    @Test func pipelineRetriesIncompleteWorkThenReusesCompletedWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("fixture.jpg")
        try Data([1, 2, 3]).write(to: source)
        let asset = MediaAsset(originalURL: source, kind: .photo, byteSize: 3, contentHash: "source", metadata: MediaMetadata(duration: 2))
        let store = try ProjectStore(createAt: root.appendingPathComponent("test.veloedit"), name: "Retry")
        try await store.update { $0.assets = [asset] }
        let analyzer = RecoveringAnalyzer()
        let pipeline = VeloEditPipeline(store: store, analyzer: analyzer)
        #expect(try await pipeline.analyzeMissing() == 1)
        #expect(try await pipeline.analyzeMissing() == 1)
        #expect(try await pipeline.analyzeMissing() == 0)
        #expect(await analyzer.calls == 2)
    }
}

private actor RetryCount {
    var value = 0
    func increment() { value += 1 }
}

private actor RecoveringAnalyzer: VisionModelProtocol {
    var calls = 0
    func analyze(asset: MediaAsset) async throws -> AnalysisResult {
        calls += 1
        var result = AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash,
            candidates: [Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 2,
                scores: ClipScores(quality: 0.8, interest: 0.8, action: 0.5, stability: 0.8), tags: ["outdoor"])],
            completedDepth: .maximum)
        result.aiExecution = AIExecutionEvidence(visualAnalysisCompleted: true, plannedScenes: 1,
            evaluatedScenes: calls == 1 ? 0 : 1, modelAvailable: true)
        return result
    }
}
