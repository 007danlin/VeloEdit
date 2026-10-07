import Foundation
import CoreGraphics
import CoreImage
import CoreText

/// Shared camera artwork for library cards, playback and the encoded film.
enum VideoCameraEffectRenderer {
    private static let overlayCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 12
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()

    static func render(_ source: CIImage, barSize: Double, recordingLight: Bool) -> CIImage {
        let extent = source.extent
        let monochrome = source.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: 1.08
        ])
        guard let overlay = overlay(size: extent.size, barSize: barSize, recordingLight: recordingLight) else {
            return monochrome.cropped(to: extent)
        }
        return overlay.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .composited(over: monochrome).cropped(to: extent)
    }

    private static func overlay(size: CGSize, barSize: Double, recordingLight: Bool) -> CIImage? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let width = Int(ceil(size.width)), height = Int(ceil(size.height))
        // Quantize animated margins to pixels so their cache keys stay bounded.
        let barHeight = (size.height * min(max(0, barSize), 0.2)).rounded()
        let key = "\(size.width)x\(size.height):\(barHeight):\(recordingLight)" as NSString
        if let image = overlayCache.object(forKey: key) { return image }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: barHeight))
        context.fill(CGRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight))

        let unit = min(size.width, size.height)
        let inset = unit * 0.045
        let frame = CGRect(x: inset, y: barHeight + inset,
            width: size.width - inset * 2, height: size.height - (barHeight + inset) * 2)
        let corner = unit * 0.065
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        context.setFillColor(CGColor(gray: 1, alpha: 0.95))
        context.setLineWidth(max(0.75, unit * 0.0035))
        context.setLineCap(.square)
        context.setLineJoin(.miter)
        context.setShadow(offset: .zero, blur: unit * 0.004, color: CGColor(gray: 0, alpha: 0.8))
        for (x, dx) in [(frame.minX, corner), (frame.maxX, -corner)] {
            for (y, dy) in [(frame.minY, corner), (frame.maxY, -corner)] {
                context.move(to: CGPoint(x: x, y: y + dy))
                context.addLine(to: CGPoint(x: x, y: y))
                context.addLine(to: CGPoint(x: x + dx, y: y))
            }
        }
        context.strokePath()

        let statusY = frame.maxY - unit * 0.047
        let dotX = frame.minX + unit * 0.045
        let fontSize = unit * 0.039
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let label = NSAttributedString(string: "REC", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ])
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: dotX + unit * 0.023, y: statusY - CTFontGetCapHeight(font) / 2)
        CTLineDraw(CTLineCreateWithAttributedString(label), context)
        if recordingLight {
            context.setFillColor(CGColor(red: 1, green: 0.16, blue: 0.19, alpha: 1))
            let radius = unit * 0.01
            context.fillEllipse(in: CGRect(x: dotX - radius, y: statusY - radius, width: radius * 2, height: radius * 2))
        }

        // A small battery mark completes the familiar viewfinder silhouette.
        let battery = CGRect(x: frame.maxX - unit * 0.115, y: statusY - unit * 0.014,
            width: unit * 0.07, height: unit * 0.028)
        context.stroke(battery)
        context.setFillColor(CGColor(gray: 1, alpha: 0.95))
        context.fill(CGRect(x: battery.maxX, y: statusY - unit * 0.006, width: unit * 0.006, height: unit * 0.012))
        context.fill(battery.insetBy(dx: unit * 0.006, dy: unit * 0.006))

        guard let cgImage = context.makeImage() else { return nil }
        let image = CIImage(cgImage: cgImage)
        overlayCache.setObject(image, forKey: key, cost: context.bytesPerRow * height)
        return image
    }
}
