import CoreGraphics
import Foundation

/// Format information derived from the actual pixel dimensions of a video
/// frame. Layout decisions use the continuous aspect ratio; `orientation` is
/// descriptive and is not a switch between two hard-coded templates.
public enum VideoFrameOrientation: String, Codable, Hashable, Sendable {
    case landscape
    case square
    case portrait
}

public struct VideoFrameGeometry: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }

    public var aspectRatio: Double { Double(width) / Double(height) }

    public var orientation: VideoFrameOrientation {
        if abs(aspectRatio - 1) <= 0.03 { return .square }
        return aspectRatio > 1 ? .landscape : .portrait
    }

    /// Smooth influence used to reflow compositions between 16:9 and 9:16.
    /// Intermediate formats therefore receive intermediate layouts.
    public var portraitInfluence: Double {
        let landscapeThreshold = 1.35
        let portraitReference = 9.0 / 16.0
        return min(max(0, (landscapeThreshold - aspectRatio) / (landscapeThreshold - portraitReference)), 1)
    }
}

public struct AdaptiveTitleLayoutElement: Hashable, Sendable {
    public var id: String
    public var kind: TitleTemplateElementKind
    public var frame: CGRect
    public var maximumLines: Int
}

public struct AdaptiveTitleLayout: Hashable, Sendable {
    public var geometry: VideoFrameGeometry
    public var safeRect: CGRect
    public var elements: [AdaptiveTitleLayoutElement]

    public static func resolve(template: TitleTemplateDefinition, renderSize: CGSize) -> AdaptiveTitleLayout {
        let geometry = VideoFrameGeometry(
            width: Int(max(1, renderSize.width.rounded())),
            height: Int(max(1, renderSize.height.rounded()))
        )
        let bounds = CGRect(origin: .zero, size: renderSize)
        let safeRect = template.safeArea.rect(in: renderSize)
        let elements = template.layout.elements.map { element in
            let container = element.followsSafeArea ? safeRect : bounds
            return AdaptiveTitleLayoutElement(
                id: element.id,
                kind: element.kind,
                frame: adaptiveFrame(for: element, in: container, portraitInfluence: geometry.portraitInfluence),
                maximumLines: adaptiveLineCount(
                    base: template.textConstraints.maxLines,
                    element: element,
                    portraitInfluence: geometry.portraitInfluence
                )
            )
        }
        return AdaptiveTitleLayout(geometry: geometry, safeRect: safeRect, elements: elements)
    }

    public func element(id: String) -> AdaptiveTitleLayoutElement? {
        elements.first { $0.id == id }
    }

    public var typographyScale: CGFloat {
        let shortSide = CGFloat(min(geometry.width, geometry.height))
        let portraitBoost = 1 + CGFloat(geometry.portraitInfluence) * 0.16
        return shortSide / 1080 * portraitBoost
    }

    private static func adaptiveLineCount(
        base: Int,
        element: TitleTemplateElement,
        portraitInfluence: Double
    ) -> Int {
        guard element.kind == .text else { return base }
        let additional = Int(ceil(portraitInfluence * (element.content == .primaryText || element.content == .activeCaption ? 2 : 1)))
        return min(4, max(1, base + additional))
    }

    private static func adaptiveFrame(
        for element: TitleTemplateElement,
        in container: CGRect,
        portraitInfluence: Double
    ) -> CGRect {
        let original = element.frame
        let p = CGFloat(portraitInfluence)
        if let portrait = element.portraitFrame {
            func blend(_ a: Double, _ b: Double) -> Double { a + (b - a) * portraitInfluence }
            return TitleNormalizedRect(
                x: blend(original.x, portrait.x), y: blend(original.y, portrait.y),
                width: blend(original.width, portrait.width), height: blend(original.height, portrait.height)
            ).rect(in: container)
        }
        var width = CGFloat(original.width)
        var height = CGFloat(original.height)

        switch element.kind {
        case .text:
            width = min(0.94, width * (1 + 0.48 * p))
            let isPrimary = element.content == .primaryText || element.content == .activeCaption
            height = min(isPrimary ? 0.44 : 0.22, height * (1 + (isPrimary ? 0.68 : 0.38) * p))
        case .rectangle, .roundedRectangle:
            // Panels are layout containers and may reflow with their text.
            // Their corners and strokes still use uniform, short-side scaling.
            guard !(original.x == 0 && original.y == 0 && original.width == 1 && original.height == 1) else {
                return container
            }
            width = min(0.96, width * (1 + 0.40 * p))
            height = min(0.72, height * (1 + 0.22 * p))
        case .line:
            width = min(0.94, width * (1 + 0.28 * p))
        case .circle:
            let proposed = original.rect(in: container)
            let diameter = min(proposed.width, proposed.height)
            return CGRect(x: proposed.midX - diameter / 2, y: proposed.midY - diameter / 2, width: diameter, height: diameter)
        }

        let originalCenterX = CGFloat(original.x + original.width / 2)
        let centerX = originalCenterX + (0.5 - originalCenterX) * p * 0.28
        var x = centerX - width / 2
        var y = CGFloat(original.y)
        x = min(max(0, x), max(0, 1 - width))
        y = min(max(0, y), max(0, 1 - height))
        return TitleNormalizedRect(x: Double(x), y: Double(y), width: Double(width), height: Double(height)).rect(in: container)
    }
}
