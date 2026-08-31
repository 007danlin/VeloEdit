import Foundation
import AVFoundation
import CoreImage

/// Renders only clips that need color processing. Geometry, transitions and
/// audio remain in PlaybackEngine, so ordinary camera clips keep the fast path.
public actor AdjustedClipGenerator {
    public init() {}

    public func generate(
        sourceURL: URL,
        sourceStart: Double,
        sourceDuration: Double,
        adjustments: VideoAdjustments,
        destination: URL
    ) async throws -> URL {
        try? FileManager.default.removeItem(at: destination)
        let source = AVURLAsset(url: sourceURL)
        guard let sourceTrack = try await source.loadTracks(withMediaType: .video).first else {
            throw DerivedMediaError.noVideoTrack
        }
        let composition = AVMutableComposition()
        guard let targetTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw DerivedMediaError.cannotCreateDestination
        }
        let range = CMTimeRange(
            start: CMTime(seconds: max(0, sourceStart), preferredTimescale: 600),
            duration: CMTime(seconds: max(0.05, sourceDuration), preferredTimescale: 600)
        )
        try targetTrack.insertTimeRange(range, of: sourceTrack, at: .zero)
        targetTrack.preferredTransform = try await sourceTrack.load(.preferredTransform)

        let videoComposition = AVMutableVideoComposition(asset: composition) { request in
            var image = request.sourceImage.clampedToExtent()
            image = Self.apply(adjustments, to: image)
            request.finish(with: image.cropped(to: request.sourceImage.extent), context: nil)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080) else {
            throw DerivedMediaError.exportUnavailable
        }
        session.outputURL = destination
        session.outputFileType = .mov
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = false
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw DerivedMediaError.exportFailed(session.error?.localizedDescription ?? String(describing: session.status))
        }
        return destination
    }

    public static func needsRender(_ value: VideoAdjustments) -> Bool {
        value.filter != .none ||
        abs(value.brightness) > 0.0001 ||
        abs(value.contrast - 1) > 0.0001 ||
        abs(value.saturation - 1) > 0.0001 ||
        abs(value.warmth) > 0.0001 ||
        abs(value.exposure ?? 0) > 0.0001 ||
        abs(value.highlights ?? 0) > 0.0001 ||
        abs(value.shadows ?? 0) > 0.0001 ||
        abs(value.vignette ?? 0) > 0.0001 ||
        abs(value.grain ?? 0) > 0.0001 ||
        abs(value.tint ?? 0) > 0.0001 ||
        (value.filter != .none && abs((value.filterIntensity ?? 1) - 1) > 0.0001) ||
        abs(value.stabilization ?? 0) > 0.0001 ||
        (value.rollingShutterCorrection ?? false) ||
        (value.smoothSlowMotion ?? false) ||
        value.subjectReframe != nil ||
        abs(value.sharpening ?? 0) > 0.0001 ||
        abs(value.denoise ?? 0) > 0.0001 ||
        abs(value.blur ?? 0) > 0.0001
    }

    static func apply(_ value: VideoAdjustments, to source: CIImage) -> CIImage {
        var image = source
        let unfiltered = source
        var appliedCatalogFilter = false
        if value.filter == .monochrome || value.filter == .noir {
            if let filter = CIFilter(name: value.filter == .noir ? "CIPhotoEffectNoir" : "CIPhotoEffectMono") {
                filter.setValue(image, forKey: kCIInputImageKey)
                image = filter.outputImage ?? image
                appliedCatalogFilter = true
            }
        } else if value.filter == .sepia {
            if let filter = CIFilter(name: "CISepiaTone") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(0.85, forKey: kCIInputIntensityKey)
                image = filter.outputImage ?? image
                appliedCatalogFilter = true
            }
        } else if value.filter == .dramatic {
            if let filter = CIFilter(name: "CIPhotoEffectProcess") {
                filter.setValue(image, forKey: kCIInputImageKey)
                image = filter.outputImage ?? image
                appliedCatalogFilter = true
            }
        }

        if appliedCatalogFilter {
            let intensity = min(max(0, value.filterIntensity ?? 1), 1)
            image = unfiltered.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: image,
                kCIInputTimeKey: intensity
            ])
        }

        var saturation = value.saturation
        var contrast = value.contrast
        var brightness = value.brightness
        var warmth = value.warmth
        let catalogIntensity = min(max(0, value.filterIntensity ?? 1), 1)
        switch value.filter {
        case .vivid: saturation *= 1 + 0.28 * catalogIntensity; contrast *= 1 + 0.08 * catalogIntensity
        case .warm: warmth += 0.35 * catalogIntensity
        case .cool: warmth -= 0.35 * catalogIntensity
        case .dramatic: contrast *= 1 + 0.18 * catalogIntensity; saturation *= 1 - 0.08 * catalogIntensity; brightness -= 0.02 * catalogIntensity
        default: break
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(image, forKey: kCIInputImageKey)
            controls.setValue(min(max(-1, brightness), 1), forKey: kCIInputBrightnessKey)
            controls.setValue(min(max(0, contrast), 4), forKey: kCIInputContrastKey)
            controls.setValue(min(max(0, saturation), 2.5), forKey: kCIInputSaturationKey)
            image = controls.outputImage ?? image
        }
        let tint = min(max(-1, value.tint ?? 0), 1)
        if abs(warmth) > 0.0001 || abs(tint) > 0.0001, let temperature = CIFilter(name: "CITemperatureAndTint") {
            temperature.setValue(image, forKey: kCIInputImageKey)
            temperature.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temperature.setValue(CIVector(x: 6500 + min(max(-1, warmth), 1) * 2200, y: tint * 140), forKey: "inputTargetNeutral")
            image = temperature.outputImage ?? image
        }
        if let exposure = value.exposure, abs(exposure) > 0.0001 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: min(max(-4, exposure), 4)
            ])
        }
        let highlights = value.highlights ?? 0
        let shadows = value.shadows ?? 0
        if abs(highlights) > 0.0001 || abs(shadows) > 0.0001 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": min(max(0, 1 + highlights), 2),
                "inputShadowAmount": min(max(-1, shadows), 1)
            ])
        }
        if let vignette = value.vignette, vignette > 0.0001 {
            image = image.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: min(max(0, vignette), 1) * 1.8,
                kCIInputRadiusKey: max(0.5, min(image.extent.width, image.extent.height) * 0.42)
            ])
        }
        if let denoise = value.denoise, denoise > 0.0001 {
            image = image.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.02 + min(max(0, denoise), 1) * 0.08,
                "inputSharpness": 0.18
            ])
        }
        if let sharpening = value.sharpening, sharpening > 0.0001 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: min(max(0, sharpening), 1) * 1.25
            ])
        }
        if let blur = value.blur, blur > 0.0001 {
            image = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: min(max(0, blur), 1) * 16])
                .cropped(to: source.extent)
        }
        if let grain = value.grain, grain > 0.0001 {
            let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?
                .cropped(to: image.extent)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.22, y: 0.22, z: 0.22, w: 0),
                    "inputGVector": CIVector(x: 0.22, y: 0.22, z: 0.22, w: 0),
                    "inputBVector": CIVector(x: 0.22, y: 0.22, z: 0.22, w: 0),
                    "inputBiasVector": CIVector(x: -0.33, y: -0.33, z: -0.33, w: 0)
                ])
            if let noise {
                let mixed = noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
                image = mixed.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: image,
                    kCIInputTimeKey: 1 - min(max(0, grain), 1) * 0.28
                ])
            }
        }
        return image
    }
}
