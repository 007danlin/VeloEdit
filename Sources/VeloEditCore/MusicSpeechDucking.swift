import Foundation
import AVFoundation

public struct MusicDuckingExclusion: Codable, Hashable, Sendable {
    public var target: String
    public var assetID: UUID
    public var sourceRange: ClosedRange<Double>
}

/// Measured source-time speech, separate from transcripts and caption settings.
public struct SpeechActivityRecord: Codable, Hashable, Sendable {
    public var assetID: UUID
    public var ranges: [ClosedRange<Double>]

    public init(assetID: UUID, ranges: [ClosedRange<Double>]) {
        self.assetID = assetID
        self.ranges = ranges
    }
}

public struct MusicDuckingRegion: Identifiable, Hashable, Sendable {
    public struct Anchor: Hashable, Sendable {
        public var itemID: UUID
        public var assetID: UUID
        public var isAudioClip: Bool
        public var sourceRange: ClosedRange<Double>
    }

    public var target: String
    public var speechRange: ClosedRange<Double>
    public var playbackRange: ClosedRange<Double>
    public var timelineRange: ClosedRange<Double>
    public var attenuation: Double
    public var anchors: [Anchor]
    public var id: String {
        target + ":\(Int((playbackRange.lowerBound * 1000).rounded())):\(Int((playbackRange.upperBound * 1000).rounded())):" + anchors.map {
            "\($0.itemID):\(Int(($0.sourceRange.lowerBound * 1000).rounded())):\(Int(($0.sourceRange.upperBound * 1000).rounded()))"
        }.sorted().joined(separator: "|")
    }

    public func gain(at time: Double) -> Double {
        guard time >= playbackRange.lowerBound, time <= playbackRange.upperBound else { return 1 }
        if time < speechRange.lowerBound {
            return 1 - (1 - attenuation) * (time - playbackRange.lowerBound)
                / max(0.000_001, speechRange.lowerBound - playbackRange.lowerBound)
        }
        if time > speechRange.upperBound {
            return attenuation + (1 - attenuation) * (time - speechRange.upperBound)
                / max(0.000_001, playbackRange.upperBound - speechRange.upperBound)
        }
        return attenuation
    }
}

/// One plan drives both the visible zones and the actual preview/export mix.
/// Missing speech evidence is silence for this policy, never "the whole clip".
public enum MusicSpeechDucking {
    public static let soundtrack = "soundtrack"

    public static func transcriptRanges(_ record: SpeechSourceRecord) -> [ClosedRange<Double>]? {
        switch record.status {
        case .ready, .partial:
            return record.transcript.speechRanges ?? record.transcript.sentences.compactMap {
                guard !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      $0.confidence >= 0.35, $0.endTime > $0.startTime else { return nil }
                return $0.startTime...$0.endTime
            }
        case .noSpeech: return []
        case .modelUnavailable, .failed, .cancelled: return nil
        }
    }

