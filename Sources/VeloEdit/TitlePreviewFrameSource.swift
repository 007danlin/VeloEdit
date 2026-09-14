import AVFoundation
import CoreImage
import SwiftUI
import VeloEditCore

/// Reads decoded frames without replacing AVPlayer's native video presentation.
/// Image analysis/drawing runs off the main thread, with one in-flight frame.
@MainActor
final class TitlePreviewFrameSource: ObservableObject {
    @Published private(set) var image: CGImage?
    private weak var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var transform = CGAffineTransform.identity
    private var geometryReady = false
    private var renderer = AdaptiveTitlePreviewRenderer()
    private var generation = UUID()
    private var drawing = false
    private var cachedFrame: (time: Double, image: CIImage)?
    private var configurationTask: Task<Void, Never>?
    private struct FrameRequest {
        var timeline: Timeline
        var time: Double
        var renderSize: CGSize
        var poster: CGImage?
        var active: [TitleTimelineItem] {
            timeline.effectiveTitleItems.filter { $0.enabled && time >= $0.startTime && time < $0.endTime }
        }
    }
    private var latest: FrameRequest?
    private var pending: FrameRequest?

    func attach(to newItem: AVPlayerItem?) {
        guard item !== newItem else { return }
        detach()
        guard let newItem else { return }
        item = newItem
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        newItem.add(output)
        self.output = output
        let token = generation
        configurationTask = Task { [weak self, weak newItem] in
            guard let newItem else { return }
            var transform = CGAffineTransform.identity
            // A video composition already emits display-oriented canvas pixels.
            if newItem.videoComposition == nil,
               let track = try? await newItem.asset.loadTracks(withMediaType: .video).first {
                transform = (try? await track.load(.preferredTransform)) ?? .identity
            }
            guard let self, self.generation == token else { return }
            self.transform = transform
            self.geometryReady = true
            // Also refresh a paused viewer once orientation metadata arrives.
            self.pending = self.latest
            self.drawPendingFrame()
        }
    }

    func detach() {
        configurationTask?.cancel()
        if let item, let output { item.remove(output) }
        item = nil
        output = nil
        cachedFrame = nil
        image = nil
        generation = UUID()
        renderer = AdaptiveTitlePreviewRenderer()
        geometryReady = false
        drawing = false
        pending = nil
        latest = nil
    }

    func update(timeline: Timeline, time: Double, renderSize: CGSize, poster: CGImage?) {
        if let latest, abs(latest.time - time) > 0.15 { image = nil; cachedFrame = nil }
        let request = FrameRequest(timeline: timeline, time: time, renderSize: renderSize, poster: poster)
        latest = request
        guard !request.active.isEmpty else {
            image = nil
            cachedFrame = nil
            pending = nil
            return
        }
        // Coalesce to the latest frame; a paused text edit must never be lost
        // just because the previous frame is still being drawn.
        pending = request
        drawPendingFrame()
    }

    private func drawPendingFrame() {
        guard !drawing, let request = pending, !request.active.isEmpty else { return }
        pending = nil
        let time = request.time
        let renderSize = request.renderSize
        let active = request.active
        let bounds = CGRect(origin: .zero, size: renderSize)
        var source: CIImage?
        if geometryReady, let output {
            let requested = CMTime(seconds: time, preferredTimescale: 600)
            var displayTime = CMTime.invalid
            if let buffer = output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &displayTime) {
                let frame = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
                cachedFrame = (displayTime.isValid ? displayTime.seconds : time, frame)
            }
            if let cachedFrame, abs(cachedFrame.time - time) < 0.12 { source = cachedFrame.image }
        }
        if source == nil, let poster = request.poster { source = CIImage(cgImage: poster) }
        if let frame = source, frame.extent.width > 0, frame.extent.height > 0 {
            let scale = min(renderSize.width / frame.extent.width, renderSize.height / frame.extent.height)
            let fitted = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: (renderSize.width - frame.extent.width * scale) / 2,
                                                   y: (renderSize.height - frame.extent.height * scale) / 2))
            source = fitted.composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
        }
        let renderer = renderer
        let token = generation
        let background = source
        drawing = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let frame = renderer.image(items: active, timelineTime: time, renderSize: renderSize, background: background)
            await MainActor.run { [weak self] in
                guard let self, self.generation == token else { return }
                self.drawing = false
                if let latest = self.latest, abs(latest.time - time) < 0.15, latest.active == active {
                    self.image = frame
                }
                self.drawPendingFrame()
            }
        }
    }
}
