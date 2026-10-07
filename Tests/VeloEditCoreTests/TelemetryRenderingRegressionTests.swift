import Foundation
import AVFoundation
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import VeloEditCore

private func telemetryPixels(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { storage in
        let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}

private func saveTelemetryQA(_ image: CGImage, name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["VELOEDIT_TELEMETRY_QA_DIR"] else { return }
    let directory = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = try #require(CGImageDestinationCreateWithURL(directory.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

@Test func telemetryRegionsDoNotOverlapAtCardAndVideoSizes() {
    for size in [CGSize(width: 480, height: 152), CGSize(width: 422, height: 238), CGSize(width: 160, height: 200)] {
        for presentation in TelemetryWidgetPresentation.allCases {
            for labels in [true, false] {
                let rect = CGRect(origin: .zero, size: size)
                let geometry = TelemetryWidgetGeometry(rect: rect, presentation: presentation, showsLabel: labels)
                let regions = [geometry.label, geometry.value, geometry.graphic].filter { !$0.isEmpty }
                for (index, region) in regions.enumerated() {
                    #expect(rect.contains(region))
                    for other in regions.dropFirst(index + 1) { #expect(!region.intersects(other)) }
                }
            }
        }
    }
}

@Test(arguments: TelemetryWidgetStyle.allCases)
func telemetryCatalogueRendersEveryPresentation(_ style: TelemetryWidgetStyle) throws {
    var overview: [(String, CGImage)] = []
    let featured: Set<TelemetryWidgetKind> = [.verticalSpeed, .routeMap, .elevationProfile, .heading, .gForceXY, .leanAngle, .lapTimer, .coordinates, .cameraShutter, .heartRate, .power, .elapsedTime]
    for preset in TelemetryWidgetPreset.all {
        let image = try #require(TelemetryOverlayRenderer.previewCGImage(kind: preset.kind, presentation: preset.presentation,
            style: style, size: CGSize(width: 480, height: 152)))
        let pixels = telemetryPixels(image)
        let hasPixels = pixels.strideAlphaContainsVisiblePixel
        #expect(hasPixels, "Empty widget: \(style.rawValue)/\(preset.id)")
        let body = try #require(image.cropping(to: CGRect(x: 0, y: 45, width: 480, height: 107)))
        let hasBody = telemetryPixels(body).strideAlphaContainsVisiblePixel
        #expect(hasBody, "Missing value/graphic: \(style.rawValue)/\(preset.id)")
        // The configured widget occupies 4...96% of the image. No title,
        // unit, icon or plot may leak into adjacent widgets at delivery size.
        var leakedPixels = 0
        for y in 0..<image.height {
            for x in 0..<image.width where x < 17 || x > 463 || y < 4 || y > 147 {
                if pixels[(y * image.width + x) * 4 + 3] > 0 { leakedPixels += 1 }
            }
        }
        #expect(leakedPixels == 0, "Overflow: \(style.rawValue)/\(preset.id)")
        let prefix = style == .acidTitanium ? "catalogue" : "catalogue-\(style.rawValue)"
        try saveTelemetryQA(image, name: "\(prefix)-\(preset.id.replacingOccurrences(of: ":", with: "-"))")
        if featured.contains(preset.kind), preset.kind == .verticalSpeed || preset.presentation == preset.kind.defaultPresentation || preset.presentation == .lapLog {
            overview.append(("\(preset.kind.localizedTitle) · \(preset.presentation.localizedTitle)", image))
        }
    }
    // Contact sheets are opt-in QA artifacts, not application resources.
    if ProcessInfo.processInfo.environment["VELOEDIT_TELEMETRY_QA_DIR"] != nil {
        let columns = 3, cellWidth = 360, cellHeight = 142
        let rows = (overview.count + columns - 1) / columns
        let canvas = try #require(CGContext(data: nil, width: columns * cellWidth, height: rows * cellHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(red: 0.035, green: 0.055, blue: 0.07, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: columns * cellWidth, height: rows * cellHeight))
        for (index, entry) in overview.enumerated() {
            let x = index % columns * cellWidth, y = (rows - 1 - index / columns) * cellHeight
            canvas.draw(entry.1, in: CGRect(x: x, y: y + 24, width: cellWidth, height: 114))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: entry.0, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 10, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.75, alpha: 1)
            ]))
            canvas.textPosition = CGPoint(x: x + 12, y: y + 10)
            CTLineDraw(line, canvas)
        }
        try saveTelemetryQA(try #require(canvas.makeImage()), name: "overview-\(style.rawValue)")
    }
}

private extension Array where Element == UInt8 {
    var strideAlphaContainsVisiblePixel: Bool { stride(from: 3, to: count, by: 4).contains { self[$0] > 0 } }
}

