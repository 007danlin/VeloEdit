import Foundation
import AVFoundation

public enum MusicSourceProvider: String, Codable, Sendable {
    case bundled
    case pixabay
    case freeToUse = "free-to-use"
    case openverse
    case incompetech
    case audionautix
    case scottBuckley = "scott-buckley"
    case internetArchive = "internet-archive"
    case web = "web-search"
    case user
    case other

    public var isOnline: Bool {
        switch self {
        case .freeToUse, .openverse, .incompetech, .audionautix, .scottBuckley, .pixabay, .internetArchive, .web: return true
        case .bundled, .user, .other: return false
        }
    }

    public var localizedTitle: String {
        switch self {
        case .bundled: return "VeloEdit Library"
        case .user: return "My Music"
        case .freeToUse: return "Free To Use"
        case .openverse: return "Openverse"
        case .incompetech: return "Incompetech"
        case .audionautix: return "Audionautix"
        case .scottBuckley: return "Scott Buckley"
        case .internetArchive: return "Internet Archive"
        case .web: return "Интернет"
        case .pixabay: return "Pixabay"
        case .other: return "Другой источник"
        }
    }
}

public struct MusicLicenseRecord: Codable, Hashable, Sendable {
    public var name: String
    public var url: URL
    public var downloadedAt: Date
    public var attributionText: String?
    public var usageRestrictions: String?
    public var sourceName: String?
    public var sourceURL: URL?
    public var licenseCheckedAt: Date?
    public var requiresAttribution: Bool?

    public init(
        name: String,
        url: URL,
        downloadedAt: Date = Date(),
        attributionText: String? = nil,
        usageRestrictions: String? = nil,
        sourceName: String? = nil,
        sourceURL: URL? = nil,
        licenseCheckedAt: Date? = nil,
        requiresAttribution: Bool? = nil
    ) {
        self.name = name
        self.url = url
        self.downloadedAt = downloadedAt
        self.attributionText = attributionText
        self.usageRestrictions = usageRestrictions
        self.sourceName = sourceName
        self.sourceURL = sourceURL
        self.licenseCheckedAt = licenseCheckedAt
        self.requiresAttribution = requiresAttribution
    }

    public static func freeToUse(title: String, author: String, downloadedAt: Date = Date()) -> MusicLicenseRecord {
        MusicLicenseRecord(
            name: "Free To Use — Free License",
            url: URL(string: "https://freetouse.com/license")!,
            downloadedAt: downloadedAt,
            attributionText: "Music from Free To Use\nSource: https://freetouse.com/music\n\(title) by \(author)",
            usageRestrictions: "Только user-generated content в социальных платформах с корректной атрибуцией. Коммерческий контент, broadcast и digital products требуют отдельной платной лицензии.",
            sourceName: "Free To Use Music",
            sourceURL: URL(string: "https://freetouse.com/music"),
            licenseCheckedAt: downloadedAt,
            requiresAttribution: true
        )
    }

    public static func userFile(importedAt: Date = Date()) -> MusicLicenseRecord {
        MusicLicenseRecord(
            name: "Пользовательский аудиофайл",
            url: URL(string: "about:blank")!,
            downloadedAt: importedAt,
            usageRestrictions: "Права на использование и распространение этого файла определяет пользователь.",
            sourceName: "My Music",
            licenseCheckedAt: importedAt,
            requiresAttribution: false
        )
    }
}

public struct MusicCredit: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var trackTitle: String
    public var artist: String
    public var sourceProvider: MusicSourceProvider
    public var sourceURL: URL
    public var license: MusicLicenseRecord

    public init(track: LocalMusicTrack) {
        id = "\(track.sourceProvider.rawValue):\(track.providerTrackID ?? track.id.uuidString)"
        trackTitle = track.title
        artist = track.author
        sourceProvider = track.sourceProvider
        sourceURL = track.sourcePageURL
        license = track.license
    }
}

