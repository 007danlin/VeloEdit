import Foundation
@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Vision

final class VeloCompositorLayer {
    let trackID: CMPersistentTrackID
    let item: TimelineItem
    let start: CMTime
    let duration: CMTime
    let transform: CGAffineTransform
    let telemetry: TelemetrySummary?

    init(trackID: CMPersistentTrackID, item: TimelineItem, start: CMTime, duration: CMTime, transform: CGAffineTransform, telemetry: TelemetrySummary? = nil) {
        self.trackID = trackID
        self.item = item
        self.start = start
        self.duration = duration
        self.transform = transform
        self.telemetry = telemetry
    }
}

final class VeloTelemetryLayer {
    let item: TimelineTelemetryItem
    let telemetry: TelemetrySummary
    let targetClip: TimelineItem?
    let start: CMTime
    let duration: CMTime

    init(item: TimelineTelemetryItem, telemetry: TelemetrySummary, targetClip: TimelineItem?, start: CMTime, duration: CMTime) {
        self.item = item
        self.telemetry = telemetry
        self.targetClip = targetClip
        self.start = start
        self.duration = duration
    }
}

/// Geometry shared by the runtime compositor and focused unit tests. Subject
/// coordinates are normalized in the display-oriented image. The base
/// transform already contains preferred orientation and aspect-fill, so its
/// transformed extent is the only reliable scale for a landscape-to-portrait
/// camera move.
enum SubjectReframeGeometry {
    static func transform(
        base: CGAffineTransform,
        sourceExtent: CGRect,
        plan: SubjectReframePlan,
        progress: Double,
        renderSize: CGSize
    ) -> CGAffineTransform {
        guard sourceExtent.width.isFinite, sourceExtent.height.isFinite,
              sourceExtent.width > 0, sourceExtent.height > 0,
              renderSize.width > 0, renderSize.height > 0 else { return base }

        let progress = min(max(0, progress), 1)
        let centerX = plan.startCenterX + (plan.endCenterX - plan.startCenterX) * progress
        let centerY = plan.startCenterY + (plan.endCenterY - plan.startCenterY) * progress
        let requestedScale = plan.startScale + (plan.endScale - plan.startScale) * progress
        let canvas = CGRect(origin: .zero, size: renderSize)
        let baseExtent = sourceExtent.applying(base).standardized
        guard baseExtent.width.isFinite, baseExtent.height.isFinite,
              baseExtent.width > 0, baseExtent.height > 0 else { return base }

        // Old projects may contain a subject plan with crop=.fit. Raising the
        // minimum scale restores full canvas coverage before applying focus.
        let coverageScale = max(
            1,
            max(canvas.width / baseExtent.width, canvas.height / baseExtent.height)
        )
        let scale = CGFloat(max(requestedScale, Double(coverageScale)))
        let canvasCenter = CGPoint(x: canvas.midX, y: canvas.midY)
        let zoom = CGAffineTransform(translationX: canvasCenter.x, y: canvasCenter.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -canvasCenter.x, y: -canvasCenter.y)
        let zoomedBase = base.concatenating(zoom)
        let zoomedExtent = sourceExtent.applying(zoomedBase).standardized

        let focusBeforeZoom = CGPoint(
            x: baseExtent.minX + baseExtent.width * CGFloat(centerX),
            y: baseExtent.minY + baseExtent.height * CGFloat(centerY)
        )
        let focusAfterZoom = focusBeforeZoom.applying(zoom)
        let requestedX = canvas.midX - focusAfterZoom.x
        let requestedY = canvas.midY - focusAfterZoom.y

        // Translation is limited to the overscan supplied by aspect-fill and
        // digital zoom. This guarantees there is never an uncovered edge.
        let minimumX = canvas.maxX - zoomedExtent.maxX
        let maximumX = canvas.minX - zoomedExtent.minX
        let minimumY = canvas.maxY - zoomedExtent.maxY
        let maximumY = canvas.minY - zoomedExtent.minY
        let x = minimumX <= maximumX ? min(maximumX, max(minimumX, requestedX)) : 0
        let y = minimumY <= maximumY ? min(maximumY, max(minimumY, requestedY)) : 0
        return zoomedBase.concatenating(CGAffineTransform(translationX: x, y: y))
    }
}

