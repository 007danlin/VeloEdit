import Foundation

public struct AuthorizedMediaFolder: Codable, Hashable, Sendable {
    public var url: URL
    public var bookmark: Data?
    public init(url: URL) {
        self.url = url.standardizedFileURL
        bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    func resolved() -> URL {
        var stale = false
        return bookmark.flatMap { try? URL(resolvingBookmarkData: $0, options: [.withSecurityScope], bookmarkDataIsStale: &stale) } ?? url
    }
}

enum MediaSourceRecovery {
    static func resolve(_ asset: MediaAsset, folders: [URL], maximumFiles: Int = 4_000, includeOriginalDirectory: Bool = true) throws -> URL? {
        if FileManager.default.isReadableFile(atPath: asset.originalURL.path) { return asset.originalURL }
        if let bookmark = asset.bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale),
               try matches(url, asset: asset) { return url }
        }
        var visited = Set<URL>()
        var matches = Set<URL>()
        var count = 0
        let roots = folders + (includeOriginalDirectory ? [asset.originalURL.deletingLastPathComponent()] : [])
        for root in roots where visited.insert(root.standardizedFileURL).inserted {
            let accessed = root.startAccessingSecurityScopedResource()
            defer { if accessed { root.stopAccessingSecurityScopedResource() } }
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let candidate = enumerator?.nextObject() as? URL {
                try Task.checkCancellation()
                count += 1
                if count > maximumFiles { return nil } // Incomplete search cannot resolve an ambiguity.
                if (enumerator?.level ?? 0) > 6 { enumerator?.skipDescendants(); continue }
                if candidate.pathExtension.lowercased() != asset.originalURL.pathExtension.lowercased() { continue }
                if try Self.matches(candidate, asset: asset) { matches.insert(candidate.standardizedFileURL) }
                if matches.count > 1 { return nil }
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    static func matches(_ url: URL, asset: MediaAsset) throws -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, Int64(values.fileSize ?? -1) == asset.byteSize else { return false }
        if let full = asset.fullContentHash { return try MediaImporter.sha256(url: url) == full }
        // The stored modification time belongs to the identity algorithm, not
        // to the new path. Copying a file can change its filesystem timestamp.
        return try MediaImporter.quickFingerprint(url: url, byteSize: asset.byteSize, modificationDate: asset.metadata.modificationDate) == asset.contentHash
    }
}

extension VeloEditPipeline {
    /// Availability is operational state; losing a volume must not discard edits.
    public func refreshMediaAvailability() async throws {
        let project = await store.manifest
        let missing = Set(project.assets.filter {
            !FileManager.default.isReadableFile(atPath: $0.originalURL.path)
        }.map(\.id))
        guard project.assets.contains(where: { $0.missing != missing.contains($0.id) }) else { return }
        try await store.persistOperationalState { manifest in
            for index in manifest.assets.indices {
                manifest.assets[index].missing = missing.contains(manifest.assets[index].id)
            }
        }
    }

    public func relinkMedia(assetID: UUID, to url: URL) async throws {
        let lease = try ProjectOperationLease(package: store.packageURL)
        defer { withExtendedLifetime(lease) {} }
        guard let asset = await store.manifest.assets.first(where: { $0.id == assetID }) else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard try MediaSourceRecovery.matches(url, asset: asset) else {
            throw MediaRelinkError.differentFile(asset.displayName)
        }
        try await applyRecoveredSources([assetID: url.standardizedFileURL])
    }

    public func relinkMedia(in folder: URL) async throws -> Int {
        let lease = try ProjectOperationLease(package: store.packageURL)
        defer { withExtendedLifetime(lease) {} }
        let project = await store.manifest
        var replacements: [UUID: URL] = [:]
        for asset in project.assets where !FileManager.default.isReadableFile(atPath: asset.originalURL.path) {
            if let found = try MediaSourceRecovery.resolve(asset, folders: [folder], maximumFiles: 100_000, includeOriginalDirectory: false) { replacements[asset.id] = found }
        }
        if !replacements.isEmpty {
            try await applyRecoveredSources(replacements)
            try await store.persistOperationalState {
                if !($0.authorizedMediaFolders ?? []).contains(where: { $0.url == folder.standardizedFileURL }) {
                    $0.authorizedMediaFolders = ($0.authorizedMediaFolders ?? []) + [AuthorizedMediaFolder(url: folder)]
                }
            }
        }
        try await refreshMediaAvailability()
        return replacements.count
    }

    @discardableResult
    public func recoverMissingSources() async throws -> Int {
        let project = await store.manifest
        let folders = (project.authorizedMediaFolders ?? []).map { $0.resolved() }
            + project.assets.map { $0.originalURL.deletingLastPathComponent() }
        var replacements: [UUID: URL] = [:]
        for asset in project.assets where !FileManager.default.isReadableFile(atPath: asset.originalURL.path) {
            if let found = try MediaSourceRecovery.resolve(asset, folders: folders) { replacements[asset.id] = found }
        }
        guard !replacements.isEmpty else {
            try await refreshMediaAvailability()
            return 0
        }
        try await applyRecoveredSources(replacements)
        try await refreshMediaAvailability()
        return replacements.count
    }

    private func applyRecoveredSources(_ replacements: [UUID: URL]) async throws {
        try await store.updateAnalysisProgress { manifest in
            for index in manifest.assets.indices {
                guard let url = replacements[manifest.assets[index].id] else { continue }
                manifest.packagedFilePaths?.removeValue(forKey: manifest.assets[index].originalURL.absoluteString)
                manifest.assets[index].originalURL = url
                manifest.assets[index].missing = false
                manifest.assets[index].bookmarkData = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                let asset = manifest.assets[index]
                let identity = FrameCacheKey.sourceIdentity(url: url, contentHash: asset.contentHash)
                for analysisIndex in manifest.analyses.indices where manifest.analyses[analysisIndex].assetID == asset.id
                    && manifest.analyses[analysisIndex].analyzedContentHash == asset.contentHash
                    && manifest.analyses[analysisIndex].analyzedSourceIdentity != nil {
                    manifest.analyses[analysisIndex].analyzedSourceIdentity = identity
                }
                // A portable package can now point to a recovered external file.
                // Its former embedded path must not override this choice on open.
                manifest.packagedMediaPaths?.removeValue(forKey: asset.id)
            }
        }
        try await store.rebindRecoveredMediaInputs()
    }
}

public enum MediaRelinkError: LocalizedError {
    case differentFile(String)
    public var errorDescription: String? {
        switch self {
        case .differentFile(let name): return "Выбранный файл не совпадает с исходником «\(name)». Выберите оригинал или его точную копию — монтаж сохранён."
        }
    }
}
