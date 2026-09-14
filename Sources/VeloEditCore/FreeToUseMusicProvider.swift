import Foundation

public struct FreeToUseRemoteTrack: Decodable, Identifiable, Sendable {
    public struct Artist: Decodable, Sendable {
        public let id: String
        public let name: String
    }

    public struct Category: Decodable, Sendable {
        public let id: String
        public let name: String
    }

    public struct Files: Decodable, Sendable { public let mp3: URL }

    private struct OrderedArtist: Decodable {
        let value: Artist
        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            _ = try container.decode(Int.self)
            value = try container.decode(Artist.self)
        }
    }

    private struct OrderedCategory: Decodable {
        let value: Category
        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            _ = try container.decode(Int.self)
            value = try container.decode(Category.self)
        }
    }

    private struct OrderedTag: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            _ = try container.decode(Int.self)
            value = try container.decode(String.self)
        }
    }

    public let id: String
    public let title: String
    public let genre: String?
    public let isPremium: Bool
    public let duration: Double
    public let waveform: [Int]
    public let artists: [Artist]
    public let categories: [Category]
    public let tags: [String]
    public let files: Files

    enum CodingKeys: String, CodingKey {
        case id, title, genre, duration, waveform, artists, categories, tags, files
        case isPremium = "is_premium"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        genre = try container.decodeIfPresent(String.self, forKey: .genre)
        isPremium = try container.decode(Bool.self, forKey: .isPremium)
        duration = try container.decode(Double.self, forKey: .duration)
        waveform = try container.decodeIfPresent([Int].self, forKey: .waveform) ?? []
        artists = try container.decodeIfPresent([OrderedArtist].self, forKey: .artists)?.map(\.value) ?? []
        categories = try container.decodeIfPresent([OrderedCategory].self, forKey: .categories)?.map(\.value) ?? []
        tags = try container.decodeIfPresent([OrderedTag].self, forKey: .tags)?.map(\.value) ?? []
        files = try container.decode(Files.self, forKey: .files)
    }

    public var author: String { artists.map(\.name).joined(separator: ", ") }
    public var descriptors: [String] {
        ([genre].compactMap { $0 } + categories.map(\.name) + tags).map { $0.lowercased() }
    }
    public var energy: Double {
        guard !waveform.isEmpty else { return 0.55 }
        let rootMeanSquare = sqrt(waveform.reduce(0.0) { $0 + pow(Double($1) / 100, 2) } / Double(waveform.count))
        return min(max(0.05, rootMeanSquare), 1)
    }
    public var estimatedBPM: Double {
        let text = descriptors.joined(separator: " ")
        if ["energetic", "action", "upbeat", "party", "sports", "edm", "hype", "running"].contains(where: text.contains) { return 128 }
        if ["calm", "ambient", "chill", "lofi", "relax", "dream"].contains(where: text.contains) { return 72 }
        if ["cinematic", "epic", "dramatic", "trailer"].contains(where: text.contains) { return 84 }
        if ["happy", "joy", "bright", "summer", "positive"].contains(where: text.contains) { return 112 }
        if ["electronic", "techno", "synth"].contains(where: text.contains) { return 120 }
        return 96
    }
    public var sourcePageURL: URL {
        let artist = Self.slug(artists.first?.name ?? "artist")
        let track = Self.slug(title)
        return URL(string: "https://freetouse.com/music/\(artist)/\(track)")!
    }

    private static func slug(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        return folded.unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.alphanumerics.contains(scalar) { result.unicodeScalars.append(scalar) }
            else if result.last != "-" { result.append("-") }
        }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

