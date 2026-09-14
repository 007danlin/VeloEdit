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
    static func resolve(_ asset: MediaAsset, folders: [URL], maximumFiles: Int = 4_000) throws -> URL? {
        if FileManager.default.isReadableFile(atPath: asset.originalURL.path) { return asset.originalURL }
        if let bookmark = asset.bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale),
               try matches(url, asset: asset) { return url }
        }
        var visited = Set<URL>()
        var matches = Set<URL>()
        var count = 0
        let roots = [asset.originalURL.deletingLastPathComponent()] + folders
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
    @discardableResult
    public func recoverMissingSources() async throws -> Int {
        let project = await store.manifest
        let folders = (project.authorizedMediaFolders ?? []).map { $0.resolved() }
            + project.assets.map { $0.originalURL.deletingLastPathComponent() }
        var replacements: [UUID: URL] = [:]
        for asset in project.assets where !FileManager.default.isReadableFile(atPath: asset.originalURL.path) {
            if let found = try MediaSourceRecovery.resolve(asset, folders: folders) { replacements[asset.id] = found }
        }
        guard !replacements.isEmpty else { return 0 }
        try await store.updateAnalysisProgress { manifest in
            for index in manifest.assets.indices {
                guard let url = replacements[manifest.assets[index].id] else { continue }
                manifest.assets[index].originalURL = url
                manifest.assets[index].missing = false
                manifest.assets[index].bookmarkData = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            }
        }
        try await store.rebindRecoveredMediaInputs()
        return replacements.count
    }
}
