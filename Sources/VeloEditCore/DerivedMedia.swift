import Foundation
import AVFoundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

public enum DerivedMediaError: LocalizedError {
    case noVideoTrack
    case cannotCreateDestination
    case exportUnavailable
    case exportFailed(String)
    case soundtrackUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "В файле нет видеодорожки"
        case .cannotCreateDestination: return "Не удалось создать производный файл"
        case .exportUnavailable: return "Системный экспорт недоступен для этого формата"
        case .exportFailed(let reason): return "Не удалось экспортировать видео: \(reason)"
        case .soundtrackUnavailable(let reason): return reason
        }
    }
}

public actor ThumbnailGenerator {
    public init() {}

    public func generate(for asset: MediaAsset, destination: URL, maximumPixelSize: Int = 640, videoTime: Double? = nil) async throws -> URL {
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let image: CGImage
        switch asset.kind {
        case .photo:
            guard let source = CGImageSourceCreateWithURL(asset.originalURL as CFURL, nil),
                  let result = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { throw DerivedMediaError.cannotCreateDestination }
            image = result
        case .video:
            do {
                let avAsset = AVURLAsset(url: asset.originalURL)
                let generator = AVAssetImageGenerator(asset: avAsset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
                generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
                let midpoint = min(max(videoTime ?? (asset.metadata.duration ?? 0) * 0.35, 0), max(0, (asset.metadata.duration ?? 0) - 0.05))
                image = try generator.copyCGImage(at: CMTime(seconds: midpoint, preferredTimescale: 600), actualTime: nil)
            } catch {
                let request = QLThumbnailGenerator.Request(
                    fileAt: asset.originalURL,
                    size: CGSize(width: maximumPixelSize, height: maximumPixelSize),
                    scale: 1,
                    representationTypes: .thumbnail
                )
                image = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
            }
        }
        guard let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw DerivedMediaError.cannotCreateDestination }
        CGImageDestinationAddImage(destinationRef, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destinationRef) else { throw DerivedMediaError.cannotCreateDestination }
        return destination
    }
}

public actor ProxyGenerator {
    public init() {}

    public func generate(for asset: MediaAsset, destination: URL, longEdge: Int = 720, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard asset.kind == .video else { return asset.originalURL }
        if await isUsableProxy(destination, expectedDuration: asset.metadata.duration) {
            progress?(1)
            return destination
        }
        // AVAssetExportSession can leave an empty destination behind when an
        // export is interrupted. Treating that file as a cache hit makes the
        // player show a black frame (and image generation fail with
        // "Cannot Decode") until the whole project cache is deleted.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let avAsset = AVURLAsset(url: asset.originalURL)
        let preset: String
        if longEdge <= 720 {
            preset = AVAssetExportPreset1280x720
        } else if longEdge <= 1080 {
            preset = AVAssetExportPreset1920x1080
        } else {
            preset = AVAssetExportPreset3840x2160
        }
        guard let session = AVAssetExportSession(asset: avAsset, presetName: preset) else { throw DerivedMediaError.exportUnavailable }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).partial.mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        session.outputURL = temporary
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        progress?(0)
        let monitor = Task {
            while !Task.isCancelled {
                progress?(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        await session.export()
        monitor.cancel()
        guard session.status == .completed else {
            throw DerivedMediaError.exportFailed(session.error?.localizedDescription ?? String(describing: session.status))
        }
        guard await isUsableProxy(temporary, expectedDuration: asset.metadata.duration) else {
            throw DerivedMediaError.exportFailed("созданная облегчённая копия не содержит декодируемого видео")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress?(1)
        return destination
    }

    private func isUsableProxy(_ url: URL, expectedDuration: Double?) async -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 1_024 else { return false }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true,
              (try? await asset.loadTracks(withMediaType: .video).first) != nil,
              let duration = try? await asset.load(.duration),
              duration.isNumeric,
              duration.seconds > 0.1 else { return false }
        guard let expectedDuration, expectedDuration.isFinite, expectedDuration > 0 else { return true }
        // Container rounding can differ by a few frames. Larger mismatches
        // mean the cached export was truncated and is unsafe for source-time
        // ranges from the original timeline.
        return abs(duration.seconds - expectedDuration) <= max(1, expectedDuration * 0.002)
    }
}

public struct AnalysisProxyPlanner: Sendable {
    public init() {}

    public func shouldGenerateProxy(for asset: MediaAsset, profile: AIAnalysisProfile) -> Bool {
        guard asset.kind == .video else { return false }
        switch profile.proxyPolicy {
        case .avoidFullEncode:
            return false
        case .required, .highQuality:
            return true
        case .whenNeeded:
            let longEdge = max(asset.metadata.width ?? 0, asset.metadata.height ?? 0)
            let codec = asset.metadata.codec?.lowercased() ?? ""
            let directlyFriendly = codec.contains("h264") || codec.contains("avc") || codec.contains("hevc") || codec.contains("h265")
            return longEdge > 2_560 || !directlyFriendly
        }
    }
}

public actor ThermalAwareScheduler {
    public enum Mode: String, Sendable { case cool, warm, hot }
    public private(set) var mode: Mode = .cool
    public private(set) var isPaused = false
    private var recoveryObservations = 0
    private var lastTransition = Date.distantPast
    private let recoveryCooldown: TimeInterval = 8
    public init() {}

    public func refresh() -> Mode {
        refresh(thermalState: ProcessInfo.processInfo.thermalState, now: Date())
    }

    @discardableResult
    public func refresh(thermalState: ProcessInfo.ThermalState, now: Date) -> Mode {
        let observed: Mode
        switch thermalState {
        case .nominal: observed = .cool
        case .fair, .serious: observed = .warm
        case .critical: observed = .hot
        @unknown default: observed = .warm
        }
        if observed.rawSeverity > mode.rawSeverity {
            mode = observed
            recoveryObservations = 0
            lastTransition = now
        } else if observed.rawSeverity < mode.rawSeverity {
            recoveryObservations += 1
            if recoveryObservations >= 3, now.timeIntervalSince(lastTransition) >= recoveryCooldown {
                mode = observed
                recoveryObservations = 0
                lastTransition = now
            }
        } else {
            recoveryObservations = 0
        }
        isPaused = mode == .hot
        return mode
    }

    public func recommendedConcurrency() -> Int {
        switch refresh() { case .cool: return 2; case .warm, .hot: return 1 }
    }

    public func recommendedConcurrency(for profile: AIAnalysisProfile) -> Int {
        let thermalLimit: Int
        switch refresh() { case .cool: thermalLimit = profile.aiConcurrency; case .warm, .hot: thermalLimit = 1 }
        return max(1, min(profile.aiConcurrency, thermalLimit))
    }

    /// Critical thermal pressure is treated as a back-pressure signal instead
    /// of merely changing a label. Cancellation is checked between short waits
    /// so the user can still stop the operation immediately.
    public func waitUntilSafe() async throws {
        while refresh() == .hot {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
        }
    }

    public func statusLabel() -> String {
        switch refresh() {
        case .cool: return ProcessInfo.processInfo.isLowPowerModeEnabled ? "Энергосбережение: одна AI-задача" : "Температура нормальная"
        case .warm: return "Mac нагрелся — глубина анализа снижена"
        case .hot: return "Охлаждаю Mac — тяжёлые AI-задачи приостановлены"
        }
    }
}

private extension ThermalAwareScheduler.Mode {
    var rawSeverity: Int {
        switch self { case .cool: return 0; case .warm: return 1; case .hot: return 2 }
    }
}
