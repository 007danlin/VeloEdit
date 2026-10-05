import Foundation

public extension Timeline {
    mutating func setSoundtrackVolume(_ volume: Double) {
        let volume = min(1, max(0, volume))
        music?.volume = volume
        if adaptiveSoundtrack?.userEdited == true {
            for index in adaptiveSoundtrack!.segments.indices { adaptiveSoundtrack!.segments[index].directive.volume = volume }
        }
    }

    mutating func setSoundtrackSpeed(_ speed: Double) {
        let speed = min(20, max(0.1, speed))
        music?.speed = speed
        if adaptiveSoundtrack?.userEdited == true {
            for index in adaptiveSoundtrack!.segments.indices { adaptiveSoundtrack!.segments[index].directive.speed = speed }
        }
    }
}

/// Explicit music edits share the existing segmented soundtrack renderer.
/// Regions outside the brush retain their track, source offset, gain and ducking.
enum LocalizedSoundtrackEditing {
    static func apply(_ command: EditorCommand, to source: Timeline, range: ClosedRange<Double>) -> Timeline? {
        let lower = max(0, range.lowerBound)
        let upper = min(source.duration, range.upperBound)
        guard upper - lower >= 0.05 else { return nil }
        var timeline = source
        let replacement: MusicDirective?
        if case .setMusic(let directive) = command { replacement = directive } else { replacement = nil }
        guard let master = source.music ?? replacement, let primaryID = master.trackID else { return nil }
        let prior = source.effectiveAdaptiveSoundtrack
        var regions = prior?.segments ?? [AdaptiveMusicSegment(
            timelineStart: 0, timelineDuration: source.duration,
            directive: source.music ?? silent(master), sourceStart: max(0, source.music?.sourceStart ?? 0),
            semanticLabel: master.trackTitle ?? master.style.localizedTitle, energy: 0.5, confidence: 1
        )]
        // Freeze the automatic mix's existing audible gain before editing one region.
        if prior != nil && prior?.userEdited != true {
            for index in regions.indices {
                regions[index].directive.volume = min(1, master.volume * (0.92 + regions[index].energy * 0.12))
            }
        }
        var result: [AdaptiveMusicSegment] = []
        for region in regions {
            let cuts = ([region.timelineStart, region.timelineEnd] + [lower, upper].filter {
                $0 > region.timelineStart + 0.0001 && $0 < region.timelineEnd - 0.0001
            }).sorted()
            for (index, bounds) in zip(cuts, cuts.dropFirst()).enumerated() {
                var part = region
                if index > 0 { part.id = UUID(); part.transitionDuration = 0 }
                part.timelineStart = bounds.0
                part.timelineDuration = bounds.1 - bounds.0
                let renderedStart = TimelineTiming.playbackTime(forTimelineTime: bounds.0, timeline: source)
                let renderedRegionStart = TimelineTiming.playbackTime(forTimelineTime: region.timelineStart, timeline: source)
                part.sourceStart += (renderedStart - renderedRegionStart) * region.directive.effectiveSpeed
                if bounds.0 >= lower - 0.0001 && bounds.1 <= upper + 0.0001 {
                    part.transitionDuration = 0
                    switch command {
                    case .setMusic(let directive):
                        if let directive {
                            part.directive = directive
                            let renderedSelectionStart = TimelineTiming.playbackTime(forTimelineTime: lower, timeline: source)
                            part.sourceStart = max(0, directive.sourceStart ?? 0) + (renderedStart - renderedSelectionStart) * directive.effectiveSpeed
                            part.semanticLabel = directive.trackTitle ?? directive.style.localizedTitle
                        } else {
                            part.directive.volume = 0
                            part.semanticLabel = "Без музыки"
                        }
                    case .setMusicVolume(let volume): part.directive.volume = min(1, max(0, volume))
                    case .setAudioDucking(let enabled): part.duckingEnabled = enabled
                    default: return nil
                    }
                }
                // No crossfade may carry a local edit beyond its highlighted boundary.
                if abs(bounds.0 - lower) < 0.0001 || abs(bounds.0 - upper) < 0.0001 { part.transitionDuration = 0 }
                result.append(part)
            }
        }
        timeline.music = master
        timeline.adaptiveSoundtrack = AdaptiveSoundtrackPlan(
            primaryTrackID: primaryID, timelineDuration: source.duration,
            segments: result, confidence: 1,
            explanation: ["Музыка изменена только в выделенном диапазоне"], userEdited: true
        )
        return timeline
    }

    private static func silent(_ source: MusicDirective) -> MusicDirective {
        var result = source
        result.volume = 0
        return result
    }
}
