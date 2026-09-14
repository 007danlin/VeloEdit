import Foundation
import AVFoundation
import CoreImage
import ImageIO
import Vision

public protocol VisionModelProtocol: Sendable {
    func analyze(asset: MediaAsset) async throws -> AnalysisResult
}

public protocol EmbeddingModelProtocol: Sendable {
    var modelIdentifier: String { get }
    func embedding(for input: EmbeddingInput) async throws -> VisualEmbedding
}

public protocol AudioModelProtocol: Sendable {
    func classify(url: URL) async throws -> Set<String>
}

public protocol LanguageDirectorProtocol: Sendable {
    func constraints(prompt: String, preset: FilmPreset, base: StoryConstraints) async throws -> StoryConstraints
}

public struct LocalHeuristicAnalyzer: VisionModelProtocol {
    public let schemaVersion: Int
    public init(schemaVersion: Int = 1) { self.schemaVersion = schemaVersion }

    public func analyze(asset: MediaAsset) async throws -> AnalysisResult {
        var tags = Self.tagsFromFilename(asset.displayName)
        if let width = asset.metadata.width, let height = asset.metadata.height {
            tags.insert(width >= height ? "horizontal" : "vertical")
            if width >= 3840 || height >= 2160 { tags.insert("4k") }
        }
        switch asset.kind {
        case .photo:
            tags.insert("photo")
            let metrics = Self.photoMetrics(url: asset.originalURL)
            tags.formUnion(metrics.labels)
            let scores = ClipScores(quality: metrics.quality, interest: metrics.interest, action: 0.08, stability: 1)
            let insights = CandidateInsights(
                sceneSummary: metrics.labels.sorted().prefix(4).joined(separator: ", "),
                dynamics: 0.08,
                visualAppeal: metrics.interest,
                composition: metrics.interest,
                sharpness: metrics.quality,
                exposureQuality: metrics.quality,
                storyValue: metrics.interest,
                roleScores: [.intro: metrics.interest, .setup: 0.62, .reaction: metrics.interest * 0.72, .outro: metrics.interest]
            )
            let candidate = Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: PhotoPresentationPolicy.duration, scores: scores, tags: tags, explanation: Self.explanation(scores: scores, tags: tags), insights: insights)
            return AnalysisResult(assetID: asset.id, schemaVersion: schemaVersion, analyzedContentHash: asset.contentHash, sceneTags: tags, candidates: [candidate])
        case .video:
            let duration = max(0, asset.metadata.duration ?? 0)
            guard duration > 0 else {
                return AnalysisResult(assetID: asset.id, schemaVersion: schemaVersion, analyzedContentHash: asset.contentHash, sceneTags: tags, candidates: [], warnings: ["Не удалось определить длительность видео"])
            }
            let nominalCandidateLength = duration < 12 ? duration : min(10, max(3.5, duration / 30))
            let desiredCount = min(24, max(1, Int(ceil(duration / 45))))
            let spacing = duration / Double(desiredCount)
            var candidates: [Candidate] = []
            for index in 0..<desiredCount {
                let seed = Self.stableUnit("\(asset.contentHash):\(index)")
                let resolutionScore = Self.resolutionScore(width: asset.metadata.width, height: asset.metadata.height)
                let frameRate = asset.metadata.frameRate ?? 30
                let action = min(1, 0.22 + (frameRate >= 50 ? 0.22 : 0) + seed * 0.50)
                let quality = min(1, 0.38 + resolutionScore * 0.44 + (1 - abs(seed - 0.5)) * 0.14)
                let interest = min(1, 0.28 + seed * 0.55 + (tags.isEmpty ? 0 : 0.12))
                let stability = min(1, 0.42 + (1 - seed) * 0.50)
                let candidateLength = min(duration, max(1.2, nominalCandidateLength * (1.28 - action * 0.55 + interest * 0.18)))
                let center = min(duration, (Double(index) + 0.5) * spacing)
                let start = max(0, min(duration - candidateLength, center - candidateLength / 2))
                let scores = ClipScores(quality: quality, interest: interest, action: action, stability: stability)
                var candidateTags = tags
                if action > 0.70 { candidateTags.insert("action") }
                if action < 0.38 { candidateTags.insert("atmosphere") }
                let insights = CandidateInsights(
                    sceneSummary: candidateTags.sorted().prefix(4).joined(separator: ", "),
                    dynamics: action,
                    visualAppeal: interest,
                    composition: min(1, quality * 0.55 + interest * 0.45),
                    sharpness: quality,
                    motionBlur: max(0, action - quality * 0.55),
                    noise: max(0, 1 - quality) * 0.55,
                    shake: max(0, 1 - stability),
                    exposureQuality: quality,
                    slowMotionSuitability: min(1, (frameRate >= 50 ? 0.45 : 0.12) + action * 0.32 + stability * 0.23),
                    speedRampSuitability: min(1, action * 0.58 + interest * 0.24 + stability * 0.18),
                    originalAudioUsefulness: asset.metadata.hasAudio == true ? (candidateTags.contains("people") || candidateTags.contains("action") ? 0.68 : 0.34) : 0,
                    storyValue: min(1, interest * 0.48 + quality * 0.30 + scores.uniqueness * 0.22),
                    roleScores: [
                        .intro: min(1, interest * 0.38 + quality * 0.32 + stability * 0.30),
                        .setup: min(1, interest * 0.46 + quality * 0.30 + (candidateTags.contains("people") ? 0.24 : 0)),
                        .buildup: min(1, interest * 0.44 + action * 0.34 + quality * 0.22),
                        .climax: min(1, action * 0.52 + interest * 0.30 + quality * 0.18),
                        .reaction: min(1, (1 - action) * 0.28 + interest * 0.34 + stability * 0.20 + (candidateTags.contains("people") ? 0.18 : 0)),
                        .outro: min(1, (1 - action) * 0.36 + interest * 0.34 + quality * 0.30)
                    ]
                )
                candidates.append(Candidate(assetID: asset.id, sourceStart: start, sourceDuration: candidateLength, scores: scores, tags: candidateTags, explanation: Self.explanation(scores: scores, tags: candidateTags), insights: insights))
            }
            return AnalysisResult(assetID: asset.id, schemaVersion: schemaVersion, analyzedContentHash: asset.contentHash, sceneTags: tags, candidates: candidates)
        }
    }

    private static func tagsFromFilename(_ filename: String) -> Set<String> {
        let lower = filename.lowercased()
        let vocabulary: [(String, [String])] = [
            ("bike", ["bike", "bicycle", "velo", "велосип"]),
            ("buggy", ["buggy", "багги"]),
            ("fishing", ["fish", "рыбал", "fishing"]),
            ("nature", ["forest", "nature", "лес", "природ"]),
            ("water", ["lake", "river", "sea", "озер", "рек", "мор"]),
            ("sunset", ["sunset", "закат"]),
            ("people", ["family", "people", "семь", "люди"]),
            ("travel", ["trip", "travel", "поезд", "путеше"])
        ]
        return Set(vocabulary.compactMap { tag, needles in needles.contains(where: lower.contains) ? tag : nil })
    }

    private static func photoMetrics(url: URL) -> (quality: Double, interest: Double, labels: Set<String>) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return (0.4, 0.4, [])
        }
        let megapixels = Double(image.width * image.height) / 1_000_000
        let resolution = min(1, megapixels / 12)
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([request])
        let observations = (request.results ?? []).prefix(4).filter { $0.confidence >= 0.25 }
        let labels = Set(observations.map { $0.identifier.lowercased().replacingOccurrences(of: " ", with: "-") })
        let confidence = Double(observations.first?.confidence ?? 0.35)
        return (min(1, 0.45 + resolution * 0.5), min(1, 0.35 + confidence * 0.55), labels)
    }

    private static func resolutionScore(width: Int?, height: Int?) -> Double {
        guard let width, let height else { return 0.4 }
        return min(1, Double(width * height) / Double(3840 * 2160))
    }

    private static func stableUnit(_ value: String) -> Double {
        let scalar = value.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return Double(scalar % 10_000) / 10_000
    }

    private static func explanation(scores: ClipScores, tags: Set<String>) -> [String] {
        var result: [String] = []
        if scores.action >= 0.7 { result.append("Высокая динамика") }
        if scores.quality >= 0.7 { result.append("Хорошее техническое качество") }
        if scores.interest >= 0.7 { result.append("Высокая визуальная ценность") }
        if let tag = tags.sorted().first { result.append("Сцена: \(tag)") }
        if result.isEmpty { result.append("Подходит по темпу и разнообразию") }
        return result
    }
}

public struct EventGrouper: Sendable {
    public var maximumGap: TimeInterval
    public init(maximumGap: TimeInterval = 6 * 60 * 60) { self.maximumGap = maximumGap }

    public func group(assets: [MediaAsset], analyses: [AnalysisResult]) -> [Event] {
        EventIntelligenceEngine(maximumMultiDayGap: max(maximumGap, 4 * 86_400))
            .discover(assets: assets, analyses: analyses).events
    }
}
