import Foundation
import Testing
@testable import VeloEditCore

@Suite struct EditorialChronologyTests {
    private func asset(_ name: String, date: Double? = nil, source: MediaDateSource? = .embeddedMetadata, camera: String? = nil) -> MediaAsset {
        MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/chronology-fixtures/\(name)"), kind: .video,
            byteSize: 1, contentHash: name, metadata: .init(duration: 120, creationDate: date.map(Date.init(timeIntervalSince1970:)),
                dateSource: source, dateConfidence: source == .embeddedMetadata ? 0.98 : 0.32, cameraModel: camera))
    }
    private func timeline(_ values: [(MediaAsset, Double)]) -> Timeline {
        Timeline(storyPlanID: UUID(), items: values.enumerated().map { index, value in
            TimelineItem(assetID: value.0.id, kind: .video, sourceStart: value.1, sourceDuration: 4,
                timelineStart: Double(index * 4), timelineDuration: 4)
        })
    }
    @Test func detectsReturnInsideSourceAcrossAnotherAngle() {
        let a = asset("A.mp4"), b = asset("B.mp4")
        let report = EditorialChronologyReport.inspect(timeline: timeline([(a, 50), (b, 0), (a, 10)]), assets: [a, b])
        #expect(report.findings.contains { $0.kind == .sourceTimeReversal && $0.confirmed })
        #expect(report.segments.count == 3)
    }
    @Test func usesMomentTimeRatherThanWholeFileOrderForSimultaneousCameras() {
        let a = asset("A.mp4", date: 1000, camera: "A"), b = asset("B.mp4", date: 1020, camera: "B")
        let report = EditorialChronologyReport.inspect(timeline: timeline([(a, 25), (b, 10), (a, 35)]), assets: [a, b])
        #expect(report.confirmedErrorCount == 0)
        #expect(report.findings.isEmpty)
        #expect(report.segments.map { $0.captureStart!.timeIntervalSince1970 } == [1025, 1030, 1035])
    }
    @Test func copiedFileDateCannotProveAReversal() {
        let a = asset("GX010002.MP4", date: 2000, source: .fileCreationDate)
        let b = asset("GX010001.MP4", date: 1000, source: .fileModificationDate)
        let report = EditorialChronologyReport.inspect(timeline: timeline([(a, 10), (b, 10)]), assets: [a, b])
        #expect(report.confirmedErrorCount == 0)
        #expect(report.segments.allSatisfy { $0.captureStart == nil })
        #expect(report.findings.contains { $0.kind == .unknownCaptureTime })
    }
    @Test func knownDifferentCameraClocksRemainUnresolved() {
        let a = asset("A.mp4", date: 2000, camera: "camera-A")
        let b = asset("B.mp4", date: 1000, camera: "camera-B")
        let report = EditorialChronologyReport.inspect(timeline: timeline([(a, 0), (b, 0)]), assets: [a,b])
        #expect(report.confirmedErrorCount == 0)
        #expect(report.findings.contains { $0.kind == .cameraClockAmbiguity && !$0.confirmed })
    }
    @Test func lateEpisodeBeforeEarlyEpisodeIsAnEmbeddedClockViolation() {
        let a = asset("early.mp4", date: 1000), b = asset("late.mp4", date: 2000)
        let report = EditorialChronologyReport.inspect(timeline: timeline([(b, 1), (a, 4)]), assets: [a,b])
        #expect(report.confirmedErrorCount == 1)
        #expect(report.findings[0].kind == .captureTimeReversal)
    }
}
