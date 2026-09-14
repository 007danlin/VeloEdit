import Foundation
import AVFoundation
import CoreImage
import Testing
@testable import VeloEditCore

@Test func fitBackgroundPreservesShadowLevelsAndColor() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    let context = CIContext(options: [.workingColorSpace: space])
    var previous: Float = 0
    for level in [0.01, 0.03, 0.08, 0.16, 0.3] {
        let source = CIImage(color: CIColor(red: level, green: level * 0.8, blue: level * 0.6, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = SafeFitBackgroundRenderer.shade(source)
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
                           bounds: source.extent, format: .RGBAf, colorSpace: space)
        }
        #expect(pixel[0] > previous)
        #expect(pixel[0] < Float(level))
        #expect(pixel[0] > pixel[1] && pixel[1] > pixel[2])
        #expect(pixel[2] > 0)
        #expect(abs(pixel[3] - 1) < 0.001)
        previous = pixel[0]
    }
}

@Test func reducedCompositorSurfaceKeepsEntireCanvas() {
    let canvas = CGSize(width: 1080, height: 1920)
    for output in [CGSize(width: 1080, height: 1920), CGSize(width: 540, height: 960), CGSize(width: 304, height: 540)] {
        let transform = CompositorOutputGeometry.transform(canvas: canvas, destination: output)
        let mapped = CGRect(origin: .zero, size: canvas).applying(transform)
        #expect(abs(mapped.width - output.width) < 0.001)
        #expect(abs(mapped.height - output.height) < 0.001)
        let center = CGPoint(x: 540, y: 960).applying(transform)
        #expect(abs(center.x - output.width / 2) < 0.001)
        #expect(abs(center.y - output.height / 2) < 0.001)
    }
}

@Test func singleClipCompositionHasNoEmptyReservedTracks() async throws {
    let item = TimelineItem(kind: .title, sourceDuration: 0.3,
                            timelineStart: 0, timelineDuration: 0.3, title: "Frame")
    let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180,
                            frameRate: 10, items: [item])
    let playback = try await PlaybackEngine().build(timeline: timeline, assets: [])
    #expect(!playback.composition.tracks.isEmpty)
    #expect(playback.composition.tracks.allSatisfy { !$0.segments.isEmpty })
}
