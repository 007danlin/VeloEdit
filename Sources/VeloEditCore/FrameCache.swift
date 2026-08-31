import Foundation

public enum FrameProcessingPurpose: String, Codable, CaseIterable, Sendable, Hashable {
    case sceneDetection
    case adaptiveSampling
    case localScoring
    case vision
    case vlm
    case aiDirector
}

public struct FrameCacheKey: Codable, Hashable, Sendable {
    public var sourceFile: String
    public var timestampMilliseconds: Int
    public var resolution: Int
    public var processingPurpose: FrameProcessingPurpose

    public init(sourceFile: String, timestamp: Double, resolution: Int, processingPurpose: FrameProcessingPurpose) {
        self.sourceFile = sourceFile
        timestampMilliseconds = Int((max(0, timestamp) * 1_000).rounded())
        self.resolution = max(1, resolution)
        self.processingPurpose = processingPurpose
    }

    fileprivate var canonicalIdentity: String {
        // Purpose remains part of the public audit key, while storage is
        // canonicalized so Vision, scoring and VLM reuse the same decode.
        "\(sourceFile)|\(timestampMilliseconds)|\(resolution)"
    }
}

private struct PersistedFrameRecord: Codable, Sendable {
    var sample: VisualFrameSample
    var purposes: Set<FrameProcessingPurpose>
}

public actor FrameCache {
    private let rootURL: URL
    private let maximumMemoryEntries: Int
    private var memory: [String: PersistedFrameRecord] = [:]
    private var memoryOrder: [String] = []

    public init(rootURL: URL, maximumMemoryEntries: Int = 384) {
        self.rootURL = rootURL
        self.maximumMemoryEntries = max(1, maximumMemoryEntries)
    }

    func value(for key: FrameCacheKey) -> VisualFrameSample? {
        let identity = key.canonicalIdentity
        if var record = memory[identity] {
            record.purposes.insert(key.processingPurpose)
            memory[identity] = record
            touch(identity)
            return record.sample
        }
        let url = recordURL(for: identity)
        guard let data = try? Data(contentsOf: url),
              var record = try? JSONDecoder().decode(PersistedFrameRecord.self, from: data) else { return nil }
        record.purposes.insert(key.processingPurpose)
        memory[identity] = record
        touch(identity)
        return record.sample
    }

    func store(_ sample: VisualFrameSample, for key: FrameCacheKey) throws {
        let identity = key.canonicalIdentity
        var purposes = memory[identity]?.purposes ?? []
        purposes.insert(key.processingPurpose)
        let record = PersistedFrameRecord(sample: sample, purposes: purposes)
        memory[identity] = record
        touch(identity)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: recordURL(for: identity), options: .atomic)
    }

    func removeMemoryEntries() {
        memory.removeAll(keepingCapacity: false)
        memoryOrder.removeAll(keepingCapacity: false)
    }

    public func memoryEntryCount() -> Int { memory.count }

    private func touch(_ identity: String) {
        memoryOrder.removeAll { $0 == identity }
        memoryOrder.append(identity)
        while memoryOrder.count > maximumMemoryEntries {
            memory.removeValue(forKey: memoryOrder.removeFirst())
        }
    }

    private func recordURL(for identity: String) -> URL {
        rootURL.appendingPathComponent("\(Self.fnv1a(identity)).frame.json")
    }

    private static func fnv1a(_ value: String) -> String {
        let hash = value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct DetectedScene: Hashable, Sendable {
    let startTime: Double
    let endTime: Double
    let boundaryConfidence: Double
    let motionScore: Double
    let representativeTimestamp: Double
}

struct SceneDetector: Sendable {
    func detect(samples: [VisualFrameSample], duration: Double, sensitivity: Double) -> [DetectedScene] {
        guard duration > 0 else { return [] }
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        guard !ordered.isEmpty else {
            return [DetectedScene(startTime: 0, endTime: duration, boundaryConfidence: 0, motionScore: 0, representativeTimestamp: duration / 2)]
        }

        let threshold = min(0.85, max(0.22, sensitivity))
        let maximumSceneDuration = threshold >= 0.55 ? 60.0 : threshold >= 0.45 ? 45.0 : threshold >= 0.39 ? 30.0 : 20.0
        var boundaries: [(time: Double, confidence: Double)] = [(0, 1)]
        var lastBoundary = 0.0
        for index in ordered.indices where index > 0 {
            let previous = ordered[index - 1]
            let current = ordered[index]
            let histogramChange = Self.histogramDistance(previous.histogram, current.histogram)
            let semanticChange = Self.jaccardDistance(previous.labels, current.labels)
            let score = min(1, histogramChange * 0.58 + semanticChange * 0.24 + current.motion * 0.18)
            let midpoint = (previous.timestamp + current.timestamp) / 2
            let forced = midpoint - lastBoundary >= maximumSceneDuration
            guard (score >= threshold || forced), midpoint - lastBoundary >= 1.5 else { continue }
            boundaries.append((midpoint, forced ? max(0.35, score) : score))
            lastBoundary = midpoint
        }
        if duration - lastBoundary > maximumSceneDuration {
            var time = lastBoundary + maximumSceneDuration
            while duration - time >= 1.5 {
                boundaries.append((time, 0.35))
                time += maximumSceneDuration
            }
        }

        var scenes: [DetectedScene] = []
        for index in boundaries.indices {
            let start = boundaries[index].time
            let end = index + 1 < boundaries.count ? boundaries[index + 1].time : duration
            guard end - start >= 0.2 else { continue }
            let members = ordered.filter { $0.timestamp >= start && $0.timestamp < end }
            let representative = members.max(by: { $0.interest < $1.interest })?.timestamp ?? (start + end) / 2
            let motion = members.isEmpty ? 0 : members.map(\.motion).reduce(0, +) / Double(members.count)
            scenes.append(DetectedScene(
                startTime: start,
                endTime: end,
                boundaryConfidence: boundaries[index].confidence,
                motionScore: motion,
                representativeTimestamp: representative
            ))
        }
        return scenes
    }

    private static func histogramDistance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        return min(1, zip(lhs, rhs).reduce(0) { $0 + abs($1.0 - $1.1) } / 2)
    }

    private static func jaccardDistance(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 0 }
        let union = lhs.union(rhs).count
        guard union > 0 else { return 0 }
        return 1 - Double(lhs.intersection(rhs).count) / Double(union)
    }
}
