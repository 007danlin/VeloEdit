import Foundation
import AVFoundation
import Darwin
import WhisperKit
import OnnxRuntimeBindings
import VeloEditCore

private struct Chunk: Codable {
    var index: Int
    var words: [TranscriptWord]
    var phrases: [TranscriptSentence]
    var speech: [ClosedRange<Double>]
    var silence: [ClosedRange<Double>]
    var warnings: [String]
    var language: String
    var rawText: String
    var diagnostics: [SpeechSegmentDiagnostic]?
}

@main struct SpeechWorker {
    static func main() async {
        do {
            if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--sample" {
                try await sample(requestFile: URL(fileURLWithPath: CommandLine.arguments[2]), start: Double(CommandLine.arguments[3]) ?? 0, duration: Double(CommandLine.arguments[4]) ?? 40)
                return
            }
            guard CommandLine.arguments.count == 2 else { throw SpeechComponentError.workerFailed("request file required") }
            let request = try JSONDecoder().decode(SpeechWorkerRequest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            try await run(request)
        } catch {
            FileHandle.standardError.write(Data((String(reflecting: error) + "\n" + (error as NSError).userInfo.description).utf8)); exit(1)
        }
    }
    static func sample(requestFile: URL, start: Double, duration: Double) async throws {
        let request = try JSONDecoder().decode(SpeechWorkerRequest.self, from: Data(contentsOf: requestFile))
        let transcript = try JSONDecoder().decode(SpeechTranscript.self, from: Data(contentsOf: request.outputURL))
        let asset = try await MediaImporter().makeAsset(url: request.sourceURL)
        let records = [SpeechSourceRecord(assetID: asset.id, transcript: transcript)]
        let vertical = (asset.displayAspectRatio ?? 1.78) < 1
        var timeline = Timeline(storyPlanID: UUID(), width: vertical ? 1080 : 1920, height: vertical ? 1920 : 1080,
            items: [TimelineItem(assetID: asset.id, kind: .video, sourceStart: start, sourceDuration: duration, timelineStart: 0, timelineDuration: duration)], originalAudioVolume: 1)
        timeline.speechRecords = records
        timeline = SpeechSubtitleBuilder.applying(to: timeline, records: records, enabled: true)
        let output = request.outputURL.deletingPathExtension().appendingPathExtension("sample.mp4")
        try Data(SubtitleFileExporter.render(timeline: timeline, format: .srt).utf8).write(to: output.deletingPathExtension().appendingPathExtension("srt"), options: .atomic)
        try JSONEncoder().encode(timeline).write(to: output.deletingPathExtension().appendingPathExtension("timeline.json"), options: .atomic)
        _ = try await RenderEngine().render(timeline: timeline, assets: [asset], quality: .preview720p, destination: output)
        print(output.path)
    }

