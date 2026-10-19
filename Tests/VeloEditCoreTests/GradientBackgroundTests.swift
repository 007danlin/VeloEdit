import CoreGraphics
import Foundation
import Testing
@testable import VeloEditCore

struct GradientBackgroundTests {
    @Test func gradientDitheringPreservesDirectionColorAndDeterminism() throws {
        let size = 512
        let preset = BackgroundPreset.grayGradient
        let image = try BackgroundPresetRenderer.makeImage(preset, width: size, height: size)
        let repeated = try BackgroundPresetRenderer.makeImage(preset, width: size, height: size)
        let data = try #require(image.dataProvider?.data) as Data
        #expect(data == repeated.dataProvider?.data as Data?)
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors = preset.colors.map { CGColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
        let gradient = try #require(CGGradient(colorsSpace: context.colorSpace, colors: colors as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
        let reference = context.data!.assumingMemoryBound(to: UInt8.self)
        var changed = 0
        var maximumError = 0
        var opaque = true
        for y in 0..<size {
            for x in 0..<size {
                let offset = y * image.bytesPerRow + x * 4
                let expected = Int(reference[y * size * 4 + x * 4])
                for channel in 0..<3 {
                    maximumError = max(maximumError, abs(Int(data[offset + channel]) - Int(reference[y * size * 4 + x * 4 + channel])))
                }
                opaque = opaque && data[offset + 3] == 255
                if Int(data[offset]) != expected { changed += 1 }
            }
        }
        #expect(maximumError <= 2)
        #expect(opaque)
        #expect(changed > size * size / 10)
        // Equal ideal brightness along a diagonal must not form a flat band.
        let diagonal = Set((64..<448).map { data[$0 * image.bytesPerRow + (size - 1 - $0) * 4] })
        #expect(diagonal.count == 2)
    }

    @Test func existingGradientIsRegeneratedWithoutChangingTimelineEdits() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try ProjectStore(createAt: url, name: "Gradient migration")
        let legacy = MediaAsset(originalURL: url.appendingPathComponent("old.png"), kind: .photo, byteSize: 1,
            contentHash: "veloedit-background-v3-midnightGradient-320x180",
            metadata: MediaMetadata(width: 320, height: 180))
        let clip = TimelineItem(assetID: legacy.id, kind: .photo, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
        let timeline = Timeline(storyPlanID: UUID(), items: [clip], titleItems: [
            TitleTimelineItem(kind: .title, text: "Мой текст", startTime: 0, duration: 4)
        ])
        try await store.update { $0.assets = [legacy]; $0.timelines = [timeline] }
        let pipeline = VeloEditPipeline(store: store)
        let before = await pipeline.snapshot()
        try await pipeline.migrateLegacyBuiltInBackgroundAssets()
        let manifest = await pipeline.snapshot()
        let migrated = try #require(manifest.assets.first)
        #expect(migrated.id == legacy.id)
        #expect(migrated.contentHash.hasPrefix("veloedit-background-v4-"))
        #expect(migrated.originalURL.lastPathComponent.contains("-v4-"))
        #expect(FileManager.default.fileExists(atPath: migrated.originalURL.path))
        #expect(manifest.timelines == before.timelines)
        try await pipeline.migrateLegacyBuiltInBackgroundAssets()
        #expect(await pipeline.snapshot().assets == manifest.assets)
    }

    @Test func backgroundThumbnailsAreDistinctAndRefreshWhenArtworkChanges() {
        let paths = CachePaths(root: URL(fileURLWithPath: "/tmp/cache"))
        let assets = BackgroundPreset.allCases.map {
            MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/\($0.rawValue).png"), kind: .photo, byteSize: 1,
                contentHash: "\($0.contentHashPrefix)1920x1080", metadata: MediaMetadata())
        }
        #expect(Set(assets.map { paths.thumbnail(for: $0) }).count == assets.count)
        let clip = TimelineItem(kind: .photo, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
        for preset in [BackgroundPreset.forest, .snow, .midnightGradient] {
            var old = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/old.png"), kind: .photo, byteSize: 1,
                contentHash: "veloedit-background-v3-\(preset.rawValue)-1920x1080", metadata: MediaMetadata())
            let thumbnail = paths.thumbnail(for: old)
            let filmstrip = paths.timelineFilmstrip(for: clip, asset: old, sampleCount: 5)
            old.contentHash = "\(preset.contentHashPrefix)1920x1080"
            #expect(paths.thumbnail(for: old) != thumbnail)
            #expect(paths.timelineFilmstrip(for: clip, asset: old, sampleCount: 5) != filmstrip)
        }
    }
}
