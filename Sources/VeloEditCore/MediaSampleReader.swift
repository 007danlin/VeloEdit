import AVFoundation

/// AVAssetReader can block while a composition asks Swift tasks for more work.
/// Never occupy a cooperative executor thread with that synchronous wait: a
/// handful of simultaneous exports could otherwise stall every pending task.
enum MediaSampleReader {
    // Exactly one read is in flight, awaited before another read or status
    // access. AVAssetReader's cancellation may interrupt that blocking read.
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
        let buffer: CMSampleBuffer? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: operation.output.copyNextSampleBuffer())
                }
            }
        } onCancel: {
            operation.reader.cancelReading()
        }
        try Task.checkCancellation()
        return buffer
    }
}