enum SafeFitBackgroundGeometry {
    static func aspectFillTransform(
        foregroundTransform: CGAffineTransform,
        sourceExtent: CGRect,
        renderSize: CGSize
    ) -> CGAffineTransform? {
        let foregroundExtent = sourceExtent.applying(foregroundTransform).standardized
        guard foregroundExtent.width.isFinite, foregroundExtent.height.isFinite,
              foregroundExtent.width > 0, foregroundExtent.height > 0,
              renderSize.width > 0, renderSize.height > 0 else { return nil }
        let scale = max(
            renderSize.width / foregroundExtent.width,
            renderSize.height / foregroundExtent.height
        )
        guard scale > 1.001 else { return nil }
        let center = CGPoint(x: renderSize.width / 2, y: renderSize.height / 2)
        let fill = CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: center.x - foregroundExtent.midX * scale,
            ty: center.y - foregroundExtent.midY * scale
        )
        return foregroundTransform.concatenating(fill)
    }
}

final class VeloVideoInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening: Bool
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let layers: [VeloCompositorLayer]
    let telemetryLayers: [VeloTelemetryLayer]
    let effects: [EffectTimelineItem]
    let titles: [TitleTimelineItem]
    let transition: TransitionStyle?
    let transitionItem: TimelineTransitionItem?
    let renderSize: CGSize

    init(timeRange: CMTimeRange, layers: [VeloCompositorLayer], telemetryLayers: [VeloTelemetryLayer] = [], effects: [EffectTimelineItem] = [], titles: [TitleTimelineItem] = [], transition: TransitionStyle?, transitionItem: TimelineTransitionItem? = nil, renderSize: CGSize) {
        self.timeRange = timeRange
        self.layers = layers
        self.telemetryLayers = telemetryLayers
        self.effects = effects
        self.titles = titles
        self.transition = transition
        self.transitionItem = transitionItem
        self.renderSize = renderSize
        self.containsTweening = layers.count > 1 || transition != nil || transitionItem != nil || !telemetryLayers.isEmpty || !effects.isEmpty || !titles.isEmpty || layers.contains {
            $0.item.effect != nil || $0.item.effectiveVideoAdjustments.subjectReframe != nil
        }
        self.requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
        super.init()
    }
}

