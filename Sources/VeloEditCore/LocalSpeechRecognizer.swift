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
        let locales = localeIdentifier.map { [$0] } ?? [Locale.current.identifier]
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
            // Consent belongs to the interactive app. Headless CLI/test runs
            // must report the optional ASR stage unavailable, not trigger TCC
            // against an unsigned runner or wait for an invisible prompt.
            guard Bundle.main.bundleURL.pathExtension == "app",
                  Bundle.main.executableURL?.lastPathComponent == "VeloEdit",
                  Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") is String else { return false }
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
        let state = SpeechContinuationState()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { return }
            state.complete(.failure(URLError(.timedOut)))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard state.install(continuation) else { return }
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal { state.complete(.success(result)) }
                    else if let error { state.complete(.failure(error)) }
                }
                state.retain(task)
            }
        } onCancel: {
            state.complete(.failure(CancellationError()))
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

/// Resolves once, including cancellation before the Apple callback is installed.
final class SpeechContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<SFSpeechRecognitionResult, Error>?
    private var continuation: CheckedContinuation<SFSpeechRecognitionResult, Error>?
    private var task: SFSpeechRecognitionTask?

    func install(_ continuation: CheckedContinuation<SFSpeechRecognitionResult, Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func complete(_ result: Result<SFSpeechRecognitionResult, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        self.task = nil
        lock.unlock()
        if case .failure = result { task?.cancel() }
        continuation?.resume(with: result)
    }

    func retain(_ value: SFSpeechRecognitionTask) {
        lock.lock()
        let completed = result != nil
        task = completed ? nil : value
        lock.unlock()
        if completed { value.cancel() }
    }
}
