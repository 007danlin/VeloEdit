import Foundation
import Testing
import VeloEditCore
@testable import VeloEdit

@Suite @MainActor struct AICompletionStatusTests {
    @Test func advisoryReplyCannotReturnEditsEvenWhenTheModelIncludesThem() throws {
        let content = #"{"reply":"Название: «Лесной маршрут».","normalizedBrief":"Пересобрать фильм","commands":[{"action":"set_music_volume","target":"all","value":"0.2","secondaryTarget":""},{"action":"replace_footage","target":"selected","value":"","secondaryTarget":""}]}"#
        let reply = try LocalDirectorAgent.decodeReply(content, userMessage: "Предложи название, ничего не меняй",
            runtimeLabel: "test", allowsFootageReplacement: true, mode: .advisory)
        #expect(reply.text.contains("Лесной маршрут"))
        #expect(reply.commands.isEmpty)
        #expect(reply.normalizedBrief == nil)
        #expect(!reply.replacesSelectedFootage)
    }

    @Test func partialAnalysisIsVisibleAndDoesNotMakeTheProjectReady() throws {
        let suite = "VeloEdit.AICompletionStatusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let model = AppModel(defaults: defaults, startBackgroundServices: false,
            personalTasteStore: LocalPersonalTasteStore(url: root.appendingPathComponent("taste.json")))
        model.aiPowerMode = .balanced
        let profile = model.aiProfile
        let asset = MediaAsset(originalURL: root.appendingPathComponent("source.mov"), kind: .video,
            byteSize: 1, contentHash: "source", metadata: MediaMetadata(duration: 10))
        var result = AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash,
            candidates: [Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 3,
                scores: ClipScores(quality: 0.8, interest: 0.7, action: 0.2, stability: 0.8))],
            analysisProfileKey: profile.cacheKey, aiRuntimeLabel: "Qwen3-VL · Ollama",
            completedDepth: .scene, deepMediaVersion: DeepAnalysisCache.version)
        result.aiExecution = AIExecutionEvidence(visualAnalysisCompleted: true, plannedScenes: 2,
            evaluatedScenes: 1, modelAvailable: true, modelQuantization: "Q4_K_M")
        model.project = ProjectManifest(name: "Partial", assets: [asset], analyses: [result])
        #expect(!model.isAnalysisCurrent)
        #expect(model.aiAnalysisRuntimeStatus.contains("1/2"))
        #expect(model.aiAnalysisRuntimeStatus.contains("требуется повтор"))
        #expect(model.aiAnalysisRuntimeStatus.contains("Q4_K_M"))
        model.project?.analyses[0].aiExecution?.evaluatedScenes = 2
        #expect(model.isAnalysisCurrent)
        #expect(model.aiAnalysisRuntimeStatus.contains("завершено"))
        model.project?.analyses[0].deepMediaDiagnostics = DeepMediaDiagnostics(stages: [
            DeepAnalysisStageReport(stage: .asr, ran: false, reason: "On-device ASR недоступен; использованы DSP speech/silence boundaries")
        ])
        #expect(model.aiAnalysisRuntimeStatus.contains("Распознавание речи недоступно"))
    }
}
