import Foundation
import os

/// Opt-in JSONL evidence with one monotonic clock for the complete operation.
/// No media, prompts or images are written. Unavailable measurements stay absent.
public final class PerformanceTrace: @unchecked Sendable {
    @TaskLocal public static var current: PerformanceTrace?
    @TaskLocal public static var parentSpan: String?
    public let operationID = UUID()
    private let started = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private let file: FileHandle?
    private let log = OSLog(subsystem: "app.veloedit", category: "Performance")

    public init(name: String, projectID: UUID? = nil, revision: String? = nil) {
        if let directory = ProcessInfo.processInfo.environment["VELOEDIT_TRACE_DIRECTORY"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("\(operationID).jsonl")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            file = try? FileHandle(forWritingTo: url)
        } else { file = nil }
        event("operation.begin", fields: ["name": name, "projectID": projectID?.uuidString ?? "",
                                         "revision": revision ?? "", "date": ISO8601DateFormatter().string(from: Date())])
    }

    deinit { try? file?.close() }

    public func event(_ name: String, fields: [String: String] = [:], values: [String: Double] = [:]) {
        guard let file else { return }
        let row: [String: Any] = ["operationID": operationID.uuidString, "event": name,
                                  "elapsed": ProcessInfo.processInfo.systemUptime - started,
                                  "fields": fields, "values": values]
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(10)
        lock.lock()
        defer { lock.unlock() }
        try? file.write(contentsOf: data)
    }

    public func finish(status: String) {
        event("operation.end", fields: ["status": status])
        lock.lock()
        defer { lock.unlock() }
        try? file?.synchronize()
    }

    public static func measure<T>(name: String, projectID: UUID? = nil, revision: String? = nil,
                                  fields: [String: String] = [:],
                                  operation: () async throws -> T) async rethrows -> T {
        // Nested pipeline operations retain the parent correlation ID.
        let trace = current ?? PerformanceTrace(name: name, projectID: projectID, revision: revision)
        let ownsTrace = current == nil
        let span = UUID().uuidString
        let signpost = OSSignpostID(log: trace.log)
        os_signpost(.begin, log: trace.log, name: "Operation", signpostID: signpost, "%{public}s", name)
        var metadata = fields
        metadata.merge(["span": span, "stage": name, "parent": parentSpan ?? "",
                        "revision": revision ?? ""]) { _, new in new }
        trace.event("span.begin", fields: metadata)
        return try await $current.withValue(trace) {
          try await $parentSpan.withValue(span) {
            do {
                let result = try await operation()
                trace.event("span.end", fields: ["span": span, "stage": name, "status": "success"])
                os_signpost(.end, log: trace.log, name: "Operation", signpostID: signpost)
                if ownsTrace { trace.finish(status: "success") }
                return result
            } catch {
                let status = error is CancellationError ? "cancelled" : "failed"
                trace.event("span.end", fields: ["span": span, "stage": name, "status": status])
                os_signpost(.end, log: trace.log, name: "Operation", signpostID: signpost)
                if ownsTrace { trace.finish(status: status) }
                throw error
            }
          }
        }
    }

    /// Synchronous work (including dispatch queues) retains the same clock and
    /// parent as async work. Callers on another executor pass the captured trace.
    public func begin(_ stage: String, fields: [String: String] = [:]) -> String {
        let span = UUID().uuidString
        var metadata = fields
        metadata.merge(["span": span, "stage": stage, "parent": Self.parentSpan ?? ""]) { _, new in new }
        event("span.begin", fields: metadata)
        return span
    }

    public func end(_ span: String?, stage: String, status: String = "success") {
        guard let span else { return }
        event("span.end", fields: ["span": span, "stage": stage, "status": status])
    }
}
