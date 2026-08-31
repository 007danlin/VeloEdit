import Foundation
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
        destination: URL
    ) async throws -> URL {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("veloedit-title-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        try Self.draw(text: text, style: style, width: width, height: height, destination: imageURL)
        return try await StillImageVideoGenerator().generate(
            imageURL: imageURL,
            duration: duration,
            width: width,
            height: height,
            frameRate: frameRate,
            destination: destination,
            // Motion JPEG has a software encoder in command-line and signed
            // app hosts, unlike H.264 on some macOS CLI environments.
            codec: .jpeg,
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
        let fontSize = CGFloat(style.fontSize) * min(CGFloat(width) / 1920, CGFloat(height) / 1080)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica Neue Bold" as CFString, max(18, fontSize), nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(style.textColorHex, fallback: CGColor(gray: 1, alpha: 1)),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let margin = CGFloat(width) * 0.10
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: string.length),
            nil,
            CGSize(width: CGFloat(width) - margin * 2, height: CGFloat(height) * 0.7),
            nil
        )
        let frameRect = CGRect(
            x: margin,
            y: max(CGFloat(height) * 0.15, (CGFloat(height) - suggested.height) / 2),
            width: CGFloat(width) - margin * 2,
            height: min(CGFloat(height) * 0.7, suggested.height + fontSize * 0.4)
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
