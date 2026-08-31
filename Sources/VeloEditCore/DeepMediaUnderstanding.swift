import Foundation

// MARK: - Visual embeddings and semantic index

public struct VisualEmbedding: Codable, Hashable, Sendable {
    public var modelIdentifier: String
    public var values: [Float]
    public var confidence: Double
    public var sampledTimestamps: [Double]

    public init(modelIdentifier: String, values: [Float], confidence: Double, sampledTimestamps: [Double] = []) {
        self.modelIdentifier = modelIdentifier
        self.values = Self.normalized(values)
        self.confidence = confidence.clamped01
        self.sampledTimestamps = sampledTimestamps.filter(\.isFinite).map { max(0, $0) }
    }

    public func cosineSimilarity(to other: VisualEmbedding) -> Double {
        guard values.count == other.values.count, !values.isEmpty else { return 0 }
        let dot = zip(values, other.values).reduce(Float.zero) { $0 + $1.0 * $1.1 }
        return Double(max(-1, min(1, dot))).clamped01
    }

    private static func normalized(_ values: [Float]) -> [Float] {
        let finite = values.map { $0.isFinite ? $0 : 0 }
        let norm = sqrt(finite.reduce(Float.zero) { $0 + $1 * $1 })
        guard norm > 0.000_001 else { return finite }
        return finite.map { $0 / norm }
    }
}

public struct EmbeddingFrameDescriptor: Hashable, Sendable {
    public var timestamp: Double
    public var histogram: [Double]
    public var luminanceFingerprint: [UInt8]
    public var labels: Set<String>

    public init(timestamp: Double, histogram: [Double], luminanceFingerprint: [UInt8], labels: Set<String> = []) {
        self.timestamp = max(0, timestamp)
        self.histogram = histogram
        self.luminanceFingerprint = luminanceFingerprint
        self.labels = labels
    }
}

public struct EmbeddingInput: Hashable, Sendable {
    public var frames: [EmbeddingFrameDescriptor]
    public var semanticTokens: Set<String>

    public init(frames: [EmbeddingFrameDescriptor], semanticTokens: Set<String> = []) {
        self.frames = frames
        self.semanticTokens = semanticTokens
    }
}

/// Lightweight local descriptor built from already-decoded adaptive key frames.
/// It combines spatial luminance, histogram and hashed semantic channels, so it
/// separates visually different events even when their high-level tags match.
public struct LocalVisualEmbeddingModel: EmbeddingModelProtocol, Sendable {
    public let modelIdentifier = "velo-visual-embedding-v1"
    public init() {}

    public func embedding(for input: EmbeddingInput) async throws -> VisualEmbedding {
        try Task.checkCancellation()
        guard !input.frames.isEmpty else {
            return VisualEmbedding(modelIdentifier: modelIdentifier, values: [], confidence: 0)
        }
        var histogram = [Double](repeating: 0, count: 16)
        var spatial = [Double](repeating: 0, count: 24)
        for frame in input.frames {
            for index in histogram.indices where index < frame.histogram.count {
                histogram[index] += frame.histogram[index]
            }
            let fingerprint = frame.luminanceFingerprint
            for index in spatial.indices where !fingerprint.isEmpty {
                let lower = index * fingerprint.count / spatial.count
                let upper = max(lower + 1, (index + 1) * fingerprint.count / spatial.count)
                let slice = fingerprint[lower..<min(fingerprint.count, upper)]
                spatial[index] += slice.isEmpty ? 0 : Double(slice.reduce(0) { $0 + Int($1) }) / Double(slice.count * 255)
            }
        }
        let divisor = Double(input.frames.count)
        histogram = histogram.map { $0 / divisor }
        spatial = spatial.map { $0 / divisor }

        var semantic = [Double](repeating: 0, count: 24)
        let tokens = input.semanticTokens.union(input.frames.flatMap(\.labels))
        for token in tokens {
            let hash = Self.fnv1a(token.lowercased())
            let index = Int(hash % UInt64(semantic.count))
            let sign = ((hash >> 8) & 1) == 0 ? 1.0 : -1.0
            semantic[index] += sign * (0.55 + Double((hash >> 16) % 45) / 100)
        }
        if !tokens.isEmpty {
            semantic = semantic.map { $0 / sqrt(Double(tokens.count)) }
        }
        let vector = (histogram.map { Float($0 * 1.15) }
            + spatial.map { Float($0 * 0.82) }
            + semantic.map { Float($0 * 0.68) })
        let confidence = min(1, 0.34 + Double(input.frames.count) * 0.11 + (tokens.isEmpty ? 0 : 0.18))
        return VisualEmbedding(
            modelIdentifier: modelIdentifier,
            values: vector,
            confidence: confidence,
            sampledTimestamps: input.frames.map(\.timestamp)
        )
    }

