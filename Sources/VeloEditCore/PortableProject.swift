import Foundation

extension VeloEditPipeline {
    public func collectProjectCopy(to destination: URL, progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> URL {
        let lease = try ProjectOperationLease(package: store.packageURL)
        defer { withExtendedLifetime(lease) {} }
        _ = try await recoverMissingSources()
        var project = await store.manifest
        let tracks = try await musicTracks()
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".veloedit-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let assets = project.assets + (project.removedMedia ?? []).map(\.asset)
        var dependencies: [(URL, String)] = assets.map { ($0.originalURL, "Media/\($0.id.uuidString).\($0.originalURL.pathExtension)") }
        dependencies += tracks.map { ($0.localFileURL, "MusicLibrary/Files/\($0.id.uuidString).\($0.localFileURL.pathExtension)") }
        dependencies += project.effectiveTelemetrySources.compactMap { source in
            source.originalURL.map { ($0, "Telemetry/\(source.id.uuidString).\($0.pathExtension)") }
        }
        dependencies += project.renderJobs.filter { $0.status == .completed }.map { ($0.outputURL, "Exports/\($0.id.uuidString).\($0.outputURL.pathExtension)") }
        let requiredBytes = try dependencies.reduce(Int64(0)) { total, dependency in
            total + Int64(try dependency.0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        if let available = ExportPreflight.availableCapacity(near: destination), available < requiredBytes + 64_000_000 {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        var relocated: [String: String] = [:]
        for (index, dependency) in dependencies.enumerated() {
            try Task.checkCancellation()
            let output = staging.appendingPathComponent(dependency.1)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: output.path) {
                try Self.copyPortableFile(from: dependency.0, to: output)
                guard try MediaImporter.sha256(url: dependency.0) == MediaImporter.sha256(url: output) else { throw CocoaError(.fileReadCorruptFile) }
            }
            relocated[dependency.0.absoluteString] = destination.appendingPathComponent(dependency.1).absoluteString
            progress?(ImportProgress(completed: index + 1, total: dependencies.count, currentName: "Собираю копию проекта"))
        }
        project.packagedMediaPaths = Dictionary(assets.map { ($0.id, "Media/\($0.id.uuidString).\($0.originalURL.pathExtension)") }, uniquingKeysWith: { a, _ in a })
        project.packagedFilePaths = Dictionary(dependencies.map {
            (destination.appendingPathComponent($0.1).absoluteString, $0.1)
        }, uniquingKeysWith: { a, _ in a })
        if project.autonomousJob?.state.resumesAutomatically == true { project.autonomousJob?.state = .paused }
        project.authorizedMediaFolders = []
        // Copies have their own task identity, while all asset/timeline IDs stay
        // stable so edits, music, analysis and telemetry retain their bindings.
        project.id = UUID()
        project.autonomousJob?.projectID = project.id
        func rewrite(_ value: Any) -> Any {
            if let text = value as? String { return relocated[text] ?? text }
            if let values = value as? [Any] { return values.map(rewrite) }
            if let values = value as? [String: Any] { return values.mapValues(rewrite) }
            return value
        }
        let manifestObject = try JSONSerialization.jsonObject(with: JSONEncoder.veloEdit.encode(project))
        let manifestData = try JSONSerialization.data(withJSONObject: rewrite(manifestObject))
        _ = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: manifestData)
        try LocalProjectRecovery.durableWrite(manifestData, to: staging.appendingPathComponent("project.json"))
        let tracksObject = try JSONSerialization.jsonObject(with: JSONEncoder.veloEdit.encode(tracks))
        let musicDirectory = staging.appendingPathComponent("MusicLibrary")
        try FileManager.default.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
        try LocalProjectRecovery.durableWrite(JSONSerialization.data(withJSONObject: rewrite(tracksObject)), to: musicDirectory.appendingPathComponent("tracks.json"))
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: destination)
        _ = try ProjectStore(open: destination)
        return destination
    }
    private static func copyPortableFile(from source: URL, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: bytes)
        }
        try output.synchronize()
    }
}

enum PortableProjectPaths {
    static func needsRelocation(_ paths: [String: String]?, to package: URL) -> Bool {
        paths?.contains { original, relative in
            isSafe(relative) && original != package.appendingPathComponent(relative).absoluteString
        } == true
    }

    private static func isSafe(_ relative: String) -> Bool {
        !relative.hasPrefix("/") && !relative.split(separator: "/").contains("..")
    }

    static func relocate(_ data: Data, to package: URL) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = object["packagedFilePaths"] as? [String: String], !paths.isEmpty else { return data }
        let safe = paths.filter { isSafe($0.value) }
        let mapped = safe.mapValues { package.appendingPathComponent($0).absoluteString }
        let roots = Set(safe.compactMap { key, relative -> String? in
            guard var url = URL(string: key), url.isFileURL else { return nil }
            for _ in relative.split(separator: "/") { url.deleteLastPathComponent() }
            return url.absoluteString.hasSuffix("/") ? url.absoluteString : url.absoluteString + "/"
        })
        let newRoot = package.absoluteString.hasSuffix("/") ? package.absoluteString : package.absoluteString + "/"
        guard mapped.contains(where: { $0.key != $0.value }) else { return data }
        func rewrite(_ value: Any) -> Any {
            if let value = value as? String {
                if let replacement = mapped[value] { return replacement }
                if let root = roots.first(where: { value.hasPrefix($0) }) {
                    return newRoot + value.dropFirst(root.count)
                }
                return value
            }
            if let value = value as? [Any] { return value.map(rewrite) }
            if let value = value as? [String: Any] { return value.mapValues(rewrite) }
            return value
        }
        object = rewrite(object) as! [String: Any]
        object["packagedFilePaths"] = Dictionary(safe.map { (package.appendingPathComponent($0.value).absoluteString, $0.value) }, uniquingKeysWith: { a, _ in a })
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
