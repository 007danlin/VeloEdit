import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import VeloEditCore

@Test func professionalTransitionAndEffectCatalogsCoverTZ14Families() {
    let transitionCategories = Set(TransitionPresetRegistry.all.map(\.category))
    #expect(transitionCategories == Set(TransitionPresetCategory.allCases))
    #expect(TransitionPresetRegistry.all.count == TransitionStyle.allCases.count)
    #expect(Set(TransitionPresetRegistry.all.map(\.style)).isSuperset(of: [
        .cut, .crossDissolve, .fadeThroughBlack, .fadeToWhite, .dipToColor,
        .pushLeft, .pushRight, .pushUp, .pushDown, .slideLeft, .wipeRight,
        .zoomIn, .zoomOut, .whipLeft, .spin, .cameraPush, .cameraPull,
        .filmDissolve, .filmBurn, .lightLeak, .blurDissolve, .lensBlur, .exposureFlash,
        .glitch, .rgbSplit, .digitalDistortion, .pixelate, .shatter, .ripple, .wave,
        .circle, .iris, .radial, .geometricWipe, .maskReveal
    ]))

    #expect(Set(EffectPresetRegistry.all.map(\.category)) == Set(TimelineEffectCategory.allCases))
    #expect(EffectPresetRegistry.all.count == TimelineEffectType.allCases.count)
    #expect(Set(EffectPresetRegistry.all.map(\.type)).isSuperset(of: [
        .filmGrain, .vignette, .bloom, .glow, .lensBlur, .exposure,
        .motionBlur, .directionalBlur, .zoom, .shake, .cameraDrift,
        .chromaticAberration, .lensDistortion, .fisheye, .barrelDistortion,
        .glitch, .rgbSplit, .scanlines, .pixelate, .halftone,
        .lightLeak, .filmBurn, .dust, .noise, .fogHaze
    ]))
    #expect(TransitionPresetRegistry.all.allSatisfy { $0.version > 0 && !$0.semanticTags.isEmpty })
    #expect(EffectPresetRegistry.all.allSatisfy { $0.version > 0 && !$0.semanticTags.isEmpty })
}

@Test func sharedRendererKeepsExactTransitionEndpointsAndProducesLiveCards() throws {
    let bounds = CGRect(x: 0, y: 0, width: 24, height: 16)
    let outgoing = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
    let incoming = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: bounds)
    for style in TransitionStyle.allCases {
        let preset = TransitionPresetRegistry.preset(for: style)
        let item = TimelineTransitionItem(
            style: style,
            outgoingClipID: UUID(),
            incomingClipID: UUID(),
            startTime: 0,
            duration: preset.defaultDuration
        )
        let start = TransitionEffectRenderer.renderTransition(
            outgoing: outgoing, incoming: incoming, item: item, progress: 0, bounds: bounds
        )
        let end = TransitionEffectRenderer.renderTransition(
            outgoing: outgoing, incoming: incoming, item: item, progress: 1, bounds: bounds
        )
        let startPixel = try averagePixel(start, bounds: bounds)
        let endPixel = try averagePixel(end, bounds: bounds)
        #expect(startPixel.0 > 245 && startPixel.2 < 10, "\(style.rawValue) must start on outgoing")
        #expect(endPixel.2 > 245 && endPixel.0 < 10, "\(style.rawValue) must end on incoming")
        #expect(TransitionEffectRenderer.previewTransitionCGImage(style: style, progress: 0.5, size: bounds.size) != nil)
    }
    for effect in TimelineEffectType.allCases {
        #expect(TransitionEffectRenderer.previewEffectCGImage(type: effect, progress: 0.5, size: bounds.size) != nil)
    }
}

@Test func legacyTransitionDecodesWithMetadataDefaults() throws {
    let transition = TimelineTransitionItem(
        style: .lensBlur,
        outgoingClipID: UUID(),
        incomingClipID: UUID(),
        startTime: 3,
        duration: 0.7
    )
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder.veloEdit.encode(transition)) as? [String: Any])
    json.removeValue(forKey: "intensity")
    json.removeValue(forKey: "parameters")
    let decoded = try JSONDecoder.veloEdit.decode(
        TimelineTransitionItem.self,
        from: JSONSerialization.data(withJSONObject: json)
    )
    #expect(decoded.style == .lensBlur)
    #expect(decoded.effectiveIntensity == TransitionPresetRegistry.preset(for: .lensBlur).defaultIntensity)
    #expect(decoded.effectiveParameters == TransitionPresetRegistry.preset(for: .lensBlur).defaultParameters)
}

