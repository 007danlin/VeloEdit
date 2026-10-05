import Foundation
import CryptoKit
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

public struct AdaptiveSamplingPlan: Hashable, Sendable {
    public let coarseTimestamps: [Double]
    public let candidateDuration: Double

    public init(duration: Double, profile: AIAnalysisProfile) {
        guard duration > 0 else {
            coarseTimestamps = []
            candidateDuration = 0
            return
        }
        let estimatedCount = max(2, Int(ceil(duration / profile.coarseInterval)))
        let count = min(profile.maximumCoarseFrames, estimatedCount)
        let spacing = duration / Double(count)
        coarseTimestamps = (0..<count).map { min(max(0, (Double($0) + 0.5) * spacing), max(0, duration - 0.04)) }
        candidateDuration = duration < 12 ? duration : min(8, max(3.5, duration / 30))
    }

    public func denseTimestamps(around centers: [Double], duration: Double, interval: Double, framesPerCandidate: Int) -> [Double] {
        guard duration > 0, interval > 0 else { return [] }
        var values = Set(coarseTimestamps.map { Int(($0 * 1000).rounded()) })
        let radius = Double(max(1, framesPerCandidate - 1)) * interval / 2
        for center in centers {
            var timestamp = center - radius
            for _ in 0..<framesPerCandidate {
                values.insert(Int((min(max(0, timestamp), max(0, duration - 0.04)) * 1000).rounded()))
                timestamp += interval
            }
        }
        return values.sorted().map { Double($0) / 1000 }
    }
}

struct VisualFrameSample: Codable, Hashable, Sendable {
    var timestamp: Double
    let motion: Double
    let exposure: Double
    let detail: Double
    let labels: Set<String>
    let labelConfidence: Double
    let faceCount: Int
    var jpegBase64: String
    let histogram: [Double]
    let luminanceFingerprint: [UInt8]
    let subjects: [FrameSubjectObservation]?
    var actualTimestamp: Double? = nil
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil

    init(
        timestamp: Double,
        motion: Double,
        exposure: Double,
        detail: Double,
        labels: Set<String>,
        labelConfidence: Double,
        faceCount: Int,
        jpegBase64: String,
        histogram: [Double],
        luminanceFingerprint: [UInt8],
        subjects: [FrameSubjectObservation]? = nil
    ) {
        self.timestamp = timestamp
        self.motion = motion
        self.exposure = exposure
        self.detail = detail
        self.labels = labels
        self.labelConfidence = labelConfidence
        self.faceCount = faceCount
        self.jpegBase64 = jpegBase64
        self.histogram = histogram
        self.luminanceFingerprint = luminanceFingerprint
        self.subjects = subjects
    }

    func withMotion(_ motion: Double) -> VisualFrameSample {
        var value = VisualFrameSample(timestamp: timestamp, motion: motion, exposure: exposure, detail: detail,
            labels: labels, labelConfidence: labelConfidence, faceCount: faceCount, jpegBase64: jpegBase64,
            histogram: histogram, luminanceFingerprint: luminanceFingerprint, subjects: subjects)
        value.actualTimestamp = actualTimestamp
        value.pixelWidth = pixelWidth
        value.pixelHeight = pixelHeight
        return value
    }

    var interest: Double {
        let faces = min(1, Double(faceCount) / 2)
        return min(1, 0.27 * motion + 0.24 * detail + 0.19 * exposure + 0.15 * labelConfidence + 0.15 * faces)
    }

    var semanticPotential: Double {
        let faces = min(1, Double(faceCount) / 2)
        return min(1, 0.34 * detail + 0.26 * exposure + 0.22 * labelConfidence + 0.18 * faces)
    }

    var technicalQuality: Double {
        min(1, 0.58 * detail + 0.42 * exposure)
    }
}

struct FrameSamplingOutcome: Sendable {
    let samples: [VisualFrameSample]
    let scenes: [DetectedScene]
    let decodedFrameCount: Int
    let cacheHitCount: Int
    let visionCallCount: Int
}

