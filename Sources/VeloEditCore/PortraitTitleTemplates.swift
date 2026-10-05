import Foundation

extension TitleTemplateRegistry {
    /// Authored compositions share a coordinate system: panels, accents and
    /// text move together. Independent widening moved accent bars into glyphs.
    static func portraitLayout(_ source: TitleTemplateDefinition) -> TitleTemplateDefinition {
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> TitleNormalizedRect {
            .init(x: x, y: y, width: w, height: h)
        }
        let frames: [String: TitleNormalizedRect]
        switch source.id {
        case "title.minimal-clean.v1": frames = [
            "primary": rect(0.06, 0.32, 0.88, 0.22), "secondary": rect(0.08, 0.59, 0.84, 0.08),
            "hairline": rect(0.28, 0.72, 0.44, 0.004)]
        case "title.cinematic.v1": frames = [
            "top-rule": rect(0.18, 0.26, 0.64, 0.003), "primary": rect(0.04, 0.32, 0.92, 0.25),
            "secondary": rect(0.08, 0.63, 0.84, 0.08), "bottom-rule": rect(0.34, 0.77, 0.32, 0.003)]
        case "title.modern.v1": frames = [
            "panel": rect(0.015, 0.30, 0.97, 0.34), "accent": rect(0.015, 0.30, 0.014, 0.34),
            "primary": rect(0.09, 0.335, 0.82, 0.18), "secondary": rect(0.09, 0.545, 0.82, 0.065)]
        case "title.bold.v1": frames = [
            "shadow": rect(0.05, 0.35, 0.93, 0.25), "banner": rect(0.02, 0.325, 0.93, 0.25),
            "primary": rect(0.08, 0.35, 0.81, 0.20), "secondary": rect(0.08, 0.63, 0.81, 0.08)]
        case "title.elegant.v1": frames = [
            "frame": rect(0.025, 0.23, 0.95, 0.57), "primary": rect(0.10, 0.33, 0.80, 0.24),
            "ornament": rect(0.493, 0.61, 0.014, 0.008), "secondary": rect(0.10, 0.66, 0.80, 0.08)]
        case "title.dynamic.v1": frames = [
            "accent": rect(0.40, 0.27, 0.20, 0.004), "primary": rect(0.04, 0.34, 0.92, 0.25),
            "secondary": rect(0.06, 0.65, 0.88, 0.08)]
        case "title.travel.v1": frames = [
            "sun": rect(0.73, 0.16, 0.17, 0.096), "primary": rect(0.07, 0.33, 0.86, 0.23),
            "secondary": rect(0.07, 0.62, 0.86, 0.08), "route": rect(0.07, 0.77, 0.78, 0.004),
            "marker": rect(0.83, 0.76, 0.035, 0.02)]
        case "title.chapter.v1": frames = [
            "number": rect(0.07, 0.18, 0.86, 0.15), "primary": rect(0.07, 0.40, 0.86, 0.23),
            "secondary": rect(0.07, 0.69, 0.86, 0.08)]
        case "title.location.v1": frames = [
            "pin-outer": rect(0.015, 0.68, 0.06, 0.034), "pin-inner": rect(0.03, 0.6885, 0.03, 0.017),
            "primary": rect(0.11, 0.635, 0.86, 0.11), "secondary": rect(0.11, 0.78, 0.86, 0.07)]
        case "title.lower-third.v1": frames = [
            "panel": rect(0.015, 0.66, 0.97, 0.23), "accent": rect(0.015, 0.66, 0.014, 0.23),
            "primary": rect(0.075, 0.685, 0.85, 0.105), "secondary": rect(0.075, 0.815, 0.85, 0.055)]
        case "title.date.v1": frames = [
            "bracket-top": rect(0.52, 0.065, 0.43, 0.003), "primary": rect(0.21, 0.09, 0.74, 0.08),
            "secondary": rect(0.21, 0.195, 0.74, 0.055)]
        case "title.end-card.v1": frames = [
            "background": rect(0, 0, 1, 1), "rule": rect(0.42, 0.25, 0.16, 0.004),
            "primary": rect(0.06, 0.34, 0.88, 0.23), "secondary": rect(0.06, 0.62, 0.88, 0.08),
            "cta": rect(0.08, 0.78, 0.84, 0.08)]
        case "caption.clean.v1": frames = [
            "caption-bg": rect(0.015, 0.735, 0.97, 0.16), "primary": rect(0.075, 0.757, 0.85, 0.116)]
        case "caption.word-focus.v1": frames = [
            "caption-bg": rect(0.015, 0.724, 0.97, 0.18), "accent": rect(0.015, 0.724, 0.012, 0.18),
            "primary": rect(0.075, 0.749, 0.85, 0.13)]
        default: return source
        }
        var result = source
        result.layout.elements = source.layout.elements.map { original in
            var element = original
            element.portraitFrame = frames[element.id]
            if element.kind == .text {
                switch element.content {
                case .primaryText, .activeCaption:
                    element.portraitMaxLines = source.category == .lowerThirds || source.category == .dateTime ? 2 : 3
                case .chapterNumber: element.portraitMaxLines = 1
                default:
                    element.portraitFontSize = max(36, element.typography?.fontSize ?? 36)
                    element.portraitMaxLines = 2
                }
            }
            return element
        }
        return result
    }
}
