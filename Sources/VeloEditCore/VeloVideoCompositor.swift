import Foundation
@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Vision

/// AVFoundation transforms use a top-left origin; Core Image uses bottom-left.
/// Conjugating both coordinate spaces preserves identity and fixes quarter-turn
/// camera metadata without introducing another orientation pass.
enum CoreImageVideoGeometry {
    static func transform(_ avTransform: CGAffineTransform, source: CGSize, target: CGSize) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: source.height)
            .concatenating(avTransform)
            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: target.height))
    }
}

final class VeloCompositorLayer {
    let trackID: CMPersistentTrackID
    let item: TimelineItem
    let start: CMTime
    let duration: CMTime
    let naturalSize: CGSize
    let transform: CGAffineTransform
    let telemetry: TelemetrySummary?

    init(trackID: CMPersistentTrackID, item: TimelineItem, start: CMTime, duration: CMTime, naturalSize: CGSize, transform: CGAffineTransform, telemetry: TelemetrySummary? = nil) {
        self.trackID = trackID
        self.item = item
        self.start = start
        self.duration = duration
        self.naturalSize = naturalSize
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
        renderSize: CGSize,
        sourceTime: Double? = nil
    ) -> CGAffineTransform {
        guard sourceExtent.width.isFinite, sourceExtent.height.isFinite,
              sourceExtent.width > 0, sourceExtent.height > 0,
              renderSize.width > 0, renderSize.height > 0 else { return base }

        let progress = min(max(0, progress), 1)
        let keyframe = sourceTime.map { plan.interpolated(atSourceTime: $0) } ?? plan.interpolated(progress: progress)
        let centerX = keyframe.centerX
        let centerY = keyframe.centerY
        let requestedScale = keyframe.scale
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

enum CompositorOutputGeometry {
    static func transform(canvas: CGSize, destination: CGSize) -> CGAffineTransform {
        guard canvas.width > 0, canvas.height > 0 else { return .identity }
        return CGAffineTransform(scaleX: destination.width / canvas.width,
                                 y: destination.height / canvas.height)
    }
}

enum SafeFitBackgroundRenderer {
    /// Scale light instead of subtracting a constant: subtraction crushes
    /// low-light RGB channels independently into black and saturated patches.
    static func shade(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.72])
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.65])
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
    let colorProfile: VideoColorProfile
    let endingFade: FilmEndingFade?
    let timelineTimeRange: CMTimeRange?

    init(timeRange: CMTimeRange, layers: [VeloCompositorLayer], telemetryLayers: [VeloTelemetryLayer] = [], effects: [EffectTimelineItem] = [], titles: [TitleTimelineItem] = [], transition: TransitionStyle?, transitionItem: TimelineTransitionItem? = nil, renderSize: CGSize, colorProfile: VideoColorProfile = .rec709, endingFade: FilmEndingFade? = nil, timelineTimeRange: CMTimeRange? = nil) {
        self.timeRange = timeRange
        self.layers = layers
        self.telemetryLayers = telemetryLayers
        self.effects = effects
        self.titles = titles
        self.transition = transition
        self.transitionItem = transitionItem
        self.renderSize = renderSize
        self.colorProfile = colorProfile
        self.endingFade = endingFade
        self.timelineTimeRange = timelineTimeRange
        // Every instruction is handled by the custom compositor, including a
        // visually neutral single-layer interval. Advertising such an interval
        // as non-tweening while also exposing no passthrough track is an invalid
        // AVVideoCompositionInstruction contract and makes AVAssetExportSession
        // reject the composition before startRequest(_:) is ever called.
        self.containsTweening = true
        self.requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
        super.init()
    }

    /// Instruction boundaries include every primary start, so this interval
    /// maps linearly to the editor clock even when transitions overlap clips.
    /// Effects, title animations and keyframes keep their original timestamps.
    func timelineTime(at time: CMTime) -> Double {
        guard let timelineTimeRange, timeRange.duration.seconds > 0 else { return time.seconds }
        let fraction = min(1, max(0, (time - timeRange.start).seconds / timeRange.duration.seconds))
        return timelineTimeRange.start.seconds + timelineTimeRange.duration.seconds * fraction
    }

    var effectiveTransitionItem: TimelineTransitionItem? {
        if let transitionItem { return transitionItem }
        let primaries = layers.filter { $0.item.overlay == nil }
        guard let transition, transition != .cut, primaries.count == 2 else { return nil }
        return TimelineTransitionItem(style: transition,
                                      outgoingClipID: primaries[1].item.id,
                                      incomingClipID: primaries[0].item.id,
                                      startTime: primaries[0].start.seconds,
                                      duration: (primaries[1].start + primaries[1].duration - primaries[0].start).seconds)
    }

    func transitionProgress(at time: CMTime) -> Double {
        guard let item = effectiveTransitionItem, item.duration > 0 else { return 0 }
        return min(1, max(0, (time.seconds - item.startTime) / item.duration))
    }

    /// Transition only the two primary clips, then place connected video above
    /// the result. A PiP/overlay must neither disable nor join the transition.
    func compositeFrames(_ frames: [UUID: CIImage], at time: CMTime) -> CIImage {
        let bounds = CGRect(origin: .zero, size: renderSize)
        var result = CIImage(color: .black).cropped(to: bounds)
        if let item = effectiveTransitionItem,
           let outgoing = frames[item.outgoingClipID], let incoming = frames[item.incomingClipID] {
            result = TransitionEffectRenderer.renderTransition(
                outgoing: outgoing, incoming: incoming, item: item,
                progress: transitionProgress(at: time), bounds: bounds
            ).composited(over: result)
        } else {
            for layer in layers.reversed() where layer.item.overlay == nil {
                if let image = frames[layer.item.id] { result = image.composited(over: result) }
            }
        }
        for layer in layers.reversed() where layer.item.overlay != nil {
            if let image = frames[layer.item.id] { result = image.composited(over: result) }
        }
        return result.cropped(to: bounds)
    }
}

