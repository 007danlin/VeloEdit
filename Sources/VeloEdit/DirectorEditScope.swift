import Foundation
import VeloEditCore

/// A scope may be sent by itself after the director asks where to apply an edit.
enum DirectorEditScope: Equatable {
    case wholeFilm
    case interval(ClosedRange<Double>)
    case invalidInterval
    case beginning, end, clip(Int)
    case firstSeconds(Double), lastSeconds(Double)

    func range(in timeline: Timeline, transitions: Bool) -> ClosedRange<Double>? {
        guard timeline.duration > 0 else { return nil }
        let primary = timeline.items.filter { $0.overlay == nil && $0.kind != .title }.sorted { $0.timelineStart < $1.timelineStart }
        let item: TimelineItem?
        switch self {
        case .wholeFilm: return 0...timeline.duration
        case .interval(let interval):
            guard interval.lowerBound < timeline.duration else { return nil }
            return interval.lowerBound...min(interval.upperBound, timeline.duration)
        case .firstSeconds(let seconds): return 0...min(timeline.duration, seconds)
        case .lastSeconds(let seconds): return max(0, timeline.duration - seconds)...timeline.duration
        case .beginning: item = transitions ? primary.dropFirst().first : primary.first
        case .end: item = primary.last
        case .clip(let number): item = primary.indices.contains(number - 1) ? primary[number - 1] : nil
        case .invalidInterval: return nil
        }
        return item.map { $0.timelineStart...($0.timelineStart + $0.timelineDuration) }
    }