    private static func fnv1a(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

public struct SemanticSimilarityMatch: Hashable, Sendable {
    public var candidateID: UUID
    public var similarity: Double
}

public struct SemanticSceneCluster: Hashable, Sendable {
    public var id: String
    public var candidateIDs: [UUID]
    public var bestCandidateID: UUID
    public var meanSimilarity: Double
}

public struct SemanticSceneIndex: Sendable {
    private struct IndexPair: Hashable {
        var first: Int
        var second: Int
        init(_ first: Int, _ second: Int) {
            self.first = min(first, second)
            self.second = max(first, second)
        }
    }

    private var candidates: [UUID: Candidate]

    public init(candidates: [Candidate]) {
        self.candidates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
    }

    public func similarity(between first: Candidate, and second: Candidate) -> Double {
        if let lhs = first.insights?.visualEmbedding, let rhs = second.insights?.visualEmbedding,
           !lhs.values.isEmpty, lhs.values.count == rhs.values.count {
            return lhs.cosineSimilarity(to: rhs)
        }
        let lhs = semanticTokens(first)
        let rhs = semanticTokens(second)
        let union = lhs.union(rhs)
        let jaccard = union.isEmpty ? 0 : Double(lhs.intersection(rhs).count) / Double(union.count)
        let scoreDistance = abs(first.scores.action - second.scores.action)
            + abs(first.scores.quality - second.scores.quality)
            + abs(first.scores.interest - second.scores.interest)
        return (jaccard * 0.72 + max(0, 1 - scoreDistance / 3) * 0.28).clamped01
    }

    public func nearest(to candidate: Candidate, limit: Int = 8, excludingSameAsset: Bool = false) -> [SemanticSimilarityMatch] {
        candidates.values
            .filter { $0.id != candidate.id && (!excludingSameAsset || $0.assetID != candidate.assetID) }
            .map { SemanticSimilarityMatch(candidateID: $0.id, similarity: similarity(between: candidate, and: $0)) }
            .sorted { $0.similarity > $1.similarity }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func clusters(threshold: Double = 0.88) -> [SemanticSceneCluster] {
        let threshold = threshold.clamped01
        let values = Array(candidates.values)
        var parent = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0.id) })
        func root(_ id: UUID, in parent: [UUID: UUID]) -> UUID {
            var value = id
            while let next = parent[value], next != value { value = next }
            return value
        }
        for pair in comparisonPairs(values) {
                guard similarity(between: values[pair.first], and: values[pair.second]) >= threshold else { continue }
                let lhs = root(values[pair.first].id, in: parent)
                let rhs = root(values[pair.second].id, in: parent)
                if lhs != rhs { parent[rhs] = lhs }
        }
        let grouped = Dictionary(grouping: values) { root($0.id, in: parent) }
        return grouped.values.filter { $0.count > 1 }.map { group in
            let ordered = group.sorted { Self.bestTakeScore($0) > Self.bestTakeScore($1) }
            var similarities: [Double] = []
            if group.count <= 128 {
                for first in group.indices {
                    for second in group.indices where second > first {
                        similarities.append(similarity(between: group[first], and: group[second]))
                    }
                }
            } else if let anchor = ordered.first {
                similarities = ordered.dropFirst().map { similarity(between: anchor, and: $0) }
            }
            let stableID = ordered.map(\.id.uuidString).sorted().joined(separator: "|")
            return SemanticSceneCluster(
                id: String(LocalVisualEmbeddingModelHash.fnv1a(stableID), radix: 16),
                candidateIDs: ordered.map(\.id),
                bestCandidateID: ordered[0].id,
                meanSimilarity: similarities.reduce(0, +) / Double(max(1, similarities.count))
            )
        }
    }

    public static func bestTakeScore(_ candidate: Candidate) -> Double {
        let insight = candidate.insights
        let subject = insight?.subjectTracking?.mainSubjectVisibility ?? 0.45
        let boundary = candidate.momentBoundary?.confidence ?? 0.35
        return (candidate.scores.quality * 0.25 + candidate.scores.stability * 0.17
            + (insight?.composition ?? candidate.scores.quality) * 0.18
            + candidate.scores.interest * 0.16 + subject * 0.12 + boundary * 0.12).clamped01
    }

