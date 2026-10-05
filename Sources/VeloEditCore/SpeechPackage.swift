import Foundation
import CryptoKit

public enum SpeechComponentError: LocalizedError {
    case unavailable, invalidPackage(String), workerFailed(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Для влога нужен локальный речевой пакет. Установите его в параметрах фильма или перенесите с диска. Проект сохранён."
        case .invalidPackage(let detail): return "Речевой пакет не прошёл проверку: \(detail)"
        case .workerFailed(let detail): return "Распознавание речи не завершено: \(detail). Готовые порции сохранены."
        }
    }
}

public struct SpeechPackageManifest: Codable, Sendable {
    public struct File: Codable, Sendable {
        public var path: String
        public var url: URL
        public var sha256: String
        public var bytes: Int64
    }
    public var version: Int
    public var id: String
    public var runtime: String
    public var model: String
    public var revision: String
    public var tokenizerRevision: String
    public var vadRevision: String
    public var preprocessing: String
    public var files: [File]
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    public var identity: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SpeechFileHash.data((try? encoder.encode(self)) ?? Data())
    }

    public static func bundled() throws -> Self {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("Speech/package.json"),
                          URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Speech/package.json")]
        guard let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw SpeechComponentError.unavailable }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    public func validatedFileURL(_ entry: File, in root: URL) throws -> URL {
        guard !entry.path.hasPrefix("/"), !entry.path.split(separator: "/").contains(".."), entry.bytes >= 0,
              entry.sha256.count == 64 else { throw SpeechComponentError.invalidPackage(entry.path) }
        let url = root.appendingPathComponent(entry.path)
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw SpeechComponentError.invalidPackage(entry.path) }
        return url
    }
}

public enum SpeechFileHash {
    public static func data(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func file(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public actor SpeechAssetStore {
    public static let shared = SpeechAssetStore()
    public let root: URL
    private var installing = false
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VeloEdit/Speech", isDirectory: true)
    }
    public func installedURL(manifest: SpeechPackageManifest) -> URL? {
        let installed = root.appendingPathComponent(manifest.id + "-" + manifest.revision.prefix(12))
        let candidates = [installed, Bundle.main.resourceURL?.appendingPathComponent("Speech/ModelsPackage")]
        return candidates.compactMap { $0 }.first { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("package.json")),
                  let stored = try? JSONDecoder().decode(SpeechPackageManifest.self, from: data) else { return false }
            return stored.identity == manifest.identity
        }
    }
    public func verify(_ directory: URL, manifest: SpeechPackageManifest) throws {
        for entry in manifest.files {
            let url = try manifest.validatedFileURL(entry, in: directory)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(size) == entry.bytes, try SpeechFileHash.file(url) == entry.sha256 else { throw SpeechComponentError.invalidPackage(entry.path) }
        }
    }
    public func install(manifest: SpeechPackageManifest, from local: URL? = nil, progress: @escaping @Sendable (Int64, Int64) async -> Void) async throws -> URL {
        guard !installing else { throw SpeechComponentError.invalidPackage("установка уже выполняется") }
        installing = true; defer { installing = false }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if let existing = installedURL(manifest: manifest), (try? verify(existing, manifest: manifest)) != nil { return existing }
        let stage = root.appendingPathComponent(".install-" + manifest.id + "-" + manifest.revision.prefix(12))
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        let free = (try fm.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free > manifest.totalBytes + 256_000_000 else { throw SpeechComponentError.invalidPackage("недостаточно свободного места") }
        var completed: Int64 = 0
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for entry in manifest.files {
            try Task.checkCancellation()
            let destination = try manifest.validatedFileURL(entry, in: stage)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path), (try? SpeechFileHash.file(destination)) == entry.sha256 {
                completed += entry.bytes; await progress(completed, manifest.totalBytes); continue
            }
            if let local {
                let source = try manifest.validatedFileURL(entry, in: local)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: source, to: destination)
            } else {
                guard entry.url.scheme == "https" else { throw SpeechComponentError.invalidPackage("небезопасный адрес загрузки") }
                let partial = destination.appendingPathExtension("partial")
                if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
                let output = try FileHandle(forWritingTo: partial)
                do {
                    var offset = try output.seekToEnd()
                    if offset > entry.bytes { try output.truncate(atOffset: 0); offset = 0 }
                    while offset < entry.bytes {
                        try Task.checkCancellation()
                        let end = min(UInt64(entry.bytes) - 1, offset + 16_777_215)
                        var request = URLRequest(url: entry.url)
                        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                        let (temporary, response) = try await session.download(for: request)
                        defer { try? fm.removeItem(at: temporary) }
                        guard let http = response as? HTTPURLResponse, http.statusCode == 206 || (http.statusCode == 200 && offset == 0) else { throw URLError(.badServerResponse) }
                        if http.statusCode == 206, !(http.value(forHTTPHeaderField: "Content-Range") ?? "").hasPrefix("bytes \(offset)-") { throw URLError(.badServerResponse) }
                        let input = try FileHandle(forReadingFrom: temporary); defer { try? input.close() }
                        let before = offset
                        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
                            try Task.checkCancellation(); try output.write(contentsOf: bytes); offset += UInt64(bytes.count)
                        }
                        guard offset > before, offset <= entry.bytes else { throw URLError(.badServerResponse) }
                        await progress(completed + Int64(offset), manifest.totalBytes)
                    }
                    try output.close()
                } catch { try? output.close(); throw error }
                guard try SpeechFileHash.file(partial) == entry.sha256 else { try? fm.removeItem(at: partial); throw SpeechComponentError.invalidPackage(entry.path) }
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: partial, to: destination)
            }
            guard try SpeechFileHash.file(destination) == entry.sha256 else { throw SpeechComponentError.invalidPackage(entry.path) }
            completed += entry.bytes; await progress(completed, manifest.totalBytes)
        }
        try verify(stage, manifest: manifest)
        try JSONEncoder().encode(manifest).write(to: stage.appendingPathComponent("package.json"), options: .atomic)
        let final = root.appendingPathComponent(manifest.id + "-" + manifest.revision.prefix(12))
        let backup = root.appendingPathComponent(".replaced-" + UUID().uuidString)
        if fm.fileExists(atPath: final.path) { try fm.moveItem(at: final, to: backup) }
        do { try fm.moveItem(at: stage, to: final) }
        catch { if fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: backup, to: final) }; throw error }
        try? fm.removeItem(at: backup)
        return final
    }
}
