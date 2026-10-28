import Foundation
import CoreGraphics
import Testing
@testable import VeloEditCore

struct ControlExportIdentityTests {
    private func key(_ timeline: Timeline, _ assets: [MediaAsset]) -> String {
        EditorialRenderDependencies.artifactSignature(timeline: timeline, assets: assets, tracks: [])
    }

    @Test func identicalPlainRenderCanReuseFileWithoutReusingTimelineCertificates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("original.mov")
        try Data("unchanged source bytes".utf8).write(to: file)
        let asset = MediaAsset(originalURL: file, kind: .video, byteSize: 22, contentHash: "source",
            metadata: .init(duration: 8, width: 1920, height: 1080, frameRate: 30))
        var first = Timeline(storyPlanID: UUID(), items: [TimelineItem(assetID: asset.id,
            kind: .video, sourceStart: 1, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)])
        var title = TitleTimelineItem(kind: .chapter, text: "У реки", startTime: 0, duration: 2)
        title.anchorClipID = first.items[0].id
        title.targetClipID = first.items[0].id
        title.filmPartID = UUID()
        first.titleItems = [title]
        var second = first
        second.id = UUID(); second.storyPlanID = UUID(); second.createdAt = Date()
        second.items[0].id = UUID()
        second.titleItems?[0].id = UUID()
        second.titleItems?[0].anchorClipID = second.items[0].id
        second.titleItems?[0].targetClipID = second.items[0].id
        second.titleItems?[0].filmPartID = UUID()
        #expect(key(first, [asset]) == key(second, [asset]))
        // Exact source/MP4 item receipts still use the ordinary signature.
        #expect(EditorialRenderSignature.signature(first) != EditorialRenderSignature.signature(second))

