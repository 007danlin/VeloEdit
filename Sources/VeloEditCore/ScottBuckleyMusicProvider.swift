import Foundation

/// The composer's public WordPress REST catalogue. Only licensed full mixes.
public actor ScottBuckleyMusicProvider: MusicProvider {
    public nonisolated let identifier = "scott-buckley"
    public nonisolated let sourceProvider: MusicSourceProvider = .scottBuckley
    public nonisolated let priority = 116
    public nonisolated let fallbackTier = 1
    private let library: LocalMusicLibrary
    private let session: URLSession
    private let access: MusicCatalogAccess
    private var cache: [String: (Date, [MusicProviderTrack])] = [:]
    private static let host = "www.scottbuckley.com.au"

    public init(library: LocalMusicLibrary = .shared, session: URLSession? = nil) {
        self.library = library
        let transport = session ?? MusicAudioDownloader.makeSession()
        self.session = transport
        self.access = MusicCatalogAccess(host: Self.host, session: transport)
    }

    public func availability() async -> MusicProviderAvailability { .available }

    public func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack] {
        // A broad latest-release pool avoids repeatedly selecting the same
        // small set. Ranking still uses the composer's musical descriptions.
        let query = MusicCatalogText.titleQuery(intent, removing: "Scott Buckley") ?? ""
        if let (date, tracks) = cache[query], Date().timeIntervalSince(date) < 21_600 { return tracks }
        var url = URLComponents(string: "https://\(Self.host)/library/wp-json/wp/v2/posts")!
        url.queryItems = [URLQueryItem(name: "per_page", value: "50"), URLQueryItem(name: "_fields", value: "id,link,title,content"),
                         URLQueryItem(name: "orderby", value: "date"), URLQueryItem(name: "order", value: "desc")]
        if !query.isEmpty { url.queryItems?.append(URLQueryItem(name: "search", value: query)) }
        let endpoint = url.url!
        try await access.authorize(endpoint)
        let data = try await MusicHTTPClient.data(at: endpoint, session: session, timeout: 8, maximumBytes: 3_000_000)
        let tracks = try Self.candidates(data: data)
        cache[query] = (Date(), tracks)
        return tracks
    }

    nonisolated static func candidates(data: Data) throws -> [MusicProviderTrack] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        var seen: Set<Int> = []
        return rows.compactMap { row in
            guard let id = row["id"] as? Int, seen.insert(id).inserted,
                  let link = row["link"] as? String, let page = URL(string: link),
                  page.host == Self.host, page.path.hasPrefix("/library/"), MusicAudioDownloader.publicHTTPS(page),
                  let rawTitle = (row["title"] as? [String: Any])?["rendered"] as? String,
                  let content = row["content"] as? [String: Any], content["protected"] as? Bool != true,
                  let html = content["rendered"] as? String else { return nil }
            let anchors = MusicCatalogText.captures("<a\\b([^>]*)>(.*?)</a>", in: html)
            let licensed = anchors.contains { anchor in
                anchor[0].range(of: #"rel\s*=\s*["']license["']"#, options: .regularExpression) != nil &&
                anchor[0].range(of: #"href\s*=\s*["']https?://creativecommons\.org/licenses/by/4\.0/["']"#, options: .regularExpression) != nil
            }
            guard licensed else { return nil }
            let files = anchors.filter { MusicCatalogText.plain($0[1]).lowercased().contains("mp3 (full mix)") }
            guard let href = files.compactMap({ MusicCatalogText.captures(#"href\s*=\s*["']([^"']+)["']"#, in: $0[0]).first?.first }).first,
                  let audio = URL(string: MusicCatalogText.plain(href)), audio.host == Self.host,
                  MusicAudioDownloader.publicHTTPS(audio), audio.path.hasPrefix("/library/wp-content/uploads/"),
                  audio.pathExtension.lowercased() == "mp3", !audio.path.contains("..") else { return nil }
            let title = MusicCatalogText.plain(rawTitle)
            guard !title.isEmpty else { return nil }
            // Patron names, license prose and comments are not music tags.
            let description = MusicCatalogText.captures("<p[^>]*>(.*?)</p>", in: html).first?.first ?? ""
            let tags = MusicCatalogText.descriptors(MusicCatalogText.plain(description)).union(["instrumental"])
            let energy = MusicCatalogText.energy(tags)
            return MusicProviderTrack(id: String(id), sourceProvider: .scottBuckley,
                metadata: MusicTrackMetadata(title: title, artist: "Scott Buckley", genres: tags.sorted(), moods: tags.sorted(), tags: tags.sorted(),
                    energy: energy, bpm: 70 + energy * 70, duration: 180, sourceName: "Scott Buckley", instrumental: true),
                license: MusicCatalogText.license(title: title, artist: "Scott Buckley", source: "Scott Buckley", page: page),
                sourcePageURL: page, downloadURL: audio)
        }
    }

    public func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack {
        guard track.sourceProvider == .scottBuckley, let url = track.downloadURL, url.host == Self.host,
              url.path.hasPrefix("/library/wp-content/uploads/"), url.pathExtension.lowercased() == "mp3" else { throw URLError(.unsupportedURL) }
        try await access.authorize(url)
        return try await MusicAudioDownloader.download(track, into: library, session: session, minimumDuration: 45)
    }
    public func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata { track.metadata }
    public func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord { track.license }
}
