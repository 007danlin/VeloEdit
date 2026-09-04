import Foundation
import Testing
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import VeloEditCore

@Test func exportGeometryPreservesPortraitAndLandscapeAspectRatios() {
    let empty: [TimelineItem] = []
    let portrait = Timeline(storyPlanID: UUID(), width: 1_080, height: 1_920, items: empty)
    let landscape = Timeline(storyPlanID: UUID(), width: 1_920, height: 1_080, items: empty)
    let cinematic = Timeline(storyPlanID: UUID(), width: 2_560, height: 1_080, items: empty)

    let portrait1080 = RenderGeometryPolicy.timeline(portrait, for: .final1080p)
    let portrait4K = RenderGeometryPolicy.timeline(portrait, for: .final4K)
    let landscape720 = RenderGeometryPolicy.timeline(landscape, for: .preview720p)
    let cinematic1080 = RenderGeometryPolicy.timeline(cinematic, for: .final1080p)

    #expect(portrait1080.width == 1_080)
    #expect(portrait1080.height == 1_920)
    #expect(portrait4K.width == 2_160)
    #expect(portrait4K.height == 3_840)
    #expect(landscape720.width == 1_280)
    #expect(landscape720.height == 720)
    #expect(cinematic1080.width == 1_920)
    #expect(cinematic1080.height == 810)
}

@Test func overlappingFadeAndDuckingRampsDoNotCrashPlaybackBuild() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("veloedit-overlapping-audio-ramps-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let audioURL = root.appendingPathComponent("tone.m4a")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
    let frameCount: AVAudioFrameCount = 44_100
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    let samples = try #require(buffer.floatChannelData)
    for channel in 0..<2 {
        for frame in 0..<Int(frameCount) {
            samples[channel][frame] = sin(Float(frame) * 2 * .pi * 220 / 44_100) * 0.1
        }
    }
    var output: AVAudioFile? = try AVAudioFile(forWriting: audioURL, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000,
    ])
    try output?.write(from: buffer)
    output = nil

    let asset = MediaAsset(
        originalURL: audioURL,
        kind: .video,
        byteSize: 1,
        contentHash: "overlapping-ramps",
        metadata: MediaMetadata(duration: 1, hasAudio: true)
    )
    let background = TimelineAudioClip(
        assetID: asset.id,
        title: "Background",
        role: .detached,
        sourceDuration: 1,
        timelineStart: 0,
        timelineDuration: 1,
        adjustments: AudioAdjustments(fadeIn: 0.4, fadeOut: 0.4)
    )
    let foreground = TimelineAudioClip(
        assetID: asset.id,
        title: "Foreground",
        role: .voice,
        sourceDuration: 0.8,
        timelineStart: 0.1,
        timelineDuration: 0.8,
        adjustments: AudioAdjustments(duckOthers: true, duckingAmount: 0.6)
    )
    let title = TimelineItem(
        kind: .title,
        sourceDuration: 1,
        timelineStart: 0,
        timelineDuration: 1,
        title: "Audio ramp test"
    )
    let timeline = Timeline(
        storyPlanID: UUID(),
        width: 320,
        height: 180,
        frameRate: 10,
        items: [title],
        audioClips: [background, foreground]
    )

    let playback = try await PlaybackEngine().build(timeline: timeline, assets: [asset])
    #expect(playback.audioMix != nil)
    #expect(playback.renderedItemCount == 1)
}

@Test func originalURLAndSourceRangeArePreserved() throws {
    let url = URL(fileURLWithPath: "/Volumes/Media/Bike & Lake.mov")
    let asset = MediaAsset(originalURL: url, kind: .video, byteSize: 1, contentHash: "x", metadata: MediaMetadata(duration: 100, width: 3840, height: 2160, frameRate: 30, hasAudio: true))
    let item = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 42.5, sourceDuration: 9.3, timelineStart: 0, timelineDuration: 9.3, explanation: ["Высокая динамика"])
    let timeline = Timeline(storyPlanID: UUID(), items: [item])
    let xml = try FCPXMLExporter().xml(timeline: timeline, assets: [asset])
    #expect((try? XMLDocument(xmlString: xml)) != nil)
    #expect(xml.contains("1275/30s"))
    #expect(xml.contains("Bike%20&amp;%20Lake.mov"))
    #expect(!xml.contains("rendered-master"))
}