    /// Accept a named topic only when the rest of the message is a complete
    /// scope or level. A fresh instruction such as «добавь эффект» stays an edit.
    static func namedCorrection(_ text: String) -> (category: String, qualifier: String)? {
        if let category = restoredCategory(text) { return (category, text) }
        let words = text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = words.firstMatch(of: #/^(?:(?:нет|а|тогда|давай)[, ]+)*(?:оставь |оставим |пусть )?(переходы|переход|громкость музыки|музыку|музыка|фильтр|эффекты|эффект|исходный звук)\s*[,—–-]?\s+(?:(?:оставь|оставим|оставь их|будут|будет|сделай) )?(.+)$/#) else { return nil }
        let qualifier = String(match.2)
        guard Self(qualifier) != nil || revisedPercent(qualifier) != nil else { return nil }
        let category: String
        switch match.1 {
        case "переходы", "переход": category = "transition"
        case "фильтр": category = "filter"
        case "эффекты", "эффект": category = "effect"
        case "исходный звук": category = "original-audio-volume"
        default: category = "music-volume"
        }
        return (category, qualifier)
    }

    static func restoredCategory(_ text: String) -> String? {
        let words = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        if words.range(of: #"^(?:нет,? )?(?:верни|восстанови) (?:(?:прежние|старые|исходные) переходы|переходы как (?:были|раньше))$"#, options: .regularExpression) != nil { return "transition" }
        if words.range(of: #"^(?:нет,? )?верни (?:прежнюю громкость музыки|громкость музыки как (?:была|раньше))$"#, options: .regularExpression) != nil { return "music-volume" }
        return nil
    }

    static func revisedPercent(_ text: String) -> String? {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = normalized.firstMatch(of: #/^(?:(?:нет|а|лучше|давай|тогда|всё-таки|все-таки)[, ]+)*(?:на )?(\d{1,3}(?:[.,]\d+)?)\s*(?:%|процент(?:а|ов)?)(?:[.!])?$/#),
              let percent = Double(match.1.replacingOccurrences(of: ",", with: ".")), (0...100).contains(percent) else { return nil }
        return String(match.1)
    }

    /// Accept a trailing interval on an instruction as well as a scope-only reply.
    static func splitInterval(from text: String) -> (instruction: String, scope: Self)? {
        guard let suffix = text.range(of: #"(?:^|[\s,])(?:(?:на интервале|на участке|в диапазоне)\s+)?(?:с\s+)?"# + Self.clock + #"\s*(?:[-–—]|до|по)\s*"# + Self.clock + #"[.!]?$"#,
                                      options: [.regularExpression, .caseInsensitive]) else { return nil }
        let instruction = text[..<suffix.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespacesAndNewlines))
        let interval = text[suffix].drop(while: { !$0.isNumber }).trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        guard !instruction.isEmpty, let scope = Self(interval) else { return nil }
        return (instruction, scope)
    }

    private static let clock = #"\d{1,3}:\d{2}(?::\d{2})?(?:[.,]\d{1,3})?"#

    init?(_ text: String) {
        let value = text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let qualifier = value.replacingOccurrences(of: #"^(?:(?:нет|лучше|давай|тогда|а|(?:я )?передумал[аи]?)[, ]+)*(?:(?:оставь|оставим)(?: (?:это|его|её|ее|их))? )?(?:только |лишь )?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".! "))
        switch qualifier {
        case "в конце", "в самом конце", "в финале", "на последнем стыке": self = .end; return
        case "в начале", "в самом начале", "на первом стыке": self = .beginning; return
        default: break
        }
        let ordinal = ["первом", "втором", "третьем", "четвертом", "пятом"]
        if let match = qualifier.firstMatch(of: #/^(?:на|во?) (первом|втором|третьем|четвертом|пятом|последнем)(?: (?:клипе|видео|фрагменте|плане|кадре))?$/#) {
            if match.1 == "последнем" { self = .end; return }
            guard let index = ordinal.firstIndex(of: String(match.1)) else { return nil }
            self = .clip(index + 1)
            return
        }
        if let match = qualifier.firstMatch(of: #/^(?:на |в )?(первы[ех]|последни[ех]) (\d+(?:[.,]\d+)?|две|три|четыре|пять) (?:секунд[а-я]*|с)$/#) {
            let number = String(match.2)
            let words: [String: Double] = ["две": 2, "три": 3, "четыре": 4, "пять": 5]
            guard let seconds = Double(number.replacingOccurrences(of: ",", with: ".")) ?? words[number],
                  seconds.isFinite, seconds > 0 else { return nil }
            self = match.1.hasPrefix("перв") ? .firstSeconds(seconds) : .lastSeconds(seconds)
            return
        }
        if qualifier.range(of: #"^(?:на весь (?:фильм|ролик|интервал видео)|на все видео(?: целиком)?|по всему (?:фильму|ролику|видео)|на все клипы)$"#,
                           options: .regularExpression) != nil {
            self = .wholeFilm
            return
        }
        let clock = "(" + Self.clock + ")"
        guard let match = try? NSRegularExpression(pattern: "^(?:с |на )?" + clock + #"\s*(?:[-–—]|до|по)\s*"# + clock + "$")
            .firstMatch(in: qualifier, range: NSRange(qualifier.startIndex..., in: qualifier)),
              let first = Range(match.range(at: 1), in: qualifier), let last = Range(match.range(at: 2), in: qualifier) else { return nil }
        func seconds(_ parts: Substring) -> Double? {
            let fields = parts.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
            guard fields.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
            return fields.reduce(0) { $0 * 60 + $1 }
        }
        if let start = seconds(qualifier[first]), let end = seconds(qualifier[last]), start < end {
            self = .interval(start...end)
        } else { self = .invalidInterval }
    }
}

extension EditorCommand {
    // Retarget settings, never replay an insertion, deletion, clip reorder or music search.
    var allowsScopeCorrection: Bool {
        switch self {
        case .setTransition, .setTransitionPattern, .lowerMusicVolume, .setMusicVolume, .setOriginalAudioVolume, .setAudioDucking,
             .setFilter, .setEffect, .addLibraryEffect, .setClipMuted, .setClipVolume, .setCrop, .setBrightness,
             .setContrast, .setSaturation, .setWarmth, .setOpacity, .setExposure, .setHighlights, .setShadows,
             .setGrain, .setBlur, .setStabilization, .setEQ, .setNoiseReduction: true
        default: false
        }
    }
}
