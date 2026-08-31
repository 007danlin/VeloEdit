import Foundation

private struct BundledMusicManifest: Decodable {
    var tracks: [BundledMusicEntry]
}

private struct BundledMusicEntry: Decodable {
    var id: String
    var file: String
    var title: String
    var artist: String
    var genres: [String]
    var moods: [String]
    var tags: [String]
    var energy: Double
    var bpm: Double
    var duration: Double
    var source: String
    var sourceURL: String
    var license: String
    var licenseURL: String
    var attribution: String?
    var licenseCheckedAt: String
    var instrumental: Bool?
}

public actor BundledMusicProvider: MusicProvider {
    public nonisolated let identifier = "bundled"
    public nonisolated let sourceProvider: MusicSourceProvider = .bundled
    public nonisolated let priority = 0

    private let library: LocalMusicLibrary
    private let rootURL: URL?
    private var cachedCatalog: [MusicProviderTrack]?

    public init(library: LocalMusicLibrary, rootURL: URL? = nil) {
        self.library = library
        self.rootURL = rootURL ?? Self.defaultRootURL()
    }

    public func availability() async -> MusicProviderAvailability {
        guard let rootURL,
              FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("manifest.json").path) else {
            return .unavailable(reason: "встроенный каталог не найден")
        }
        return .available
    }

    public func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack] {
        if let cachedCatalog { return cachedCatalog }
        guard let rootURL else { return [] }
        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(BundledMusicManifest.self, from: data)
        let catalog = manifest.tracks.compactMap { entry -> MusicProviderTrack? in
            let fileURL = rootURL.appendingPathComponent(entry.file)
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let sourceURL = URL(string: entry.sourceURL),
                  let licenseURL = URL(string: entry.licenseURL) else { return nil }
            let checkedAt = ISO8601DateFormatter().date(from: entry.licenseCheckedAt)
            let metadata = MusicTrackMetadata(
                title: entry.title,
                artist: entry.artist,
                genres: entry.genres,
                moods: entry.moods,
                tags: entry.tags,
                energy: entry.energy,
                bpm: entry.bpm,
                duration: entry.duration,
                sourceName: entry.source,
                instrumental: entry.instrumental ?? true
            )
            let license = MusicLicenseRecord(
                name: entry.license,
                url: licenseURL,
                attributionText: entry.attribution,
                usageRestrictions: entry.license.lowercased().contains("cc0")
                    ? "CC0 1.0 Universal: атрибуция не требуется; разрешены использование, изменение и распространение в пределах применимого законодательства."
                    : "Использование определяется лицензией, указанной в каталоге.",
                sourceName: entry.source,
                sourceURL: sourceURL,
                licenseCheckedAt: checkedAt,
                requiresAttribution: !entry.license.lowercased().contains("cc0") && entry.attribution?.isEmpty == false
            )
            return MusicProviderTrack(
                id: entry.id,
                sourceProvider: .bundled,
                metadata: metadata,
                license: license,
                sourcePageURL: sourceURL,
                localFileURL: fileURL
            )
        }
        cachedCatalog = catalog
        return catalog
    }

    public func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack {
        guard track.sourceProvider == .bundled, let fileURL = track.localFileURL else {
            throw MusicLibraryError.unreadableAudio
        }
        return try await library.importProviderTrack(track, downloadedFileURL: fileURL)
    }

    public func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata { track.metadata }
    public func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord { track.license }

    private nonisolated static func defaultRootURL() -> URL? {
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("Music", isDirectory: true))
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Resources/Music", isDirectory: true)
        )
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }
    }
}

public actor LocalMusicProvider: MusicProvider {
    public nonisolated let identifier = "local"
    public nonisolated let sourceProvider: MusicSourceProvider = .user
    public nonisolated let priority = 10

    private let library: LocalMusicLibrary

    public init(library: LocalMusicLibrary) {
        self.library = library
    }

    public func availability() async -> MusicProviderAvailability { .available }

    public func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack] {
        try await library.tracks()
            .filter { $0.sourceProvider == .user && $0.isPlayable }
            .map(Self.candidate)
    }

    public func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack {
        guard let existing = try await library.tracks().first(where: {
            ($0.providerTrackID ?? $0.id.uuidString) == track.id && $0.isPlayable
        }) else { throw MusicLibraryError.unreadableAudio }
        return existing
    }

    public func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata { track.metadata }
    public func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord { track.license }

    private nonisolated static func candidate(_ track: LocalMusicTrack) -> MusicProviderTrack {
        MusicProviderTrack(
            id: track.providerTrackID ?? track.id.uuidString,
            sourceProvider: .user,
            metadata: MusicTrackMetadata(
                title: track.title,
                artist: track.author,
                genres: track.genres,
                moods: track.moods,
                tags: track.tags ?? [],
                energy: track.energy,
                bpm: track.bpm,
                duration: track.duration,
                sourceName: "My Music",
                loudness: track.loudness,
                waveform: track.waveform,
                musicalKey: track.musicalKey
            ),
            license: track.license,
            sourcePageURL: track.sourcePageURL,
            localFileURL: track.localFileURL
        )
    }
}