/// Core Image compositor used only when a clip has a color adjustment. It
/// applies filters in memory during playback/render, avoiding a blocking
/// per-clip transcode before the movie can be viewed.
public final class VeloVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let workingColorSpace = CGColorSpace(name: CGColorSpace.itur_709)
        ?? CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    public let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
    ]
    public let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var renderContext: AVVideoCompositionRenderContext?
    private var cancellationGeneration: UInt64 = 0
    private var stabilizationReferences: [UUID: CVPixelBuffer] = [:]
    private var stabilizationReferenceOrder: [UUID] = []

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        lock.lock()
        renderContext = newRenderContext
        lock.unlock()
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock()
        let currentContext = renderContext
        let requestGeneration = cancellationGeneration
        lock.unlock()
        guard let instruction = request.videoCompositionInstruction as? VeloVideoInstruction,
              let destination = currentContext?.newPixelBuffer() else {
            request.finish(with: NSError(domain: "VeloEdit.VideoCompositor", code: 1))
            return
        }

        autoreleasepool {
            let bounds = CGRect(origin: .zero, size: instruction.renderSize)
            var result = CIImage(color: .black).cropped(to: bounds)
            let transitionProgress = Self.progress(
                time: request.compositionTime,
                start: instruction.timeRange.start,
                duration: instruction.timeRange.duration
            )

            var processedLayers: [CIImage] = []
            // The newest/incoming layer is first. Reversing yields outgoing,
            // then incoming — the order expected by the shared renderer.
            for layer in instruction.layers.reversed() {
                guard let buffer = request.sourceFrame(byTrackID: layer.trackID) else { continue }
                var image = CIImage(cvPixelBuffer: buffer)
                image = AdjustedClipGenerator.apply(layer.item.effectiveVideoAdjustments, to: image)
                image = stabilizedImage(image, buffer: buffer, layer: layer)
                let clipTrack = layer.item.overlay == nil ? 0 : 1
                let standaloneEffects = instruction.effects.active(at: request.compositionTime.seconds, for: layer.item.id, clipTrack: clipTrack)
                image = TransitionEffectRenderer.applyEffects(standaloneEffects, to: image, timelineTime: request.compositionTime.seconds)
                if layer.item.overlay?.style == .greenScreen {
                    image = Self.removeGreen(from: image)
                }
                var transform = Self.effectTransform(
                    base: layer.transform,
                    effect: layer.item.effect.flatMap(ClipEffect.init(rawValue:)),
                    progress: Self.progress(time: request.compositionTime, start: layer.start, duration: layer.duration),
                    renderSize: instruction.renderSize
                )
                transform = Self.subjectReframeTransform(
                    transform,
                    sourceExtent: image.extent,
                    plan: layer.item.effectiveVideoAdjustments.subjectReframe,
                    progress: Self.progress(time: request.compositionTime, start: layer.start, duration: layer.duration),
                    renderSize: instruction.renderSize
                )
                transform = TransitionEffectRenderer.effectTransform(
                    standaloneEffects,
                    base: transform,
                    timelineTime: request.compositionTime.seconds,
                    renderSize: instruction.renderSize
                )
                let foreground = image.transformed(by: transform)
                let splitScreenIsActive = instruction.layers.contains { $0.item.overlay?.style == .splitScreen }
                if layer.item.effectiveVideoAdjustments.crop == .fit,
                   layer.item.overlay == nil,
                   !splitScreenIsActive,
                   let backgroundTransform = SafeFitBackgroundGeometry.aspectFillTransform(
                       foregroundTransform: transform,
                       sourceExtent: image.extent,
                       renderSize: instruction.renderSize
                   ) {
                    let blurRadius = min(36, max(12, min(bounds.width, bounds.height) * 0.016))
                    let background = image.transformed(by: backgroundTransform)
                        .clampedToExtent()
                        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
                        .applyingFilter("CIColorControls", parameters: [
                            kCIInputBrightnessKey: -0.16,
                            kCIInputContrastKey: 0.88,
                            kCIInputSaturationKey: 0.72
                        ])
                        .cropped(to: bounds)
                    image = foreground.composited(over: background).cropped(to: bounds)
                } else {
                    image = foreground.cropped(to: bounds)
                }
                var opacity = layer.item.effectiveVideoAdjustments.opacity
                opacity *= TransitionEffectRenderer.effectOpacity(standaloneEffects, timelineTime: request.compositionTime.seconds)
                if opacity < 0.999 {
                    image = image.applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
                    ])
                }
                processedLayers.append(image)
            }
            if processedLayers.count == 2,
               let transitionItem = instruction.transitionItem ?? instruction.transition.map({ style in
                   TimelineTransitionItem(
                       style: style,
                       outgoingClipID: instruction.layers.last?.item.id ?? UUID(),
                       incomingClipID: instruction.layers.first?.item.id ?? UUID(),
                       startTime: instruction.timeRange.start.seconds,
                       duration: instruction.timeRange.duration.seconds
                   )
               }) {
                result = TransitionEffectRenderer.renderTransition(
                    outgoing: processedLayers[0],
                    incoming: processedLayers[1],
                    item: transitionItem,
                    progress: transitionProgress,
                    bounds: bounds
                )
            } else {
                for image in processedLayers { result = image.composited(over: result) }
            }
            if instruction.telemetryLayers.isEmpty,
               let layer = instruction.layers.first(where: { $0.item.telemetryOverlay != nil }),
               let settings = layer.item.telemetryOverlay,
               let telemetry = layer.telemetry {
                let clipProgress = Self.progress(time: request.compositionTime, start: layer.start, duration: layer.duration)
                if let overlay = TelemetryOverlayRenderer.image(
                    settings: settings,
                    telemetry: telemetry,
                    progress: clipProgress,
                    sourceTime: layer.item.sourceStart + layer.item.sourceDuration * (layer.item.isReversed ? 1 - clipProgress : clipProgress),
                    renderSize: instruction.renderSize
                ) {
                    result = overlay.composited(over: result)
                }
            }
            for layer in instruction.telemetryLayers {
                let elapsed = request.compositionTime.seconds - layer.start.seconds
                let progress = min(max(0, elapsed / max(0.05, layer.duration.seconds)), 1)
                let sourceTime: Double
                if let clip = layer.targetClip {
                    let targetTimelineTime = layer.item.timelineStart + layer.item.timelineDuration * progress
                    sourceTime = clip.sourceTime(atTimelineTime: targetTimelineTime) + layer.item.syncOffset
                } else {
                    sourceTime = layer.item.sourceStart + elapsed + layer.item.syncOffset
                }
                guard sourceTime >= 0,
                      let overlay = TelemetryOverlayRenderer.image(
                        settings: layer.item.settings,
                        telemetry: layer.telemetry,
                        progress: progress,
                        sourceTime: sourceTime,
                        renderSize: instruction.renderSize
                      ) else { continue }
                result = overlay.composited(over: result)
            }
            for title in instruction.titles.sorted(by: { $0.track < $1.track }) {
                if let overlay = TitleOverlayRenderer.image(
                    item: title,
                    timelineTime: request.compositionTime.seconds,
                    renderSize: instruction.renderSize
                ) {
                    result = overlay.composited(over: result)
                }
            }
            // AVFoundation video frames are normally Rec.709. Rendering them
            // into an sRGB-tagged buffer and exporting that buffer as video
            // changes gamma/contrast across the entire movie whenever the
            // custom compositor is enabled by one adjusted clip.
            context.render(result, to: destination, bounds: bounds, colorSpace: Self.workingColorSpace)
            CVBufferSetAttachment(destination, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(destination, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(destination, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            lock.lock()
            let wasCancelled = requestGeneration != cancellationGeneration
            lock.unlock()
            if wasCancelled {
                request.finishCancelledRequest()
            } else {
                request.finish(withComposedVideoFrame: destination)
            }
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        cancellationGeneration &+= 1
        stabilizationReferences.removeAll()
        stabilizationReferenceOrder.removeAll()
        lock.unlock()
    }

    /// Registers every frame against the first frame of the clip with Vision,
    /// then applies a bounded correction and safety crop. This is intentionally
    /// translation-based: it removes handheld shake without introducing the
    /// rubber-sheet artifacts common to aggressive perspective stabilization.
    private func stabilizedImage(_ source: CIImage, buffer: CVPixelBuffer, layer: VeloCompositorLayer) -> CIImage {
        let settings = layer.item.effectiveVideoAdjustments
        let strength = min(max(0, settings.stabilization ?? 0), 1)
        guard strength > 0.0001 || settings.rollingShutterCorrection == true else {
            return smoothedSlowMotion(source, item: layer.item, motion: .identity)
        }

        lock.lock()
        let reference = stabilizationReferences[layer.item.id]
        if reference == nil {
            stabilizationReferences[layer.item.id] = buffer
            stabilizationReferenceOrder.removeAll { $0 == layer.item.id }
            stabilizationReferenceOrder.append(layer.item.id)
            while stabilizationReferenceOrder.count > 4 {
                stabilizationReferences.removeValue(forKey: stabilizationReferenceOrder.removeFirst())
            }
        }
        lock.unlock()
        guard let reference else { return smoothedSlowMotion(source, item: layer.item, motion: .identity) }

        // The targeted image is the floating/current frame. Vision returns the
        // transform that maps it onto the reference frame supplied to handler.
        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: buffer)
        request.regionOfInterest = CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)
        let handler = VNImageRequestHandler(cvPixelBuffer: reference)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return smoothedSlowMotion(source, item: layer.item, motion: .identity)
        }

        let extent = source.extent
        let detected = observation.alignmentTransform
        let maximumX = extent.width * 0.075
        let maximumY = extent.height * 0.075
        let correction = CGAffineTransform(
            translationX: min(max(-maximumX, detected.tx * strength), maximumX),
            y: min(max(-maximumY, detected.ty * strength), maximumY)
        )
        let rollingSafety = settings.rollingShutterCorrection == true ? 0.025 : 0
        let safetyScale = 1 + max(rollingSafety, 0.075 * strength)
        var image = source.transformed(by:
            CGAffineTransform(translationX: extent.midX, y: extent.midY)
                .scaledBy(x: safetyScale, y: safetyScale)
                .translatedBy(x: -extent.midX, y: -extent.midY)
                .concatenating(correction)
        )

        if settings.rollingShutterCorrection == true {
            let skew = min(max(-extent.width * 0.018, detected.tx * 0.12), extent.width * 0.018)
            image = image.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": CIVector(cgPoint: CGPoint(x: extent.minX - skew, y: extent.maxY)),
                "inputTopRight": CIVector(cgPoint: CGPoint(x: extent.maxX - skew, y: extent.maxY)),
                "inputBottomLeft": CIVector(cgPoint: CGPoint(x: extent.minX + skew, y: extent.minY)),
                "inputBottomRight": CIVector(cgPoint: CGPoint(x: extent.maxX + skew, y: extent.minY))
            ])
        }
        return smoothedSlowMotion(image, item: layer.item, motion: detected)
    }

    private func smoothedSlowMotion(_ source: CIImage, item: TimelineItem, motion: CGAffineTransform) -> CIImage {
        guard item.effectiveVideoAdjustments.smoothSlowMotion == true, item.speed < 0.999 else { return source }
        let radius = min(9, max(0.5, (1 / max(0.1, item.speed) - 1) * 2.5))
        let angle = abs(motion.tx) + abs(motion.ty) > 0.001 ? atan2(motion.ty, motion.tx) : 0
        return source.clampedToExtent()
            .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: angle])
            .cropped(to: source.extent)
    }

    private static func progress(time: CMTime, start: CMTime, duration: CMTime) -> Double {
        guard duration.seconds > 0 else { return 0 }
        return min(max(0, (time - start).seconds / duration.seconds), 1)
    }

    private static func effectTransform(
        base: CGAffineTransform,
        effect: ClipEffect?,
        progress: Double,
        renderSize: CGSize
    ) -> CGAffineTransform {
        guard let effect else { return base }
        switch effect {
        case .kenBurns:
            return zoomed(base, scale: 1 + 0.08 * progress, renderSize: renderSize)
        case .zoomIn:
            return zoomed(base, scale: 1 + 0.12 * progress, renderSize: renderSize)
        case .zoomOut:
            return zoomed(base, scale: 1.12 - 0.12 * progress, renderSize: renderSize)
        case .pushIn:
            return zoomed(base, scale: 1 + 0.20 * progress, renderSize: renderSize)
        case .pullOut:
            return zoomed(base, scale: 1.20 - 0.20 * progress, renderSize: renderSize)
        case .panLeft:
            return base.concatenating(CGAffineTransform(translationX: renderSize.width * (0.04 - 0.08 * progress), y: 0))
        case .panRight:
            return base.concatenating(CGAffineTransform(translationX: renderSize.width * (-0.04 + 0.08 * progress), y: 0))
        case .mirror:
            return base.concatenating(CGAffineTransform(translationX: renderSize.width, y: 0).scaledBy(x: -1, y: 1))
        }
    }

    private static func subjectReframeTransform(
        _ base: CGAffineTransform,
        sourceExtent: CGRect,
        plan: SubjectReframePlan?,
        progress: Double,
        renderSize: CGSize
    ) -> CGAffineTransform {
        guard let plan, plan.confidence >= 0.24 else { return base }
        return SubjectReframeGeometry.transform(
            base: base,
            sourceExtent: sourceExtent,
            plan: plan,
            progress: progress,
            renderSize: renderSize
        )
    }

    private static func zoomed(_ base: CGAffineTransform, scale: CGFloat, renderSize: CGSize) -> CGAffineTransform {
        base.concatenating(
            CGAffineTransform(translationX: renderSize.width / 2, y: renderSize.height / 2)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -renderSize.width / 2, y: -renderSize.height / 2)
        )
    }

    private static func removeGreen(from image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIColorCube") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(greenCubeDimension, forKey: "inputCubeDimension")
        filter.setValue(greenCubeData, forKey: "inputCubeData")
        return filter.outputImage ?? image
    }

    private static let greenCubeDimension = 32
    private static let greenCubeData: Data = {
        let dimension = greenCubeDimension
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let r = Float(red) / Float(dimension - 1)
                    let g = Float(green) / Float(dimension - 1)
                    let b = Float(blue) / Float(dimension - 1)
                    let keyed = g > 0.28 && g > r * 1.22 && g > b * 1.22
                    let alpha: Float = keyed ? 0 : 1
                    values.append(r * alpha)
                    values.append((keyed ? min(r, b) : g) * alpha)
                    values.append(b * alpha)
                    values.append(alpha)
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }()
}
