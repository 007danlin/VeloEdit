import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@main struct InspectExport {
    static func main() async throws {
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let video = tracks.first else { throw URLError(.cannotDecodeContentData) }
        let size = try await video.load(.naturalSize)
        let fps = try await video.load(.nominalFrameRate)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var audioMeasurement: [String: Any] = [:]
        if let track = audio.first {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
            guard reader.canAdd(output) else { throw URLError(.cannotDecodeContentData) }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? URLError(.cannotDecodeContentData) }
            var count = 0, clipped = 0
            var squares = 0.0, peak = 0.0
            while let sample = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let byteCount = CMBlockBufferGetDataLength(block)
                var values = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.stride)
                let status = values.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: bytes.baseAddress!)
                }
                guard status == noErr else { throw URLError(.cannotDecodeContentData) }
                for value in values {
                    let magnitude = abs(Double(value))
                    squares += magnitude * magnitude
                    peak = max(peak, magnitude)
                    if magnitude >= 1 { clipped += 1 }
                }
                count += values.count
            }
            guard reader.status == .completed else { throw reader.error ?? URLError(.cannotDecodeContentData) }
            audioMeasurement = ["decodedPCMValues": count, "rms": sqrt(squares / Double(max(1, count))),
                                "peak": peak, "clippedValues": clipped]
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var samples: [[String: Any]] = []
        let extraTimes = CommandLine.arguments.dropFirst(3).compactMap(Double.init)
        for time in [0.5, 10, 30, 60, 90, min(118, duration - 0.5)] + extraTimes where time >= 0 && time < duration {
            var actual = CMTime.zero
            let image = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: &actual)
            let target = root.appendingPathComponent("frame-\(time).jpg")
            guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw URLError(.cannotCreateFile) }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw URLError(.cannotWriteToFile) }
            samples.append(["requested":time,"actual":actual.seconds,"width":image.width,"height":image.height,"file":target.path])
        }
        let report: [String: Any] = ["file":file.path,"duration":duration,"width":size.width,"height":size.height,"fps":fps,"audioTracks":audio.count,"audioMeasurement":audioMeasurement,"decodedSamples":samples]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
        try data.write(to: root.appendingPathComponent("measurement.json"), options: .atomic)
        print(String(decoding:data,as:UTF8.self))
    }
}
