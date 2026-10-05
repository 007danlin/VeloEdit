import Foundation

/// Source attenuation and music ducking have opposite purposes. A request to
/// lower camera sound must not also give that sound priority over the music.
public enum SourceAudioMixPolicy {
    /// The final mix cannot be raised without also raising camera audio. Keep
    /// an explicitly attenuated source at its requested level through export.
    public static func preservesAttenuation(in timeline: Timeline) -> Bool {
        let embedded = timeline.items.contains { item in
            guard item.kind == .video else { return false }
            let gain = timeline.effectiveOriginalAudioVolume * item.effectiveAudioAdjustments.effectiveVolume
            return gain > 0 && gain < 1
        }
        return embedded || timeline.effectiveAudioClips.contains { clip in
            isSource(clip) && clip.adjustments.effectiveVolume > 0 && clip.adjustments.effectiveVolume < 1
        }
    }

    /// A deliberately quiet delivery is valid only when the request calls for
    /// attenuation. An accidentally quiet preserve/mute mix still fails QA.
    public static func allowsQuietDelivery(timeline: Timeline, plan: StoryPlan) -> Bool {
        guard let requested = ExplicitDeliveryRequirements(plan: plan).originalAudioVolume,
              requested > 0, requested < 1 else { return false }
        return preservesAttenuation(in: timeline)
    }

    public static func musicDucking(in timeline: Timeline) -> AudioDuckingSettings {
        timeline.audioDucking ?? AudioDuckingSettings(enabled: timeline.effectiveOriginalAudioVolume >= 1)
    }

    public static func applyingRequestedVolume(_ volume: Double, to source: Timeline) -> Timeline {
        var timeline = source
        let volume = min(1, max(0, volume))
        timeline.originalAudioVolume = volume
        if volume < 1 {
            timeline.audioDucking = AudioDuckingSettings(enabled: false)
            if var plan = timeline.adaptiveSoundtrack {
                for index in plan.segments.indices { plan.segments[index].duckingEnabled = false }
                timeline.adaptiveSoundtrack = plan
            }
            for index in timeline.items.indices where timeline.items[index].kind == .video {
                var audio = timeline.items[index].effectiveAudioAdjustments
                audio.volume = min(1, audio.volume)
                audio.duckOthers = false
                timeline.items[index].audioAdjustments = audio
            }
        }
        for index in (timeline.audioClips ?? []).indices {
            guard let clip = timeline.audioClips?[index], isSource(clip) else { continue }
            timeline.audioClips?[index].adjustments.volume = volume
            if volume < 1 { timeline.audioClips?[index].adjustments.duckOthers = false }
        }
        return timeline
    }

    private static func isSource(_ clip: TimelineAudioClip) -> Bool {
        clip.assetID != nil && [.detached, .dialogue, .naturalSound].contains(clip.role)
    }
}
