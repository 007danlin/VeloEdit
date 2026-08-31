import Foundation
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
    let timestamp: Double
    let motion: Double
    let exposure: Double
    let detail: Double
    let labels: Set<String>
    let labelConfidence: Double
    let faceCount: Int
    let jpegBase64: String
    let histogram: [Double]
    let luminanceFingerprint: [UInt8]
    let subjects: [FrameSubjectObservation]?

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
    func samplePhoto(
        url: URL,
        sourceHash: String,
        maximumSize: Int,
        frameCache: FrameCache
    ) async throws -> FrameSamplingOutcome {
        let key = FrameCacheKey(sourceFile: sourceHash, timestamp: 0, resolution: maximumSize, processingPurpose: .adaptiveSampling)
        if let cached = await frameCache.value(for: key) {
            return FrameSamplingOutcome(samples: [cached], scenes: [], decodedFrameCount: 0, cacheHitCount: 1, visionCallCount: 0)
        }
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
        let sample = VisualFrameSample(
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
        try? await frameCache.store(sample, for: key)
        return FrameSamplingOutcome(samples: [sample], scenes: [], decodedFrameCount: 1, cacheHitCount: 0, visionCallCount: 1)
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
        var previousFingerprint: [UInt8]?
        var previousTimestamp: Double?
        var result: [VisualFrameSample] = []
        var decoded = 0
        var cacheHits = 0
        var visionCalls = 0
        result.reserveCapacity(timestamps.count)
        for timestamp in timestamps {
            if Task.isCancelled { throw CancellationError() }
            let key = FrameCacheKey(sourceFile: sourceHash, timestamp: timestamp, resolution: maximumSize, processingPurpose: purpose)
            if let cached = await frameCache.value(for: key) {
                result.append(cached)
                cacheHits += 1
                previousFingerprint = cached.luminanceFingerprint
                previousTimestamp = timestamp
                continue
            }
            let image = try generator.copyCGImage(at: CMTime(seconds: timestamp, preferredTimescale: 600), actualTime: nil)
            decoded += 1
            let fingerprint = Self.fingerprint(image)
            let rawMotion = previousFingerprint.map { Self.motion(between: $0, and: fingerprint) } ?? 0
            let deltaTime = previousTimestamp.map { max(0.001, timestamp - $0) } ?? 1
            // A large difference between sparse frames is not necessarily
            // motion; discount long gaps while preserving dense action peaks.
            let motion = min(1, rawMotion * min(1, max(0.15, 1 / deltaTime)))
            previousFingerprint = fingerprint
            previousTimestamp = timestamp
            let mean = fingerprint.isEmpty ? 128 : Double(fingerprint.reduce(0) { $0 + Int($1) }) / Double(fingerprint.count)
            let exposure = max(0, 1 - abs(mean - 128) / 128)
            let detail = Self.detail(fingerprint, width: 32)
            let vision = Self.visionFeatures(for: image)
            visionCalls += 1
            let sample = VisualFrameSample(
                timestamp: timestamp,
                motion: motion,
                exposure: exposure,
                detail: detail,
                labels: vision.labels,
                labelConfidence: vision.confidence,
                faceCount: vision.faceCount,
                jpegBase64: Self.jpegBase64(image),
                histogram: Self.histogram(fingerprint),
                luminanceFingerprint: fingerprint,
                subjects: vision.subjects
            )
            result.append(sample)
            try? await frameCache.store(sample, for: key)
        }
        return (result, decoded, cacheHits, visionCalls)
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

private struct OllamaVisionRequest: Encodable {
    let model: String
    let messages: [OllamaVisionMessage]
    let stream = false
    let think: Bool
    let format = "json"
    let keepAlive = "10m"

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, think, format
        case keepAlive = "keep_alive"
    }
}

private struct OllamaVisionResponse: Decodable { let message: OllamaVisionMessage }
private struct OllamaModelTags: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}

private struct DeepFrameJudgement: Decodable {
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
}