    static func run(_ request: SpeechWorkerRequest) async throws {
        let manifest = try JSONDecoder().decode(SpeechPackageManifest.self, from: Data(contentsOf: request.packageURL.appendingPathComponent("package.json")))
        let asset = AVURLAsset(url: request.sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite && duration > 0, let track = try await asset.loadTracks(withMediaType: .audio).first else { throw SpeechComponentError.workerFailed("нет звуковой дорожки") }
        try FileManager.default.createDirectory(at: request.cacheURL, withIntermediateDirectories: true)
        let statusURL = request.outputURL.appendingPathExtension("progress")
        try Data("warmup".utf8).write(to: statusURL, options: .atomic)
        let warmupStart = ProcessInfo.processInfo.systemUptime
        var decodeSeconds = 0.0, vadSeconds = 0.0, asrSeconds = 0.0
        var resumedChunks = 0
        let pipe = try await WhisperKit(WhisperKitConfig(modelFolder: request.packageURL.appendingPathComponent("model").path,
            tokenizerFolder: request.packageURL.appendingPathComponent("tokenizer"), verbose: true, prewarm: true, load: true, download: false))
        let vad = try SileroDetector(model: request.packageURL.appendingPathComponent("silero_vad.onnx"))
        let warmupSeconds = (ProcessInfo.processInfo.systemUptime - warmupStart)
        var chunks: [Chunk] = []
        let count = Int(ceil(duration / 24))
        for index in 0..<count {
            while await SystemResourceMonitor.shared.snapshot().workLimit == .cooling {
                try await Task.sleep(for: .milliseconds(500))
            }
            let file = request.cacheURL.appendingPathComponent(String(format: "%06d.json", index))
            let digestFile = file.appendingPathExtension("sha256")
            if let data = try? Data(contentsOf: file), let hash = try? String(contentsOf: digestFile, encoding: .utf8),
               hash == SpeechFileHash.data(data), let chunk = try? JSONDecoder().decode(Chunk.self, from: data), chunk.index == index {
                chunks.append(chunk); resumedChunks += 1; continue
            }
            let coreStart = Double(index) * 24; let coreEnd = min(duration, coreStart + 24)
            let start = max(0, coreStart - 2); let end = min(duration, coreEnd + 2)
            let decodeStart = ProcessInfo.processInfo.systemUptime
            let samples = try audio(asset: asset, track: track, start: start, end: end)
            decodeSeconds += (ProcessInfo.processInfo.systemUptime - decodeStart)
            let vadStart = ProcessInfo.processInfo.systemUptime
            let activity = try vad.analyze(samples)
            vadSeconds += (ProcessInfo.processInfo.systemUptime - vadStart)
            var chunk = Chunk(index: index, words: [], phrases: [], speech: [], silence: [], warnings: [], language: request.locale, rawText: "")
            chunk.speech = ranges(activity.speech, frame: 0.032, offset: start, lower: coreStart, upper: coreEnd)
            chunk.silence = ranges(activity.silence, frame: 0.032, offset: start, lower: coreStart, upper: coreEnd)
            // Always run ASR on audio, including low-energy voice. VAD is a second
            // independent signal, never a gate that drops quiet recordings.
            var language = request.locale
            if activity.speech.contains(true), let detected = try? await pipe.detectLangauge(audioArray: samples), (detected.langProbs[detected.language] ?? 0) >= 0.85 {
                language = detected.language
            }
            chunk.language = language
            let options = DecodingOptions(task: .transcribe, language: language, temperatureFallbackCount: 2, detectLanguage: false, skipSpecialTokens: true, wordTimestamps: true, concurrentWorkerCount: 1)
            let asrStart = ProcessInfo.processInfo.systemUptime
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            asrSeconds += (ProcessInfo.processInfo.systemUptime - asrStart)
            let speech = ranges(activity.speech, frame: 0.032, offset: start, lower: start, upper: end)
            append(segments: results.flatMap(\.segments), offset: start, end: end, core: coreStart...coreEnd, speech: speech, attempt: 0, to: &chunk)
            // Retry only a chunk with detected voice and no publishable words.
            // Shorter overlapping contexts recover long-window alignment failures;
            // accepted chunks are never sent through a second full-file recognizer.
            if !chunk.speech.isEmpty && chunk.words.isEmpty && chunk.phrases.isEmpty {
                var retry = Chunk(index: index, words: [], phrases: [], speech: chunk.speech, silence: chunk.silence, warnings: [], language: language, rawText: "")
                for part in stride(from: coreStart, to: coreEnd, by: 12) {
                    let lo = max(start, part - 1); let hi = min(end, part + 13)
                    let slice = Array(samples[Int(((lo - start) * 16000).rounded())..<min(samples.count, Int(((hi - start) * 16000).rounded()))])
                    let retryStart = ProcessInfo.processInfo.systemUptime
                    let result = try await pipe.transcribe(audioArray: slice, decodeOptions: options)
                    asrSeconds += (ProcessInfo.processInfo.systemUptime - retryStart)
                    append(segments: result.flatMap(\.segments), offset: lo, end: hi, core: part...min(coreEnd, part + 12), speech: speech, attempt: 1, to: &retry)
                }
                if !retry.words.isEmpty || !retry.phrases.isEmpty {
                    retry.diagnostics = (chunk.diagnostics ?? []) + (retry.diagnostics ?? [])
                    retry.rawText = chunk.rawText + "\n[retry] " + retry.rawText
                    chunk = retry
                } else { chunk.diagnostics = (chunk.diagnostics ?? []) + (retry.diagnostics ?? []) }
            }
            if !chunk.speech.isEmpty && chunk.words.isEmpty && chunk.phrases.isEmpty { chunk.warnings.append("VAD обнаружил возможную речь без подтверждённого текста: \(Int(coreStart))–\(Int(coreEnd)) с") }
            let data = try JSONEncoder().encode(chunk)
            try data.write(to: file, options: .atomic)
            try Data(SpeechFileHash.data(data).utf8).write(to: digestFile, options: .atomic)
            chunks.append(chunk)
            try Data("\(index + 1)/\(count)".utf8).write(to: statusURL, options: .atomic)
        }
        var words: [TranscriptWord] = []
        for word in chunks.flatMap(\.words).sorted(by: { $0.startTime < $1.startTime }) {
            if let last = words.last, last.text.lowercased() == word.text.lowercased(), word.startTime < last.endTime { continue }
            words.append(word)
        }
        var sentences = chunks.flatMap(\.phrases)
        var group: [TranscriptWord] = []
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            sentences.append(TranscriptSentence(text: group.map(\.text).joined(separator: " "), startTime: first.startTime, endTime: last.endTime, confidence: group.map(\.confidence).reduce(0,+) / Double(group.count)))
            group = []
        }
        for word in words {
            if let last = group.last, word.startTime - last.endTime > 0.8 { flush() }
            group.append(word)
            if word.text.last.map({ ".!?…".contains($0) }) == true { flush() }
        }
        flush()
        let warnings = chunks.flatMap(\.warnings)
        var transcript = SpeechTranscript(localeIdentifier: chunks.first?.language ?? request.locale, words: words,
            sentences: sentences.sorted { $0.startTime < $1.startTime }, silenceBoundaries: merge(chunks.flatMap(\.silence)),
            confidence: words.isEmpty ? 0 : words.map(\.confidence).reduce(0,+) / Double(words.count))
        transcript.provenance = SpeechProvenance(manifest: manifest, sourceHash: request.sourceHash)
        transcript.speechRanges = merge(chunks.flatMap(\.speech)); transcript.rawText = chunks.map(\.rawText).joined(separator: "\n")
        transcript.warnings = warnings
        transcript.status = !warnings.isEmpty ? .partial : (sentences.isEmpty ? .noSpeech : .ready)
        transcript.segmentDiagnostics = chunks.flatMap { $0.diagnostics ?? [] }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        transcript.runtimeMetrics = SpeechRuntimeMetrics(warmupSeconds: warmupSeconds, decodeSeconds: decodeSeconds, vadSeconds: vadSeconds, asrAndAlignmentSeconds: asrSeconds, peakResidentBytes: UInt64(max(0, usage.ru_maxrss)), resumedChunks: resumedChunks)
        let encoded = try JSONEncoder().encode(transcript)
        try encoded.write(to: request.outputURL, options: .atomic)
        try Data(SpeechFileHash.data(encoded).utf8).write(to: request.outputURL.appendingPathExtension("sha256"), options: .atomic)
    }
    private static func append(segments: [TranscriptionSegment], offset: Double, end: Double, core: ClosedRange<Double>, speech: [ClosedRange<Double>], attempt: Int, to chunk: inout Chunk) {
        chunk.rawText += segments.map(\.text).joined(separator: " ")
        for segment in segments {
            let a = offset + Double(segment.start); let b = offset + Double(segment.end)
            let hasVoice = speech.contains { $0.lowerBound < b && $0.upperBound > a }
            let nonempty = !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let validBounds = a.isFinite && b.isFinite && b > a && a >= offset - 0.03 && a < end
            // Whisper's no-speech rule is conjunctive: a high noSpeechProb alone
            // must not discard a confident sentence. VAD remains independent.
            let plausible = hasVoice && segment.avgLogprob > -1.0 && segment.compressionRatio < 2.4
            var decision = "accepted"
            if !nonempty { decision = "empty" }
            else if !validBounds { decision = "invalid-bounds" }
            else if !hasVoice { decision = "no-vad-speech" }
            else if !plausible { decision = "uncertain" }
            chunk.diagnostics = (chunk.diagnostics ?? []) + [SpeechSegmentDiagnostic(start: a, end: b, averageLogProbability: Double(segment.avgLogprob), noSpeechProbability: Double(segment.noSpeechProb), compressionRatio: Double(segment.compressionRatio), text: segment.text, decision: decision, attempt: attempt)]
            guard nonempty else { continue }
            if validBounds && !hasVoice && segment.avgLogprob > -1.0 && segment.compressionRatio < 2.4 {
                chunk.warnings.append("ASR и VAD расходятся около \(Int(max(0, a))) с; текст не подтверждён, исходный голос сохранён")
            }
            guard validBounds, plausible else {
                if hasVoice { chunk.warnings.append("Неразборчивая речь \(Int(max(0, a)))–\(Int(min(end, max(0, b)))) с; исходный голос сохранён") }
                continue
            }
            // A padded segment may end at 30 s. Its measured words inside the
            // real audio are still useful; never clamp an out-of-bounds word.
            let validWords = (segment.words ?? []).filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && $0.start >= 0 && offset + Double($0.end) <= end + 0.001 }
            if validWords.isEmpty {
                if a >= core.lowerBound && b <= core.upperBound {
                    chunk.phrases.append(TranscriptSentence(text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines), startTime: a, endTime: b, confidence: Double(exp(segment.avgLogprob))))
                } else { chunk.warnings.append("Фраза на границе порции требует проверки: \(Int(a)) с") }
            } else {
                for word in validWords {
                    let midpoint = offset + Double(word.start + word.end) / 2
                    guard midpoint >= core.lowerBound, midpoint < core.upperBound else { continue }
                    let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    chunk.words.append(TranscriptWord(text: text, startTime: offset + Double(word.start), duration: Double(word.end - word.start), confidence: Double(word.probability)))
                }
            }
        }
    }
    static func audio(asset: AVAsset, track: AVAssetTrack, start: Double, end: Double) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 16000), duration: CMTime(seconds: end - start, preferredTimescale: 16000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); guard reader.startReading() else { throw reader.error ?? SpeechComponentError.workerFailed("декодирование аудио") }
        var samples = [Float](repeating: 0, count: Int(ceil((end - start) * 16000)))
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { continue }
            let position = Int(((CMSampleBufferGetPresentationTimeStamp(sample).seconds - start) * 16000).rounded())
            data.withUnsafeBytes { bytes in
                let values = bytes.bindMemory(to: Float.self)
                let lo = max(0, -position); let hi = min(values.count, samples.count - position)
                if hi > lo { for i in lo..<hi { samples[position + i] = values[i] } }
            }
        }
        if reader.status == .failed { throw reader.error ?? SpeechComponentError.workerFailed("декодирование аудио") }
        return samples
    }
    static func ranges(_ flags: [Bool], frame: Double, offset: Double, lower: Double, upper: Double) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []; var start: Int?
        for i in 0...flags.count {
            if i < flags.count && flags[i] { if start == nil { start = i } }
            else if let first = start {
                let a = max(lower, offset + Double(first) * frame); let b = min(upper, offset + Double(i) * frame)
                if b > a { result.append(a...b) }; start = nil
            }
        }
        return result
    }
    static func merge(_ values: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in values.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound + 0.04 { result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound) }
            else { result.append(range) }
        }
        return result
    }
}

