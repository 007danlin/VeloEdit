import SwiftUI
import AppKit
import VeloEditCore

/// Keeps thumbnail disk I/O and image decoding out of SwiftUI's body pass.
/// Timeline filmstrips may display the same source image dozens of times, so a
/// shared cache avoids decoding it again whenever the playhead or hover moves.
private final class ThumbnailImageCache: @unchecked Sendable {
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

struct CachedThumbnailImage: View {
    let url: URL?
    let kind: MediaKind
    var contentMode: ContentMode = .fit

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
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
