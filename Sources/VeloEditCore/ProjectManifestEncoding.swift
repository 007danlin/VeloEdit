import Foundation

/// A build checkpoint contains several large value snapshots. Encoding it on
/// a cooperative executor's small stack can exhaust the guard page before
/// Swift can throw an error. Keep synchronous ProjectStore transactions while
/// moving only Codable work to an owned thread with a bounded larger stack.
enum ProjectManifestEncoding {
    private final class Work: @unchecked Sendable {
        let manifest: ProjectManifest
        let finished = DispatchSemaphore(value: 0)
        // Publication is synchronized by finished; only the worker writes.
        var result: Result<Data, Error>?
        init(_ manifest: ProjectManifest) { self.manifest = manifest }
        func encode() {
            autoreleasepool { result = Result { try JSONEncoder.veloEdit.encode(manifest) } }
            finished.signal()
        }
    }

    static func encode(_ manifest: ProjectManifest) throws -> Data {
        let work = Work(manifest)
        let thread = Thread { work.encode() }
        thread.name = "VeloEdit project encoding"
        thread.stackSize = 8 * 1024 * 1024
        thread.start()
        work.finished.wait()
        return try work.result!.get()
    }
}
