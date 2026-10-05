import Foundation

/// Library insertions are one operation: a title requested on a background
/// must travel with that background and must not land on an existing shot.
public struct DirectorBackgroundInsertion: Hashable, Sendable {
    public var background: String
    public var title: String?
    public var duration: Double
    public var position: TimelineInsertionPosition

    public init(background: String, title: String? = nil, duration: Double = 4, position: TimelineInsertionPosition = .beginning) {
        self.background = background
        self.title = title
        self.duration = duration
        self.position = position
    }
}

public enum DirectorLibraryEdits {
    public static func background(matching query: String) -> BackgroundPreset? {
        let text = normalized(query).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if let exact = BackgroundPreset.allCases.first(where: {
            normalized($0.rawValue) == text || normalized($0.localizedTitle) == text
        }) { return exact }
        let aliases: [(BackgroundPreset, [String])] = [
            (.stars, ["звезд", "ночное небо", "star"]),
            (.clouds, ["небо", "неба", "облак", "sky", "cloud"]),
            (.sunset, ["закат", "sunset"]), (.forest, ["лес", "forest"]),
            (.underwater, ["под водой", "подвод", "underwater"]),
            (.black, ["черн", "black"]), (.white, ["бел", "white"]),
            (.green, ["зелен", "green"]), (.blue, ["син", "голуб", "blue"]),
            (.red, ["красн", "red"]), (.gray, ["серый", "сером", "gray"]),
            (.aurora, ["северное сияние", "aurora"])
        ]
        if let match = aliases.first(where: { $0.1.contains(where: text.contains) }) { return match.0 }
        return BackgroundPreset.catalogPresets.sorted { $0.localizedTitle.count > $1.localizedTitle.count }.first {
            text.contains(normalized($0.localizedTitle)) || text == normalized($0.rawValue)
        }
    }

