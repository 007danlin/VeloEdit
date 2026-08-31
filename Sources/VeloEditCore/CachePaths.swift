import Foundation

public struct CachePaths: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func thumbnail(for asset: MediaAsset) -> URL {
        root.appendingPathComponent("Thumbnails", isDirectory: true).appendingPathComponent("\(asset.contentHash.prefix(20)).jpg")
    }

    public func proxy(for asset: MediaAsset) -> URL {
        root.appendingPathComponent("Proxies", isDirectory: true).appendingPathComponent("\(asset.contentHash.prefix(20)).mp4")
    }

    public func analysisProxy(for asset: MediaAsset, longEdge: Int) -> URL {
        root.appendingPathComponent("Proxies", isDirectory: true)
            .appendingPathComponent("\(asset.contentHash.prefix(20))-analysis-\(longEdge)p.mp4")
    }

    public var frameCacheDirectory: URL {
        root.appendingPathComponent("Frames", isDirectory: true)
    }

    public var analysisCacheDirectory: URL {
        root.appendingPathComponent("Analysis", isDirectory: true)
    }

    public var deepMediaCacheDirectory: URL {
        analysisCacheDirectory.appendingPathComponent("DeepMedia", isDirectory: true)
    }

    public var backgroundsDirectory: URL {
        root.appendingPathComponent("Backgrounds", isDirectory: true)
    }

    public var previewDerivedMediaDirectory: URL {
        root.appendingPathComponent("Preview", isDirectory: true)
            .appendingPathComponent("DerivedMedia", isDirectory: true)
    }

    public func previewDerivedMedia(identity: String) -> URL {
        previewDerivedMediaDirectory.appendingPathComponent("\(identity).mov")
    }

    public func background(_ preset: BackgroundPreset, width: Int, height: Int) -> URL {
        backgroundsDirectory.appendingPathComponent("\(preset.rawValue)-v3-\(width)x\(height).png")
    }

    public var throughputHistory: URL {
        analysisCacheDirectory.appendingPathComponent("throughput-history.json")
    }

    public func timelineThumbnail(for item: TimelineItem, asset: MediaAsset) -> URL {
        let start = Int((item.sourceStart * 1000).rounded())
        let duration = Int((item.sourceDuration * 1000).rounded())
        return root.appendingPathComponent("TimelineThumbnails", isDirectory: true)
            .appendingPathComponent("\(item.id.uuidString)-\(asset.contentHash.prefix(12))-\(start)-\(duration).jpg")
    }

    public func analysisKey(for asset: MediaAsset, schemaVersion: Int) -> String {
        "\(asset.contentHash)-analysis-v\(schemaVersion)"
    }
}
