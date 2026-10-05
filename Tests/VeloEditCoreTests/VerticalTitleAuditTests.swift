import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VeloEditCore

@Suite(.serialized) struct VerticalTitleAuditTests {
    private let size = CGSize(width: 360, height: 640)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var output: URL? {
        ProcessInfo.processInfo.environment["VELOEDIT_VERTICAL_TITLE_AUDIT"].map { URL(fileURLWithPath: $0) }
    }
    private var baseline: Bool { ProcessInfo.processInfo.environment["VELOEDIT_VERTICAL_TITLE_BASELINE"] == "1" }

    private func sample(_ template: TitleTemplateDefinition, scenario: Int) -> TitleTimelineItem {
        var item = template.previewItem()
        if scenario == 1 || scenario == 3 {
            switch template.category {
            case .captions: item.text = "Мы продолжаем путешествие и встречаем рассвет у моря"
            case .lowerThirds: item.text = "АЛЕКСАНДРА КОНСТАНТИНОВА"
            case .locationTitles: item.text = "ПЕТРОПАВЛОВСК-КАМЧАТСКИЙ"
            case .dateTime: item.text = "16 СЕНТЯБРЯ 2026"
            case .dynamicKinetic: item.text = "ПУТЕШЕСТВИЕ НАЧИНАЕТСЯ"
            case .endCards: item.text = "ДО НОВЫХ ВСТРЕЧ"
            default: item.text = "ПУТЕШЕСТВИЕ ПО СЕВЕРНОМУ ПОБЕРЕЖЬЮ"
            }
            item.additionalText = "КАРЕЛИЯ · СЕНТЯБРЬ 2026"
            item.callToAction = "СОХРАНИТЕ ЭТУ ИСТОРИЮ"
            item.setChapterNumber(123)
        }
        if scenario == 4 { item.additionalText = nil; item.callToAction = nil }
        if scenario == 5 { item.style.fontSize *= 1.3; item.style.textColorHex = "#FFD60A" }
        if item.kind == .wordLevelCaptions {
            let words = item.text.split(whereSeparator: \.isWhitespace)
            let highlighted = words.dropFirst().first ?? words.first ?? ""
            item.words = [CaptionWord(word: String(highlighted), start: 0, end: item.duration)]
        }
        return item
    }

