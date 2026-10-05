import Foundation
import CryptoKit
import Darwin
import CoreMedia

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
    public var requestedTimestamp: Double
    public var representation: String
    public var decodeTimeScale: Int32?

    public init(sourceFile: String, timestamp: Double, resolution: Int, processingPurpose: FrameProcessingPurpose,
                representation: String = "preferred-transform|tol=150/600|jpeg=.68|vision-v2", decodeTimeScale: Int32? = nil) {
        self.sourceFile = sourceFile
        requestedTimestamp = max(0, timestamp)
        timestampMilliseconds = Int((requestedTimestamp * 1_000).rounded())
        self.resolution = max(1, resolution)
        self.processingPurpose = processingPurpose
        self.representation = representation
        self.decodeTimeScale = decodeTimeScale
    }

    var canonicalIdentity: String {
        // A supplied timescale describes the actual decoder request, not an
        // approximate temporal bucket. Preserve the caller's original time in
        // its sample/trace while sharing identical AVFoundation CMTime inputs.
        let time: String
        if let scale = decodeTimeScale {
            let value = CMTime(seconds: requestedTimestamp, preferredTimescale: scale)
            time = "cm:\(value.value)/\(value.timescale):\(value.epoch)"
        } else { time = "bits:\(requestedTimestamp.bitPattern)" }
        return "v2|\(sourceFile.utf8.count):\(sourceFile)|\(time)|\(resolution)|\(representation)"
    }

    static func sourceIdentity(url: URL, contentHash: String) -> String {
        var info = stat()
        guard url.resolvingSymlinksInPath().withUnsafeFileSystemRepresentation({ path in path.map { lstat($0, &info) } ?? -1 }) == 0 else {
            // Missing/unreadable input must not reuse an older file's frames.
            return "unavailable:\(UUID().uuidString)"
        }
        return "\(contentHash)|\(url.standardizedFileURL.path)|\(info.st_dev):\(info.st_ino):\(info.st_size)|\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
}

private struct PersistedFrameRecord: Codable, Sendable {
    var identity: String
    var sample: VisualFrameSample
    var jpeg: Data?
}

struct CachedFrame: Sendable {
    enum Origin: String, Sendable { case computed, memory, disk, shared }
    var sample: VisualFrameSample
    var origin: Origin
}

