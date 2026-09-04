import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VeloEditCore

private func framingTracking(
    region: NormalizedRegion = NormalizedRegion(x: 0.66, y: 0.30, width: 0.12, height: 0.28),
    confidence: Double = 0.92
) -> SubjectTrackingSummary {
    let track = SubjectTrack(
        kind: .person,
        label: "person",
        observations: [
            SubjectTrackObservation(timestamp: 0, region: region, confidence: confidence),
            SubjectTrackObservation(timestamp: 3, region: region, confidence: confidence)
        ],
        meanConfidence: confidence,
        visibility: 0.90,
        compositionQuality: 0.88
    )
    return SubjectTrackingSummary(
        tracks: [track],
        mainSubjectID: track.id,
        confidence: confidence,
        analyzedFrameCount: 2
    )
}

private func framingPlan(
    centerX: Double,
    centerY: Double = 0.5,
    endCenterX: Double? = nil,
    endScale: Double = 1
) -> SubjectReframePlan {
    SubjectReframePlan(
        startCenterX: centerX,
        startCenterY: centerY,
        endCenterX: endCenterX ?? centerX,
        endCenterY: centerY,
        startScale: 1,
        endScale: endScale,
        targetAspectRatio: 9.0 / 16.0,
        confidence: 0.95
    )
}

@Test func subjectReframeCentersFocusUsingAspectFillSourceDimensions() {
    let source = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let renderSize = CGSize(width: 1080, height: 1920)
    let fillScale = renderSize.height / source.height
    let base = CGAffineTransform(
        a: fillScale,
        b: 0,
        c: 0,
        d: fillScale,
        tx: (renderSize.width - source.width * fillScale) / 2,
        ty: 0
    )
    let transform = SubjectReframeGeometry.transform(
        base: base,
        sourceExtent: source,
        plan: framingPlan(centerX: 0.80),
        progress: 0,
        renderSize: renderSize
    )

    let focus = CGPoint(x: source.width * 0.80, y: source.height * 0.50).applying(transform)
    let extent = source.applying(transform).standardized
    #expect(abs(focus.x - renderSize.width / 2) < 0.001)
    #expect(abs(focus.y - renderSize.height / 2) < 0.001)
    #expect(extent.minX <= 0.001)
    #expect(extent.maxX >= renderSize.width - 0.001)
    #expect(extent.minY <= 0.001)
    #expect(extent.maxY >= renderSize.height - 0.001)
}

@Test func subjectReframeClampsExtremeFocusWithoutExposingCanvas() {
    let source = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let renderSize = CGSize(width: 1080, height: 1920)
    let fillScale = renderSize.height / source.height
    let base = CGAffineTransform(
        a: fillScale,
        b: 0,
        c: 0,
        d: fillScale,
        tx: (renderSize.width - source.width * fillScale) / 2,
        ty: 0
    )
    let transform = SubjectReframeGeometry.transform(
        base: base,
        sourceExtent: source,
        plan: framingPlan(centerX: 0.99),
        progress: 0,
        renderSize: renderSize
    )
    let extent = source.applying(transform).standardized
    #expect(extent.minX <= 0.001)
    #expect(extent.maxX >= renderSize.width - 0.001)
    #expect(extent.minY <= 0.001)
    #expect(extent.maxY >= renderSize.height - 0.001)
}

@Test func safeFitBackgroundExpandsLetterboxedFrameToCoverCanvas() throws {
    let source = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let renderSize = CGSize(width: 1080, height: 1920)
    let fitScale = renderSize.width / source.width
    let foreground = CGAffineTransform(
        a: fitScale,
        b: 0,
        c: 0,
        d: fitScale,
        tx: 0,
        ty: (renderSize.height - source.height * fitScale) / 2
    )
    let background = try #require(SafeFitBackgroundGeometry.aspectFillTransform(
        foregroundTransform: foreground,
        sourceExtent: source,
        renderSize: renderSize
    ))
    let extent = source.applying(background).standardized
    #expect(extent.minX <= 0.001)
    #expect(extent.maxX >= renderSize.width - 0.001)
    #expect(extent.minY <= 0.001)
    #expect(extent.maxY >= renderSize.height - 0.001)
}