    private func semanticTokens(_ candidate: Candidate) -> Set<String> {
        var result = Set(candidate.tags.map { $0.lowercased() })
        if let summary = candidate.insights?.sceneSummary {
            result.formUnion(summary.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        }
        return result
    }

    /// Exhaustive comparison is more accurate for the small candidate sets
    /// produced per clip. Large libraries use several deterministic locality
    /// buckets plus within-asset comparisons, avoiding O(N²) work for hundreds
    /// of GoPro files while preserving a fallback when embeddings are absent.
    private func comparisonPairs(_ values: [Candidate]) -> Set<IndexPair> {
        guard values.count > 1 else { return [] }
        if values.count <= 384 {
            return Set(values.indices.flatMap { first in
                values.indices.compactMap { second in second > first ? IndexPair(first, second) : nil }
            })
        }
        var pairs = Set<IndexPair>()
        func addGroup(_ indices: [Int]) {
            guard indices.count > 1 else { return }
            if indices.count <= 128 {
                for position in indices.indices {
                    for secondPosition in indices.indices where secondPosition > position {
                        pairs.insert(IndexPair(indices[position], indices[secondPosition]))
                    }
                }
            } else {
                // Dense identical buckets are connected by a bounded set of
                // representatives. A similarity edge to any representative is
                // sufficient for union-find to form the complete cluster.
                let representatives = Array(indices.prefix(16))
                for (position, index) in indices.enumerated() {
                    for representative in representatives where representative != index {
                        pairs.insert(IndexPair(index, representative))
                    }
                    if position > 0 { pairs.insert(IndexPair(index, indices[position - 1])) }
                }
            }
        }

        Dictionary(grouping: values.indices, by: { values[$0].assetID }).values.forEach { addGroup($0) }
        let projections = [[40, 43, 46, 49, 52, 55, 58, 61], [41, 44, 47, 50, 53, 56, 59, 62]]
        for projection in projections {
            let buckets = Dictionary(grouping: values.indices.compactMap { index -> (String, Int)? in
                guard let embedding = values[index].insights?.visualEmbedding,
                      embedding.values.count > (projection.max() ?? 0) else { return nil }
                let signature = projection.map { embedding.values[$0] >= 0 ? "1" : "0" }.joined()
                return (signature, index)
            }, by: { $0.0 })
            buckets.values.forEach { addGroup($0.map(\.1)) }
        }
        let visualBuckets = Dictionary(grouping: values.indices.compactMap { index -> (String, Int)? in
            guard let embedding = values[index].insights?.visualEmbedding, embedding.values.count >= 16 else { return nil }
            let top = embedding.values.prefix(16).indices.sorted { embedding.values[$0] > embedding.values[$1] }.prefix(3)
            return (top.map(String.init).joined(separator: "-"), index)
        }, by: { $0.0 })
        visualBuckets.values.forEach { addGroup($0.map(\.1)) }

        let fallbackBuckets = Dictionary(grouping: values.indices.filter {
            values[$0].insights?.visualEmbedding?.values.isEmpty ?? true
        }, by: { semanticTokens(values[$0]).sorted().prefix(3).joined(separator: "|") })
        fallbackBuckets.values.forEach { addGroup($0) }
        return pairs
    }
}

private enum LocalVisualEmbeddingModelHash {
    static func fnv1a(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

// MARK: - Subjects, tracking and reframing

public enum SubjectKind: String, Codable, CaseIterable, Hashable, Sendable {
    case face, person, cyclist, bicycle, vehicle, animal, salientObject = "salient-object", unknown
}

public struct NormalizedRegion: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x.clamped01
        self.y = y.clamped01
        self.width = min(max(0.001, width), 1 - self.x)
        self.height = min(max(0.001, height), 1 - self.y)
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
    public var area: Double { width * height }
    public var touchesEdge: Bool { x < 0.015 || y < 0.015 || x + width > 0.985 || y + height > 0.985 }
}

public struct FrameSubjectObservation: Codable, Hashable, Sendable {
    public var kind: SubjectKind
    public var label: String
    public var region: NormalizedRegion
    public var confidence: Double

    public init(kind: SubjectKind, label: String, region: NormalizedRegion, confidence: Double) {
        self.kind = kind
        self.label = label
        self.region = region
        self.confidence = confidence.clamped01
    }
}

public struct SubjectFrameDescriptor: Hashable, Sendable {
    public var timestamp: Double
    public var observations: [FrameSubjectObservation]
    public init(timestamp: Double, observations: [FrameSubjectObservation]) {
        self.timestamp = max(0, timestamp)
        self.observations = observations
    }
}

public struct SubjectTrackObservation: Codable, Hashable, Sendable {
    public var timestamp: Double
    public var region: NormalizedRegion
    public var confidence: Double
}

public struct SubjectTrack: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: SubjectKind
    public var label: String
    public var observations: [SubjectTrackObservation]
    public var meanConfidence: Double
    public var visibility: Double
    public var compositionQuality: Double
    public var movementX: Double
    public var movementY: Double

    public init(id: UUID = UUID(), kind: SubjectKind, label: String, observations: [SubjectTrackObservation], meanConfidence: Double, visibility: Double, compositionQuality: Double, movementX: Double = 0, movementY: Double = 0) {
        self.id = id
        self.kind = kind
        self.label = label
        self.observations = observations.sorted { $0.timestamp < $1.timestamp }
        self.meanConfidence = meanConfidence.clamped01
        self.visibility = visibility.clamped01
        self.compositionQuality = compositionQuality.clamped01
        self.movementX = min(max(-1, movementX), 1)
        self.movementY = min(max(-1, movementY), 1)
    }
}

public struct SubjectTrackingSummary: Codable, Hashable, Sendable {
    public var tracks: [SubjectTrack]
    public var mainSubjectID: UUID?
    public var confidence: Double
    public var analyzedFrameCount: Int

    public init(tracks: [SubjectTrack], mainSubjectID: UUID?, confidence: Double, analyzedFrameCount: Int) {
        self.tracks = tracks
        self.mainSubjectID = mainSubjectID
        self.confidence = confidence.clamped01
        self.analyzedFrameCount = max(0, analyzedFrameCount)
    }

    public var mainSubject: SubjectTrack? { mainSubjectID.flatMap { id in tracks.first { $0.id == id } } }
    public var mainSubjectVisibility: Double { mainSubject?.visibility ?? 0 }
    public var compositionQuality: Double { mainSubject?.compositionQuality ?? 0.45 }
}

public struct LocalSubjectTracker: Sendable {
    public init() {}