@Test func tenRequiredFixturesAreWellFormed() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let outputs = try FCPXMLFixtureFactory().writeAll(to: root)
    #expect(outputs.count == 10)
    for output in outputs { #expect((try? XMLDocument(contentsOf: output)) != nil) }
}

@Test func fcpxmlCarriesSpeedTransformOpacityAudioAndUnsupportedIntent() throws {
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/clip.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "clip",
        metadata: MediaMetadata(duration: 30, width: 1920, height: 1080, frameRate: 30, hasAudio: true)
    )
    let item = TimelineItem(
        assetID: asset.id,
        kind: .video,
        sourceStart: 3,
        sourceDuration: 8,
        timelineStart: 0,
        timelineDuration: 4,
        speed: 2,
        transition: TransitionStyle.wipeLeft.rawValue,
        effect: ClipEffect.mirror.rawValue,
        videoAdjustments: VideoAdjustments(crop: .fit, rotationQuarterTurns: 1, filter: .noir, opacity: 0.5),
        audioAdjustments: AudioAdjustments(volume: 0.5, fadeIn: 1, fadeOut: 1)
    )
    let xml = try FCPXMLExporter().xml(
        timeline: Timeline(storyPlanID: UUID(), items: [item], originalAudioVolume: 0.8),
        assets: [asset]
    )
    #expect(xml.contains("<timeMap"))
    #expect(xml.contains("time=\"120/30s\" value=\"330/30s\""))
    #expect(xml.contains("<adjust-conform type=\"fit\""))
    #expect(xml.contains("scale=\"-1 1\" rotation=\"-90\""))
    #expect(xml.contains("<adjust-blend amount=\"0.5000\""))
    #expect(xml.contains("<adjust-volume amount=\"-7.9588dB\""))
    #expect(xml.contains("com.veloedit.filter\" value=\"noir\""))
    #expect(xml.contains("com.veloedit.transition\" value=\"wipe-left\""))
}

@Test func fcpxmlCarriesReverseAndFreezeTiming() throws {
    let assetID = UUID()
    let asset = MediaAsset(
        id: assetID,
        originalURL: URL(fileURLWithPath: "/tmp/reverse.mov"),
        displayName: "reverse.mov",
        kind: .video,
        byteSize: 1,
        contentHash: "reverse",
        metadata: MediaMetadata(duration: 20, width: 1920, height: 1080, frameRate: 30, hasAudio: true)
    )
    let reverse = TimelineItem(
        assetID: assetID,
        kind: .video,
        sourceStart: 4,
        sourceDuration: 6,
        timelineStart: 0,
        timelineDuration: 6,
        reversePlayback: true
    )
    let freeze = TimelineItem(
        assetID: assetID,
        kind: .video,
        sourceStart: 12,
        sourceDuration: 1.0 / 30.0,
        timelineStart: 6,
        timelineDuration: 2,
        freezeFrame: true
    )
    let timeline = Timeline(storyPlanID: UUID(), items: [reverse, freeze])
    let xml = try FCPXMLExporter().xml(timeline: timeline, assets: [asset], mode: .edit)
    #expect(xml.contains("com.veloedit.reverse\" value=\"true"))
    #expect(xml.contains("com.veloedit.freezeFrame\" value=\"true"))
    #expect(xml.components(separatedBy: "<timeMap").count == 3)
}

