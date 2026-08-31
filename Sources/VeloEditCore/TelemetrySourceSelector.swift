import Foundation

/// Chooses the strongest source per metric when a clip has embedded camera
/// telemetry plus one or more sidecars. GPMF remains the timing authority for
/// camera motion; FIT is preferred for sport sensors.
public struct TelemetrySourceSelector: Sendable {
    public init() {}

    public func bestSource(
        for kind: TelemetryWidgetKind,
        linkedAssetID: UUID,
        sources: [TelemetrySource]
    ) -> TelemetrySource? {
        sources
            .filter {
                $0.linkedAssetID == linkedAssetID &&
                $0.summary.supports(kind, presentation: kind.defaultPresentation)
            }
            .max { quality($0, for: kind) < quality($1, for: kind) }
    }

    public func bestGeneralSource(linkedAssetID: UUID, sources: [TelemetrySource]) -> TelemetrySource? {
        sources.filter { $0.linkedAssetID == linkedAssetID && $0.summary.hasTelemetry }
            .max { generalQuality($0) < generalQuality($1) }
    }

    public func availableKinds(linkedAssetID: UUID, sources: [TelemetrySource]) -> Set<TelemetryWidgetKind> {
        Set(sources.filter { $0.linkedAssetID == linkedAssetID }.flatMap { $0.summary.availableWidgetKinds })
    }

    private func quality(_ source: TelemetrySource, for kind: TelemetryWidgetKind) -> Double {
        var score = generalQuality(source)
        switch kind {
        case .heartRate, .cadence, .power, .leftRightBalance, .strideLength,
             .verticalOscillation, .groundContactTime, .calories:
            if source.format == .fit { score += 3.0 }
        case .gForce, .acceleration, .leanAngle, .heading, .compass,
             .cameraISO, .cameraAperture, .cameraShutter, .cameraFocalLength,
             .cameraEV, .cameraColorTemperature:
            if isEmbedded(source.format) { score += 3.2 }
        case .speedometer, .speedValue, .speedBar, .routeMap, .routeProgress,
             .coordinates, .satelliteStatus:
            if source.format == .embeddedGPMF { score += 2.8 }
            else if isEmbedded(source.format) { score += 2.1 }
            else if source.format == .gpx { score += 1.3 }
        default:
            break
        }
        return score
    }

    private func generalQuality(_ source: TelemetrySource) -> Double {
        let kinds = Double(source.summary.availableWidgetKinds.count)
        let sampleScore = min(2, log10(Double(max(1, source.summary.sampleCount))) * 0.7)
        return kinds * 0.18 + sampleScore + source.synchronization.confidence * 1.6 + (isEmbedded(source.format) ? 1.5 : 0)
    }

    private func isEmbedded(_ format: TelemetrySourceFormat) -> Bool {
        switch format {
        case .embeddedGPMF, .embeddedDJI, .embeddedInsta360, .embeddedCamera, .embeddedQuickTime:
            return true
        default:
            return false
        }
    }
}
