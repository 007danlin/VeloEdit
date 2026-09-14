import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import CoreImage
import VideoToolbox

/// Deterministic export path for compositions that require rendered frames.
/// Renders the shared composition straight into the delivery encoder. There
/// is no lossy JPEG intermediate or preset-driven second video encode.
enum SoftwareCompositionExporter {
    static func remaster(source: URL, gainDB: Double, duration: Double, destination: URL) async throws {
        let directory = destination.deletingLastPathComponent()
            .appendingPathComponent(".veloedit-remaster-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("mastered.m4a")
        try await encodeAudio(
            asset: AVURLAsset(url: source),
            audioMix: nil,
            gainDB: gainDB,
            directory: directory,
            destination: audioURL,
            duration: duration
        )
        try? FileManager.default.removeItem(at: destination)
        try await mux(videoURL: source, audioURL: audioURL, duration: duration, destination: destination)
    }

    static func export(
        asset: AVAsset,
        videoComposition: AVVideoComposition?,
        audioMix: AVAudioMix?,
        settings: ExportVideoSettings,
        duration: Double,
        destination: URL,
        softwareEncoder: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        var resourcePacer = ResourceWorkPacer()
        try await resourcePacer.checkpoint()
        try? FileManager.default.removeItem(at: destination)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw DerivedMediaError.noVideoTrack }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let temporaryDirectory = destination.deletingLastPathComponent()
            .appendingPathComponent(".veloedit-software-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let encodedVideoURL = temporaryDirectory.appendingPathComponent("video.mp4")
        let writer = try AVAssetWriter(outputURL: encodedVideoURL, fileType: .mp4)
        var writerSettings = settings.writerSettings
        if softwareEncoder {
            writerSettings[AVVideoEncoderSpecificationKey] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
        videoInput.mediaTimeScale = 6_000_000
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw DerivedMediaError.exportFailed("delivery writer cannot add video input") }
        writer.add(videoInput)

        guard writer.startWriting() else {
            throw DerivedMediaError.exportFailed("delivery video writer start: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        frames.videoComposition = videoComposition
        frames.alwaysCopiesSampleData = false
        guard reader.canAdd(frames) else { throw DerivedMediaError.exportFailed("cannot read the video composition") }
        reader.add(frames)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 6_000_000))
        guard reader.startReading() else {
            throw DerivedMediaError.exportFailed("composition reader: \(reader.error?.localizedDescription ?? "unknown error")")
        }
        defer {
            if writer.status == .writing { writer.cancelWriting() }
            if reader.status == .reading { reader.cancelReading() }
        }
        // Preserve the compositor's pixel buffers, color attachments and exact
        // rational timestamps. A CGImage round trip changes the transfer curve
        // and can select neighbouring frames at fractional rates.
        while true {
            try await resourcePacer.checkpoint()
            guard let sample = try await MediaSampleReader.next(from: frames, reader: reader) else { break }
            while !videoInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else {
                    throw DerivedMediaError.exportFailed("delivery writer: \(writer.error?.localizedDescription ?? "stopped")")
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard videoInput.append(sample) else {
                throw DerivedMediaError.exportFailed("delivery writer rejected a frame: \(writer.error?.localizedDescription ?? "unknown error")")
            }
            progress?(0.92 * min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration))
        }
        guard reader.status == .completed else {
            throw DerivedMediaError.exportFailed("composition reader: \(reader.error?.localizedDescription ?? "incomplete")")
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw DerivedMediaError.exportFailed("delivery video writer finish: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        await FilmBuildReporting.report(FilmBuildProgress(.controlExport, detail: "Соединяю готовое видео и звук"))
        if audioTracks.isEmpty {
            try FileManager.default.moveItem(at: encodedVideoURL, to: destination)
        } else {
            let audioURL = temporaryDirectory.appendingPathComponent("audio.m4a")
            try await encodeAudio(
                asset: asset,
                audioMix: audioMix,
                gainDB: 0,
                directory: temporaryDirectory,
                destination: audioURL,
                duration: duration
            )
            try await mux(videoURL: encodedVideoURL, audioURL: audioURL, duration: duration, destination: destination)
        }
        progress?(1)
    }

    private static func encodeAudio(
        asset: AVAsset,
        audioMix: AVAudioMix?,
        gainDB: Double,
        directory: URL,
        destination: URL,
        duration: Double
    ) async throws {
        let encodeAsset: AVAsset
        if abs(gainDB) >= 0.01 {
            let pcmURL = directory.appendingPathComponent("mastered.caf")
            try await writeAmplifiedPCM(
                asset: asset,
                audioMix: audioMix,
                gainDB: gainDB,
                destination: pcmURL
            )
            encodeAsset = AVURLAsset(url: pcmURL)
        } else {
            encodeAsset = asset
        }
        guard let session = AVAssetExportSession(asset: encodeAsset, presetName: AVAssetExportPresetAppleM4A) else {
            throw DerivedMediaError.exportFailed("software export cannot create the AAC audio pass")
        }
        session.outputURL = destination
        session.outputFileType = .m4a
        if abs(gainDB) < 0.01 { session.audioMix = audioMix }
        session.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: max(0.05, duration), preferredTimescale: 48_000)
        )
        do {
            try await EditorialAudioMastering.export(session, timeout: 180)
        } catch {
            throw DerivedMediaError.exportFailed("software AAC pass: \(error.localizedDescription)")
        }
    }

    private static func writeAmplifiedPCM(
        asset: AVAsset,
        audioMix: AVAudioMix?,
        gainDB: Double,
        destination: URL
    ) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw DerivedMediaError.exportFailed("mastering source has no audio") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = audioMix
        guard reader.canAdd(output) else { throw DerivedMediaError.exportFailed("mastering reader cannot add PCM output") }
        reader.add(output)
        guard reader.startReading() else {
            throw DerivedMediaError.exportFailed("mastering reader start: \(reader.error?.localizedDescription ?? "unknown error")")
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw DerivedMediaError.exportFailed("mastering PCM format is unavailable")
        }
        try? FileManager.default.removeItem(at: destination)
        let file = try AVAudioFile(
            forWriting: destination,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let factor = Float(pow(10, gainDB / 20))
        defer { if reader.status == .reading { reader.cancelReading() } }
        var resourcePacer = ResourceWorkPacer()
        while true {
            try await resourcePacer.checkpoint()
            guard let sample = try await MediaSampleReader.next(from: output, reader: reader) else { break }
            guard let block = CMSampleBufferGetDataBuffer(sample) else {
                throw DerivedMediaError.exportFailed("mastering PCM sample has no data")
            }
            let sampleCount = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            let frameCount = sampleCount / 2
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
                  let channels = buffer.floatChannelData else { continue }
            var values = [Float](repeating: 0, count: sampleCount)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else {
                throw DerivedMediaError.exportFailed("mastering PCM copy failed")
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            for frame in 0..<frameCount {
                channels[0][frame] = min(0.999, max(-0.999, values[frame * 2] * factor))
                channels[1][frame] = min(0.999, max(-0.999, values[frame * 2 + 1] * factor))
            }
            try file.write(from: buffer)
        }
        guard reader.status == .completed else {
            throw DerivedMediaError.exportFailed("mastering reader finish: \(reader.error?.localizedDescription ?? "unknown error")")
        }
    }

    /// Audio is encoded separately. Muxing and subsequent mastering copy the
    /// video stream without another generation of compression.
    private static func mux(videoURL: URL, audioURL: URL, duration: Double, destination: URL) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw DerivedMediaError.exportFailed("software mux is missing an encoded stream")
        }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw DerivedMediaError.exportFailed("software mux cannot create destination tracks")
        }
        let requested = CMTimeRange(start: .zero, duration: CMTime(seconds: max(0.05, duration), preferredTimescale: 600))
        let videoRange = CMTimeRangeGetIntersection(try await sourceVideo.load(.timeRange), otherRange: requested)
        let audioRange = CMTimeRangeGetIntersection(try await sourceAudio.load(.timeRange), otherRange: requested)
        try videoTrack.insertTimeRange(videoRange, of: sourceVideo, at: .zero)
        try audioTrack.insertTimeRange(audioRange, of: sourceAudio, at: .zero)
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw DerivedMediaError.exportFailed("software mux cannot create a passthrough session")
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        session.timeRange = requested
        do {
            try await EditorialAudioMastering.export(session, timeout: 180)
        } catch {
            throw DerivedMediaError.exportFailed("software mux: \(error.localizedDescription)")
        }
    }
}