    private func background(_ scenario: Int, size: CGSize) throws -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        switch scenario {
        case 1: return CIImage(color: .white).cropped(to: bounds)
        case 2, 3:
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let url = root.appendingPathComponent("Resources/TransitionPreviews/moraine-lake.jpg")
            let image = try #require(CIImage(contentsOf: url))
            let scale = max(size.width / image.extent.width, size.height / image.extent.height)
            let fitted = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return fitted.transformed(by: CGAffineTransform(translationX: (size.width - fitted.extent.width) / 2,
                                                          y: (size.height - fitted.extent.height) / 2)).cropped(to: bounds)
        case 5:
            return try #require(CIFilter(name: "CICheckerboardGenerator", parameters: [
                "inputColor0": CIColor(red: 0.02, green: 0.14, blue: 0.04), "inputColor1": CIColor.white,
                "inputWidth": 5, "inputSharpness": 1
            ])?.outputImage).cropped(to: bounds)
        default: return CIImage(color: CIColor(red: 0.035, green: 0.045, blue: 0.065)).cropped(to: bounds)
        }
    }

    @Test func allTemplatesAcrossPortraitScenarios() throws {
        let scenarios = ["Default / dark", "Long / white", "Default / scenery", "Long / scenery", "No subtitle", "Size +30% / texture"]
        var rows = ["template,scenario,element,font_at_360px,lines,truncated,outside_safe,glyph_collisions"]
        var problems: [String] = []
        for template in TitleTemplateRegistry.all {
            var frames: [(String, CGImage)] = []
            for scenario in scenarios.indices {
                let item = sample(template, scenario: scenario)
                let regions = TitleOverlayRenderer.textLayout(item: item, timelineTime: 1.5, renderSize: size)
                let expected = template.layout.elements.filter { element in
                    guard element.kind == .text else { return false }
                    switch element.content {
                    case .primaryText, .activeCaption, .chapterNumber: return true
                    case .secondaryText: return item.additionalText?.isEmpty == false
                    case .callToAction: return item.callToAction?.isEmpty == false
                    case .none: return element.fixedText?.isEmpty == false
                    }
                }.map(\.id)
                let missing = Set(expected).subtracting(regions.map(\.elementID))
                if !missing.isEmpty { problems.append("\(template.name) / \(scenario): missing \(missing.sorted())") }
                if !baseline { #expect(missing.isEmpty) }
                let safe = template.safeArea.rect(in: size).insetBy(dx: -1, dy: -1)
                for region in regions {
                    let truncated = region.renderedText.contains("…")
                    let outside = !safe.contains(region.bounds)
                    let overlaps = regions.filter { $0.elementID != region.elementID && $0.lineRects.contains { other in region.lineRects.contains { $0.intersects(other) } } }.count
                    rows.append("\(template.name),\(scenario),\(region.elementID),\(region.fontSize),\(region.lineRects.count),\(truncated),\(outside),\(overlaps)")
                    if truncated || outside || overlaps > 0 || region.fontSize < 10 {
                        problems.append("\(template.name) / \(scenarios[scenario]) / \(region.elementID): font=\(String(format: "%.1f", region.fontSize)), truncated=\(truncated), outside=\(outside), collisions=\(overlaps)")
                    }
                    if !baseline {
                        #expect(!truncated, "\(template.name) / \(scenario): \(region.requestedText)")
                        #expect(!outside, "\(template.name) / \(scenario): \(region.elementID) outside safe area")
                        #expect(overlaps == 0, "\(template.name) / \(scenario): intersecting glyphs")
                        #expect(region.fontSize >= 10, "\(template.name) / \(scenario): unreadable \(region.elementID)")
                    }
                }
                let bg = try background(scenario, size: size)
                let rendered = TitleOverlayRenderer.composited(item: item, timelineTime: 1.5, renderSize: size,
                    over: bg, adaptation: AdaptiveTitleBackgroundRenderer(subjectDetector: { _, _ in [] }))
                let frame = try #require(context.createCGImage(rendered, from: CGRect(origin: .zero, size: size)))
                frames.append((scenarios[scenario], frame))
            }
            if let output { try sheet(frames, columns: 3, to: output.appendingPathComponent("\(template.id).png")) }
        }
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try rows.joined(separator: "\n").write(to: output.appendingPathComponent("measurements.csv"), atomically: true, encoding: .utf8)
            try problems.joined(separator: "\n").write(to: output.appendingPathComponent("findings.txt"), atomically: true, encoding: .utf8)
        }
        print("VERTICAL AUDIT: \(TitleTemplateRegistry.all.count * scenarios.count) scenarios; \(problems.count) text problems")
    }

    @Test func portraitAccentBarsStayOutsideTextAndPanelsContainTheirLabels() throws {
        for id in ["title.modern.v1", "title.lower-third.v1", "caption.word-focus.v1"] {
            let template = try #require(TitleTemplateRegistry.template(id: id))
            for size in [CGSize(width: 360, height: 640), CGSize(width: 360, height: 780), CGSize(width: 1080, height: 1350), CGSize(width: 1080, height: 1080), CGSize(width: 1920, height: 1080)] {
                let layout = AdaptiveTitleLayout.resolve(template: template, renderSize: size)
                let panel = try #require(layout.element(id: "panel") ?? layout.element(id: "caption-bg"))
                let accent = try #require(layout.element(id: "accent"))
                for text in layout.elements where text.kind == .text {
                    #expect(!accent.frame.intersects(text.frame), "\(id): accent crosses \(text.id) at \(size)")
                    #expect(panel.frame.contains(text.frame), "\(id): \(text.id) leaves panel at \(size)")
                }
            }
        }
    }

    @Test func shortPortraitTitlesHaveASettledReadableMiddleFrame() throws {
        for template in TitleTemplateRegistry.all {
            for duration in [0.4, 0.8, 1.2] {
                var item = template.previewItem()
                item.duration = duration
                let regions = TitleOverlayRenderer.textLayout(item: item, timelineTime: duration * 0.5, renderSize: size)
                #expect(!regions.isEmpty)
                #expect(regions.allSatisfy { $0.visibility > 0.98 }, "\(template.name), \(duration)s: text never fully appears")
            }
        }
    }

    @Test func verticalMixedSourcesAndRotatedPhoneVideoMatchExport() async throws {
        let root = output?.appendingPathComponent("playback") ?? FileManager.default.temporaryDirectory.appendingPathComponent("portrait-parity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if output == nil { try? FileManager.default.removeItem(at: root) } }
        let segment = 10.0
        var assets: [MediaAsset] = []
        for (index, canvas) in [size, CGSize(width: 640, height: 360), CGSize(width: 640, height: 360)].enumerated() {
            let imageURL = root.appendingPathComponent("source-\(index).png")
            let upright = try background(index == 1 ? 1 : 2, size: index == 2 ? size : canvas)
            // A phone stores rotated pixels plus a track transform. Encode
            // the inverse rotation so applying that metadata restores an
            // upright scene, rather than making the fixture itself sideways.
            let bg = index == 2 ? upright.transformed(by:
                CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)) : upright
            try png(try #require(context.createCGImage(bg, from: CGRect(origin: .zero, size: canvas))), to: imageURL)
            var videoURL = try await StillImageVideoGenerator().generate(imageURL: imageURL, duration: segment,
                width: Int(canvas.width), height: Int(canvas.height), frameRate: 20,
                destination: root.appendingPathComponent("source-\(index).mov"), codec: .jpeg, motion: nil)
            if index == 2 {
                let asset = AVURLAsset(url: videoURL)
                let source = try #require(try await asset.loadTracks(withMediaType: .video).first)
                let format = try #require(try await source.load(.formatDescriptions).first)
                let rotatedURL = root.appendingPathComponent("phone-rotation.mov")
                try? FileManager.default.removeItem(at: rotatedURL)
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: source, outputSettings: nil)
                reader.add(output)
                let writer = try AVAssetWriter(outputURL: rotatedURL, fileType: .mov)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
                input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: canvas.height, ty: 0)
                writer.add(input)
                try #require(reader.startReading(), "Phone fixture reader: \(String(describing: reader.error))")
                try #require(writer.startWriting(), "Phone fixture writer: \(String(describing: writer.error))")
                writer.startSession(atSourceTime: .zero)
                while let buffer = output.copyNextSampleBuffer() {
                    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                    try #require(input.append(buffer), "Phone fixture copy: \(String(describing: writer.error))")
                }
                input.markAsFinished()
                await writer.finishWriting()
                try #require(writer.status == .completed, "Phone fixture finish: \(String(describing: writer.error))")
                videoURL = rotatedURL
            }
            assets.append(MediaAsset(originalURL: videoURL, kind: .video, byteSize: 1, contentHash: "portrait-\(UUID())",
                metadata: MediaMetadata(duration: segment, width: Int(index == 2 ? canvas.height : canvas.width),
                    height: Int(index == 2 ? canvas.width : canvas.height), frameRate: 20, hasAudio: false)))
        }
        let titles = TitleTemplateRegistry.all.enumerated().map { index, template in
            var item = sample(template, scenario: index % 2 == 0 ? 0 : 1)
            item.startTime = 0.5 + Double(index) * 2; item.duration = 1.8
            return item
        }
        var timeline = Timeline(storyPlanID: UUID(), width: 360, height: 640, frameRate: 20,
            items: assets.enumerated().map { index, asset in
                TimelineItem(assetID: asset.id, kind: .video, sourceDuration: segment,
                    timelineStart: Double(index) * segment, timelineDuration: segment,
                    videoAdjustments: VideoAdjustments(crop: index == 1 ? .fit : .fill))
            }, titleItems: titles)
        timeline = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(timeline))
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: assets, preferStableRealtimePreview: true)
        let preview = generator(playback.composition); preview.videoComposition = playback.videoComposition
        let movieURL = root.appendingPathComponent("vertical-titles.mp4")
        let report = try await RenderEngine().render(timeline: timeline, assets: assets, quality: .maximum, destination: movieURL)
        #expect(report.skippedItemIDs.isEmpty)
        let exported = generator(AVURLAsset(url: movieURL))
        var rows = ["template,time,mean_pixel_error"]
        var pairs: [(String, CGImage)] = []
        for title in titles {
            for local in [0.2, 0.9, 1.6] {
                let time = CMTime(seconds: title.startTime + local, preferredTimescale: 600)
                let live = try preview.copyCGImage(at: time, actualTime: nil)
                let encoded = try exported.copyCGImage(at: time, actualTime: nil)
                #expect(live.width == 360 && live.height == 640)
                #expect(encoded.width == 360 && encoded.height == 640)
                let lhs = pixels(live), rhs = pixels(encoded)
                let delta = zip(lhs, rhs).enumerated().filter { $0.offset % 4 != 3 }.reduce(0.0) { $0 + Double(abs(Int($1.element.0) - Int($1.element.1))) } / Double(360 * 640 * 3 * 255)
                #expect(delta < 0.045, "\(title.effectiveTemplateID ?? "") at \(local): preview/export mismatch \(delta)")
                rows.append("\(title.effectiveTemplateID ?? ""),\(title.startTime + local),\(delta)")
                if local == 0.9 { pairs.append(("Preview / \(title.kind.rawValue)", live)); pairs.append(("Export", encoded)) }
            }
        }
        try rows.joined(separator: "\n").write(to: root.appendingPathComponent("comparison.csv"), atomically: true, encoding: .utf8)
        for index in stride(from: 0, to: pairs.count, by: 8) {
            try sheet(Array(pairs[index..<min(pairs.count, index + 8)]), columns: 4, to: root.appendingPathComponent("comparison-\(index / 8).png"))
        }
    }

    private func generator(_ asset: AVAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let bounds = CGRect(x: 0, y: 0, width: 360, height: 640)
        var bytes = [UInt8](repeating: 0, count: 360 * 640 * 4)
        bytes.withUnsafeMutableBytes { context.render(CIImage(cgImage: image), toBitmap: $0.baseAddress!, rowBytes: 360 * 4,
            bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) }
        return bytes
    }

    @Test func portraitMotionAndFormatsKeepReadableTextInsideCanvas() throws {
        for template in TitleTemplateRegistry.all {
            for size in [CGSize(width: 360, height: 640), CGSize(width: 360, height: 780), CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1350)] {
                let item = sample(template, scenario: 1)
                for fraction in [0.1, 0.2, 0.35, 0.5, 0.75, 0.9] {
                    let regions = TitleOverlayRenderer.textLayout(item: item, timelineTime: item.duration * fraction, renderSize: size)
                    for region in regions where region.visibility > 0.95 {
                        #expect(CGRect(origin: .zero, size: size).contains(region.bounds), "\(template.name) at \(fraction), \(size)")
                    }
                }
                #expect(TitleOverlayRenderer.cgImage(item: item, timelineTime: item.endTime, renderSize: size) == nil)
            }
        }
    }

    private func sheet(_ frames: [(String, CGImage)], columns: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let width = frames[0].1.width, height = frames[0].1.height, header = 28
        let rows = (frames.count + columns - 1) / columns
        let canvas = try #require(CGContext(data: nil, width: width * columns, height: (height + header) * rows,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(gray: 0.08, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        for (index, entry) in frames.enumerated() {
            let x = (index % columns) * width, y = (rows - 1 - index / columns) * (height + header)
            canvas.draw(entry.1, in: CGRect(x: x, y: y, width: width, height: height))
            let label = NSAttributedString(string: entry.0, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 12, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1)
            ])
            canvas.textPosition = CGPoint(x: x + 10, y: y + height + 9)
            CTLineDraw(CTLineCreateWithAttributedString(label), canvas)
        }
        try png(try #require(canvas.makeImage()), to: url)
    }

    private func png(_ image: CGImage, to url: URL) throws {
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        #expect(CGImageDestinationFinalize(writer))
    }
}
