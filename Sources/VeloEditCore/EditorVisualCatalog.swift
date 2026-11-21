import Foundation

/// Both speech and the model can call a look a “filter” even when the editor
/// implements it as an effect layer. A transition always refers to a cut.
public enum EditorVisualCatalog {
    public enum Kind { case filter, libraryEffect, clipEffect, transition }

    private static func key(_ name: String) -> String {
        let text = name.lowercased().replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: CharacterSet(charactersIn: " «»\"“”"))
            .replacingOccurrences(of: #"[-_\s]+"#, with: " ", options: .regularExpression)
        // These endings cover common case changes in catalog names such as
        // «пикселизацию», «хроматической аберрации» and «мягкую виньетку».
        return text.replacingOccurrences(of: #"аци(?:я|ю|и|ей)\b"#, with: "ация", options: .regularExpression)
            .replacingOccurrences(of: #"к(?:а|у|и|ой)\b"#, with: "ка", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=[а-я])(?:ая|ую|ой|ые|ый)\b"#, with: "ый", options: .regularExpression)
    }

    private static func index<T: CaseIterable & RawRepresentable>(
        _ type: T.Type, title: KeyPath<T, String>, aliases: [String: T] = [:]
    ) -> [String: T] where T.RawValue == String {
        var result: [String: T] = [:]
        for value in T.allCases {
            result[key(value.rawValue)] = value
            result[key(value[keyPath: title])] = value
        }
        for (name, value) in aliases { result[key(name)] = value }
        return result
    }

    private static let filters = index(VideoFilter.self, title: \.localizedTitle, aliases: [
        "монохром": .monochrome, "чб": .monochrome, "ч/б": .monochrome, "без цвета": .monochrome,
        "черно-белыми": .monochrome, "черно-белым": .monochrome, "черно-белое": .monochrome, "черно-белой": .monochrome,
        "сепию": .sepia, "сепии": .sepia
    ])
    private static let library = index(TimelineEffectType.self, title: \.localizedTitle, aliases: [
        "камеры": .videoCamera, "камера": .videoCamera, "видеокамеры": .videoCamera,
        "camera": .videoCamera, "rec": .videoCamera, "видоискатель": .videoCamera, "видоискателя": .videoCamera,
        "глитч": .glitch, "зум": .zoom, "дрожание камеры": .shake, "ручной камеры": .handheld,
        "дрейфа камеры": .cameraDrift, "рыбьего глаза": .fisheye, "пленочного зерна": .filmGrain,
        "пикселями": .pixelate, "в пикселях": .pixelate, "крупными пикселями": .pixelate,
        "пиксельный": .pixelate,
        "пикселизация изображения": .pixelate, "pixelation": .pixelate, "pixelated": .pixelate,
        "мозаика": .pixelate, "винтаж": .vintage, "винтажный": .vintage, "ретро": .vintage, "блюр": .blur,
        "как на старой видеокассете": .vhsDistortion, "как с видеокассеты": .vhsDistortion,
        "как на VHS": .vhsDistortion, "кинополосы": .letterbox, "черные полосы сверху и снизу": .letterbox,
        "размытый фон": .backgroundBlur, "дымка": .fogHaze
    ])
    private static let motion = index(ClipEffect.self, title: \.localizedTitle)
    private static let transitions = index(TransitionStyle.self, title: \.localizedTitle, aliases: [
        "кроссфейд": .crossDissolve, "crossfade": .crossDissolve, "глитч": .glitch,
        "пиксельный": .pixelate, "мозаика": .pixelate
    ])
    private static let lookNames = Set(filters.keys).union(library.keys).union(motion.keys)

    public static func command(named name: String, kind: Kind, target: EditorCommandTarget) -> EditorCommand? {
        let name = key(name)
        if let command = exact(name, kind: kind, target: target) { return command }
        // Repair one typo only in a distinctive, single-word name. An unknown
        // qualifier (a face, a duration, an exception) must reach the planner.
        guard (7...32).contains(name.count), name.allSatisfy(\.isLetter) else { return nil }
        let names = kind == .transition ? Set(transitions.keys) : lookNames
        let matches = Set(names.compactMap { candidate -> EditorCommand? in
            guard candidate.allSatisfy(\.isLetter), oneTypo(name, candidate) else { return nil }
            return exact(candidate, kind: kind, target: target)
        })
        return matches.count == 1 ? matches.first : nil
    }

    private static func oneTypo(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1 else { return false }
        if a.count == b.count {
            let differences = a.indices.filter { a[$0] != b[$0] }
            if differences.count == 1 { return true }
            guard differences.count == 2 else { return false }
            let i = differences[0], j = differences[1]
            return j == i + 1 && a[i] == b[j] && a[j] == b[i]
        }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        let i = short.indices.first { short[$0] != long[$0] } ?? short.count
        return short[i...].elementsEqual(long[(i + 1)...])
    }

    private static func exact(_ name: String, kind: Kind, target: EditorCommandTarget) -> EditorCommand? {
        switch kind {
        case .transition:
            return transitions[name].map { .setTransition($0, target) }
        case .filter:
            if let filter = filters[name] { return .setFilter(filter, target) }
        case .clipEffect:
            if let effect = motion[name] { return .setEffect(effect, target) }
        case .libraryEffect: break
        }
        if let effect = library[name] { return .addLibraryEffect(effect, target) }
        if let effect = motion[name] { return .setEffect(effect, target) }
        guard let filter = filters[name], filter != .none else { return nil }
        return .setFilter(filter, target)
    }
}
