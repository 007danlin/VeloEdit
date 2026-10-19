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
    public var isCalculating = false
    public var availabilityIsKnown = true

    public static func pending(_ url: URL) -> Self {
        Self(url: url, name: url.deletingPathExtension().lastPathComponent,
             totalBytes: 0, cacheBytes: [:], embeddedMediaBytes: 0,
             unavailable: false, isCalculating: true, availabilityIsKnown: false)
    }
}

public enum StorageMaintenance {
    /// Cheap metadata pass so projects can be selected before their sizes finish.
    public static func overview(of package: URL) -> ProjectStorageUsage {
        let available = FileManager.default.isReadableFile(atPath: package.appendingPathComponent("project.json").path)
        return ProjectStorageUsage(url: package,
            name: ProjectSummary.load(from: package)?.name ?? package.deletingPathExtension().lastPathComponent,
            totalBytes: 0, cacheBytes: [:], embeddedMediaBytes: 0,
            unavailable: !available, isCalculating: available)
    }
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
        let name = ProjectSummary.load(from: package)?.name ?? package.deletingPathExtension().lastPathComponent
        guard available, !Task.isCancelled else {
            return ProjectStorageUsage(url: package, name: name, totalBytes: 0, cacheBytes: [:], embeddedMediaBytes: 0, unavailable: !available)
        }
        let protected = try? protectedFiles(in: package)
        let root = package.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path + "/"
        let categories = ProjectCacheCategory.allCases.flatMap { category in
            category.directories.map { ("Cache/" + $0 + "/", category) }
        }
        var sizes: [ProjectCacheCategory: Int64] = [:]
        var total: Int64 = 0
        var embedded: Int64 = 0
        // Read cached resource values during a single walk, instead of walking
        // the package and each cache/media subtree separately and stat'ing again.
        if let iterator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: []) {
            for case let file as URL in iterator {
                guard !Task.isCancelled else { break }
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { continue }
                if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
                guard values.isRegularFile == true else { continue }
                let bytes = Int64(values.fileSize ?? 0)
                total += bytes
                let normalized = file.standardizedFileURL
                let relative = String(normalized.path.dropFirst(rootPrefix.count))
                if ["Media/", "MusicLibrary/Files/", "Telemetry/"].contains(where: relative.hasPrefix) { embedded += bytes }
                if let protected, !protected.contains(normalized),
                   let category = categories.first(where: { relative.hasPrefix($0.0) })?.1 {
                    sizes[category, default: 0] += bytes
                }
            }
        }
        for category in ProjectCacheCategory.allCases { sizes[category, default: 0] += 0 }
        return ProjectStorageUsage(url: package, name: name,
            totalBytes: total, cacheBytes: sizes, embeddedMediaBytes: embedded, unavailable: false)
    }

    private static func protectedFiles(in package: URL, allowingMissingManifest: Bool = false) throws -> Set<URL> {
        let data: Data?
        do {
            data = try Data(contentsOf: package.appendingPathComponent("project.json"))
        } catch {
            let failure = error as NSError
            // Deleted projects can leave cache-only folders in the library.
            // Ignore only a missing manifest in OTHER projects; permission and
            // decoding failures must still stop a destructive operation.
            guard allowingMissingManifest, failure.domain == NSCocoaErrorDomain,
                  failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError else { throw error }
            data = nil
        }
        var protected = Set<URL>()
        func collect(_ value: Any) {
            if let text = value as? String, let url = URL(string: text), url.isFileURL {
                protected.insert(url.resolvingSymlinksInPath().standardizedFileURL)
            } else if let values = value as? [Any] { values.forEach(collect) }
            else if let values = value as? [String: Any] { values.values.forEach(collect) }
        }
        if let data {
            _ = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: data)
            collect(try JSONSerialization.jsonObject(with: data))
        }
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
            guard !packages.contains(where: { sameProject($0, project) }) else { return false }
            return try protectedFiles(in: project, allowingMissingManifest: true).contains { file in roots.contains { file.path.hasPrefix($0) } }
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
        try clear([category], package: package, protectingProjects: protectingProjects)
    }

    @discardableResult
    public static func clear(_ categories: Set<ProjectCacheCategory>, package: URL, protectingProjects: [URL] = []) throws -> Int64 {
        let lease = try ProjectOperationLease(package: package)
        defer { withExtendedLifetime(lease) {} }
        return try ProjectStore.withManifestLock(for: package.appendingPathComponent("project.json")) {
            var protected = try protectedFiles(in: package)
            for other in protectingProjects where !sameProject(other, package) {
                protected.formUnion(try protectedFiles(in: other, allowingMissingManifest: true))
            }
            let cache = package.resolvingSymlinksInPath().appendingPathComponent("Cache").standardizedFileURL
            guard cache.resolvingSymlinksInPath() == cache else { throw CocoaError(.fileWriteNoPermission) }
            var freed: Int64 = 0
            for directory in ProjectCacheCategory.allCases.filter({ categories.contains($0) }).flatMap(\.directories) {
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