@Test func fcpxmlCarriesEditableSpeedRampAndRenderedFallbackReference() throws {
    let assetID = UUID()
    let asset = MediaAsset(
        id: assetID,
        originalURL: URL(fileURLWithPath: "/tmp/ramp.mov"),
        displayName: "ramp.mov",
        kind: .video,
        byteSize: 1,
        contentHash: "ramp",
        metadata: MediaMetadata(duration: 20, width: 1920, height: 1080, frameRate: 30, hasAudio: true)
    )
    let ramp = SpeedRamp.action
    let item = TimelineItem(
        assetID: assetID,
        kind: .video,
        sourceStart: 2,
        sourceDuration: 8,
        timelineStart: 0,
        timelineDuration: ramp.outputDuration(sourceDuration: 8),
        transition: TransitionStyle.blurDissolve.rawValue,
        videoAdjustments: VideoAdjustments(exposure: 0.5, vignette: 0.3, tint: 0.2, stabilization: 0.4, rollingShutterCorrection: true),
        audioAdjustments: AudioAdjustments(noiseReduction: 0.5, eqPreset: .voice, normalize: true, effect: .room),
        speedRamp: ramp
    )
    let timeline = Timeline(storyPlanID: UUID(), items: [item])
    let exporter = FCPXMLExporter()
    #expect(exporter.requiresRenderedFallback(for: timeline))
    let rendered = URL(fileURLWithPath: "/tmp/ramp-rendered.mp4")
    let xml = try exporter.xml(timeline: timeline, assets: [asset], renderedFallbackURL: rendered)
    #expect(xml.components(separatedBy: "<timept ").count >= 5)
    #expect(xml.contains("interp=\"smooth2\""))
    #expect(xml.contains("com.veloedit.speedRamp"))
    #expect(xml.contains("noiseReduction=0.5000;eq=voice"))
    #expect(xml.contains("tint=0.2000"))
    #expect(xml.contains("stabilization=0.4000"))
    #expect(xml.contains("rollingShutter=true"))
    #expect(xml.contains("normalize=true"))
    #expect(xml.contains("effect=room"))
    #expect(xml.contains("ramp-rendered.mp4"))
    #expect(xml.contains("Rendered Reference"))
    #expect(xml.contains("Editable"))
}

