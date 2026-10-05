import AVFoundation

/// AVAssetReader can block while a composition asks Swift tasks for more work.
/// Never occupy a cooperative executor thread with that synchronous wait: a
/// handful of simultaneous exports could otherwise stall every pending task.
enum MediaSampleReader {
    // Exactly one read is in flight, awaited before another read, status
    // access, or teardown. Keep both objects alive until the worker returns.
    private final class ReadOperation: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let reader: AVAssetReader
        init(output: AVAssetReaderOutput, reader: AVAssetReader) {
            self.output = output
            self.reader = reader
        }
    }

    static func next(from output: AVAssetReaderOutput, reader: AVAssetReader) async throws -> CMSampleBuffer? {
        try Task.checkCancellation()
        let operation = ReadOperation(output: output, reader: reader)
        let buffer: CMSampleBuffer? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let sample = withExtendedLifetime(operation) {
                    operation.output.copyNextSampleBuffer()
                }
                continuation.resume(returning: sample)
            }
        }
        // Do not cancel the reader from a task cancellation handler: AVFoundation
        // can free its visual context while copyNextSampleBuffer still uses it.
        // Await this one sample, then throw so the caller's defer cancels safely.
        try Task.checkCancellation()
        return buffer
    }
}
