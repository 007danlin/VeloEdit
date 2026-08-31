import Foundation

public enum ProjectStoreError: LocalizedError {
    case invalidProjectPackage(URL)
    case unsupportedProjectVersion(Int)
    case staleRevision(expected: UInt64, actual: UInt64)

    public var errorDescription: String? {
        switch self {
        case .invalidProjectPackage(let url): return "Некорректный проект: \(url.path)"
        case .unsupportedProjectVersion(let version): return "Версия проекта \(version) пока не поддерживается"
        case .staleRevision(let expected, let actual):
            return "Фоновый результат устарел: проект уже изменён (ожидалась ревизия \(expected), текущая \(actual))"
        }
    }
}

/// An immutable manifest and the in-process revision that produced it. Long
/// background operations must commit against this token instead of replacing
/// newer user edits with results computed from an old snapshot.
public struct ProjectStoreSnapshot: Sendable {
    public let manifest: ProjectManifest
    public let revision: UInt64

    public init(manifest: ProjectManifest, revision: UInt64) {
        self.manifest = manifest
        self.revision = revision
    }
}

public actor ProjectStore {
    public static let packageExtension = "veloedit"
    public let packageURL: URL
    public private(set) var manifest: ProjectManifest
    private var revision: UInt64 = 0

    public var manifestURL: URL { packageURL.appendingPathComponent("project.json") }
    public var cacheURL: URL { packageURL.appendingPathComponent("Cache", isDirectory: true) }
    public var thumbnailsURL: URL { cacheURL.appendingPathComponent("Thumbnails", isDirectory: true) }
    public var proxiesURL: URL { cacheURL.appendingPathComponent("Proxies", isDirectory: true) }
    public var previewsURL: URL { cacheURL.appendingPathComponent("Preview", isDirectory: true) }
    public var exportsURL: URL { packageURL.appendingPathComponent("Exports", isDirectory: true) }
    public var logsURL: URL { packageURL.appendingPathComponent("Logs", isDirectory: true) }
    public nonisolated var musicLibraryURL: URL { packageURL.appendingPathComponent("MusicLibrary", isDirectory: true) }

    public init(createAt packageURL: URL, name: String) throws {
        self.packageURL = packageURL
        self.manifest = ProjectManifest(name: name)
        try Self.createDirectories(at: packageURL)
        try Self.write(self.manifest, to: packageURL.appendingPathComponent("project.json"))
    }

    public init(open packageURL: URL) throws {
        self.packageURL = packageURL
        let data = try Data(contentsOf: packageURL.appendingPathComponent("project.json"))
        let decoder = JSONDecoder.veloEdit
        let decoded = try decoder.decode(ProjectManifest.self, from: data)
        guard decoded.projectVersion <= 1 else { throw ProjectStoreError.unsupportedProjectVersion(decoded.projectVersion) }
        self.manifest = decoded
        try Self.createDirectories(at: packageURL)
    }

    public func update(_ mutation: (inout ProjectManifest) throws -> Void) throws {
        var next = manifest
        try mutation(&next)
        next.updatedAt = Date()
        try Self.write(next, to: manifestURL)
        manifest = next
        revision &+= 1
    }

    /// Compare-and-swap persistence for work that crossed an `await`. The
    /// mutation is never evaluated when the token is stale, keeping a newer
    /// manual Timeline edit authoritative over an older AI/analysis result.
    public func update(
        ifRevision expectedRevision: UInt64,
        _ mutation: (inout ProjectManifest) throws -> Void
    ) throws {
        guard revision == expectedRevision else {
            throw ProjectStoreError.staleRevision(expected: expectedRevision, actual: revision)
        }
        try update(mutation)
    }

    public func snapshot() -> ProjectStoreSnapshot {
        ProjectStoreSnapshot(manifest: manifest, revision: revision)
    }

    public func currentRevision() -> UInt64 { revision }

    public func save() throws {
        manifest.updatedAt = Date()
        try Self.write(manifest, to: manifestURL)
        revision &+= 1
    }

    public func reload() throws {
        let data = try Data(contentsOf: manifestURL)
        manifest = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: data)
        revision &+= 1
    }

    public func cachedAnalysis(for asset: MediaAsset) -> AnalysisResult? {
        manifest.analyses.first {
            $0.assetID == asset.id &&
            $0.analyzedContentHash == asset.contentHash &&
            $0.schemaVersion == manifest.analysisSchemaVersion
        }
    }

    public func resolveURL(for asset: MediaAsset) -> URL? {
        if FileManager.default.fileExists(atPath: asset.originalURL.path) { return asset.originalURL }
        guard let bookmark = asset.bookmarkData else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private static func createDirectories(at packageURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        for relative in ["Cache/Thumbnails", "Cache/TimelineThumbnails", "Cache/Proxies", "Cache/Frames", "Cache/Analysis", "Cache/Preview", "Cache/Backgrounds", "Exports", "Logs", "MusicLibrary/Files"] {
            try fm.createDirectory(at: packageURL.appendingPathComponent(relative, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    private static func write(_ manifest: ProjectManifest, to url: URL) throws {
        let data = try JSONEncoder.veloEdit.encode(manifest)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".project-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: url)
        }
    }
}

public extension JSONEncoder {
    static var veloEdit: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    static var veloEdit: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