@Test func gpmfDecodesGPSRouteSpeedAltitudeDistanceAndGForce() throws {
    func int32(_ value: Int32) -> [UInt8] {
        let raw = UInt32(bitPattern: value)
        return [UInt8(raw >> 24), UInt8((raw >> 16) & 0xff), UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
    }
    func int16(_ value: Int16) -> [UInt8] {
        let raw = UInt16(bitPattern: value)
        return [UInt8(raw >> 8), UInt8(raw & 0xff)]
    }
    func record(_ key: String, type: Character, structure: Int, repeats: Int, payload: [UInt8]) -> Data {
        var result = Data(key.utf8)
        result.append(UInt8(type.asciiValue!))
        result.append(UInt8(structure))
        result.append(UInt8((repeats >> 8) & 0xff))
        result.append(UInt8(repeats & 0xff))
        result.append(contentsOf: payload)
        while result.count % 4 != 0 { result.append(0) }
        return result
    }
    let gpsScale = [10_000_000, 10_000_000, 1_000, 1_000, 1_000].flatMap { int32(Int32($0)) }
    let gpsValues = [
        557_500_000, 376_100_000, 120_000, 12_500, 12_700,
        557_501_000, 376_102_000, 125_000, 15_000, 15_100
    ].flatMap { int32(Int32($0)) }
    let gpsStream = record("SCAL", type: "l", structure: 4, repeats: 5, payload: gpsScale)
        + record("GPS5", type: "l", structure: 20, repeats: 2, payload: gpsValues)
    let accelScale = [1, 1, 1].flatMap { int16(Int16($0)) }
    let accelValues = [0, 0, 20].flatMap { int16(Int16($0)) }
    let accelStream = record("SCAL", type: "s", structure: 2, repeats: 3, payload: accelScale)
        + record("ACCL", type: "s", structure: 6, repeats: 1, payload: accelValues)
    let payload = record("STRM", type: "\0", structure: 1, repeats: gpsStream.count, payload: [UInt8](gpsStream))
        + record("STRM", type: "\0", structure: 1, repeats: accelStream.count, payload: [UInt8](accelStream))
    let records = try GPMFParser().parse(payload)
    let summary = GPMFParser().summary(records)
    #expect(summary.route?.count == 2)
    #expect(summary.maxSpeedMetersPerSecond == 15)
    #expect(summary.minAltitudeMeters == 120)
    #expect(summary.maxAltitudeMeters == 125)
    #expect((summary.distanceMeters ?? 0) > 10)
    #expect((summary.maxGForce ?? 0) > 2)
    let timed = GPMFParser().timedSamples(records, startTime: 10, duration: 2)
    #expect(timed.count == 2)
    #expect(timed.first?.timestamp == 10.5)
    #expect(timed.last?.timestamp == 11.5)
    #expect(timed.first?.speedMetersPerSecond == 12.5)
    #expect(timed.last?.speedMetersPerSecond == 15)
    #expect((timed.first?.gForce ?? 0) > 2)
}

@Test func parsesPaddedKLVAndSummary() throws {
    var data = Data("GPS5".utf8)
    data.append(contentsOf: [0x6c, 0x14, 0x00, 0x02])
    data.append(Data(repeating: 0, count: 40))
    let records = try GPMFParser().parse(data)
    #expect(records.first?.key == "GPS5")
    #expect(records.first?.repeatCount == 2)
    let summary = GPMFParser().summary(records)
    #expect(summary.hasGPMF)
    #expect(summary.sampleCount == 2)
    #expect(summary.streams.contains("GPS5"))
}

@Test func rejectsTruncatedPayload() {
    let data = Data([0x47, 0x50, 0x53, 0x35, 0x6c, 0x14, 0, 2, 0])
    var didThrow = false
    do { _ = try GPMFParser().parse(data) } catch { didThrow = true }
    #expect(didThrow)
}

@Test func stillPhotoBecomesPlayableKenBurnsVideo() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let imageURL = root.appendingPathComponent("photo.png")
    let outputURL = root.appendingPathComponent("photo.mov")
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64 * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    // Keep a visible off-centre detail so the assertion below verifies the
    // deliberately simple push-in animation rather than style-specific FX.
    context.setFillColor(CGColor(red: 0.95, green: 0.2, blue: 0.15, alpha: 1))
    context.fill(CGRect(x: 6, y: 7, width: 14, height: 11))
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    do {
        _ = try await StillImageVideoGenerator().generate(imageURL: imageURL, duration: 0.3, width: 320, height: 180, frameRate: 10, destination: outputURL)
    } catch DerivedMediaError.exportFailed(let reason) where reason.contains("-11834") || reason.contains("-12903") {
        // Headless Command Line Tools runners can lack a usable VideoToolbox
        // encoder. Signed app/integration hosts execute the assertions below.
        return
    }
    let asset = AVURLAsset(url: outputURL)
    #expect(!(try await asset.loadTracks(withMediaType: .video)).isEmpty)
    #expect((try await asset.load(.duration)).seconds >= 0.2)

    let animatedURL = root.appendingPathComponent("endless-rain-background.mov")
    _ = try await StillImageVideoGenerator().generate(
        imageURL: imageURL,
        duration: 0.5,
        width: 320,
        height: 180,
        frameRate: 10,
        destination: animatedURL,
        motion: nil,
        backgroundAnimationStyle: .rain
    )
    let animatedAsset = AVURLAsset(url: animatedURL)
    #expect((try await animatedAsset.load(.duration)).seconds >= 0.4)
    let imageGenerator = AVAssetImageGenerator(asset: animatedAsset)
    imageGenerator.requestedTimeToleranceBefore = .zero
    imageGenerator.requestedTimeToleranceAfter = .zero
    let firstFrame = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
    let laterFrame = try imageGenerator.copyCGImage(at: CMTime(seconds: 0.3, preferredTimescale: 600), actualTime: nil)
    let firstBytes = firstFrame.dataProvider?.data as Data?
    let laterBytes = laterFrame.dataProvider?.data as Data?
    #expect(firstBytes != laterBytes)

    for style in BackgroundAnimationStyle.allCases {
        let styleURL = root.appendingPathComponent("background-\(style.rawValue).mov")
        _ = try await StillImageVideoGenerator().generate(
            imageURL: imageURL,
            duration: 0.2,
            width: 160,
            height: 90,
            frameRate: 10,
            destination: styleURL,
            codec: .jpeg,
            motion: nil,
            backgroundAnimationStyle: style
        )
        #expect(FileManager.default.fileExists(atPath: styleURL.path))
    }
}

@Test func aiTransitionAndMotionIntentsForceARealVideoComposition() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let imageURL = root.appendingPathComponent("source.png")
    let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.9, green: 0.45, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(destination))

    let asset = MediaAsset(
        originalURL: imageURL,
        kind: .photo,
        byteSize: 1,
        contentHash: "photo",
        metadata: MediaMetadata(width: 64, height: 48, hasAudio: false)
    )
    let first = TimelineItem(
        assetID: asset.id,
        kind: .photo,
        sourceDuration: 0.8,
        timelineStart: 0,
        timelineDuration: 0.8,
        effect: ClipEffect.pushIn.rawValue
    )
    let second = TimelineItem(
        assetID: asset.id,
        kind: .photo,
        sourceDuration: 0.8,
        timelineStart: 0.8,
        timelineDuration: 0.8,
        transition: TransitionStyle.blurDissolve.rawValue,
        effect: ClipEffect.panLeft.rawValue
    )
    let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 10, items: [first, second])
    do {
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [asset])
        #expect(playback.renderedItemCount == 2)
        #expect(playback.videoComposition != nil)
        #expect(playback.duration < 1.6)
        #expect(playback.duration > 1.2)
    } catch DerivedMediaError.exportFailed(let reason) where reason.contains("-11834") || reason.contains("-12903") {
        return
    }
}

