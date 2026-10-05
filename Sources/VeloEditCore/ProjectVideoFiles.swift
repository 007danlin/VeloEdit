import Foundation

/// Finished films live beside the project package and can be opened or shared
/// directly in Finder. Existing files are never chosen for a default export.
public enum ProjectVideoFiles {
    public static func destination(nextTo package: URL, fileExtension: String = "mp4") -> URL {
        let directory = package.deletingLastPathComponent()
        let name = package.deletingPathExtension().lastPathComponent
        var result = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
        var version = 2
        while FileManager.default.fileExists(atPath: result.path) {
            result = directory.appendingPathComponent("\(name) — \(version)").appendingPathExtension(fileExtension)
            version += 1
        }
        return result
    }

    public static func isInsideProject(_ file: URL, package: URL) -> Bool {
        file.standardizedFileURL.path.hasPrefix(package.standardizedFileURL.path + "/")
    }
}
