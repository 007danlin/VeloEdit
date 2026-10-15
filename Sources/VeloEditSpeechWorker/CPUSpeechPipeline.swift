import CWhisper
import Foundation
import WhisperKit
import VeloEditCore

/// Runs in the existing isolated speech worker. Killing that worker also stops
/// inference: there is no child CLI process or separate model download.
final class CPUSpeechPipeline: SpeechPipeline {
    private let context: OpaquePointer
    private let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1)))

    init(package: URL) throws {
        var options = whisper_context_default_params()
        options.use_gpu = false
        options.flash_attn = false
        options.dtw_token_timestamps = true
        options.dtw_aheads_preset = WHISPER_AHEADS_LARGE_V3_TURBO
        let model = package.appendingPathComponent("cpu/ggml-large-v3-turbo-q5_0.bin")
        guard let context = model.path.withCString({ whisper_init_from_file_with_params($0, options) }) else {
            throw SpeechComponentError.workerFailed("whisper.cpp: не удалось загрузить CPU-модель large-v3-turbo")
        }
        self.context = context
        FileHandle.standardError.write(Data(("whisper.cpp CPU features: " + String(cString: whisper_print_system_info()) + "\n").utf8))
    }

    deinit { whisper_free(context) }

    func transcribe(_ samples: [Float], language: String, detectLanguage: Bool) async throws -> SpeechRecognitionBatch {
        try Task.checkCancellation()
        guard !samples.isEmpty, samples.count <= Int(Int32.max), samples.allSatisfy(\.isFinite) else {
            throw SpeechComponentError.workerFailed("whisper.cpp: некорректные аудиоданные")
        }
        var language = language
        // Match the existing confidence gate for automatic language selection.
        // Reuse the mel buffer for detection; whisper_full prepares its own input.
        if detectLanguage {
            let melStatus = samples.withUnsafeBufferPointer {
                whisper_pcm_to_mel(context, $0.baseAddress, Int32($0.count), threads)
            }
            guard melStatus == 0 else { throw SpeechComponentError.workerFailed("whisper.cpp: спектр аудио, код \(melStatus)") }
            var probabilities = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
            let detected = probabilities.withUnsafeMutableBufferPointer {
                whisper_lang_auto_detect(context, 0, threads, $0.baseAddress)
            }
            if detected >= 0, Int(detected) < probabilities.count, probabilities[Int(detected)] >= 0.85,
               let name = whisper_lang_str(detected) { language = String(cString: name) }
        }
        if language.withCString({ whisper_lang_id($0) }) < 0 { language = "auto" }
        var options = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        options.n_threads = threads
        options.no_context = true
        options.token_timestamps = true
        options.print_progress = false
        options.print_realtime = false
        options.print_timestamps = false
        options.greedy.best_of = 1
        // Silero remains the independent VAD; do not filter away quiet inputs.
        options.vad = false
        let status = language.withCString { name in
            options.language = name
            return samples.withUnsafeBufferPointer {
                whisper_full(context, options, $0.baseAddress, Int32($0.count))
            }
        }
        guard status == 0 else { throw SpeechComponentError.workerFailed("whisper.cpp: распознавание, код \(status)") }
        try Task.checkCancellation()
        var segments: [TranscriptionSegment] = []
        for index in 0..<whisper_full_n_segments(context) {
            let text = String(cString: whisper_full_get_segment_text(context, index))
            var tokens: [CPUSpeechToken] = []
            for position in 0..<whisper_full_n_tokens(context, index) {
                let token = whisper_full_get_token_data(context, index, position)
                guard token.id < whisper_token_eot(context) else { continue }
                let bytes = whisper_full_get_token_text(context, index, position)!
                // BPE can split a Cyrillic UTF-8 character across tokens. Decode
                // only after joining bytes, never String(cString:) per token.
                let data = Data(bytes: bytes, count: strlen(bytes))
                tokens.append(CPUSpeechToken(id: Int(token.id), bytes: data, start: Float(token.t0) / 100,
                    end: Float(token.t1) / 100, probability: token.p, logProbability: token.plog,
                    alignmentTime: token.t_dtw >= 0 ? Float(token.t_dtw) / 100 : nil))
            }
            let averageLogProbability = tokens.isEmpty ? -100 : tokens.map(\.logProbability).reduce(0, +) / Float(tokens.count)
            segments.append(TranscriptionSegment(id: Int(index),
                start: Float(whisper_full_get_segment_t0(context, index)) / 100,
                end: Float(whisper_full_get_segment_t1(context, index)) / 100,
                text: text, tokens: tokens.map(\.id), temperature: options.temperature,
                avgLogprob: averageLogProbability, compressionRatio: TextUtilities.compressionRatio(of: text),
                noSpeechProb: whisper_full_get_segment_no_speech_prob(context, index),
                words: CPUSpeechToken.words(from: tokens)))
        }
        let detectedLanguage = whisper_full_lang_id(context)
        if let name = whisper_lang_str(detectedLanguage) { language = String(cString: name) }
        return SpeechRecognitionBatch(segments: segments, language: language)
    }
}

struct CPUSpeechToken {
    var id: Int
    var bytes: Data
    var start: Float
    var end: Float
    var probability: Float
    var logProbability: Float
    var alignmentTime: Float? = nil

    static func words(from tokens: [Self]) -> [WordTiming] {
        var words: [WordTiming] = []
        var alignments: [(first: Float?, last: Float?)] = []
        var pending: [Self] = []
        func flush() {
            guard let first = pending.first, let last = pending.last else { return }
            let data = pending.reduce(into: Data()) { $0.append($1.bytes) }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                words.append(WordTiming(word: text, tokens: pending.map(\.id), start: first.start, end: last.end,
                    probability: pending.map(\.probability).reduce(0, +) / Float(pending.count)))
                alignments.append((first.alignmentTime, pending.compactMap(\.alignmentTime).last))
            }
            pending.removeAll(keepingCapacity: true)
        }
        for token in tokens {
            if token.bytes.first.map({ $0 == 32 || $0 == 10 || $0 == 9 }) == true { flush() }
            pending.append(token)
        }
        flush()
        // The legacy timestamp heuristic can put the first word in leading
        // silence. Use measured cross-attention DTW transitions instead. Hold
        // each word until the next word's transition; the final word ends at
        // its last transition (or the model's segment/token end when needed).
        for index in words.indices {
            guard let start = alignments[index].first, start.isFinite else { continue }
            let nextStart = index + 1 < words.count ? alignments[index + 1].first : nil
            let end = nextStart ?? alignments[index].last.flatMap { $0 > start ? $0 : nil } ?? words[index].end
            words[index].start = start
            words[index].end = end
        }
        return words
    }
}