/// A local, user-acquired music file. VeloEdit never republishes this file and
/// uses it only as a component of a rendered creative video.
public struct LocalMusicTrack: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var author: String
    public var bpm: Double
    public var genres: [String]
    public var moods: [String]
    public var energy: Double
    public var duration: Double
    public var license: MusicLicenseRecord
    public var sourceProvider: MusicSourceProvider
    public var sourcePageURL: URL
    public var localFileURL: URL
    public var originalFileName: String
    public var importedAt: Date
    public var providerTrackID: String?
    public var isPremium: Bool?
    public var bpmIsEstimated: Bool?
    public var tags: [String]?
    public var loudness: Double?
    public var waveform: [Double]?
    public var musicalKey: String?

    public init(
        id: UUID = UUID(),
        title: String,
        author: String,
        bpm: Double,
        genres: [String],
        moods: [String],
        energy: Double,
        duration: Double,
        license: MusicLicenseRecord,
        sourceProvider: MusicSourceProvider,
        sourcePageURL: URL,
        localFileURL: URL,
        originalFileName: String,
        importedAt: Date = Date(),
        providerTrackID: String? = nil,
        isPremium: Bool? = nil,
        bpmIsEstimated: Bool? = nil,
        tags: [String]? = nil,
        loudness: Double? = nil,
        waveform: [Double]? = nil,
        musicalKey: String? = nil
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bpm = min(max(40, bpm), 240)
        self.genres = Self.cleaned(genres)
        self.moods = Self.cleaned(moods)
        self.energy = min(max(0, energy), 1)
        self.duration = max(0, duration)
        self.license = license
        self.sourceProvider = sourceProvider
        self.sourcePageURL = sourcePageURL
        self.localFileURL = localFileURL
        self.originalFileName = originalFileName
        self.importedAt = importedAt
        self.providerTrackID = providerTrackID
        self.isPremium = isPremium
        self.bpmIsEstimated = bpmIsEstimated
        self.tags = tags.map(Self.cleaned)
        self.loudness = loudness.map { min(max(0, $0), 1) }
        self.waveform = waveform?.map { min(max(0, $0), 1) }
        self.musicalKey = musicalKey
    }

    private static func cleaned(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })).sorted()
    }

    public var suggestedStyle: MusicStyle {
        let values = Set((genres + moods + (tags ?? [])).map { $0.lowercased() })
        if !values.isDisjoint(with: ["electronic", "synth", "techno", "edm", "электронный"]) { return .electronic }
        if !values.isDisjoint(with: ["acoustic", "guitar", "folk", "акустический"]) { return .acoustic }
        if !values.isDisjoint(with: ["cinematic", "epic", "dramatic", "кинематографичный", "эпичный"]) { return .cinematic }
        if !values.isDisjoint(with: ["happy", "joyful", "bright", "uplifting", "весёлый", "радостный"]) { return .joyful }
        if energy >= 0.7 { return .energetic }
        if energy <= 0.4 { return .calm }
        return .cinematic
    }

    public var isPlayable: Bool { FileManager.default.fileExists(atPath: localFileURL.path) }
}

public enum MusicLibraryError: LocalizedError {
    case unreadableAudio
    case duplicateSource

    public var errorDescription: String? {
        switch self {
        case .unreadableAudio:
            return "Файл не содержит читаемой аудиодорожки."
        case .duplicateSource:
            return "Этот трек уже есть в локальной библиотеке."
        }
    }
}

