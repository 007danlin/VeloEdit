import Foundation

/// A scope may be sent by itself after the director asks where to apply an edit.
enum DirectorEditScope: Equatable {
    case wholeFilm
    case interval(ClosedRange<Double>)
    case invalidInterval

    /// Accept a trailing interval on an instruction as well as a scope-only reply.
    static func splitInterval(from text: String) -> (instruction: String, scope: Self)? {
        guard let suffix = text.range(of: #"(?:^|[\s,])(?:(?:на интервале|на участке|в диапазоне)\s+)?(?:с\s+)?\d{1,3}:\d{2}(?::\d{2})?\s*(?:[-–—]|до|по)\s*\d{1,3}:\d{2}(?::\d{2})?[.!]?$"#,
                                      options: [.regularExpression, .caseInsensitive]) else { return nil }
        let instruction = text[..<suffix.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespacesAndNewlines))
        let interval = text[suffix].drop(while: { !$0.isNumber }).trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        guard !instruction.isEmpty, let scope = Self(interval) else { return nil }
        return (instruction, scope)
    }

    init?(_ text: String) {
        let value = text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^(?:на весь (?:фильм|ролик|интервал видео)|на все видео(?: целиком)?|по всему (?:фильму|ролику|видео)|на все клипы)[.!]?$"#,
                       options: .regularExpression) != nil {
            self = .wholeFilm
            return
        }
        let clock = #"(\d{1,3}:\d{2}(?::\d{2})?)"#
        guard let match = try? NSRegularExpression(pattern: "^(?:с |на )?" + clock + #"\s*(?:[-–—]|до|по)\s*"# + clock + "$")
            .firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let first = Range(match.range(at: 1), in: value), let last = Range(match.range(at: 2), in: value) else { return nil }
        func seconds(_ parts: Substring) -> Double? {
            let fields = parts.split(separator: ":").compactMap { Int($0) }
            guard fields.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
            return Double(fields.reduce(0) { $0 * 60 + $1 })
        }
        if let start = seconds(value[first]), let end = seconds(value[last]), start < end {
            self = .interval(start...end)
        } else { self = .invalidInterval }
    }
}
