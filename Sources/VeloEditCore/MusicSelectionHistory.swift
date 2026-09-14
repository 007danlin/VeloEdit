import Foundation

/// A provider-stable identity used to rotate soundtracks between projects.
/// Local UUIDs are not sufficient for online tracks because every project has
/// its own music library and may import the same provider track under a new URL.
extension LocalMusicTrack {
    public var selectionIdentity: String {
        Self.selectionIdentity(sourceProvider: sourceProvider, providerTrackID: providerTrackID, localID: id)
    }

    fileprivate static func selectionIdentity(
        sourceProvider: MusicSourceProvider,
        providerTrackID: String?,
        localID: UUID
    ) -> String {
        let sourceID = providerTrackID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableID = sourceID.flatMap { $0.isEmpty ? nil : $0 } ?? localID.uuidString
        return "\(sourceProvider.rawValue):\(stableID.lowercased())"
    }
}

extension MusicProviderTrack {
    public var selectionIdentity: String {
        "\(sourceProvider.rawValue):\(id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
}

public struct RecentMusicSelection: Codable, Hashable, Sendable {
    public var identity: String
    public var title: String
    public var artist: String
    public var selectedAt: Date

    public init(identity: String, title: String, artist: String, selectedAt: Date) {
        self.identity = identity
        self.title = title
        self.artist = artist
        self.selectedAt = selectedAt
    }
}

/// Device-local, path-free soundtrack history. It stores only provider IDs and
/// display metadata, never audio files or project/media identifiers.
public actor LocalMusicSelectionHistoryStore {
    public static let shared = LocalMusicSelectionHistoryStore()

    public let url: URL
    private let maximumEntryCount: Int
    private var cached: [RecentMusicSelection]?

    public init(
        url: URL = LocalMusicSelectionHistoryStore.defaultURL,
        maximumEntryCount: Int = 24
    ) {
        self.url = url
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("VeloEdit", isDirectory: true)
            .appendingPathComponent("recent-music-v1.json")
    }

    public func recentSelections() -> [RecentMusicSelection] {
        load()
    }

    public func recentIdentities() -> Set<String> {
        Set(load().flatMap { [$0.identity, MusicRecordingIdentity.key(title: $0.title, artist: $0.artist)] })
    }

    public func record(_ track: LocalMusicTrack, selectedAt: Date = Date()) throws {
        var entries = load()
        entries.removeAll { $0.identity == track.selectionIdentity }
        entries.append(RecentMusicSelection(
            identity: track.selectionIdentity,
            title: track.title,
            artist: track.author,
            selectedAt: selectedAt
        ))
        if entries.count > maximumEntryCount {
            entries.removeFirst(entries.count - maximumEntryCount)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.veloEdit.encode(entries).write(to: url, options: .atomic)
        cached = entries
    }

    private func load() -> [RecentMusicSelection] {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.veloEdit.decode([RecentMusicSelection].self, from: data) else {
            cached = []
            return []
        }
        let bounded = Array(decoded.suffix(maximumEntryCount))
        cached = bounded
        return bounded
    }
}

/// Also catches the same recording indexed by two different services.
enum MusicRecordingIdentity {
    static func key(title: String, artist: String) -> String {
        "recording:" + MusicSearchRequest.words(title).sorted().joined(separator: " ") + "|" + MusicSearchRequest.words(artist).sorted().joined(separator: " ")
    }
}

extension MusicProviderTrack {
    var noveltyIdentities: Set<String> { [selectionIdentity, MusicRecordingIdentity.key(title: metadata.title, artist: metadata.artist)] }
}

extension LocalMusicTrack {
    var noveltyIdentities: Set<String> { [selectionIdentity, MusicRecordingIdentity.key(title: title, artist: author)] }
}
