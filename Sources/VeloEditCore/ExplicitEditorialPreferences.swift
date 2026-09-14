import Foundation

public enum EditorialPreferenceAspect: String, Codable, CaseIterable, Sendable {
    case music, pacing, titles
    public var title: String { switch self { case .music: "Музыка"; case .pacing: "Темп"; case .titles: "Титры" } }
}

public enum EditorialPreferenceScope: String, Codable, Sendable { case film, mood, track }

/// Only an explicit UI/command action can create these signals. Export,
/// automatic selection, failed downloads and closing a preview are not votes.
public struct ExplicitEditorialPreference: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var createdAt: Date = Date()
    public var aspect: EditorialPreferenceAspect
    public var scope: EditorialPreferenceScope
    public var projectID: UUID
    public var timelineID: UUID
    public var revision: String
    public var style: MusicStyle
    public var trackIdentity: String?
    public var recordingIdentity: String?
    public var character: [String]
    public var value: Double
    public var excluded: Bool
    public var label: String
    public var origin: String = "explicit-user"

    public init(aspect: EditorialPreferenceAspect, scope: EditorialPreferenceScope, projectID: UUID,
                timeline: Timeline, track: LocalMusicTrack?, value: Double = 1, excluded: Bool = false) {
        self.aspect = aspect; self.scope = scope; self.projectID = projectID; timelineID = timeline.id
        revision = EditorialRenderSignature.signature(timeline)
        style = timeline.music?.style ?? .cinematic
        trackIdentity = track?.selectionIdentity
        recordingIdentity = track.map { MusicRecordingIdentity.key(title: $0.title, artist: $0.author) }
        character = (track?.genres ?? []) + (track?.moods ?? [])
        self.value = value; self.excluded = excluded
        label = aspect == .music ? track?.title ?? "Музыка" : aspect.title
    }
}

public struct ExplicitEditorialPreferenceSnapshot: Codable, Hashable, Sendable {
    public var schemaVersion: Int = 1
    public var signals: [ExplicitEditorialPreference] = []

    public func excludes(_ track: LocalMusicTrack) -> Bool {
        signals.contains { $0.excluded && $0.scope == .track &&
            ($0.trackIdentity == track.selectionIdentity || $0.recordingIdentity == MusicRecordingIdentity.key(title: track.title, artist: track.author)) }
    }

    public var excludedIdentities: Set<String> {
        Set(signals.filter { $0.excluded && $0.scope == .track }.flatMap { [$0.trackIdentity, $0.recordingIdentity].compactMap { $0 } })
    }

    public func musicAdjustment(_ track: LocalMusicTrack, style: MusicStyle, projectID: UUID? = nil) -> Double {
        musicAdjustment(identity: track.selectionIdentity, title: track.title, artist: track.author,
            character: track.genres + track.moods, style: style, projectID: projectID)
    }

    public func musicAdjustment(_ track: MusicProviderTrack, style: MusicStyle) -> Double {
        musicAdjustment(identity: track.selectionIdentity, title: track.metadata.title, artist: track.metadata.artist,
            character: track.metadata.genres + track.metadata.moods, style: style)
    }

    private func musicAdjustment(identity: String, title: String, artist: String, character: [String], style: MusicStyle, projectID: UUID? = nil) -> Double {
        let tokens = Set(character)
        let applicable = signals.filter { $0.aspect == .music && !$0.excluded &&
            ($0.scope == .track || $0.style == style) && ($0.scope != .film || $0.projectID == projectID) }
        return max(-0.3, min(0.3, applicable.reduce(0) { sum, signal in
            let exact = signal.trackIdentity == identity || signal.recordingIdentity == MusicRecordingIdentity.key(title: title, artist: artist)
            let shared = Double(tokens.intersection(signal.character).count) / Double(max(1, Set(signal.character).count))
            return sum + signal.value * (exact ? 0.16 : signal.scope == .mood ? shared * 0.08 : 0)
        }))
    }

    public func preferredValue(_ aspect: EditorialPreferenceAspect, style: MusicStyle) -> Double? {
        signals.last { $0.aspect == aspect && $0.style == style && $0.scope == .mood }?.value
    }
}

public actor ExplicitEditorialPreferenceStore {
    public static let shared = ExplicitEditorialPreferenceStore()
    public let url: URL
    public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("VeloEdit/explicit-editorial-preferences-v1.json")) { self.url = url }

    public func snapshot() -> ExplicitEditorialPreferenceSnapshot {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder.veloEdit.decode(ExplicitEditorialPreferenceSnapshot.self, from: data) else { return .init() }
        return value
    }

    public func record(_ signals: [ExplicitEditorialPreference]) throws {
        var value = snapshot()
        for signal in signals where signal.origin == "explicit-user" {
            value.signals.removeAll { $0.id == signal.id || ($0.projectID == signal.projectID && $0.revision == signal.revision && $0.aspect == signal.aspect && $0.scope == signal.scope && $0.excluded == signal.excluded) }
            value.signals.append(signal)
        }
        try write(value)
    }

    public func remove(ids: Set<UUID>) throws {
        var value = snapshot(); value.signals.removeAll { ids.contains($0.id) }; try write(value)
    }

    private func write(_ value: ExplicitEditorialPreferenceSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.veloEdit.encode(value).write(to: url, options: .atomic)
    }
}
