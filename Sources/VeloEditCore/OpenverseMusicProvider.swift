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
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = Self.searchTimeout
            configuration.timeoutIntervalForResource = Self.downloadTimeout
            self.session = URLSession(configuration: configuration)
        }
    }

    public func availability() async -> MusicProviderAvailability { .available }

    public func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack] {
        var components = URLComponents(url: Self.apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: Self.searchQuery(for: intent)),
            URLQueryItem(name: "categories", value: "music"),
            URLQueryItem(name: "license", value: Self.allowedLicenses.sorted().joined(separator: ",")),
            URLQueryItem(name: "page_size", value: "50")
        ]
        guard let url = components.url else { throw OpenverseMusicError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.searchTimeout
        request.setValue("VeloEdit/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            throw OpenverseMusicError.invalidResponse
        }
        let candidates = decoded.results.compactMap { Self.candidate($0, intent: intent) }
        guard !candidates.isEmpty else { throw OpenverseMusicError.noCompatibleTrack }
        return candidates
    }

    public func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack {
        if let existing = try await library.tracks().first(where: {
            $0.sourceProvider == .openverse && $0.providerTrackID == track.id && $0.isPlayable
        }) { return existing }
        guard track.sourceProvider == .openverse,
              let audioURL = track.downloadURL,
              audioURL.scheme?.lowercased() == "https",
              audioURL.host?.isEmpty == false else {
            throw OpenverseMusicError.invalidDownloadURL
        }
        var request = URLRequest(url: audioURL)
        request.timeoutInterval = Self.downloadTimeout
        request.setValue("VeloEdit/1.0", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenverseMusicError.downloadFailed
        }
        let allowedExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg"]
        let remoteExtension = audioURL.pathExtension.lowercased()
        let fileExtension = allowedExtensions.contains(remoteExtension) ? remoteExtension : "mp3"
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("veloedit-openverse-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        try FileManager.default.copyItem(at: temporaryURL, to: stagedURL)
        return try await library.importProviderTrack(track, downloadedFileURL: stagedURL)
    }

    public func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata { track.metadata }
    public func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord { track.license }

    private nonisolated static func candidate(_ remote: RemoteTrack, intent: MusicIntent) -> MusicProviderTrack? {
        let licenseCode = remote.license.lowercased()
        guard allowedLicenses.contains(licenseCode),
              let downloadURL = remote.url,
              downloadURL.scheme?.lowercased() == "https",
              let licenseURL = remote.licenseURL else { return nil }
        let title = remote.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = remote.creator?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let artist, !artist.isEmpty, artist.lowercased() != "unknown" else { return nil }
        let tags = remote.tags?.map(\.name) ?? []
        let duration: Double = {
            guard let value = remote.duration, value.isFinite, value > 0 else {
                return (intent.durationRange.lowerBound + intent.durationRange.upperBound) / 2
            }
            // Openverse documents duration in milliseconds. A few upstream
            // sources historically sent seconds, so accept both representations.
            return value > 10_000 ? value / 1_000 : value
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
            moods: Array(intent.mood),
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
        let genre = intent.genres.sorted().first
        let mood = intent.mood.sorted().first
        return ["instrumental", genre ?? mood ?? "music"].joined(separator: " ")
    }
}
