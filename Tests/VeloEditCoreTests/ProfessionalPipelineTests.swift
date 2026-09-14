import Foundation
import AVFoundation
import Testing
@testable import VeloEditCore

private func professionalAsset(
    id: UUID = UUID(),
    url: URL,
    range: DynamicRange,
    transfer: String? = nil,
    bitDepth: Int? = nil
) -> MediaAsset {
    MediaAsset(
        id: id,
        originalURL: url,
        kind: .video,
        byteSize: 4,
        contentHash: "test",
        metadata: MediaMetadata(
            duration: 4,
            width: 3840,
            height: 2160,
            frameRate: 30,
            codec: "hvc1",
            dynamicRange: range,
            colorPrimaries: range == .hdr ? "ITU_R_2020" : "ITU_R_709_2",
            transferFunction: transfer,
            yCbCrMatrix: range == .hdr ? "ITU_R_2020" : "ITU_R_709_2",
            bitDepth: bitDepth,
            hasAudio: true
        )
    )
}

private func professionalTimeline(assetIDs: [UUID], titles: [TitleTimelineItem] = []) -> Timeline {
    let items = assetIDs.enumerated().map { index, id in
        TimelineItem(
            assetID: id,
            kind: .video,
            sourceStart: 0,
            sourceDuration: 4,
            timelineStart: Double(index * 4),
            timelineDuration: 4
        )
    }
    return Timeline(storyPlanID: UUID(), width: 3840, height: 2160, frameRate: 30, items: items, titleItems: titles)
}

@Test func hdrColorPolicyPreservesPQAndTenBit() {
    let id = UUID()
    let asset = professionalAsset(id: id, url: URL(fileURLWithPath: "/tmp/hdr.mov"), range: .hdr, transfer: "SMPTE_ST_2084_PQ", bitDepth: 10)
    let profile = VideoColorPipeline.profile(timeline: professionalTimeline(assetIDs: [id]), assets: [asset])
    #expect(profile.dynamicRange == .hdr)
    #expect(profile.transferFunction == .pq)
    #expect(profile.bitDepth >= 10)
    #expect(!profile.containsMixedDynamicRange)
}

@Test func mixedHDRSDRChoosesManagedHDRWorkingProfile() {
    let hdrID = UUID()
    let sdrID = UUID()
    let assets = [
        professionalAsset(id: hdrID, url: URL(fileURLWithPath: "/tmp/hdr.mov"), range: .hdr, transfer: "ITU_R_2100_HLG", bitDepth: 10),
        professionalAsset(id: sdrID, url: URL(fileURLWithPath: "/tmp/sdr.mov"), range: .sdr, transfer: "ITU_R_709_2", bitDepth: 8)
    ]
    let profile = VideoColorPipeline.profile(timeline: professionalTimeline(assetIDs: [hdrID, sdrID]), assets: assets)
    #expect(profile.dynamicRange == .hdr)
    #expect(profile.transferFunction == .hlg)
    #expect(profile.containsMixedDynamicRange)
}

@Test func oldMediaMetadataDecodesWithoutColorTags() throws {
    let data = Data(#"{"dynamicRange":"sdr","hasAudio":false,"orientationDegrees":0}"#.utf8)
    let metadata = try JSONDecoder().decode(MediaMetadata.self, from: data)
    #expect(metadata.dynamicRange == .sdr)
    #expect(metadata.colorPrimaries == nil)
    #expect(metadata.transferFunction == nil)
    #expect(metadata.bitDepth == nil)
}

@Test func exportPreflightBlocksMissingSourceAndWarnsAboutUnsafeTitle() async {
    let id = UUID()
    var style = TitleStyle()
    style.xPosition = 0.01
    let title = TitleTimelineItem(kind: .title, text: "За краем", startTime: 0, duration: 2, style: style)
    let timeline = professionalTimeline(assetIDs: [id], titles: [title])
    let asset = professionalAsset(id: id, url: URL(fileURLWithPath: "/definitely-missing/source.mov"), range: .sdr)
    let report = await ExportPreflight().inspect(
        timeline: timeline,
        assets: [asset],
        destination: FileManager.default.temporaryDirectory.appendingPathComponent("movie.mp4"),
        quality: .final4K
    )
    #expect(!report.canExport)
    #expect(report.issues.contains { $0.kind == .missingSource && $0.severity == .blocking })
    #expect(report.issues.contains { $0.kind == .unsafeTitle && $0.severity == .warning })
}

@Test func persistentJobStateSurvivesAStoreRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let state = PersistentJobState(kind: .analysis, stage: .processing, completedUnits: 17, totalUnits: 100, resumableKey: "asset-batch")
    try await PersistentJobStateStore(directory: root).save(state)
    let restored = await PersistentJobStateStore(directory: root).unfinishedStates()
    #expect(restored.count == 1)
    #expect(restored.first?.id == state.id)
    #expect(restored.first?.completedUnits == 17)
    #expect(restored.first?.stage == .processing)
}

@Test func exportPreflightDoesNotTreatAPFSZeroCapacityHintAsFullDisk() async {
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("nested/movie.mp4")
    let timeline = professionalTimeline(assetIDs: [])
    let report = await ExportPreflight().inspect(
        timeline: timeline,
        assets: [],
        destination: destination,
        quality: .maximum
    )
    #expect(report.availableBytes == nil || report.availableBytes! > 0)
    #expect(!report.issues.contains { $0.kind == .insufficientDiskSpace })
}

@Test func renderUsesExplicitCodecAndPreservesPortraitGeometry() {
    var timeline = professionalTimeline(assetIDs: [])
    timeline.width = 1_920
    timeline.height = 1_080
    #expect(ExportVideoSettings(timeline: timeline, quality: .final1080p).codec == .h264)
    timeline.width = 1_080
    timeline.height = 1_920
    #expect(ExportVideoSettings(timeline: timeline, quality: .final1080p).width == 1080)
}

@Test func exportReserveMatchesActualSDRDeliveryForHDRSources() {
    let timeline = professionalTimeline(assetIDs: [UUID()])
    let sdr = ExportPreflight.estimatedOutputBytes(timeline: timeline, quality: .maximum, profile: .rec709)
    let hdr = ExportPreflight.estimatedOutputBytes(
        timeline: timeline,
        quality: .maximum,
        profile: VideoColorProfile(dynamicRange: .hdr, transferFunction: .hlg, bitDepth: 10)
    )
    #expect(hdr == sdr)
}

@Test func previewExportContractAllowsResolutionChangeButRejectsFPSOrColorMismatch() {
    let id = UUID()
    let asset = professionalAsset(id: id, url: URL(fileURLWithPath: "/tmp/source.mov"), range: .hdr, transfer: "ITU_R_2100_HLG", bitDepth: 10)
    let previewTimeline = professionalTimeline(assetIDs: [id])
    var exportTimeline = previewTimeline
    exportTimeline.width = 1920
    exportTimeline.height = 1080
    let preview = PreviewExportSignature(timeline: previewTimeline, assets: [asset])
    let matchingExport = PreviewExportSignature(timeline: exportTimeline, assets: [asset])
    #expect(PreviewExportConsistencyContract.issues(preview: preview, export: matchingExport).isEmpty)

    exportTimeline.frameRate = 60
    let mismatchedExport = PreviewExportSignature(timeline: exportTimeline, assets: [asset])
    #expect(PreviewExportConsistencyContract.issues(preview: preview, export: mismatchedExport).contains { $0.contains("FPS") })
}