    static func parse(_ prompt: String) -> EditorCommand? {
        let unquoted = prompt.replacingOccurrences(of: #"[«“\"][^»”\"]*[»”\"]"#, with: "", options: .regularExpression)
        let text = normalized(unquoted)
        guard text.range(of: #"\b(?:добав\w*|встав\w*|поставь|создай|сделай|add|insert)\b"#, options: .regularExpression) != nil else { return nil }
        let position: TimelineInsertionPosition = text.range(of: #"\b(?:в|на)\s+начал\w*|\b(?:beginning|start)\b"#, options: .regularExpression) != nil ? .beginning : .end
        if let marker = prompt.range(of: #"\b(?:фон|фоном|заставку|заставка|background)\b"#, options: [.regularExpression, .caseInsensitive]),
           !normalized(String(prompt[..<marker.lowerBound])).contains("эффект") {
            let suffix = String(prompt[marker.upperBound...])
            let titlePattern = #"\s+(?:с\s+)?(?:титром|титр|надписью|надпись|текстом|текст)\s*[:—-]?\s*"#
            let titleMarker = suffix.range(of: titlePattern, options: [.regularExpression, .caseInsensitive])
            var query = titleMarker.map { String(suffix[..<$0.lowerBound]) } ?? suffix
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                query = String(prompt[..<marker.lowerBound]).replacingOccurrences(of: #"(?i)\b(?:добав\w*|встав\w*|поставь|создай|сделай)\b"#, with: "", options: .regularExpression)
            }
            let durationPattern = #"\s+на\s+(\d+(?:[.,]\d+)?)\s*(?:с\b|сек\w*|seconds?)"#
            let duration = NLText.firstNumber(in: text, pattern: durationPattern) ?? 4
            func clean(_ value: String) -> String {
                value.replacingOccurrences(of: durationPattern, with: "", options: [.regularExpression, .caseInsensitive])
                    .replacingOccurrences(of: #"(?i)\s+(?:в|на)\s+(?:начал\w*|конец|конце)(?:\s+фильма)?"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "«»\"“”.")))
            }
            let title = titleMarker.map { marker -> String in
                let tail = String(suffix[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let quoted = NLText.firstMatch(in: tail, pattern: #"^[«“\"]([^»”\"]*)[»”\"]"#)?.first { return quoted }
                return clean(tail)
            }.flatMap { $0.isEmpty ? nil : $0 }
            return .insertBackground(.init(background: clean(query), title: title, duration: duration,
                position: text.contains("в конце") || text.contains("в конец") || text.contains("end") ? .end : .beginning))
        }
        if text.range(of: #"\b(?:кусок|фрагмент|момент|кадр|сцену|сцена|клип|видео|shot|scene|clip)\b"#, options: .regularExpression) != nil,
           text.contains("где ") || text.contains(" с ") || text.contains("из исходник") || text.contains("with ") {
            let query = prompt.range(of: #"\b(?:где|with)\s+"#, options: [.regularExpression, .caseInsensitive]).map { String(prompt[$0.upperBound...]) } ?? prompt
            return .insertSource(query.trimmingCharacters(in: .whitespacesAndNewlines), position)
        }
        return nil
    }

    /// Search only per-shot evidence, never a selected clip or an event's
    /// broad tags. Quality breaks ties but cannot establish a content match.
    static func sourceMatch(query: String, timeline: Timeline, assets: [MediaAsset], analyses: [AnalysisResult]) -> Candidate? {
        let tokens = NLText.semanticTokens(query)
        guard !tokens.isEmpty else { return nil }
        let availableAssets = assets.filter { $0.kind == .video && !$0.missing && !$0.excluded && FileManager.default.fileExists(atPath: $0.originalURL.path) }
        let available = Set(availableAssets.map(\.id))
        let matches = analyses.filter { analysis in
            availableAssets.contains { $0.id == analysis.assetID && $0.contentHash == analysis.analyzedContentHash }
        }.flatMap(\.directorCandidates).filter { candidate in
            guard !candidate.excluded, available.contains(candidate.assetID) else { return false }
            return !timeline.items.contains { item in
                item.assetID == candidate.assetID && item.sourceStart < candidate.sourceStart + candidate.sourceDuration
                    && item.sourceStart + item.sourceDuration > candidate.sourceStart
            }
        }.compactMap { candidate -> (Candidate, Double)? in
            let evidence = NLText.semanticTokens(candidate.tags.sorted().joined(separator: " ") + " " + (candidate.insights?.sceneSummary ?? ""))
            let coverage = Double(tokens.intersection(evidence).count) / Double(tokens.count)
            guard coverage >= 0.5 else { return nil }
            return (candidate, coverage)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            let lhs = SemanticSceneIndex.bestTakeScore($0.0), rhs = SemanticSceneIndex.bestTakeScore($1.0)
            return lhs == rhs ? $0.0.id.uuidString < $1.0.id.uuidString : lhs > rhs
        }
        return matches.first?.0
    }

    static func insert(_ item: TimelineItem, at position: TimelineInsertionPosition, into timeline: inout Timeline) {
        // Materialize legacy derived objects before changing the primary track.
        var titles = timeline.effectiveTitleItems
        var effects = timeline.effectiveEffects
        var telemetry = timeline.effectiveTelemetryItems
        var transitions = timeline.effectiveTransitionItems
        var audio = timeline.effectiveAudioClips
        var soundtrack = timeline.effectiveAdaptiveSoundtrack
        if position == .beginning {
            let delta = item.timelineDuration
            for index in titles.indices { titles[index].startTime += delta }
            for index in effects.indices { effects[index].startTime += delta }
            for index in telemetry.indices { telemetry[index].timelineStart += delta }
            for index in transitions.indices { transitions[index].startTime += delta }
            for index in audio.indices { audio[index].timelineStart += delta }
        }
        timeline.titleItems = titles
        timeline.effects = effects
        timeline.telemetryItems = telemetry
        timeline.transitionItems = transitions
        timeline.audioClips = audio
        timeline.items.insert(item, at: position == .beginning ? 0 : timeline.items.count)
        timeline.items = TimelineTiming.retimed(timeline.items)
        if var plan = soundtrack, !plan.segments.isEmpty {
            if position == .beginning {
                plan.segments[0].timelineDuration += item.timelineDuration
                for index in plan.segments.indices.dropFirst() { plan.segments[index].timelineStart += item.timelineDuration }
            } else {
                plan.segments[plan.segments.count - 1].timelineDuration += item.timelineDuration
            }
            plan.timelineDuration = timeline.duration
            plan.timelineFingerprint = timeline.adaptiveSoundtrackFingerprint
            soundtrack = plan
            timeline.adaptiveSoundtrack = soundtrack
        }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }
}