@Test func canvasChangeUsesDisplayAspectAndChoosesSubjectAwareFill() throws {
    // Video dimensions are already display-oriented. orientationDegrees must
    // not swap them a second time.
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/oriented-video.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "oriented-video",
        metadata: MediaMetadata(
            duration: 10,
            width: 1920,
            height: 1080,
            frameRate: 30,
            hasAudio: false,
            orientationDegrees: 90
        )
    )
    let candidate = Candidate(
        assetID: asset.id,
        sourceStart: 0,
        sourceDuration: 5,
        scores: ClipScores(quality: 0.9, interest: 0.9, action: 0.5, stability: 0.9),
        insights: CandidateInsights(subjectTracking: framingTracking())
    )
    let item = TimelineItem(
        candidateID: candidate.id,
        assetID: asset.id,
        kind: .video,
        sourceDuration: 5,
        timelineStart: 0,
        timelineDuration: 5
    )
    let source = Timeline(storyPlanID: UUID(), items: [item])
    let result = DirectorEditingTools().apply(
        [.setCanvas(width: 1080, height: 1920, subjectAware: true, reason: "portrait")],
        to: source,
        assets: [asset],
        analyses: [AnalysisResult(assetID: asset.id, analyzedContentHash: "a", candidates: [candidate])]
    ).timeline

    let adjustments = try #require(result.items.first?.videoAdjustments)
    #expect(result.width == 1080)
    #expect(result.height == 1920)
    #expect(adjustments.crop == .fill)
    #expect(adjustments.subjectReframe != nil)
}

@Test func canvasChangeClearsStaleReframeAndSafelyFitsWithoutTracking() throws {
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/untracked.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "untracked",
        metadata: MediaMetadata(duration: 10, width: 1920, height: 1080, frameRate: 30)
    )
    let candidate = Candidate(
        assetID: asset.id,
        sourceStart: 0,
        sourceDuration: 5,
        scores: ClipScores(quality: 0.8, interest: 0.8, action: 0.5, stability: 0.8)
    )
    let stale = VideoAdjustments(crop: .fill, subjectReframe: framingPlan(centerX: 0.2))
    let item = TimelineItem(
        candidateID: candidate.id,
        assetID: asset.id,
        kind: .video,
        sourceDuration: 5,
        timelineStart: 0,
        timelineDuration: 5,
        videoAdjustments: stale
    )
    let source = Timeline(storyPlanID: UUID(), items: [item])
    let result = DirectorEditingTools().apply(
        [.setCanvas(width: 1080, height: 1920, subjectAware: true, reason: "portrait")],
        to: source,
        assets: [asset],
        analyses: [AnalysisResult(assetID: asset.id, analyzedContentHash: "a", candidates: [candidate])]
    ).timeline

    #expect(result.items[0].effectiveVideoAdjustments.crop == .fit)
    #expect(result.items[0].effectiveVideoAdjustments.subjectReframe == nil)
}

@Test func stillImageGeometryIncludesAspectFillBaseScale() {
    let placement = StillImageRenderGeometry.placement(
        sourceExtent: CGRect(x: 0, y: 0, width: 4000, height: 3000),
        targetSize: CGSize(width: 1080, height: 1920),
        motionScale: 1.10,
        horizontalTravel: 0,
        verticalTravel: 0,
        subjectReframe: nil,
        progress: 0.5
    )
    #expect(abs(placement.scale - 0.704) < 0.000_001)
    #expect(placement.x <= 0)
    #expect(placement.y <= 0)
}

@Test func stillImageFitGeometryPreservesFullFrame() {
    let placement = StillImageRenderGeometry.placement(
        sourceExtent: CGRect(x: 0, y: 0, width: 4000, height: 3000),
        targetSize: CGSize(width: 1080, height: 1920),
        motionScale: 1,
        horizontalTravel: 0,
        verticalTravel: 0,
        subjectReframe: nil,
        progress: 0,
        fill: false
    )
    #expect(abs(placement.scale - 0.27) < 0.000_001)
    #expect(abs(placement.x) < 0.000_001)
    #expect(abs(placement.y - 555) < 0.000_001)
}

@Test func stillImageLoaderAppliesExifOrientation() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("veloedit-exif-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("oriented.tiff")
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: 20,
        height: 40,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.tiff.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyOrientation: 6
    ] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))

    let oriented = try #require(StillImageRenderGeometry.orientedImage(at: url))
    #expect(Int(oriented.extent.width.rounded()) == 40)
    #expect(Int(oriented.extent.height.rounded()) == 20)
}

@Test func dynamicSubjectReframeRequiresRenderedFcpxmlFallback() {
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/reframe.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "reframe",
        metadata: MediaMetadata(duration: 5, width: 1920, height: 1080, frameRate: 30)
    )
    let adjustments = VideoAdjustments(
        crop: .fill,
        subjectReframe: framingPlan(centerX: 0.35, endCenterX: 0.70, endScale: 1.08)
    )
    let item = TimelineItem(
        assetID: asset.id,
        kind: .video,
        sourceDuration: 5,
        timelineStart: 0,
        timelineDuration: 5,
        videoAdjustments: adjustments
    )
    let timeline = Timeline(storyPlanID: UUID(), items: [item])
    #expect(FCPXMLExporter().requiresRenderedFallback(for: timeline))
}