public actor FrameCache {
    private let rootURL: URL
    private let maximumMemoryEntries: Int
    private let maximumMemoryBytes: Int
    private var memory: [String: VisualFrameSample] = [:]
    private var memoryOrder: [String] = []
    private var memoryBytes = 0
    private var reservedProducerBytes = 0
    private var producerReservations: [String: Int] = [:]
    private var admissionWaiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight: [String: (id: UUID, task: Task<VisualFrameSample, Error>)] = [:]

    public init(rootURL: URL, maximumMemoryEntries: Int = 384, maximumMemoryBytes: Int = 96 * 1_024 * 1_024) {
        self.rootURL = rootURL
        self.maximumMemoryEntries = max(1, maximumMemoryEntries)
        self.maximumMemoryBytes = max(0, maximumMemoryBytes)
    }

    func value(for key: FrameCacheKey) -> VisualFrameSample? { lookup(key)?.sample }

    private func lookup(_ key: FrameCacheKey) -> CachedFrame? {
        let identity = key.canonicalIdentity
        if let sample = memory[identity] {
            touch(identity)
            return CachedFrame(sample: sample, origin: .memory)
        }
        // v1 JSON deliberately misses: it lacks source representation and PTS.
        guard let data = try? Data(contentsOf: recordURL(for: identity)), data.count > 32 else { return nil }
        let payload = Data(data.dropFirst(32))
        guard Data(SHA256.hash(data: payload)) == data.prefix(32),
              let record = try? PropertyListDecoder().decode(PersistedFrameRecord.self, from: payload),
              record.identity == identity else { return nil }
        var sample = record.sample
        if let jpeg = record.jpeg { sample.jpegBase64 = jpeg.base64EncodedString() }
        insert(sample, identity: identity)
        return CachedFrame(sample: sample, origin: .disk)
    }

    /// One producer per exact key. A cancelled waiter never cancels another
    /// consumer's work. Only a completed, successful producer enters the cache.
    func resolve(_ key: FrameCacheKey, produce: @escaping @Sendable () async throws -> VisualFrameSample) async throws -> CachedFrame {
        try Task.checkCancellation()
        let identity = key.canonicalIdentity
        // Reserve decoded RGBA plus conversion workspace, not just retained
        // JPEG entries. A single oversized frame may run alone; never fan out
        // unbounded decode work when many consumers request different frames.
        let reservation = min(max(1, maximumMemoryBytes), Int(min(Double(Int.max / 2), max(131_072, Double(key.resolution) * Double(key.resolution) * 8))))
        while true {
            try Task.checkCancellation()
            if let hit = lookup(key) { return hit }
            if inFlight[identity] != nil { break }
            if inFlight.isEmpty || (inFlight.count < 2 && reservedProducerBytes + reservation <= maximumMemoryBytes) { break }
            await withCheckedContinuation { admissionWaiters.append($0) }
        }
        let work: (id: UUID, task: Task<VisualFrameSample, Error>)
        let origin: CachedFrame.Origin
        if let existing = inFlight[identity] {
            work = existing
            origin = .shared
        } else {
            reservedProducerBytes += reservation
            producerReservations[identity] = reservation
            trimMemory()
            work = (UUID(), Task { try await produce() })
            inFlight[identity] = work
            origin = .computed
        }
        do {
            let sample = try await work.task.value
            if inFlight[identity]?.id == work.id {
                releaseProducer(identity)
                try? store(sample, for: key)
            }
            try Task.checkCancellation()
            return CachedFrame(sample: sample, origin: origin)
        } catch {
            if inFlight[identity]?.id == work.id { releaseProducer(identity) }
            throw error
        }
    }

    private func releaseProducer(_ identity: String) {
        inFlight.removeValue(forKey: identity)
        reservedProducerBytes -= producerReservations.removeValue(forKey: identity) ?? 0
        let waiters = admissionWaiters
        admissionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func store(_ sample: VisualFrameSample, for key: FrameCacheKey) throws {
        let identity = key.canonicalIdentity
        // Motion belongs to the caller's ordered sequence, never to this frame.
        var features = sample.withMotion(0)
        insert(features, identity: identity)
        let jpeg = Data(base64Encoded: features.jpegBase64)
        if jpeg != nil { features.jpegBase64 = "" }
        let record = PersistedFrameRecord(identity: identity, sample: features, jpeg: jpeg)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payload = try encoder.encode(record)
        var data = Data(SHA256.hash(data: payload))
        data.append(payload)
        try data.write(to: recordURL(for: identity), options: .atomic)
    }

    func removeMemoryEntries() {
        memory.removeAll(keepingCapacity: false)
        memoryOrder.removeAll(keepingCapacity: false)
        memoryBytes = 0
    }

    public func memoryEntryCount() -> Int { memory.count }
    public func memoryByteCount() -> Int { memoryBytes }

    private func insert(_ sample: VisualFrameSample, identity: String) {
        if let old = memory.removeValue(forKey: identity) { memoryBytes -= cost(old) }
        memory[identity] = sample
        memoryBytes += cost(sample)
        touch(identity)
    }

    private func cost(_ sample: VisualFrameSample) -> Int {
        sample.jpegBase64.utf8.count + sample.luminanceFingerprint.count + sample.histogram.count * 8
            + sample.labels.reduce(0) { $0 + $1.utf8.count + 64 } + (sample.subjects?.count ?? 0) * 256 + 1_024
    }

    private func touch(_ identity: String) {
        memoryOrder.removeAll { $0 == identity }
        memoryOrder.append(identity)
        trimMemory()
    }

    private func trimMemory() {
        while !memoryOrder.isEmpty && (memoryOrder.count > maximumMemoryEntries || memoryBytes > max(0, maximumMemoryBytes - reservedProducerBytes)) {
            let evicted = memoryOrder.removeFirst()
            if let old = memory.removeValue(forKey: evicted) { memoryBytes -= cost(old) }
        }
    }

    private func recordURL(for identity: String) -> URL {
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return rootURL.appendingPathComponent("\(hash).frame-v2.bin")
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
