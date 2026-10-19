import CoreText
import Foundation

public struct TitleFontFace: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var weight: Double
}

/// A verified family and a real installed face. Core Text performs fallback
/// on individual glyph runs (including composed emoji), never on the heading.
public enum TitleFontResolver {
    private static let descriptors = CTFontCollectionCreateMatchingFontDescriptors(
        CTFontCollectionCreateFromAvailableFonts(nil)) as? [CTFontDescriptor] ?? []

    public static let families: [String] = Array(Set(descriptors.compactMap {
        CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
    })).sorted()

    private static let faceCatalog: [String: [TitleFontFace]] = {
        var result: [String: [TitleFontFace]] = [:]
        for descriptor in descriptors {
            guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { continue }
            let font = CTFontCreateWithFontDescriptor(descriptor, 24, nil)
            let traits = CTFontGetSymbolicTraits(font)
            guard !traits.contains(.traitItalic), !traits.contains(.traitCondensed), !traits.contains(.traitExpanded) else { continue }
            let values = CTFontCopyTraits(font) as NSDictionary
            let ctWeight = (values[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            let weight = ctWeight < 0 ? max(0, 0.4 + ctWeight * 0.5) : min(1, 0.4 + ctWeight * 1.125)
            let face = TitleFontFace(id: name, name: CTFontCopyName(font, kCTFontSubFamilyNameKey) as String? ?? name, weight: weight)
            result[family.lowercased(), default: []].append(face)
            result[name.lowercased(), default: []].append(face)
        }
        return result.mapValues { $0.sorted { $0.weight == $1.weight ? $0.id < $1.id : $0.weight < $1.weight } }
    }()

    public static func faces(family: String) -> [TitleFontFace] {
        faceCatalog[family.lowercased()] ?? []
    }

    public static func font(family: String, size: CGFloat, weight: Double, version: Int? = nil) -> CTFont {
        let candidates = [family, "Avenir Next", "Helvetica Neue", "Arial"]
        for candidate in candidates {
            let base = CTFontCreateWithName(candidate as CFString, max(1, size), nil)
            let actualFamily = CTFontCopyFamilyName(base) as String
            let actualName = CTFontCopyPostScriptName(base) as String
            guard actualFamily.caseInsensitiveCompare(candidate) == .orderedSame
                || actualName.caseInsensitiveCompare(candidate) == .orderedSame else { continue }
            let available = faces(family: candidate)
            if (version ?? 1) >= 2,
               let face = available.min(by: { abs($0.weight - weight) < abs($1.weight - weight) }) {
                return CTFontCreateWithName(face.id as CFString, max(0.1, size), nil)
            }
            let bold: CTFontSymbolicTraits = weight >= 0.72 ? .traitBold : []
            return CTFontCreateCopyWithSymbolicTraits(base, max(1, size), nil, bold, bold) ?? base
        }
        return CTFontCreateUIFontForLanguage(.system, size, nil)!
    }

    public static func resolvedFace(style: TitleStyle) -> TitleFontFace {
        let font = font(family: style.effectiveFontFamily, size: 24,
                        weight: style.effectiveFontWeight, version: style.typographyVersion)
        return TitleFontFace(id: CTFontCopyPostScriptName(font) as String,
            name: CTFontCopyFullName(font) as String, weight: style.effectiveFontWeight)
    }

    public static func replacementFamily(style: TitleStyle) -> String? {
        let font = font(family: style.effectiveFontFamily, size: 24,
                        weight: style.effectiveFontWeight, version: style.typographyVersion)
        let family = CTFontCopyFamilyName(font) as String
        return family.caseInsensitiveCompare(style.effectiveFontFamily) == .orderedSame ? nil : family
    }
}
