import Foundation
import AVFoundation
import CoreImage
import CoreVideo

/// Exports only editable telemetry layers as ProRes 4444 with a real alpha
/// channel. This is intentionally independent of the picture compositor so it
/// can be placed over the original footage in Final Cut, Resolve or Premiere.
public actor TelemetryAlphaRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])

    public init() {}

    public func render(
        timeline: Timeline,
        telemetry: [UUID: TelemetrySummary],
        destination: URL,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> RenderReport {
        guard !timeline.effectiveTelemetryItems.isEmpty else {
            throw FCPXMLExportError.invalidTimeline("на Timeline нет слоёв телеметрии")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: timeline.width,
            AVVideoHeightKey: timeline.height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: timeline.width,
            kCVPixelBufferHeightKey as String: timeline.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw DerivedMediaError.exportUnavailable }
        writer.add(input)
        guard writer.startWriting() else { throw DerivedMediaError.exportFailed(writer.error?.localizedDescription ?? "ProRes 4444") }
        writer.startSession(atSourceTime: .zero)
        let frameRate = Int32(max(1, timeline.frameRate.rounded()))
        let frameCount = max(1, Int((timeline.duration * Double(frameRate)).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: timeline.width, height: timeline.height)
        for frame in 0..<frameCount {
            if Task.isCancelled { writer.cancelWriting(); throw CancellationError() }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw DerivedMediaError.cannotCreateDestination }
            var optional: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optional) == kCVReturnSuccess, let buffer = optional else { throw DerivedMediaError.cannotCreateDestination }
            let time = Double(frame) / Double(frameRate)
            var image = CIImage(color: .clear).cropped(to: bounds)
            for item in timeline.effectiveTelemetryItems where item.timelineStart <= time && item.timelineEnd > time {
                guard let summary = item.sourceID.flatMap({ telemetry[$0] }) ?? item.linkedAssetID.flatMap({ telemetry[$0] }) else { continue }
                let elapsed = time - item.timelineStart
                let sourceTime = item.targetClipID
                    .flatMap { clipID in timeline.items.first(where: { $0.id == clipID }) }
                    .map { $0.sourceTime(atTimelineTime: time) + item.syncOffset }
                    ?? (item.sourceStart + elapsed + item.syncOffset)
                guard sourceTime >= 0, let overlay = TelemetryOverlayRenderer.image(
                    settings: item.settings,
                    telemetry: summary,
                    progress: elapsed / max(0.05, item.timelineDuration),
                    sourceTime: sourceTime,
                    renderSize: bounds.size
                ) else { continue }
                image = overlay.composited(over: image)
            }
            context.render(image, to: buffer, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: frameRate)) else {
                throw DerivedMediaError.exportFailed(writer.error?.localizedDescription ?? "ProRes 4444 frame")
            }
            if frame % max(1, Int(frameRate / 2)) == 0 {
                progress?(ImportProgress(completed: frame, total: frameCount, currentName: "Прозрачная телеметрия · \(Int(Double(frame) / Double(frameCount) * 100))%"))
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw DerivedMediaError.exportFailed(writer.error?.localizedDescription ?? "ProRes 4444") }
        progress?(ImportProgress(completed: frameCount, total: frameCount, currentName: "Прозрачный overlay готов"))
        return RenderReport(outputURL: destination, renderedItemCount: timeline.effectiveTelemetryItems.count, skippedItemIDs: [])
    }
}
