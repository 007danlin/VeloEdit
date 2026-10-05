import Foundation

public struct SpeechCaptionAnchor: Codable, Hashable, Sendable {
    public var key: String
    public var assetID: UUID
    public var sourceStart: Double
    public var sourceEnd: Double
    public var words: [TranscriptWord]
    public var hasManualTiming: Bool?
}

public enum SpeechTimeMap {
    /// Inverts the same piecewise speed map used by playback and telemetry.
    public static func timelineTime(sourceTime: Double, item: TimelineItem) -> Double? {
        guard !item.isReversed, !item.isFreezeFrame, sourceTime >= item.sourceStart - 0.001,
              sourceTime <= item.sourceStart + item.sourceDuration + 0.001 else { return nil }
        var lo = item.timelineStart; var hi = lo + item.timelineDuration
        for _ in 0..<48 {
            let mid = (lo + hi) / 2
            if item.sourceTime(atTimelineTime: mid) < sourceTime { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
    public static func playbackStart(itemID: UUID, timeline: Timeline) -> Double? {
        var cursor = 0.0; var previous: TimelineItem?
        for item in TimelineTiming.retimed(timeline.items) where item.overlay == nil {
            let start = cursor - TimelineTiming.transitionOverlap(incoming: item, previous: previous, transitionItems: timeline.effectiveTransitionItems)
            if item.id == itemID { return start }
            cursor = start + TimelineTiming.compositionTime(item.timelineDuration).seconds; previous = item
        }
        return nil
    }
    public static func playbackRange(anchor: SpeechCaptionAnchor, item: TimelineItem, timeline: Timeline) -> ClosedRange<Double>? {
        guard let a = timelineTime(sourceTime: anchor.sourceStart, item: item),
              let b = timelineTime(sourceTime: anchor.sourceEnd, item: item), b > a,
              let start = playbackStart(itemID: item.id, timeline: timeline) else { return nil }
        return (start + a - item.timelineStart)...(start + b - item.timelineStart)
    }
}

public enum SpeechSubtitleBuilder {
    public static func applying(to source: Timeline, records: [SpeechSourceRecord], enabled: Bool, allowMuted: Bool = false, previous: Timeline? = nil, style: SpeechCaptionStyle? = nil) -> Timeline {
        var result = source
        let existing = (previous ?? source).effectiveTitleItems.filter { $0.speechAnchor != nil } + ((previous ?? source).speechCaptionArchive ?? [])
        let suppressed = Set((previous ?? source).suppressedSpeechCaptionKeys ?? [])
        result.suppressedSpeechCaptionKeys = Array(suppressed).sorted()
        var titles = source.effectiveTitleItems.filter { $0.speechAnchor == nil }
        guard enabled else { result.speechCaptionArchive = existing; result.titleItems = titles; return result }
        result.speechCaptionArchive = nil
        let lineLimit = source.height > source.width ? 30 : 42
        for item in source.items where item.overlay == nil && item.kind == .video && !item.isReversed && !item.isFreezeFrame {
            guard let assetID = item.assetID, let transcript = records.first(where: { $0.assetID == assetID })?.transcript,
                  allowMuted || (!item.effectiveAudioAdjustments.muted && item.effectiveAudioAdjustments.effectiveVolume > 0 && source.effectiveOriginalAudioVolume > 0) else { continue }
            for sentence in transcript.sentences {
                let words = transcript.words.filter { $0.startTime >= sentence.startTime - 0.02 && $0.endTime <= sentence.endTime + 0.02 && $0.duration > 0 }
                let groups: [[TranscriptWord]] = groups(words, maximumCharacters: 60)
                if groups.isEmpty {
                    // Phrase timing is evidence; synthetic per-word timing is not.
                    guard sentence.startTime >= item.sourceStart, sentence.endTime <= item.sourceStart + item.sourceDuration else { continue }
                    append(text: sentence.text, start: sentence.startTime, end: sentence.endTime, words: [], assetID: assetID, item: item, source: source, existing: existing, suppressed: suppressed, limit: lineLimit, titles: &titles)
                } else {
                    for group in groups {
                        let kept = group.filter { $0.startTime >= item.sourceStart - 0.001 && $0.endTime <= item.sourceStart + item.sourceDuration + 0.001 }
                        guard let first = kept.first, let last = kept.last else { continue }
                        append(text: kept.map(\.text).joined(separator: " "), start: first.startTime, end: last.endTime, words: kept, assetID: assetID, item: item, source: source, existing: existing, suppressed: suppressed, limit: lineLimit, titles: &titles)
                    }
                }
            }
        }
        if let style, let template = TitleTemplateRegistry.template(id: style.templateID) {
            titles = titles.map { title in
                guard title.speechAnchor != nil, title.userEdited != true else { return title }
                var value = title
                value.templateID = template.id; value.kind = template.kind; value.style = template.defaultStyle
                value.activeWordHighlighting = template.kind == .wordLevelCaptions
                if let item = source.items.first(where: { $0.id == value.targetClipID }) {
                    value.words = measuredCaptionWords(for: value, item: item)
                }
                return value
            }
        }
        result.titleItems = titles
        return result
    }
    private static func groups(_ words: [TranscriptWord], maximumCharacters: Int) -> [[TranscriptWord]] {
        guard !words.isEmpty else { return [] }
        let limit = maximumCharacters / 2
        var cost = [Double](repeating: .infinity, count: words.count + 1)
        var next = [Int](repeating: words.count, count: words.count)
        cost[words.count] = 0
        for i in words.indices.reversed() {
            for j in (i + 1)...words.count {
                let group = Array(words[i..<j])
                let text = group.map(\.text).joined(separator: " ")
                let duration = max(0.01, group.last!.endTime - group[0].startTime)
                let lines = wrapped(text, limit: limit).split(separator: "\n")
                if j > i + 1 && (duration > 6 || text.count > maximumCharacters || lines.contains(where: { $0.count > limit })) { break }
                if j > i + 1 && words[j - 1].startTime - words[j - 2].endTime > 0.7 { break }
                let short = max(0, 0.8 - duration) * 8
                let speed = max(0, Double(text.count) / duration - 20) * 0.03
                let orphan = group.count == 1 && words.count > 1 ? 2.0 : 0
                let value = 1 + short + speed + orphan + cost[j]
                if value < cost[i] { cost[i] = value; next[i] = j }
            }
        }
        var result: [[TranscriptWord]] = []; var i = 0
        while i < words.count { let j = max(i + 1, next[i]); result.append(Array(words[i..<j])); i = j }
        return result
    }
    private static func append(text: String, start: Double, end: Double, words: [TranscriptWord], assetID: UUID, item: TimelineItem, source: Timeline, existing: [TitleTimelineItem], suppressed: Set<String>, limit: Int, titles: inout [TitleTimelineItem]) {
        guard end > start else { return }
        let key = "speech-v1|\(assetID)|\(Int((start * 1000).rounded()))|\(Int((end * 1000).rounded()))"
        guard !suppressed.contains(key) else { return }
        let previous = existing.first { $0.speechAnchor?.key == key }
        let anchor = previous?.speechAnchor?.hasManualTiming == true ? previous!.speechAnchor! : SpeechCaptionAnchor(key: key, assetID: assetID, sourceStart: start, sourceEnd: end, words: words)
        guard let a = SpeechTimeMap.timelineTime(sourceTime: anchor.sourceStart, item: item), let b = SpeechTimeMap.timelineTime(sourceTime: anchor.sourceEnd, item: item) else { return }
        var title = previous ?? TitleTimelineItem(kind: .automaticSubtitles, templateID: "caption.clean.v1", text: wrapped(text, limit: limit), startTime: a, duration: b - a, track: 2,
            style: TitleStyle(fontSize: source.height > source.width ? 54 : 48, textColorHex: "#FFFFFF", backgroundColorHex: "#111111", fontWeight: 0.65, yPosition: source.height > source.width ? 0.73 : 0.84, shadow: 0.65, strokeWidth: 1.2, backgroundOpacity: 0.48),
            activeWordHighlighting: false, targetClipID: item.id,
            explanation: ["Локальная речь; фразовые субтитры", Double(text.count) / max(0.01, b - a) > 20 ? "Быстрая речь: проверьте читаемость" : "Синхронно с исходным голосом"])
        if titles.contains(where: { $0.id == title.id }) { title.id = UUID() }
        title.startTime = a; title.duration = b - a; title.targetClipID = item.id; title.speechAnchor = anchor
        title.words = measuredCaptionWords(for: title, item: item)
        titles.append(title)
    }
    private static func wrapped(_ text: String, limit: Int) -> String {
        let clean = text.replacingOccurrences(of: #"(?<=\p{L})\s+-(?=\p{L})"#, with: "-", options: .regularExpression)
        let tokens = clean.split(whereSeparator: \.isWhitespace).map(String.init)
        guard clean.count > limit, tokens.count > 1 else { return clean }
        let split = (1..<tokens.count).min { a, b in
            func score(_ index: Int) -> Int {
                let first = tokens[..<index].joined(separator: " ").count
                let second = tokens[index...].joined(separator: " ").count
                return max(0, max(first, second) - limit) * 100 + abs(first - second)
            }
            return score(a) < score(b)
        } ?? 1
        return tokens[..<split].joined(separator: " ") + "\n" + tokens[split...].joined(separator: " ")
    }
    public static func reconcile(_ source: Timeline) -> Timeline {
        guard source.effectiveTitleItems.contains(where: { $0.speechAnchor != nil }) else { return source }
        var result = source
        result.titleItems = source.effectiveTitleItems.flatMap { title -> [TitleTimelineItem] in
            guard let anchor = title.speechAnchor else { return [title] }
            let matches = source.items.filter { $0.assetID == anchor.assetID && $0.overlay == nil && !$0.isReversed && !$0.isFreezeFrame && $0.sourceStart < anchor.sourceEnd && $0.sourceStart + $0.sourceDuration > anchor.sourceStart }
            return matches.compactMap { item in
                var value = title; var trimmed = anchor
                let words = anchor.words.filter { $0.startTime >= item.sourceStart - 0.001 && $0.endTime <= item.sourceStart + item.sourceDuration + 0.001 }
                if !anchor.words.isEmpty {
                    guard let first = words.first, let last = words.last else { return nil }
                    if anchor.hasManualTiming == true {
                        trimmed.sourceStart = max(anchor.sourceStart, item.sourceStart)
                        trimmed.sourceEnd = min(anchor.sourceEnd, item.sourceStart + item.sourceDuration)
                    } else { trimmed.sourceStart = first.startTime; trimmed.sourceEnd = last.endTime }
                    trimmed.words = words
                    if words != anchor.words {
                        if title.userEdited == true && !matchesMeasuredText(title, anchor: anchor) {
                            // A manual rewrite has no known per-word alignment.
                            // Preserve it for editing, but never publish words
                            // which may belong to the removed part of the audio.
                            value.enabled = false
                            let warning = "Ручной текст пересекает обрезанную речь: проверьте и включите субтитр после правки"
                            if !value.explanation.contains(warning) { value.explanation.append(warning) }
                        } else { value.text = wrapped(words.map(\.text).joined(separator: " "), limit: source.height > source.width ? 30 : 42) }
                    }
                } else if anchor.sourceStart < item.sourceStart || anchor.sourceEnd > item.sourceStart + item.sourceDuration { return nil }
                guard let a = SpeechTimeMap.timelineTime(sourceTime: trimmed.sourceStart, item: item), let b = SpeechTimeMap.timelineTime(sourceTime: trimmed.sourceEnd, item: item), b > a else { return nil }
                if item.id != title.targetClipID { value.id = stableUUID(title.id.uuidString + item.id.uuidString) }
                value.targetClipID = item.id; value.startTime = a; value.duration = b - a; value.speechAnchor = trimmed
                value.words = measuredCaptionWords(for: value, item: item)
                return value
            }
        }
        // A split can cause two previous anchors to converge. Keep one occurrence.
        var seen = Set<String>()
        result.titleItems = result.titleItems?.filter { title in
            guard let anchor = title.speechAnchor else { return true }
            return seen.insert("\(title.targetClipID?.uuidString ?? "")|\(anchor.sourceStart)|\(anchor.sourceEnd)").inserted
        }
        return result
    }
    private static func matchesMeasuredText(_ title: TitleTimelineItem, anchor: SpeechCaptionAnchor) -> Bool {
        func normalize(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return normalize(title.text) == normalize(anchor.words.map(\.text).joined(separator: " "))
    }

    /// Keep an explicitly selected highlight style, while deriving its clock
    /// only from measured source words through the same speed map as playback.
    public static func measuredCaptionWords(for title: TitleTimelineItem, item: TimelineItem) -> [CaptionWord] {
        guard title.activeWordHighlighting, let anchor = title.speechAnchor,
              matchesMeasuredText(title, anchor: anchor) else { return [] }
        return anchor.words.compactMap { word in
            guard word.startTime >= anchor.sourceStart - 0.001, word.endTime <= anchor.sourceEnd + 0.001,
                  let a = SpeechTimeMap.timelineTime(sourceTime: word.startTime, item: item),
                  let b = SpeechTimeMap.timelineTime(sourceTime: word.endTime, item: item) else { return nil }
            let start = max(0, a - title.startTime), end = min(title.duration, b - title.startTime)
            guard end > start else { return nil }
            return CaptionWord(id: stableUUID("\(anchor.key)|\(word.startTime)|\(word.text)"), word: word.text, start: start, end: end)
        }
    }
    /// A manual cue boundary is converted back to source time, so subsequent
    /// ripple edits and speed changes preserve the user's timing correction.
    public static func preservingManualTiming(_ edited: inout TitleTimelineItem, previous: TitleTimelineItem, timeline: Timeline) {
        guard abs(edited.startTime - previous.startTime) > 0.000001 || abs(edited.duration - previous.duration) > 0.000001,
              var anchor = edited.speechAnchor,
              let item = timeline.items.first(where: { $0.id == edited.targetClipID }), !item.isReversed else { return }
        let a = max(item.timelineStart, edited.startTime)
        let b = min(item.timelineStart + item.timelineDuration, edited.endTime)
        guard b > a else { return }
        anchor.sourceStart = item.sourceTime(atTimelineTime: a)
        anchor.sourceEnd = item.sourceTime(atTimelineTime: b)
        anchor.hasManualTiming = true
        edited.startTime = a; edited.duration = b - a; edited.speechAnchor = anchor
    }
    private static func stableUUID(_ value: String) -> UUID {
        let hash = SpeechFileHash.data(Data(value.utf8)); let chars = Array(hash.prefix(32))
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }
        return UUID(uuidString: parts.joined(separator: "-"))!
    }
    public static func suppress(_ title: TitleTimelineItem, in timeline: inout Timeline) {
        if let key = title.speechAnchor?.key {
            timeline.suppressedSpeechCaptionKeys = Array(Set((timeline.suppressedSpeechCaptionKeys ?? []) + [key])).sorted()
        }
    }
}

public enum SubtitleFileFormat: String, Sendable { case srt, vtt }
public enum SubtitleFileExporter {
    public static func render(timeline: Timeline, format: SubtitleFileFormat) -> String {
        let values = SpeechSubtitleBuilder.reconcile(timeline).effectiveTitleItems.filter { $0.enabled && [.subtitle, .automaticSubtitles, .wordLevelCaptions].contains($0.kind) }.compactMap { title -> (Double, Double, String)? in
            let range: ClosedRange<Double>
            if let anchor = title.speechAnchor, let item = timeline.items.first(where: { $0.id == title.targetClipID }), let mapped = SpeechTimeMap.playbackRange(anchor: anchor, item: item, timeline: timeline) { range = mapped }
            else { range = TimelineTiming.playbackTime(forTimelineTime: title.startTime, timeline: timeline)...TimelineTiming.playbackTime(forTimelineTime: title.endTime, timeline: timeline) }
            guard range.upperBound > range.lowerBound else { return nil }
            return (range.lowerBound, range.upperBound, title.text)
        }.sorted { $0.0 < $1.0 }
        return (format == .vtt ? "WEBVTT\n\n" : "") + values.enumerated().map { i, cue in
            let text = format == .vtt ? cue.2.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") : cue.2
            return "\(i + 1)\n\(stamp(cue.0, format)) --> \(stamp(cue.1, format))\n\(text)\n"
        }.joined(separator: "\n")
    }
    private static func stamp(_ seconds: Double, _ format: SubtitleFileFormat) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, format == .srt ? "," : ".", ms % 1000)
    }
}
