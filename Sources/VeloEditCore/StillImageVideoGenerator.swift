import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO

public enum BackgroundAnimationConfiguration {
    public static var intensity: Double = 0.5
}

public actor StillImageVideoGenerator {
    private struct ParticleLayer {
        let speed: CGFloat
        let direction: CGVector
        let scale: CGFloat
        let blur: CGFloat
        let opacity: CGFloat
        let rotationSpeed: CGFloat
        let phase: CGFloat
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    public init() {}

    public func generate(
        imageURL: URL,
        duration: Double,
        width: Int,
        height: Int,
        frameRate: Int32,
        destination: URL,
        codec: AVVideoCodecType = .h264,
        motion: ClipEffect? = .kenBurns,
        backgroundAnimationStyle: BackgroundAnimationStyle? = nil,
        animationIntensity: Double = BackgroundAnimationConfiguration.intensity
    ) async throws -> URL {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil), let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DerivedMediaError.cannotCreateDestination
        }
        let intensity = CGFloat(max(0, min(1, animationIntensity)))
        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let compression: [String: Any] = codec == .jpeg
            ? [AVVideoQualityKey: 0.92]
            : [AVVideoAverageBitRateKey: min(18_000_000, width * height * 4)]
        let settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw DerivedMediaError.exportUnavailable }
        writer.add(input)
        guard writer.startWriting() else {
            let error = writer.error as NSError?
            throw DerivedMediaError.exportFailed("startWriting: \(error?.domain ?? "AVAssetWriter") \(error?.code ?? -1) \(error?.userInfo ?? [:])")
        }
        writer.startSession(atSourceTime: .zero)

        let frames = max(1, Int((duration * Double(frameRate)).rounded()))
        let image = CIImage(cgImage: cgImage)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let baseScale = max(CGFloat(width) / image.extent.width, CGFloat(height) / image.extent.height)
        for frame in 0..<frames {
            if Task.isCancelled { writer.cancelWriting(); throw CancellationError() }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw DerivedMediaError.cannotCreateDestination }
            var optional: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optional) == kCVReturnSuccess, let buffer = optional else {
                throw DerivedMediaError.cannotCreateDestination
            }
            let progress = frames <= 1 ? 0 : CGFloat(frame) / CGFloat(frames - 1)

            var motionScale: CGFloat = 1
            var horizontalTravel: CGFloat = 0
            var verticalTravel: CGFloat = 0
            if let style = backgroundAnimationStyle {
                let transform = animatedBaseTransform(
                    style: style,
                    progress: progress,
                    width: CGFloat(width),
                    height: CGFloat(height),
                    intensity: intensity
                )
                motionScale = baseScale * transform.scale
                horizontalTravel = transform.translation.width
                verticalTravel = transform.translation.height
            } else {
                switch motion {
                case .kenBurns:
                    motionScale = 1 + 0.09 * progress
                    horizontalTravel = CGFloat(width) * (-0.025 + 0.05 * progress)
                case .zoomIn:
                    motionScale = 1 + 0.07 * progress
                case .zoomOut:
                    motionScale = 1.07 - 0.07 * progress
                case .pushIn:
                    motionScale = 1 + 0.16 * progress
                case .pullOut:
                    motionScale = 1.16 - 0.16 * progress
                case .panLeft:
                    motionScale = 1.08
                    horizontalTravel = CGFloat(width) * (0.045 - 0.09 * progress)
                case .panRight:
                    motionScale = 1.08
                    horizontalTravel = CGFloat(width) * (-0.045 + 0.09 * progress)
                case .mirror, .none:
                    break
                }
            }

            let scale = motionScale
            let scaledWidth = image.extent.width * scale
            let scaledHeight = image.extent.height * scale
            let x = (CGFloat(width) - scaledWidth) / 2 + horizontalTravel
            let y = (CGFloat(height) - scaledHeight) / 2 + verticalTravel
            let baseImage = image.transformed(
                by: CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: x / scale, y: y / scale)
            )
            // Every animated background uses the same calm continuous push-in.
            // No particles, wobble, pans or style-specific motion are layered on.
            let finalImage = baseImage.cropped(to: bounds)

            context.render(finalImage, to: buffer, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: frameRate)) else {
                throw DerivedMediaError.exportFailed(writer.error?.localizedDescription ?? "pixel buffer")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            let error = writer.error as NSError?
            throw DerivedMediaError.exportFailed("\(error?.domain ?? "AVAssetWriter") \(error?.code ?? Int(writer.status.rawValue)) \(error?.userInfo ?? [:])")
        }
        return destination
    }

    private func animatedBaseTransform(
        style _: BackgroundAnimationStyle,
        progress: CGFloat,
        width _: CGFloat,
        height _: CGFloat,
        intensity: CGFloat
    ) -> (scale: CGFloat, translation: CGSize) {
        (scale: 1 + (0.045 + 0.025 * intensity) * progress, translation: .zero)
    }

    private func animateBackground(
        _ image: CIImage,
        style: BackgroundAnimationStyle,
        particleTexture: CIImage?,
        elapsed: CGFloat,
        bounds: CGRect,
        intensity: CGFloat
    ) -> CIImage {
        let wavePulse = sin(elapsed * 2 * .pi / 3.5)
        let deepPulse = (sin(elapsed * 2 * .pi / 4.5) + 1) / 2
        var result = image
        switch style {
        case .water:
            if let noise = makeNoiseTexture(bounds: bounds, elapsed: elapsed, phaseX: elapsed * 7, phaseY: elapsed * 4.5, blur: 18 * (0.5 + 0.5 * intensity), contrast: 1.15 + 0.1 * intensity) {
                result = applyDisplacement(to: result, map: noise, scale: 2.6 + 10 * intensity * (0.35 + deepPulse * 0.65))
            }
            result = result
                .applyingFilter("CITwirlDistortion", parameters: [
                    kCIInputCenterKey: CIVector(x: bounds.midX + bounds.width * 0.15 * wavePulse, y: bounds.midY + bounds.height * 0.1 * cos(elapsed * 0.31)),
                    kCIInputRadiusKey: max(bounds.width, bounds.height) * 0.75,
                    kCIInputAngleKey: 0.06 * wavePulse
                ])
                .applyingFilter("CIGloom", parameters: [
                    kCIInputRadiusKey: 12 + 2 * (wavePulse + 1),
                    kCIInputIntensityKey: 0.16 + 0.04 * intensity
                ])

        case .rain:
            if let particleTexture {
                let layer = movingParticles(
                    particleTexture,
                    layers: [
                        ParticleLayer(speed: 760, direction: CGVector(dx: -0.04, dy: 0.97), scale: 1.1, blur: 0.8, opacity: 0.52, rotationSpeed: 0, phase: 0),
                        ParticleLayer(speed: 1020, direction: CGVector(dx: 0.02, dy: 0.96), scale: 0.84, blur: 0.6, opacity: 0.34, rotationSpeed: 0, phase: 0.7),
                        ParticleLayer(speed: 560, direction: CGVector(dx: 0.01, dy: 1), scale: 1.25, blur: 1.0, opacity: 0.24, rotationSpeed: 0.08, phase: 2.4)
                    ],
                    elapsed: elapsed,
                    bounds: bounds,
                    intensity: intensity
                )
                result = layer.composited(over: result)
                result = result.applyingFilter("CIGloom", parameters: [
                    kCIInputRadiusKey: 2.2,
                    kCIInputIntensityKey: 0.11 * intensity
                ])
            }

        case .snow:
            if let particleTexture {
                let layer = movingParticles(
                    particleTexture,
                    layers: [
                        ParticleLayer(speed: 84, direction: CGVector(dx: -0.25, dy: 1), scale: 1.2, blur: 1.5, opacity: 0.32, rotationSpeed: 0, phase: 0),
                        ParticleLayer(speed: 128, direction: CGVector(dx: 0.05, dy: 1), scale: 0.75, blur: 2.7, opacity: 0.41, rotationSpeed: 0.02, phase: 2.1),
                        ParticleLayer(speed: 56, direction: CGVector(dx: 0.15, dy: 1), scale: 1.5, blur: 0.8, opacity: 0.22, rotationSpeed: -0.018, phase: 4.2)
                    ],
                    elapsed: elapsed,
                    bounds: bounds,
                    intensity: intensity
                )
                result = layer.composited(over: result)
                result = result.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1.08 + 0.03 * intensity
                ])
            }

        case .stars:
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.04 + 0.03 * deepPulse
            ])
            if let particleTexture {
                let stars = movingParticles(
                    particleTexture,
                    layers: [
                        ParticleLayer(speed: 4, direction: CGVector(dx: -0.7, dy: 0.2), scale: 1.0, blur: 0, opacity: 0.15 + 0.2 * deepPulse, rotationSpeed: 0, phase: 0.22),
                        ParticleLayer(speed: 2.5, direction: CGVector(dx: 0.6, dy: 0.06), scale: 1.2, blur: 0, opacity: 0.09 + 0.12 * wavePulse, rotationSpeed: 0, phase: 1.6)
                    ],
                    elapsed: elapsed,
                    bounds: bounds,
                    intensity: intensity
                )
                let flicker = applyAlpha(stars, (0.14 + 0.22 * deepPulse) * intensity)
                result = flicker.composited(over: result)
            }
            if let noise = makeNoiseTexture(bounds: bounds, elapsed: elapsed * 0.08, phaseX: 3.2, phaseY: 1.8, blur: 28 * (0.5 + 0.5 * intensity), contrast: 1.2) {
                result = applyAlpha(noise, 0.03 * intensity).composited(over: result)
            }

        case .dust:
            if let particleTexture {
                let dust = movingParticles(
                    particleTexture,
                    layers: [
                        ParticleLayer(speed: 25, direction: CGVector(dx: 0.3, dy: 0.4), scale: 0.86, blur: 1.2, opacity: 0.34, rotationSpeed: 0.03, phase: 0),
                        ParticleLayer(speed: 15, direction: CGVector(dx: -0.18, dy: 0.26), scale: 1.2, blur: 2, opacity: 0.27, rotationSpeed: -0.014, phase: 1.8)
                    ],
                    elapsed: elapsed,
                    bounds: bounds,
                    intensity: intensity
                )
                result = dust.composited(over: result)
            }
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: 0.006 * wavePulse,
                kCIInputSaturationKey: 1.06
            ])

        case .confetti:
            if let particleTexture {
                let confetti = movingParticles(
                    particleTexture,
                    layers: [
                        ParticleLayer(speed: 150, direction: CGVector(dx: -0.08, dy: 0.98), scale: 0.9, blur: 0.3, opacity: 0.62, rotationSpeed: 0.22, phase: 0.6),
                        ParticleLayer(speed: 95, direction: CGVector(dx: 0.14, dy: 0.88), scale: 1.2, blur: 0.7, opacity: 0.38, rotationSpeed: -0.14, phase: 2.6)
                    ],
                    elapsed: elapsed,
                    bounds: bounds,
                    intensity: intensity
                )
                result = confetti.composited(over: result)
            }

        case .petals, .leaves:
            if let particleTexture {
                let leaves = movingParticles(
                    particleTexture,
                    layers: [
                        ParticleLayer(speed: 70, direction: CGVector(dx: -0.06, dy: 0.72), scale: 1.1, blur: 0.9, opacity: 0.45, rotationSpeed: 0.08, phase: 0.4),
                        ParticleLayer(speed: 52, direction: CGVector(dx: 0.08, dy: 0.65), scale: 0.9, blur: 1.4, opacity: 0.31, rotationSpeed: -0.12, phase: 3.0)
                    ],
                    elapsed: elapsed,
                    bounds: bounds,
                    intensity: intensity
                )
                result = leaves.composited(over: result)
            }
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.08 + 0.04 * intensity
            ])

        case .floating:
            if let particleTexture {
                let particles = movingParticles(
                    particleTexture,
                    layers: [
                        ParticleLayer(speed: 8, direction: CGVector(dx: 0.4, dy: 0.03), scale: 1.1, blur: 0.3, opacity: 0.4, rotationSpeed: 0.06, phase: 0.4),
                        ParticleLayer(speed: 12, direction: CGVector(dx: -0.28, dy: -0.02), scale: 0.86, blur: 0.5, opacity: 0.22, rotationSpeed: -0.04, phase: 2.1)
                    ],
                    elapsed: elapsed,
                    bounds: bounds,
                    intensity: intensity
                )
                result = particles.composited(over: result)
            }

        case .analog:
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: 0.012 * sin(elapsed * 1.8),
                kCIInputContrastKey: 1.02 + 0.02 * sin(elapsed * 1.2)
            ])
            if let noise = analogNoise(elapsed: elapsed, bounds: bounds) {
                result = noise.composited(over: result)
            }

        case .clouds:
            result = result.applyingFilter("CIGloom", parameters: [
                kCIInputRadiusKey: 2.6 + intensity,
                kCIInputIntensityKey: 0.18 + 0.05 * intensity
            ])
            if let noise = makeNoiseTexture(bounds: bounds, elapsed: elapsed * 0.6, phaseX: 8.6, phaseY: 6.4, blur: 40, contrast: 1.12) {
                result = applyAlpha(noise, 0.06 * intensity).composited(over: result)
            }

        case .smoke:
            if let noise = makeNoiseTexture(bounds: bounds, elapsed: elapsed * 0.95, phaseX: 11.4, phaseY: 9.1, blur: 55, contrast: 1.09) {
                result = applyAlpha(noise, 0.55).composited(over: result)
                result = result.applyingFilter("CIGloom", parameters: [
                    kCIInputRadiusKey: 6 + 2 * intensity,
                    kCIInputIntensityKey: 0.22 + 0.05 * intensity
                ])
            }
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.72 + 0.1 * intensity,
                kCIInputBrightnessKey: -0.01 * deepPulse
            ])

        case .fog:
            let hazePulse = 0.9 + 0.25 * wavePulse
            if let noise = makeNoiseTexture(bounds: bounds, elapsed: elapsed * 1.1, phaseX: 13.6, phaseY: 3.4, blur: 70, contrast: 1.2 + 0.1 * intensity) {
                result = applyAlpha(noise, (0.06 + 0.06 * intensity) * hazePulse).composited(over: result)
            }
            result = result.applyingFilter("CIGloom", parameters: [
                kCIInputRadiusKey: 9 * intensity,
                kCIInputIntensityKey: 0.18 + 0.06 * intensity
            ])

        case .fire:
            if let map = makeNoiseTexture(bounds: bounds, elapsed: elapsed * 1.35, phaseX: 5.3, phaseY: 2.2, blur: 10, contrast: 1.25) {
                result = applyDisplacement(to: result, map: map, scale: 18 * (0.5 + intensity))
            }
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: 0.018 * (0.35 + deepPulse),
                kCIInputContrastKey: 1.05 + 0.12 * intensity,
                kCIInputSaturationKey: 1.1 + 0.35 * intensity
            ])
            if let particleTexture {
                let embers = movingParticles(
                    particleTexture,
                    layers: [
                        ParticleLayer(speed: 180, direction: CGVector(dx: 0, dy: -0.1), scale: 1.0, blur: 0.7, opacity: 0.14, rotationSpeed: 0.0, phase: 0),
                        ParticleLayer(speed: 110, direction: CGVector(dx: 0, dy: -0.2), scale: 1.5, blur: 1.3, opacity: 0.08, rotationSpeed: 0, phase: 1.4)
                    ],
                    elapsed: elapsed,
                    bounds: bounds,
                    intensity: intensity
                )
                result = applyAlpha(embers, 0.5 * intensity).composited(over: result)
            }
            result = result.applyingFilter("CIGloom", parameters: [
                kCIInputRadiusKey: 18 + 5 * intensity,
                kCIInputIntensityKey: 0.45 + 0.16 * intensity
            ])

        case .aurora:
            result = result.applyingFilter("CIGloom", parameters: [
                kCIInputRadiusKey: 8 + 4 * intensity,
                kCIInputIntensityKey: 0.2 + 0.08 * intensity
            ])
            if let map = makeNoiseTexture(bounds: bounds, elapsed: elapsed * 0.65, phaseX: 3.5, phaseY: 8.7, blur: 26, contrast: 1.3) {
                let colorShift = map
                    .applyingFilter("CIColorControls", parameters: [
                        kCIInputSaturationKey: 1.8 + 0.5 * intensity,
                        kCIInputBrightnessKey: 0.08 * wavePulse,
                        kCIInputContrastKey: 1.1 + 0.1 * deepPulse
                    ])
                result = applyAlpha(colorShift, 0.26 * intensity).composited(over: result)
            }

        case .bokeh:
            if let particleTexture {
                let bokeh = movingParticles(
                    particleTexture,
                    layers: [
                        ParticleLayer(speed: 12, direction: CGVector(dx: 0.22, dy: -0.05), scale: 1.12, blur: 1.8, opacity: 0.5, rotationSpeed: 0.09, phase: 0),
                        ParticleLayer(speed: 9, direction: CGVector(dx: -0.14, dy: 0.03), scale: 0.85, blur: 2.4, opacity: 0.25, rotationSpeed: -0.05, phase: 1.4)
                    ],
                    elapsed: elapsed,
                    bounds: bounds,
                    intensity: intensity
                )
                result = applyAlpha(bokeh, 0.75).composited(over: result)
            }
            result = result.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.004 * wavePulse])

        case .atmospheric:
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: 0.01 * sin(elapsed * 0.28),
                kCIInputSaturationKey: 1.02 + 0.03 * intensity
            ])
            if let noise = makeNoiseTexture(bounds: bounds, elapsed: elapsed * 0.18, phaseX: 7.8, phaseY: 4.6, blur: 34, contrast: 1.08) {
                result = applyAlpha(noise, 0.05 * intensity).composited(over: result)
            }
            result = result.applyingFilter("CIGloom", parameters: [
                kCIInputRadiusKey: 5 + 1.5 * intensity,
                kCIInputIntensityKey: 0.08 + 0.03 * intensity
            ])

        case .cinematic:
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: 0.005 * wavePulse,
                kCIInputSaturationKey: 1.01 + 0.01 * wavePulse
            ])
        }
        return result.cropped(to: bounds)
    }

    private func movingParticles(
        _ texture: CIImage,
        layers: [ParticleLayer],
        elapsed: CGFloat,
        bounds: CGRect,
        intensity: CGFloat
    ) -> CIImage {
        let base = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: bounds)
        return layers.enumerated().reduce(base) { current, pair in
            let index = pair.offset
            let layer = pair.element
            let motion = particleMotionTexture(
                texture,
                layer: layer,
                elapsed: elapsed + layer.phase,
                bounds: bounds,
                intensity: intensity,
                layerIndex: index
            )
            return motion.composited(over: current)
        }
    }

    private func particleMotionTexture(
        _ texture: CIImage,
        layer: ParticleLayer,
        elapsed: CGFloat,
        bounds: CGRect,
        intensity: CGFloat,
        layerIndex: Int
    ) -> CIImage {
        let intensity = max(0, min(1, intensity))
        let width = bounds.width
        let height = bounds.height
        let speed = (layer.speed * (0.4 + 0.6 * intensity))
        let direction = normalize(layer.direction)
        let tx = abs(direction.dx) > 0.0001 ? periodicOffset(elapsed * speed * direction.dx, extent: max(1, width)) : 0
        let ty = abs(direction.dy) > 0.0001 ? periodicOffset(elapsed * speed * direction.dy, extent: max(1, height)) : 0
        let signX: CGFloat = direction.dx >= 0 ? 1 : -1
        let signY: CGFloat = direction.dy >= 0 ? 1 : -1
        let primaryOffsetX: CGFloat = abs(direction.dx) > 0.0001 ? signX * tx : 0
        let primaryOffsetY: CGFloat = abs(direction.dy) > 0.0001 ? signY * ty : 0
        let secondaryOffsetX: CGFloat = abs(direction.dx) > 0.0001 ? primaryOffsetX - signX * width : 0
        let secondaryOffsetY: CGFloat = abs(direction.dy) > 0.0001 ? primaryOffsetY - signY * height : 0

        let transform = CGAffineTransform(
            translationX: primaryOffsetX + (0.3 * CGFloat(layerIndex)),
            y: signY * ty + (0.2 * CGFloat(layerIndex))
        )
        let second = CGAffineTransform(
            translationX: secondaryOffsetX,
            y: secondaryOffsetY
        )
        let rotation = CGAffineTransform(
            translationX: bounds.midX,
            y: bounds.midY
        ).rotated(by: elapsed * layer.rotationSpeed * (0.2 + intensity)).translatedBy(
            x: -bounds.midX,
            y: -bounds.midY
        )
        let scale = CGAffineTransform(
            translationX: bounds.midX,
            y: bounds.midY
        ).scaledBy(x: layer.scale * (0.7 + 0.6 * intensity), y: layer.scale * (0.7 + 0.6 * intensity))
            .translatedBy(x: -bounds.midX, y: -bounds.midY)

        var moving = texture
            .transformed(by: scale.concatenating(rotation))
            .transformed(by: textureTranslation(transform))
            .cropped(to: bounds)
        let secondLayer = texture
            .transformed(by: scale.concatenating(rotation))
            .transformed(by: textureTranslation(second))
            .cropped(to: bounds)
        if layer.blur > 0 {
            moving = moving.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: layer.blur * intensity])
        }
        let tiled = secondLayer.composited(over: moving)
        let opacity = layer.opacity * (0.45 + 0.55 * intensity)
        return applyAlpha(tiled, opacity)
    }

    private func textureTranslation(_ transform: CGAffineTransform) -> CGAffineTransform {
        if transform.tx == 0 && transform.ty == 0 { return .identity }
        return transform
    }

    private func periodicOffset(_ value: CGFloat, extent: CGFloat) -> CGFloat {
        let wrapped = value.truncatingRemainder(dividingBy: extent)
        return wrapped >= 0 ? wrapped : wrapped + extent
    }

    private func normalize(_ vector: CGVector) -> CGVector {
        let length = max(0.0001, sqrt(vector.dx * vector.dx + vector.dy * vector.dy))
        return CGVector(dx: vector.dx / length, dy: vector.dy / length)
    }

    private func applyDisplacement(to image: CIImage, map: CIImage, scale: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: "CIDisplacementDistortion") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(map, forKey: "inputDisplacementImage")
        filter.setValue(max(0, scale), forKey: kCIInputScaleKey)
        return filter.outputImage ?? image
    }

    private func applyAlpha(_ image: CIImage, _ alpha: CGFloat) -> CIImage {
        let clampedAlpha = max(0, min(1, alpha))
        guard let filter = CIFilter(name: "CIColorMatrix") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: clampedAlpha), forKey: "inputAVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        return filter.outputImage ?? image
    }

    private func makeNoiseTexture(bounds: CGRect, elapsed: CGFloat, phaseX: CGFloat, phaseY: CGFloat, blur: CGFloat, contrast: Double = 1.15) -> CIImage? {
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return nil }
        let translated = random
            .transformed(by: CGAffineTransform(translationX: elapsed * phaseX, y: elapsed * phaseY))
            .cropped(to: bounds)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: contrast
            ])
        return translated
    }

    private func analogNoise(elapsed: CGFloat, bounds: CGRect) -> CIImage? {
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return nil }
        return random
            .transformed(by: CGAffineTransform(translationX: elapsed * 917, y: elapsed * 613))
            .cropped(to: bounds)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0.055)
            ])
    }

    private func makeParticleTexture(style: BackgroundAnimationStyle, width: Int, height: Int) -> CIImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let drawing = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        drawing.clear(CGRect(x: 0, y: 0, width: width, height: height))

        let (count, drawMode): (Int, ParticleDrawMode) = {
            switch style {
            case .rain: return (220, .rain)
            case .snow: return (165, .snow)
            case .dust: return (115, .dust)
            case .confetti: return (95, .confetti)
            case .petals, .leaves: return (90, .leaf)
            case .floating: return (70, .dust)
            case .fire: return (130, .confetti)
            case .stars: return (240, .star)
            case .bokeh: return (70, .bokeh)
            case .clouds, .atmospheric, .fog: return (95, .softCloud)
            default: return (0, .none)
            }
        }()
        if count == 0 { return nil }

        let palette: [CGColor] = [
            CGColor(red: 1, green: 0.20, blue: 0.35, alpha: 0.82),
            CGColor(red: 0.10, green: 0.78, blue: 1, alpha: 0.82),
            CGColor(red: 1, green: 0.82, blue: 0.08, alpha: 0.82),
            CGColor(red: 0.48, green: 0.92, blue: 0.32, alpha: 0.82)
        ]
        for index in 0..<count {
            let x = CGFloat((index * 193 + 47) % 997) / 997 * CGFloat(width)
            let y = CGFloat((index * 389 + 113) % 991) / 991 * CGFloat(height)
            let variation = CGFloat((index * 29) % 17) / 16
            switch drawMode {
            case .rain:
                drawing.setStrokeColor(CGColor(red: 0.72, green: 0.87, blue: 1, alpha: 0.18 + 0.24 * variation))
                drawing.setLineWidth(0.7 + 1.5 * variation)
                drawing.move(to: CGPoint(x: x, y: y))
                drawing.addLine(to: CGPoint(x: x - 5 - 7 * variation, y: y + 20 + 34 * variation))
                drawing.strokePath()
            case .snow:
                let size = 2.5 + 7 * variation
                drawing.setFillColor(CGColor(red: 0.92, green: 0.97, blue: 1, alpha: 0.32 + 0.52 * variation))
                drawing.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
            case .dust:
                let size = 1.5 + 4 * variation
                drawing.setFillColor(CGColor(red: 1, green: 0.76, blue: 0.28, alpha: 0.2 + 0.42 * variation))
                drawing.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
            case .confetti:
                drawing.setFillColor(palette[index % palette.count])
                let size = 4 + 7 * variation
                drawing.fill(CGRect(x: x, y: y, width: size * 0.55, height: size))
            case .leaf:
                drawing.setFillColor(CGColor(red: 1, green: 0.52, blue: 0.68, alpha: 0.28 + 0.45 * variation))
                let size = 4 + 8 * variation
                drawing.fillEllipse(in: CGRect(x: x, y: y, width: size * 1.55, height: size))
            case .star:
                drawing.setFillColor(palette[index % palette.count])
                drawing.fillEllipse(in: CGRect(x: x, y: y, width: 1 + 2.1 * variation, height: 1 + 2.1 * variation))
            case .bokeh:
                let alpha = 0.08 + 0.34 * variation
                drawing.setFillColor(CGColor(red: 1, green: 1, blue: 0.95, alpha: alpha))
                let size = 5 + 14 * variation
                drawing.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size * 0.78))
            case .softCloud:
                let alpha = 0.12 + 0.18 * variation
                drawing.setFillColor(CGColor(red: 0.78, green: 0.82, blue: 0.9, alpha: alpha))
                let width = 16 + 24 * variation
                let height = 8 + 11 * variation
                drawing.fillEllipse(in: CGRect(x: x, y: y, width: width, height: height))
            case .none:
                break
            }
        }
        guard let cgImage = drawing.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }
}

private enum ParticleDrawMode {
    case none
    case rain
    case snow
    case dust
    case confetti
    case leaf
    case star
    case bokeh
    case softCloud
}