        var changed = second; changed.items[0].sourceStart += 0.1
        #expect(key(first, [asset]) != key(changed, [asset]))
        changed = second; changed.titleItems?[0].text = "У леса"
        #expect(key(first, [asset]) != key(changed, [asset]))
        changed = second; changed.titleItems?[0].startTime += 0.1
        #expect(key(first, [asset]) != key(changed, [asset]))
        changed = second; changed.originalAudioVolume = 0.2
        #expect(key(first, [asset]) != key(changed, [asset]))
        changed = second; changed.frameRate = 60
        #expect(key(first, [asset]) != key(changed, [asset]))
        changed = second; changed.endingFadeDuration = 1
        #expect(key(first, [asset]) != key(changed, [asset]))
        changed = second; changed.titleItems?[0].targetClipID = UUID()
        #expect(key(first, [asset]) != key(changed, [asset]))
        var updatedAsset = asset; updatedAsset.metadata.frameRate = 24
        #expect(key(first, [asset]) != key(first, [updatedAsset]))
        let previous = key(first, [asset])
        try Data("replaced source bytes".utf8).write(to: file, options: .atomic)
        #expect(previous != key(first, [asset]))
    }

    @Test func staticPushInIdentityRetainsItsExactTransformAndTarget() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("source".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let asset = MediaAsset(originalURL: file, kind: .video,
            byteSize: 6, contentHash: "source", metadata: .init(duration: 8, width: 1920, height: 1080))
        var first = Timeline(storyPlanID: UUID(), items: [TimelineItem(assetID: asset.id,
            kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)])
        first.effects = [EffectTimelineItem(effectType: .pushIn, startTime: 0, duration: 4,
            parameters: EffectPresetRegistry.preset(for: .pushIn).defaultParameters,
            intensity: 0.12, targetClipID: first.items[0].id)]
        var second = first; second.id = UUID(); second.storyPlanID = UUID(); second.items[0].id = UUID()
        second.effects?[0].id = UUID(); second.effects?[0].targetClipID = second.items[0].id
        #expect(key(first, [asset]) == key(second, [asset]))
        #expect(EditorialRenderSignature.signature(first) != EditorialRenderSignature.signature(second))
        for time in [0.0, 0.01, 1, 2, 3.99, 4] {
            let a = first.effectiveEffects.filter { $0.affects(clipID: first.items[0].id, timelineTime: time) }
            let b = second.effectiveEffects.filter { $0.affects(clipID: second.items[0].id, timelineTime: time) }
            let size = CGSize(width: 1920, height: 1080)
            #expect(TransitionEffectRenderer.effectTransform(a, base: .identity, timelineTime: time, renderSize: size)
                == TransitionEffectRenderer.effectTransform(b, base: .identity, timelineTime: time, renderSize: size))
            #expect(TransitionEffectRenderer.effectOpacity(a, timelineTime: time)
                == TransitionEffectRenderer.effectOpacity(b, timelineTime: time))
        }
        var changed = second; changed.effects?[0].intensity += 0.01
        #expect(key(first, [asset]) != key(changed, [asset]))
        changed = second; changed.effects?[0].startTime += 0.01
        #expect(key(first, [asset]) != key(changed, [asset]))
        changed = second; changed.effects?[0].duration += 0.01
        #expect(key(first, [asset]) != key(changed, [asset]))
        changed = second; changed.effects?[0].targetClipID = UUID()
        #expect(key(changed, [asset]) == EditorialRenderDependencies.signature(timeline: changed, assets: [asset], tracks: []))
        changed = second; changed.effects?[0].effectType = .shake
        #expect(key(changed, [asset]) == EditorialRenderDependencies.signature(timeline: changed, assets: [asset], tracks: []))
        changed = second; changed.effects?.append(second.effectiveEffects[0])
        #expect(key(changed, [asset]) == EditorialRenderDependencies.signature(timeline: changed, assets: [asset], tracks: []))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_SAVED_RENDER_PROJECT"] != nil))
    func realRepeatedEditReusesPixelsWithoutTransferringItsCertificate() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VELOEDIT_SAVED_RENDER_PROJECT"])
        let root = URL(fileURLWithPath: path)
        let first = try JSONDecoder.veloEdit.decode(ProjectManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("prior-cached-2-project.json")))
        let second = try JSONDecoder.veloEdit.decode(ProjectManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("project.json")))
        let a = try #require(first.filmBuildRecovery?.draft?.timeline)
        let b = try #require(second.filmBuildRecovery?.draft?.timeline)
        #expect(a.items.map(\.sourceStart) == b.items.map(\.sourceStart))
        #expect(a.items.map(\.sourceDuration) == b.items.map(\.sourceDuration))
        #expect(a.effectiveTitleItems.map(\.text) == b.effectiveTitleItems.map(\.text))
        #expect(key(a, first.assets) == key(b, second.assets))
        #expect(EditorialRenderSignature.signature(a) != EditorialRenderSignature.signature(b))
    }

    @Test func unqualifiedEditTypesKeepConservativeIdentity() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("source".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let asset = MediaAsset(originalURL: file, kind: .video, byteSize: 6, contentHash: "source", metadata: .init(duration: 8))
        let first = Timeline(storyPlanID: UUID(), items: [TimelineItem(assetID: asset.id,
            kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4, speed: 2)])
        var second = first; second.id = UUID(); second.items[0].id = UUID()
        #expect(key(first, [asset]) != key(second, [asset]))
        #expect(key(first, [asset]) == EditorialRenderDependencies.signature(timeline: first, assets: [asset], tracks: []))
    }

    @Test func previewPixelReuseRebindsTitlesAndCannotTransferSemanticAudioOrMP4Proof() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var first = Timeline(storyPlanID: UUID(), items: [TimelineItem(kind: .video,
            sourceDuration: 4, timelineStart: 0, timelineDuration: 4)])
        let title = TitleTimelineItem(kind: .chapter, text: "У реки", startTime: 0, duration: 2)
        first.titleItems = [title]
        var frame = PerceptualRenderedFrameEvidence(timelineTime: 1, meanLuma: 80, lumaDeviation: 10, isBlack: false)
        frame.decodeFailed = false
        frame.titleEvidence = [TitleReadabilityEvidence(titleID: title.id,
            renderSignature: EditorialRenderSignature.signature(first), algorithmVersion: TitleReadabilityInspector.version,
            timelineTime: 1, actualPTS: 1, source: "preview", expectedText: title.text,
            recognizedText: title.text, confidences: [1], pixelWidth: 1920, pixelHeight: 1080, score: 1)]
        frame.editorialClaims = [EditorialSemanticClaim(domain: .actionProgression, status: .passed,
            itemIDs: [first.items[0].id], probeTimes: [1], confidence: 1, observation: "fixture",
            method: "test", renderSignature: EditorialRenderSignature.signature(first))]
        frame.audioMasteringReport = EditorialAudioMasteringReport(appliedGainDB: 0, peakLimited: false, measuredFrames: 10)
        frame.exportVerification = EditorialExportVerification(renderSignature: EditorialRenderSignature.signature(first),
            probes: [], durationDifference: 0, aspectRatioMatches: true, provenance: "fixture")
        let preview = RenderedProbeCache(directory: root.appendingPathComponent("preview"), visualOnly: true)
        let complete = RenderedProbeCache(directory: root.appendingPathComponent("complete"))
        try await preview.store([frame], timeline: first, assets: [])
        try await complete.store([frame], timeline: first, assets: [])
        var second = first; second.id = UUID(); second.storyPlanID = UUID()
        second.items[0].id = UUID(); second.titleItems?[0].id = UUID()
        second.originalAudioVolume = 0.2
        let cached = try #require(await preview.load(timeline: second, assets: []))
        let rebound = try #require(cached.first?.titleEvidence?.first)
        #expect(rebound.titleID == second.titleItems?[0].id)
        #expect(rebound.isCurrent(for: second))
        #expect(rebound.pixelWidth == 1920 && rebound.pixelHeight == 1080)
        #expect(cached[0].editorialClaims == nil)
        #expect(cached[0].audioMasteringReport == nil)
        #expect(cached[0].exportVerification == nil)
        #expect(await complete.load(timeline: second, assets: []) == nil)
        var changed = second; changed.titleItems?[0].style.fontSize += 1
        #expect(await preview.load(timeline: changed, assets: []) == nil)
        changed = second; changed.items[0].sourceStart += 0.1
        #expect(await preview.load(timeline: changed, assets: []) == nil)
        changed = second; changed.titleItems?[0].duration += 0.1
        #expect(await preview.load(timeline: changed, assets: []) == nil)
        // Corrupt title mapping must not be used to reassign another title's OCR.
        let file = try #require(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("preview"), includingPropertiesForKeys: nil).first)
        var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        record["titleIDs"] = [UUID().uuidString]
        try JSONSerialization.data(withJSONObject: record).write(to: file)
        #expect(await preview.load(timeline: second, assets: []) == nil)
    }

}