public enum FreeToUseAPIError: LocalizedError {
    case invalidResponse
    case noFreeTrack
    case invalidDownloadURL
    case downloadFailed
    case providerFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Free To Use API вернул некорректный ответ."
        case .noFreeTrack: return "В Free To Use не найден подходящий бесплатный трек."
        case .invalidDownloadURL: return "Free To Use API вернул небезопасный адрес аудиофайла."
        case .downloadFailed: return "Не удалось скачать трек из Free To Use."
        case .providerFailure(let reason): return "Не удалось подготовить трек из Free To Use: \(reason)"
        }
    }
}

public actor FreeToUseMusicProvider {
    private static let apiTimeout: TimeInterval = 10
    private struct SearchResponse: Decodable {
        let ok: Bool
        let data: [FreeToUseRemoteTrack]
        enum CodingKeys: String, CodingKey { case ok, data }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ok = try container.decode(Bool.self, forKey: .ok)
            var rows = try container.nestedUnkeyedContainer(forKey: .data)
            var valid: [FreeToUseRemoteTrack] = []
            while !rows.isAtEnd {
                let row = try rows.superDecoder()
                if let track = try? FreeToUseRemoteTrack(from: row) { valid.append(track) }
            }
            data = valid
        }
    }
    private struct TrackResponse: Decodable { let ok: Bool; let data: FreeToUseRemoteTrack? }
    public static let apiBaseURL = URL(string: "https://api.freetouse.com/v3")!
    public static let musicHomeURL = URL(string: "https://freetouse.com/music")!
    public static let licenseURL = URL(string: "https://freetouse.com/license")!

    private let library: LocalMusicLibrary
    private let session: URLSession

    public init(library: LocalMusicLibrary = .shared, session: URLSession? = nil) {
        self.library = library
        self.session = session ?? Self.makeDefaultSession()
    }

    private static func makeDefaultSession() -> URLSession {
        MusicAudioDownloader.makeSession()
    }

    @discardableResult
    public func downloadBestMatch(for directive: MusicDirective, excludingProviderIDs: Set<String> = []) async throws -> LocalMusicTrack {
        let remoteTracks = try await search(query: Self.query(for: directive.style))
        let candidates = remoteTracks.filter { !$0.isPremium && !excludingProviderIDs.contains($0.id) }
        let ranked = candidates.sorted { score($0, directive) > score($1, directive) }
        guard !ranked.isEmpty else {
            throw FreeToUseAPIError.noFreeTrack
        }
        var lastError: Error?
        for selected in ranked.prefix(3) {
            do {
                // Search responses intentionally contain only a shortened
                // descriptor list. Load the official record before persisting.
                let completeTrack = try await track(id: selected.id)
                guard !completeTrack.isPremium else { continue }
                return try await download(completeTrack)
            } catch MusicLibraryError.duplicateSource {
                if let existing = try await library.tracks().first(where: { $0.providerTrackID == selected.id }),
                   FileManager.default.fileExists(atPath: existing.localFileURL.path) {
                    return existing
                }
                lastError = MusicLibraryError.duplicateSource
            } catch {
                lastError = error
            }
        }
        throw FreeToUseAPIError.providerFailure(
            lastError?.localizedDescription ?? FreeToUseAPIError.noFreeTrack.localizedDescription
        )
    }

    public func bootstrap(styles: [MusicStyle] = MusicStyle.allCases) async throws -> [LocalMusicTrack] {
        var result: [LocalMusicTrack] = []
        var excluded = Set(try await library.tracks().compactMap(\.providerTrackID))
        for style in styles {
            let directive = MusicDirective(style: style, bpm: Self.defaultBPM(for: style))
            do {
                let track = try await downloadBestMatch(for: directive, excludingProviderIDs: excluded)
                excluded.insert(track.providerTrackID ?? "")
                result.append(track)
            } catch MusicLibraryError.duplicateSource {
                continue
            }
        }
        return result
    }

    public func search(query: String) async throws -> [FreeToUseRemoteTrack] {
        var components = URLComponents(url: Self.apiBaseURL.appendingPathComponent("music/tracks/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "60"),
            URLQueryItem(name: "order", value: "random"),
            URLQueryItem(name: "sort", value: "desc")
        ]
        guard let url = components.url else { throw FreeToUseAPIError.invalidResponse }
        let data = try await MusicHTTPClient.data(at: url, session: session, timeout: Self.apiTimeout)
        guard
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data), decoded.ok else {
            throw FreeToUseAPIError.invalidResponse
        }
        return decoded.data
    }

    public func track(id: String) async throws -> FreeToUseRemoteTrack {
        guard UUID(uuidString: id) != nil else { throw FreeToUseAPIError.invalidResponse }
        let url = Self.apiBaseURL.appendingPathComponent("music/tracks").appendingPathComponent(id)
        let data = try await MusicHTTPClient.data(at: url, session: session, timeout: Self.apiTimeout)
        guard
              let decoded = try? JSONDecoder().decode(TrackResponse.self, from: data),
              decoded.ok, let track = decoded.data else {
            throw FreeToUseAPIError.invalidResponse
        }
        return track
    }

    public func download(_ remote: FreeToUseRemoteTrack) async throws -> LocalMusicTrack {
        guard !remote.isPremium else { throw FreeToUseAPIError.noFreeTrack }
        let audioURL = remote.files.mp3
        guard audioURL.scheme == "https", audioURL.host?.lowercased() == "data.freetouse.com" else {
            throw FreeToUseAPIError.invalidDownloadURL
        }
        let author = remote.author.isEmpty ? "Free To Use artist" : remote.author
        let candidate = MusicProviderTrack(id: remote.id, sourceProvider: .freeToUse,
            metadata: MusicTrackMetadata(title: remote.title, artist: author,
                genres: [remote.genre].compactMap { $0 }, moods: remote.categories.map(\.name), tags: remote.tags,
                energy: remote.energy, bpm: remote.estimatedBPM, duration: remote.duration, sourceName: "Free To Use Music"),
            license: .freeToUse(title: remote.title, author: author), sourcePageURL: remote.sourcePageURL, downloadURL: audioURL)
        return try await MusicAudioDownloader.download(candidate, into: library, session: session)
    }

    private func score(_ track: FreeToUseRemoteTrack, _ directive: MusicDirective) -> Double {
        let words = Set(track.descriptors)
        let desired = Set(Self.query(for: directive.style).split(separator: " ").map(String.init))
        let semantic = Double(words.intersection(desired).count) / Double(max(1, desired.count))
        let bpm = max(0, 1 - abs(track.estimatedBPM - directive.bpm) / 80)
        let targetEnergy: Double
        switch directive.style {
        case .calm: targetEnergy = 0.24
        case .acoustic: targetEnergy = 0.42
        case .cinematic: targetEnergy = 0.52
        case .joyful: targetEnergy = 0.56
        case .energetic, .electronic: targetEnergy = 0.64
        }
        let energy = max(0, 1 - abs(track.energy - targetEnergy))
        let text = track.descriptors.joined(separator: " ")
        let fatiguePenalty = ["aggressive", "hard", "heavy", "bass", "metal", "trap", "dubstep", "intense"]
            .filter(text.contains).count
        return semantic * 0.48 + bpm * 0.20 + energy * 0.32 - Double(fatiguePenalty) * 0.16
    }

    private static func query(for style: MusicStyle) -> String {
        switch style {
        case .energetic: return "uplifting energetic background sport"
        case .cinematic: return "cinematic inspiring emotional background"
        case .calm: return "calm ambient relaxing"
        case .joyful: return "happy joyful bright"
        case .electronic: return "melodic electronic synth background"
        case .acoustic: return "acoustic guitar folk"
        }
    }

    private static func defaultBPM(for style: MusicStyle) -> Double {
        switch style {
        case .energetic: return 118
        case .cinematic: return 82
        case .calm: return 68
        case .joyful: return 112
        case .electronic: return 116
        case .acoustic: return 94
        }
    }


}