actor OllamaVisionRuntime {
    private let baseURL = URL(string: "http://127.0.0.1:11434")!

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
        timeout: TimeInterval
    ) async throws -> [Int: DeepFrameJudgement] {
        let images = scenes.flatMap { $0.frames.map(\.jpegBase64).filter { !$0.isEmpty } }
        guard !images.isEmpty else { throw URLError(.cannotDecodeContentData) }
        let grouping = scenes.map { scene in
            let telemetry = scene.telemetry.map { "\($0.explanation), \(Int($0.score * 100))%" } ?? "нет"
            return "scene index=\(scene.index): frames=\(scene.frames.count), telemetry=\(telemetry)"
        }.joined(separator: "\n")
        let prompt = """
        Оцени несколько коротких сцен видео. Изображения приложены последовательно группами в указанном порядке:
        \(grouping)
        Верни только JSON вида:
        {"scenes":[{"index":0,"interest":0.0,"action":0.0,"quality":0.0,"stability":0.0,"tags":["..."],"reason":"...","scene":"...","emotion":"...","visualAppeal":0.0,"composition":0.0,"sharpness":0.0,"motionBlur":0.0,"noise":0.0,"shake":0.0,"exposureQuality":0.0,"slowMotionSuitability":0.0,"speedRampSuitability":0.0,"originalAudioUsefulness":0.0,"storyValue":0.0,"intro":0.0,"setup":0.0,"buildup":0.0,"climax":0.0,"outro":0.0}]}.
        Все числовые оценки от 0 до 1. Опиши реальное содержание и действие, эмоцию, людей/транспорт/природу/воду/пейзаж, композицию, резкость, смаз, шум, тряску, экспозицию, визуальную и сюжетную ценность, пригодность для slow motion/speed ramp и роли intro/setup/build-up/climax/outro. originalAudioUsefulness оценивай консервативно по видимой вероятности полезного синхронного звука; если определить нельзя, ставь 0.3. Спокойный значимый момент может быть интереснее хаотичного движения. Постоянная скорость сама по себе не означает хороший момент; резкое ускорение, поворот, перепад или перегрузка являются подтверждением действия. Не выдумывай то, чего не видно.
        """
        let payload = OllamaVisionRequest(model: model, messages: [OllamaVisionMessage(role: "user", content: prompt, images: images)], think: thinking)
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let envelope = try JSONDecoder().decode(OllamaVisionResponse.self, from: data)
        var content = envelope.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("```json") { content.removeFirst(7) }
        else if content.hasPrefix("```") { content.removeFirst(3) }
        if content.hasSuffix("```") { content.removeLast(3) }
        let cleanData = Data(content.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        if let envelope = try? JSONDecoder().decode(DeepSceneEnvelope.self, from: cleanData) {
            return Dictionary(uniqueKeysWithValues: envelope.scenes.compactMap { judgement in
                judgement.index.map { ($0, judgement) }
            })
        }
        if scenes.count == 1, let judgement = try? JSONDecoder().decode(DeepFrameJudgement.self, from: cleanData) {
            return [scenes[0].index: judgement]
        }
        throw URLError(.cannotParseResponse)
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
        var baseline: AnalysisResult
        if let previous,
           previous.assetID == asset.id,
           previous.analyzedContentHash == asset.contentHash,
           previous.schemaVersion == schemaVersion {
            baseline = previous
        } else {
            baseline = try await LocalHeuristicAnalyzer(schemaVersion: schemaVersion).analyze(asset: asset)
        }
        await metrics?.finish(.fastInspection)
        baseline.analysisProfileKey = profile.cacheKey
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
            baseline.completedDepth = profile.targetDepth
            progress?("Быстрый анализ фото готов", 1)
            detailedProgress?(AnalysisStageUpdate(stage: .fusion, fraction: 1))
            return baseline
        }
        guard let duration = asset.metadata.duration, duration > 0 else {
            baseline.aiRuntimeLabel = "Метаданные · локальный fallback"
            baseline.completedDepth = profile.targetDepth
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
            let persistentAudio = await deepCache?.load(contentHash: asset.contentHash)?.audioAnalysis
            let previousAudio = previous?.audioAnalysis
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
        let thermalCritical = ProcessInfo.processInfo.thermalState == .critical
        let ollamaAllowed = profile.maximumVLMScenes > 0 && profile.runtime != .mlx && !thermalCritical
        let hasVisionModel = ollamaAllowed
            ? await LocalAIModelManager.shared.availability(
                model: profile.ollamaModelID
            ).installed
            : false
        var deepIndices: Set<Int> = []
        var deepFailures = 0
        if hasVisionModel {
            await metrics?.start(.vlm)
            try? await LocalAIModelManager.shared.warmUp(model: profile.ollamaModelID)
            let selectedIndices = selectedVLMIndices(in: candidates)
            let batches = stride(from: 0, to: selectedIndices.count, by: profile.scenesPerVLMRequest).map {
                Array(selectedIndices[$0..<min(selectedIndices.count, $0 + profile.scenesPerVLMRequest)])
            }
            for (batchNumber, indices) in batches.enumerated() {
                try Task.checkCancellation()
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
                        ).flatMap { $0.score >= 0.08 ? $0 : nil }
                    )
                }
                let started = Date()
                do {
                    let judgements = try await runtime.analyzeBatch(
                        scenes: inputs,
                        model: profile.ollamaModelID,
                        thinking: profile.thinkingEnabled,
                        timeout: profile.vlmTimeout
                    )
                    await metrics?.recordVLMCall(latency: Date().timeIntervalSince(started))
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
                    await metrics?.recordVLMCall(latency: Date().timeIntervalSince(started))
                    deepFailures += indices.count
                }
            }

            if profile.rechecksImportantScenes {
                let recheck = selectedIndices.filter { index in
                    let confidenceDistance = abs(candidates[index].scores.composite - 0.72)
                    return confidenceDistance < 0.22
                }.prefix(2)
                if !recheck.isEmpty {
                    let inputs = recheck.map { index in
                        VLMSceneInput(index: index, frames: nearbyFrames(for: candidates[index], in: samples), telemetry: nil)
                    }
                    let started = Date()
                    if let judgements = try? await runtime.analyzeBatch(
                        scenes: inputs,
                        model: profile.ollamaModelID,
                        thinking: profile.thinkingEnabled,
                        timeout: profile.vlmTimeout
                    ) {
                        await metrics?.recordVLMCall(latency: Date().timeIntervalSince(started))
                        for index in recheck {
                            guard let judgement = judgements[index] else { continue }
                            apply(judgement, to: &candidates[index])
                        }
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
            let reason = thermalCritical
                ? "Глубокий AI-анализ приостановлен до охлаждения Mac; адаптивный анализ сохранён."
                : profile.runtime == .mlx
                ? "Нативный MLX runtime выбран, но модель ещё не установлена в сборку; использован Apple Vision."
                : "Модель \(profile.ollamaModelID) не загружена; использован адаптивный Apple Vision-анализ."
            baseline.warnings.append(reason)
            baseline.aiRuntimeLabel = telemetryMoments.isEmpty
                ? "Apple Vision + adaptive sampling · локально"
                : "Apple Vision + video/GPMF · локально"
        }
        detailedProgress?(AnalysisStageUpdate(stage: .embeddings, label: "Embeddings, объекты, звук и речь", fraction: 0.94))
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
        baseline.completedDepth = profile.targetDepth
        await metrics?.finish(.fusion, workUnits: baseline.scenes?.count ?? 0)
        progress?("Передаю лучшие моменты Story Engine", 1)
        detailedProgress?(AnalysisStageUpdate(stage: .fusion, label: "Анализ готов для AI Director", fraction: 1))
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

    private func selectedVLMIndices(in candidates: [Candidate]) -> [Int] {
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
        return Array(selected.prefix(profile.maximumVLMScenes))
    }

    private func nearbyFrames(for candidate: Candidate, in samples: [VisualFrameSample]) -> [VisualFrameSample] {
        let center = candidate.sourceStart + candidate.sourceDuration / 2
        let maximumPerScene = max(2, min(profile.framesPerCandidate, max(3, 18 / profile.scenesPerVLMRequest)))
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
