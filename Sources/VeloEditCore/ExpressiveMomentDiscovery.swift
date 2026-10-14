import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// A discovery observation, not a certificate of technical safety or action
/// completion. The exact selected source and final MP4 still need review.
public struct ExpressiveMomentEvidence: Codable, Hashable, Sendable {
    public var version: Int = 2
    public var sourceStart: Double
    public var sourceEnd: Double
    public var sampleTimes: [Double]
    public var composition: Double
    public var humanMoment: Double
    public var meaningfulMovement: Double
    public var confidence: Double
    public var recommendedDuration: Double
    public var observation: String
    public var model: String

    // Literal source observations qualify the model's proposed scores.
    // An ordinary route can explain travel without earning a scenic hold;
    // camera translation alone cannot stand in for a visible subject action.
    var value: Double {
        let words = Set(observation.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        func has(_ vocabulary: Set<String>) -> Bool { !words.isDisjoint(with: vocabulary) }
        let route = has(["road", "path", "track", "street", "gravel"])
        let scenic = has(["river", "lake", "water", "sea", "mountain", "mountains", "valley", "reflections", "reflection", "cliff", "waterfall", "coast", "horizon", "sunlight", "light", "shadows", "canopy", "sunset", "sunrise"])
        let subjectAction = has(["steering", "wheel", "suspension", "paddle", "paddling", "rowing", "fishing", "tackle", "assembling", "unfolding", "folding", "packing", "pouring", "bottle", "helmet", "driver", "passenger"])
        let readableHuman = has(["face", "faces", "smile", "smiling", "talking", "conversation", "sitting", "seated", "bench", "interaction", "interacting", "gesture", "gestures"])
        let clothingOnly = has(["coat", "jacket", "clothing"]) && !readableHuman && !subjectAction
        let leavesScenery = scenic && route && has(["ending", "ends", "end"]) && has(["car", "van", "container", "fence"])
        let scenicScore = route && !scenic || clothingOnly && !scenic || leavesScenery ? min(composition, 0.55) : composition
        let actionScore = route && !subjectAction ? min(meaningfulMovement, 0.5) : meaningfulMovement
        let peopleScore = clothingOnly ? min(humanMoment, 0.45) : humanMoment
        return max(scenicScore, peopleScore, actionScore)
    }
    var supportsObservation: Bool {
        version == 2 && confidence >= 0.75 && value >= 0.65 && sampleTimes.count >= 3
            && sourceEnd > sourceStart && !observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func covers(_ candidate: Candidate) -> Bool {
        candidate.sourceStart >= sourceStart - 0.001
            && candidate.sourceStart + candidate.sourceDuration <= sourceEnd + 0.001
    }
}

enum ExpressiveMomentPolicy {
    static func requested(in prompt: String) -> Bool {
        let text = prompt.lowercased()
        return ["больше красоты", "насладиться поездкой", "выразительные пейзажи", "не торопить", "дать кадрам время", "живые моменты", "let shots breathe", "expressive landscapes"].contains(where: text.contains)
    }

    /// Existing taste stays the default. Only observed expressive moments
    /// receive longer holds; a fast detail does not become a ten-second shot.
    static func duration(_ unit: EditorialUnit, pacing: Double) -> Double? {
        guard let evidence = unit.candidate.insights?.expressiveMoment,
              evidence.supportsObservation, evidence.covers(unit.candidate),
              unit.evidence.confidence >= 0.55, !unit.evidence.hasHardOcclusion else { return nil }
        let hold = min(10, max(3, evidence.recommendedDuration))
        return min(unit.usableDuration, max(3, hold - max(0, pacing - 0.45)))
    }
    static func selectionValue(_ unit: EditorialUnit) -> Double {
        guard let evidence = unit.candidate.insights?.expressiveMoment,
              evidence.confidence >= 0.75, evidence.covers(unit.candidate) else { return unit.quality * 0.6 }
        return unit.quality * 0.4 + evidence.value * 0.6
    }
}

/// Source-wide, evenly spaced discovery independent of local quality peaks.
/// Every 12-second window receives three ordered images, including its edges.
/// These sparse observations propose moments; they never waive exact review.
struct ExpressiveMomentDiscovery: Sendable {
    static let version = "expressive-source-survey-v5-independent-repeated-observations"
    let cacheURL: URL
    let model: String
    struct Window: Sendable {
        var index: Int
        var start: Double
        var end: Double
        var samples: [VisualFrameSample]
    }
    struct Judgement: Codable {
        var index: Int
        var scene: String
        var composition: Double
        var humanMoment: Double
        var meaningfulMovement: Double
        var confidence: Double
        var recommendedDuration: Double
        var tags: [String]
        enum CodingKeys: String, CodingKey {
            case index, composition, humanMoment, meaningfulMovement, confidence, recommendedDuration, tags
            case scene = "a_observation"
        }
    }
    struct Response: Codable { var windows: [Judgement] }
    static func parse(_ content: String, indices: [Int]) throws -> [Judgement] {
        let decoded = try JSONDecoder().decode(Response.self, from: Data(content.utf8)).windows
        guard decoded.count == indices.count, Set(decoded.map(\.index)) == Set(indices),
              Set(decoded.map(\.index)).count == decoded.count,
              decoded.allSatisfy({ j in
                  [j.composition, j.humanMoment, j.meaningfulMovement, j.confidence].allSatisfy { $0.isFinite && (0...1).contains($0) }
                      && j.recommendedDuration.isFinite && (3...10).contains(j.recommendedDuration)
                      && j.scene.split(whereSeparator: { !$0.isLetter }).filter({ $0.count > 1 }).count >= 3
              }) else { throw URLError(.cannotParseResponse) }
        return decoded.sorted { $0.index < $1.index }
    }

    /// Repeated prose across different rows is not independent evidence.
    /// Real batch probes described four different road/river windows using
    /// the same pan and score. Recheck such rows separately, even if a static
    /// scene could legitimately look similar.
    static func requiresIndependentRows(_ rows: [Judgement]) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        }
        for i in rows.indices {
            let a = words(rows[i].scene)
            guard !a.isEmpty else { continue }
            for j in rows.indices where j > i {
                let b = words(rows[j].scene)
                let union = a.union(b).count
                if union > 0 && Double(a.intersection(b).count) / Double(union) >= 0.92 { return true }
            }
        }
        return false
    }

