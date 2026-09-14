import Foundation

/// Catalogue descriptions and measured rhythm remain separate evidence.
/// This record deliberately makes no claim to have measured emotion in audio.
public struct SoundtrackSelectionEvidence: Codable, Hashable, Sendable {
    public var algorithmVersion: Int = 1
    public var request: String
    public var catalogCharacter: [String]
    public var characterSource: String
    public var characterConfidence: Double?
    public var rhythmSource: String
    public var rhythmConfidence: Double
    public var window: MusicWindowDecision
    public var alternatives: [String]
}

public struct MusicWindowDecision: Codable, Hashable, Sendable {
    public var sourceStart: Double
    public var sourceDuration: Double
    public var score: Double
    public var measured: Bool
    public var reasons: [String]
}

/// Evaluates a bounded set of audible windows on the actual, final movie
/// clock. It changes only music; speech, actions and manual cuts cannot move.
public enum SoundtrackEditorialPolicy {
    public static let maximumCandidates = 4

    public static func window(track: LocalMusicTrack, structure: MusicStructure?, timeline: Timeline,
                              analyses: [AnalysisResult] = [], timelineStart: Double = 0,
                              duration: Double? = nil) -> MusicWindowDecision {
        let speed = timeline.music?.effectiveSpeed ?? 1
        let movieLength = duration ?? TimelineTiming.playbackTime(forTimelineTime: timeline.duration, timeline: timeline)
        let length = max(0.05, movieLength * speed)
        let available = max(0.05, track.duration)
        let latest = max(0, available - length)
        guard let structure, structure.analysisIsMeasured == true else {
            return .init(sourceStart: 0, sourceDuration: min(length, available), score: 0,
                         measured: false, reasons: ["Нет измеренной структуры: сохранено начало трека; характер известен только из каталога"])
        }
        let style = timeline.music?.style ?? track.suggestedStyle
        let desired = MusicIntent(directive: timeline.music ?? MusicDirective(style: style, bpm: track.bpm)).energy
        let dynamic = [.energetic, .electronic, .joyful].contains(style)
        let candidatesByID = Dictionary(analyses.flatMap(\.directorCandidates).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Only completed measured actions contribute strong event anchors.
        let events: [Double] = timeline.items.compactMap { item in
            guard let id = item.candidateID, let candidate = candidatesByID[id] else { return nil }
            let unit = EditorialUnit(candidate: candidate)
            guard unit.evidence.hasProgression, unit.evidence.completion >= 0.65,
                  item.sourceStart + item.sourceDuration + 1 / max(1, timeline.frameRate) >= unit.evidence.usableRange.end else { return nil }
            let time = TimelineTiming.playbackTime(forTimelineTime: item.timelineStart + item.timelineDuration, timeline: timeline) - timelineStart
            return time > 0 && time < movieLength ? time : nil
        }
        let reliableRhythm = (structure.tempoConfidence ?? 0) >= 0.65
        let accents = reliableRhythm ? (structure.accents ?? []).filter { ($0.confidence ?? 0) >= 0.65 && $0.strength >= 0.65 }.map(\.time) : []
        let phrases = (structure.phraseConfidence ?? 0) >= 0.55 ? structure.phraseBoundaries ?? [] : []
        let quiet = structure.quietRanges ?? []
        var starts = [0.0, latest]
        starts += structure.sections.map(\.start)
        starts += phrases
        starts += phrases.map { $0 - length }
        starts += quiet.map { $0.lowerBound - length }
        // Align the music to a completed action, never truncate the action to
        // force a beat. The final sample grid is retained by the renderer.
        for event in events.prefix(4) { starts += accents.prefix(64).map { $0 - event * speed } }
        let unique = Array(Set(starts.filter { $0.isFinite && $0 >= 0 && $0 <= latest }.map { ($0 * 600).rounded() / 600 })).sorted()
        let bounded: [Double] = unique.count <= 96 ? unique : (0..<96).map { unique[$0 * (unique.count - 1) / 95] }
        func energy(_ start: Double, _ end: Double) -> Double {
            var total = 0.0, seconds = 0.0
            for section in structure.sections {
                let overlap = max(0, min(end, section.start + section.duration) - max(start, section.start))
                total += section.energy * overlap; seconds += overlap
            }
            return seconds > 0 ? total / seconds : track.energy
        }
        func score(_ start: Double) -> Double {
            let end = min(available, start + length)
            let opening = energy(start, min(end, start + min(4 * speed, length * 0.25)))
            let ending = energy(max(start, end - min(3 * speed, length * 0.2)), end)
            var result = (1 - abs(energy(start, end) - desired)) * 0.35
            result += dynamic ? min(1, opening / max(0.3, desired)) * 0.3 : (1 - abs(opening - desired)) * 0.18
            let silence = quiet.reduce(0.0) { $0 + max(0, min(start + min(4, length), $1.upperBound) - max(start, $1.lowerBound)) }
            if dynamic { result -= min(0.45, silence * 0.14) }
            let atEnd = abs(end - available) <= 0.1
            let endsQuietly = quiet.contains { $0.contains(end) }
            let phraseDistance = phrases.map { abs($0 - end) }.min() ?? .infinity
            result += atEnd ? 0.23 : endsQuietly ? 0.18 : max(0, 1 - phraseDistance / max(0.5, structure.beatInterval)) * 0.15
            result += (1 - ending) * 0.07
            for event in events.prefix(4) {
                let distance = accents.map { abs($0 - (start + event * speed)) }.min() ?? .infinity
                result += max(0, 1 - distance / max(0.05, 2 / timeline.frameRate * speed)) * 0.08
            }
            for item in timeline.items {
                guard let id = item.candidateID, let speech = candidatesByID[id]?.insights?.speech, speech.confidence >= 0.65 else { continue }
                let a = TimelineTiming.playbackTime(forTimelineTime: item.timelineStart, timeline: timeline) - timelineStart
                let b = a + item.timelineDuration
                guard b > 0 && a < movieLength else { continue }
                result -= energy(start + max(0, a) * speed, min(end, start + b * speed)) * min(0.12, item.timelineDuration / max(1, movieLength) * 0.2)
            }
            return result
        }
        let best = bounded.max { a, b in score(a) == score(b) ? a > b : score(a) < score(b) } ?? 0
        var reasons = ["Сравнено участков: \(bounded.count); карта фильма \(String(format: "%.2f", movieLength)) с", "Энергия и паузы измерены; эмоциональный характер аудио не определялся"]
        if dynamic { reasons.append("Проверены слышимое вступление и первые секунды") }
        if !reliableRhythm { reasons.append("Ритм недостаточно достоверен: привязка действий к долям отключена") }
        if length > available { reasons.append("Трек короче фильма; выбор участка не устраняет необходимость продолжения") }
        return .init(sourceStart: best, sourceDuration: min(length, available - best), score: score(best), measured: true, reasons: reasons)
    }

    public static func applying(track: LocalMusicTrack, structure: MusicStructure?, to timeline: Timeline,
                                analyses: [AnalysisResult] = [], alternatives: [String] = []) -> Timeline {
        var result = timeline
        guard var music = result.music else { return result }
        let decision = window(track: track, structure: structure, timeline: timeline, analyses: analyses)
        music.trackID = track.id; music.trackTitle = track.title
        music.structure = structure; music.sourceStart = decision.sourceStart
        music.selectionEvidence = .init(request: music.searchRequests?.map(\.query).joined(separator: "; ") ?? music.style.rawValue,
            catalogCharacter: track.genres + track.moods, characterSource: "catalog:\(track.sourceProvider.rawValue)",
            characterConfidence: nil, rhythmSource: structure?.analysisIsMeasured == true ? "decoded-audio" : "catalog-bpm",
            rhythmConfidence: structure?.tempoConfidence ?? 0, window: decision, alternatives: alternatives)
        result.music = music
        return result
    }
}