private final class SileroDetector {
    let env: ORTEnv
    let session: ORTSession
    init(model: URL) throws {
        env = try ORTEnv(loggingLevel: .error)
        let options = try ORTSessionOptions(); try options.setIntraOpNumThreads(1)
        session = try ORTSession(env: env, modelPath: model.path, sessionOptions: options)
    }
    func analyze(_ samples: [Float]) throws -> (speech: [Bool], silence: [Bool]) {
        var state = [Float](repeating: 0, count: 256); var context = [Float](repeating: 0, count: 64)
        var speech: [Bool] = []; var silence: [Bool] = []
        let rate = [Int64(16000)]
        let sr = try ORTValue(tensorData: NSMutableData(data: rate.withUnsafeBytes { Data($0) }), elementType: .int64, shape: [])
        for offset in stride(from: 0, to: samples.count, by: 512) {
            var frame = Array(samples[offset..<min(offset + 512, samples.count)])
            frame += Array(repeating: 0, count: 512 - frame.count)
            let input = context + frame
            let x = try ORTValue(tensorData: NSMutableData(data: input.withUnsafeBytes { Data($0) }), elementType: .float, shape: [1, 576])
            let h = try ORTValue(tensorData: NSMutableData(data: state.withUnsafeBytes { Data($0) }), elementType: .float, shape: [2, 1, 128])
            let out = try session.run(withInputs: ["input": x, "state": h, "sr": sr], outputNames: ["output", "stateN"], runOptions: nil)
            guard let probability = out["output"], let next = out["stateN"] else { throw SpeechComponentError.workerFailed("Silero output") }
            let p = (try probability.tensorData() as Data).withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            state = (try next.tensorData() as Data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            context = Array(frame.suffix(64))
            speech.append(p >= 0.35)
            let rms = sqrt(frame.reduce(Float(0)) { $0 + $1 * $1 } / 512)
            silence.append(p < 0.15 && rms < 0.007)
        }
        return (speech, silence)
    }
}
