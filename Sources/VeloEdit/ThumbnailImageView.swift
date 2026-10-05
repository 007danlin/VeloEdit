import SwiftUI
import AppKit
import ImageIO
import VeloEditCore

/// Keeps thumbnail disk I/O and image decoding out of SwiftUI's body pass.
/// Timeline filmstrips may display the same source image dozens of times, so a
/// shared cache avoids decoding it again whenever the playhead or hover moves.
final class ThumbnailImageCache: @unchecked Sendable {
    static let shared = ThumbnailImageCache()

    fileprivate let cache = NSCache<NSURL, NSImage>()
    private let loader = ThumbnailImageLoader()

    private init() {
        cache.countLimit = 512
        cache.totalCostLimit = 192 * 1_024 * 1_024
    }

    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = cachedImage(for: url) { return cached }
        return await loader.image(for: url, cache: self)
    }

}

/// Serial background decoding bounds CPU/memory demand when hundreds of clips
/// become visible. Re-checking the shared cache also coalesces duplicate loads.
private actor ThumbnailImageLoader {
    func image(for url: URL, cache: ThumbnailImageCache) -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cache.cachedImage(for: url) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              !Task.isCancelled else { return nil }
        let image = NSImage(cgImage: decoded, size: .zero)
        cache.cache.setObject(image, forKey: url as NSURL, cost: decoded.bytesPerRow * decoded.height)
        return image
    }
}

/// Draws selected cells from a cached composite filmstrip at a stable visual
/// width. The number of visible cells follows the clip width, while their
/// source frames stay distributed across the whole edited range.
struct CachedAdaptiveFilmstripImage: View {
    let url: URL?
    let kind: MediaKind
    let sourceFrameCount: Int
    var targetTileWidth: CGFloat = 104

    @State private var image: NSImage?
    @Environment(\.timelineRenderRange) private var renderRange

    var body: some View {
        GeometryReader { proxy in
            if let image {
                let fullWidth = proxy.size.width
                let slice = TimelineDrawingSlice(width: fullWidth,
                    origin: proxy.frame(in: .named("timelineCanvas")).minX, range: renderRange)
                Canvas(opaque: true, rendersAsynchronously: true) { context, size in
                    let visibleCount = max(1, Int(ceil(fullWidth / targetTileWidth)))
                    let tileWidth = fullWidth / CGFloat(visibleCount)
                    let sourceCount = max(1, sourceFrameCount)
                    let swiftUIImage = Image(nsImage: image)
                    for visibleIndex in slice.indices(count: visibleCount, fullWidth: fullWidth) {
                        let fraction = visibleCount == 1 ? 0.5 : Double(visibleIndex) / Double(visibleCount - 1)
                        let sourceIndex = min(sourceCount - 1, Int((fraction * Double(sourceCount - 1)).rounded()))
                        let tileRect = CGRect(x: CGFloat(visibleIndex) * tileWidth - slice.lower, y: 0, width: tileWidth, height: size.height)
                        context.drawLayer { layer in
                            layer.clip(to: Path(tileRect))
                            layer.draw(
                                swiftUIImage,
                                in: CGRect(
                                    x: tileRect.minX - CGFloat(sourceIndex) * tileWidth,
                                    y: 0,
                                    width: tileWidth * CGFloat(sourceCount),
                                    height: size.height
                                )
                            )
                        }
                    }
                }
                .frame(width: slice.width, height: proxy.size.height)
                .offset(x: slice.lower)
            } else {
                ZStack {
                    Color.secondary.opacity(0.13)
                    Image(systemName: kind == .video ? "video.fill" : "photo.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            if let cached = ThumbnailImageCache.shared.cachedImage(for: url) {
                image = cached
            } else {
                let loaded = await ThumbnailImageCache.shared.image(for: url)
                guard !Task.isCancelled else { return }
                image = loaded
            }
        }
    }
}

struct CachedThumbnailImage: View {
    let url: URL?
    let kind: MediaKind
    var contentMode: ContentMode = .fit
    var stretchesToFill = false

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                if stretchesToFill {
                    Image(nsImage: image).resizable()
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                }
            } else {
                ZStack {
                    Color.secondary.opacity(0.13)
                    Image(systemName: kind == .video ? "video.fill" : "photo.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            if let cached = ThumbnailImageCache.shared.cachedImage(for: url) {
                image = cached
                return
            }
            let loaded = await ThumbnailImageCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
