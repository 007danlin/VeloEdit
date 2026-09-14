import CoreGraphics
import CoreImage
import Foundation

/// Produces a transparent title/support layer for the native AVPlayer viewer.
/// Unaffected pixels stay transparent, so the video retains its native quality.
public final class AdaptiveTitlePreviewRenderer: @unchecked Sendable {
    private let adaptation = AdaptiveTitleBackgroundRenderer()
    private let context = CIContext(options: [.cacheIntermediates: false])

    public init() {}

    public func image(items: [TitleTimelineItem], timelineTime: Double, renderSize: CGSize,
                      background: CIImage?) -> CGImage? {
        let bounds = CGRect(origin: .zero, size: renderSize)
        var overlay = CIImage(color: .clear).cropped(to: bounds)
        var hasTitle = false
        for item in items.sorted(by: { $0.track < $1.track }) where
            item.enabled && timelineTime >= item.startTime && timelineTime < item.endTime {
            hasTitle = true
            let layer: CIImage?
            if let background {
                layer = TitleOverlayRenderer.composited(
                    item: item, timelineTime: timelineTime, renderSize: renderSize,
                    over: overlay.composited(over: background), adaptation: adaptation, overlayOnly: true
                )
            } else {
                layer = TitleOverlayRenderer.image(item: item, timelineTime: timelineTime, renderSize: renderSize)
            }
            if let layer { overlay = layer.composited(over: overlay) }
        }
        return hasTitle ? context.createCGImage(overlay, from: bounds) : nil
    }
}
