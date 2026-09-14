import Foundation

/// Jason Shaw's public CC BY catalogue and original MP3 downloads.
public actor AudionautixMusicProvider: MusicProvider {
    public nonisolated let identifier = "audionautix"
    public nonisolated let sourceProvider: MusicSourceProvider = .audionautix
    public nonisolated let priority = 115
    public nonisolated let fallbackTier = 1
    private let library: LocalMusicLibrary
    private let session: URLSession
    private let access: MusicCatalogAccess
    private var cache: [String: (Date, [MusicProviderTrack])] = [:]
    private static let baseURL = URL(string: "https://audionautix.com/")!

    public init(library: LocalMusicLibrary = .shared, session: URLSession? = nil) {
        self.library = library
        let transport = session ?? MusicAudioDownloader.makeSession()
        self.session = transport
        self.access = MusicCatalogAccess(host: "audionautix.com", session: transport, delay: 3)
    }

    public func availability() async -> MusicProviderAvailability { .available }

    public func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack] {
        let genre = Self.genre(for: intent)
        if let (date, tracks) = cache[genre], Date().timeIntervalSince(date) < 21_600 { return tracks }
        let page = Self.baseURL.appendingPathComponent("free-music").appendingPathComponent(genre)
        var request = URLRequest(url: page)
        request.timeoutInterval = 8
        // Apache negotiates the PHP script type before serving HTML. A strict
        // text/html Accept produces HTTP 406 on this otherwise public page.
        request.setValue("text/html, */*;q=0.8", forHTTPHeaderField: "Accept")
        try await access.authorize(page)
        let data = try await MusicHTTPClient.data(for: request, session: session, maximumBytes: 2_000_000, minimumRetryDelay: 3)
        guard let html = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        let tracks = Self.candidates(html: html, page: page)
        cache[genre] = (Date(), tracks)
        return tracks
    }

    nonisolated static func genre(for intent: MusicIntent) -> String {
        let genres = intent.genres.union(intent.mood)
        for (tokens, genre) in [(Set(["rock", "metal"]), "rock"), (["electronic", "techno", "synth"], "electronic"),
                                (["cinematic", "orchestral"], "soundtrack"), (["jazz"], "jazz"),
                                (["acoustic", "folk", "joyful"], "acoustic"), (["ambient", "calm"], "meditative")] {
            if !genres.isDisjoint(with: tokens) { return genre }
        }
        return "soundtrack"
    }

    nonisolated static func candidates(html: String, page: URL) -> [MusicProviderTrack] {
        guard page.host == "audionautix.com", MusicAudioDownloader.publicHTTPS(page),
              html.range(of: #"https?://creativecommons\.org/licenses/by/4\.0/(?:legalcode)?["']"#, options: .regularExpression) != nil else { return [] }
        var seen: Set<String> = []
        return html.components(separatedBy: "class=\"single-song\"").dropFirst().compactMap { block in
            guard let heading = MusicCatalogText.captures("<h3[^>]*>(.*?)</h3>", in: block).first?.first,
                  let path = MusicCatalogText.captures(#"href=["'](/Music/[^"']+\.mp3)["']"#, in: block).first?.first,
                  let url = URL(string: MusicCatalogText.plain(path), relativeTo: Self.baseURL)?.absoluteURL,
                  url.host == "audionautix.com", url.path.hasPrefix("/Music/"),
                  !url.path.contains(".."), seen.insert(url.path).inserted else { return nil }
            let headingText = MusicCatalogText.plain(heading)
            let time = MusicCatalogText.captures(#"\((\d*):(\d{2})\)\s*$"#, in: headingText).first
            let duration = time.map { (Double($0[0]) ?? 0) * 60 + (Double($0[1]) ?? 0) } ?? 180
            guard duration >= 45, duration <= 1_800 else { return nil }
            let title = headingText.replacingOccurrences(of: #"\s*\(\d*:\d{2}\)\s*$"#, with: "", options: .regularExpression)
            guard !title.isEmpty else { return nil }
            let fields = MusicCatalogText.captures("<tr[^>]*>\\s*<td[^>]*>(.*?)</td>\\s*<td[^>]*>(.*?)</td>", in: block)
            func field(_ name: String) -> String {
                fields.first { MusicCatalogText.plain($0[0]).lowercased() == name }.map { MusicCatalogText.plain($0[1]) } ?? ""
            }
            // Keep the catalogue's declarations separate. Expanding every
            // mood into every genre made a single song appear to fit any film.
            let genres = MusicSearchRequest.words(field("genre:"))
            let moods = MusicSearchRequest.words(field("mood:"))
            let tags = genres.union(moods).union(["instrumental"])
            let tempo = field("tempo:").lowercased()
            let energy = tempo == "fast" ? 0.78 : tempo == "slow" ? 0.30 : 0.52
            return MusicProviderTrack(id: url.deletingPathExtension().lastPathComponent, sourceProvider: .audionautix,
                metadata: MusicTrackMetadata(title: title, artist: "Jason Shaw", genres: genres.sorted(), moods: moods.sorted(), tags: tags.sorted(),
                    energy: energy, bpm: 70 + energy * 70, duration: duration, sourceName: "Audionautix", instrumental: true),
                license: MusicCatalogText.license(title: title, artist: "Jason Shaw", source: "Audionautix", page: page),
                sourcePageURL: page, downloadURL: url)
        }
    }

    public func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack {
        guard track.sourceProvider == .audionautix, let url = track.downloadURL,
              url.host == "audionautix.com", url.path.hasPrefix("/Music/"), url.pathExtension.lowercased() == "mp3" else { throw URLError(.unsupportedURL) }
        try await access.authorize(url)
        return try await MusicAudioDownloader.download(track, into: library, session: session, minimumDuration: 45, minimumRetryDelay: 3)
    }
    public func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata { track.metadata }
    public func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord { track.license }
}
