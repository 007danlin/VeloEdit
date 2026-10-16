import VeloEditCore

extension ViewerAdjustmentTool {
    /// Derived from the selected clip, including legacy projects with omitted defaults.
    /// Keep each section aligned with its controls and its section reset action.
    func isModified(in item: TimelineItem?) -> Bool {
        guard let item else { return false }
        let video = item.effectiveVideoAdjustments
        let audio = item.effectiveAudioAdjustments
        func differs(_ value: Double, from defaultValue: Double = 0) -> Bool {
            abs(value - defaultValue) >= 0.0001
        }
        switch self {
        case .colorBalance:
            return differs(video.brightness) || differs(video.warmth) || differs(video.tint ?? 0)
        case .colorCorrection:
            return differs(video.exposure ?? 0) || differs(video.contrast, from: 1)
                || differs(video.saturation, from: 1) || differs(video.highlights ?? 0)
                || differs(video.shadows ?? 0)
        case .crop:
            return video.crop != .fill || video.rotationQuarterTurns != 0
                || video.subjectReframe != nil || item.effect == ClipEffect.kenBurns.rawValue
        case .stabilization:
            return differs(video.stabilization ?? 0) || (video.rollingShutterCorrection ?? false)
        case .volume:
            return differs(audio.volume, from: 1) || audio.muted || (audio.normalize ?? false)
                || (audio.duckOthers ?? false) || differs(audio.duckingAmount ?? 0.5, from: 0.5)
        case .noiseReduction:
            return differs(audio.noiseReduction ?? 0) || (audio.eqPreset ?? .flat) != .flat
        case .speed:
            return differs(item.speed, from: 1) || item.speedRamp != nil || item.isReversed
                || (video.smoothSlowMotion ?? false) || !(audio.preservePitch ?? true)
        case .filters:
            return video.filter != .none || differs(video.filterIntensity ?? 1, from: 1)
                || (audio.effect ?? AudioEffect.none) != .none
        case .information:
            return false
        }
    }
}
