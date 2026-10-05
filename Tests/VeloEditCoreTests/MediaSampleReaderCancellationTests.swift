import Foundation
import AVFoundation
import Testing
@testable import VeloEditCore

@Suite struct MediaSampleReaderCancellationTests {
    @Test func cancellationWaitsForTheInFlightReadBeforeTearingDownTheReader() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let reader = try AVAssetReader(asset: fixture.asset)
        let output = GatedTrackOutput(track: fixture.track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        let task = Task {
            defer { reader.cancelReading() }
            _ = try await MediaSampleReader.next(from: output, reader: reader)
        }
        defer { output.release.signal() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !output.hasStarted && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(output.hasStarted)
        task.cancel()
        // The old cancellation handler synchronously destroyed the decoder
        // here, while copyNextSampleBuffer was still executing on its worker.
        #expect(reader.status == .reading)
        output.release.signal()
        do {
            _ = try await task.value
            Issue.record("A cancelled read returned successfully")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(output.hasFinished)
        #expect(reader.status == .cancelled)
    }

    @Test func alreadyCancelledTaskDoesNotStartReading() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let reader = try AVAssetReader(asset: fixture.asset)
        let output = GatedTrackOutput(track: fixture.track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        defer { reader.cancelReading(); output.release.signal() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await MediaSampleReader.next(from: output, reader: reader)
        }
        do {
            _ = try await task.value
            Issue.record("A cancelled read returned successfully")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(!output.hasStarted)
        #expect(reader.status == .reading)
    }

    @Test func uncancelledReaderStillDeliversSamplesThroughEndOfStream() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let reader = try AVAssetReader(asset: fixture.asset)
        let output = AVAssetReaderTrackOutput(track: fixture.track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        defer { if reader.status == .reading { reader.cancelReading() } }
        var frames = 0
        while let sample = try await MediaSampleReader.next(from: output, reader: reader) {
            frames += CMSampleBufferGetNumSamples(sample)
        }
        #expect(frames == 8_000)
        #expect(reader.status == .completed)
    }

    /// Holds the synchronous call open without depending on decoder timing or
    /// provoking an actual use-after-free in AVFoundation on a failing run.
    private final class GatedTrackOutput: AVAssetReaderTrackOutput, @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var started = false
        private var finished = false
        var hasStarted: Bool { lock.withLock { started } }
        var hasFinished: Bool { lock.withLock { finished } }

        override func copyNextSampleBuffer() -> CMSampleBuffer? {
            lock.withLock { started = true }
            let result = release.wait(timeout: .now() + 10)
            #expect(result == .success, "Test did not release the pending sample read")
            lock.withLock { finished = true }
            return nil
        }
    }

    private struct Fixture {
        let url: URL
        let asset: AVURLAsset
        let track: AVAssetTrack

        static func make() async throws -> Fixture {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("veloedit-reader-\(UUID().uuidString).caf")
            do {
                let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
                buffer.frameLength = 8_000
                let channel = try #require(buffer.floatChannelData?[0])
                channel.update(repeating: 0, count: 8_000)
                try write(buffer, format: format, to: url)
                let asset = AVURLAsset(url: url)
                let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
                return Fixture(url: url, asset: asset, track: track)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }

        private static func write(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat, to url: URL) throws {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }
}
