import Foundation
import Darwin

/// Disposable intermediates have an owner before the first byte is written.
/// The owner is retained by the playback, or released when a build throws.
/// A process lock distinguishes abandoned work from another live editor/CLI.
final class TemporaryMediaWorkspace: @unchecked Sendable {
    static let defaultRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("VeloEdit-TemporaryMedia-v1", isDirectory: true)
    private let root: URL
    private let lock = NSLock()
    private var directory: URL?
    private var descriptor: Int32 = -1

    init(root: URL = TemporaryMediaWorkspace.defaultRoot) {
        self.root = root.standardizedFileURL
    }

    func file(_ name: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if directory == nil {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard root.resolvingSymlinksInPath().path == root.path else { throw CocoaError(.fileWriteNoPermission) }
            TemporaryMediaMaintenance.removeAbandonedWork(in: root)
            let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            let fd = open(url.appendingPathComponent(".owner").path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                if fd >= 0 { close(fd) }
                try? FileManager.default.removeItem(at: url)
                throw CocoaError(.fileWriteNoPermission)
            }
            descriptor = fd
            directory = url
        }
        return directory!.appendingPathComponent(name)
    }

    deinit {
        // Keep the lock until removal finishes: another process must never
        // mistake a live composition for abandoned work during teardown.
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if descriptor >= 0 { close(descriptor) }
    }
}

public enum TemporaryMediaMaintenance {
    public static var directory: URL { TemporaryMediaWorkspace.defaultRoot }
    public static var usedBytes: Int64 {
        let temp = FileManager.default.temporaryDirectory
        let legacy = ((try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? [])
            .filter { isLegacyMediaName($0.lastPathComponent) }
            .reduce(Int64(0)) { total, url in
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { return total }
                return total + Int64(values.fileSize ?? 0)
            }
        let frameCaches = ["VeloEdit-PhotoSource-v1", "VeloEdit-FrameCache", "VeloEdit-FrameCache-v2", "VeloEdit-MasteringAudio"]
            .reduce(Int64(0)) { $0 + bytes(in: temp.appendingPathComponent($1)) }
        return bytes(in: directory) + legacy + frameCaches
    }

    /// New work is protected by file locks. Legacy versions had no ownership
    /// markers, so clean only exact UUID names older than a day and only when
    /// no other VeloEdit editor/CLI is running. Never walk arbitrary temp trees.
    public static func performStartupMaintenance() {
        removeAbandonedWork(in: directory)
        guard !anotherVeloEditProcessIsRunning() else { return }
        removeLegacyFiles(in: FileManager.default.temporaryDirectory)
    }

    @discardableResult
    static func removeAbandonedWork(in root: URL, now: Date = Date()) -> Int64 {
        guard root.resolvingSymlinksInPath().path == root.standardizedFileURL.path else { return 0 }
        var freed: Int64 = 0
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  now.timeIntervalSince(values.creationDate ?? now) > 60 else { continue }
            let fd = open(url.appendingPathComponent(".owner").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            let size = bytes(in: url)
            if (try? FileManager.default.removeItem(at: url)) != nil { freed += size }
        }
        return freed
    }

    @discardableResult
    static func removeLegacyFiles(in root: URL, now: Date = Date()) -> Int64 {
        var freed: Int64 = 0
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard isLegacyMediaName(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  now.timeIntervalSince(values.contentModificationDate ?? now) > 86_400 else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { freed += Int64(values.fileSize ?? 0) }
        }
        return freed
    }

    static func isLegacyMediaName(_ name: String) -> Bool {
        let patterns: [(String, [String])] = [
            ("veloedit-playback-", [".mov"]), ("veloedit-title-", [".mov", ".png"]),
            ("veloedit-processed-audio-", [".caf"]), ("veloedit-timeline-audio-", [".caf"]),
            ("veloedit-audio-source-", [".caf", ".denoised.caf"])
        ]
        return patterns.contains { prefix, suffixes in
            suffixes.contains { suffix in
                guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
                return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil
            }
        }
    }

    static func bytes(in root: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey]),
                  values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            total += Int64(max(values.fileSize ?? 0, values.totalFileAllocatedSize ?? 0))
        }
        return total
    }

    private static func anotherVeloEditProcessIsRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return true }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return true }
        return output.split(separator: "\n").contains { line in
            let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let pid = Int32(fields[0]), pid != getpid() else { return false }
            let name = URL(fileURLWithPath: String(fields[1]).trimmingCharacters(in: .whitespaces)).lastPathComponent
            return ["VeloEdit", "veloedit-cli"].contains(name)
        }
    }
}