    public func track(frames: [SubjectFrameDescriptor]) -> SubjectTrackingSummary {
        struct MutableTrack {
            var id = UUID()
            var kind: SubjectKind
            var label: String
            var values: [SubjectTrackObservation]
        }
        var tracks: [MutableTrack] = []
        for frame in frames.sorted(by: { $0.timestamp < $1.timestamp }) {
            for observation in frame.observations.sorted(by: { $0.confidence * $0.region.area > $1.confidence * $1.region.area }) {
                let best = tracks.indices
                    .filter { tracks[$0].kind == observation.kind }
                    .map { index -> (Int, Double) in
                        let last = tracks[index].values.last
                        let distance = last.map { hypot($0.region.centerX - observation.region.centerX, $0.region.centerY - observation.region.centerY) } ?? 1
                        return (index, distance)
                    }
                    .filter { $0.1 <= 0.34 }
                    .min { $0.1 < $1.1 }
                let value = SubjectTrackObservation(timestamp: frame.timestamp, region: observation.region, confidence: observation.confidence)
                if let index = best?.0 { tracks[index].values.append(value) }
                else { tracks.append(MutableTrack(kind: observation.kind, label: observation.label, values: [value])) }
            }
        }
        let frameCount = max(1, frames.count)
        let finalized = tracks.map { track -> SubjectTrack in
            let confidence = track.values.reduce(0) { $0 + $1.confidence } / Double(max(1, track.values.count))
            let coverage = Double(track.values.count) / Double(frameCount)
            let meanArea = track.values.reduce(0) { $0 + $1.region.area } / Double(max(1, track.values.count))
            let edgePenalty = Double(track.values.filter { $0.region.touchesEdge }.count) / Double(max(1, track.values.count))
            let ruleOfThirds = track.values.reduce(0) { partial, value in
                let region = value.region
                let targetX = region.centerX < 0.5 ? 1.0 / 3.0 : 2.0 / 3.0
                let targetY = region.centerY < 0.5 ? 1.0 / 3.0 : 2.0 / 3.0
                return partial + max(0, 1 - hypot(region.centerX - targetX, region.centerY - targetY) / 0.72)
            } / Double(max(1, track.values.count))
            let first = track.values.first?.region
            let last = track.values.last?.region
            return SubjectTrack(
                id: track.id,
                kind: track.kind,
                label: track.label,
                observations: track.values,
                meanConfidence: confidence,
                visibility: (coverage * 0.56 + min(1, meanArea / 0.18) * 0.24 + (1 - edgePenalty) * 0.20).clamped01,
                compositionQuality: (ruleOfThirds * 0.62 + (1 - edgePenalty) * 0.38).clamped01,
                movementX: (last?.centerX ?? 0.5) - (first?.centerX ?? 0.5),
                movementY: (last?.centerY ?? 0.5) - (first?.centerY ?? 0.5)
            )
        }
        let main = finalized.max { lhs, rhs in
            Self.priority(lhs) < Self.priority(rhs)
        }
        let confidence = main.map { ($0.meanConfidence * 0.45 + $0.visibility * 0.55).clamped01 } ?? 0
        return SubjectTrackingSummary(tracks: finalized, mainSubjectID: main?.id, confidence: confidence, analyzedFrameCount: frames.count)
    }

    private static func priority(_ track: SubjectTrack) -> Double {
        let kindBoost: Double
        switch track.kind {
        case .face: kindBoost = 0.25
        case .person, .cyclist: kindBoost = 0.20
        case .animal, .vehicle, .bicycle: kindBoost = 0.12
        case .salientObject: kindBoost = 0.06
        case .unknown: kindBoost = 0
        }
        return track.visibility * 0.46 + track.meanConfidence * 0.31 + track.compositionQuality * 0.23 + kindBoost
    }
}

public struct SubjectReframePlan: Codable, Hashable, Sendable {
    public var startCenterX: Double
    public var startCenterY: Double
    public var endCenterX: Double
    public var endCenterY: Double
    public var startScale: Double
    public var endScale: Double
    public var targetAspectRatio: Double
    public var confidence: Double
    public var reasons: [String]

    public init(startCenterX: Double, startCenterY: Double, endCenterX: Double, endCenterY: Double, startScale: Double, endScale: Double, targetAspectRatio: Double, confidence: Double, reasons: [String] = []) {
        self.startCenterX = startCenterX.clamped01
        self.startCenterY = startCenterY.clamped01
        self.endCenterX = endCenterX.clamped01
        self.endCenterY = endCenterY.clamped01
        self.startScale = min(max(1, startScale), 3.5)
        self.endScale = min(max(1, endScale), 3.5)
        self.targetAspectRatio = max(0.1, targetAspectRatio)
        self.confidence = confidence.clamped01
        self.reasons = reasons
    }
}

public struct SubjectAwareReframeEngine: Sendable {
    public init() {}

