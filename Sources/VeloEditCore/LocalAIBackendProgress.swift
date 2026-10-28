import Foundation

/// An optional witness from our private runtime, never model evidence. Only
/// newly appended, advancing work can postpone the first-response watchdog;
/// it cannot extend the total budget or certify an answer.
final class LocalAIBackendProgress: @unchecked Sendable {
    struct Update: Equatable {
        var phase: String
        var fraction: Double? = nil
        var tokens: Int? = nil
    }

    private let handle: FileHandle
    private let lock = NSLock()
    private var offset: UInt64
    private var pending = Data()
    private var loadingMilestones: Set<String> = []
    private var taskID: String?
    private var processedTokens = 0
    private static let promptPattern = try! NSRegularExpression(
        pattern: #"slot print_timing:.*task\s+(\d+)\s*\| prompt processing, n_tokens\s*=\s*(\d+), progress\s*=\s*([0-9.]+)"#)
    private static let loadingMarkers = [
        "load_tensors: offloaded ", "llama_kv_cache:       MTL0 KV buffer size",
        "common_init_: warming up the model", "get_dummy_batch: warmup with image size",
        "srv    load_model: loaded multimodal model", "llama-server started in"
    ]

    init?(url: URL) {
        guard let file = try? FileHandle(forReadingFrom: url), let end = try? file.seekToEnd() else { return nil }
        handle = file; offset = end // Old successes cannot keep a new request alive.
    }

    deinit { try? handle.close() }

    func next() -> Update? {
        lock.withLock {
            guard let end = try? handle.seekToEnd() else { return nil }
            // Rotation or an excessive backlog is not current progress. Fail
            // closed rather than replaying a long log to prolong a dead job.
            if end < offset || end - offset > 1_048_576 {
                offset = end; pending.removeAll(); return nil
            }
            guard end > offset, (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: 65_536), !data.isEmpty else { return nil }
            offset += UInt64(data.count); pending.append(data)
            var update: Update?
            while let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                if let next = consume(line) { update = next }
            }
            if pending.count > 65_536 { pending.removeAll() }
            return update
        }
    }

    private func consume(_ line: String) -> Update? {
        let text = line as NSString
        if let match = Self.promptPattern.firstMatch(in: line, range: NSRange(location: 0, length: text.length)),
           let count = Int(text.substring(with: match.range(at: 2))),
           let fraction = Double(text.substring(with: match.range(at: 3))), (0...1).contains(fraction) {
            let task = text.substring(with: match.range(at: 1))
            guard taskID == nil || taskID == task, count > processedTokens else { return nil }
            taskID = task; processedTokens = count
            return Update(phase: "prefill", fraction: fraction, tokens: count)
        }
        guard taskID == nil, let marker = Self.loadingMarkers.first(where: line.contains),
              loadingMilestones.insert(marker).inserted else { return nil }
        return Update(phase: "loading")
    }
}
