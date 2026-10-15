import Foundation
import WhisperKit

struct SpeechRecognitionBatch {
    var segments: [TranscriptionSegment]
    var language: String
}

protocol SpeechPipeline {
    func transcribe(_ samples: [Float], language: String, detectLanguage: Bool) async throws -> SpeechRecognitionBatch
}

final class CoreMLSpeechPipeline: SpeechPipeline {
    private let pipe: WhisperKit

    init(package: URL) async throws {
        pipe = try await WhisperKit(WhisperKitConfig(
            modelFolder: package.appendingPathComponent("model").path,
            tokenizerFolder: package.appendingPathComponent("tokenizer"),
            computeOptions: ModelComputeOptions(), verbose: true, logLevel: .debug,
            prewarm: true, load: true, download: false))
    }

    func transcribe(_ samples: [Float], language: String, detectLanguage: Bool) async throws -> SpeechRecognitionBatch {
        var language = language
        if detectLanguage, let detected = try? await pipe.detectLangauge(audioArray: samples),
           (detected.langProbs[detected.language] ?? 0) >= 0.85 {
            language = detected.language
        }
        let options = DecodingOptions(task: .transcribe, language: language, temperatureFallbackCount: 2,
            detectLanguage: false, skipSpecialTokens: true, wordTimestamps: true, concurrentWorkerCount: 1)
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return SpeechRecognitionBatch(segments: results.flatMap(\.segments), language: language)
    }
}