    func enrich(analyses: [AnalysisResult], assets: [MediaAsset], progress: FilmBuildProgressHandler? = nil) async throws -> [AnalysisResult] {
        var result = analyses
        let sourceFrames = FrameCache(rootURL: cacheURL.appendingPathComponent("ExpressiveFrames"))
        let local = LocalEditorialEvidenceAnalyzer(cacheURL: cacheURL)
        let reviewer = SelectedContentReviewer(cacheURL: cacheURL, model: model)
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for i in result.indices {
            try Task.checkCancellation()
            guard let asset = byID[result[i].assetID], asset.kind == .video,
                  !asset.excluded, !asset.missing, let duration = asset.metadata.duration, duration > 0 else { continue }
            let identity = FrameCacheKey.sourceIdentity(url: asset.originalURL, contentHash: asset.contentHash)
            let marker = Self.version + "|" + identity + "|" + model
            if result[i].warnings.contains(marker) { continue }
            // Refresh discovery proposals after a schema/cache migration. The
            // original mined candidates and their temporal evidence survive.
            result[i].candidates.removeAll { $0.explanation.contains(where: { $0.hasPrefix("Обзор всего исходника: ") }) }
            for j in result[i].candidates.indices { result[i].candidates[j].insights?.expressiveMoment = nil }
            let starts = Array(stride(from: 0.0, to: duration - 1, by: 12.0))
            var observations: [(Window, Judgement)] = []
            var completed = true
            for batchStart in stride(from: 0, to: starts.count, by: 4) {
                try Task.checkCancellation()
                await progress?(FilmBuildProgress(.moments, completed: batchStart, total: starts.count,
                    detail: "Выразительность · \(asset.displayName)"))
                var windows: [Window] = []
                for index in batchStart..<min(starts.count, batchStart + 4) {
                    let start = starts[index], end = min(duration, start + 12)
                    let times = [start, (start + end) / 2, max(start, end - 1 / max(24, asset.metadata.frameRate ?? 30))]
                    let samples = try await AdaptiveFrameSampler().editorialSamples(url: asset.originalURL,
                        sourceHash: asset.contentHash, timestamps: times, frameCache: sourceFrames)
                    guard samples.count == 3 else { completed = false; continue }
                    windows.append(.init(index: index, start: start, end: end, samples: samples))
                }
                guard !windows.isEmpty else { continue }
                let key = EditorialIdentity.hash(marker + "|\(batchStart)")
                let responseURL = cacheURL.appendingPathComponent("ExpressiveResponses/\(key).json")
                do {
                    let content = try await reviewer.modelAnswer(body: try body(windows), responseURL: responseURL)
                    let judgements = try Self.parse(content, indices: windows.map(\.index))
                    if Self.requiresIndependentRows(judgements) {
                        result[i].warnings.append("Expressive batch repeated observations; independently rechecked rows \(windows.map(\.index))")
                        throw URLError(.cannotParseResponse)
                    }
                    let byIndex = Dictionary(uniqueKeysWithValues: judgements.map { ($0.index, $0) })
                    observations += windows.compactMap { w in byIndex[w.index].map { (w, $0) } }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    // A malformed batch cannot assign invented observations.
                    // Retry each original row once with a single-row schema.
                    for window in windows {
                        do {
                            let retryURL = responseURL.deletingPathExtension().appendingPathExtension("row-\(window.index).json")
                            let answer = try await reviewer.modelAnswer(body: try body([window]), responseURL: retryURL)
                            let judgement = try Self.parse(answer, indices: [window.index])[0]
                            observations.append((window, judgement))
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            completed = false
                            result[i].warnings.append("Expressive discovery incomplete: \(asset.displayName) window \(window.index): \(error.localizedDescription)")
                        }
                    }
                }
            }
            for (window, judgement) in observations {
                let evidence = ExpressiveMomentEvidence(sourceStart: window.start, sourceEnd: window.end,
                    sampleTimes: window.samples.map(\.timestamp), composition: judgement.composition,
                    humanMoment: judgement.humanMoment, meaningfulMovement: judgement.meaningfulMovement,
                    confidence: judgement.confidence, recommendedDuration: judgement.recommendedDuration,
                    observation: judgement.scene, model: model)
                // A low survey score is not a technical exclusion. Existing
                // action/chronology evidence and mandatory reviews stay intact.
                for j in result[i].candidates.indices where evidence.covers(result[i].candidates[j]) {
                    if result[i].candidates[j].insights == nil { result[i].candidates[j].insights = CandidateInsights() }
                    result[i].candidates[j].insights?.expressiveMoment = evidence
                }
                guard evidence.supportsObservation else { continue }
                let id = EditorialIdentity.uuid(Self.version + "|" + identity + "|\(window.start)")
                if result[i].candidates.contains(where: { $0.id == id }) { continue }
                var candidate = Candidate(id: id, assetID: asset.id, sourceStart: window.start,
                    sourceDuration: window.end - window.start,
                    scores: ClipScores(quality: 0.5, interest: evidence.value, action: judgement.meaningfulMovement,
                        stability: 0.5), tags: Set(judgement.tags),
                    explanation: ["Обзор всего исходника: " + judgement.scene],
                    insights: CandidateInsights(sceneSummary: judgement.scene, visualAppeal: judgement.composition,
                        composition: judgement.composition, storyValue: max(judgement.humanMoment, judgement.meaningfulMovement)))
                let measured = try await local.analyze(candidate: candidate, asset: asset)
                candidate.insights?.editorialEvidence = measured
                candidate.insights?.expressiveMoment = evidence
                candidate.insights?.bestTakeScore = measured.samples.isEmpty ? 0.5
                    : measured.samples.reduce(0) { $0 + $1.quality } / Double(measured.samples.count)
                if EditorialUnit(candidate: candidate).usableDuration >= 1.5 { result[i].candidates.append(candidate) }
            }
            if completed && observations.count == starts.count { result[i].warnings.append(marker) }
        }
        return result
    }

