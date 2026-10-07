import Foundation
import CoreGraphics
import VeloEditCore

/// OVRLEY launches a helper process. Never run it during a SwiftUI body/layout
/// pass: waitUntilExit can pump the main run loop and reenter AttributeGraph.
actor TelemetryPreviewCache {
    struct Request: Hashable {
        let kind: TelemetryWidgetKind
        let presentation: TelemetryWidgetPresentation
        let style: TelemetryWidgetStyle
        let width: Int
        let height: Int

        init(kind: TelemetryWidgetKind, presentation: TelemetryWidgetPresentation,
             style: TelemetryWidgetStyle, size: CGSize) {
            self.kind = kind
            self.presentation = presentation
            self.style = style
            // Bucket transient layout sizes to keep scrolling/resizing cheap.
            let valid = size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            let size = valid ? size : CGSize(width: 160, height: 90)
            let longest = max(size.width, size.height)
            let bucket = (min(512, max(32, longest * 2)) / 16).rounded(.up) * 16
            let scale = bucket / longest
            // Cap both axes by one scale, otherwise wide cards stretch circles
            // into ellipses when the bitmap is displayed at the card's size.
            width = max(1, Int((size.width * scale).rounded()))
            height = max(1, Int((size.height * scale).rounded()))
        }
    }

    static let shared = TelemetryPreviewCache()
    private let cache = NSCache<NSString, CGImage>()
    private let render: @Sendable (Request) -> CGImage?

    init(render: @escaping @Sendable (Request) -> CGImage? = { request in
        TelemetryOverlayRenderer.previewCGImage(kind: request.kind, presentation: request.presentation,
            style: request.style, size: CGSize(width: request.width, height: request.height))
    }) {
        self.render = render
        cache.countLimit = 128
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    func image(for request: Request) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let key = "\(request.kind.rawValue)|\(request.presentation.rawValue)|\(request.style.rawValue)|\(request.width)x\(request.height)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let image = autoreleasepool(invoking: { render(request) }) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}