    public func plan(tracking: SubjectTrackingSummary, sourceAspectRatio: Double, targetAspectRatio: Double, isPhoto: Bool = false) -> SubjectReframePlan? {
        guard let subject = tracking.mainSubject,
              let first = subject.observations.first?.region,
              let last = subject.observations.last?.region,
              tracking.confidence >= 0.24 else { return nil }
        let aspectDifference = abs(sourceAspectRatio - targetAspectRatio)
        // A video that already matches the timeline format needs neither a
        // format conversion nor a digital camera move. Reframing such clips
        // made ordinary 16:9 footage look accidentally cropped in Preview and
        // Export. Photos may still receive a deliberate Ken Burns treatment.
        guard isPhoto || aspectDifference > 0.04 else { return nil }
        let lead = min(0.12, max(-0.12, subject.movementX * 0.42))
        func safeCenter(_ region: NormalizedRegion, lead: Double) -> (Double, Double) {
            let marginX = min(0.22, max(0.04, region.width * 0.60))
            let marginY = min(0.18, max(0.04, region.height * 0.45))
            return (
                min(1 - marginX, max(marginX, region.centerX + lead)),
                min(1 - marginY, max(marginY, region.centerY))
            )
        }
        let start = safeCenter(first, lead: lead)
        let end = safeCenter(last, lead: lead)
        // Aspect fill already supplies the format conversion. Additional zoom
        // is useful only when the subject is genuinely small, never when a
        // large face/object is already close to a crop edge.
        let meanArea = max(0.001, (first.area + last.area) / 2)
        let subjectScale = isPhoto && meanArea < 0.075 ? min(1.24, sqrt(0.075 / meanArea)) : 1
        let baseScale = subjectScale
        var reasons = ["Главный объект \(subject.label) удерживается в safe area"]
        if abs(subject.movementX) > 0.04 { reasons.append("Оставлено пространство по направлению движения") }
        if subject.kind == .face || subject.kind == .person { reasons.append("Защита лица/человека от crop") }
        if abs(sourceAspectRatio - targetAspectRatio) > 0.15 { reasons.append("Reframe \(String(format: "%.2f", sourceAspectRatio)):1 → \(String(format: "%.2f", targetAspectRatio)):1") }
        let photoDrift = isPhoto ? min(0.07, max(0.025, abs(end.0 - start.0) + 0.025)) : 0
        return SubjectReframePlan(
            startCenterX: start.0,
            startCenterY: start.1,
            endCenterX: min(0.96, max(0.04, end.0 + (subject.movementX >= 0 ? photoDrift : -photoDrift))),
            endCenterY: end.1,
            startScale: baseScale,
            endScale: isPhoto ? min(3.5, baseScale * 1.06) : baseScale,
            targetAspectRatio: targetAspectRatio,
            confidence: tracking.confidence * 0.72 + subject.compositionQuality * 0.28,
            reasons: reasons
        )
    }
}

// MARK: - Speech and audio events

public enum AudioEventKind: String, Codable, CaseIterable, Hashable, Sendable {
    case speech, laughter, applause, scream, impact, splash, engine, wind, crowd, nature, ambient, music, silence
}

public struct AudioEventObservation: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: AudioEventKind
    public var startTime: Double
    public var endTime: Double
    public var confidence: Double
    public var intensity: Double
    public var evidence: [String]

    public init(id: UUID = UUID(), kind: AudioEventKind, startTime: Double, endTime: Double, confidence: Double, intensity: Double, evidence: [String] = []) {
        self.id = id
        self.kind = kind
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime, endTime)
        self.confidence = confidence.clamped01
        self.intensity = intensity.clamped01
        self.evidence = evidence
    }

    public var duration: Double { endTime - startTime }
    public func overlaps(_ range: ClosedRange<Double>) -> Bool { startTime <= range.upperBound && endTime >= range.lowerBound }
}

public struct AudioFeatureWindow: Codable, Hashable, Sendable {
    public var startTime: Double
    public var duration: Double
    public var rms: Double
    public var peak: Double
    public var zeroCrossingRate: Double
    public var onsetStrength: Double
    public var spectralFlux: Double

    public init(startTime: Double, duration: Double, rms: Double, peak: Double, zeroCrossingRate: Double, onsetStrength: Double, spectralFlux: Double = 0) {
        self.startTime = max(0, startTime)
        self.duration = max(0.001, duration)
        self.rms = rms.clamped01
        self.peak = peak.clamped01
        self.zeroCrossingRate = zeroCrossingRate.clamped01
        self.onsetStrength = onsetStrength.clamped01
        self.spectralFlux = spectralFlux.clamped01
    }
}

public struct DSPAudioEventClassifier: Sendable {
    public init() {}