public actor LocalMusicLibrary {
    public static let shared = LocalMusicLibrary()
    private static let importAnalyzer = LocalAudioAnalyzer()

    private let rootURLProvider: @Sendable () -> URL
    private var rootURL: URL { rootURLProvider() }
    private var cachedRootURL: URL?
    private var cachedTracks: [LocalMusicTrack]?

    public init(rootURL: URL? = nil) {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = rootURL ?? applicationSupport.appendingPathComponent("VeloEdit/MusicLibrary", isDirectory: true)
        self.rootURLProvider = { root }
    }

    public init(rootURLProvider: @escaping @Sendable () -> URL) {
        self.rootURLProvider = rootURLProvider
    }

    public func tracks() throws -> [LocalMusicTrack] {
        if cachedRootURL != rootURL { cachedTracks = nil; cachedRootURL = rootURL }
        if let cachedTracks { return cachedTracks }
        try createDirectories()
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            cachedTracks = []
            return []
        }
        var decoded = try JSONDecoder.veloEdit.decode([LocalMusicTrack].self, from: Data(contentsOf: catalogURL))
        var repairedMovedPaths = false
        for index in decoded.indices {
            let packaged = filesURL.appendingPathComponent(decoded[index].localFileURL.lastPathComponent)
            if packaged != decoded[index].localFileURL, FileManager.default.fileExists(atPath: packaged.path) {
                decoded[index].localFileURL = packaged
                repairedMovedPaths = true
                continue
            }
            if FileManager.default.fileExists(atPath: decoded[index].localFileURL.path) { continue }
            if decoded[index].sourceProvider == .bundled {
                let roots = [
                    Bundle.main.resourceURL?.appendingPathComponent("Music", isDirectory: true),
                    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                        .appendingPathComponent("Resources/Music", isDirectory: true)
                ].compactMap { $0 }
                if let bundledURL = roots
                    .map({ $0.appendingPathComponent(decoded[index].originalFileName) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                    decoded[index].localFileURL = bundledURL
                    repairedMovedPaths = true
                    continue
                }
            }
            let relocatedURL = filesURL.appendingPathComponent(decoded[index].localFileURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: relocatedURL.path) {
                decoded[index].localFileURL = relocatedURL
                repairedMovedPaths = true
            }
        }
        if repairedMovedPaths { try write(decoded) }
        cachedTracks = decoded
        return decoded
    }

    /// Persists a provider-neutral track and its complete license record. The
    /// provider ID is the cache key, so repeated film creation never downloads
    /// or copies the same track twice.
    @discardableResult
    public func importProviderTrack(
        _ providerTrack: MusicProviderTrack,
        downloadedFileURL: URL
    ) async throws -> LocalMusicTrack {
        var library = try tracks()
        if let existing = library.first(where: {
            $0.sourceProvider == providerTrack.sourceProvider && $0.providerTrackID == providerTrack.id
        }), existing.isPlayable, providerTrack.sourceProvider != .bundled {
            return existing
        }

        let measuredDuration: Double
        var measuredAudio: AudioAnalysisSummary?
        if providerTrack.sourceProvider == .bundled {
            guard FileManager.default.fileExists(atPath: downloadedFileURL.path),
                  providerTrack.metadata.duration > 0 else { throw MusicLibraryError.unreadableAudio }
            measuredDuration = providerTrack.metadata.duration
        } else {
            let asset = AVURLAsset(url: downloadedFileURL)
            guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw MusicLibraryError.unreadableAudio }
            measuredDuration = try await asset.load(.duration).seconds
            guard measuredDuration.isFinite, measuredDuration > 0 else { throw MusicLibraryError.unreadableAudio }

            measuredAudio = try await Self.importAnalyzer.analyze(url: downloadedFileURL, level: .deep)
            guard measuredAudio != nil else { throw MusicLibraryError.unreadableAudio }
            try Task.checkCancellation()

            // AVFoundation suspends this actor while it inspects the file. A
            // bundled-catalog import can complete during that suspension, so
            // reload before writing to avoid replacing newer catalog entries
            // with the stale snapshot captured above.
            library = try tracks()
            if let existing = library.first(where: {
                $0.sourceProvider == providerTrack.sourceProvider && $0.providerTrackID == providerTrack.id
            }), existing.isPlayable {
                return existing
            }
        }

        try createDirectories()
        let id = UUID(uuidString: providerTrack.id) ?? UUID()
        let fileExtension = downloadedFileURL.pathExtension.lowercased()
        let destination = providerTrack.sourceProvider == .bundled
            ? downloadedFileURL.standardizedFileURL
            : filesURL
                .appendingPathComponent(id.uuidString)
                .appendingPathExtension(fileExtension.isEmpty ? "m4a" : fileExtension)
        let shouldCopy = providerTrack.sourceProvider != .bundled
            && downloadedFileURL.standardizedFileURL != destination.standardizedFileURL
        if shouldCopy {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: downloadedFileURL, to: destination)
        }
        do {
            let metadata = providerTrack.metadata
            let track = LocalMusicTrack(
                id: id,
                title: metadata.title,
                author: metadata.artist,
                bpm: (measuredAudio?.tempoConfidence ?? 0) >= 0.18 ? measuredAudio?.estimatedBPM ?? metadata.bpm : metadata.bpm,
                genres: metadata.genres,
                moods: metadata.moods,
                energy: metadata.energy,
                duration: measuredDuration,
                license: providerTrack.license,
                sourceProvider: providerTrack.sourceProvider,
                sourcePageURL: providerTrack.sourcePageURL,
                localFileURL: destination,
                originalFileName: downloadedFileURL.lastPathComponent,
                providerTrackID: providerTrack.id,
                isPremium: false,
                bpmIsEstimated: measuredAudio?.estimatedBPM == nil,
                tags: metadata.tags,
                loudness: measuredAudio?.meanVolume ?? metadata.loudness,
                waveform: measuredAudio?.waveform ?? metadata.waveform,
                musicalKey: metadata.musicalKey
            )
            library.removeAll {
                $0.sourceProvider == providerTrack.sourceProvider && $0.providerTrackID == providerTrack.id
            }
            library.append(track)
            try write(library)
            cachedTracks = library
            return track
        } catch {
            if shouldCopy { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    }

    @discardableResult
    public func importFreeToUseTrack(_ remote: FreeToUseRemoteTrack, downloadedFileURL: URL) async throws -> LocalMusicTrack {
        guard !remote.isPremium else { throw FreeToUseAPIError.noFreeTrack }
        var library = try tracks()
        guard !library.contains(where: { $0.sourceProvider == .freeToUse && $0.providerTrackID == remote.id }) else {
            throw MusicLibraryError.duplicateSource
        }
        let asset = AVURLAsset(url: downloadedFileURL)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw MusicLibraryError.unreadableAudio }
        let measuredDuration = try await asset.load(.duration).seconds
        guard measuredDuration.isFinite, measuredDuration > 0 else { throw MusicLibraryError.unreadableAudio }

        try createDirectories()
        let id = UUID()
        let destination = filesURL.appendingPathComponent(id.uuidString).appendingPathExtension("mp3")
        try FileManager.default.copyItem(at: downloadedFileURL, to: destination)
        do {
            let now = Date()
            let author = remote.author.isEmpty ? "Free To Use artist" : remote.author
            let descriptors = remote.categories.map(\.name) + remote.tags
            let track = LocalMusicTrack(
                id: id,
                title: remote.title,
                author: author,
                bpm: remote.estimatedBPM,
                genres: [remote.genre].compactMap { $0 },
                moods: descriptors.isEmpty ? ["background"] : descriptors,
                energy: remote.energy,
                duration: measuredDuration,
                license: .freeToUse(title: remote.title, author: author, downloadedAt: now),
                sourceProvider: .freeToUse,
                sourcePageURL: remote.sourcePageURL,
                localFileURL: destination,
                originalFileName: "\(remote.id).mp3",
                importedAt: now,
                providerTrackID: remote.id,
                isPremium: false,
                bpmIsEstimated: true
            )
            library.append(track)
            try write(library)
            cachedTracks = library
            return track
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    @discardableResult
    public func importUserTrack(_ sourceURL: URL, reusingExisting: Bool = false) async throws -> LocalMusicTrack {
        var library = try tracks()
        let asset = AVURLAsset(url: sourceURL)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw MusicLibraryError.unreadableAudio }
        let measuredDuration = try await asset.load(.duration).seconds
        guard measuredDuration.isFinite, measuredDuration > 0 else { throw MusicLibraryError.unreadableAudio }
        if let existing = library.first(where: {
            $0.sourceProvider == .user &&
            $0.originalFileName == sourceURL.lastPathComponent &&
            abs($0.duration - measuredDuration) < 0.01
        }) {
            if reusingExisting { return existing }
            throw MusicLibraryError.duplicateSource
        }

        try createDirectories()
        let id = UUID()
        let fileExtension = sourceURL.pathExtension.lowercased()
        let destination = filesURL
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension(fileExtension.isEmpty ? "m4a" : fileExtension)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        do {
            let now = Date()
            let commonMetadata = (try? await asset.load(.commonMetadata)) ?? []
            let titleItem = AVMetadataItem.metadataItems(
                from: commonMetadata,
                filteredByIdentifier: .commonIdentifierTitle
            ).first
            let artistItem = AVMetadataItem.metadataItems(
                from: commonMetadata,
                filteredByIdentifier: .commonIdentifierArtist
            ).first
            let embeddedTitle: String?
            if let titleItem { embeddedTitle = try? await titleItem.load(.stringValue) }
            else { embeddedTitle = nil }
            let embeddedArtist: String?
            if let artistItem { embeddedArtist = try? await artistItem.load(.stringValue) }
            else { embeddedArtist = nil }
            let analysis = try? await LocalAudioAnalyzer().analyze(url: sourceURL, level: .deep)
            let measuredBPM = analysis?.estimatedBPM ?? 100
            let measuredEnergy = min(1, max(0.12, (analysis?.meanVolume ?? 0.12) / 0.24))
            let waveform = analysis?.waveform ?? (0..<64).map { index in
                let phase = Double(index) / 63
                return min(1, measuredEnergy * (0.42 + 0.46 * abs(sin(phase * .pi * 8))))
            }
            let cleanedTitle = embeddedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedArtist = embeddedArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = cleanedTitle.flatMap { $0.isEmpty ? nil : $0 }
                ?? sourceURL.deletingPathExtension().lastPathComponent
            let author = cleanedArtist.flatMap { $0.isEmpty ? nil : $0 } ?? "Локальный файл"
            let track = LocalMusicTrack(
                id: id,
                title: title,
                author: author,
                bpm: measuredBPM,
                genres: ["local"],
                moods: ["custom"],
                energy: measuredEnergy,
                duration: measuredDuration,
                license: .userFile(importedAt: now),
                sourceProvider: .user,
                sourcePageURL: sourceURL.standardizedFileURL,
                localFileURL: destination,
                originalFileName: sourceURL.lastPathComponent,
                importedAt: now,
                bpmIsEstimated: analysis?.estimatedBPM == nil,
                tags: ["local", "user-music"],
                loudness: analysis?.meanVolume ?? 0.12,
                waveform: waveform
            )
            library.append(track)
            try write(library)
            cachedTracks = library
            return track
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Copies a catalogued track into this library while preserving its ID and
    /// attribution. This migrates projects created before music libraries became
    /// project-local without forcing another provider download.
    @discardableResult
    public func importExistingTrack(_ source: LocalMusicTrack) async throws -> LocalMusicTrack {
        var library = try tracks()
        if let existing = library.first(where: { $0.id == source.id }),
           FileManager.default.fileExists(atPath: existing.localFileURL.path) {
            return existing
        }
        guard FileManager.default.fileExists(atPath: source.localFileURL.path) else {
            throw MusicLibraryError.unreadableAudio
        }
        let asset = AVURLAsset(url: source.localFileURL)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw MusicLibraryError.unreadableAudio
        }

        try createDirectories()
        let fileExtension = source.localFileURL.pathExtension.lowercased()
        let destination = filesURL
            .appendingPathComponent(source.id.uuidString)
            .appendingPathExtension(fileExtension.isEmpty ? "m4a" : fileExtension)
        let copied = !FileManager.default.fileExists(atPath: destination.path)
        if copied { try FileManager.default.copyItem(at: source.localFileURL, to: destination) }
        do {
            var migrated = source
            migrated.localFileURL = destination
            library.removeAll { $0.id == source.id }
            library.append(migrated)
            try write(library)
            cachedTracks = library
            return migrated
        } catch {
            if copied { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    }

    public func remove(id: UUID) throws {
        var library = try tracks()
        guard let track = library.first(where: { $0.id == id }) else { return }
        library.removeAll { $0.id == id }
        try write(library)
        cachedTracks = library
        try? FileManager.default.removeItem(at: track.localFileURL)
    }

    private var filesURL: URL { rootURL.appendingPathComponent("Files", isDirectory: true) }
    private var catalogURL: URL { rootURL.appendingPathComponent("tracks.json") }

    private func createDirectories() throws {
        try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
    }

    private func write(_ tracks: [LocalMusicTrack]) throws {
        let data = try JSONEncoder.veloEdit.encode(tracks)
        try data.write(to: catalogURL, options: .atomic)
    }
}

public struct LocalMusicSelector: Sendable {
    public init() {}

    public func select(
        for directive: MusicDirective,
        from tracks: [LocalMusicTrack],
        excluding excludedID: UUID? = nil,
        excludingIdentities: Set<String> = [],
        minimumScore: Double? = nil
    ) -> LocalMusicTrack? {
        let available = tracks.filter {
            $0.id != excludedID &&
                !excludingIdentities.contains($0.selectionIdentity) &&
                AutomaticSoundtrackSuitability.accepts($0, directive: directive) &&
                FileManager.default.fileExists(atPath: $0.localFileURL.path)
        }
        if let requestedID = directive.trackID,
           let requested = available.first(where: { $0.id == requestedID }) {
            return requested
        }
        guard let selected = available.max(by: { score($0, directive: directive) < score($1, directive: directive) }) else {
            return nil
        }
        if let minimumScore, score(selected, directive: directive) < minimumScore { return nil }
        return selected
    }

    public func score(_ track: LocalMusicTrack, directive: MusicDirective) -> Double {
        guard AutomaticSoundtrackSuitability.accepts(track, directive: directive) else { return -1 }
        if let request = directive.searchRequests?.first, request.exactTrack,
           request.matches(title: track.title, artist: track.author) { return 2 }
        let intent = MusicIntent(directive: directive)
        let desired = intent.mood.union(intent.genres)
        let semantic = AutomaticSoundtrackSuitability.semanticMatch(genres: track.genres, moods: track.moods, tags: track.tags ?? [], desired: desired)
        let bpm = max(0, 1 - abs(track.bpm - directive.bpm) / 80)
        let desiredEnergy = intent.energy
        let energy = max(0, 1 - abs(track.energy - desiredEnergy))
        let character = AutomaticSoundtrackSuitability.characterAdjustment(genres: track.genres, moods: track.moods, tags: track.tags ?? [], desired: desired, request: directive.searchRequests?.first)
        return semantic * 0.48 + bpm * 0.22 + energy * 0.30 + character
    }

    private static func tokens(for style: MusicStyle) -> Set<String> {
        switch style {
        case .energetic: return ["energetic", "energy", "upbeat", "action", "dynamic", "энергичный", "драйв"]
        case .cinematic: return ["cinematic", "epic", "dramatic", "film", "кинематографичный", "эпичный"]
        case .calm: return ["calm", "ambient", "relaxing", "soft", "спокойный", "нежный"]
        case .joyful: return ["happy", "joyful", "bright", "uplifting", "весёлый", "радостный"]
        case .electronic: return ["electronic", "synth", "techno", "edm", "электронный"]
        case .acoustic: return ["acoustic", "guitar", "folk", "organic", "акустический"]
        }
    }

    private static func energy(for style: MusicStyle) -> Double {
        switch style {
        case .energetic, .electronic: return 0.64
        case .cinematic: return 0.52
        case .joyful: return 0.56
        case .acoustic: return 0.42
        case .calm: return 0.24
        }
    }
}

/// Places automatically generated cuts on the selected track's beat grid.
/// It only shortens source ranges, so synchronization never reads beyond a
/// candidate selected by the Story Engine.
public struct MusicBeatSynchronizer: Sendable {
    public init() {}

    public func synchronize(_ timeline: Timeline, to track: LocalMusicTrack, analyzedStructure: MusicStructure? = nil, structuralOnly: Bool = false) -> Timeline {
        var result = refreshingStructure(in: timeline, for: track, analyzedStructure: analyzedStructure)
        let movieDuration = max(0.1, result.duration)
        let structure = analyzedStructure ?? result.music?.structure ?? MusicSyncEngine().analyze(bpm: track.bpm, duration: movieDuration, energy: track.energy)
        // Unknown rhythm must not shorten speech, actions or manual edits.
        guard structure.analysisIsMeasured == true, (structure.tempoConfidence ?? 0) >= 0.65 else { return result }
        let beat = structure.beatInterval
        let sections = structure.sections
        if var directive = result.music {
            directive.bpm = structure.bpm
            directive.structure = structure
            result.music = directive
        }
        for index in result.items.indices where result.items[index].overlay == nil {
            var item = result.items[index]
            guard !item.locked, ![StoryRole.climax, .reaction, .outro].contains(item.storyRole ?? .bRoll),
                  result.editorialBeatPlan == nil else { continue }
            // Evidence-based plans are synchronized by moving the music window,
            // not by cutting an uninspected word or completed action.
            // Earlier clips may already have been shortened in this pass. Use
            // their updated durations for the current boundary; otherwise the
            // next clip is snapped against its stale pre-sync start time.
            item.timelineStart = result.items[..<index]
                .filter { $0.overlay == nil }
                .reduce(0) { $0 + $1.timelineDuration }
            let nextPrimary = result.items.indices.dropFirst(index + 1)
                .map { result.items[$0] }
                .first { $0.overlay == nil && $0.kind != .title }
            let structuralBoundary = nextPrimary.map { next in
                item.storyRole != next.storyRole
                    || (item.eventSceneID != nil && next.eventSceneID != nil && item.eventSceneID != next.eventSceneID)
                    || (item.eventID != nil && next.eventID != nil && item.eventID != next.eventID)
                    || item.storyRole == .climax || item.storyRole == .reaction || item.storyRole == .outro
            } ?? (item.storyRole == .outro)
            if structuralOnly, !structuralBoundary { continue }
            let beatGroup: Double
            switch item.storyRole {
            case .action, .climax: beatGroup = beat
            case .buildup, .setup: beatGroup = beat * 2
            case .intro, .reaction, .outro: beatGroup = beat * 4
            default: beatGroup = track.energy >= 0.72 ? beat : beat * 2
            }
            guard item.timelineDuration >= beatGroup * 1.25,
                  item.speedRamp == nil,
                  !item.isFreezeFrame else { continue }
            let desiredEnd = item.timelineStart + item.timelineDuration
            let structuralAnchors: [Double]
            switch item.storyRole {
            case .intro, .reaction, .outro:
                structuralAnchors = (structure.phraseConfidence ?? 0) >= 0.34
                    ? (structure.phraseBoundaries ?? [])
                    : (structure.downbeatTimestamps ?? structure.barBoundaries ?? [])
            case .setup, .buildup:
                structuralAnchors = structure.downbeatTimestamps ?? structure.barBoundaries ?? []
            case .action:
                structuralAnchors = (structure.accents ?? []).filter {
                    $0.strength >= 0.58 && ($0.confidence ?? 0.5) >= 0.28 && [.strongBeat, .downbeat, .transition, .onset].contains($0.kind)
                }.map(\.time)
            case .climax:
                structuralAnchors = (structure.accents ?? []).filter {
                    $0.strength >= 0.64 && ($0.confidence ?? 0.5) >= 0.28 && [.drop, .sectionPeak, .phrase, .downbeat].contains($0.kind)
                }.map(\.time)
            default:
                structuralAnchors = structure.beatTimestamps ?? []
            }
            var anchored = structuralAnchors
                .filter { $0 > item.timelineStart + 0.75 && $0 <= desiredEnd + 0.000_001 }
                .max()
                .map { $0 - item.timelineStart }
            if item.storyRole == .climax,
               let climaxAnchor = structuralAnchors
                .filter({ $0 > item.timelineStart + item.timelineDuration * 0.30 && $0 <= item.timelineStart + item.timelineDuration * 0.62 })
                .min(by: { abs($0 - (item.timelineStart + item.timelineDuration * 0.45)) < abs($1 - (item.timelineStart + item.timelineDuration * 0.45)) }) {
                anchored = min(item.timelineDuration, (climaxAnchor - item.timelineStart) / 0.45)
            }
            let groups = max(1, floor(item.timelineDuration / beatGroup))
            let snapped = anchored ?? groups * beatGroup
            guard snapped >= 0.75, snapped <= item.timelineDuration else { continue }
            item.timelineDuration = snapped
            if item.kind == .title {
                item.sourceDuration = snapped
            } else {
                item.sourceDuration = min(item.sourceDuration, snapped * item.speed)
            }
            let section = sections.last(where: { item.timelineStart >= $0.start })?.kind.rawValue ?? MusicSectionKind.intro.rawValue
            let measured = structure.analysisIsMeasured == true ? "DSP" : "BPM fallback"
            item.explanation.append("Монтажная граница синхронизирована с \(Int(structure.bpm.rounded())) BPM · \(measured) · музыкальная секция \(section)")
            result.items[index] = item
        }
        result.items = TimelineTiming.retimed(result.items)
        return result
    }

    /// Updates the beat grid for a newly selected track without re-trimming
    /// already edited video clips. Manual soundtrack changes must be audio-only.
    public func refreshingStructure(in timeline: Timeline, for track: LocalMusicTrack, analyzedStructure: MusicStructure? = nil) -> Timeline {
        var result = timeline
        guard var directive = result.music else { return result }
        directive.structure = analyzedStructure ?? MusicSyncEngine().analyze(
            bpm: track.bpm,
            duration: max(0.1, result.duration),
            energy: track.energy
        )
        result.music = directive
        return result
    }

}
