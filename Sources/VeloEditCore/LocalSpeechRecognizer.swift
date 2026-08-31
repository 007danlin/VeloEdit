import Foundation
import Speech

/// Optional Apple on-device ASR backend. It never requests cloud recognition:
/// when the locale/model or Speech permission is unavailable, the caller gets
/// `nil` and the editing pipeline falls back to DSP speech/silence boundaries.
public struct AppleOnDeviceSpeechRecognizer: LocalSpeechRecognizing, Sendable {
    public let modelIdentifier = "apple-speech-on-device-v1"
    public init() {}

    public func transcribe(url: URL, localeIdentifier: String? = nil) async throws -> SpeechTranscript? {
        guard await speechAuthorizationGranted() else { return nil }
        let locales = [localeIdentifier, Locale.current.identifier, "ru-RU", "en-US"].compactMap { $0 }
        guard let recognizer = locales.lazy.compactMap({ SFSpeechRecognizer(locale: Locale(identifier: $0)) }).first(where: { $0.isAvailable && $0.supportsOnDeviceRecognition }) else {
            return nil
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let result = try await recognize(request: request, recognizer: recognizer)
        guard !result.bestTranscription.segments.isEmpty else { return nil }
        let words = result.bestTranscription.segments.map { segment in
            TranscriptWord(
                text: segment.substring,
                startTime: segment.timestamp,
                duration: segment.duration,
                confidence: Double(segment.confidence)
            )
        }
        let sentences = Self.sentences(from: words)
        let silences = Self.silenceBoundaries(words: words)
        let confidence = words.reduce(0) { $0 + $1.confidence } / Double(max(1, words.count))
        return SpeechTranscript(
            localeIdentifier: recognizer.locale.identifier,
            words: words,
            sentences: sentences,
            silenceBoundaries: silences,
            confidence: confidence,
            usedOnDeviceRecognition: true
        )
    }

    private func speechAuthorizationGranted() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func recognize(request: SFSpeechRecognitionRequest, recognizer: SFSpeechRecognizer) async throws -> SFSpeechRecognitionResult {
        try await withCheckedThrowingContinuation { continuation in
            let state = SpeechContinuationState()
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal, state.finish() {
                    continuation.resume(returning: result)
                } else if let error, state.finish() {
                    continuation.resume(throwing: error)
                }
            }
            state.retain(task)
        }
    }

    private static func sentences(from words: [TranscriptWord]) -> [TranscriptSentence] {
        guard !words.isEmpty else { return [] }
        var groups: [[TranscriptWord]] = [[]]
        for word in words {
            if let previous = groups.last?.last,
               word.startTime - previous.endTime > 0.72,
               !(groups.last?.isEmpty ?? true) {
                groups.append([])
            }
            groups[groups.count - 1].append(word)
            if word.text.last.map({ ".!?…".contains($0) }) == true { groups.append([]) }
        }
        return groups.filter { !$0.isEmpty }.map { group in
            TranscriptSentence(
                text: group.map(\.text).joined(separator: " "),
                startTime: group[0].startTime,
                endTime: group.last?.endTime ?? group[0].endTime,
                confidence: group.reduce(0) { $0 + $1.confidence } / Double(group.count)
            )
        }
    }

    private static func silenceBoundaries(words: [TranscriptWord]) -> [ClosedRange<Double>] {
        guard !words.isEmpty else { return [] }
        var values: [ClosedRange<Double>] = []
        if let first = words.first, first.startTime >= 0.18 { values.append(0...first.startTime) }
        for pair in zip(words, words.dropFirst()) where pair.1.startTime - pair.0.endTime >= 0.18 {
            values.append(pair.0.endTime...pair.1.startTime)
        }
        return values
    }
}

private final class SpeechContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var task: SFSpeechRecognitionTask?

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        task = nil
        return true
    }

    func retain(_ value: SFSpeechRecognitionTask) {
        lock.lock()
        task = finished ? nil : value
        lock.unlock()
    }
}
