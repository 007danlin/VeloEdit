import Foundation
import Testing
@testable import VeloEditCore

@Test func smartTelemetryIsATimedAccentAtTheRealMaximumSpeed() throws {
    let samples = (0...10).map { second in
        TelemetrySample(timestamp: Double(second), speedMetersPerSecond: second == 6 ? 24 : Double(second) * 0.6)
    }
    let summary = TelemetrySummary(
        sampleCount: samples.count,
        maxSpeedMetersPerSecond: 24,
        timedSamples: samples,
        streams: ["SPEED"]
    )
    let clip = TimelineItem(kind: .video, sourceStart: 0, sourceDuration: 10, timelineStart: 20, timelineDuration: 10, storyRole: .action)
    let decision = try #require(SmartTelemetryEngine().decide(SmartTelemetryContext(
        telemetry: summary,
        clip: clip,
        tags: ["cycling", "action"],
        role: .action,
        explicitRequest: "Покажи максимальную скорость"
    )))
    #expect(decision.sourceMoment == 6)
    #expect(decision.timelineStart >= 25 && decision.timelineStart < 26.5)
    #expect(decision.duration <= 3.1)
    #expect(decision.duration < clip.timelineDuration)
    #expect(decision.settings.effectiveStyle.isOVRLEYTemplate)
    #expect(decision.settings.resolvedWidgets.first?.kind == .speedValue)
    #expect(decision.explanation.joined(separator: " ").contains("86 км/ч"))
}

@Test func smartTelemetryAvoidsTheSubjectAndItsDirectionOfTravel() throws {
    let samples = [
        TelemetrySample(timestamp: 0, gForce: 1, gForceX: 0, gForceY: 0),
        TelemetrySample(timestamp: 2, gForce: 2.4, gForceX: 1.1, gForceY: 0.8),
        TelemetrySample(timestamp: 4, gForce: 1, gForceX: 0, gForceY: 0)
    ]
    let summary = TelemetrySummary(sampleCount: 3, maxGForce: 2.4, timedSamples: samples, streams: ["G-FORCE"])
    let clip = TimelineItem(kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4, storyRole: .climax)
    let person = NormalizedRegion(x: 0.60, y: 0.48, width: 0.34, height: 0.48)
    let decision = try #require(SmartTelemetryEngine().decide(SmartTelemetryContext(
        telemetry: summary,
        clip: clip,
        role: .climax,
        avoidRegions: [person],
        subjectMovementX: 0.7,
        sceneComplexity: 0.82,
        explicitRequest: "Покажи перегрузку в сильном повороте"
    )))
    let layout = try #require(decision.settings.resolvedWidgets.first)
    #expect(layout.kind == .gForce)
    #expect(layout.effectivePresentation == .gForce)
    #expect(layout.x + layout.width <= 0.5)
    #expect(layout.width <= 0.19)
    #expect(decision.explanation.joined(separator: " ").contains("главным объектом"))
}

@Test func smartTelemetryDoesNotPromoteQuietSensorNoiseWithoutARequest() {
    let samples = (0...8).map { TelemetrySample(timestamp: Double($0), speedMetersPerSecond: 1 + Double($0) * 0.01) }
    let summary = TelemetrySummary(sampleCount: samples.count, timedSamples: samples, streams: ["SPEED"])
    let clip = TimelineItem(kind: .video, sourceDuration: 8, timelineStart: 0, timelineDuration: 8)
    #expect(SmartTelemetryEngine().decide(SmartTelemetryContext(telemetry: summary, clip: clip)) == nil)
}

@Test func telemetrySourceSelectionUsesGPMFForMotionAndFITForSportSensors() throws {
    let assetID = UUID()
    let embedded = TelemetrySource(
        displayName: "GoPro",
        format: .embeddedGPMF,
        linkedAssetID: assetID,
        summary: TelemetrySummary(sampleCount: 2, maxSpeedMetersPerSecond: 12, timedSamples: [
            TelemetrySample(timestamp: 0, speedMetersPerSecond: 4, gForce: 1),
            TelemetrySample(timestamp: 1, speedMetersPerSecond: 12, gForce: 2)
        ]),
        synchronization: TelemetrySynchronization(method: .embeddedTimecode, confidence: 1)
    )
    let fit = TelemetrySource(
        displayName: "ride.fit",
        format: .fit,
        linkedAssetID: assetID,
        summary: TelemetrySummary(sampleCount: 2, timedSamples: [
            TelemetrySample(timestamp: 0, speedMetersPerSecond: 4, heartRateBPM: 130, cadenceRPM: 84, powerWatts: 220),
            TelemetrySample(timestamp: 1, speedMetersPerSecond: 10, heartRateBPM: 156, cadenceRPM: 96, powerWatts: 340)
        ]),
        synchronization: TelemetrySynchronization(method: .telemetryTimestamp, confidence: 0.9)
    )
    let selector = TelemetrySourceSelector()
    #expect(selector.bestSource(for: .speedValue, linkedAssetID: assetID, sources: [fit, embedded])?.id == embedded.id)
    #expect(selector.bestSource(for: .heartRate, linkedAssetID: assetID, sources: [embedded, fit])?.id == fit.id)
    #expect(selector.bestSource(for: .power, linkedAssetID: assetID, sources: [embedded, fit])?.id == fit.id)
}

@Test func customTelemetryFieldsSurviveEncodingAndInterpolation() throws {
    let summary = TelemetrySummary(sampleCount: 2, timedSamples: [
        TelemetrySample(timestamp: 0, customFields: ["battery_voltage": 12]),
        TelemetrySample(timestamp: 2, customFields: ["battery_voltage": 14, "motor_temp": 71])
    ])
    let restored = try JSONDecoder().decode(TelemetrySummary.self, from: JSONEncoder().encode(summary))
    #expect(restored.sample(at: 1)?.customFields?["battery_voltage"] == 13)
    #expect(restored.sample(at: 1)?.customFields?["motor_temp"] == 71)
}

@Test func csvColumnMappingNormalizesTimeCoordinatesAndUnitsWithoutDroppingOriginals() throws {
    let source = TelemetrySource(
        displayName: "logger.csv",
        format: .csv,
        summary: TelemetrySummary(sampleCount: 2, timedSamples: [
            TelemetrySample(timestamp: 0, customFields: [
                "unix": 1_777_777_000,
                "lat_custom": 55.75,
                "lon_custom": 37.61,
                "velocity": 36
            ]),
            TelemetrySample(timestamp: 1, customFields: [
                "unix": 1_777_777_002,
                "lat_custom": 55.76,
                "lon_custom": 37.62,
                "velocity": 54
            ])
        ])
    )
    let mapped = TelemetryEngine().applyingCSVMapping(to: source, mapping: [
        "unix": .timestamp,
        "lat_custom": .latitude,
        "lon_custom": .longitude,
        "velocity": .speedKilometersPerHour
    ])

    let samples = try #require(mapped.summary.timedSamples)
    #expect(mapped.startDate == Date(timeIntervalSince1970: 1_777_777_000))
    #expect(samples.map(\.timestamp) == [0, 2])
    #expect(samples[0].coordinate == TelemetryCoordinate(latitude: 55.75, longitude: 37.61))
    #expect(samples[1].speedMetersPerSecond == 15)
    #expect(samples[1].customFields?["velocity"] == 54)
}
