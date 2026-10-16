import Foundation
import ImageIO

/// One orientation-correct source observation, independent of the edit's hold,
/// crop and movie raster. Identity includes the actual file's size/mtime/ctime.
struct PhotoSourceAnalysis: Sendable {
    static let version = 1
    static let longEdge = 960
    static let frames = FrameCache(rootURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("VeloEdit-PhotoSource-v\(version)"))
    let sample: VisualFrameSample
    let width: Int
    let height: Int
    let orientation: Int
    let visionCalls: Int

    static func inspect(_ asset: MediaAsset) async throws -> Self {
        guard let source = CGImageSourceCreateWithURL(asset.originalURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard (1...8).contains(orientation) else { throw CocoaError(.fileReadCorruptFile) }
        let outcome = try await AdaptiveFrameSampler().samplePhoto(url: asset.originalURL,
            sourceHash: "photo-v\(version)|" + asset.contentHash, maximumSize: longEdge, frameCache: frames)
        guard let sample = outcome.samples.first else { throw CocoaError(.fileReadCorruptFile) }
        return Self(sample: sample, width: orientation >= 5 ? height : width,
            height: orientation >= 5 ? width : height, orientation: orientation, visionCalls: outcome.visionCallCount)
    }
}

/// Source type wins even when a still has acquired an encoded video proxy.
enum OriginalMediaType {
    static func isPhoto(_ item: TimelineItem, assets: [MediaAsset]) -> Bool {
        assets.first(where: { $0.id == item.assetID }).map { $0.kind == .photo } ?? (item.kind == .photo)
    }
    static func isVideo(_ item: TimelineItem, assets: [MediaAsset]) -> Bool {
        guard item.overlay == nil else { return false }
        return assets.first(where: { $0.id == item.assetID }).map { $0.kind == .video } ?? (item.kind == .video)
    }
}