extension FreeToUseMusicProvider: MusicProvider {
    public nonisolated var identifier: String { "free-to-use" }
    public nonisolated var sourceProvider: MusicSourceProvider { .freeToUse }
    public nonisolated var priority: Int { 110 }

    public func availability() async -> MusicProviderAvailability { .available }

    public func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack] {
        var remoteTracks: [FreeToUseRemoteTrack] = []
        var lastError: Error?
        for query in Self.searchQueries(for: intent) {
            do {
                remoteTracks += try await search(query: query).filter { !$0.isPremium }
                if remoteTracks.count >= 40 { break }
            } catch {
                if Task.isCancelled { throw error }
                lastError = error
                break // Changing words cannot repair a network outage.
            }
        }
        if remoteTracks.isEmpty, let lastError { throw lastError }
        var seen: Set<String> = []
        return remoteTracks.filter { seen.insert($0.id).inserted }.map { remote in
            let author = remote.author.isEmpty ? "Free To Use artist" : remote.author
            let license = MusicLicenseRecord.freeToUse(title: remote.title, author: author)
            return MusicProviderTrack(
                id: remote.id,
                sourceProvider: .freeToUse,
                metadata: MusicTrackMetadata(
                    title: remote.title,
                    artist: author,
                    genres: [remote.genre].compactMap { $0 },
                    moods: remote.categories.map(\.name),
                    tags: remote.tags,
                    energy: remote.energy,
                    bpm: remote.estimatedBPM,
                    duration: remote.duration,
                    sourceName: "Free To Use Music",
                    instrumental: nil
                ),
                license: license,
                sourcePageURL: remote.sourcePageURL,
                downloadURL: remote.files.mp3
            )
        }
    }

    /// Free To Use matches every supplied term quite narrowly. Start with a
    /// short provider-specific query and keep the richer intent as a fallback.
    nonisolated static func searchQueries(for intent: MusicIntent) -> [String] {
        if let request = intent.request {
            if request.exactTrack { return [request.query] }
            let words = MusicSearchRequest.translatedDescriptors(request.query.lowercased())
            return [request.query] + words.filter { $0 != request.query }.prefix(2)
        }
        let tokens = intent.mood.union(intent.genres)
        let primary: String
        if intent.genres.contains("folk") {
            primary = "acoustic"
        } else if !tokens.isDisjoint(with: ["joyful", "happy", "bright"]) {
            primary = "happy"
        } else if !tokens.isDisjoint(with: ["cinematic", "dramatic", "orchestral"]) {
            primary = "cinematic"
        } else if !tokens.isDisjoint(with: ["electronic", "synth", "techno", "energetic", "upbeat"]) {
            primary = "electronic"
        } else if !tokens.isDisjoint(with: ["calm", "ambient", "soft"]) {
            primary = "calm"
        } else {
            primary = "energetic"
        }
        var queries = [primary]
        let fallback = primary == "calm" ? "ambient" : primary == "cinematic" ? "inspiring" : primary == "electronic" ? "upbeat" : "melodic"
        if !fallback.isEmpty, fallback != primary { queries.append(fallback) }
        return queries
    }

    public func download(_ candidate: MusicProviderTrack) async throws -> LocalMusicTrack {
        if let existing = try await library.tracks().first(where: {
            $0.sourceProvider == .freeToUse && $0.providerTrackID == candidate.id && $0.isPlayable
        }) { return existing }
        // Search already provides the authoritative non-premium flag and
        // direct MP3. A second metadata request must not block a valid file.
        guard candidate.sourceProvider == .freeToUse,
              candidate.downloadURL?.host?.lowercased() == "data.freetouse.com" else { throw FreeToUseAPIError.invalidDownloadURL }
        return try await MusicAudioDownloader.download(candidate, into: library, session: session)
    }

    public func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata { track.metadata }
    public func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord { track.license }
}