    public func classify(windows: [AudioFeatureWindow], speechProbability: Double, musicProbability: Double) -> [AudioEventObservation] {
        guard !windows.isEmpty else { return [] }
        let labeled: [(AudioFeatureWindow, AudioEventKind, Double)] = windows.map { window in
            let crest = max(0, window.peak - window.rms)
            let kind: AudioEventKind
            let confidence: Double
            if window.rms < 0.014 {
                kind = .silence; confidence = min(1, 0.72 + (0.014 - window.rms) * 12)
            } else if window.onsetStrength > 0.42 && crest > 0.28 {
                kind = .impact; confidence = min(1, 0.48 + window.onsetStrength * 0.38 + crest * 0.30)
            } else if window.rms > 0.30 && window.zeroCrossingRate > 0.13 {
                kind = .scream; confidence = min(1, 0.42 + window.rms * 0.42 + window.zeroCrossingRate)
            } else if window.onsetStrength > 0.20 && window.zeroCrossingRate > 0.07 {
                kind = window.spectralFlux > 0.40 ? .applause : .laughter
                confidence = min(1, 0.38 + window.onsetStrength * 0.55 + window.spectralFlux * 0.25)
            } else if speechProbability > 0.42 && window.zeroCrossingRate > 0.025 && window.zeroCrossingRate < 0.19 {
                kind = .speech; confidence = min(1, speechProbability * 0.72 + (1 - abs(window.rms - 0.12) / 0.20) * 0.28)
            } else if musicProbability > 0.58 && window.onsetStrength > 0.06 {
                kind = .music; confidence = min(1, musicProbability * 0.72 + window.onsetStrength * 0.28)
            } else if window.zeroCrossingRate < 0.035 && window.rms > 0.06 {
                kind = .engine; confidence = min(1, 0.45 + window.rms * 0.75)
            } else if window.zeroCrossingRate > 0.18 && window.onsetStrength < 0.18 {
                kind = .wind; confidence = min(1, 0.43 + window.zeroCrossingRate * 1.4)
            } else if window.zeroCrossingRate > 0.10 && window.spectralFlux < 0.26 {
                kind = .splash; confidence = min(0.82, 0.38 + window.zeroCrossingRate + window.rms * 0.45)
            } else if window.rms > 0.14 && window.spectralFlux > 0.24 {
                kind = .crowd; confidence = min(0.78, 0.38 + window.rms + window.spectralFlux * 0.30)
            } else {
                kind = window.rms < 0.07 ? .nature : .ambient
                confidence = min(0.72, 0.38 + max(window.rms, 0.18))
            }
            return (window, kind, confidence.clamped01)
        }
        var events: [AudioEventObservation] = []
        for item in labeled {
            let end = item.0.startTime + item.0.duration
            if let last = events.indices.last,
               events[last].kind == item.1,
               item.0.startTime - events[last].endTime <= max(0.08, item.0.duration * 0.4) {
                let oldDuration = max(0.001, events[last].duration)
                let newDuration = oldDuration + item.0.duration
                events[last].confidence = (events[last].confidence * oldDuration + item.2 * item.0.duration) / newDuration
                events[last].intensity = max(events[last].intensity, item.0.peak)
                events[last].endTime = end
            } else {
                events.append(AudioEventObservation(
                    kind: item.1,
                    startTime: item.0.startTime,
                    endTime: end,
                    confidence: item.2,
                    intensity: item.0.peak,
                    evidence: ["local DSP: rms/onset/zero-crossing/spectral-flux"]
                ))
            }
        }
        return events.filter { $0.duration >= 0.04 && $0.confidence >= 0.34 }
    }
}

public struct TranscriptWord: Codable, Hashable, Sendable {
    public var text: String
    public var startTime: Double
    public var duration: Double
    public var confidence: Double

    public init(text: String, startTime: Double, duration: Double, confidence: Double) {
        self.text = text
        self.startTime = max(0, startTime)
        self.duration = max(0, duration)
        self.confidence = confidence.clamped01
    }
    public var endTime: Double { startTime + duration }
}

public struct TranscriptSentence: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var startTime: Double
    public var endTime: Double
    public var confidence: Double
    public var speakerID: String?

    public init(id: UUID = UUID(), text: String, startTime: Double, endTime: Double, confidence: Double, speakerID: String? = nil) {
        self.id = id
        self.text = text
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime, endTime)
        self.confidence = confidence.clamped01
        self.speakerID = speakerID
    }
}

public struct SpeechTranscript: Codable, Hashable, Sendable {
    public var localeIdentifier: String
    public var words: [TranscriptWord]
    public var sentences: [TranscriptSentence]
    public var silenceBoundaries: [ClosedRange<Double>]
    public var confidence: Double
    public var usedOnDeviceRecognition: Bool

    public init(localeIdentifier: String, words: [TranscriptWord], sentences: [TranscriptSentence], silenceBoundaries: [ClosedRange<Double>] = [], confidence: Double, usedOnDeviceRecognition: Bool = true) {
        self.localeIdentifier = localeIdentifier
        self.words = words
        self.sentences = sentences
        self.silenceBoundaries = silenceBoundaries
        self.confidence = confidence.clamped01
        self.usedOnDeviceRecognition = usedOnDeviceRecognition
    }
}

public struct SpeechEditingEvidence: Codable, Hashable, Sendable {
    public var text: String
    public var phraseStart: Double
    public var phraseEnd: Double
    public var confidence: Double
    public var startsAtPhraseBoundary: Bool
    public var endsAtPhraseBoundary: Bool
    public var silenceBefore: Double
    public var silenceAfter: Double
    /// P8 keeps the richer on-device ASR evidence needed for editable,
    /// word-synchronous subtitles. Optional fields preserve old caches.
    public var localeIdentifier: String?
    public var speakerID: String?
    public var words: [TranscriptWord]?

    public init(text: String, phraseStart: Double, phraseEnd: Double, confidence: Double, startsAtPhraseBoundary: Bool, endsAtPhraseBoundary: Bool, silenceBefore: Double = 0, silenceAfter: Double = 0, localeIdentifier: String? = nil, speakerID: String? = nil, words: [TranscriptWord]? = nil) {
        self.text = text
        self.phraseStart = max(0, phraseStart)
        self.phraseEnd = max(self.phraseStart, phraseEnd)
        self.confidence = confidence.clamped01
        self.startsAtPhraseBoundary = startsAtPhraseBoundary
        self.endsAtPhraseBoundary = endsAtPhraseBoundary
        self.silenceBefore = max(0, silenceBefore)
        self.silenceAfter = max(0, silenceAfter)
        self.localeIdentifier = localeIdentifier
        self.speakerID = speakerID
        self.words = words
    }