@Test func transitionReplacementPreservesPositionAndDurationAndDeleteRestoresCut() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Transitions")
    let first = TimelineItem(kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
    var second = TimelineItem(kind: .video, sourceDuration: 4, timelineStart: 4, timelineDuration: 4)
    second.transition = TransitionStyle.crossDissolve.rawValue
    let transition = TimelineTransitionItem(
        style: .crossDissolve,
        outgoingClipID: first.id,
        incomingClipID: second.id,
        startTime: 4,
        duration: 0.83
    )
    try await store.update {
        $0.timelines = [Timeline(storyPlanID: UUID(), items: [first, second], transitionItems: [transition])]
    }
    let pipeline = VeloEditPipeline(store: store)

    try await pipeline.updateTransitionTimelineItem(id: transition.id, style: .whipLeft)
    let replaced = try #require((await pipeline.snapshot()).timelines.last?.effectiveTransitionItems.first)
    #expect(replaced.style == .whipLeft)
    #expect(replaced.startTime == 4)
    #expect(replaced.duration == 0.83)
    #expect(replaced.effectiveParameters == TransitionPresetRegistry.preset(for: .whipLeft).defaultParameters)

    try await pipeline.deleteTransitionTimelineItem(id: transition.id)
    let deleted = try #require((await pipeline.snapshot()).timelines.last)
    #expect(deleted.effectiveTransitionItems.isEmpty)
    #expect(deleted.items.first(where: { $0.id == second.id })?.transition == nil)
}

@Test func semanticSelectorUsesMotionAndGuardsCreativeAccents() {
    let selector = TransitionSemanticSelector()
    let motion = selector.select(for: TransitionSemanticContext(
        energy: 0.82,
        previousMovementX: 0.32,
        incomingMovementX: 0.28
    ))
    #expect(motion?.style == .whipLeft)
    #expect(motion?.explanation.localizedCaseInsensitiveContains("движ") == true)

    let guardedDrop = selector.select(for: TransitionSemanticContext(energy: 0.9, musicDrop: true))
    #expect(guardedDrop?.style == .exposureFlash)
    #expect(guardedDrop?.style != .glitch)

    let requestedGlitch = selector.select(for: TransitionSemanticContext(
        energy: 0.9,
        musicDrop: true,
        explicitCreativeRequest: true
    ))
    #expect(requestedGlitch?.style == .glitch)

    let calm = selector.select(for: TransitionSemanticContext(energy: 0.28, emotion: "спокойная ностальгия"))
    #expect(calm?.style == .crossDissolve)
    #expect(selector.select(for: TransitionSemanticContext(energy: 0.62)) == nil)

    let effectSelector = EffectSemanticSelector()
    let photo = effectSelector.select(for: EffectSemanticContext(isPhoto: true, energy: 0.32, stability: 1))
    #expect(photo?.type == .cameraDrift)
    let guardedDigital = effectSelector.select(for: EffectSemanticContext(
        isPhoto: false, energy: 0.9, stability: 0.8, tags: ["digital"]
    ))
    #expect(guardedDigital?.type != .rgbSplit)
    let explicitDigital = effectSelector.select(for: EffectSemanticContext(
        isPhoto: false, energy: 0.9, stability: 0.8, tags: ["digital"], explicitCreativeRequest: true
    ))
    #expect(explicitDigital?.type == .rgbSplit)
}

private func averagePixel(_ image: CIImage, bounds: CGRect) throws -> (UInt8, UInt8, UInt8, UInt8) {
    let filter = try #require(CIFilter(name: "CIAreaAverage"))
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(CIVector(cgRect: bounds), forKey: kCIInputExtentKey)
    let output = try #require(filter.outputImage)
    var pixel = [UInt8](repeating: 0, count: 4)
    CIContext(options: [.cacheIntermediates: false]).render(
        output,
        toBitmap: &pixel,
        rowBytes: 4,
        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        format: .RGBA8,
        colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    return (pixel[0], pixel[1], pixel[2], pixel[3])
}
