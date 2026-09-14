import Foundation
import AVFoundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

public actor TitleCardVideoGenerator {
    public init() {}

    public func generate(
        text: String,
        style: TitleStyle,
        duration: Double,
        width: Int,
        height: Int,
        frameRate: Int32,
        destination: URL,
        codec: AVVideoCodecType = .h264
    ) async throws -> URL {
        let encodedWidth = max(2, width / 2 * 2)
        let encodedHeight = max(2, height / 2 * 2)
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("veloedit-title-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        try Self.draw(text: text, style: style, width: encodedWidth, height: encodedHeight, destination: imageURL)
        return try await StillImageVideoGenerator().generate(
            imageURL: imageURL,
            duration: duration,
            width: encodedWidth,
            height: encodedHeight,
            frameRate: frameRate,
            destination: destination,
            // StillImageVideoGenerator explicitly requests software H.264,
            // avoiding the host's failing hardware VideoToolbox path.
            codec: codec,
            // A title card is a static graphic. The still-image generator's
            // default Ken Burns motion is intended for photos, not titles.
            motion: nil
        )
    }

    private static func draw(text: String, style: TitleStyle, width: Int, height: Int, destination: URL) throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw DerivedMediaError.cannotCreateDestination }
        context.setFillColor(color(style.backgroundColorHex, fallback: CGColor(gray: 0.06, alpha: 1)))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var alignment: CTTextAlignment
        switch style.alignment {
        case .left: alignment = .left
        case .center: alignment = .center
        case .right: alignment = .right
        }
        let paragraph: CTParagraphStyle = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: pointer
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
        let geometry = VideoFrameGeometry(width: width, height: height)
        let shortSideScale = CGFloat(min(width, height)) / 1080
        let readabilityBoost = 1 + CGFloat(geometry.portraitInfluence) * 0.16
        let desiredFontSize = CGFloat(style.fontSize) * shortSideScale * readabilityBoost
        let minimumFontSize = max(12 * shortSideScale, desiredFontSize * 0.48)
        let horizontalMargin = CGFloat(width) * (0.08 + CGFloat(geometry.portraitInfluence) * 0.04)
        let verticalMargin = CGFloat(height) * (0.08 + CGFloat(geometry.portraitInfluence) * 0.04)
        let available = CGSize(
            width: max(1, CGFloat(width) - horizontalMargin * 2),
            height: max(1, CGFloat(height) - verticalMargin * 2)
        )
        let foreground = color(style.textColorHex, fallback: CGColor(gray: 1, alpha: 1))

        func fittedString(_ value: String, size: CGFloat) -> (NSAttributedString, CGSize) {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(style.effectiveFontFamily as CFString, max(1, size), nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
            ]
            let string = NSAttributedString(string: value, attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: string.length),
                nil,
                CGSize(width: available.width, height: .greatestFiniteMagnitude),
                nil
            )
            return (string, suggested)
        }

        var fontSize = desiredFontSize
        var fitted = fittedString(text, size: fontSize)
        while fitted.1.height > available.height, fontSize > minimumFontSize + 0.1 {
            fontSize = max(minimumFontSize, fontSize * 0.91)
            fitted = fittedString(text, size: fontSize)
        }
        var visibleText = text
        while fitted.1.height > available.height, visibleText.count > 1 {
            visibleText.removeLast()
            fitted = fittedString(visibleText.trimmingCharacters(in: .whitespacesAndNewlines) + "…", size: minimumFontSize)
        }
        let string = fitted.0
        let suggested = fitted.1
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let frameRect = CGRect(
            x: horizontalMargin,
            y: max(verticalMargin, (CGFloat(height) - suggested.height) / 2),
            width: available.width,
            height: min(available.height, suggested.height + fontSize * 0.4)
        )
        let path = CGMutablePath()
        path.addRect(frameRect)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: string.length), path, nil)
        CTFrameDraw(frame, context)

        guard let image = context.makeImage(),
              let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw DerivedMediaError.cannotCreateDestination
        }
        CGImageDestinationAddImage(destinationRef, image, nil)
        guard CGImageDestinationFinalize(destinationRef) else { throw DerivedMediaError.cannotCreateDestination }
    }

    private static func color(_ hex: String, fallback: CGColor) -> CGColor {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let number = Int(value, radix: 16) else { return fallback }
        return CGColor(
            red: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
    }
}