    public var preservesCompletePhrase: Bool { startsAtPhraseBoundary && endsAtPhraseBoundary }

    /// Lightweight offline editorial signal. It intentionally does not infer
    /// taste; it only separates an intelligible sentence/reaction from empty
    /// or filler-only speech so Story Engine can avoid meaningless dialogue.
    public var editorialImportance: Double {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return confidence * 0.18 }
        let fillers: Set<String> = ["ээ", "эм", "ну", "типа", "короче", "uh", "um", "erm", "like"]
        let meaningful = words.filter { !fillers.contains($0) }
        let information = min(1, Double(meaningful.count) / 7)
        let reaction = text.contains("!") || text.contains("?") ? 1.0 : 0.35
        let completeness = preservesCompletePhrase ? 1.0 : 0.46
        return (information * 0.45 + reaction * 0.18 + completeness * 0.20 + confidence * 0.17).clamped01
    }
}

public protocol LocalSpeechRecognizing: Sendable {
    var modelIdentifier: String { get }
    func transcribe(url: URL, localeIdentifier: String?) async throws -> SpeechTranscript?
}

public struct TranscriptEvidenceBuilder: Sendable {
    public init() {}

    public func evidence(for range: ClosedRange<Double>, transcript: SpeechTranscript) -> SpeechEditingEvidence? {
        let overlapping = transcript.sentences.filter { $0.startTime <= range.upperBound && $0.endTime >= range.lowerBound }
        guard let first = overlapping.first, let last = overlapping.last else { return nil }
        let confidence = overlapping.reduce(0) { $0 + $1.confidence } / Double(overlapping.count)
        let before = transcript.silenceBoundaries.filter { $0.upperBound <= first.startTime }.max { $0.upperBound < $1.upperBound }
        let after = transcript.silenceBoundaries.filter { $0.lowerBound >= last.endTime }.min { $0.lowerBound < $1.lowerBound }
        let speakers = Set(overlapping.compactMap(\.speakerID))
        let words = transcript.words.filter { $0.startTime <= last.endTime && $0.endTime >= first.startTime }
        return SpeechEditingEvidence(
            text: overlapping.map(\.text).joined(separator: " "),
            phraseStart: first.startTime,
            phraseEnd: last.endTime,
            confidence: confidence,
            startsAtPhraseBoundary: range.lowerBound <= first.startTime + 0.12,
            endsAtPhraseBoundary: range.upperBound >= last.endTime - 0.12,
            silenceBefore: before.map { max(0, first.startTime - $0.upperBound) } ?? 0,
            silenceAfter: after.map { max(0, $0.lowerBound - last.endTime) } ?? 0,
            localeIdentifier: transcript.localeIdentifier,
            speakerID: speakers.count == 1 ? speakers.first : nil,
            words: words.isEmpty ? nil : words
        )
    }
}

// MARK: - Persistent cache and diagnostics

public enum DeepAnalysisStage: String, Codable, CaseIterable, Hashable, Sendable {
    case embeddings, subjectTracking, audioEvents, asr, momentRefinement
}

public struct DeepAnalysisStageReport: Codable, Hashable, Sendable {
    public var stage: DeepAnalysisStage
    public var ran: Bool
    public var cacheHit: Bool
    public var itemCount: Int
    public var confidence: Double
    public var duration: TimeInterval
    public var reason: String

    public init(stage: DeepAnalysisStage, ran: Bool, cacheHit: Bool = false, itemCount: Int = 0, confidence: Double = 0, duration: TimeInterval = 0, reason: String = "") {
        self.stage = stage
        self.ran = ran
        self.cacheHit = cacheHit
        self.itemCount = max(0, itemCount)
        self.confidence = confidence.clamped01
        self.duration = max(0, duration)
        self.reason = reason
    }
}

public struct DeepMediaDiagnostics: Codable, Hashable, Sendable {
    public var stages: [DeepAnalysisStageReport]
    public var embeddedCandidateCount: Int
    public var trackedCandidateCount: Int
    public var transcribedCandidateCount: Int
    public var audioEventCandidateCount: Int
    public var nearDuplicateCandidateIDs: [UUID]
    public var discardedCandidateIDs: [UUID]
    public var totalDuration: TimeInterval

    public init(stages: [DeepAnalysisStageReport] = [], embeddedCandidateCount: Int = 0, trackedCandidateCount: Int = 0, transcribedCandidateCount: Int = 0, audioEventCandidateCount: Int = 0, nearDuplicateCandidateIDs: [UUID] = [], discardedCandidateIDs: [UUID] = [], totalDuration: TimeInterval = 0) {
        self.stages = stages
        self.embeddedCandidateCount = max(0, embeddedCandidateCount)
        self.trackedCandidateCount = max(0, trackedCandidateCount)
        self.transcribedCandidateCount = max(0, transcribedCandidateCount)
        self.audioEventCandidateCount = max(0, audioEventCandidateCount)
        self.nearDuplicateCandidateIDs = nearDuplicateCandidateIDs
        self.discardedCandidateIDs = discardedCandidateIDs
        self.totalDuration = max(0, totalDuration)
    }

