import Foundation
import AVFoundation

/// A soundtrack repeat overlaps the previous ending instead of jumping from
/// the quiet tail to a loud first beat. This only mixes playback tracks; it
/// never changes the video cut or invents a confidently measured beat grid.
struct MusicLoopWindow {
    var start: Double
    var end: Double
    var fadeIn: Double
    var fadeOut: Double

    func gain(at time: Double) -> Float {
        guard time >= start, time <= end else { return 0 }
        let incoming = fadeIn > 0 ? min(1, max(0, (time - start) / fadeIn)) : 1
        let outgoing = fadeOut > 0 ? min(1, max(0, (end - time) / fadeOut)) : 1
        return Float(incoming * outgoing)
    }

    /// Multiply, rather than overwrite, the speech-ducking automation. The
    /// resulting ramps are disjoint, as required by AVFoundation.
    func applying(to parameters: AVAudioMixInputParameters, movieDuration: Double) -> AVAudioMixInputParameters {
        let result = AVMutableAudioMixInputParameters()
        result.trackID = parameters.trackID
        result.audioTimePitchAlgorithm = parameters.audioTimePitchAlgorithm
        result.audioTapProcessor = parameters.audioTapProcessor
        for (a, b, range) in EditorialAudioMastering.envelopes(parameters, duration: movieDuration) {
            let lower = range.start.seconds, upper = range.end.seconds
            func volume(_ time: CMTime) -> Float {
                let fraction = min(1, max(0, (time.seconds - lower) / range.duration.seconds))
                return (a + (b - a) * Float(fraction)) * gain(at: time.seconds)
            }
            let boundaries = Array(Set([lower, upper, start, start + fadeIn, end - fadeOut, end]
                .filter { $0 >= lower && $0 <= upper })).sorted()
            for (lo, hi) in zip(boundaries, boundaries.dropFirst()) where hi > lo {
                let changes = (lo < start + fadeIn && hi > start) || (lo < end && hi > end - fadeOut)
                let steps = changes ? max(1, Int(ceil((hi - lo) * 60))) : 1
                var cursor = CMTime(seconds: lo, preferredTimescale: 48_000)
                for step in 1...steps {
                    let next = CMTime(seconds: lo + (hi - lo) * Double(step) / Double(steps), preferredTimescale: 48_000)
                    guard next > cursor else { continue }
                    result.setVolumeRamp(fromStartVolume: volume(cursor), toEndVolume: volume(next),
                        timeRange: CMTimeRange(start: cursor, end: next))
                    cursor = next
                }
            }
        }
        return result
    }
}
