import Foundation

public enum ProjectCacheCategory: String, CaseIterable, Identifiable, Sendable {
    case proxies, previews, thumbnails, analysis
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .proxies: return "Прокси"
        case .previews: return "Предпросмотры"
        case .thumbnails: return "Миниатюры"
        case .analysis: return "Промежуточные данные ИИ"
        }
    }
    var directories: [String] {
        switch self {
        case .proxies: return ["Proxies"]
        case .previews: return ["Preview", "Frames", "EditorialControlExports", "EditorialRejected"]
        case .thumbnails: return ["Thumbnails", "TimelineThumbnails"]
        case .analysis: return ["Analysis", "EditorialEvidence", "EditorialFrames", "EditorialProbes"]
        }
    }
}

public struct ProjectStorageUsage: Identifiable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let totalBytes: Int64
    public let cacheBytes: [ProjectCacheCategory: Int64]
    public let embeddedMediaBytes: Int64
    public var reclaimableBytes: Int64 { cacheBytes.values.reduce(0, +) }
    public let unavailable: Bool
}

public enum StorageMaintenance {
    public static func sameProject(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }
    public static func availableCapacity(near url: URL) -> Int64? { ExportPreflight.availableCapacity(near: url) }
    /// Symlinks are never followed, including a symlinked category directory.
    public static func files(in directory: URL) -> [URL] {
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { return [] }
        guard let iterator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return [] }
        var files: [URL] = []
        for case let file as URL in iterator {
            if Task.isCancelled { break }
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if values.isRegularFile == true { files.append(file) }
        }
        return files
    }

    public static func byteCount(at directory: URL) -> Int64 {
        files(in: directory).reduce(0) { $0 + size(of: $1) }
    }

    private static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    public static func usage(of package: URL) -> ProjectStorageUsage {
        let available = FileManager.default.isReadableFile(atPath: package.appendingPathComponent("project.json").path)
        let cache = package.resolvingSymlinksInPath().appendingPathComponent("Cache")
        let safeCache = cache.resolvingSymlinksInPath() == cache.standardizedFileURL
        let protected = try? protectedFiles(in: package)
        let sizes = Dictionary(uniqueKeysWithValues: ProjectCacheCategory.allCases.map { category in
            (category, safeCache && protected != nil ? category.directories.reduce(Int64(0)) { total, directory in
                total + files(in: cache.appendingPathComponent(directory)).filter {
                    !protected!.contains($0.resolvingSymlinksInPath().standardizedFileURL)
                }.reduce(Int64(0)) { $0 + size(of: $1) }
            } : 0)
        })
        let embedded = ["Media", "MusicLibrary/Files", "Telemetry"].reduce(Int64(0)) { $0 + byteCount(at: package.appendingPathComponent($1)) }
        return ProjectStorageUsage(url: package, name: ProjectSummary.load(from: package)?.name ?? package.deletingPathExtension().lastPathComponent,
            totalBytes: available ? byteCount(at: package) : 0, cacheBytes: sizes, embeddedMediaBytes: embedded, unavailable: !available)
    }

    private static func protectedFiles(in package: URL) throws -> Set<URL> {
        let data = try Data(contentsOf: package.appendingPathComponent("project.json"))
        _ = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: data)
        var protected = Set<URL>()
        func collect(_ value: Any) {
            if let text = value as? String, let url = URL(string: text), url.isFileURL {
                protected.insert(url.resolvingSymlinksInPath().standardizedFileURL)
            } else if let values = value as? [Any] { values.forEach(collect) }
            else if let values = value as? [String: Any] { values.values.forEach(collect) }
        }
        collect(try JSONSerialization.jsonObject(with: data))
        let music = package.appendingPathComponent("MusicLibrary/tracks.json")
        if FileManager.default.fileExists(atPath: music.path) {
            collect(try JSONSerialization.jsonObject(with: Data(contentsOf: music)))
        }
        return protected
    }

    /// Moving one package must not orphan a source used by another known project.
    public static func projectsDepending(on packages: [URL], among others: [URL]) throws -> [URL] {
        let roots = packages.map { $0.resolvingSymlinksInPath().standardizedFileURL.path + "/" }
        return try others.filter { project in
            guard !packages.contains(where: { sameProject($0, project) }), FileManager.default.fileExists(atPath: project.path) else { return false }
            return try protectedFiles(in: project).contains { file in roots.contains { file.path.hasPrefix($0) } }
        }
    }

    public static func moveProjectToTrash(_ package: URL) throws {
        guard package.pathExtension.lowercased() == "veloedit",
              (try package.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == false else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let lease = try ProjectOperationLease(package: package)
        defer { withExtendedLifetime(lease) {} }
        _ = try protectedFiles(in: package)
        try FileManager.default.trashItem(at: package, resultingItemURL: nil)
    }

    /// Only regular, regenerable cache files are deleted. Any file URL stored
    /// anywhere in the manifest or music catalog remains protected, including
    /// removed source history, exports and generated source media.
    @discardableResult
    public static func clear(_ category: ProjectCacheCategory, package: URL, protectingProjects: [URL] = []) throws -> Int64 {
        let lease = try ProjectOperationLease(package: package)
        defer { withExtendedLifetime(lease) {} }
        return try ProjectStore.withManifestLock(for: package.appendingPathComponent("project.json")) {
            var protected = try protectedFiles(in: package)
            for other in protectingProjects where !sameProject(other, package) && FileManager.default.fileExists(atPath: other.path) {
                protected.formUnion(try protectedFiles(in: other))
            }
            let cache = package.resolvingSymlinksInPath().appendingPathComponent("Cache").standardizedFileURL
            guard cache.resolvingSymlinksInPath() == cache else { throw CocoaError(.fileWriteNoPermission) }
            var freed: Int64 = 0
            for directory in category.directories {
                for file in files(in: cache.appendingPathComponent(directory)) {
                    try Task.checkCancellation()
                    let resolved = file.resolvingSymlinksInPath().standardizedFileURL
                    guard resolved.path.hasPrefix(cache.path + "/"), !protected.contains(resolved),
                          (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
                    let bytes = size(of: file)
                    try FileManager.default.removeItem(at: file)
                    freed += bytes
                }
            }
            return freed
        }
    }
}