    public static func aggregate(_ values: [DeepMediaDiagnostics]) -> DeepMediaDiagnostics {
        var stageGroups: [DeepAnalysisStage: [DeepAnalysisStageReport]] = [:]
        values.flatMap(\.stages).forEach { stageGroups[$0.stage, default: []].append($0) }
        let stages = DeepAnalysisStage.allCases.compactMap { stage -> DeepAnalysisStageReport? in
            guard let reports = stageGroups[stage], !reports.isEmpty else { return nil }
            let weightedConfidence = reports.reduce(0) { $0 + $1.confidence * Double(max(1, $1.itemCount)) }
            let units = reports.reduce(0) { $0 + max(1, $1.itemCount) }
            return DeepAnalysisStageReport(
                stage: stage,
                ran: reports.contains(where: \.ran),
                cacheHit: reports.contains(where: \.cacheHit),
                itemCount: reports.reduce(0) { $0 + $1.itemCount },
                confidence: weightedConfidence / Double(max(1, units)),
                duration: reports.reduce(0) { $0 + $1.duration },
                reason: reports.map(\.reason).filter { !$0.isEmpty }.joined(separator: "; ")
            )
        }
        return DeepMediaDiagnostics(
            stages: stages,
            embeddedCandidateCount: values.reduce(0) { $0 + $1.embeddedCandidateCount },
            trackedCandidateCount: values.reduce(0) { $0 + $1.trackedCandidateCount },
            transcribedCandidateCount: values.reduce(0) { $0 + $1.transcribedCandidateCount },
            audioEventCandidateCount: values.reduce(0) { $0 + $1.audioEventCandidateCount },
            nearDuplicateCandidateIDs: values.flatMap(\.nearDuplicateCandidateIDs),
            discardedCandidateIDs: values.flatMap(\.discardedCandidateIDs),
            totalDuration: values.reduce(0) { $0 + $1.totalDuration }
        )
    }
}

public struct CachedCandidateDeepEvidence: Codable, Hashable, Sendable {
    public var sourceStart: Double
    public var sourceDuration: Double
    public var embedding: VisualEmbedding?
    public var subjectTracking: SubjectTrackingSummary?

    public init(sourceStart: Double, sourceDuration: Double, embedding: VisualEmbedding? = nil, subjectTracking: SubjectTrackingSummary? = nil) {
        self.sourceStart = sourceStart
        self.sourceDuration = sourceDuration
        self.embedding = embedding
        self.subjectTracking = subjectTracking
    }

    public var stableKey: String { "\(Int((sourceStart * 100).rounded()))-\(Int((sourceDuration * 100).rounded()))" }
}

public struct DeepMediaCacheRecord: Codable, Hashable, Sendable {
    public var contentHash: String
    public var version: Int
    public var candidates: [String: CachedCandidateDeepEvidence]
    public var transcript: SpeechTranscript?
    public var audioEvents: [AudioEventObservation]
    public var audioAnalysis: AudioAnalysisSummary?

    public init(contentHash: String, version: Int = 1, candidates: [String: CachedCandidateDeepEvidence] = [:], transcript: SpeechTranscript? = nil, audioEvents: [AudioEventObservation] = [], audioAnalysis: AudioAnalysisSummary? = nil) {
        self.contentHash = contentHash
        self.version = version
        self.candidates = candidates
        self.transcript = transcript
        self.audioEvents = audioEvents
        self.audioAnalysis = audioAnalysis
    }
}

public actor DeepAnalysisCache {
    public static let version = 1
    private let rootURL: URL
    private let maximumMemoryEntries: Int
    private var memory: [String: DeepMediaCacheRecord] = [:]
    private var memoryOrder: [String] = []

    public init(rootURL: URL, maximumMemoryEntries: Int = 48) {
        self.rootURL = rootURL
        self.maximumMemoryEntries = max(1, maximumMemoryEntries)
    }

    public func load(contentHash: String) -> DeepMediaCacheRecord? {
        if let cached = memory[contentHash], cached.version == Self.version {
            touch(contentHash)
            return cached
        }
        let url = recordURL(contentHash: contentHash)
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(DeepMediaCacheRecord.self, from: data),
              value.version == Self.version, value.contentHash == contentHash else { return nil }
        memory[contentHash] = value
        touch(contentHash)
        return value
    }

    public func store(_ record: DeepMediaCacheRecord) throws {
        memory[record.contentHash] = record
        touch(record.contentHash)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: recordURL(contentHash: record.contentHash), options: .atomic)
    }

    public func removeMemoryEntries() {
        memory.removeAll(keepingCapacity: false)
        memoryOrder.removeAll(keepingCapacity: false)
    }

    public func memoryEntryCount() -> Int { memory.count }

    private func touch(_ contentHash: String) {
        memoryOrder.removeAll { $0 == contentHash }
        memoryOrder.append(contentHash)
        while memoryOrder.count > maximumMemoryEntries {
            memory.removeValue(forKey: memoryOrder.removeFirst())
        }
    }

    private func recordURL(contentHash: String) -> URL {
        let hash = LocalVisualEmbeddingModelHash.fnv1a(contentHash)
        return rootURL.appendingPathComponent("\(String(hash, radix: 16)).deep-media-v\(Self.version).json")
    }
}