@Test func realtimeTitlePreviewAvoidsTheCustomVideoCompositor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let imageURL = root.appendingPathComponent("title-preview-source.png")
    let context = try #require(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.55, blue: 0.25, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
    let destination = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))

    let asset = MediaAsset(originalURL: imageURL, kind: .photo, byteSize: 1, contentHash: "stable-title-preview", metadata: MediaMetadata(width: 64, height: 36, hasAudio: false))
    let clip = TimelineItem(
        assetID: asset.id,
        kind: .photo,
        sourceDuration: 1,
        timelineStart: 0,
        timelineDuration: 1,
        telemetryOverlay: TelemetryOverlaySettings()
    )
    let title = TitleTimelineItem(kind: .cinematicTitle, templateID: "title.cinematic.v1", text: "Маршрут", startTime: 0, duration: 0.8)
    let telemetry = TimelineTelemetryItem(sourceStart: 0, timelineStart: 0, timelineDuration: 1)
    let timeline = Timeline(
        storyPlanID: UUID(),
        width: 320,
        height: 180,
        frameRate: 10,
        items: [clip],
        telemetryItems: [telemetry],
        titleItems: [title]
    )

    let playback = try await PlaybackEngine().build(
        timeline: timeline,
        assets: [asset],
        preferStableRealtimePreview: true
    )
    #expect(playback.videoComposition?.customVideoCompositorClass == nil)
    #expect(playback.renderedItemCount == 1)
}

@Test func titleCardIsRenderedIntoPlaybackInsteadOfBeingSkipped() async throws {
    let item = TimelineItem(
        kind: .title,
        sourceDuration: 0.3,
        timelineStart: 0,
        timelineDuration: 0.3,
        title: "Наше лето",
        titleStyle: TitleStyle(fontSize: 54, backgroundColorHex: "#17324D")
    )
    let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 10, items: [item])
    do {
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [])
        #expect(playback.renderedItemCount == 1)
        #expect(playback.skippedItemIDs.isEmpty)
        #expect(playback.duration >= 0.2)
    } catch DerivedMediaError.exportFailed(let reason) where reason.contains("-11834") || reason.contains("-12903") {
        return
    }
}

@Test func unavailableSoundtrackIsANonFatalPlaybackWarning() {
    let directive = MusicDirective(style: .cinematic, bpm: 82)
    let warning = PlaybackEngine.soundtrackWarning(for: directive, tracks: [])
    #expect(warning?.contains("без музыки") == true)
    #expect(PlaybackEngine.soundtrackWarning(for: nil, tracks: []) == nil)
}

@Test func colorAdjustedIntermediateRemainsPlayable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let imageURL = root.appendingPathComponent("source.png")
    let sourceURL = root.appendingPathComponent("source.mov")
    let adjustedURL = root.appendingPathComponent("adjusted.mov")
    let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(destination))
    do {
        _ = try await StillImageVideoGenerator().generate(imageURL: imageURL, duration: 0.4, width: 320, height: 180, frameRate: 10, destination: sourceURL)
        _ = try await AdjustedClipGenerator().generate(
            sourceURL: sourceURL,
            sourceStart: 0,
            sourceDuration: 0.3,
            adjustments: VideoAdjustments(filter: .monochrome, contrast: 1.2),
            destination: adjustedURL
        )
    } catch DerivedMediaError.exportFailed(let reason) where reason.contains("-11834") || reason.contains("-12903") {
        return
    }
    let adjusted = AVURLAsset(url: adjustedURL)
    #expect(!(try await adjusted.loadTracks(withMediaType: .video)).isEmpty)
    #expect((try await adjusted.load(.duration)).seconds >= 0.2)
}