actor AdaptiveFrameSampler {
    func editorialSamples(url: URL, sourceHash: String, timestamps: [Double], frameCache: FrameCache) async throws -> [VisualFrameSample] {
        try await extract(url: url, sourceHash: sourceHash, timestamps: timestamps, maximumSize: 384, purpose: .aiDirector, frameCache: frameCache).samples
    }

    func samplePhoto(
        url: URL,
        sourceHash: String,
        maximumSize: Int,
        frameCache: FrameCache
    ) async throws -> FrameSamplingOutcome {
        let key = FrameCacheKey(sourceFile: FrameCacheKey.sourceIdentity(url: url, contentHash: sourceHash), timestamp: 0, resolution: maximumSize, processingPurpose: .adaptiveSampling)
        let resolved = try await frameCache.resolve(key) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(256, maximumSize)
              ] as CFDictionary) else {
            throw URLError(.cannotDecodeContentData)
        }
        try Task.checkCancellation()
        let fingerprint = Self.fingerprint(image)
        let mean = fingerprint.isEmpty ? 128 : Double(fingerprint.reduce(0) { $0 + Int($1) }) / Double(fingerprint.count)
        let vision = Self.visionFeatures(for: image)
        var sample = VisualFrameSample(
            timestamp: 0,
            motion: 0,
            exposure: max(0, 1 - abs(mean - 128) / 128),
            detail: Self.detail(fingerprint, width: 32),
            labels: vision.labels,
            labelConfidence: vision.confidence,
            faceCount: vision.faceCount,
            jpegBase64: Self.jpegBase64(image),
            histogram: Self.histogram(fingerprint),
            luminanceFingerprint: fingerprint,
            subjects: vision.subjects
        )
        sample.actualTimestamp = 0
        sample.pixelWidth = image.width
        sample.pixelHeight = image.height
        return sample
        }
        let computed = resolved.origin == .computed
        return FrameSamplingOutcome(samples: [resolved.sample], scenes: [], decodedFrameCount: computed ? 1 : 0, cacheHitCount: computed ? 0 : 1, visionCallCount: computed ? 1 : 0)
    }

    func sample(
        url: URL,
        sourceHash: String,
        duration: Double,
        profile: AIAnalysisProfile,
        frameCache: FrameCache,
        priorityTimestamps: [Double] = []
    ) async throws -> FrameSamplingOutcome {
        let plan = AdaptiveSamplingPlan(duration: duration, profile: profile)
        let coarseOutcome = try await extract(
            url: url,
            sourceHash: sourceHash,
            timestamps: plan.coarseTimestamps,
            maximumSize: profile.proxyLongEdge,
            purpose: .sceneDetection,
            frameCache: frameCache
        )
        let coarse = coarseOutcome.samples
        let scenes = SceneDetector().detect(samples: coarse, duration: duration, sensitivity: profile.sceneSensitivity)
        let peakCount = min(profile.maximumDeepCandidates, max(1, coarse.count / 3))
        let visualCenters = diversePeaks(in: coarse, limit: peakCount, minimumGap: max(2, plan.candidateDuration * 0.55)).map(\.timestamp)
        var sceneCenters = scenes.map(\.representativeTimestamp)
        sceneCenters.append(contentsOf: scenes.filter { $0.motionScore >= 0.48 }.flatMap {
            [max($0.startTime, $0.representativeTimestamp - profile.denseInterval), min($0.endTime, $0.representativeTimestamp + profile.denseInterval)]
        })
        let centers = visualCenters + sceneCenters + priorityTimestamps.filter { $0.isFinite && $0 >= 0 && $0 < duration }
        let allTimes = plan.denseTimestamps(around: centers, duration: duration, interval: profile.denseInterval, framesPerCandidate: profile.framesPerCandidate)
        let denseOutcome = try await extract(
            url: url,
            sourceHash: sourceHash,
            timestamps: allTimes,
            maximumSize: profile.proxyLongEdge,
            purpose: .adaptiveSampling,
            frameCache: frameCache
        )
        return FrameSamplingOutcome(
            samples: denseOutcome.samples,
            scenes: scenes,
            decodedFrameCount: coarseOutcome.decoded + denseOutcome.decoded,
            cacheHitCount: coarseOutcome.cacheHits + denseOutcome.cacheHits,
            visionCallCount: coarseOutcome.visionCalls + denseOutcome.visionCalls
        )
    }

    private func extract(
        url: URL,
        sourceHash: String,
        timestamps: [Double],
        maximumSize: Int,
        purpose: FrameProcessingPurpose,
        frameCache: FrameCache
    ) async throws -> (samples: [VisualFrameSample], decoded: Int, cacheHits: Int, visionCalls: Int) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumSize, height: maximumSize)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        let sourceIdentity = FrameCacheKey.sourceIdentity(url: url, contentHash: sourceHash)
        var previous: VisualFrameSample?
        var result: [VisualFrameSample] = []
        var decoded = 0
        var cacheHits = 0
        var visionCalls = 0
        result.reserveCapacity(timestamps.count)
        var resourcePacer = ResourceWorkPacer()
        for timestamp in timestamps {
            try Task.checkCancellation()
            let key = FrameCacheKey(sourceFile: sourceIdentity, timestamp: timestamp, resolution: maximumSize, processingPurpose: purpose, decodeTimeScale: 600)
            try await resourcePacer.checkpoint()
            let trace = PerformanceTrace.current
            let resolved = try await frameCache.resolve(key) {
                let started = ProcessInfo.processInfo.systemUptime
                var actualTime = CMTime.invalid
                let image = try generator.copyCGImage(at: CMTime(seconds: timestamp, preferredTimescale: 600), actualTime: &actualTime)
                trace?.event("frame.decode", values: ["seconds": ProcessInfo.processInfo.systemUptime - started])
                let fingerprint = Self.fingerprint(image)
                let mean = fingerprint.isEmpty ? 128 : Double(fingerprint.reduce(0) { $0 + Int($1) }) / Double(fingerprint.count)
                let visionStarted = ProcessInfo.processInfo.systemUptime
                let vision = Self.visionFeatures(for: image)
                trace?.event("frame.vision", values: ["seconds": ProcessInfo.processInfo.systemUptime - visionStarted])
                var sample = VisualFrameSample(
                    timestamp: timestamp, motion: 0,
                    exposure: max(0, 1 - abs(mean - 128) / 128), detail: Self.detail(fingerprint, width: 32),
                    labels: vision.labels, labelConfidence: vision.confidence, faceCount: vision.faceCount,
                    jpegBase64: Self.jpegBase64(image), histogram: Self.histogram(fingerprint),
                    luminanceFingerprint: fingerprint, subjects: vision.subjects)
                sample.actualTimestamp = actualTime.seconds.isFinite ? actualTime.seconds : nil
                sample.pixelWidth = image.width
                sample.pixelHeight = image.height
                return sample
            }
            if resolved.origin == .computed { decoded += 1; visionCalls += 1 }
            else { cacheHits += 1 }
            var requestedSample = resolved.sample
            requestedSample.timestamp = timestamp
            let sample = Self.contextualSample(requestedSample, previous: previous)
            trace?.event("frame.evaluated", fields: ["source": sourceIdentity, "purpose": purpose.rawValue,
                "origin": resolved.origin.rawValue, "representation": key.representation], values: [
                "requested": timestamp, "actual": sample.actualTimestamp ?? timestamp,
                "previous": previous?.timestamp ?? -1, "width": Double(sample.pixelWidth ?? maximumSize),
                "height": Double(sample.pixelHeight ?? maximumSize)])
            previous = sample
            result.append(sample)
        }
        return (result, decoded, cacheHits, visionCalls)
    }

    static func contextualSample(_ sample: VisualFrameSample, previous: VisualFrameSample?) -> VisualFrameSample {
        let rawMotion = previous.map { motion(between: $0.luminanceFingerprint, and: sample.luminanceFingerprint) } ?? 0
        let deltaTime = previous.map { max(0.001, sample.timestamp - $0.timestamp) } ?? 1
        return sample.withMotion(min(1, rawMotion * min(1, max(0.15, 1 / deltaTime))))
    }

    private func diversePeaks(in samples: [VisualFrameSample], limit: Int, minimumGap: Double) -> [VisualFrameSample] {
        guard limit > 0 else { return [] }
        var selected: [VisualFrameSample] = []
        func append(from ranked: [VisualFrameSample], quota: Int) {
            var added = 0
            for sample in ranked where selected.count < limit && added < quota {
                if selected.allSatisfy({ abs($0.timestamp - sample.timestamp) >= minimumGap }) {
                    selected.append(sample)
                    added += 1
                }
            }
        }
        append(from: samples.sorted { $0.interest > $1.interest }, quota: max(1, limit / 2))
        append(from: samples.sorted { $0.semanticPotential > $1.semanticPotential }, quota: max(1, limit / 3))
        append(from: samples.sorted { $0.technicalQuality > $1.technicalQuality }, quota: limit)
        return selected
    }

    private static func fingerprint(_ image: CGImage) -> [UInt8] {
        let width = 32
        let height = 18
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    private static func motion(between lhs: [UInt8], and rhs: [UInt8]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let delta = zip(lhs, rhs).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return min(1, Double(delta) / Double(lhs.count * 72))
    }

    private static func detail(_ pixels: [UInt8], width: Int) -> Double {
        guard pixels.count > width else { return 0 }
        var delta = 0
        for index in 1..<pixels.count where index % width != 0 {
            delta += abs(Int(pixels[index]) - Int(pixels[index - 1]))
        }
        return min(1, Double(delta) / Double(max(1, pixels.count - 1) * 42))
    }

    private static func histogram(_ pixels: [UInt8]) -> [Double] {
        guard !pixels.isEmpty else { return [] }
        var bins = [Double](repeating: 0, count: 16)
        for pixel in pixels { bins[min(15, Int(pixel) / 16)] += 1 }
        return bins.map { $0 / Double(pixels.count) }
    }

    private static func visionFeatures(for image: CGImage) -> (labels: Set<String>, confidence: Double, faceCount: Int, subjects: [FrameSubjectObservation]) {
        let classification = VNClassifyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([classification, faces, saliency])
        let observations = (classification.results ?? []).prefix(6).filter { $0.confidence >= 0.25 }
        let labels = Set(observations.map {
            $0.identifier.lowercased().replacingOccurrences(of: " ", with: "-")
        })
        var subjects = (faces.results ?? []).map { face in
            FrameSubjectObservation(
                kind: .face,
                label: "face",
                region: NormalizedRegion(x: face.boundingBox.minX, y: face.boundingBox.minY, width: face.boundingBox.width, height: face.boundingBox.height),
                confidence: Double(face.confidence)
            )
        }
        let primaryKind = subjectKind(for: labels)
        let primaryLabel = subjectLabel(for: labels, kind: primaryKind)
        for object in saliency.results?.first?.salientObjects ?? [] where object.confidence >= 0.18 {
            subjects.append(FrameSubjectObservation(
                kind: primaryKind,
                label: primaryLabel,
                region: NormalizedRegion(x: object.boundingBox.minX, y: object.boundingBox.minY, width: object.boundingBox.width, height: object.boundingBox.height),
                confidence: Double(object.confidence)
            ))
        }
        if !subjects.contains(where: { $0.kind == .person }), !subjects.filter({ $0.kind == .face }).isEmpty {
            let facesUnion = subjects.filter { $0.kind == .face }.map(\.region)
            if let first = facesUnion.first {
                let minX = facesUnion.map(\.x).min() ?? first.x
                let minY = facesUnion.map(\.y).min() ?? first.y
                let maxX = facesUnion.map { $0.x + $0.width }.max() ?? first.x + first.width
                let maxY = facesUnion.map { $0.y + $0.height }.max() ?? first.y + first.height
                subjects.append(FrameSubjectObservation(
                    kind: .person,
                    label: "person",
                    region: NormalizedRegion(x: max(0, minX - 0.08), y: max(0, minY - 0.18), width: min(1 - max(0, minX - 0.08), maxX - minX + 0.16), height: min(1 - max(0, minY - 0.18), maxY - minY + 0.32)),
                    confidence: subjects.filter { $0.kind == .face }.map(\.confidence).max() ?? 0.5
                ))
            }
        }
        return (labels, Double(observations.first?.confidence ?? 0), faces.results?.count ?? 0, subjects)
    }

    private static func subjectKind(for labels: Set<String>) -> SubjectKind {
        let text = labels.joined(separator: " ")
        if ["cyclist", "bicyclist", "cycling", "mountain-bike"].contains(where: text.contains) { return .cyclist }
        if ["bicycle", "bike"].contains(where: text.contains) { return .bicycle }
        if ["person", "people", "human", "pedestrian"].contains(where: text.contains) { return .person }
        if ["car", "automobile", "vehicle", "motorcycle", "truck", "bus"].contains(where: text.contains) { return .vehicle }
        if ["dog", "cat", "animal", "horse", "bird"].contains(where: text.contains) { return .animal }
        return .salientObject
    }

    private static func subjectLabel(for labels: Set<String>, kind: SubjectKind) -> String {
        let preferred: [String]
        switch kind {
        case .cyclist: preferred = ["cyclist", "bicyclist", "cycling"]
        case .bicycle: preferred = ["bicycle", "bike"]
        case .person: preferred = ["person", "people", "human"]
        case .vehicle: preferred = ["car", "vehicle", "motorcycle", "truck"]
        case .animal: preferred = ["dog", "cat", "animal", "horse", "bird"]
        default: preferred = []
        }
        return labels.first(where: { label in preferred.contains(where: label.contains) }) ?? kind.rawValue
    }

    private static func jpegBase64(_ image: CGImage) -> String {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return "" }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.68] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return "" }
        return (data as Data).base64EncodedString()
    }
}

