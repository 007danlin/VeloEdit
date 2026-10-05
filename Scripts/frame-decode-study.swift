// swiftc -O -parse-as-library Scripts/frame-decode-study.swift -o Build/Performance/frame-decode-study
import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

struct Input: Decodable { var url: String; var times: [Double]; var size: Int }
struct Frame: Codable, Equatable { var requested: Double; var actual: Double; var jpegSHA256: String }
struct Run: Codable { var input: String; var pair: Int; var method: String; var seconds: Double; var frames: [Frame]; var errors: Int }
func frame(_ image: CGImage, requested: CMTime, actual: CMTime) -> Frame {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.68] as CFDictionary)
    CGImageDestinationFinalize(destination)
    return Frame(requested: requested.seconds, actual: actual.seconds, jpegSHA256: SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined())
}
final class Results: @unchecked Sendable {
    let lock = NSLock()
    var frames: [Frame] = []
    var errors = 0
    var remaining: Int
    init(_ count: Int) { remaining = count }
    func add(_ item: Frame?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let item { frames.append(item) } else { errors += 1 }
        remaining -= 1; return remaining == 0
    }
}
@main struct Study {
    static func main() async throws {
        let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: inputURL))
        var runs: [Run] = []
        for input in inputs {
            let times = input.times.map { CMTime(seconds: $0, preferredTimescale: 600) }
            for pair in 1...5 {
                for method in pair % 2 == 1 ? ["sync", "batch"] : ["batch", "sync"] {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: input.url)))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: input.size, height: input.size)
                    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
                    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
                    let results = Results(times.count)
                    let start = ProcessInfo.processInfo.systemUptime
                    if method == "sync" {
                        for time in times {
                            var actual = CMTime.zero
                            do { _ = results.add(frame(try generator.copyCGImage(at: time, actualTime: &actual), requested: time, actual: actual)) }
                            catch { _ = results.add(nil) }
                        }
                    } else if !times.isEmpty {
                        await withCheckedContinuation { continuation in
                            generator.generateCGImagesAsynchronously(forTimes: times.map(NSValue.init(time:))) { requested, image, actual, status, _ in
                                let item = status == .succeeded ? image.map { frame($0, requested: requested, actual: actual) } : nil
                                if results.add(item) { continuation.resume() }
                            }
                        }
                    }
                    let run = Run(input: input.url, pair: pair, method: method, seconds: ProcessInfo.processInfo.systemUptime - start,
                                  frames: results.frames.sorted { $0.requested < $1.requested }, errors: results.errors)
                    runs.append(run)
                    try JSONEncoder().encode(runs).write(to: outputURL, options: .atomic)
                    print("\(pair) \(method) \(input.size) \(run.seconds) seconds, \(run.errors) errors")
                }
            }
        }
    }
}
