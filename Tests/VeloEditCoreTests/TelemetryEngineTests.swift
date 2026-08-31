import Foundation
import CoreImage
import ImageIO
import Testing
@testable import VeloEditCore

@Test func gpxImportsOfflineAndDerivesUnifiedMetrics() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("ride.gpx")
    let gpx = """
    <?xml version="1.0"?><gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
      <trk><trkseg>
        <trkpt lat="55.7500" lon="37.6100"><ele>120</ele><time>2026-08-22T10:00:00Z</time><extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>130</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions></trkpt>
        <trkpt lat="55.7505" lon="37.6110"><ele>124</ele><time>2026-08-22T10:00:05Z</time><extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>142</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions></trkpt>
      </trkseg></trk>
    </gpx>
    """
    try gpx.write(to: url, atomically: true, encoding: .utf8)
    let source = try await TelemetryEngine().importSource(url: url)
    #expect(source.format == .gpx)
    #expect(source.summary.sampleCount == 2)
    #expect((source.summary.distanceMeters ?? 0) > 70)
    #expect((source.summary.maxSpeedMetersPerSecond ?? 0) > 10)
    #expect(source.summary.sample(at: 2.5)?.heartRateBPM == 136)
}

@Test func vendoredOVRLEYBridgeParsesCSVLocally() async throws {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ovrley-telemetry.csv")
    let source = try await TelemetryEngine().importSource(url: fixture)
    #expect(source.format == .csv)
    #expect(source.summary.sampleCount == 3)
    #expect(source.summary.maxSpeedMetersPerSecond == 7)
    #expect((source.summary.distanceMeters ?? 0) > 30)
    #expect(source.summary.sourceFormat == TelemetrySourceFormat.csv.rawValue)
}

