import SwiftUI
import AppKit
import VeloEditCore

/// Keeps thumbnail disk I/O and image decoding out of SwiftUI's body pass.
/// Timeline filmstrips may display the same source image dozens of times, so a
/// shared cache avoids decoding it again whenever the playhead or hover moves.
final class ThumbnailImageCache: @unchecked Sendable {
    static let shared = ThumbnailImageCache()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 512
        cache.totalCostLimit = 192 * 1_024 * 1_024
    }

    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = cachedImage(for: url) { return cached }
        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: url, options: [.mappedIfSafe])
        }.value
        guard !Task.isCancelled, let data, let image = NSImage(data: data) else { return nil }
        let pixels = max(1, Int(image.size.width * image.size.height))
        cache.setObject(image, forKey: url as NSURL, cost: pixels * 4)
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

    var body: some View {
        GeometryReader { proxy in
            if let image {
                Canvas(opaque: true, rendersAsynchronously: false) { context, size in
                    let visibleCount = max(1, Int(ceil(size.width / targetTileWidth)))
                    let tileWidth = size.width / CGFloat(visibleCount)
                    let sourceCount = max(1, sourceFrameCount)
                    let swiftUIImage = Image(nsImage: image)
                    for visibleIndex in 0..<visibleCount {
                        let fraction = visibleCount == 1 ? 0.5 : Double(visibleIndex) / Double(visibleCount - 1)
                        let sourceIndex = min(sourceCount - 1, Int((fraction * Double(sourceCount - 1)).rounded()))
                        let tileRect = CGRect(x: CGFloat(visibleIndex) * tileWidth, y: 0, width: tileWidth, height: size.height)
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
                image = await ThumbnailImageCache.shared.image(for: url)
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
            image = await ThumbnailImageCache.shared.image(for: url)
        }
    }
}
