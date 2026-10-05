import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import VeloEditCore

private let auditFCPDTD = ProcessInfo.processInfo.environment["VELOEDIT_FCPXML_DTD"]
    ?? "/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_11.dtd"

@Suite(.serialized)
struct ApplicationAuditRegressionTests {
    @Test func titleStylesBelongToTheirTitlesWithUniqueIDs() throws {
        let (timeline, assets) = xmlFixture()
        let document = try XMLDocument(xmlString: FCPXMLExporter().xml(timeline: timeline, assets: assets))
        #expect(try document.nodes(forXPath: "/fcpxml/resources/text-style-def").isEmpty)
        #expect(try document.nodes(forXPath: "//sequence/spine/*[@lane]").isEmpty)
        #expect(try document.nodes(forXPath: "//asset-clip/title").count == 2)
        #expect(try document.nodes(forXPath: "/fcpxml/resources/effect/@uid").first?.stringValue?.contains("Bumper:Opener") == true)
        let titles = try document.nodes(forXPath: "//title")
        #expect(titles.count == 4)
        var ids: Set<String> = []
        for title in titles {
            let style = try #require(title.nodes(forXPath: "text-style-def").first as? XMLElement)
            let id = try #require(style.attribute(forName: "id")?.stringValue)
            #expect(ids.insert(id).inserted)
            let reference = try #require(title.nodes(forXPath: "text/text-style/@ref").first?.stringValue)
            #expect(reference == id)
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: auditFCPDTD), "Requires Apple's FCPXML 1.11 DTD (installed FCP or VELOEDIT_FCPXML_DTD)"))
    func exportedTitlesEffectsAndTransitionsPassFinalCutDTD() throws {
        let (timeline, assets) = xmlFixture()
        let exporter = FCPXMLExporter()
        for mode in [FCPXMLExportMode.edit, .selects] {
            let xml = try exporter.xml(timeline: timeline, assets: assets, mode: mode,
                                      renderedFallbackURL: URL(fileURLWithPath: "/tmp/rendered-reference.mp4"))
            try validateDTD(xml)
            var bare = timeline
            bare.titleItems = []; bare.effects = []; bare.transitionItems = []
            bare.items.removeAll { $0.kind == .title }
            try validateDTD(exporter.xml(timeline: bare, assets: assets, mode: mode))
        }
    }

    @Test func mixedFolderImportReportsEachFileAndPersistsRetryResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-audit-import-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let photo = media.appendingPathComponent("Фото 🎬.png")
        let context = try #require(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(photo as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        try Data().write(to: media.appendingPathComponent("zero.mp4"))
        try Data("damaged".utf8).write(to: media.appendingPathComponent("broken.png"))
        try Data("unknown".utf8).write(to: media.appendingPathComponent("unsupported.xyz"))
        let missing = root.appendingPathComponent("missing.mov")
        let package = root.appendingPathComponent("Test.veloedit")
        let store = try ProjectStore(createAt: package, name: "Audit")
        let pipeline = VeloEditPipeline(store: store)
        #expect(try await pipeline.importMedia([photo]).isEmpty)
        let warnings = try await pipeline.importMedia([media, missing])
        #expect(warnings.count == 4)
        let report = try #require(await store.manifest.lastImportReport)
        #expect(report.entries.count == 5)
        #expect(report.entries.first { $0.url == photo }?.outcome == .duplicate)
        #expect(report.entries.first { $0.url.lastPathComponent == "zero.mp4" }?.message.contains("0 байт") == true)
        #expect(report.entries.first { $0.url.lastPathComponent == "broken.png" }?.message.contains("повреждён") == true)
        #expect(report.entries.first { $0.url.lastPathComponent == "unsupported.xyz" }?.message.contains("не поддерживается") == true)
        #expect(report.entries.first { $0.url == missing }?.message.contains("недоступны") == true)
        #expect(await store.manifest.assets.count == 1)
        let reopened = try ProjectStore(open: package)
        #expect(await reopened.manifest.lastImportReport?.text == report.text)
        let corrected = media.appendingPathComponent("broken.png")
        try FileManager.default.removeItem(at: corrected)
        try FileManager.default.copyItem(at: photo, to: corrected)
        _ = try await pipeline.importMedia(report.failures.map(\.url))
        #expect(await store.manifest.lastImportReport?.failures.count == 3)
        #expect(await store.manifest.assets.count == 1)
    }

    @Test func longUnbrokenTitlesRemainBoundedAcrossTemplatesAndFrames() throws {
        for template in TitleTemplateRegistry.all {
            var item = template.previewItem()
            item.animation = .init(entrance: .none, exit: .none)
            item.text = String(String(repeating: "ОченьДлинноеСловоБезПробелов", count: 8).prefix(200))
            for size in [CGSize(width: 480, height: 270), CGSize(width: 270, height: 480)] {
                let first = try #require(TitleOverlayRenderer.textSizing(item: item, renderSize: size))
                #expect(first.isTruncated)
                for time in [0.5, 1.0, 1.5] {
                    #expect(TitleOverlayRenderer.cgImage(item: item, timelineTime: time, renderSize: size) != nil)
                    let sizing = try #require(TitleOverlayRenderer.textSizing(item: item, renderSize: size))
                    #expect(sizing.fontSize == first.fontSize)
                    #expect(sizing.lineCount == 1)
                }
                item.style.textColorHex = "#FF0000"
                item.text = "ЛЕТО\nSummer 🎬"
                let revised = try #require(TitleOverlayRenderer.textSizing(item: item, renderSize: size))
                #expect(!revised.isTruncated)
                item.text = String(String(repeating: "ОченьДлинноеСловоБезПробелов", count: 8).prefix(200))
            }
        }
    }

    private func validateDTD(_ xml: String) throws {
        let document = try XMLDocument(xmlString: xml)
        let dtd = try XMLDTD(contentsOf: URL(fileURLWithPath: auditFCPDTD))
        dtd.name = "fcpxml"
        document.dtd = dtd
        try document.validate()
    }

    private func xmlFixture() -> (Timeline, [MediaAsset]) {
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/Clip & 1.mov"), kind: .video, byteSize: 1,
            contentHash: "fixture", metadata: .init(duration: 30, width: 1920, height: 1080, frameRate: 30, hasAudio: true))
        let first = TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
        let second = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 4, sourceDuration: 4, timelineStart: 4, timelineDuration: 4, transition: "cross-dissolve")
        let legacy = (0..<2).map { TimelineItem(kind: .title, sourceDuration: 2, timelineStart: Double(8 + $0 * 2), timelineDuration: 2, title: "Титр \($0) 🎬") }
        let titles = (0..<2).map { TitleTimelineItem(kind: .title, text: "Аудит 🎬 — Русский\nLatin & <xml> \($0)", startTime: Double($0 * 2), duration: 2) }
        let effect = EffectTimelineItem(effectType: .filmGrain, startTime: 0, duration: 4, targetClipID: first.id)
        let transition = TimelineTransitionItem(style: .crossDissolve, outgoingClipID: first.id, incomingClipID: second.id, startTime: 4)
        return (Timeline(storyPlanID: UUID(), items: [first, second] + legacy, effects: [effect], titleItems: titles, transitionItems: [transition]), [asset])
    }
}
