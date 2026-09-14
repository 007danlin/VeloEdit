import Foundation

public enum ProjectPersistenceLocation: String, Sendable {
    case project, localRecovery
}

/// A base is written once per outage. Later edits replace a compact top-level
/// delta, rather than copying the archive's unchanged analysis on every edit.
/// This journal is local to the app and is never considered disposable cache.
enum LocalProjectRecovery {
    struct Record: Codable {
        var schemaVersion = 1
        var projectID: UUID
        var packagePath: String
        var baseFingerprint: String
        var baseFile: String
        var patch: Data
        var resultFingerprint: String
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VeloEdit/Recovery", isDirectory: true)
    }

    static func directory(package: URL, root: URL) -> URL {
        root.appendingPathComponent(EditorialProjectMigration.hash(Data(package.standardizedFileURL.path.utf8)), isDirectory: true)
    }

    static func read(package: URL, root: URL) throws -> (Record, Data, Data)? {
        let folder = directory(package: package, root: root)
        let recordURL = folder.appendingPathComponent("journal.json")
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        let record = try JSONDecoder.veloEdit.decode(Record.self, from: Data(contentsOf: recordURL))
        guard record.schemaVersion == 1, record.packagePath == package.standardizedFileURL.path,
              !record.baseFile.contains("/"), !record.baseFile.contains("..") else {
            throw ProjectStoreError.invalidProjectPackage(package)
        }
        let base = try Data(contentsOf: folder.appendingPathComponent(record.baseFile))
        guard EditorialProjectMigration.hash(base) == record.baseFingerprint else {
            throw ProjectStoreError.invalidProjectPackage(package)
        }
        var object = try dictionary(base)
        for (key, value) in try dictionary(record.patch) {
            if value is NSNull { object.removeValue(forKey: key) } else { object[key] = value }
        }
        let result = try canonical(object)
        let project = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: result)
        guard project.id == record.projectID, EditorialProjectMigration.hash(result) == record.resultFingerprint else {
            throw ProjectStoreError.invalidProjectPackage(package)
        }
        return (record, base, result)
    }

    static func stage(_ manifest: ProjectManifest, base: ProjectManifest, package: URL, root: URL) throws {
        let folder = directory(package: package, root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = try read(package: package, root: root)
        let baseData = try existing?.1 ?? JSONEncoder.veloEdit.encode(base)
        let baseObject = try dictionary(baseData)
        let resultObject = try dictionary(JSONEncoder.veloEdit.encode(manifest))
        let resultData = try canonical(resultObject)
        var patch: [String: Any] = [:]
        for key in Set(baseObject.keys).union(resultObject.keys) where !equal(baseObject[key], resultObject[key]) {
            patch[key] = resultObject[key] ?? NSNull()
        }
        let baseFile = existing?.0.baseFile ?? "base-\(UUID().uuidString).json"
        if existing == nil { try durableWrite(baseData, to: folder.appendingPathComponent(baseFile)) }
        let record = Record(projectID: manifest.id, packagePath: package.standardizedFileURL.path,
                            baseFingerprint: EditorialProjectMigration.hash(baseData), baseFile: baseFile,
                            patch: try canonical(patch), resultFingerprint: EditorialProjectMigration.hash(resultData))
        try durableWrite(JSONEncoder.veloEdit.encode(record), to: folder.appendingPathComponent("journal.json"))
        guard try read(package: package, root: root)?.0.resultFingerprint == record.resultFingerprint else {
            throw ProjectStoreError.invalidProjectPackage(package)
        }
    }

    /// Three-way merge of independent object fields. Arrays (including a
    /// Timeline) remain indivisible: an overlapping edit is preserved separately.
    static func merge(base: Data, local: Data, remote: Data) throws -> Data {
        func mergeValue(_ base: Any?, _ local: Any?, _ remote: Any?) throws -> Any? {
            if equal(local, base) { return remote }
            if equal(remote, base) || equal(local, remote) { return local }
            if let b = base as? [String: Any], let l = local as? [String: Any], let r = remote as? [String: Any] {
                var output = r
                for key in Set(b.keys).union(l.keys).union(r.keys) {
                    if key == "updatedAt" || key == "filmBuildContentRevision" { continue }
                    output[key] = try mergeValue(b[key], l[key], r[key])
                }
                return output
            }
            throw ProjectStoreError.externalModification
        }
        return try canonical(mergeValue(dictionary(base), dictionary(local), dictionary(remote)) as! [String: Any])
    }

    static func clear(package: URL, root: URL) {
        // Only this package's app-owned recovery files, after primary commit.
        try? FileManager.default.removeItem(at: directory(package: package, root: root))
    }

    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }
    private static func canonical(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return NSDictionary(dictionary: ["value": a]).isEqual(to: ["value": b])
    }
    static func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        guard try Data(contentsOf: url) == data else { throw CocoaError(.fileWriteUnknown) }
    }
}