/// Core Image compositor for transitions, effects and color adjustments. It
/// applies filters in memory during playback/render, avoiding a blocking
/// per-clip transcode before the movie can be viewed.
public class VeloVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    public var sourcePixelBufferAttributes: [String: any Sendable]? { [
        // Keep source and destination pools on one Core Image-native format.
        // Mixed 8/10-bit YUV alternatives let AVFoundation pick a surface
        // that cannot be joined to the BGRA render context and fail before
        // startRequest(_:) with VideoToolbox -12903.
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]
    ] }
    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { [
        // BGRA is the common Core Image surface and avoids asking CIContext to
        // render into a bi-planar YUV pool it cannot reliably allocate.
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ] }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let titleBackgroundRenderer = AdaptiveTitleBackgroundRenderer()
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
        let requestGeneration = cancellationGeneration
        lock.unlock()
        guard let instruction = request.videoCompositionInstruction as? VeloVideoInstruction else {
            request.finish(with: NSError(domain: "VeloEdit.VideoCompositor", code: 1))
            return
        }
        guard let destination = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "VeloEdit.VideoCompositor", code: 2))
            return
        }

        autoreleasepool {
            let bounds = CGRect(origin: .zero, size: instruction.renderSize)
            let timelineTime = instruction.timelineTime(at: request.compositionTime)
            var processedLayers: [UUID: CIImage] = [:]
            // The newest/incoming layer is first. Reversing yields outgoing,
            // then incoming — the order expected by the shared renderer.
            for layer in instruction.layers.reversed() {
                guard let buffer = request.sourceFrame(byTrackID: layer.trackID) else { continue }
                var image = CIImage(cvPixelBuffer: buffer)
                // AVKit's native compositor accounts for non-square pixels;
                // Core Image receives the encoded raster instead (for example
                // 720×576 for a 1024×576 anamorphic movie). Placement transforms
                // use naturalSize, so first map that raster into the same space.
                // Keep stabilization in buffer coordinates and derive this map
                // before it adds overscan or changes the image extent.
                let sourceToNatural = CGAffineTransform(
                    scaleX: layer.naturalSize.width / image.extent.width,
                    y: layer.naturalSize.height / image.extent.height
                )
                image = AdjustedClipGenerator.apply(layer.item.effectiveVideoAdjustments, to: image)
                image = stabilizedImage(image, buffer: buffer, layer: layer)
                image = image.transformed(by: sourceToNatural)
                let clipTrack = layer.item.overlay == nil ? 0 : 1
                let standaloneEffects = instruction.effects.active(at: timelineTime, for: layer.item.id, clipTrack: clipTrack)
                image = TransitionEffectRenderer.applyEffects(standaloneEffects, to: image, timelineTime: timelineTime)
                if layer.item.overlay?.style == .greenScreen {
                    image = Self.removeGreen(from: image)
                }
                var transform = Self.effectTransform(
                    base: CoreImageVideoGeometry.transform(layer.transform, source: layer.naturalSize, target: instruction.renderSize),
                    effect: layer.item.effect.flatMap(ClipEffect.init(rawValue:)),
                    progress: Self.progress(time: request.compositionTime, start: layer.start, duration: layer.duration),
                    renderSize: instruction.renderSize
                )
                transform = Self.subjectReframeTransform(
                    transform,
                    sourceExtent: image.extent,
                    plan: layer.item.effectiveVideoAdjustments.subjectReframe,
                    progress: Self.progress(time: request.compositionTime, start: layer.start, duration: layer.duration),
                    renderSize: instruction.renderSize,
                    sourceTime: layer.item.sourceTime(atTimelineTime: layer.item.timelineStart + Self.progress(time: request.compositionTime, start: layer.start, duration: layer.duration) * layer.item.timelineDuration)
                )
                transform = TransitionEffectRenderer.effectTransform(
                    standaloneEffects,
                    base: transform,
                    timelineTime: timelineTime,
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
                    let blurred = image.transformed(by: backgroundTransform)
                        .clampedToExtent()
                        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
                    let background = SafeFitBackgroundRenderer.shade(blurred).cropped(to: bounds)
                    image = foreground.composited(over: background).cropped(to: bounds)
                } else {
                    image = foreground.cropped(to: bounds)
                }
                var opacity = layer.item.effectiveVideoAdjustments.opacity
                opacity *= TransitionEffectRenderer.effectOpacity(standaloneEffects, timelineTime: timelineTime)
                if opacity < 0.999 {
                    image = image.applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
                    ])
                }
                processedLayers[layer.item.id] = image
            }
            var result = instruction.compositeFrames(processedLayers, at: request.compositionTime)
            if instruction.telemetryLayers.isEmpty,
               let layer = instruction.layers.first(where: { $0.item.telemetryOverlay != nil }),
               let settings = layer.item.telemetryOverlay,
               let telemetry = layer.telemetry {
                let clipProgress = Self.progress(time: request.compositionTime, start: layer.start, duration: layer.duration)
                if let overlay = TelemetryOverlayRenderer.image(
                    settings: settings,
                    telemetry: telemetry,
                    progress: clipProgress,
                    sourceTime: layer.item.sourceTime(atTimelineTime: timelineTime),
                    renderSize: instruction.renderSize
                ) {
                    result = overlay.composited(over: result)
                }
            }
            for layer in instruction.telemetryLayers {
                let elapsed = timelineTime - layer.item.timelineStart
                let progress = min(max(0, elapsed / max(0.05, layer.item.timelineDuration)), 1)
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
                result = TitleOverlayRenderer.composited(
                    item: title,
                    timelineTime: title.speechAnchor == nil ? timelineTime : request.compositionTime.seconds,
                    renderSize: instruction.renderSize,
                    over: result,
                    adaptation: titleBackgroundRenderer
                )
            }
            if let endingFade = instruction.endingFade {
                result = endingFade.applying(to: result, at: request.compositionTime.seconds)
            }
            // AVFoundation video frames are normally Rec.709. Rendering them
            // into an sRGB-tagged buffer and exporting that buffer as video
            // changes gamma/contrast across the entire movie whenever the
            // custom compositor is enabled by one adjusted clip.
            let colorSpace = VideoColorPipeline.cgColorSpace(for: instruction.colorProfile)
            // AVPlayer can request a reduced render surface. Instructions and
            // layer transforms remain in timeline pixels: fit the entire canvas
            // to the actual buffer rather than cropping its lower-left corner.
            let outputBounds = CGRect(x: 0, y: 0,
                                      width: CVPixelBufferGetWidth(destination),
                                      height: CVPixelBufferGetHeight(destination))
            let output = result.transformed(by: CompositorOutputGeometry.transform(
                canvas: bounds.size, destination: outputBounds.size
            ))
            context.render(output, to: destination, bounds: outputBounds, colorSpace: colorSpace)
            if instruction.colorProfile.dynamicRange == .hdr {
                CVBufferSetAttachment(destination, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
                CVBufferSetAttachment(
                    destination,
                    kCVImageBufferTransferFunctionKey,
                    instruction.colorProfile.transferFunction == .pq
                        ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
                        : kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                    .shouldPropagate
                )
                CVBufferSetAttachment(destination, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            } else {
                CVBufferSetAttachment(destination, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(destination, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(destination, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            }
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
        renderSize: CGSize,
        sourceTime: Double? = nil
    ) -> CGAffineTransform {
        guard let plan, plan.confidence >= 0.24 else { return base }
        return SubjectReframeGeometry.transform(
            base: base,
            sourceExtent: sourceExtent,
            plan: plan,
            progress: progress,
            renderSize: renderSize,
            sourceTime: plan.keyframes == nil ? nil : sourceTime
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

/// HDR keeps a 10-bit compositor surface; PlaybackEngine selects this class
/// only for an HDR delivery profile.
public final class VeloHDRVideoCompositor: VeloVideoCompositor, @unchecked Sendable {
    public override var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    ] }
}