    private func body(_ windows: [Window]) throws -> [String: Any] {
        let indices = windows.map(\.index)
        var fields: [String: Any] = ["index": ["type": "integer", "enum": indices],
            // Literal content comes before numerical scores in the grammar.
            // Real 8B and 30B probes otherwise echoed numbers into scene.
            "a_observation": ["type": "string", "maxLength": 220],
            "recommendedDuration": ["type": "number", "minimum": 3, "maximum": 10],
            "tags": ["type": "array", "maxItems": 6, "items": ["type": "string"]]]
        for name in ["composition", "humanMoment", "meaningfulMovement", "confidence"] {
            fields[name] = ["type": "number", "minimum": 0, "maximum": 1]
        }
        let prompt = """
        Each row is ONE continuous source window, with its beginning, middle and ending from left to right. Row labels are original window indices \(indices). Judge each row independently. Return exactly those indices.
        a_observation: FIRST write one concrete English sentence under 140 characters describing the visible subject and change across the row, including bad edges. Then grade it. composition: expressive space, depth, light, reflections or balanced view; sharpness alone is NOT beauty. humanMoment: readable faces, reactions or people interacting; cropped clothing alone has no human value. meaningfulMovement: purposeful visible action, vehicle/wheel/suspension moving through a route, paddle stroke; random camera swing or adjusting the camera has no value. Scores 0..1: 0.3 ordinary/incidental, 0.5 useful but modest, 0.8 strong clear moment. Do not give every row a high score. confidence: certainty of these observations, not technical sharpness. recommendedDuration 3..10 seconds: give a strong calm landscape/human interaction time to breathe (6..10), a brief detail less. Do not infer audio or certify a complete action from three frames. tags: concrete English content labels, distinguish buggy/UTV from bicycle. A low-action landscape can be strong. Lens cover, accidental tilt, ground or coat that dominates a row reduces its editorial value.
        """
        return ["model": model, "stream": false, "think": false,
            // A measured four-row request uses about 1,355 input tokens plus
            // at most 1,280 output tokens. Match the exact clip review context:
            // alternating 8K/4K runners otherwise reload the same local model
            // for tens of seconds on every request without adding evidence.
            "options": ["num_ctx": 4096, "num_predict": max(600, windows.count * 320), "temperature": 0, "seed": 0],
            "format": ["type": "object", "required": ["windows"], "properties": [
                "windows": ["type": "array", "minItems": windows.count, "maxItems": windows.count,
                    "items": ["type": "object", "additionalProperties": false, "required": fields.keys.sorted(), "properties": fields]]]],
            "messages": [["role": "user", "content": prompt, "images": [try sheet(windows)]]]]
    }

    private func sheet(_ windows: [Window]) throws -> String {
        let width = 960, rowHeight = 204, height = windows.count * rowHeight
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw URLError(.cannotDecodeContentData) }
        context.setFillColor(CGColor(gray: 0.03, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (row, window) in windows.enumerated() {
            for (column, sample) in window.samples.enumerated() {
                guard let data = Data(base64Encoded: sample.jpegBase64),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw URLError(.cannotDecodeContentData) }
                let x = Double(column * 320), y = Double((windows.count - row - 1) * rowHeight)
                let scale = min(320 / Double(image.width), 180 / Double(image.height))
                let w = Double(image.width) * scale, h = Double(image.height) * scale
                context.draw(image, in: CGRect(x: x + (320 - w) / 2, y: y + 24 + (180 - h) / 2, width: w, height: h))
                context.textPosition = CGPoint(x: x + 8, y: y + 5)
                let text = NSAttributedString(string: "WINDOW \(window.index) / \(column)", attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 17, nil),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
        }
        guard let image = context.makeImage() else { throw URLError(.cannotDecodeContentData) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw URLError(.cannotDecodeContentData) }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw URLError(.cannotDecodeContentData) }
        return (data as Data).base64EncodedString()
    }
}