private struct OllamaVisionMessage: Codable {
    let role: String
    let content: String
    let images: [String]?
}

private struct OllamaVisionResponse: Decodable {
    let message: OllamaVisionMessage?
    let model: String?
    let done: Bool?
    let done_reason: String?
    let error: String?
    let load_duration: Double?
    let prompt_eval_duration: Double?
    let eval_duration: Double?
    let prompt_eval_count: Double?
    let eval_count: Double?

    var runtimeMeasurements: [String: Double] {
        var values: [String: Double] = [:]
        if let load_duration { values["loadSeconds"] = load_duration / 1_000_000_000 }
        if let prompt_eval_duration { values["promptSeconds"] = prompt_eval_duration / 1_000_000_000 }
        if let eval_duration { values["generationSeconds"] = eval_duration / 1_000_000_000 }
        if let prompt_eval_count { values["promptTokens"] = prompt_eval_count }
        if let eval_count { values["generatedTokens"] = eval_count }
        return values
    }
}

/// Only a finished, validated response may enter the semantic cache.
struct OllamaVisionStream {
    private(set) var content = ""
    private(set) var finished = false
    private(set) var measurements: [String: Double] = [:]
    let expectedModel: String

    mutating func append(_ line: String) throws {
        guard !finished else { throw URLError(.cannotParseResponse) }
        let event = try JSONDecoder().decode(OllamaVisionResponse.self, from: Data(line.utf8))
        if let error = event.error {
            throw NSError(domain: "OllamaInference", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
        if let model = event.model, model != expectedModel && model != expectedModel + ":latest" {
            throw URLError(.cannotParseResponse)
        }
        content += event.message?.content ?? ""
        guard content.utf8.count <= 2_000_000, event.done_reason != "length" else {
            throw URLError(.cannotParseResponse)
        }
        finished = event.done == true
        if finished { measurements = event.runtimeMeasurements }
    }

    func completedContent() throws -> String {
        guard finished, !content.isEmpty else { throw URLError(.cannotParseResponse) }
        return content
    }
}
private struct OllamaModelTags: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}

struct DeepFrameJudgement: Decodable {
    let index: Int?
    let interest: Double?
    let action: Double?
    let quality: Double?
    let stability: Double?
    let tags: [String]?
    let reason: String?
    let scene: String?
    let emotion: String?
    let visualAppeal: Double?
    let composition: Double?
    let sharpness: Double?
    let motionBlur: Double?
    let noise: Double?
    let shake: Double?
    let exposureQuality: Double?
    let slowMotionSuitability: Double?
    let speedRampSuitability: Double?
    let originalAudioUsefulness: Double?
    let storyValue: Double?
    let intro: Double?
    let setup: Double?
    let buildup: Double?
    let climax: Double?
    let outro: Double?
}

private struct DeepSceneEnvelope: Decodable {
    let scenes: [DeepFrameJudgement]
}

private struct VLMSceneInput: Sendable {
    let index: Int
    let frames: [VisualFrameSample]
    let telemetry: TelemetryMoment?
    var sourceWindow: ClosedRange<Double>? = nil
}

actor OllamaVisionRuntime {
    private let baseURL = URL(string: "http://127.0.0.1:11434")!

    static func responseSchema(indices: [Int]) -> [String: Any] {
        var fields: [String: Any] = [
            "index": ["type": "integer", "enum": indices],
            "scene": ["type": "string"], "reason": ["type": "string"],
            "tags": ["type": "array", "items": ["type": "string"], "maxItems": 8]
        ]
        for name in ["interest", "action", "quality", "stability", "storyValue"] {
            fields[name] = ["type": "number", "minimum": 0, "maximum": 1]
        }
        return ["type": "object", "additionalProperties": false, "required": ["scenes"],
            "properties": ["scenes": ["type": "array", "minItems": indices.count, "maxItems": indices.count,
                "items": ["type": "object", "additionalProperties": false,
                    "required": fields.keys.sorted(), "properties": fields]]]]
    }

    static func parseBatch(_ content: String, indices: [Int]) throws -> [Int: DeepFrameJudgement] {
        var clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```json") { clean.removeFirst(7) }
        else if clean.hasPrefix("```") { clean.removeFirst(3) }
        if clean.hasSuffix("```") { clean.removeLast(3) }
        let data = Data(clean.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let envelope = try JSONDecoder().decode(DeepSceneEnvelope.self, from: data)
        var result: [Int: DeepFrameJudgement] = [:]
        let requested = Set(indices)
        for judgement in envelope.scenes {
            guard let index = judgement.index, requested.contains(index), result[index] == nil else {
                // Never attach a renumbered/duplicate scene to another clip,
                // or trap inside Dictionary(uniqueKeysWithValues:).
                throw URLError(.cannotParseResponse)
            }
            let scores = [judgement.interest, judgement.action, judgement.quality, judgement.stability, judgement.storyValue].compactMap { $0 }
            guard scores.count == 5, scores.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  judgement.scene?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  judgement.tags?.isEmpty == false else { throw URLError(.cannotParseResponse) }
            result[index] = judgement
        }
        guard Set(result.keys) == requested else { throw URLError(.cannotParseResponse) }
        return result
    }

    func isAvailable(model: String) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let tags = try? JSONDecoder().decode(OllamaModelTags.self, from: data) else { return false }
        if model.contains(":") { return tags.models.contains { $0.name == model } }
        return tags.models.contains { $0.name == model || $0.name == "\(model):latest" }
    }

    fileprivate func analyzeBatch(
        scenes: [VLMSceneInput],
        model: String,
        thinking: Bool,
        timeout: TimeInterval,
        cache: DeepAnalysisCache? = nil,
        cacheContext: String? = nil,
        metrics: AnalysisMetricsRecorder? = nil
    ) async throws -> [Int: DeepFrameJudgement] {
        do {
            return try await LocalAIModelManager.recoveringRequest(retryTimeouts: false) {
                try await requestBatch(scenes: scenes, model: model, thinking: thinking, timeout: timeout, cache: cache, cacheContext: cacheContext, metrics: metrics)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Small local models can repeat an index in a valid JSON array.
            // A one-scene schema removes that ambiguity. Retry each scene
            // once, preserving successful answers and bounding extra work.
            guard scenes.count > 1,
                  error is DecodingError || (error as? URLError)?.code == .cannotParseResponse else { throw error }
            var recovered: [Int: DeepFrameJudgement] = [:]
            for scene in scenes {
                try Task.checkCancellation()
                do {
                    let answer = try await requestBatch(scenes: [scene], model: model, thinking: thinking, timeout: timeout, cache: cache, cacheContext: cacheContext, metrics: metrics)
                    recovered.merge(answer) { _, new in new }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if (error as? URLError)?.code == .cancelled { throw error }
                }
            }
            return recovered
        }
    }

    private func requestBatch(
        scenes: [VLMSceneInput], model: String, thinking: Bool, timeout: TimeInterval,
        cache: DeepAnalysisCache?, cacheContext: String?, metrics: AnalysisMetricsRecorder?
    ) async throws -> [Int: DeepFrameJudgement] {
        var resourcePacer = ResourceWorkPacer()
        try await resourcePacer.checkpoint()
        let images = scenes.flatMap { $0.frames.map(\.jpegBase64).filter { !$0.isEmpty } }
        guard !images.isEmpty else { throw URLError(.cannotDecodeContentData) }
        let grouping = scenes.map { scene in
            let telemetry = scene.telemetry.map { "\($0.explanation), \(Int($0.score * 100))%" } ?? "нет"
            return "scene index=\(scene.index): frames=\(scene.frames.count), telemetry=\(telemetry)"
        }.joined(separator: "\n")
        let prompt = """
        Оцени несколько коротких сцен видео. Изображения приложены последовательно группами в указанном порядке:
        \(grouping)
        Верни JSON по заданной схеме: ровно одну оценку на каждую указанную сцену. Сохраняй её исходный index, не перенумеровывай и не добавляй сцен.
        scene: коротко опиши видимое место, главный объект и действие. tags: до восьми конкретных английских меток содержания; различай bicycle, buggy/UTV, car и motorcycle только когда это видно. reason: одно короткое объяснение монтажной ценности.
        Оцени каждую сцену независимо: interest — интерес зрителя, action — изменение действия между кадрами, quality — видимость и техническое качество изображения, stability — устойчивость камеры, storyValue — ценность для истории. Шкала 0...1: quality=0 означает нечитаемый или испорченный кадр, около 0.5 — обычный пригодный кадр, около 0.8 — ясный хороший кадр. Низкая action не означает низкое quality: спокойный пейзаж и портрет могут быть ценными. Не присваивай всем полям одну оценку. Не выдумывай события, движение или звук, которых не подтверждают изображения.
        """
        let payload: [String: Any] = ["model": model,
            "messages": [["role": "user", "content": prompt, "images": images]],
            "stream": true, "think": thinking, "keep_alive": "10m",
            // Structured scene judgements are short. A model stuck repeating
            // text must return control to batch repair/local recovery.
            "options": ["num_predict": max(768, scenes.count * 384) + (thinking ? 4096 : 0)],
            "format": Self.responseSchema(indices: scenes.map(\.index))]
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let preparedRequest = request
        let indices = scenes.map(\.index)
        let trace = PerformanceTrace.current
        let produce: @Sendable () async throws -> String = {
            let started = ProcessInfo.processInfo.systemUptime
            var recorded = false
            do {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = timeout
                configuration.timeoutIntervalForResource = timeout + 600
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let (bytes, response) = try await session.bytes(for: preparedRequest)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw NSError(domain: "OllamaHTTP", code: (response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                var stream = OllamaVisionStream(expectedModel: model)
                var receivedText = false
                for try await line in bytes.lines where !line.isEmpty {
                    try Task.checkCancellation()
                    try stream.append(line)
                    if !receivedText && !stream.content.isEmpty {
                        receivedText = true
                        trace?.event("vlm.first-token", fields: ["model": model],
                                     values: ["seconds": ProcessInfo.processInfo.systemUptime - started])
                    }
                    if stream.finished { break }
                }
                let content = try stream.completedContent()
                _ = try Self.parseBatch(content, indices: indices)
                await metrics?.recordVLMCall(latency: ProcessInfo.processInfo.systemUptime - started)
                recorded = true
                trace?.event("vlm.runtime", fields: ["model": model], values: stream.measurements)
                return content
            } catch {
                if !recorded { await metrics?.recordVLMCall(latency: ProcessInfo.processInfo.systemUptime - started) }
                let failure = error as NSError
                trace?.event("vlm.failed", fields: ["error": String(describing: type(of: error)),
                    "domain": failure.domain, "code": String(failure.code), "message": failure.localizedDescription,
                    "model": model], values: ["seconds": ProcessInfo.processInfo.systemUptime - started])
                throw error
            }
        }
        if let cache, let cacheContext,
           let digest = await LocalAIModelManager.shared.installedModelDigest(model: model) {
            let windows = scenes.map { scene in
                "\(scene.index):\(scene.sourceWindow?.lowerBound.bitPattern ?? 0):\(scene.sourceWindow?.upperBound.bitPattern ?? 0):" + scene.frames.map {
                    "\($0.timestamp.bitPattern)/\($0.actualTimestamp?.bitPattern ?? 0)"
                }.joined(separator: ",")
            }.joined(separator: "|")
            var input = Data("vision-v1|\(digest)|\(cacheContext)|\(windows)|".utf8)
            input.append(preparedRequest.httpBody ?? Data())
            let identity = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
            let response = try await cache.visionResponse(identity: identity, indices: indices, produce: produce)
            if response.reused { await metrics?.recordVLMCacheHit() }
            trace?.event("vlm.evaluated", fields: ["inputSHA256": identity, "modelDigest": digest,
                "origin": response.reused ? "reused" : "computed", "indices": indices.map(String.init).joined(separator: ",")])
            return try Self.parseBatch(response.content, indices: indices)
        }
        // Independent rechecks deliberately omit the cache, even with equal inputs.
        return try Self.parseBatch(try await produce(), indices: indices)
    }
}

public struct AdaptiveLocalAnalyzer: Sendable {
    public let schemaVersion: Int
    public let profile: AIAnalysisProfile

    public init(schemaVersion: Int = 1, profile: AIAnalysisProfile) {
        self.schemaVersion = schemaVersion
        self.profile = profile
    }

    public func analyze(
        asset: MediaAsset,
        analysisURL: URL,
        usedProxy: Bool,
        telemetry: TelemetrySummary? = nil,
        previous: AnalysisResult? = nil,
        frameCache: FrameCache? = nil,
        deepCache: DeepAnalysisCache? = nil,
        metrics: AnalysisMetricsRecorder? = nil,
        progress: (@Sendable (String, Double) -> Void)? = nil,
        detailedProgress: (@Sendable (AnalysisStageUpdate) -> Void)? = nil
    ) async throws -> AnalysisResult {
        await metrics?.start(.fastInspection)
        // Rebuild local scores; a retry must not blend a previous VLM answer twice.
        var baseline = try await LocalHeuristicAnalyzer(schemaVersion: schemaVersion).analyze(asset: asset)
        baseline.aiExecution = AIExecutionEvidence(visualAnalysisCompleted: false)
        baseline.completedDepth = .metadata
        await metrics?.finish(.fastInspection)
        baseline.analysisProfileKey = profile.cacheKey
        baseline.analyzedSourceIdentity = FrameCacheKey.sourceIdentity(url: asset.originalURL, contentHash: asset.contentHash)
        baseline.usedProxy = usedProxy
        baseline.telemetry = telemetry
        if asset.kind == .photo {
            let cacheRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("VeloEdit-FrameCache/\(asset.contentHash)", isDirectory: true)
            let effectiveFrameCache = frameCache ?? FrameCache(rootURL: cacheRoot)
            do {
                let sampling = try await AdaptiveFrameSampler().samplePhoto(
                    url: analysisURL,
                    sourceHash: asset.contentHash,
                    maximumSize: profile.proxyLongEdge,
                    frameCache: effectiveFrameCache
                )
                let deepMedia = await DeepMediaCandidateEnricher().enrich(
                    candidates: baseline.candidates,
                    samples: sampling.samples,
                    asset: asset,
                    profile: profile,
                    audio: nil,
                    cache: deepCache
                )
                baseline.candidates = deepMedia.candidates
                baseline.sceneTags.formUnion(deepMedia.candidates.flatMap(\.tags))
                baseline.deepMediaDiagnostics = deepMedia.diagnostics
                baseline.sampledFrameCount = sampling.samples.count
                await metrics?.recordFrames(total: 1, decoded: sampling.decodedFrameCount, analyzed: 1, cacheHits: sampling.cacheHitCount)
                await metrics?.recordVisionCalls(sampling.visionCallCount)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                baseline.warnings.append("Deep-анализ фото недоступен: \(error.localizedDescription)")
                baseline.deepMediaDiagnostics = DeepMediaDiagnostics(stages: [
                    DeepAnalysisStageReport(stage: .embeddings, ran: false, reason: "Photo fallback: \(error.localizedDescription)")
                ])
            }
            baseline.deepMediaVersion = DeepAnalysisCache.version
            baseline.aiRuntimeLabel = "Apple Vision · локально"
            let photoComplete = (baseline.sampledFrameCount ?? 0) > 0
            baseline.aiExecution = AIExecutionEvidence(visualAnalysisCompleted: photoComplete)
            baseline.completedDepth = photoComplete ? profile.targetDepth : .metadata
            progress?(photoComplete ? "Анализ фото готов" : "Фото требует повторного анализа", 1)
            detailedProgress?(AnalysisStageUpdate(stage: .fusion, fraction: 1))
            return baseline
        }
        guard let duration = asset.metadata.duration, duration > 0 else {
            baseline.aiRuntimeLabel = "Метаданные · локальный fallback"
            baseline.completedDepth = .metadata
            baseline.deepMediaVersion = DeepAnalysisCache.version
            progress?("Metadata fallback готов", 1)
            detailedProgress?(AnalysisStageUpdate(stage: .fusion, fraction: 1))
            return baseline
        }

        let telemetryDetector = TelemetryHighlightDetector()
        let telemetryMoments = telemetryDetector.moments(from: telemetry, duration: duration)
        let telemetryPeaks = telemetryDetector.rankedMoments(
            from: telemetry,
            duration: duration,
            limit: max(2, profile.maximumDeepCandidates / 2),
            minimumGap: max(1.5, AdaptiveSamplingPlan(duration: duration, profile: profile).candidateDuration * 0.45)
        )
        if telemetry?.hasTelemetry == true, telemetryMoments.isEmpty {
            baseline.warnings.append("Телеметрия найдена, но поток не содержит синхронизируемых пиков; отбор выполнен по видео.")
        }

        let sampling: FrameSamplingOutcome
        do {
            await metrics?.start(.adaptiveSampling)
            let samplingLabel = usedProxy ? "Разреженная выборка кадров из proxy" : "Быстрая выборка без полного proxy"
            progress?(samplingLabel, 0.05)
            detailedProgress?(AnalysisStageUpdate(stage: .adaptiveSampling, label: samplingLabel, fraction: 0.05))
            let cacheRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("VeloEdit-FrameCache/\(asset.contentHash)", isDirectory: true)
            let effectiveFrameCache = frameCache ?? FrameCache(rootURL: cacheRoot)
            let previousCenters = previous?.candidates.map { $0.sourceStart + $0.sourceDuration / 2 } ?? []
            sampling = try await AdaptiveFrameSampler().sample(
                url: analysisURL,
                sourceHash: asset.contentHash,
                duration: duration,
                profile: profile,
                frameCache: effectiveFrameCache,
                priorityTimestamps: telemetryPeaks.map(\.timestamp) + previousCenters
            )
            await metrics?.finish(.adaptiveSampling, workUnits: sampling.samples.count)
            await metrics?.recordFrames(
                total: sampling.samples.count,
                decoded: sampling.decodedFrameCount,
                analyzed: sampling.samples.count,
                cacheHits: sampling.cacheHitCount
            )
            await metrics?.recordVisionCalls(sampling.visionCallCount)
            await metrics?.start(.sceneSegmentation)
            await metrics?.finish(.sceneSegmentation, workUnits: sampling.scenes.count)
            progress?("Сопоставляю кадры, сцены и пики телеметрии", 0.38)
            detailedProgress?(AnalysisStageUpdate(
                stage: .sceneSegmentation,
                label: "Найдено сцен: \(sampling.scenes.count)",
                fraction: 0.38,
                currentScene: sampling.scenes.isEmpty ? nil : 1,
                sceneCount: sampling.scenes.count
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await metrics?.finish(.adaptiveSampling)
            baseline.warnings.append("Адаптивная выборка кадров недоступна: \(error.localizedDescription)")
            baseline.aiRuntimeLabel = "Метаданные · локальный fallback"
            progress?("Сохранён metadata fallback", 1)
            detailedProgress?(AnalysisStageUpdate(stage: .fusion, label: "Сохранён metadata fallback", fraction: 1))
            return baseline
        }

        let samples = sampling.samples
        baseline.sampledFrameCount = samples.count
        var audioSummary: AudioAnalysisSummary?
        if profile.audioAnalysisLevel != .none, asset.metadata.hasAudio {
            await metrics?.start(.audio)
            detailedProgress?(AnalysisStageUpdate(stage: .audio, fraction: 0.41))
            let stored = await deepCache?.load(contentHash: asset.contentHash)
            let sourceIdentity = FrameCacheKey.sourceIdentity(url: asset.originalURL, contentHash: asset.contentHash)
            let persistentAudio = stored?.sourceIdentity == sourceIdentity ? stored?.audioAnalysis : nil
            let previousAudio = previous?.analyzedContentHash == asset.contentHash && previous?.analyzedSourceIdentity == sourceIdentity
                ? previous?.audioAnalysis : nil
            let cachedAudio = persistentAudio ?? previousAudio
            let cacheSupportsRequestedDepth = cachedAudio.map { value in
                profile.audioAnalysisLevel == .basic || (value.featureWindows != nil && value.onsetEnvelope != nil)
            } ?? false
            if cacheSupportsRequestedDepth {
                audioSummary = cachedAudio
            } else {
                do {
                    audioSummary = try await LocalAudioAnalyzer().analyze(url: asset.originalURL, level: profile.audioAnalysisLevel)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    baseline.warnings.append("Анализ звука недоступен: \(error.localizedDescription)")
                }
            }
            await metrics?.finish(.audio)
        }
        await metrics?.start(.localScoring)
        let plan = AdaptiveSamplingPlan(duration: duration, profile: profile)
        let selected = selectPeaks(
            samples,
            scenes: sampling.scenes,
            telemetryMoments: telemetryMoments,
            candidateDuration: plan.candidateDuration,
            limit: profile.maximumDeepCandidates,
            minimumGap: max(2, plan.candidateDuration * 0.55)
        )
        let boundarySignals = samples.map { sample in
            let nearbyTelemetry = telemetryDetector.strongestMoment(
                in: max(0, sample.timestamp - 0.75)...min(duration, sample.timestamp + 0.75),
                moments: telemetryMoments
            )?.score ?? 0
            let audioOnset = Self.audioOnset(at: sample.timestamp, duration: duration, summary: audioSummary)
            return MomentSignal(
                timestamp: sample.timestamp,
                motion: sample.motion,
                interest: sample.interest,
                semantic: sample.semanticPotential,
                audioOnset: audioOnset,
                telemetry: nearbyTelemetry
            )
        }
        let boundaryRefiner = MomentBoundaryRefiner()
        var candidates = selected.map { sample -> Candidate in
            // Calm, attractive scenes are allowed to breathe; intense action
            // gets a shorter window. This deliberately avoids the old fixed
            // five-second assumption while staying within the source.
            let nominalDuration = min(duration, min(14, max(1.2,
                plan.candidateDuration * (1.32 - sample.motion * 0.58 + sample.semanticPotential * 0.22)
            )))
            let boundary = boundaryRefiner.refine(
                around: sample.timestamp,
                signals: boundarySignals,
                sourceDuration: duration,
                nominalDuration: nominalDuration
            )
            let candidateDuration = boundary.duration
            let start = boundary.anticipationStart
            let moment = telemetryDetector.strongestMoment(in: start...(start + candidateDuration), moments: telemetryMoments)
                .flatMap { $0.score >= 0.08 ? $0 : nil }
            let telemetryScore = moment?.score ?? 0
            var tags = baseline.sceneTags.union(sample.labels)
            if sample.motion > 0.62 { tags.insert("action") }
            if sample.motion < 0.22 { tags.insert("atmosphere") }
            if sample.faceCount > 0 { tags.insert("people") }
            tags.formUnion(moment?.tags ?? [])
            let scores = ClipScores(
                quality: sample.technicalQuality,
                interest: min(1, sample.interest * 0.88 + telemetryScore * 0.38),
                action: min(1, max(sample.motion, sample.motion * 0.70 + telemetryScore * 0.55)),
                stability: min(1, 0.50 * sample.detail + 0.35 * sample.exposure + 0.15 * (1 - sample.motion))
            )
            var explanation = ["Видео: динамика \(Int(sample.motion * 100))%, детали \(Int(sample.detail * 100))%, сцена \(Int(sample.semanticPotential * 100))%"]
            explanation.append(contentsOf: boundary.evidence)
            if let moment { explanation.append("Телеметрия: \(moment.explanation)") }
            let highFrameRate = (asset.metadata.frameRate ?? 30) >= 50 ? 1.0 : 0.28
            let audioBase = asset.metadata.hasAudio == true
                ? max(
                    tags.contains("people") || tags.contains("action") ? 0.72 : 0.38,
                    (audioSummary?.originalSoundQuality ?? 0) * (1 - (audioSummary?.silenceRatio ?? 1))
                )
                : 0
            let insights = CandidateInsights(
                sceneSummary: sample.labels.sorted().prefix(4).joined(separator: ", "),
                dynamics: sample.motion,
                visualAppeal: min(1, sample.semanticPotential * 0.55 + sample.technicalQuality * 0.45),
                composition: sample.semanticPotential,
                sharpness: sample.detail,
                motionBlur: max(0, sample.motion - sample.detail * 0.58),
                noise: max(0, (1 - sample.detail) * (1 - sample.exposure) * 0.72),
                shake: max(0, 1 - scores.stability),
                exposureQuality: sample.exposure,
                slowMotionSuitability: min(1, highFrameRate * 0.46 + scores.action * 0.30 + scores.stability * 0.24),
                speedRampSuitability: min(1, scores.action * 0.58 + scores.interest * 0.24 + scores.stability * 0.18),
                originalAudioUsefulness: audioBase,
                storyValue: min(1, scores.interest * 0.46 + scores.quality * 0.24 + scores.uniqueness * 0.18 + telemetryScore * 0.22),
                roleScores: [
                    .intro: min(1, sample.semanticPotential * 0.44 + sample.exposure * 0.28 + scores.stability * 0.28),
                    .setup: min(1, (sample.faceCount > 0 ? 0.28 : 0) + sample.semanticPotential * 0.42 + scores.quality * 0.30),
                    .buildup: min(1, scores.interest * 0.46 + scores.action * 0.30 + scores.quality * 0.24),
                    .climax: min(1, scores.action * 0.48 + scores.interest * 0.30 + telemetryScore * 0.32),
                    .reaction: min(1, (sample.faceCount > 0 ? 0.26 : 0) + scores.interest * 0.30 + (1 - sample.motion) * 0.24 + audioBase * 0.20),
                    .outro: min(1, (1 - sample.motion) * 0.34 + sample.semanticPotential * 0.36 + scores.quality * 0.30)
                ]
            )
            return Candidate(assetID: asset.id, sourceStart: start, sourceDuration: candidateDuration, scores: scores, tags: tags, explanation: explanation, insights: insights, momentBoundary: boundary)
        }
        if candidates.isEmpty { candidates = baseline.candidates }
        await metrics?.finish(.localScoring, workUnits: candidates.count)

        let runtime = OllamaVisionRuntime()
        // ResourceWorkPacer waits for cooling; it never drops scheduled VLM work.
        let availability = await LocalAIModelManager.shared.availability(model: profile.ollamaModelID)
        let modelInfo = availability.installed
            ? await LocalAIModelManager.shared.installedModelInfo(model: profile.ollamaModelID) : nil
        let hasVisionModel = modelInfo != nil
        baseline.analysisModelDigest = modelInfo?.digest
        let selectedIndices = selectedVLMIndices(in: candidates)
        var execution = AIExecutionEvidence(
            visualAnalysisCompleted: !samples.isEmpty,
            audioAnalysisCompleted: profile.audioAnalysisLevel == .none || !asset.metadata.hasAudio || audioSummary != nil,
            plannedScenes: selectedIndices.count,
            plannedRechecks: profile.rechecksImportantScenes ? min(2, selectedIndices.count) : 0,
            modelAvailable: hasVisionModel, modelQuantization: modelInfo?.quantization)
        var deepIndices: Set<Int> = []
        var deepFailures = 0
        if hasVisionModel {
            var resourcePacer = ResourceWorkPacer()
            try await resourcePacer.checkpoint()
            await metrics?.start(.vlm)
            let batches = stride(from: 0, to: selectedIndices.count, by: profile.scenesPerVLMRequest).map {
                Array(selectedIndices[$0..<min(selectedIndices.count, $0 + profile.scenesPerVLMRequest)])
            }
            for (batchNumber, indices) in batches.enumerated() {
                try await resourcePacer.checkpoint()
                let scenePosition = min(selectedIndices.count, batchNumber * profile.scenesPerVLMRequest + 1)
                let fraction = 0.44 + 0.48 * Double(batchNumber) / Double(max(1, batches.count))
                let label = "Qwen3-VL: пакет сцен \(batchNumber + 1) из \(batches.count)"
                progress?(label, fraction)
                detailedProgress?(AnalysisStageUpdate(
                    stage: .vlm,
                    label: label,
                    fraction: fraction,
                    currentScene: scenePosition,
                    sceneCount: selectedIndices.count
                ))
                let inputs = indices.map { index in
                    VLMSceneInput(
                        index: index,
                        frames: nearbyFrames(for: candidates[index], in: samples),
                        telemetry: telemetryDetector.strongestMoment(
                            in: candidates[index].sourceStart...(candidates[index].sourceStart + candidates[index].sourceDuration),
                            moments: telemetryMoments
                        ).flatMap { $0.score >= 0.08 ? $0 : nil },
                        sourceWindow: candidates[index].sourceStart...(candidates[index].sourceStart + candidates[index].sourceDuration)
                    )
                }
                do {
                    let judgements = try await runtime.analyzeBatch(
                        scenes: inputs,
                        model: profile.ollamaModelID,
                        thinking: profile.thinkingEnabled,
                        timeout: profile.vlmPrefillTimeout(imageCount: inputs.reduce(0) { $0 + $1.frames.count }),
                        cache: deepCache,
                        cacheContext: profile.cacheKey + "|" + FrameCacheKey.sourceIdentity(url: asset.originalURL, contentHash: asset.contentHash),
                        metrics: metrics
                    )
                    for index in indices {
                        guard let judgement = judgements[index] else {
                            deepFailures += 1
                            continue
                        }
                        apply(judgement, to: &candidates[index])
                        deepIndices.insert(index)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    deepFailures += indices.count
                }
            }

            if profile.rechecksImportantScenes {
                // Always independently verify the strongest/ambiguous planned
                // moments, even when none passes the former arbitrary threshold.
                let recheck = selectedIndices.sorted {
                    abs(candidates[$0].scores.composite - 0.72) < abs(candidates[$1].scores.composite - 0.72)
                }.prefix(execution.plannedRechecks)
                for index in recheck {
                    try await resourcePacer.checkpoint()
                    let inputs = [VLMSceneInput(index: index, frames: nearbyFrames(for: candidates[index], in: samples), telemetry: nil)]
                    do {
                        let judgements = try await runtime.analyzeBatch(
                            scenes: inputs, model: profile.ollamaModelID, thinking: profile.thinkingEnabled,
                            timeout: profile.vlmPrefillTimeout(imageCount: inputs[0].frames.count), metrics: metrics)
                        if let judgement = judgements[index] {
                            apply(judgement, to: &candidates[index])
                            execution.evaluatedRechecks += 1
                            PerformanceTrace.current?.event("vlm.recheck-completed", fields: ["index": String(index)])
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                        baseline.warnings.append("Независимая перепроверка сцены не завершена: \(error.localizedDescription)")
                    }
                }
            }
            await metrics?.finish(.vlm, workUnits: deepIndices.count)
            if deepFailures > 0 {
                baseline.warnings.append("Qwen3-VL не смогла оценить \(deepFailures) сцен; для них сохранена совместная локальная оценка.")
            }
            baseline.aiRuntimeLabel = deepIndices.isEmpty
                ? "Apple Vision + video/telemetry · локальный fallback"
                : "Qwen3-VL batch + video/telemetry · Ollama · локально"
        } else {
            let reason = "Модель \(profile.ollamaModelID) не установлена; нейроанализ не завершён. Сохранён локальный анализ кадров."
            baseline.warnings.append(reason)
            baseline.aiRuntimeLabel = telemetryMoments.isEmpty
                ? "Apple Vision + adaptive sampling · локально"
                : "Apple Vision + video/GPMF · локально"
        }
        detailedProgress?(AnalysisStageUpdate(stage: .embeddings, label: "Локальные признаки, объекты, звук и речь", fraction: 0.94))
        let deepMedia = await DeepMediaCandidateEnricher().enrich(
            candidates: candidates,
            samples: samples,
            asset: asset,
            profile: profile,
            audio: audioSummary,
            telemetryMoments: telemetryMoments,
            cache: deepCache
        )
        candidates = deepMedia.candidates
        if audioSummary != nil { audioSummary?.events = deepMedia.audioEvents }
        baseline.deepMediaVersion = DeepAnalysisCache.version
        baseline.deepMediaDiagnostics = deepMedia.diagnostics
        if let speech = deepMedia.diagnostics.stages.first(where: { $0.stage == .asr }),
           !speech.ran, speech.reason.contains("недоступен") {
            baseline.warnings.append(speech.reason)
        }
        await metrics?.start(.fusion)
        baseline.deepAnalyzedCandidateCount = deepIndices.count
        baseline.candidates = candidates
        baseline.sceneTags.formUnion(candidates.flatMap(\.tags))
        baseline.audioAnalysis = audioSummary
        baseline.scenes = makeSceneAnalyses(
            detected: sampling.scenes,
            samples: samples,
            candidates: candidates,
            telemetryMoments: telemetryMoments,
            audio: audioSummary
        )
        try Task.checkCancellation()
        execution.evaluatedScenes = deepIndices.count
        baseline.aiExecution = execution
        baseline.completedDepth = execution.isComplete ? profile.targetDepth : min(profile.targetDepth, .quick)
        if !execution.isComplete { baseline.warnings.append(execution.summary) }
        await metrics?.finish(.fusion, workUnits: baseline.scenes?.count ?? 0)
        progress?("Передаю лучшие моменты Story Engine", 1)
        detailedProgress?(AnalysisStageUpdate(stage: .fusion, label: execution.isComplete
            ? "Анализ готов для AI Director" : "Частичный анализ: \(execution.summary)", fraction: 1))
        return baseline
    }

    private static func audioOnset(at timestamp: Double, duration: Double, summary: AudioAnalysisSummary?) -> Double {
        guard let waveform = summary?.waveform, waveform.count > 1, duration > 0 else { return 0 }
        let position = min(1, max(0, timestamp / duration))
        let index = min(waveform.count - 1, max(1, Int((position * Double(waveform.count - 1)).rounded())))
        let rise = waveform[index] - waveform[index - 1]
        return min(1, max(0, rise * 2.4 + waveform[index] * 0.18))
    }

    private func selectPeaks(
        _ samples: [VisualFrameSample],
        scenes: [DetectedScene],
        telemetryMoments: [TelemetryMoment],
        candidateDuration: Double,
        limit: Int,
        minimumGap: Double
    ) -> [VisualFrameSample] {
        guard limit > 0 else { return [] }
        var selected: [VisualFrameSample] = []
        func append(_ sample: VisualFrameSample) -> Bool {
            guard selected.count < limit,
                  selected.allSatisfy({ abs($0.timestamp - sample.timestamp) >= minimumGap }) else { return false }
            selected.append(sample)
            return true
        }

        let rankedScenes = scenes.sorted {
            ($0.motionScore + $0.boundaryConfidence) > ($1.motionScore + $1.boundaryConfidence)
        }
        for scene in rankedScenes.prefix(max(1, limit / 2)) {
            if let representative = samples.min(by: {
                abs($0.timestamp - scene.representativeTimestamp) < abs($1.timestamp - scene.representativeTimestamp)
            }) {
                _ = append(representative)
            }
        }

        var telemetryAdded = 0
        let telemetryQuota = min(limit, max(1, limit / 3))
        for moment in telemetryMoments.sorted(by: { $0.score > $1.score }) where moment.score >= 0.12 && telemetryAdded < telemetryQuota {
            if let nearest = samples.min(by: { abs($0.timestamp - moment.timestamp) < abs($1.timestamp - moment.timestamp) }),
               append(nearest) {
                telemetryAdded += 1
            }
        }
        var semanticAdded = 0
        let semanticQuota = max(1, limit / 4)
        for sample in samples.sorted(by: { $0.semanticPotential > $1.semanticPotential }) where semanticAdded < semanticQuota {
            if append(sample) { semanticAdded += 1 }
        }
        for sample in samples.sorted(by: { $0.interest > $1.interest }) where selected.count < max(1, limit * 3 / 4) {
            _ = append(sample)
        }
        let detector = TelemetryHighlightDetector()
        let combined = samples.sorted { lhs, rhs in
            func score(_ sample: VisualFrameSample) -> Double {
                let range = (sample.timestamp - candidateDuration / 2)...(sample.timestamp + candidateDuration / 2)
                let telemetry = detector.strongestMoment(in: range, moments: telemetryMoments)?.score ?? 0
                return sample.interest * 0.72 + sample.semanticPotential * 0.18 + telemetry * 0.40
            }
            return score(lhs) > score(rhs)
        }
        for sample in combined where selected.count < limit { _ = append(sample) }
        return selected.sorted { $0.timestamp < $1.timestamp }
    }

    func selectedVLMIndices(in candidates: [Candidate]) -> [Int] {
        let ranked = candidates.indices.sorted { lhs, rhs in
            let left = candidates[lhs]
            let right = candidates[rhs]
            let leftStory = left.insights?.storyValue ?? left.scores.interest
            let rightStory = right.insights?.storyValue ?? right.scores.interest
            return leftStory + left.scores.composite > rightStory + right.scores.composite
        }
        let selected: [Int]
        switch profile.vlmCandidatePolicy {
        case .ambiguityOnly:
            selected = ranked.filter { index in
                let score = candidates[index].scores.composite
                let semantic = candidates[index].insights?.storyValue ?? 0.5
                return (score > 0.48 && score < 0.82) || semantic > 0.76
            }
        case .keyScenes:
            selected = ranked.filter { index in
                let candidate = candidates[index]
                return candidate.scores.interest >= 0.48 || candidate.tags.contains("action") || candidate.tags.contains("people")
            }
        case .broadScenes, .temporalRecheck:
            selected = ranked
        }
        // Keep the preferred semantic ordering, then fill the mode's budget
        // with representative scenes. Calm scenery must still reach the VLM.
        let remaining = ranked.filter { !selected.contains($0) }
        return Array((selected + remaining).prefix(profile.maximumVLMScenes))
    }

    func nearbyFrames(for candidate: Candidate, in samples: [VisualFrameSample]) -> [VisualFrameSample] {
        let center = candidate.sourceStart + candidate.sourceDuration / 2
        let maximumPerScene = profile.framesPerCandidate
        return Array(samples.sorted { abs($0.timestamp - center) < abs($1.timestamp - center) }
            .prefix(maximumPerScene))
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func apply(_ judgement: DeepFrameJudgement, to candidate: inout Candidate) {
        candidate.scores = blend(candidate.scores, judgement)
        candidate.tags.formUnion(judgement.tags ?? [])
        candidate.insights = blend(candidate.insights, judgement)
        if let reason = judgement.reason, !reason.isEmpty, !candidate.explanation.contains(reason) {
            candidate.explanation.append(reason)
        }
    }

    private func makeSceneAnalyses(
        detected: [DetectedScene],
        samples: [VisualFrameSample],
        candidates: [Candidate],
        telemetryMoments: [TelemetryMoment],
        audio: AudioAnalysisSummary?
    ) -> [SceneAnalysis] {
        let telemetryDetector = TelemetryHighlightDetector()
        return detected.map { scene in
            let sceneSamples = samples.filter { $0.timestamp >= scene.startTime && $0.timestamp < scene.endTime }
            let candidate = candidates.max { lhs, rhs in
                Self.overlap(of: lhs, with: scene) < Self.overlap(of: rhs, with: scene)
            }.flatMap { Self.overlap(of: $0, with: scene) > 0 ? $0 : nil }
            let labels = Set(sceneSamples.flatMap(\.labels)).union(candidate?.tags ?? [])
            let people = labels.filter { $0.contains("person") || $0.contains("people") || $0.contains("face") }.sorted()
            let technical: Set<String> = ["horizontal", "vertical", "4k", "action", "atmosphere"]
            let objects = labels.subtracting(technical).subtracting(people).sorted().prefix(10)
            let averageQuality = sceneSamples.isEmpty
                ? candidate?.scores.quality ?? 0.5
                : sceneSamples.map(\.technicalQuality).reduce(0, +) / Double(sceneSamples.count)
            let averageSharpness = sceneSamples.isEmpty
                ? candidate?.insights?.sharpness ?? 0.5
                : sceneSamples.map(\.detail).reduce(0, +) / Double(sceneSamples.count)
            let averageStability = candidate?.scores.stability ?? max(0, 1 - scene.motionScore)
            let moment = telemetryDetector.strongestMoment(
                in: scene.startTime...scene.endTime,
                moments: telemetryMoments
            ).flatMap { $0.score >= 0.08 ? $0 : nil }
            let highlights = candidate?.explanation ?? []
            var uses: [String] = []
            if (candidate?.insights?.roleScores[.intro] ?? 0) >= 0.65 { uses.append("intro") }
            if (candidate?.insights?.roleScores[.climax] ?? 0) >= 0.65 { uses.append("climax") }
            if (candidate?.insights?.roleScores[.outro] ?? 0) >= 0.65 { uses.append("outro") }
            if uses.isEmpty { uses.append(scene.motionScore > 0.55 ? "action" : "b-roll") }
            return SceneAnalysis(
                startTime: scene.startTime,
                endTime: scene.endTime,
                semanticDescription: candidate?.insights?.sceneSummary ?? objects.prefix(4).joined(separator: ", "),
                qualityScore: averageQuality,
                motionScore: scene.motionScore,
                actionScore: candidate?.scores.action ?? scene.motionScore,
                beautyScore: candidate?.insights?.visualAppeal ?? averageQuality,
                stabilityScore: averageStability,
                sharpnessScore: averageSharpness,
                audioScore: audio?.originalSoundQuality ?? candidate?.insights?.originalAudioUsefulness ?? 0,
                people: people,
                objects: Array(objects),
                telemetry: moment,
                highlights: highlights,
                recommendedUses: uses,
                boundaryConfidence: scene.boundaryConfidence
            )
        }
    }

    private static func overlap(of candidate: Candidate, with scene: DetectedScene) -> Double {
        max(0, min(candidate.sourceStart + candidate.sourceDuration, scene.endTime) - max(candidate.sourceStart, scene.startTime))
    }

    private func blend(_ base: ClipScores, _ deep: DeepFrameJudgement) -> ClipScores {
        func value(_ local: Double, _ remote: Double?) -> Double { min(1, max(0, local * 0.42 + (remote ?? local) * 0.58)) }
        return ClipScores(
            quality: value(base.quality, deep.quality),
            interest: value(base.interest, deep.interest),
            action: value(base.action, deep.action),
            stability: value(base.stability, deep.stability),
            uniqueness: base.uniqueness
        )
    }

    private func blend(_ base: CandidateInsights?, _ deep: DeepFrameJudgement) -> CandidateInsights {
        let local = base ?? CandidateInsights()
        func value(_ measured: Double, _ inferred: Double?) -> Double {
            min(1, max(0, measured * 0.45 + (inferred ?? measured) * 0.55))
        }
        var roles = local.roleScores
        roles[.intro] = value(roles[.intro] ?? 0.5, deep.intro)
        roles[.setup] = value(roles[.setup] ?? 0.5, deep.setup)
        roles[.buildup] = value(roles[.buildup] ?? 0.5, deep.buildup)
        roles[.climax] = value(roles[.climax] ?? 0.5, deep.climax)
        roles[.reaction] = value(roles[.reaction] ?? 0.5, max(deep.outro ?? 0.5, deep.emotion?.isEmpty == false ? 0.72 : 0.42))
        roles[.outro] = value(roles[.outro] ?? 0.5, deep.outro)
        return CandidateInsights(
            sceneSummary: deep.scene ?? local.sceneSummary,
            emotion: deep.emotion ?? local.emotion,
            dynamics: value(local.dynamics, deep.action),
            visualAppeal: value(local.visualAppeal, deep.visualAppeal),
            composition: value(local.composition, deep.composition),
            sharpness: value(local.sharpness, deep.sharpness),
            motionBlur: value(local.motionBlur, deep.motionBlur),
            noise: value(local.noise, deep.noise),
            shake: value(local.shake, deep.shake),
            exposureQuality: value(local.exposureQuality, deep.exposureQuality),
            slowMotionSuitability: value(local.slowMotionSuitability, deep.slowMotionSuitability),
            speedRampSuitability: value(local.speedRampSuitability, deep.speedRampSuitability),
            originalAudioUsefulness: value(local.originalAudioUsefulness, deep.originalAudioUsefulness),
            storyValue: value(local.storyValue, deep.storyValue),
            roleScores: roles
        )
    }
}
