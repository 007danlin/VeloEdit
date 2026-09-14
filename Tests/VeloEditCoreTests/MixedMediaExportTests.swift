import Foundation
import Testing
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import VeloEditCore

/// Exercises the real importer, photo intermediates, preview compositor and
/// MP4 exporter together. No encoder/decode failures are silently skipped.
@Test func mixedMediaFilmPreservesEveryFrameAndClipOrder() async throws {
    let savedRoot = ProcessInfo.processInfo.environment["VELOEDIT_MIXED_QA_ROOT"]
    let root = savedRoot.map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-mixed-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { if savedRoot == nil { try? FileManager.default.removeItem(at: root) } }

    let blue = root.appendingPathComponent("blue.png")
    let orange = root.appendingPathComponent("landscape.jpg")
    let green = root.appendingPathComponent("green.png")
    let red = root.appendingPathComponent("portrait-exif.jpg")
    try mixedImage(blue, color: (0.1, 0.25, 0.85))
    try mixedImage(orange, color: (0.85, 0.5, 0.1), width: 240, height: 180)
    try mixedImage(green, color: (0.1, 0.75, 0.2))
    try mixedImage(red, color: (0.8, 0.12, 0.15), orientation: 6)
    var videoURLs: [URL] = []
    for (index, image) in [blue, green].enumerated() {
        let url = root.appendingPathComponent("video-\(index).mov")
        _ = try await StillImageVideoGenerator().generate(
            imageURL: image, duration: 2, width: 320, height: 180,
            frameRate: 30, destination: url, codec: .jpeg, motion: .panLeft
        )
        videoURLs.append(url)
    }
    let imported = await MediaImporter().importAssets(from: [videoURLs[0], orange, videoURLs[1], red])
    let assets = try imported.map { try $0.get() }
    let byURL = Dictionary(uniqueKeysWithValues: assets.map { ($0.originalURL, $0) })
    let orderedAssets = try [videoURLs[0], orange, videoURLs[1], red].map { try #require(byURL[$0]) }
    #expect(orderedAssets.map(\.kind) == [.video, .photo, .video, .photo])
    #expect(orderedAssets[3].displayDimensions?.width == 180)
    #expect(orderedAssets[3].displayDimensions?.height == 320)

    var items = orderedAssets.enumerated().map { index, asset in
        TimelineItem(assetID: asset.id, kind: asset.kind == .photo ? .photo : .video,
                     sourceStart: asset.kind == .video ? 0.25 : 0,
                     sourceDuration: index == 3 ? 1.17 : 1.15,
                     timelineStart: 0, timelineDuration: index == 3 ? 1.17 : 1.15,
                     effect: asset.kind == .photo ? ClipEffect.panRight.rawValue : nil,
                     videoAdjustments: VideoAdjustments(crop: .fit))
    }
    items[1].transition = TransitionStyle.crossDissolve.rawValue
    items[2].transition = TransitionStyle.crossDissolve.rawValue
    items = TimelineTiming.retimed(items)
    let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 30, items: items)
    let playback = try await PlaybackEngine().build(timeline: timeline, assets: assets, forceVideoComposition: true)
    #expect(playback.renderedItemCount == 4)
    #expect(playback.skippedItemIDs.isEmpty)
    let overlaps = items.indices.dropFirst().map {
        TimelineTiming.transitionOverlap(incoming: items[$0], previous: items[$0 - 1])
    }
    let expectedDuration = items.reduce(0) { $0 + $1.timelineDuration } - overlaps.reduce(0, +)
    #expect(abs(playback.duration - expectedDuration) < 0.002)

    let output = root.appendingPathComponent("mixed-film.mp4")
    let report = try await RenderEngine().render(timeline: timeline, assets: assets,
                                               quality: .maximum, destination: output)
    #expect(report.renderedItemCount == 4)
    #expect(report.skippedItemIDs.isEmpty)
    let exported = AVURLAsset(url: output)
    let duration = try await exported.load(.duration).seconds
    #expect(abs(duration - expectedDuration) <= 1 / 30.0)
    let track = try #require(try await exported.loadTracks(withMediaType: .video).first)
    let dimensions = try await track.load(.naturalSize)
    #expect(dimensions == CGSize(width: 320, height: 180))

    // Sequential decoding catches black/missing tail frames even when a
    // random-access image generator would seek back to the preceding frame.
    let reader = try AVAssetReader(asset: exported)
    let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    reader.add(readerOutput)
    try #require(reader.startReading())
    let context = CIContext()
    var count = 0
    var previousPTS = -1.0
    while let sample = readerOutput.copyNextSampleBuffer() {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        #expect(pts > previousPTS)
        if previousPTS >= 0 { #expect(pts - previousPTS < 1.5 / 30) }
        previousPTS = pts
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        let rgb = mixedAverage(CIImage(cvPixelBuffer: buffer), context: context)
        #expect(rgb.reduce(0, +) > 0.15, "Black frame at \(pts)s")
        count += 1
    }
    #expect(reader.status == .completed)
    #expect(abs(Double(count) - expectedDuration * 30) <= 1)

    let preview = AVAssetImageGenerator(asset: playback.composition)
    preview.videoComposition = playback.videoComposition
    let final = AVAssetImageGenerator(asset: exported)
    for generator in [preview, final] {
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
    }
    var start = 0.0
    // Each fixture has a distinct RGB channel order. Identify which clip is
    // visible independently of encoder/color-profile rounding.
    let expectedChannelOrder = [[2, 1, 0], [0, 1, 2], [1, 2, 0], [0, 2, 1]]
    for index in items.indices {
        if index > 0 { start -= overlaps[index - 1] }
        let time = CMTime(seconds: start + items[index].timelineDuration * 0.55, preferredTimescale: 600)
        let previewImage = try await preview.image(at: time).image
        let finalImage = try await final.image(at: time).image
        let region = CGRect(x: 150, y: 80, width: 20, height: 20)
        let previewRGB = mixedAverage(CIImage(cgImage: previewImage).cropped(to: region), context: context)
        let finalRGB = mixedAverage(CIImage(cgImage: finalImage).cropped(to: region), context: context)
        #expect([0, 1, 2].sorted { finalRGB[$0] > finalRGB[$1] } == expectedChannelOrder[index])
        for channel in 0..<3 {
            #expect(abs(finalRGB[channel] - previewRGB[channel]) < 0.08)
        }
        try mixedSave(finalImage, to: root.appendingPathComponent("frame-\(index).png"))
        start += items[index].timelineDuration
    }
}

private func mixedAverage(_ image: CIImage, context: CIContext) -> [Double] {
    let mean = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
    var pixel = [UInt8](repeating: 0, count: 4)
    pixel.withUnsafeMutableBytes {
        context.render(mean, toBitmap: $0.baseAddress!, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
    return pixel.prefix(3).map { Double($0) / 255 }
}

private func mixedImage(_ url: URL, color: (CGFloat, CGFloat, CGFloat), width: Int = 320,
                        height: Int = 180, orientation: Int = 1) throws {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: 0.95, alpha: 1))
    context.fill(CGRect(x: width / 8, y: height / 8, width: width / 8, height: height / 8))
    let image = try #require(context.makeImage())
    let type = url.pathExtension == "jpg" ? UTType.jpeg : UTType.png
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
}

private func mixedSave(_ image: CGImage, to url: URL) throws {
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
}
