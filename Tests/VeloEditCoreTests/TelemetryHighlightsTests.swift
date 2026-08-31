import Foundation
import Testing
@testable import VeloEditCore

@Test func telemetryDetectorFindsTheSynchronizedActionPeak() {
    let samples = [
        TelemetrySample(timestamp: 0, speedMetersPerSecond: 0, altitudeMeters: 100, gForce: 1),
        TelemetrySample(timestamp: 1, speedMetersPerSecond: 2, altitudeMeters: 100, gForce: 1.02),
        TelemetrySample(timestamp: 2, speedMetersPerSecond: 18, altitudeMeters: 106, gForce: 2.8),
        TelemetrySample(timestamp: 3, speedMetersPerSecond: 20, altitudeMeters: 107, gForce: 1.1),
        TelemetrySample(timestamp: 10, speedMetersPerSecond: 20, altitudeMeters: 107, gForce: 1)
    ]
    let telemetry = TelemetrySummary(hasGPMF: true, timedSamples: samples, streams: ["GPS5", "ACCL"])
    let detector = TelemetryHighlightDetector()
    let ranked = detector.rankedMoments(from: telemetry, duration: 12, limit: 3, minimumGap: 0.5)

    #expect(ranked.first?.timestamp == 2)
    #expect(ranked.first?.tags.contains("acceleration") == true)
    #expect(ranked.first?.tags.contains("g-force") == true)
    #expect(ranked.first?.tags.contains("elevation-change") == true)
    #expect(detector.strongestMoment(in: 1.5...2.5, moments: detector.moments(from: telemetry))?.timestamp == 2)
}

@Test func telemetryDetectorDoesNotPromoteSensorNoise() {
    var samples: [TelemetrySample] = []
    for index in 0..<12 {
        let speed = 1.0 + (index.isMultiple(of: 2) ? 0 : 0.02)
        let altitude = 100.0 + (index.isMultiple(of: 2) ? 0 : 0.01)
        let force = 1.0 + (index.isMultiple(of: 2) ? 0 : 0.01)
        samples.append(TelemetrySample(
            timestamp: Double(index),
            speedMetersPerSecond: speed,
            altitudeMeters: altitude,
            gForce: force
        ))
    }
    let telemetry = TelemetrySummary(hasGPMF: true, timedSamples: samples, streams: ["GPS5", "ACCL"])
    let ranked = TelemetryHighlightDetector().rankedMoments(from: telemetry, limit: 4, minimumGap: 1)
    #expect(ranked.isEmpty)
}

@Test func telemetryTimelineRemainsBackwardCompatibleWhenMissing() throws {
    let legacy = """
    {"hasGPMF":true,"sampleCount":1,"streams":["GPS5"]}
    """
    let decoded = try JSONDecoder().decode(TelemetrySummary.self, from: Data(legacy.utf8))
    #expect(decoded.hasGPMF)
    #expect(decoded.timedSamples == nil)
}

@Test func telemetryWordsInTheBriefPrioritizeSensorEvents() {
    let constraints = PromptInterpreter().interpret(
        prompt: "Покажи лучший разгон, прыжок и максимальные перегрузки по телеметрии",
        preset: .highlight
    )
    #expect(constraints.includeTags.contains("high-speed"))
    #expect(constraints.includeTags.contains("elevation-change"))
    #expect(constraints.includeTags.contains("g-force"))
    #expect(constraints.includeTags.contains("telemetry-event"))
}
