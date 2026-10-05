import Foundation

public enum FilmDurationMode: String, Codable, Sendable { case automatic, approximate, exact, range, minimum, maximum }

public struct FilmDurationRequirement: Codable, Equatable, Hashable, Sendable {
    public var mode: FilmDurationMode
    public var target: Double?
    public var lowerBound: Double?
    public var upperBound: Double?
    public var sourcePhrase: String? = nil

    public static func parse(prompt: String, explicitSeconds: Double? = nil, mode: FilmDurationMode? = nil) -> Self {
        var text = prompt.lowercased().replacingOccurrences(of: ",", with: ".")
        for (word, value) in [("одну", "1"), ("одна", "1"), ("одной", "1"), ("две", "2"), ("два", "2"), ("двух", "2"), ("три", "3"), ("четыре", "4"), ("пять", "5"), ("шесть", "6"), ("семь", "7"), ("восемь", "8"), ("девять", "9"), ("десять", "10")] {
            text = text.replacingOccurrences(of: "(?<![\\p{L}])" + word + "(?![\\p{L}])", with: value, options: .regularExpression)
        }
        let number = #"\d+(?:\.\d+)?"#
        let minute = #"(?:мин(?:ут[ауы]?)?|min(?:utes?)?)(?![\p{L}])"#
        let second = #"(?:сек(?:унд[ауы]?)?|sec(?:onds?)?)(?![\p{L}])"#
        let clock = #"\d{1,3}:[0-5]\d"#
        let duration = "(?:" + clock + "|" + number + "\\s*" + minute + "(?:\\s*" + number + "\\s*" + second + ")?|" + number + "\\s*" + second + ")"
        func matches(_ pattern: String, _ value: String) -> [NSTextCheckingResult] {
            (try? NSRegularExpression(pattern: pattern).matches(in: value, range: NSRange(value.startIndex..., in: value))) ?? []
        }
        func part(_ match: NSTextCheckingResult, _ i: Int, _ value: String) -> String {
            Range(match.range(at: i), in: value).map { String(value[$0]) } ?? ""
        }
        func seconds(_ value: String) -> Double? {
            if value.contains(":"), let m = matches("^(\\d+):([0-5]\\d)$", value).first {
                return (Double(part(m, 1, value)) ?? 0) * 60 + (Double(part(m, 2, value)) ?? 0)
            }
            let mins = matches("(" + number + ")\\s*" + minute, value).first.map { (Double(part($0, 1, value)) ?? 0) * 60 } ?? 0
            let secs = matches("(" + number + ")\\s*" + second, value).first.map { Double(part($0, 1, value)) ?? 0 } ?? 0
            return mins + secs > 0 ? mins + secs : nil
        }
        var result: Self?
        // Split sentences without splitting decimal seconds. Scope is decided
        // for each clause; a title's duration cannot replace the film runtime.
        let clauses = text.replacingOccurrences(of: #"(?<!\d)\.|\.(?!\d)|[!?;\n]|\s+(?:а|но|and|but)\s+"#, with: "\n", options: .regularExpression).components(separatedBy: "\n")
        for clause in clauses {
            let local = ["титр", "сцен", "кадр", "эпизод", "title", "caption", "scene", "shot"]
            let global = ["фильм", "ролик", "видео", "общая длительность", "film", "movie", "video"]
            guard !local.contains(where: clause.contains) || global.contains(where: clause.contains) else { continue }
            let rangePattern = "(?:от\\s*)?(" + duration + ")\\s*(?:–|-|до|to)\\s*(" + duration + ")"
            if let m = matches(rangePattern, clause).last, let low = seconds(part(m, 1, clause)), let high = seconds(part(m, 2, clause)), low <= high {
                result = Self(mode: .range, target: (low + high) / 2, lowerBound: low, upperBound: high, sourcePhrase: clause.trimmingCharacters(in: .whitespaces))
                continue
            }
            // Shared unit, e.g. «от 90 до 120 секунд».
            if let m = matches("(?:от\\s*)?(" + number + ")\\s*(?:–|-|до|to)\\s*(" + duration + ")", clause).last,
               let lowValue = Double(part(m, 1, clause)), let high = seconds(part(m, 2, clause)) {
                let highText = part(m, 2, clause)
                let low = lowValue * (matches(minute, highText).isEmpty ? 1 : 60)
                if low <= high { result = Self(mode: .range, target: (low + high) / 2, lowerBound: low, upperBound: high, sourcePhrase: clause); continue }
            }
            let scoped = matches(duration, clause).filter { match in
                let prefix = String((clause as NSString).substring(to: match.range.location))
                func last(_ words: [String]) -> Int {
                    words.compactMap { word in prefix.range(of: word, options: .backwards).map { prefix.distance(from: prefix.startIndex, to: $0.lowerBound) } }.max() ?? -1
                }
                return last(local) <= last(global)
            }
            guard let m = scoped.last, let value = seconds(part(m, 0, clause)), value > 0 else { continue }
            let prefix = String((clause as NSString).substring(to: m.range.location))
            let selectedMode: FilmDurationMode
            if ["не больше", "не более", "до ", "at most", "no more"].contains(where: prefix.contains) { selectedMode = .maximum }
            else if ["не меньше", "не менее", "at least", "no less"].contains(where: prefix.contains) { selectedMode = .minimum }
            else if ["около", "примерно", "приблизительно", "about", "around"].contains(where: prefix.contains) { selectedMode = .approximate }
            else { selectedMode = .exact }
            result = Self(mode: selectedMode, target: value,
                lowerBound: selectedMode == .minimum ? value : selectedMode == .approximate ? value * 0.95 : nil,
                upperBound: selectedMode == .maximum ? value : selectedMode == .approximate ? value * 1.05 : nil,
                sourcePhrase: clause.trimmingCharacters(in: .whitespaces))
        }
        if var result { result.sourcePhrase = prompt; return result }
        guard let value = explicitSeconds, value.isFinite, value > 0 else { return Self(mode: .automatic) }
        let chosen = mode == nil || mode == .automatic ? FilmDurationMode.exact : mode!
        return Self(mode: chosen, target: value, lowerBound: chosen == .minimum ? value : chosen == .approximate ? value * 0.95 : nil,
                    upperBound: chosen == .maximum ? value : chosen == .approximate ? value * 1.05 : nil)
    }

    public func accepts(duration: Double, frameRate: Double) -> Bool {
        guard duration.isFinite, duration > 0, frameRate.isFinite, frameRate > 0 else { return false }
        let frame = 1 / frameRate + 0.000_001
        switch mode {
        case .automatic: return true
        case .exact: return target.map { abs(duration - $0) <= frame } ?? false
        case .approximate: return duration >= (lowerBound ?? (target ?? .infinity) * 0.95) - 0.000_001 && duration <= (upperBound ?? (target ?? 0) * 1.05) + 0.000_001
        case .range: return duration >= (lowerBound ?? .infinity) - frame && duration <= (upperBound ?? 0) + frame
        case .minimum: return duration >= (lowerBound ?? target ?? .infinity) - frame
        case .maximum: return duration <= (upperBound ?? target ?? 0) + frame
        }
    }

    func validate(_ timeline: Timeline) throws {
        let duration = AutomaticFilmDurationPolicy.renderedDuration(of: timeline)
        guard accepts(duration: duration, frameRate: timeline.frameRate) else {
            throw AutonomousOperationError.verificationFailed("Сохранён фильм: длительность \(String(format: "%.2f", duration)) с пока не соответствует заданию \(String(format: "%.2f", target ?? 0)) с.")
        }
    }
}
