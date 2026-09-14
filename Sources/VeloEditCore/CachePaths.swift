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

    /// Keep Full HD playback copies separate from legacy 720p and analysis caches.
    public func previewProxy(for asset: MediaAsset) -> URL {
        root.appendingPathComponent("Proxies", isDirectory: true)
            .appendingPathComponent("\(asset.contentHash.prefix(20))-preview-1080p.mp4")
    }

    public func analysisProxy(for asset: MediaAsset, longEdge: Int) -> URL {
        root.appendingPathComponent("Proxies", isDirectory: true)
            .appendingPathComponent("\(asset.contentHash.prefix(20))-analysis-\(longEdge)p.mp4")
    }

    /// Returns an already completed proxy without starting a transcode. This
    /// is the safe render source for camera formats that the current
    /// VideoToolbox process cannot decode reliably (notably some 5K GoPro
    /// HEVC files). A zero-byte/partial export can never be selected.
    public func existingVideoProxy(for asset: MediaAsset) -> URL? {
        videoProxyCandidates(for: asset).first { url in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
            return size > 1_024
        }
    }

    /// Ordered cache locations shared by playback and render. Existence alone
    /// is not validation: readers must skip corrupt/truncated candidates.
    public func videoProxyCandidates(for asset: MediaAsset) -> [URL] {
        let candidates = [previewProxy(for: asset)] + ((try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Proxies", isDirectory: true),
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter {
            $0.lastPathComponent.hasPrefix("\(asset.contentHash.prefix(20))-analysis-") &&
            $0.pathExtension.lowercased() == "mp4"
        }.sorted { lhs, rhs in
            Self.proxyLongEdge(lhs) > Self.proxyLongEdge(rhs)
        } + [proxy(for: asset)]
        return candidates
    }

    public func stableRenderSources(for assets: [MediaAsset]) -> [UUID: URL] {
        Dictionary(uniqueKeysWithValues: assets.compactMap { asset in
            guard Self.requiresStableRenderProxy(asset), let proxy = existingVideoProxy(for: asset) else { return nil }
            return (asset.id, proxy)
        })
    }

    public static func requiresStableRenderProxy(_ asset: MediaAsset) -> Bool {
        guard asset.kind == .video,
              let width = asset.metadata.width,
              let height = asset.metadata.height else { return false }
        let codec = asset.metadata.codec?.lowercased() ?? ""
        return max(width, height) > 4_096 && (codec.contains("hvc") || codec.contains("hevc"))
    }

    private static func proxyLongEdge(_ url: URL) -> Int {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let marker = stem.range(of: "-analysis-", options: .backwards) else { return 0 }
        return Int(stem[marker.upperBound...].dropLast()) ?? 0
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
        timelineThumbnail(for: item, asset: asset, sampleIndex: nil)
    }

    public func timelineThumbnail(for item: TimelineItem, asset: MediaAsset, sampleIndex: Int?) -> URL {
        let start = Int((item.sourceStart * 1000).rounded())
        let duration = Int((item.sourceDuration * 1000).rounded())
        let sample = sampleIndex.map { "-s\($0)" } ?? ""
        return root.appendingPathComponent("TimelineThumbnails", isDirectory: true)
            .appendingPathComponent("\(item.id.uuidString)-\(asset.contentHash.prefix(12))-\(start)-\(duration)\(sample).jpg")
    }

    public func timelineFilmstrip(for item: TimelineItem, asset: MediaAsset, sampleCount: Int) -> URL {
        let start = Int((item.sourceStart * 1000).rounded())
        let duration = Int((item.sourceDuration * 1000).rounded())
        return root.appendingPathComponent("TimelineThumbnails", isDirectory: true)
            .appendingPathComponent("\(item.id.uuidString)-\(asset.contentHash.prefix(12))-\(start)-\(duration)-filmstrip-\(sampleCount)-v4.jpg")
    }

    public func analysisKey(for asset: MediaAsset, schemaVersion: Int) -> String {
        "\(asset.contentHash)-analysis-v\(schemaVersion)"
    }
}