@Test(arguments: TelemetryWidgetStyle.allCases)
func telemetryImportedSamplesDriveValuesGaugesAndRoute(_ style: TelemetryWidgetStyle) async throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/ovrley-telemetry.csv")
    let source = try await TelemetryEngine().importSource(url: fixture)
    #expect(source.summary.sample(at: 0.5)?.speedMetersPerSecond == 5.5)
    #expect(source.summary.sample(at: 1.5)?.speedMetersPerSecond == 6.5)
    let presets: [(TelemetryWidgetKind, TelemetryWidgetPresentation)] = [(.speedValue, .text), (.speedBar, .linear), (.altitude, .arc), (.speedometer, .corner), (.routeMap, .routePlot)]
    let context = CIContext()
    for (kind, presentation) in presets {
        var layout = TelemetryWidgetLayout.presetLayout(kind: kind, presentation: presentation)
        layout.x = 0.04; layout.y = 0.04; layout.width = 0.92; layout.height = 0.92
        let settings = TelemetryOverlaySettings(style: style, widgets: [layout])
        let bounds = CGRect(x: 0, y: 0, width: 480, height: 152)
        let first = try #require(TelemetryOverlayRenderer.image(settings: settings, telemetry: source.summary, progress: 0, sourceTime: 0.25, renderSize: bounds.size))
        let last = try #require(TelemetryOverlayRenderer.image(settings: settings, telemetry: source.summary, progress: 1, sourceTime: 1.75, renderSize: bounds.size))
        let firstCG = try #require(context.createCGImage(first, from: bounds))
        let lastCG = try #require(context.createCGImage(last, from: bounds))
        let a = telemetryPixels(firstCG), b = telemetryPixels(lastCG)
        #expect(a.strideAlphaContainsVisiblePixel)
        #expect(b.strideAlphaContainsVisiblePixel)
        #expect(a != b)
        try saveTelemetryQA(firstCG, name: "real-\(style.rawValue)-\(kind.rawValue)-start")
        try saveTelemetryQA(lastCG, name: "real-\(style.rawValue)-\(kind.rawValue)-end")
    }
}

@Test func telemetryAlphaExportContainsChangingFramesFromRetimedSource() async throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/ovrley-telemetry.csv")
    let source = try await TelemetryEngine().importSource(url: fixture)
    let clip = TimelineItem(kind: .video, sourceStart: 0.25, sourceDuration: 1.5, timelineStart: 0, timelineDuration: 1, speed: 1.5)
    var widget = TelemetryWidgetLayout.presetLayout(kind: .speedBar, presentation: .linear)
    widget.x = 0.08; widget.y = 0.15; widget.width = 0.84; widget.height = 0.70
    let settings = TelemetryOverlaySettings(style: .acidTitanium, widgets: [widget])
    let layer = TimelineTelemetryItem(targetClipID: clip.id, sourceID: source.id, timelineStart: 0, timelineDuration: 1, settings: settings)
    let timeline = Timeline(storyPlanID: UUID(), width: 480, height: 160, frameRate: 12, items: [clip], telemetryItems: [layer])
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VELOEDIT_TELEMETRY_QA_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("telemetry-export-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { if ProcessInfo.processInfo.environment["VELOEDIT_TELEMETRY_QA_DIR"] == nil { try? FileManager.default.removeItem(at: directory) } }
    let destination = directory.appendingPathComponent("moving-telemetry.mov")
    _ = try await TelemetryAlphaRenderer().render(timeline: timeline, telemetry: [source.id: source.summary], destination: destination)
    let asset = AVURLAsset(url: destination)
    let duration = try await asset.load(.duration)
    #expect(abs(duration.seconds - 1) < 0.1)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let first = try await generator.image(at: CMTime(seconds: 0, preferredTimescale: 12)).image
    let last = try await generator.image(at: CMTime(seconds: 10.0 / 12, preferredTimescale: 12)).image
    #expect(telemetryPixels(first) != telemetryPixels(last))
    #expect(telemetryPixels(first).strideAlphaContainsVisiblePixel)
    try saveTelemetryQA(first, name: "export-start")
    try saveTelemetryQA(last, name: "export-end")
}

@Test func telemetryStaticPhoneMetadataDoesNotInventMotion() throws {
    let summary = try #require(QuickTimeVideoTelemetryExtractor.summary(iso6709: "+55.7274+037.6070+146.54/", duration: 80))
    #expect(summary.timedSamples?.allSatisfy { $0.speedMetersPerSecond == nil && $0.headingDegrees == nil && $0.verticalSpeedMetersPerSecond == nil } == true)
    var old = summary
    old.timedSamples?[1].verticalSpeedMetersPerSecond = 0
    old.timedSamples?[1].headingDegrees = 0
    #expect(!old.supports(.verticalSpeed))
    #expect(!old.supports(.heading))
    #expect(old.supports(.altitude))
    #expect(old.supports(.coordinates))
}