    public static func regions(in timeline: Timeline, activity: [SpeechActivityRecord] = []) -> [MusicDuckingRegion] {
        let settings = SourceAudioMixPolicy.musicDucking(in: timeline)
        let duration = TimelineTiming.playbackTime(forTimelineTime: timeline.duration, timeline: timeline)
        guard duration > 0 else { return [] }
        var evidence = Dictionary(activity.map { ($0.assetID, $0.ranges) }, uniquingKeysWith: +)
        for record in timeline.speechRecords ?? [] {
            if let ranges = transcriptRanges(record) { evidence[record.assetID] = ranges }
        }
        guard evidence.values.contains(where: { !$0.isEmpty }) else { return [] }
        struct Target { var key: String; var range: ClosedRange<Double> }
        var targets: [Target] = []
        func audioRange(_ clip: TimelineAudioClip) -> ClosedRange<Double> {
            if let owner = timeline.items.first(where: { $0.id == clip.attachedToItemID }),
               let start = SpeechTimeMap.playbackStart(itemID: owner.id, timeline: timeline) {
                let a = max(0, start + clip.timelineStart - owner.timelineStart)
                return a...max(a, min(duration, a + clip.timelineDuration))
            }
            let a = TimelineTiming.playbackTime(forTimelineTime: clip.timelineStart, timeline: timeline)
            let b = min(duration, TimelineTiming.playbackTime(forTimelineTime: clip.timelineEnd, timeline: timeline))
            return a...max(a, b)
        }
        if let adaptive = timeline.effectiveAdaptiveSoundtrack {
            for segment in adaptive.segments where (segment.duckingEnabled ?? settings.enabled) && segment.directive.volume > 0 {
                let a = TimelineTiming.playbackTime(forTimelineTime: segment.timelineStart, timeline: timeline)
                let b = TimelineTiming.playbackTime(forTimelineTime: segment.timelineStart + segment.timelineDuration, timeline: timeline)
                if b > a { targets.append(Target(key: soundtrack, range: a...b)) }
            }
        } else if settings.enabled, let music = timeline.music, music.volume > 0 {
            targets.append(Target(key: soundtrack, range: 0...duration))
        }
        if settings.enabled {
            for clip in timeline.effectiveAudioClips where clip.role == .music && clip.adjustments.effectiveVolume > 0 {
                let range = audioRange(clip), a = range.lowerBound, b = range.upperBound
                if b > a { targets.append(Target(key: clip.id.uuidString, range: a...b)) }
            }
        }
        struct Event { var range: ClosedRange<Double>; var anchor: MusicDuckingRegion.Anchor }
        // Inverting the source speed map leaves sub-sample rounding residue.
        // Use the same clock as the mix so speech at zero is already ducked,
        // rather than becoming a long ramp from an almost-zero attack.
        func audioTime(_ time: Double) -> Double { (time * 48_000).rounded() / 48_000 }
        var result: [MusicDuckingRegion] = []
        for target in targets {
            var events: [Event] = []
            func append(assetID: UUID?, itemID: UUID, isAudio: Bool, source: ClosedRange<Double>,
                        audio: AudioAdjustments, map: (Double) -> Double?) {
                guard let assetID, audio.effectiveVolume > 0 else { return }
                let excluded = (audio.musicDuckingExclusions ?? []).filter { $0.target == target.key && $0.assetID == assetID }.map(\.sourceRange)
                for speech in evidence[assetID] ?? [] {
                    let lo = max(source.lowerBound, speech.lowerBound), hi = min(source.upperBound, speech.upperBound)
                    guard lo.isFinite, hi.isFinite, hi > lo else { continue }
                    for range in subtract(excluded, from: lo...hi) {
                        guard let a = map(range.lowerBound), let b = map(range.upperBound) else { continue }
                        let start = audioTime(max(target.range.lowerBound, a))
                        let end = audioTime(min(target.range.upperBound, b))
                        guard end > start else { continue }
                        func sourceTime(at playback: Double) -> Double {
                            var lower = range.lowerBound, upper = range.upperBound
                            for _ in 0..<48 {
                                let middle = (lower + upper) / 2
                                if (map(middle) ?? a) < playback { lower = middle } else { upper = middle }
                            }
                            return (lower + upper) / 2
                        }
                        // A music segment may cover only part of an utterance.
                        // Removing its zone must leave adjacent segments alone.
                        let sourceStart = a < target.range.lowerBound ? sourceTime(at: target.range.lowerBound) : range.lowerBound
                        let sourceEnd = b > target.range.upperBound ? sourceTime(at: target.range.upperBound) : range.upperBound
                        events.append(Event(range: start...end,
                            anchor: .init(itemID: itemID, assetID: assetID, isAudioClip: isAudio, sourceRange: sourceStart...max(sourceStart, sourceEnd))))
                    }
                }
            }
            if timeline.effectiveOriginalAudioVolume > 0 {
                for item in timeline.items where item.kind == .video && !item.isReversed && !item.isFreezeFrame {
                    guard let assetID = item.assetID, evidence[assetID]?.isEmpty == false,
                          item.effectiveAudioAdjustments.effectiveVolume > 0 else { continue }
                    let start = item.overlay == nil
                        ? SpeechTimeMap.playbackStart(itemID: item.id, timeline: timeline)
                        : TimelineTiming.playbackTime(forTimelineTime: item.timelineStart, timeline: timeline)
                    append(assetID: assetID, itemID: item.id, isAudio: false,
                        source: item.sourceStart...(item.sourceStart + item.sourceDuration),
                        audio: item.effectiveAudioAdjustments) { time in
                        guard let mapped = SpeechTimeMap.timelineTime(sourceTime: time, item: item), let start else { return nil }
                        return start + mapped - item.timelineStart
                    }
                }
            }
            for clip in timeline.effectiveAudioClips where clip.role != .music {
                let range = audioRange(clip), start = range.lowerBound, end = range.upperBound
                append(assetID: clip.assetID, itemID: clip.id, isAudio: true,
                    source: clip.sourceStart...(clip.sourceStart + clip.sourceDuration), audio: clip.adjustments) {
                    start + ($0 - clip.sourceStart) / max(0.001, clip.sourceDuration) * (end - start)
                }
            }
            // Leave pauses audible; merge only envelopes whose fades overlap.
            var groups: [[Event]] = []
            for event in events.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                if let last = groups.last, event.range.lowerBound <= (last.map(\.range.upperBound).max() ?? 0) + settings.attack + settings.release {
                    groups[groups.count - 1].append(event)
                } else { groups.append([event]) }
            }
            for group in groups {
                let a = group.map(\.range.lowerBound).min()!, b = group.map(\.range.upperBound).max()!
                let start = audioTime(max(target.range.lowerBound, a - settings.attack))
                let end = audioTime(min(target.range.upperBound, b + settings.release))
                let timelineStart = TimelineTiming.timelineTime(forPlaybackTime: start, timeline: timeline)
                let timelineEnd = TimelineTiming.timelineTime(forPlaybackTime: end, timeline: timeline)
                result.append(.init(target: target.key, speechRange: a...b, playbackRange: start...end,
                    timelineRange: timelineStart...max(timelineStart, timelineEnd),
                    attenuation: settings.attenuation, anchors: group.map(\.anchor)))
            }
        }
        return result.sorted { $0.playbackRange.lowerBound < $1.playbackRange.lowerBound }
    }

    public static func removing(_ region: MusicDuckingRegion, from timeline: inout Timeline) {
        for anchor in region.anchors {
            let exclusion = MusicDuckingExclusion(target: region.target, assetID: anchor.assetID, sourceRange: anchor.sourceRange)
            if anchor.isAudioClip, let index = timeline.audioClips?.firstIndex(where: { $0.id == anchor.itemID }) {
                var values = timeline.audioClips?[index].adjustments.musicDuckingExclusions ?? []
                if !values.contains(exclusion) { values.append(exclusion) }
                timeline.audioClips?[index].adjustments.musicDuckingExclusions = values
            } else if let index = timeline.items.firstIndex(where: { $0.id == anchor.itemID }) {
                var audio = timeline.items[index].effectiveAudioAdjustments
                var values = audio.musicDuckingExclusions ?? []
                if !values.contains(exclusion) { values.append(exclusion) }
                audio.musicDuckingExclusions = values
                timeline.items[index].audioAdjustments = audio
            }
        }
    }

    public static func retargetExclusions(from old: String, to new: String, in timeline: inout Timeline, copy: Bool = false) {
        func retarget(_ audio: inout AudioAdjustments) {
            guard let values = audio.musicDuckingExclusions, values.contains(where: { $0.target == old }) else { return }
            let mapped = values.filter { $0.target == old }.map { value -> MusicDuckingExclusion in
                var value = value; value.target = new; return value
            }
            audio.musicDuckingExclusions = (copy ? values : values.filter { $0.target != old }) + mapped
        }
        for index in timeline.items.indices {
            guard var audio = timeline.items[index].audioAdjustments else { continue }
            retarget(&audio)
            timeline.items[index].audioAdjustments = audio
        }
        for index in (timeline.audioClips ?? []).indices {
            retarget(&timeline.audioClips![index].adjustments)
        }
    }

    static func subtract(_ exclusions: [ClosedRange<Double>], from source: ClosedRange<Double>) -> [ClosedRange<Double>] {
        var ranges = [source]
        for excluded in exclusions {
            ranges = ranges.flatMap { range -> [ClosedRange<Double>] in
                guard excluded.upperBound > range.lowerBound, excluded.lowerBound < range.upperBound else { return [range] }
                var parts: [ClosedRange<Double>] = []
                if excluded.lowerBound > range.lowerBound { parts.append(range.lowerBound...excluded.lowerBound) }
                if excluded.upperBound < range.upperBound { parts.append(excluded.upperBound...range.upperBound) }
                return parts
            }
        }
        return ranges
    }

    /// Compose speech gain with existing fades instead of overwriting them or
    /// scheduling overlapping AVFoundation ramps.
    static func applying(_ regions: [MusicDuckingRegion], to original: AVAudioMixInputParameters,
                         duration: Double) -> AVAudioMixInputParameters {
        guard !regions.isEmpty else { return original }
        let result = AVMutableAudioMixInputParameters()
        result.trackID = original.trackID
        result.audioTimePitchAlgorithm = original.audioTimePitchAlgorithm
        result.audioTapProcessor = original.audioTapProcessor
        let knots = regions.flatMap { [$0.playbackRange.lowerBound, $0.speechRange.lowerBound,
                                      $0.speechRange.upperBound, $0.playbackRange.upperBound] }
        for (a, b, range) in EditorialAudioMastering.envelopes(original, duration: duration) {
            let lo = range.start.seconds, hi = range.end.seconds
            let boundaries = Array(Set(([lo, hi] + knots).filter { $0 >= lo && $0 <= hi })).sorted()
            func volume(_ time: Double) -> Float {
                let base = a + (b - a) * Float(min(1, max(0, (time - lo) / (hi - lo))))
                return base * Float(regions.map { $0.gain(at: time) }.min() ?? 1)
            }
            for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
                let steps = max(1, Int(ceil((end - start) * (a == b ? 1 : 60))))
                var cursor = CMTime(seconds: start, preferredTimescale: 48_000)
                for step in 1...steps {
                    let next = CMTime(seconds: start + (end - start) * Double(step) / Double(steps), preferredTimescale: 48_000)
                    guard next > cursor else { continue }
                    result.setVolumeRamp(fromStartVolume: volume(cursor.seconds), toEndVolume: volume(next.seconds),
                        timeRange: CMTimeRange(start: cursor, end: next))
                    cursor = next
                }
            }
        }
        return result
    }
}
