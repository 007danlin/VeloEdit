import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import VeloEditCore

/// Optional full-resolution evidence and a disposable project for UI checks.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_PREVIEW_AUDIT_OUTPUT"] != nil))
func renderTitleAndBackgroundAudit() async throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VELOEDIT_PREVIEW_AUDIT_OUTPUT"]!)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Backgrounds")
    let store = try ProjectStore(createAt: root.appendingPathComponent("Preview Audit.veloedit"), name: "Проверка титров и фонов")
    var assets: [MediaAsset] = []
    var clips: [TimelineItem] = []
    for (index, preset) in [BackgroundPreset.midnightGradient, .forest, .snow].enumerated() {
        let url = root.appendingPathComponent("\(preset.rawValue).png")
        try BackgroundPresetRenderer.render(preset, width: 1920, height: 1080,
            sourceImageURL: preset.bundledResourceFileName.map { resources.appendingPathComponent($0 + ".png") }, to: url)
        let asset = MediaAsset(originalURL: url, displayName: preset.localizedTitle, kind: .photo, byteSize: 1,
            contentHash: "\(preset.contentHashPrefix)1920x1080", metadata: MediaMetadata(width: 1920, height: 1080))
        assets.append(asset)
        clips.append(TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: 4,
            timelineStart: Double(index * 4), timelineDuration: 4, title: preset.localizedTitle))
    }
    let title = TitleTemplateRegistry.defaultTemplate(for: .title)!.makeTimelineItem(text: "НАЗВАНИЕ ПРОЕКТА", startTime: 0, duration: 3)
    let timeline = Timeline(storyPlanID: UUID(), items: clips, titleItems: [title], originalAudioVolume: 0)
    try await store.update { $0.assets = assets; $0.timelines = [timeline] }
    let pipeline = VeloEditPipeline(store: store)
    let playback = try await pipeline.makePlayback()
    let generator = AVAssetImageGenerator(asset: playback.composition)
    generator.videoComposition = playback.videoComposition
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    for (name, time) in [("gradient-preview", 3.5), ("forest-preview", 5.5), ("winter-preview", 9.5), ("title-preview", 1.5)] {
        let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        try save(image, to: root.appendingPathComponent(name + ".png"))
    }
    generator.videoComposition = TitleLibraryPreview.videoComposition(from: playback.videoComposition)
    let clean = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
    try save(clean, to: root.appendingPathComponent("title-library-clean.png"))
    #expect(clean.width == 1920 && clean.height == 1080)
}

private func save(_ image: CGImage, to url: URL) throws {
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}