@Test func telemetryBridgeUsesCanonicalUnitsAndNeverDropsMixedWidgets() throws {
    let summary = TelemetrySummary(sampleCount: 2, timedSamples: [
        TelemetrySample(timestamp: 0, verticalSpeedMetersPerSecond: 0.28, airPressureHPA: 1012, verticalOscillationCentimeters: 8.6),
        TelemetrySample(timestamp: 1, verticalSpeedMetersPerSecond: 1.28, airPressureHPA: 1013, verticalOscillationCentimeters: 9)
    ])
    let payload = try #require(OVRLEYFrameRenderer.activityPayload(summary))
    let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    #expect((object["air_pressure"] as? [Double])?.first == 1.012)
    #expect((object["vertical_oscillation"] as? [Double])?.first == 86)
    let settings = TelemetryOverlaySettings(style: .acidTitanium, widgets: [
        .presetLayout(kind: .verticalSpeed, presentation: .text),
        .presetLayout(kind: .verticalSpeed, presentation: .arc)
    ])
    #expect(OVRLEYFrameRenderer.renderTemplate(settings: settings, telemetry: summary, renderSize: CGSize(width: 640, height: 360)) == nil)
}

@Test func telemetryCatalogueTextUsesTheOriginalRenderer() throws {
    let summary = TelemetryOverlayRenderer.catalogueTelemetry
    let layout = TelemetryWidgetLayout(kind: .verticalSpeed, presentation: .text, x: 0.04, y: 0.04, width: 0.92, height: 0.92)
    let settings = TelemetryOverlaySettings(style: .acidTitanium, widgets: [layout])
    let config = try #require(OVRLEYFrameRenderer.renderTemplate(settings: settings, telemetry: summary, renderSize: CGSize(width: 480, height: 152)))
    let payload = try #require(OVRLEYFrameRenderer.activityPayload(summary))
    let png = try OVRLEYBridge().renderFrame(payload: payload, config: config, second: 5)
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    try saveTelemetryQA(image, name: "native-vertical-speed")
}

@Test func telemetryEveryMetricReadsItsChangingSample() throws {
    var summary = TelemetryOverlayRenderer.catalogueTelemetry
    var first = try #require(summary.timedSamples?.first)
    var last = try #require(summary.timedSamples?.last)
    let channels: [WritableKeyPath<TelemetrySample, Double?>] = [
        \.speedMetersPerSecond, \.altitudeMeters, \.gForce, \.distanceMeters,
        \.accelerationMetersPerSecondSquared, \.gForceX, \.gForceY, \.headingDegrees,
        \.heartRateBPM, \.cadenceRPM, \.powerWatts, \.leanAngleDegrees, \.rpm,
        \.throttlePercent, \.brakePercent, \.temperatureCelsius, \.gradientPercent,
        \.verticalSpeedMetersPerSecond, \.torqueNewtonMeters, \.gear, \.calories,
        \.airPressureHPA, \.strideLengthMeters, \.verticalOscillationCentimeters,
        \.groundContactTimeMilliseconds, \.leftRightBalancePercent, \.strokeRate,
        \.cameraISO, \.cameraAperture, \.cameraShutterSeconds, \.cameraFocalLengthMM,
        \.cameraEV, \.cameraColorTemperatureKelvin
    ]
    for channel in channels { last[keyPath: channel] = last[keyPath: channel].map { $0 * 1.4 } }
    first.coordinate = summary.route?.first; last.coordinate = summary.route?.last
    first.lapNumber = 1; first.lapTimeSeconds = 1
    last.lapNumber = 2; last.lapTimeSeconds = 2
    summary.timedSamples = [first, last]
    let context = CIContext()
    let bounds = CGRect(x: 0, y: 0, width: 480, height: 152)
    for preset in TelemetryWidgetPreset.all where preset.kind != .satelliteStatus {
        var layout = TelemetryWidgetLayout.presetLayout(kind: preset.kind, presentation: preset.presentation)
        layout.x = 0.04; layout.y = 0.04; layout.width = 0.92; layout.height = 0.92
        let settings = TelemetryOverlaySettings(style: .acidTitanium, widgets: [layout])
        let a = try #require(TelemetryOverlayRenderer.image(settings: settings, telemetry: summary, progress: 0, sourceTime: first.timestamp, renderSize: bounds.size))
        let b = try #require(TelemetryOverlayRenderer.image(settings: settings, telemetry: summary, progress: 1, sourceTime: last.timestamp, renderSize: bounds.size))
        let firstCG = try #require(context.createCGImage(a, from: bounds))
        let lastCG = try #require(context.createCGImage(b, from: bounds))
        let changes = telemetryPixels(firstCG) != telemetryPixels(lastCG)
        #expect(changes, "Frozen telemetry: \(preset.id)")
    }
}
