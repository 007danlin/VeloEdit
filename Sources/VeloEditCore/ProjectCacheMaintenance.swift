import Foundation

public enum ProjectCacheMaintenance {
    /// Only orphaned files from known regenerable categories are eligible.
    /// Every current/removed source is retained, including history references.
    @discardableResult
    public static func removeOrphanedArtifacts(package: URL, manifest: ProjectManifest) throws -> Int64 {
        let protected = Set((manifest.assets + (manifest.removedMedia ?? []).map(\.asset)).map { String($0.contentHash.prefix(20)) })
        let cache = package.appendingPathComponent("Cache").resolvingSymlinksInPath()
        var freed: Int64 = 0
        for category in ["Thumbnails", "TimelineThumbnails", "Proxies"] {
            let directory = cache.appendingPathComponent(category)
            guard directory.resolvingSymlinksInPath().path.hasPrefix(cache.path + "/") else { continue }
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])) ?? [] {
                try Task.checkCancellation()
                let name = file.lastPathComponent
                let prefix = String(name.prefix(20))
                guard prefix.count == 20, prefix.allSatisfy({ $0.isHexDigit }), !protected.contains(prefix),
                      ["jpg", "jpeg", "png", "mp4"].contains(file.pathExtension.lowercased()),
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                try FileManager.default.removeItem(at: file)
                freed += Int64(values.fileSize ?? 0)
            }
        }
        return freed
    }
}
