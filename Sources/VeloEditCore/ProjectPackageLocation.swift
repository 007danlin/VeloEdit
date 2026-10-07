import Foundation
import CoreFoundation

/// A file reference follows the directory's identity across Finder renames.
/// Looking up its path also avoids mistaking a replacement at the old path for
/// the project that is still open in the editor.
final class ProjectPackageLocation: @unchecked Sendable {
    private let originalURL: URL
    private let referenceURL: CFURL?

    init(_ url: URL) {
        originalURL = url
        // Retain the CF reference itself: bridging it through Swift.URL first
        // eagerly converts it to a path and loses rename tracking.
        referenceURL = CFURLCreateFileReferenceURL(nil, url as CFURL, nil)?.takeRetainedValue()
    }

    var url: URL {
        guard let resolved = referenceURL.flatMap({ CFURLCreateFilePathURL(nil, $0, nil)?.takeRetainedValue() }) as URL? else { return originalURL }
        if resolved.standardizedFileURL.path == originalURL.resolvingSymlinksInPath().standardizedFileURL.path { return originalURL }
        return URL(fileURLWithPath: resolved.path, isDirectory: originalURL.hasDirectoryPath)
    }

    static func relocate(_ manifest: ProjectManifest, from old: URL, to new: URL) throws -> ProjectManifest {
        guard old.standardizedFileURL.path != new.standardizedFileURL.path else { return manifest }
        let oldPrefix = old.standardizedFileURL.path + "/"
        func rewrite(_ value: Any) -> Any {
            if let text = value as? String, let url = URL(string: text), url.isFileURL,
               url.standardizedFileURL.path.hasPrefix(oldPrefix) {
                return new.appendingPathComponent(String(url.standardizedFileURL.path.dropFirst(oldPrefix.count))).absoluteString
            }
            if let array = value as? [Any] { return array.map(rewrite) }
            if let object = value as? [String: Any] {
                return Dictionary(object.map { (rewrite($0.key) as? String ?? $0.key, rewrite($0.value)) },
                                  uniquingKeysWith: { first, _ in first })
            }
            return value
        }
        let object = try JSONSerialization.jsonObject(with: ProjectManifestEncoding.encode(manifest))
        let data = try JSONSerialization.data(withJSONObject: rewrite(object), options: [.sortedKeys])
        return try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: data)
    }
}
