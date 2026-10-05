import Foundation

public enum SpeechCaptionStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case vlog, travel, social
    public var id: String { rawValue }
    public var templateID: String { "caption.\(rawValue).v1" }
    public var localizedTitle: String {
        switch self { case .vlog: return "Влог"; case .travel: return "Путешествие"; case .social: return "Соцсети" }
    }
    public var detail: String {
        switch self {
        case .vlog: return "Крупный жирный текст с тёмной подложкой"
        case .travel: return "Средний размер, мягкая подложка и плавное появление"
        case .social: return "Крупный текст, активное появление и подсветка слов"
        }
    }
}

/// Review candidates available in the title catalog. None changes the
/// automatic speech-caption default before the user chooses a treatment.
enum SpeechCaptionStyleCandidates {
    static let templates: [TitleTemplateDefinition] = [
        make(id: "cinematic", name: "Киношный", size: 42, weight: 0.48,
             color: "#F5F2EC", panel: nil, panelOpacity: 0,
             entrance: .init(duration: 0.16), exit: .init(duration: 0.12)),
        make(id: "vlog", name: "Влог", size: 62, weight: 0.84,
             color: "#FFFFFF", panel: "#111318", panelOpacity: 0.82,
             entrance: .init(duration: 0.13, translateY: 0.008, scaleFrom: 0.98),
             exit: .init(duration: 0.10)),
        make(id: "travel", name: "Путешествие", size: 50, weight: 0.58,
             color: "#FFF6E5", panel: "#253D3B", panelOpacity: 0.52,
             entrance: .init(duration: 0.22, translateY: 0.004),
             exit: .init(duration: 0.18)),
        make(id: "social", name: "Соцсети", size: 72, weight: 0.92,
             color: "#FFFFFF", panel: "#111220", panelOpacity: 0.68,
             entrance: .init(duration: 0.18, translateY: 0.024, scaleFrom: 0.80, rotationFrom: -1.5),
             exit: .init(duration: 0.10, translateY: -0.012, scaleFrom: 0.94),
             highlight: true)
    ]

    private static func make(
        id: String, name: String, size: Double, weight: Double,
        color: String, panel: String?, panelOpacity: Double,
        entrance: TitleMotionPhase, exit: TitleMotionPhase, highlight: Bool = false
    ) -> TitleTemplateDefinition {
        let typography = TitleTemplateTypography(
            fontFamily: "Avenir Next", fontSize: size, fontWeight: weight,
            textColorHex: color, lineSpacing: 1.08
        )
        let frame = TitleNormalizedRect(x: 0.04, y: 0.755, width: 0.92, height: 0.14)
        var elements: [TitleTemplateElement] = []
        if let panel {
            let panelFrame = TitleNormalizedRect(x: 0.01, y: 0.752, width: 0.98, height: 0.146)
            elements.append(TitleTemplateElement(
                id: "caption-bg", kind: .roundedRectangle, frame: panelFrame,
                portraitFrame: panelFrame, fillColorHex: panel, opacity: panelOpacity,
                cornerRadius: id == "travel" ? 24 : 14
            ))
        }
        var text = TitleTemplateElement(
            id: "primary", kind: .text, content: highlight ? .activeCaption : .primaryText,
            frame: frame, portraitFrame: frame, typography: typography
        )
        text.portraitFontSize = size
        text.portraitMaxLines = 2
        elements.append(text)
        return TitleTemplateDefinition(
            id: "caption.\(id).v1", name: name, category: .captions,
            kind: highlight ? .wordLevelCaptions : .automaticSubtitles,
            preview: .init(primaryText: "Дорога начинается здесь"), duration: 2.8,
            typography: typography, layout: .init(elements: elements),
            animation: .init(animationIn: entrance, animationHold: .init(cycles: 0), animationOut: exit),
            safeArea: .init(horizontal: 0.08, vertical: 0.06, portraitHorizontal: 0.07, portraitVertical: 0.065),
            textConstraints: .init(maxCharacters: 92, maxLines: 2, maxWidth: 0.92, maxHeight: 0.14, minFontScale: 0.48),
            styleAnchor: frame
        )
    }
}
