import Foundation

/// A compact, model-independent temporal observation. Automatic learned
/// evaluators can feed the same contract from optical-flow/audio models
/// without changing Candidate or Story Engine.
public struct MomentSignal: Hashable, Sendable {
    public var timestamp: Double
    public var motion: Double
    public var interest: Double
    public var semantic: Double
    public var audioOnset: Double
    public var telemetry: Double
    public var audioEvent: Double
    public var subject: Double
    public var speechBoundary: Double
    public var vlm: Double

    public init(timestamp: Double, motion: Double, interest: Double, semantic: Double, audioOnset: Double = 0, telemetry: Double = 0, audioEvent: Double = 0, subject: Double = 0, speechBoundary: Double = 0, vlm: Double = 0) {
        self.timestamp = max(0, timestamp)
        self.motion = motion.clamped01
        self.interest = interest.clamped01
        self.semantic = semantic.clamped01
        self.audioOnset = audioOnset.clamped01
        self.telemetry = telemetry.clamped01
        self.audioEvent = audioEvent.clamped01
        self.subject = subject.clamped01
        self.speechBoundary = speechBoundary.clamped01
        self.vlm = vlm.clamped01
    }

    public var activity: Double {
        (motion * 0.23 + interest * 0.17 + semantic * 0.11 + audioOnset * 0.09
            + telemetry * 0.14 + audioEvent * 0.15 + subject * 0.07
            + speechBoundary * 0.04 + vlm * 0.08).clamped01
    }
}

public protocol MomentBoundaryRefining: Sendable {
    func refine(around timestamp: Double, signals: [MomentSignal], sourceDuration: Double, nominalDuration: Double) -> MomentBoundary
}

/// Finds the local action peak, walks backwards through anticipation and
/// forwards through completion/reaction. It is deterministic and bounded, so
/// a sparse or noisy signal cannot consume an entire source clip.
public struct MomentBoundaryRefiner: MomentBoundaryRefining, Sendable {
    public init() {}

    public func refine(around timestamp: Double, signals: [MomentSignal], sourceDuration: Double, nominalDuration: Double) -> MomentBoundary {
        let duration = max(0.1, sourceDuration)
        let nominal = min(duration, max(1.2, nominalDuration))
        let radius = min(10, max(2.5, nominal * 1.15))
        let local = signals
            .filter { abs($0.timestamp - timestamp) <= radius }
            .sorted { $0.timestamp < $1.timestamp }
        guard !local.isEmpty else {
            let start = max(0, min(duration - nominal, timestamp - nominal * 0.45))
            let peak = min(duration, timestamp)
            let end = min(duration, start + nominal)
            return MomentBoundary(
                anticipationStart: start,
                actionStart: max(start, peak - nominal * 0.18),
                peakTime: peak,
                actionEnd: min(end, peak + nominal * 0.16),
                reactionStart: min(end, peak + nominal * 0.16),
                reactionEnd: end,
                completionEnd: end,
                confidence: 0.18,
                evidence: ["fallback: sparse temporal evidence"]
            )
        }

        let peak = local.max { lhs, rhs in
            let leftProximity = max(0, 1 - abs(lhs.timestamp - timestamp) / radius) * 0.10
            let rightProximity = max(0, 1 - abs(rhs.timestamp - timestamp) / radius) * 0.10
            return lhs.activity + leftProximity < rhs.activity + rightProximity
        } ?? local[local.count / 2]
        let sortedActivity = local.map(\.activity).sorted()
        let baseline = sortedActivity[sortedActivity.count / 2]
        let peakThreshold = max(0.24, baseline * 0.72, peak.activity * 0.48)
        let anticipationThreshold = max(0.12, baseline * 0.54)
        let maximumLead = min(4.5, max(0.7, nominal * 0.42))
        let maximumTail = min(5.5, max(0.9, nominal * 0.56))

        var start = max(0, peak.timestamp - min(1.0, maximumLead))
        for signal in local.reversed() where signal.timestamp < peak.timestamp && peak.timestamp - signal.timestamp <= maximumLead {
            start = signal.timestamp
            if signal.activity <= anticipationThreshold { break }
        }

        var end = min(duration, peak.timestamp + min(1.2, maximumTail))
        var sawCompletion = false
        for signal in local where signal.timestamp > peak.timestamp && signal.timestamp - peak.timestamp <= maximumTail {
            end = signal.timestamp
            if signal.activity <= peakThreshold {
                sawCompletion = true
                break
            }
        }
        if !sawCompletion { end = min(duration, max(end, peak.timestamp + maximumTail * 0.72)) }

        let minimum = min(duration, max(1.2, nominal * 0.42))
        if end - start < minimum {
            let missing = minimum - (end - start)
            start = max(0, start - missing * 0.42)
            end = min(duration, end + missing * 0.58)
        }
        let maximum = min(duration, max(2.2, nominal * 1.35))
        if end - start > maximum {
            start = max(0, peak.timestamp - maximum * 0.42)
            end = min(duration, start + maximum)
        }

        let temporalCoverage = min(1, Double(local.count) / 6)
        let prominence = max(0, peak.activity - baseline)
        let confidence = min(1, 0.28 + temporalCoverage * 0.30 + prominence * 0.68 + (sawCompletion ? 0.14 : 0))
        var evidence = ["peak activity \(Int((peak.activity * 100).rounded()))%", "anticipation → peak → completion"]
        if peak.telemetry >= 0.35 { evidence.append("telemetry-confirmed peak") }
        if peak.audioOnset >= 0.35 { evidence.append("audio-confirmed peak") }
        if peak.audioEvent >= 0.35 { evidence.append("audio-event-confirmed peak") }
        if peak.subject >= 0.35 { evidence.append("subject-confirmed peak") }
        if local.contains(where: { $0.speechBoundary >= 0.35 }) { evidence.append("speech phrase boundary") }
        if peak.vlm >= 0.58 { evidence.append("VLM semantic evidence") }
        let activeBeforePeak = local.filter {
            $0.timestamp <= peak.timestamp && $0.timestamp >= start && $0.activity >= anticipationThreshold
        }
        let activeAfterPeak = local.filter {
            $0.timestamp >= peak.timestamp && $0.timestamp <= end && $0.activity >= peakThreshold
        }
        let actionStart = max(start, activeBeforePeak.first?.timestamp ?? peak.timestamp - min(0.35, nominal * 0.12))
        let actionEnd = min(end, max(peak.timestamp, activeAfterPeak.last?.timestamp ?? peak.timestamp + min(0.38, nominal * 0.14)))
        let reactionStart = actionEnd
        let protectedConfidence = min(1, confidence * 0.88 + max(peak.audioEvent, peak.audioOnset) * 0.12)
        let protectedReason = peak.audioEvent >= 0.35 || peak.audioOnset >= 0.35
            ? "Не разрывать действие и подтверждающий его звуковой акцент"
            : "Не разрывать действие вокруг подтверждённого peak"
        let protected = actionEnd - actionStart >= 0.08
            ? [EditorialSourceRange(start: actionStart, end: actionEnd, phase: .action, reason: protectedReason, confidence: protectedConfidence)]
            : []
        return MomentBoundary(
            anticipationStart: start,
            actionStart: actionStart,
            peakTime: peak.timestamp,
            actionEnd: actionEnd,
            reactionStart: reactionStart,
            reactionEnd: end,
            completionEnd: end,
            doNotCutRanges: protected,
            confidence: confidence,
            evidence: evidence
        )
    }
}
