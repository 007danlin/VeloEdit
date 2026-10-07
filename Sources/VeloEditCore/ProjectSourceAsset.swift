import Foundation

/// Compact source identities let the library deduplicate media across projects
/// without reopening camera files or decoding cached analysis on every refresh.
public struct ProjectSourceAsset: Codable, Equatable, Sendable {
    public var identity: String
    public var fullIdentity: String?
    public var duration: Double

    public init?(asset: MediaAsset) {
        guard BackgroundPreset.preset(for: asset) == nil else { return nil }
        let prefix = "\(asset.kind.rawValue):\(asset.byteSize):"
        let hash = asset.contentHash.trimmingCharacters(in: .whitespacesAndNewlines)
        identity = hash.isEmpty ? "asset:\(asset.id.uuidString)" : prefix + hash
        fullIdentity = asset.fullContentHash.flatMap { $0.isEmpty ? nil : "sha256:" + prefix + $0 }
        let seconds = asset.metadata.duration ?? 0
        duration = asset.kind == .video && seconds.isFinite ? max(0, seconds) : 0
    }

    /// Full hashes, when available, also join copies whose fast fingerprint
    /// changed with the file timestamp. Keep the fast identity as an alias for
    /// projects that have not run the optional integrity check.
    public static func uniqueDurations(_ sources: [Self]) -> [String: Double] {
        var fullIdentities: [String: Set<String>] = [:]
        for source in sources {
            if let fullIdentity = source.fullIdentity {
                fullIdentities[source.identity, default: []].insert(fullIdentity)
            }
        }
        var durations: [String: Double] = [:]
        for source in sources {
            let knownFull = fullIdentities[source.identity]
            let identity = source.fullIdentity
                ?? (knownFull?.count == 1 ? knownFull?.first : nil)
                ?? source.identity
            let duration = source.duration.isFinite ? max(0, source.duration) : 0
            // Missing/stale metadata in one project must not hide a known
            // source duration, and the result must not depend on scan order.
            durations[identity] = max(durations[identity] ?? 0, duration)
        }
        return durations
    }
}
