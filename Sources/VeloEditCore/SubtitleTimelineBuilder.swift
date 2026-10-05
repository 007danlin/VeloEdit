import Foundation

struct SubtitleTimelineBuilder: Sendable {
    let translator: any SubtitleTranslationProviding

    func build(directive: DirectorSubtitleDirective, input: NaturalLanguageDirectorInput) -> [TitleTimelineItem] {
        if let records = input.timeline.speechRecords, directive.language == .russian {
            return SpeechSubtitleBuilder.applying(to: input.timeline, records: records, enabled: true).effectiveTitleItems.filter { $0.speechAnchor != nil }
        }
        let candidates = Dictionary(uniqueKeysWithValues: input.currentProject.analyses.flatMap(\.directorCandidates).map { ($0.id, $0) })
        return input.timeline.items.compactMap { item -> TitleTimelineItem? in
            guard item.kind == .video, !item.isReversed,
                  item.overlay == nil, item.speedRamp == nil,
                  let candidate = item.candidateID.flatMap({ candidates[$0] }),
                  let speech = candidate.insights?.speech,
                  speech.confidence >= 0.32 else { return nil }
            let sourceStart = max(item.sourceStart, speech.phraseStart)
            let sourceEnd = min(item.sourceStart + item.sourceDuration, speech.phraseEnd)
            guard sourceEnd - sourceStart >= 0.08 else { return nil }
            let scale = item.timelineDuration / max(0.001, item.sourceDuration)
            let startTime = item.timelineStart + (sourceStart - item.sourceStart) * scale
            let duration = max(0.08, (sourceEnd - sourceStart) * scale)
            let retainedWords = (speech.words ?? []).filter { $0.startTime >= sourceStart && $0.endTime <= sourceEnd }
            guard !retainedWords.isEmpty || (speech.phraseStart >= item.sourceStart && speech.phraseEnd <= item.sourceStart + item.sourceDuration) else { return nil }
            let retainedText = retainedWords.isEmpty ? speech.text : retainedWords.map(\.text).joined(separator: " ")
            let translated = translator.translate(retainedText, from: speech.localeIdentifier, to: directive.language)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else { return nil }
            let style = subtitleStyle(directive.style, tracking: candidate.insights?.subjectTracking, vertical: input.timeline.height > input.timeline.width)
            let words = captionWords(
                translatedText: translated,
                sourceWords: retainedWords,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd,
                outputDuration: duration
            )
            return TitleTimelineItem(
                kind: words.isEmpty ? .automaticSubtitles : .wordLevelCaptions,
                templateID: words.isEmpty ? "caption.clean.v1" : "caption.word-focus.v1",
                text: translated,
                startTime: startTime,
                duration: duration,
                track: 2,
                style: style,
                animation: subtitleAnimation(directive.style),
                words: words,
                activeWordHighlighting: false,
                targetClipID: item.id,
                explanation: [
                    "P8 NaturalLanguageDirector subtitles",
                    "language=\(directive.language.rawValue)",
                    "style=\(directive.style.rawValue)",
                    speech.speakerID.map { "speaker=\($0)" } ?? "speaker=unknown",
                    "safe-area + face avoidance"
                ]
            )
        }
    }

    private func captionWords(
        translatedText: String,
        sourceWords: [TranscriptWord],
        sourceStart: Double,
        sourceEnd: Double,
        outputDuration: Double
    ) -> [CaptionWord] {
        let translatedTokens = translatedText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !translatedTokens.isEmpty else { return [] }
        let usable = sourceWords.filter { $0.startTime <= sourceEnd && $0.endTime >= sourceStart }
        if usable.map(\.text) == translatedTokens {
            let sourceSpan = max(0.001, sourceEnd - sourceStart)
            return zip(translatedTokens, usable).map { token, word in
                CaptionWord(
                    word: token,
                    start: min(outputDuration, max(0, (word.startTime - sourceStart) / sourceSpan * outputDuration)),
                    end: min(outputDuration, max(0, (word.endTime - sourceStart) / sourceSpan * outputDuration))
                )
            }
        }
        return []
    }

    private func subtitleStyle(_ preset: DirectorSubtitleStyle, tracking: SubjectTrackingSummary?, vertical: Bool) -> TitleStyle {
        let centers = tracking?.mainSubject?.observations.map { $0.region.centerY } ?? []
        let subjectY: Double? = centers.isEmpty ? nil : centers.reduce(0, +) / Double(centers.count)
        let y = (subjectY ?? 0.4) > 0.58 ? 0.17 : (vertical ? 0.76 : 0.84)
        switch preset {
        case .cinematic:
            return TitleStyle(fontSize: 54, textColorHex: "#FFFFFF", backgroundColorHex: "#111111", fontWeight: 0.62, yPosition: y, shadow: 0.72, strokeWidth: 1.2, backgroundOpacity: 0.10)
        case .vlog:
            return TitleStyle(fontSize: 70, textColorHex: "#FFFFFF", backgroundColorHex: "#111111", fontWeight: 0.82, yPosition: y, shadow: 0.55, strokeWidth: 1.8, backgroundOpacity: 0.32, activeWordColorHex: "#FFD60A")
        case .travel:
            return TitleStyle(fontSize: 60, textColorHex: "#FFFFFF", backgroundColorHex: "#111111", fontWeight: 0.70, yPosition: y, shadow: 0.62, strokeWidth: 1.2, backgroundOpacity: 0.22, activeWordColorHex: "#5AC8FA")
        case .social:
            return TitleStyle(fontSize: 76, textColorHex: "#FFFFFF", backgroundColorHex: "#111111", fontWeight: 0.90, yPosition: y, shadow: 0.45, strokeWidth: 2.0, backgroundOpacity: 0.38, activeWordColorHex: "#FFCC00")
        }
    }

    private func subtitleAnimation(_ style: DirectorSubtitleStyle) -> TitleAnimation {
        switch style {
        case .cinematic, .travel: return TitleAnimation(entrance: .fade, exit: .fade, duration: 0.22)
        case .vlog: return TitleAnimation(entrance: .scale, exit: .fade, duration: 0.16)
        case .social: return TitleAnimation(entrance: .kinetic, exit: .scale, duration: 0.12)
        }
    }
}

