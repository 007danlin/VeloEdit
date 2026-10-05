import Foundation
import CoreGraphics
import Vision

/// A measurement of one title in actual composited pixels, never a planner's
/// estimate. Preview and encoded-file observations remain separate receipts.
public struct TitleReadabilityEvidence: Codable, Hashable, Sendable {
    public var titleID: UUID
    public var renderSignature: String
    public var algorithmVersion: Int
    public var timelineTime: Double
    public var actualPTS: Double?
    public var source: String
    public var expectedText: String
    public var recognizedText: String
    public var confidences: [Double]
    public var region: NormalizedRegion?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var score: Double
    public var failure: String?

    public var passed: Bool { failure == nil && score.isFinite && score >= 0.5 }
    public func isCurrent(for timeline: Timeline) -> Bool {
        algorithmVersion == TitleReadabilityInspector.version
            && renderSignature == EditorialRenderSignature.signature(timeline)
            && timeline.effectiveTitleItems.contains { $0.id == titleID && $0.enabled && $0.text == expectedText }
    }
}

enum TitleReadabilityInspector {
    static let version = 1
    // The old 640-pixel whole-frame OCR intermittently lost small outlined
    // headings. Decode real pixels at 1080p; do not upscale or substitute art.
    static let maximumSize = CGSize(width: 1920, height: 1920)

    static func holdRange(_ title: TitleTimelineItem, frameRate: Double) -> ClosedRange<Double> {
        let motion = TitleTemplateRegistry.template(for: title)?.animationFitted(to: title.duration)
        let stagger = Double(TitleTemplateRegistry.template(for: title)?.layout.elements.map(\.staggerIndex).max() ?? 0)
        let entrance = title.animation.entrance == .none ? 0 : (motion?.animationIn.duration ?? 0.35) + stagger * (motion?.animationIn.stagger ?? 0)
        let exit = title.animation.exit == .none ? 0 : (motion?.animationOut.duration ?? 0.35) + stagger * (motion?.animationOut.stagger ?? 0)
        let margin = 1 / max(15, frameRate)
        let first = title.startTime + min(title.duration / 2, entrance + margin)
        let last = title.endTime - min(title.duration / 2, exit + margin)
        return min(first, last)...max(first, last)
    }

    static func times(_ title: TitleTimelineItem, frameRate: Double) -> [Double] {
        let range = holdRange(title, frameRate: frameRate)
        return Array(Set([range.lowerBound, (range.lowerBound + range.upperBound) / 2, range.upperBound]
            .map { ($0 * 600).rounded() / 600 })).sorted()
    }

    static func titles(at time: Double, timeline: Timeline) -> [TitleTimelineItem] {
        timeline.effectiveTitleItems.filter {
            $0.enabled && holdRange($0, frameRate: timeline.frameRate).contains(time)
                || $0.enabled && times($0, frameRate: timeline.frameRate).contains { abs($0 - time) < 1 / 1200 }
        }
    }

    static func tokens(_ text: String) -> [String] {
        text.precomposedStringWithCanonicalMapping.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func score(expected: String, recognized: String) -> Double {
        let wanted = tokens(expected)
        guard !wanted.isEmpty else { return 0 }
        var available = tokens(recognized)
        let matched = wanted.reduce(0) { count, word in
            guard let index = available.firstIndex(of: word) else { return count }
            available.remove(at: index)
            return count + 1
        }
        return Double(matched) / Double(wanted.count)
    }

    static func inspect(image: CGImage?, title: TitleTimelineItem, timeline: Timeline,
                        time: Double, actualPTS: Double?, source: String) -> TitleReadabilityEvidence {
        var result = TitleReadabilityEvidence(titleID: title.id, renderSignature: EditorialRenderSignature.signature(timeline),
            algorithmVersion: version, timelineTime: time, actualPTS: actualPTS, source: source,
            expectedText: title.text, recognizedText: "", confidences: [], pixelWidth: image?.width ?? 0,
            pixelHeight: image?.height ?? 0, score: 0)
        guard let image, let actualPTS, actualPTS.isFinite else { result.failure = "decode-failed"; return result }
        let size = CGSize(width: image.width, height: image.height)
        let bounds = CGRect(origin: .zero, size: size)
        let regions = TitleOverlayRenderer.textLayout(item: title, timelineTime: time, renderSize: size)
            .filter { !$0.requestedText.isEmpty }
        guard !regions.isEmpty, regions.allSatisfy({
            bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.bounds) && !$0.bounds.isEmpty
                && tokens($0.requestedText) == tokens($0.renderedText)
                && $0.visibility >= 0.9 && $0.textOpacity * title.style.effectiveOpacity >= 0.5
        }) else { result.failure = "clipped-hidden-or-incomplete-layout"; return result }
        let rect = regions.reduce(CGRect.null) { $0.union($1.bounds) }.insetBy(dx: -12, dy: -12).intersection(bounds)
        let roi = CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
                         width: rect.width / size.width, height: rect.height / size.height)
        result.region = NormalizedRegion(x: roi.minX, y: roi.minY, width: roi.width, height: roi.height)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        request.regionOfInterest = roi
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let candidates = (request.results ?? []).compactMap { $0.topCandidates(1).first }
            result.recognizedText = candidates.map(\.string).joined(separator: " ")
            result.confidences = candidates.map { Double($0.confidence) }
            result.score = score(expected: title.text, recognized: result.recognizedText)
            if result.score < 0.5 { result.failure = "ocr-below-threshold" }
        } catch { result.failure = "ocr-error: \(error.localizedDescription)" }
        return result
    }

    static func coverage(timeline: Timeline, evidence: [TitleReadabilityEvidence], source: String) -> (complete: Bool, passed: Bool) {
        let titles = timeline.effectiveTitleItems.filter(\.enabled)
        let current = evidence.filter { $0.source == source && $0.isCurrent(for: timeline) }
        let complete = titles.allSatisfy { title in
            times(title, frameRate: timeline.frameRate).allSatisfy { time in
                current.contains { $0.titleID == title.id && abs($0.timelineTime - time) < 1 / 120 }
            }
        }
        return (complete, complete && current.allSatisfy(\.passed))
    }
}
