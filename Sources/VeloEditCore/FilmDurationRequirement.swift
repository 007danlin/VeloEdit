import Foundation

public enum FilmDurationMode: String, Codable, Sendable { case automatic, approximate, exact, range }

public struct FilmDurationRequirement: Codable, Equatable, Sendable {
    public var mode: FilmDurationMode
    public var target: Double?
    public var lowerBound: Double?
    public var upperBound: Double?

    public static func parse(prompt: String, explicitSeconds: Double? = nil, mode: FilmDurationMode? = nil) -> Self {
        var text = prompt.lowercased().replacingOccurrences(of: ",", with: ".")
        for (word, value) in [("одну", "1"), ("одна", "1"), ("две", "2"), ("два", "2"), ("три", "3"), ("четыре", "4"), ("пять", "5"), ("шесть", "6"), ("семь", "7"), ("восемь", "8"), ("девять", "9"), ("десять", "10")] {
            text = text.replacingOccurrences(of: "(?<![\\p{L}])" + word + "(?![\\p{L}])", with: value, options: .regularExpression)
        }
        let unit = "(мин(?:ут[ауы]?)?|min(?:utes?)?|сек(?:унд[ауы]?)?|sec(?:onds?)?)"
        if let expression = try? NSRegularExpression(pattern: "(?:от\\s*)?(\\d+(?:\\.\\d+)?)\\s*(?:–|-|до)\\s*(\\d+(?:\\.\\d+)?)\\s*" + unit),
           let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let first = Range(match.range(at: 1), in: text), let last = Range(match.range(at: 2), in: text), let units = Range(match.range(at: 3), in: text),
           let low = Double(text[first]), let high = Double(text[last]), low <= high {
            let multiplier = text[units].hasPrefix("м") || text[units].hasPrefix("min") ? 60.0 : 1.0
            return Self(mode: .range, target: (low + high) * multiplier / 2, lowerBound: low * multiplier, upperBound: high * multiplier)
        }
        var seconds: Double?
        if let expression = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*" + unit),
           let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let number = Range(match.range(at: 1), in: text), let units = Range(match.range(at: 2), in: text), let value = Double(text[number]) {
            seconds = value * (text[units].hasPrefix("м") || text[units].hasPrefix("min") ? 60 : 1)
        }
        seconds = seconds ?? explicitSeconds
        guard let seconds, seconds.isFinite, seconds > 0 else { return Self(mode: .automatic) }
        let approximate = ["около", "примерно", "приблизительно", "about", "around"].contains { text.contains($0) }
        return Self(mode: approximate || mode == .approximate ? .approximate : .exact, target: seconds)
    }

    public func accepts(duration: Double, frameRate: Double) -> Bool {
        guard duration.isFinite, duration > 0, frameRate.isFinite, frameRate > 0 else { return false }
        let frame = 1 / frameRate + 0.000_001
        switch mode {
        case .automatic: return true
        case .exact: return target.map { abs(duration - $0) <= frame } ?? false
        case .approximate: return target.map { abs(duration - $0) <= $0 * 0.05 + 0.000_001 } ?? false
        case .range: return duration >= (lowerBound ?? .infinity) - frame && duration <= (upperBound ?? 0) + frame
        }
    }

    func validate(_ timeline: Timeline) throws {
        let duration = AutomaticFilmDurationPolicy.renderedDuration(of: timeline)
        guard accepts(duration: duration, frameRate: timeline.frameRate) else {
            throw AutonomousOperationError.verificationFailed("Сохранён черновик: длительность \(String(format: "%.2f", duration)) с пока не соответствует заданию \(String(format: "%.2f", target ?? 0)) с.")
        }
    }
}
