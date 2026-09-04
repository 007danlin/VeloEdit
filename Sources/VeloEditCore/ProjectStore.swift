import Foundation

/// Small, stable metadata used by the home screen without decoding a project
/// manifest that may contain tens of megabytes of analysis and telemetry.
public struct ProjectSummary: Codable, Equatable, Sendable {
    public static let fileName = "project-summary.json"

    public var projectID: UUID
    public var name: String
    public var assetCount: Int
    public var updatedAt: Date
    public var previewKind: MediaKind?
    public var previewRelativePaths: [String]

    public static func load(from packageURL: URL) -> ProjectSummary? {
        let url = packageURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return try? JSONDecoder.veloEdit.decode(ProjectSummary.self, from: data)
    }
}

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
    public var summaryURL: URL { packageURL.appendingPathComponent(ProjectSummary.fileName) }
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
        try? Self.writeSummary(for: self.manifest, at: packageURL)
    }

    public init(open packageURL: URL) throws {
        self.packageURL = packageURL
        let data = try Data(contentsOf: packageURL.appendingPathComponent("project.json"))
        let decoder = JSONDecoder.veloEdit
        let decoded = try decoder.decode(ProjectManifest.self, from: data)
        guard decoded.projectVersion <= 1 else { throw ProjectStoreError.unsupportedProjectVersion(decoded.projectVersion) }
        self.manifest = decoded
        try Self.createDirectories(at: packageURL)
        // Opening an older package also migrates it to the lightweight summary
        // used by recent-project cards.
        try? Self.writeSummary(for: decoded, at: packageURL)
    }

    public func update(_ mutation: (inout ProjectManifest) throws -> Void) throws {
        var next = manifest
        try mutation(&next)
        next.updatedAt = Date()
        try Self.write(next, to: manifestURL)
        try? Self.writeSummary(for: next, at: packageURL)
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
        try? Self.writeSummary(for: manifest, at: packageURL)
        revision &+= 1
    }

    public func reload() throws {
        let data = try Data(contentsOf: manifestURL)
        manifest = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: data)
        try? Self.writeSummary(for: manifest, at: packageURL)
        revision &+= 1
    }

    public func cachedAnalysis(for asset: MediaAsset) -> AnalysisResult? {
        manifest.analyses.first {
            $0.assetID == asset.id &&
            $0.analyzedContentHash == asset.contentHash &&
            $0.schemaVersion == manifest.analysisSchemaVersion &&
            $0.deepMediaVersion == DeepAnalysisCache.version
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

    private static func writeSummary(for manifest: ProjectManifest, at packageURL: URL) throws {
        let assetsByID = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.id, $0) })
        let firstTimelinePair = manifest.timelines.last?.items
            .filter { $0.overlay == nil && $0.kind != .title && $0.assetID != nil }
            .enumerated()
            .sorted {
                if $0.element.timelineStart != $1.element.timelineStart {
                    return $0.element.timelineStart < $1.element.timelineStart
                }
                return $0.offset < $1.offset
            }
            .lazy
            .compactMap { indexed -> (TimelineItem, MediaAsset)? in
                guard let assetID = indexed.element.assetID, let asset = assetsByID[assetID] else { return nil }
                return (indexed.element, asset)
            }
            .first

        let cachePaths = CachePaths(root: packageURL.appendingPathComponent("Cache", isDirectory: true))
        let previewAsset = firstTimelinePair?.1 ?? manifest.assets.first
        var previewURLs: [URL] = []
        if let (item, asset) = firstTimelinePair {
            previewURLs.append(cachePaths.timelineThumbnail(for: item, asset: asset))
        }
        if let previewAsset {
            previewURLs.append(cachePaths.thumbnail(for: previewAsset))
        }
        let packagePrefix = packageURL.standardizedFileURL.path + "/"
        let relativePaths = previewURLs.compactMap { candidate -> String? in
            let path = candidate.standardizedFileURL.path
            guard path.hasPrefix(packagePrefix) else { return nil }
            return String(path.dropFirst(packagePrefix.count))
        }

        let summary = ProjectSummary(
            projectID: manifest.id,
            name: manifest.name,
            assetCount: manifest.assets.count,
            updatedAt: manifest.updatedAt,
            previewKind: previewAsset?.kind,
            previewRelativePaths: relativePaths
        )
        let url = packageURL.appendingPathComponent(ProjectSummary.fileName)
        let data = try JSONEncoder.veloEdit.encode(summary)
        let temporary = packageURL.appendingPathComponent(".summary-\(UUID().uuidString).tmp")
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
        // Project manifests can contain millions of analysis/telemetry values.
        // Pretty printing inflated real projects by roughly 60% and made every
        // autosave parse and write tens of unnecessary megabytes.
        encoder.outputFormatting = [.withoutEscapingSlashes]
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
