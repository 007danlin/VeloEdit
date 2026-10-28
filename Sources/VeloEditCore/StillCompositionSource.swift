import Foundation
import AVFoundation
import CoreImage
import CoreVideo

/// A still is a source image plus an edit, never a full-duration scratch movie.
/// AVFoundation gets one tiny clock track; the compositor draws the actual
/// source at each requested time, including seeks, transitions and export.
struct StillCompositionSource {
    enum Content {
        case photo(URL)
        case title(String, TitleStyle)
    }
    let content: Content
    let identity: String
    let item: TimelineItem
    let size: CGSize
    let frameRate: Double
    let preset: BackgroundPreset?
    let intensity: CGFloat

    func image() throws -> CIImage {
        switch content {
        case .photo(let url):
            guard let image = StillImageRenderGeometry.orientedImage(at: url) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return image
        case .title(let text, let style):
            return CIImage(cgImage: try TitleCardVideoGenerator.image(text: text, style: style,
                width: Int(size.width), height: Int(size.height)))
        }
    }

    func frame(from image: CIImage, progress: Double) -> CIImage {
        guard case .photo = content else { return image }
        let frameDuration = VideoFrameTiming.duration(for: frameRate).seconds
        let frames = max(1, Int(ceil(item.timelineDuration / frameDuration - 0.000_001)))
        // Match the old generator's first/last-frame positions exactly.
        // Use the media clock even when the cut ends between frames. The
        // epsilon only absorbs floating-point error at exact frame boundaries.
        let index = min(frames - 1, max(0, Int((progress * item.timelineDuration / frameDuration + 0.000_000_1).rounded(.down))))
        let frameProgress = frames <= 1 ? 0 : CGFloat(index) / CGFloat(frames - 1)
        return StillImageRenderGeometry.frame(image: image, size: size, progress: frameProgress,
            duration: item.timelineDuration,
            motion: item.effect.flatMap(ClipEffect.init(rawValue:)) ?? preset?.animationMotion ?? .zoomIn,
            subjectReframe: item.effectiveVideoAdjustments.subjectReframe,
            cropStyle: item.effectiveVideoAdjustments.crop,
            backgroundAnimationStyle: preset?.animationStyle, intensity: intensity)
    }

    private static let stillColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private static let decodedStillColorSpace = CVImageBufferCreateColorSpaceFromAttachments([
        kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2
    ] as CFDictionary)?.takeRetainedValue()

    static func videoColorMatched(_ image: CIImage) -> CIImage {
        // The old intermediate held sRGB samples, decoded with Core Video's
        // synthesized HDTV profile. The named itur_709 ICC profile has a
        // different transfer curve and darkens these samples. Reproduce the
        // decoder's profile in memory, without encoding a scratch movie.
        guard let srgb = stillColorSpace,
              let video = decodedStillColorSpace,
              let samples = image.matchedFromWorkingSpace(to: srgb),
              let matched = samples.matchedToWorkingSpace(from: video) else { return image }
        return matched
    }
}

/// Only recently used source images are retained. The number and duration of
/// clips do not determine resident memory or create a disk-backed movie cache.
final class StillCompositionImageCache {
    private let images = NSCache<NSString, CIImage>()
    private let maximumBytes = 128 * 1_024 * 1_024

    init() {
        images.totalCostLimit = maximumBytes
        images.countLimit = 8
    }

    func image(for source: StillCompositionSource) throws -> CIImage {
        if let image = images.object(forKey: source.identity as NSString) { return image }
        let image = try source.image()
        let cost = min(Double(Int.max / 2), image.extent.width * image.extent.height * 4)
        if cost < Double(maximumBytes) {
            images.setObject(image, forKey: source.identity as NSString, cost: Int(cost))
        }
        return image
    }

    func frame(for source: StillCompositionSource, progress: Double, context: CIContext) throws -> CIImage {
        let staticFit: Bool
        if case .photo = source.content {
            staticFit = source.item.effectiveVideoAdjustments.crop == .fit &&
                source.item.effectiveVideoAdjustments.subjectReframe == nil && source.preset?.animationStyle == nil
        } else { staticFit = false }
        guard staticFit else { return source.frame(from: try image(for: source), progress: progress) }
        let key = "fit|\(source.identity)|\(source.size.width)x\(source.size.height)" as NSString
        if let frame = images.object(forKey: key) { return frame }
        let frame = source.frame(from: try image(for: source), progress: 0)
        // The static blurred surround is expensive at 4K. Rasterize once in
        // the same sRGB/8-bit surface as the former still-video generator.
        // Keep this in the shared memory budget, never in a movie on disk.
        guard let raster = context.createCGImage(frame, from: CGRect(origin: .zero, size: source.size),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return frame }
        let result = CIImage(cgImage: raster)
        let cost = raster.bytesPerRow * raster.height
        if cost < maximumBytes { images.setObject(result, forKey: key, cost: cost) }
        return result
    }
}
