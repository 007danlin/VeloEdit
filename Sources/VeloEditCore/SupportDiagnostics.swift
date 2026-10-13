import Foundation

/// Independent of the project package so a deleted project cannot erase the
/// evidence needed to investigate it. Bounded and available after relaunch.
public final class SupportDiagnostics: @unchecked Sendable {
    public static let shared = SupportDiagnostics(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VeloEdit/Diagnostics/recent.log"))
    public let url: URL
    private let lock = NSLock()
    private var recent: [String] = []
    private let maximumBytes = 256 * 1024

    public init(url: URL) { self.url = url }

    public func record(_ message: String, error: Error? = nil) {
        lock.lock(); defer { lock.unlock() }
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(message)"
            + (error.map { "\n" + Self.describe($0) } ?? "")
        recent.append(String(entry.prefix(16_384)))
        if recent.count > 100 { recent.removeFirst(recent.count - 100) }
        let previous = Self.tail(url, limit: maximumBytes / 2)
        let text = previous + "\n" + entry.prefix(16_384) + "\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch { /* The in-memory copy still makes the failure report useful. */ }
    }

    public func report() -> String {
        lock.lock(); defer { lock.unlock() }
        return "Журнал приложения: \(url.path)\n"
            + Self.tail(url, limit: maximumBytes)
            + "\nСобытия текущего сеанса:\n" + recent.joined(separator: "\n")
    }

    public static func describe(_ error: Error) -> String {
        var lines: [String] = []
        var current: NSError? = error as NSError
        for _ in 0..<8 {
            guard let value = current else { break }
            lines.append("\(value.domain) (\(value.code)): \(value.localizedDescription)")
            if let reason = value.localizedFailureReason { lines.append("Причина: \(reason)") }
            if let suggestion = value.localizedRecoverySuggestion { lines.append("Восстановление: \(suggestion)") }
            for key in [NSFilePathErrorKey, NSURLErrorKey] {
                if let path = value.userInfo[key] { lines.append("\(key): \(path)") }
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return lines.joined(separator: "\n")
    }

    public static func tail(_ url: URL, limit: Int = 32_768) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0)
            return String(decoding: try handle.read(upToCount: limit) ?? Data(), as: UTF8.self)
        } catch { return describe(error) }
    }

    public static func storage(_ url: URL) -> String {
        let fm = FileManager.default
        var existing = url
        while !fm.fileExists(atPath: existing.path), existing.path != "/" {
            existing.deleteLastPathComponent()
        }
        let values = try? existing.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeIsRemovableKey,
            .volumeIsReadOnlyKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        func flag(_ value: Bool?) -> String { value.map { $0 ? "да" : "нет" } ?? "неизвестно" }
        return """
        Путь: \(url.path)
        Существует: \(fm.fileExists(atPath: url.path)); чтение: \(fm.isReadableFile(atPath: url.path)); запись: \(fm.isWritableFile(atPath: url.path))
        Том ближайшего доступного каталога: \(values?.volumeName ?? "неизвестно") · \(values?.volume?.path ?? existing.path)
        Формат: \(values?.volumeLocalizedFormatDescription ?? "неизвестно")
        Съёмный: \(flag(values?.volumeIsRemovable)); только чтение: \(flag(values?.volumeIsReadOnly))
        Свободно байт: \(values?.volumeAvailableCapacity.map(String.init) ?? "неизвестно"); всего: \(values?.volumeTotalCapacity.map(String.init) ?? "неизвестно")
        """
    }
}