@Test func ovrleyCameraVendorMetadataIsPreserved() throws {
    let activity = try JSONDecoder().decode(OVRLEYActivity.self, from: Data(#"""
    {
      "file_name":"DJI_001.mp4",
      "file_format":"mp4_telemetry",
      "metadata":{"camera_type":"DJI","camera_model":"Osmo Action","telemetry_source":"telemetry_parser","gps_sample_count":12,"imu_sample_count":24,"camera_sample_count":30},
      "sample_elapsed_seconds":[0,1],
      "battery_voltage":[12.1,12.0]
    }
    """#.utf8))
    #expect(activity.metadata?.cameraType == "DJI")
    #expect(activity.metadata?.cameraModel == "Osmo Action")
    #expect(activity.metadata?.gpsSampleCount == 12)
    #expect(activity.embeddedCameraName == "DJI Osmo Action")
    #expect(activity.customSeries["battery_voltage"]?[0] == 12.1)
}

@Test func telemetryTimelineObjectsRemainIndependentAndCodable() throws {
    let sourceID = UUID()
    let widget = TelemetryWidgetLayout(kind: .speedometer, x: 0.2, y: 0.3, width: 0.25, height: 0.2, opacity: 0.8)
    let item = TimelineTelemetryItem(
        sourceID: sourceID,
        sourceStart: 4,
        timelineStart: 2,
        timelineDuration: 8,
        syncOffset: -0.25,
        settings: TelemetryOverlaySettings(metrics: [.speed], style: .racing, widgets: [widget], opacity: 0.75)
    )
    let timeline = Timeline(storyPlanID: UUID(), items: [], telemetryItems: [item])
    let decoded = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(timeline))
    let restored = try #require(decoded.effectiveTelemetryItems.first)
    #expect(restored.sourceID == sourceID)
    #expect(restored.syncOffset == -0.25)
    #expect(restored.settings.effectiveStyle == .racing)
    #expect(restored.settings.resolvedWidgets.first?.x == 0.2)
}

@Test func automaticTelemetrySynchronizationUsesAbsoluteTimestamps() {
    let videoDate = Date(timeIntervalSince1970: 1_800_000_000)
    let sourceDate = videoDate.addingTimeInterval(-2.5)
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/camera.mov"),
        kind: .video,
        byteSize: 0,
        contentHash: "sync",
        metadata: MediaMetadata(duration: 10, frameRate: 30, creationDate: videoDate)
    )
    let source = TelemetrySource(
        displayName: "activity.gpx",
        format: .gpx,
        startDate: sourceDate,
        summary: TelemetrySummary(sampleCount: 2, timedSamples: [TelemetrySample(timestamp: 0), TelemetrySample(timestamp: 10)])
    )
    let sync = TelemetryEngine().synchronize(source: source, with: asset)
    #expect(sync.method == .telemetryTimestamp)
    #expect(abs(sync.offsetSeconds - 2.5) < 0.0001)
    #expect(sync.confidence > 0.9)
}

@Test func ovrleyVisualCatalogueCoversTemplatesAndDisplayVariants() throws {
    #expect(TelemetryWidgetStyle.ovrleyTemplates.count == 12)
    #expect(Set(TelemetryWidgetStyle.ovrleyTemplates.map(\.rawValue)).count == 12)
    #expect(TelemetryWidgetPreset.all.count > 50)
    #expect(TelemetryWidgetPreset.all.contains { $0.kind == .power && $0.presentation == .linear })
    #expect(TelemetryWidgetPreset.all.contains { $0.kind == .power && $0.presentation == .arc })
    #expect(!TelemetryWidgetPreset.all.contains { $0.presentation == .linearSegmented || $0.presentation == .arcSegmentedDense })
    #expect(TelemetryWidgetPreset.all.contains { $0.kind == .routeMap && $0.presentation == .routePlot })
    #expect(TelemetryWidgetPreset.all.contains { $0.kind == .lapTimer && $0.presentation == .lapLog })

    let original = TelemetryWidgetLayout.presetLayout(kind: .power, presentation: .arcReverse)
    let restored = try JSONDecoder().decode(
        TelemetryWidgetLayout.self,
        from: JSONEncoder().encode(original)
    )
    #expect(restored.effectivePresentation == .arcReverse)

    // A widget written before `presentation` existed still resolves to the
    // same visual mode instead of breaking old project manifests.
    let legacy = try JSONDecoder().decode(
        TelemetryWidgetLayout.self,
        from: JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString,
            "kind": "speedometer",
            "x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2,
            "opacity": 1, "foregroundHex": "#FFFFFF", "backgroundHex": "#00000000",
            "accentHex": "#FFFFFF", "borderWidth": 0, "shadowRadius": 0,
            "fontName": "Helvetica Neue", "showsLabel": true
        ])
    )
    #expect(legacy.effectivePresentation == .arc)
}

@Test func editedClipClockDrivesTelemetryClock() {
    let forward = TimelineItem(
        kind: .video,
        sourceStart: 10,
        sourceDuration: 8,
        timelineStart: 4,
        timelineDuration: 4,
        speed: 2
    )
    #expect(forward.sourceTime(atTimelineTime: 4) == 10)
    #expect(forward.sourceTime(atTimelineTime: 6) == 14)
    #expect(forward.sourceTime(atTimelineTime: 8) == 18)

    var reversed = forward
    reversed.reversePlayback = true
    #expect(reversed.sourceTime(atTimelineTime: 4) == 18)
    #expect(reversed.sourceTime(atTimelineTime: 6) == 14)
    #expect(reversed.sourceTime(atTimelineTime: 8) == 10)

    var ramped = forward
    ramped.speedRamp = .action
    let early = ramped.sourceTime(atTimelineTime: 5)
    let late = ramped.sourceTime(atTimelineTime: 7)
    #expect(early > 10 && early < late)
    #expect(late < 18)
}

@Test func telemetryPresetBindsAndRebindsToTheVideoFragmentUnderIt() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Привязка телеметрии")
    let firstAsset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/first.mov"), kind: .video, byteSize: 1, contentHash: "telemetry-first", metadata: MediaMetadata(duration: 40))
    let secondAsset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/second.mov"), kind: .video, byteSize: 1, contentHash: "telemetry-second", metadata: MediaMetadata(duration: 40))
    let firstClip = TimelineItem(assetID: firstAsset.id, kind: .video, sourceStart: 4, sourceDuration: 8, timelineStart: 0, timelineDuration: 4, speed: 2)
    let secondClip = TimelineItem(assetID: secondAsset.id, kind: .video, sourceStart: 20, sourceDuration: 5, timelineStart: 4, timelineDuration: 5)
    let summary = TelemetrySummary(sampleCount: 2, maxGForce: 2, timedSamples: [
        TelemetrySample(timestamp: 0, gForce: 0.2),
        TelemetrySample(timestamp: 40, gForce: 1.2)
    ])
    let firstSource = TelemetrySource(displayName: "first", format: .embeddedGPMF, linkedAssetID: firstAsset.id, summary: summary)
    let secondSource = TelemetrySource(displayName: "second", format: .embeddedGPMF, linkedAssetID: secondAsset.id, summary: summary)
    try await store.update { project in
        project.assets = [firstAsset, secondAsset]
        project.telemetrySources = [firstSource, secondSource]
        project.timelines = [Timeline(storyPlanID: UUID(), items: [firstClip, secondClip])]
    }
    let pipeline = VeloEditPipeline(store: store)

    let settings = TelemetryOverlaySettings(
        metrics: [.gForce],
        widgets: [.presetLayout(kind: .gForce, presentation: .text)]
    )
    let insertedID = try #require(await pipeline.addTelemetryItem(attachedTo: secondClip.id, settings: settings))
    var item = try #require((await pipeline.snapshot()).timelines.last?.effectiveTelemetryItems.first)
    #expect(item.id == insertedID)
    #expect(item.targetClipID == secondClip.id)
    #expect(item.sourceID == secondSource.id)
    #expect(item.linkedAssetID == secondAsset.id)
    #expect(item.sourceStart == 20)
    #expect(item.timelineStart == 4)

    try await pipeline.updateTelemetryItem(id: insertedID, timelineStart: 0)
    item = try #require((await pipeline.snapshot()).timelines.last?.effectiveTelemetryItems.first)
    #expect(item.targetClipID == firstClip.id)
    #expect(item.sourceID == firstSource.id)
    #expect(item.linkedAssetID == firstAsset.id)
    #expect(item.sourceStart == 4)
}

@Test func telemetryCatalogueOnlyExposesDecodedValues() {
    let summary = TelemetrySummary(
        hasGPMF: true,
        sampleCount: 2,
        distanceMeters: 0,
        maxGForce: 2,
        timedSamples: [
            TelemetrySample(timestamp: 0, gForce: 0.2, distanceMeters: 0, lapNumber: -1, cameraISO: 100, cameraShutterSeconds: 1 / 240, cameraColorTemperatureKelvin: 5_200),
            TelemetrySample(timestamp: 1, gForce: 1.2, distanceMeters: 0, lapNumber: -1, cameraISO: 400, cameraShutterSeconds: 1 / 120, cameraColorTemperatureKelvin: 5_600)
        ],
        streams: ["G-FORCE", "CAMERA"]
    )

    #expect(summary.supports(.gForce, presentation: .text))
    #expect(summary.supports(.cameraISO, presentation: .text))
    #expect(summary.supports(.cameraShutter, presentation: .text))
    #expect(summary.supports(.cameraColorTemperature, presentation: .text))
    #expect(summary.supports(.elapsedTime, presentation: .text))
    #expect(!summary.supports(.speedValue, presentation: .text))
    #expect(!summary.supports(.altitude, presentation: .text))
    #expect(!summary.supports(.temperature, presentation: .text))
    #expect(!summary.supports(.distance, presentation: .text))
    #expect(!summary.supports(.lapCounter, presentation: .text))
    #expect(!summary.supports(.coordinates, presentation: .text))
}

@Test func smartphoneQuickTimeLocationBecomesRealTelemetryWithoutFakeRoute() throws {
    let summary = try #require(QuickTimeVideoTelemetryExtractor.summary(
        iso6709: "+55.7283+037.6090+144.654/",
        duration: 12.5
    ))
    let first = try #require(summary.timedSamples?.first)
    let last = try #require(summary.timedSamples?.last)

    #expect(first.coordinate?.latitude == 55.7283)
    #expect(first.coordinate?.longitude == 37.6090)
    #expect(first.altitudeMeters == 144.654)
    #expect(last.timestamp == 12.5)
    #expect(summary.supports(.coordinates, presentation: .text))
    #expect(summary.supports(.altitude, presentation: .text))
    #expect(summary.supports(.satelliteStatus, presentation: .text))
    #expect(!summary.supports(.routeMap, presentation: .routePlot))
    #expect(!summary.supports(.speedValue, presentation: .text))
}

@Test func telemetryRendererProducesVisibleChangingValues() throws {
    let summary = TelemetrySummary(
        hasGPMF: true,
        sampleCount: 2,
        maxGForce: 2,
        timedSamples: [TelemetrySample(timestamp: 0, gForce: 0.2), TelemetrySample(timestamp: 10, gForce: 1.8)]
    )
    var layout = TelemetryWidgetLayout.presetLayout(kind: .gForce, presentation: .text)
    layout.x = 0.1; layout.y = 0.1; layout.width = 0.5; layout.height = 0.35
    let settings = TelemetryOverlaySettings(metrics: [.gForce], style: .acidTitanium, widgets: [layout])
    let size = CGSize(width: 640, height: 360)
    let first = try #require(TelemetryOverlayRenderer.rasterImage(settings: settings, telemetry: summary, progress: 0, sourceTime: 0, renderSize: size))
    let last = try #require(TelemetryOverlayRenderer.rasterImage(settings: settings, telemetry: summary, progress: 1, sourceTime: 10, renderSize: size))

    func pixels(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }
    let firstPixels = pixels(first.image)
    let lastPixels = pixels(last.image)
    #expect(CGRect(origin: first.origin, size: CGSize(width: first.image.width, height: first.image.height)).intersects(CGRect(origin: .zero, size: size)))
    #expect(firstPixels.contains { $0 > 0 })
    #expect(firstPixels != lastPixels)
}

@Test func originalOVRLEYRustRendererProducesTheSharedFrame() throws {
    let summary = TelemetrySummary(
        sampleCount: 3,
        maxSpeedMetersPerSecond: 18,
        timedSamples: [
            TelemetrySample(timestamp: 0, speedMetersPerSecond: 4),
            TelemetrySample(timestamp: 1, speedMetersPerSecond: 12),
            TelemetrySample(timestamp: 2, speedMetersPerSecond: 18)
        ],
        sourceFormat: "test"
    )
    var layout = TelemetryWidgetLayout.presetLayout(kind: .speedValue, presentation: .text)
    layout.x = 0.08; layout.y = 0.08; layout.width = 0.32; layout.height = 0.24
    let settings = TelemetryOverlaySettings(metrics: [.speed], style: .acidTitanium, widgets: [layout])
    let payload = try #require(OVRLEYFrameRenderer.activityPayload(summary))
    let config = try #require(OVRLEYFrameRenderer.renderTemplate(
        settings: settings,
        telemetry: summary,
        renderSize: CGSize(width: 320, height: 180)
    ))
    let png = try OVRLEYBridge().renderFrame(payload: payload, config: config, second: 1)
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 320)
    #expect(image.height == 180)
}
