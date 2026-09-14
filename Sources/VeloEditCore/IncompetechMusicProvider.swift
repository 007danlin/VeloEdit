import Foundation

/// Official machine-readable catalogue and direct MP3s, documented at
/// https://incompetech.com/agent-section/ . No account or API key is needed.
public actor IncompetechMusicProvider: MusicProvider {
    public nonisolated let identifier = "incompetech"
    public nonisolated let sourceProvider: MusicSourceProvider = .incompetech
    public nonisolated let priority = 105
    private let library: LocalMusicLibrary
    private let session: URLSession
    private var cached: (date: Date, tracks: [MusicProviderTrack])?
    static let baseURL = URL(string: "https://incompetech.com/music/royalty-free/")!

    public init(library: LocalMusicLibrary, session: URLSession? = nil) {
        self.library = library
        self.session = session ?? MusicAudioDownloader.makeSession()
    }

    public func availability() async -> MusicProviderAvailability { .available }

    public func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack] {
        if let cached, Date().timeIntervalSince(cached.date) < 21_600 { return cached.tracks }
        async let pieces = MusicHTTPClient.data(at: Self.baseURL.appendingPathComponent("pieces.json"), session: session)
        async let genres = try? MusicHTTPClient.data(at: Self.baseURL.appendingPathComponent("genre.json"), session: session)
        do {
            let tracks = try await Self.candidates(data: pieces, genreData: genres)
            guard !tracks.isEmpty else { throw URLError(.cannotParseResponse) }
            cached = (Date(), tracks)
            // Rank against the complete catalogue in MusicLibrary. This also
            // lets novelty exclusions reach beyond a provider's first page.
            return tracks
        } catch {
            if !Task.isCancelled, let cached { return cached.tracks }
            throw error
        }
    }

    static func candidates(data: Data, genreData: Data? = nil) throws -> [MusicProviderTrack] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        let genreRows = genreData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        var genres: [String: String] = [:]
        for row in genreRows {
            if let id = row["id"], let genre = row["genre"] as? String { genres[String(describing: id)] = genre.lowercased() }
        }
        let licenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
        return rows.compactMap { row in
            func text(_ key: String) -> String { (row[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let title = text("title"), filename = text("filename"), isrc = text("isrc")
            let id = isrc.isEmpty ? text("uuid") : isrc
            guard !id.isEmpty, !title.isEmpty, filename.lowercased().hasSuffix(".mp3"),
                  !filename.contains("/"), !filename.contains("\\"), !filename.contains("..") else { return nil }
            let parts = text("length").split(separator: ":")
            let numbers = parts.compactMap { Double($0) }
            guard numbers.count == parts.count, !numbers.isEmpty else { return nil }
            let duration = numbers.reduce(0) { $0 * 60 + $1 }
            guard duration.isFinite, (45...1_800).contains(duration) else { return nil }
            let description = text("feel") + " " + text("instruments") + " " + text("description")
            var tags = MusicSearchRequest.positiveDescriptorWords(description)
            let genre = genres[text("genre")] ?? "soundtrack"
            let declared = AutomaticSoundtrackSuitability.descriptiveTokens([genre, text("feel")])
            tags.formUnion(declared)
            let bpm = Double(text("bpm")).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 100
            let energy = !declared.isDisjoint(with: ["calm", "soft"]) ? 0.28
                : !declared.isDisjoint(with: ["energetic", "aggressive", "intense"]) ? 0.78
                : !declared.isDisjoint(with: ["upbeat", "cinematic"]) ? 0.62 : 0.44
            var source = URLComponents(url: Self.baseURL.appendingPathComponent("index.html"), resolvingAgainstBaseURL: false)!
            source.queryItems = [URLQueryItem(name: isrc.isEmpty ? "search" : "isrc", value: isrc.isEmpty ? title : isrc)]
            let page = source.url!
            return MusicProviderTrack(id: id, sourceProvider: .incompetech,
                metadata: MusicTrackMetadata(title: title, artist: "Kevin MacLeod", genres: [genre],
                    moods: text("feel").lowercased().components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                    tags: tags.sorted(), energy: energy, bpm: bpm, duration: duration, sourceName: "Incompetech",
                    instrumental: tags.isDisjoint(with: ["vocals", "vocal", "voice", "singing"]) ? true : nil),
                license: MusicLicenseRecord(name: "Creative Commons BY 4.0", url: licenseURL,
                    attributionText: "\(title) — Kevin MacLeod (incompetech.com). CC BY 4.0: \(licenseURL.absoluteString). \(page.absoluteString). Музыка смонтирована для видео.",
                    usageRestrictions: "Укажите автора, ссылку на лицензию и внесённые изменения в титрах или описании видео.",
                    sourceName: "Incompetech", sourceURL: page, licenseCheckedAt: Date(), requiresAttribution: true),
                sourcePageURL: page, downloadURL: Self.baseURL.appendingPathComponent("mp3-royaltyfree").appendingPathComponent(filename))
        }
    }

    public func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack {
        guard track.sourceProvider == .incompetech, track.downloadURL?.host == "incompetech.com" else { throw URLError(.unsupportedURL) }
        return try await MusicAudioDownloader.download(track, into: library, session: session)
    }
    public func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata { track.metadata }
    public func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord { track.license }
}
