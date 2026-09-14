import Foundation

public enum OpenverseMusicError: LocalizedError {
    case invalidResponse
    case noCompatibleTrack
    case invalidDownloadURL
    case downloadFailed

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Openverse вернул некорректный ответ."
        case .noCompatibleTrack: return "В Openverse нет подходящего трека с проверяемой лицензией."
        case .invalidDownloadURL: return "Openverse вернул небезопасный адрес аудиофайла."
        case .downloadFailed: return "Не удалось скачать трек из Openverse."
        }
    }
}

public actor OpenverseMusicProvider: MusicProvider {
    public nonisolated let identifier = "openverse"
    public nonisolated let sourceProvider: MusicSourceProvider = .openverse
    public nonisolated let fallbackTier = 2
    public nonisolated let priority = 100

    private struct SearchResponse: Decodable {
        var results: [RemoteTrack]
    }

    private struct RemoteTag: Decodable {
        var name: String
    }

    private struct RemoteTrack: Decodable {
        var id: String
        var title: String?
        var creator: String?
        var url: URL?
        var foreignLandingURL: URL?
        var license: String
        var licenseVersion: String?
        var licenseURL: URL?
        var attribution: String?
        var duration: Double?
        var genres: [String]?
        var tags: [RemoteTag]?
        var source: String?
        var provider: String?
        var category: String?

        enum CodingKeys: String, CodingKey {
            case id, title, creator, url, license, attribution, duration, genres, tags, source, provider, category
            case foreignLandingURL = "foreign_landing_url"
            case licenseVersion = "license_version"
            case licenseURL = "license_url"
        }
    }

    public static let apiBaseURL = URL(string: "https://api.openverse.org/v1/audio/")!
    // BY-SA is intentionally excluded: applying ShareAlike to a finished
    // client video is an unnecessary licensing burden. CC0/PDM require no
    // credit; CC BY remains usable because VeloEdit persists attribution.
    private static let allowedLicenses: Set<String> = ["cc0", "pdm", "by"]
    private static let searchTimeout: TimeInterval = 7
    private static let downloadTimeout: TimeInterval = 60

    private let library: LocalMusicLibrary
    private let session: URLSession

    public init(library: LocalMusicLibrary, session: URLSession? = nil) {
        self.library = library
        self.session = session ?? MusicAudioDownloader.makeSession()
    }

    public func availability() async -> MusicProviderAvailability { .available }

    public func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack] {
        guard let url = Self.searchURL(for: intent) else { throw OpenverseMusicError.invalidResponse }
        let data = try await MusicHTTPClient.data(at: url, session: session, timeout: Self.searchTimeout)
        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else { throw OpenverseMusicError.invalidResponse }
        let candidates = decoded.results.compactMap { Self.candidate($0, intent: intent) }
        return candidates
    }

    /// Anonymous Openverse clients are limited to 20 results per page. Keeping
    /// URL construction separate makes that production constraint testable.
    nonisolated static func searchURL(for intent: MusicIntent) -> URL? {
        var components = URLComponents(url: Self.apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: Self.searchQuery(for: intent)),
            URLQueryItem(name: "categories", value: "music"),
            URLQueryItem(name: "license", value: Self.allowedLicenses.sorted().joined(separator: ",")),
            URLQueryItem(name: "page_size", value: "20")
        ]
        return components.url
    }

    public func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack {
        guard track.sourceProvider == .openverse else { throw OpenverseMusicError.invalidDownloadURL }
        return try await MusicAudioDownloader.download(track, into: library, session: session)
    }

    public func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata { track.metadata }
    public func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord { track.license }

    private nonisolated static func candidate(_ remote: RemoteTrack, intent: MusicIntent) -> MusicProviderTrack? {
        let licenseCode = remote.license.lowercased()
        guard allowedLicenses.contains(licenseCode),
              let downloadURL = remote.url,
              downloadURL.scheme?.lowercased() == "https",
              let rawLicenseURL = remote.licenseURL,
              let licenseURL = InternetArchiveMusicProvider.allowedLicense(rawLicenseURL.absoluteString) else { return nil }
        let title = remote.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = remote.creator?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let artist, !artist.isEmpty, artist.lowercased() != "unknown" else { return nil }
        let tags = remote.tags?.map(\.name) ?? []
        let duration: Double = {
            guard let value = remote.duration, value.isFinite, value > 0 else {
                return (intent.durationRange.lowerBound + intent.durationRange.upperBound) / 2
            }
            // The API contract uses milliseconds, including short clips.
            return value / 1_000
        }()
        guard duration >= 45 else { return nil }
        let attributionRequired = !["cc0", "pdm"].contains(licenseCode)
        let licenseName = "Creative Commons \(licenseCode.uppercased()) \(remote.licenseVersion ?? "")"
            .trimmingCharacters(in: .whitespaces)
        let sourcePageURL = remote.foreignLandingURL ?? downloadURL
        let attribution = attributionRequired
            ? (remote.attribution ?? "\(title ?? "Untitled") — \(artist) (\(licenseName)); \(sourcePageURL.absoluteString)")
            : nil
        let checkedAt = Date()
        let license = MusicLicenseRecord(
            name: licenseName,
            url: licenseURL,
            downloadedAt: checkedAt,
            attributionText: attribution,
            usageRestrictions: attributionRequired ? "Требуется сохранить указанную атрибуцию CC BY в титрах или описании ролика." : nil,
            sourceName: remote.source ?? remote.provider ?? "Openverse",
            sourceURL: sourcePageURL,
            licenseCheckedAt: checkedAt,
            requiresAttribution: attributionRequired
        )
        let metadata = MusicTrackMetadata(
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Openverse track",
            artist: artist,
            genres: remote.genres ?? [remote.category].compactMap { $0 },
            moods: tags,
            tags: tags,
            energy: intent.energy,
            bpm: (intent.bpmRange.lowerBound + intent.bpmRange.upperBound) / 2,
            duration: duration,
            sourceName: remote.source ?? remote.provider ?? "Openverse",
            instrumental: intent.instrumentalPreferred
        )
        return MusicProviderTrack(
            id: remote.id,
            sourceProvider: .openverse,
            metadata: metadata,
            license: license,
            sourcePageURL: sourcePageURL,
            downloadURL: downloadURL
        )
    }

    private nonisolated static func searchQuery(for intent: MusicIntent) -> String {
        if let request = intent.request { return request.query }
        let genre = intent.genres.sorted().first
        let mood = intent.mood.sorted().first
        return ["instrumental", genre ?? mood ?? "music"].joined(separator: " ")
    }
}
