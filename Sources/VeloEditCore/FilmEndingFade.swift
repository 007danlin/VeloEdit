import Foundation
import CoreImage
import AVFoundation

/// A movie-level finish, expressed on the rendered clock after transitions.
/// Keep one fully black output frame without adding time or truncating a clip.
struct FilmEndingFade {
    static let defaultDuration = 3.0

    /// Only automatic film finishing calls this. The explicit no-fade request
    /// is separate from the amount of decorative effects or cut transitions.
    static func finishing(_ source: Timeline, plan: StoryPlan) -> Timeline {
        let prompt = plan.prompt.lowercased()
        let disabled = ["без затемнения", "no fade", "without fade"].contains(where: prompt.contains)
        var result = source
        result.endingFadeDuration = disabled ? 0 : ((source.endingFadeDuration ?? 0) > 0
            ? source.endingFadeDuration : defaultDuration)
        if result.endingFadeDuration != source.endingFadeDuration {
            result.editorialReview = nil
            result.filmDeliveryReport = nil
            result.selectedContentReview = nil
        }
        return result
    }

    /// Older automatic edits copied the movie's audio finish onto their last
    /// selected clip. Migrate once, before that clip can move into the body.
    static func migratingLegacyClipAudio(_ source: Timeline) -> Timeline {
        guard source.movieEndingAudioVersion == nil else { return source }
        var result = source
        result.movieEndingAudioVersion = 1
        if let duration = source.endingFadeDuration, duration > 0,
           let index = result.items.lastIndex(where: { $0.overlay == nil }),
           result.items[index].candidateID != nil,
           abs(result.items[index].effectiveAudioAdjustments.fadeOut - duration) < 0.0001 {
            var audio = result.items[index].effectiveAudioAdjustments
            audio.fadeOut = 0
            result.items[index].audioAdjustments = audio
        }
        return result
    }

    let start: Double
    let end: Double

    static func expectsVisibleContent(atTimelineTime time: Double, timeline: Timeline) -> Bool {
        let movieDuration = TimelineTiming.playbackTime(forTimelineTime: timeline.duration, timeline: timeline)
        let fade = FilmEndingFade(duration: timeline.endingFadeDuration, movieDuration: movieDuration, frameRate: timeline.frameRate)
        let playbackTime = TimelineTiming.playbackTime(forTimelineTime: time, timeline: timeline)
        return (fade?.opacity(at: playbackTime) ?? 1) > 0.1
    }

    init?(duration: Double?, movieDuration: Double, frameRate: Double) {
        guard let duration, duration.isFinite, duration > 0,
              movieDuration.isFinite, movieDuration > 0,
              frameRate.isFinite, frameRate > 0 else { return nil }
        end = max(0, movieDuration - 1 / frameRate)
        start = max(0, end - duration)
    }

    func opacity(at time: Double) -> Double {
        guard time > start else { return 1 }
        guard time < end else { return 0 }
        let progress = (time - start) / max(0.000_001, end - start)
        return 1 - progress * progress * (3 - 2 * progress)
    }

    func applying(to image: CIImage, at time: Double) -> CIImage {
        let amount = opacity(at: time)
        guard amount < 1 else { return image }
        // Fade all composed layers together, including titles and overlays.
        // Retain opaque alpha so the final image is black in every player.
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0)
        ])
    }

    /// Multiply the completed music automation by the film's closing curve.
    /// Rebuild disjoint ramps instead of adding an overlapping fade, which
    /// AVFoundation can reject or let a later ducking release overwrite.
    func applying(to parameters: AVAudioMixInputParameters, movieDuration: Double) -> AVAudioMixInputParameters {
        let result = AVMutableAudioMixInputParameters()
        result.trackID = parameters.trackID
        result.audioTimePitchAlgorithm = parameters.audioTimePitchAlgorithm
        result.audioTapProcessor = parameters.audioTapProcessor
        for (a, b, range) in EditorialAudioMastering.envelopes(parameters, duration: movieDuration) {
            let rangeStart = range.start.seconds
            let rangeEnd = range.end.seconds
            func volume(at time: CMTime) -> Float {
                let progress = min(1, max(0, (time.seconds - rangeStart) / range.duration.seconds))
                return (a + (b - a) * Float(progress)) * Float(opacity(at: time.seconds))
            }
            // Keep existing automation exact before the finish and sample
            // only the curved tail at 60 Hz. Shared CMTime boundaries avoid
            // rounding gaps/overlaps, including at fractional frame rates.
            let boundaries = [rangeStart, start, end, rangeEnd]
                .filter { $0 >= rangeStart && $0 <= rangeEnd }
                .sorted()
            for (lower, upper) in zip(boundaries, boundaries.dropFirst()) where upper > lower {
                let steps = lower >= start && lower < end ? max(1, Int(ceil((upper - lower) * 60))) : 1
                var cursor = CMTime(seconds: lower, preferredTimescale: 48_000)
                for step in 1...steps {
                    let next = CMTime(seconds: lower + (upper - lower) * Double(step) / Double(steps), preferredTimescale: 48_000)
                    guard next > cursor else { continue }
                    result.setVolumeRamp(fromStartVolume: volume(at: cursor), toEndVolume: volume(at: next),
                                         timeRange: CMTimeRange(start: cursor, end: next))
                    cursor = next
                }
            }
        }
        return result
    }
}
