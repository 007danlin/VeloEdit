import Foundation

/// The app process never loads Core ML/ONNX alongside a visual model. One
/// killable worker owns speech inference and checkpoints completed source chunks.
public struct WhisperKitSpeechRecognizer: LocalSpeechRecognizing, Sendable {
    public let modelIdentifier = "vlog-whisperkit-turbo-silero-v4"
    public let cacheURL: URL
    public init(cacheURL: URL) { self.cacheURL = cacheURL }
    public func transcribe(url: URL, localeIdentifier: String? = "ru") async throws -> SpeechTranscript? {
        try await SpeechWorkerCoordinator.shared.transcribe(url: url, locale: localeIdentifier ?? "ru", cache: cacheURL)
    }
}
private actor SpeechWorkerCoordinator {
    static let shared = SpeechWorkerCoordinator()
    private var busy = false
    func transcribe(url: URL, locale: String, cache: URL) async throws -> SpeechTranscript {
        while busy { try await Task.sleep(for: .milliseconds(100)) }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        let manifest = try SpeechPackageManifest.bundled()
        guard let package = await SpeechAssetStore.shared.installedURL(manifest: manifest) else { throw SpeechComponentError.unavailable }
        try await SpeechAssetStore.shared.verify(package, manifest: manifest)
        let hash = try SpeechFileHash.file(url)
        let key = SpeechFileHash.data(Data("speech-v4|\(hash)|\(manifest.identity)|track0|mono|\(locale)|chunk24-context2|alignment2".utf8))
        let directory = cache.appendingPathComponent("Speech/" + key, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("transcript.json")
        if let data = try? Data(contentsOf: output), let digest = try? String(contentsOf: output.appendingPathExtension("sha256"), encoding: .utf8), digest == SpeechFileHash.data(data), let value = try? JSONDecoder().decode(SpeechTranscript.self, from: data), value.provenance?.sourceHash == hash, value.provenance?.modelHash == manifest.identity { return value }
        let executableCandidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/VeloEditSpeechWorker"),
                                    Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("VeloEditSpeechWorker")]
        guard let executable = executableCandidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw SpeechComponentError.unavailable }
        let request = SpeechWorkerRequest(sourceURL: url, packageURL: package, cacheURL: directory, outputURL: output, locale: locale.hasPrefix("ru") ? "ru" : locale, sourceHash: hash)
        let requestURL = directory.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        let logURL = directory.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
        let process = Process(); process.executableURL = executable; process.arguments = [requestURL.path]
        process.standardOutput = log; process.standardError = log; process.standardInput = FileHandle.nullDevice
        try process.run()
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw CancellationError()
            }
            let progress = (try? String(contentsOf: output.appendingPathExtension("progress"), encoding: .utf8)) ?? "warmup"
            let counts = progress.split(separator: "/").compactMap { Int($0) }
            await FilmBuildReporting.report(FilmBuildProgress(progress == "warmup" ? .speechWarmup : .speech,
                completed: counts.first, total: counts.count == 2 ? counts[1] : nil, detail: url.lastPathComponent))
            try? await Task.sleep(for: .milliseconds(250))
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "worker exit \(process.terminationStatus)"
            throw SpeechComponentError.workerFailed(String(text.suffix(1000)))
        }
        return try JSONDecoder().decode(SpeechTranscript.self, from: Data(contentsOf: output))
    }
}
