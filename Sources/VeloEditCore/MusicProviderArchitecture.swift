import Foundation

public enum MusicProviderAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
    case coolingDown(until: Date)
}

/// A provider-neutral request produced by Story Engine / AI Director.
/// Providers never need to know how the montage was planned.
public struct MusicIntent: Hashable, Sendable {
    public var mood: Set<String>
    public var energy: Double
    public var genres: Set<String>
    public var bpmRange: ClosedRange<Double>
    public var durationRange: ClosedRange<Double>
    public var sceneType: String?
    public var startIntensity: Double
    public var endingIntensity: Double
    public var vocalsAllowed: Bool
    public var instrumentalPreferred: Bool

    public init(
        mood: Set<String>,
        energy: Double,
        genres: Set<String>,
        bpmRange: ClosedRange<Double>,
        durationRange: ClosedRange<Double>,
        sceneType: String? = nil,
        startIntensity: Double,
        endingIntensity: Double,
        vocalsAllowed: Bool = true,
        instrumentalPreferred: Bool = true
    ) {
        self.mood = Set(mood.map { $0.lowercased() })
        self.energy = min(max(0, energy), 1)
        self.genres = Set(genres.map { $0.lowercased() })
        self.bpmRange = min(bpmRange.lowerBound, bpmRange.upperBound)...max(bpmRange.lowerBound, bpmRange.upperBound)
        self.durationRange = max(1, min(durationRange.lowerBound, durationRange.upperBound))...max(1, max(durationRange.lowerBound, durationRange.upperBound))
        self.sceneType = sceneType
        self.startIntensity = min(max(0, startIntensity), 1)
        self.endingIntensity = min(max(0, endingIntensity), 1)
        self.vocalsAllowed = vocalsAllowed
        self.instrumentalPreferred = instrumentalPreferred
    }

    public init(directive: MusicDirective, timelineDuration: Double? = nil) {
        let autonomous = directive.autonomousIntent
        let targetBPM = autonomous?.desiredBPM ?? directive.bpm
        let desiredDuration = max(30, autonomous?.desiredDuration ?? timelineDuration ?? 150)
        let curve = autonomous?.narrativeEnergyCurve ?? []
        let styleTokens = Self.tokens(for: directive.style)
        self.init(
            mood: (autonomous?.moodTokens ?? []).union(styleTokens.moods),
            energy: autonomous?.desiredEnergy ?? Self.energy(for: directive.style),
            genres: styleTokens.genres,
            bpmRange: max(55, targetBPM - 14)...min(190, targetBPM + 14),
            durationRange: max(30, desiredDuration * 0.72)...max(45, desiredDuration * 1.8),
            sceneType: autonomous?.needsBuildAndDrop == true ? "build-and-drop" : nil,
            startIntensity: curve.first ?? 0.28,
            endingIntensity: curve.last ?? 0.34,
            vocalsAllowed: true,
            instrumentalPreferred: true
        )
    }

    public var searchQuery: String {
        Array(mood.union(genres)).sorted().prefix(6).joined(separator: " ")
    }

    private static func tokens(for style: MusicStyle) -> (moods: Set<String>, genres: Set<String>) {
        switch style {
        case .energetic: return (["energetic", "adventure", "upbeat", "travel"], ["electronic", "cinematic"])
        case .cinematic: return (["cinematic", "emotional", "dramatic", "adventure"], ["cinematic", "orchestral"])
        case .calm: return (["calm", "ambient", "soft", "travel"], ["ambient", "acoustic"])
        case .joyful: return (["joyful", "happy", "bright", "travel"], ["pop", "acoustic"])
        case .electronic: return (["energetic", "modern", "travel"], ["electronic", "synth"])
        case .acoustic: return (["calm", "warm", "emotional"], ["acoustic", "folk"])
        }
    }

    private static func energy(for style: MusicStyle) -> Double {
        switch style {
        case .energetic, .electronic: return 0.78
        case .cinematic: return 0.64
        case .joyful: return 0.62
        case .acoustic: return 0.44
        case .calm: return 0.28
        }
    }
}

public struct MusicTrackMetadata: Codable, Hashable, Sendable {
    public var title: String
    public var artist: String
    public var genres: [String]
    public var moods: [String]
    public var tags: [String]
    public var energy: Double
    public var bpm: Double
    public var duration: Double
    public var sourceName: String
    public var loudness: Double?
    public var waveform: [Double]?
    public var musicalKey: String?
    public var instrumental: Bool?

    public init(
        title: String,
        artist: String,
        genres: [String],
        moods: [String],
        tags: [String] = [],
        energy: Double,
        bpm: Double,
        duration: Double,
        sourceName: String,
        loudness: Double? = nil,
        waveform: [Double]? = nil,
        musicalKey: String? = nil,
        instrumental: Bool? = nil
    ) {
        self.title = title
        self.artist = artist
        self.genres = genres
        self.moods = moods
        self.tags = tags
        self.energy = min(max(0, energy), 1)
        self.bpm = min(max(40, bpm), 240)
        self.duration = max(0, duration)
        self.sourceName = sourceName
        self.loudness = loudness
        self.waveform = waveform
        self.musicalKey = musicalKey
        self.instrumental = instrumental
    }
}

public struct MusicProviderTrack: Identifiable, Hashable, Sendable {
    public var id: String
    public var sourceProvider: MusicSourceProvider
    public var metadata: MusicTrackMetadata
    public var license: MusicLicenseRecord
    public var sourcePageURL: URL
    public var downloadURL: URL?
    public var localFileURL: URL?

    public init(
        id: String,
        sourceProvider: MusicSourceProvider,
        metadata: MusicTrackMetadata,
        license: MusicLicenseRecord,
        sourcePageURL: URL,
        downloadURL: URL? = nil,
        localFileURL: URL? = nil
    ) {
        self.id = id
        self.sourceProvider = sourceProvider
        self.metadata = metadata
        self.license = license
        self.sourcePageURL = sourcePageURL
        self.downloadURL = downloadURL
        self.localFileURL = localFileURL
    }
}

public protocol MusicProvider: Sendable {
    var identifier: String { get }
    var sourceProvider: MusicSourceProvider { get }
    var priority: Int { get }
    func availability() async -> MusicProviderAvailability
    func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack]
    func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack
    func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata
    func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord
}

public struct MusicProviderFailure: Equatable, Sendable {
    public var provider: String
    public var reason: String
}

public struct MusicResolution: Sendable {
    public var track: LocalMusicTrack?
    public var catalog: [LocalMusicTrack]
    public var failures: [MusicProviderFailure]

    public init(track: LocalMusicTrack?, catalog: [LocalMusicTrack], failures: [MusicProviderFailure] = []) {
        self.track = track
        self.catalog = catalog
        self.failures = failures
    }
}

public struct MusicLibraryStatus: Equatable, Sendable {
    public var bundledCount: Int
    public var localCount: Int
    public var cachedOnlineCount: Int
    public var onlineProviderCount: Int
    public var unavailableProviders: [String]

    public init(bundledCount: Int = 0, localCount: Int = 0, cachedOnlineCount: Int = 0, onlineProviderCount: Int = 0, unavailableProviders: [String] = []) {
        self.bundledCount = bundledCount
        self.localCount = localCount
        self.cachedOnlineCount = cachedOnlineCount
        self.onlineProviderCount = onlineProviderCount
        self.unavailableProviders = unavailableProviders
    }

    public var offlineReady: Bool { bundledCount + localCount + cachedOnlineCount > 0 }
    public var localizedSummary: String {
        if offlineReady { return "Offline ready · \(bundledCount + localCount + cachedOnlineCount) треков локально" }
        return "Локальная музыка пока не подготовлена"
    }
}

public actor MusicProviderHealthRegistry {
    private struct FailureState: Sendable {
        var count: Int
        var coolingDownUntil: Date?
    }

    private var states: [String: FailureState] = [:]
    private let failureThreshold: Int
    private let cooldown: TimeInterval

    public init(failureThreshold: Int = 2, cooldown: TimeInterval = 15 * 60) {
        self.failureThreshold = max(1, failureThreshold)
        self.cooldown = max(1, cooldown)
    }

    public func availability(for provider: String, now: Date = Date()) -> MusicProviderAvailability {
        guard let state = states[provider], let until = state.coolingDownUntil else { return .available }
        if until <= now {
            states[provider] = nil
            return .available
        }
        return .coolingDown(until: until)
    }

    public func recordSuccess(for provider: String) {
        states[provider] = nil
    }

    @discardableResult
    public func recordFailure(for provider: String, now: Date = Date()) -> MusicProviderAvailability {
        var state = states[provider] ?? FailureState(count: 0, coolingDownUntil: nil)
        state.count += 1
        if state.count >= failureThreshold { state.coolingDownUntil = now.addingTimeInterval(cooldown) }
        states[provider] = state
        return state.coolingDownUntil.map(MusicProviderAvailability.coolingDown) ?? .available
    }
}

/// Offline-first provider orchestrator used by VeloEditPipeline. Provider
/// failures are contained here and are never promoted to a montage failure.
public actor MusicLibrary {
    private let localLibrary: LocalMusicLibrary
    private let providers: [any MusicProvider]
    private let health: MusicProviderHealthRegistry
    private var bundledPrepared = false
    private var onlinePrefetchTasks: [String: Task<Void, Never>] = [:]

    public init(
        localLibrary: LocalMusicLibrary,
        providers: [any MusicProvider],
        health: MusicProviderHealthRegistry = MusicProviderHealthRegistry()
    ) {
        self.localLibrary = localLibrary
        self.providers = providers.sorted { $0.priority < $1.priority }
        self.health = health
    }

    public func tracks() async throws -> [LocalMusicTrack] {
        await prepareBundledCatalogIfNeeded()
        return try await localLibrary.tracks().filter(\.isPlayable)
    }

    public func status() async -> MusicLibraryStatus {
        let tracks = (try? await self.tracks()) ?? []
        var unavailable: [String] = []
        for provider in providers where provider.priority >= 100 {
            if case .coolingDown = await health.availability(for: provider.identifier) {
                unavailable.append(provider.identifier)
            }
        }
        return MusicLibraryStatus(
            bundledCount: tracks.filter { $0.sourceProvider == .bundled }.count,
            localCount: tracks.filter { $0.sourceProvider == .user }.count,
            cachedOnlineCount: tracks.filter { $0.sourceProvider.isOnline }.count,
            onlineProviderCount: providers.filter { $0.priority >= 100 }.count,
            unavailableProviders: unavailable.sorted()
        )
    }

    public func resolve(
        _ intent: MusicIntent,
        requestedTrackID: UUID? = nil,
        excluding excludedID: UUID? = nil,
        preferCachedOnline: Bool = false
    ) async -> MusicResolution {
        await prepareBundledCatalogIfNeeded()
        var localTracks = ((try? await localLibrary.tracks()) ?? []).filter(\.isPlayable)
        if let requestedTrackID, let requested = localTracks.first(where: { $0.id == requestedTrackID }) {
            return MusicResolution(track: requested, catalog: localTracks)
        }

        let directive = intent.directive
        let selector = LocalMusicSelector()
        let sourceOrder: [MusicSourceProvider] = preferCachedOnline
            ? [.openverse, .freeToUse, .pixabay, .bundled, .user, .other]
            : [.bundled, .user, .openverse, .freeToUse, .pixabay, .other]
        for source in sourceOrder {
            let candidates = localTracks.filter { $0.sourceProvider == source }
            if let selected = selector.select(for: directive, from: candidates, excluding: excludedID, minimumScore: 0.30) {
                return MusicResolution(track: selected, catalog: localTracks)
            }
        }

        var failures: [MusicProviderFailure] = []
        for provider in providers where provider.priority >= 100 {
            if case .coolingDown(let until) = await health.availability(for: provider.identifier) {
                failures.append(MusicProviderFailure(provider: provider.identifier, reason: "временно недоступен до \(until.formatted())"))
                continue
            }
            do {
                guard case .available = await provider.availability() else {
                    _ = await health.recordFailure(for: provider.identifier)
                    failures.append(MusicProviderFailure(provider: provider.identifier, reason: "источник недоступен"))
                    continue
                }
                let found = try await provider.search(intent)
                guard let candidate = Self.best(found, for: intent) else {
                    failures.append(MusicProviderFailure(provider: provider.identifier, reason: "подходящих треков нет"))
                    continue
                }
                let downloaded = try await provider.download(candidate)
                await health.recordSuccess(for: provider.identifier)
                localTracks = ((try? await localLibrary.tracks()) ?? localTracks).filter(\.isPlayable)
                return MusicResolution(track: downloaded, catalog: localTracks, failures: failures)
            } catch {
                _ = await health.recordFailure(for: provider.identifier)
                failures.append(MusicProviderFailure(provider: provider.identifier, reason: error.localizedDescription))
            }
        }

        // Suitability is intentionally relaxed only after every provider has
        // been exhausted. Returning any playable local track is preferable to
        // failing the film because the network is unavailable.
        let fallback = LocalMusicSelector().select(for: directive, from: localTracks, excluding: excludedID)
        return MusicResolution(track: fallback, catalog: localTracks, failures: failures)
    }

    /// Starts an optional network fetch without making film creation wait for
    /// DNS, a blocked provider, or a slow download. A completed track is kept
    /// in the project cache and can be selected by the current film if it is
    /// ready in time, or by the next film otherwise.
    public func scheduleOnlineTrack(for intent: MusicIntent) {
        let key = Self.prefetchKey(for: intent)
        guard onlinePrefetchTasks[key] == nil else { return }
        onlinePrefetchTasks[key] = Task { [weak self] in
            await self?.prefetchOnlineTrack(for: intent, key: key)
        }
    }

    /// Explicit online refresh for the UI. It is optional and never required
    /// for Story Engine to create a film.
    public func prepareOnlineCatalog(styles: [MusicStyle] = MusicStyle.allCases) async -> [LocalMusicTrack] {
        await prepareBundledCatalogIfNeeded()
        var downloaded: [LocalMusicTrack] = []
        for provider in providers where provider.priority >= 100 {
            guard case .available = await health.availability(for: provider.identifier) else { continue }
            for style in styles {
                let directive = MusicDirective(style: style, bpm: Self.defaultBPM(for: style))
                let intent = MusicIntent(directive: directive)
                do {
                    let candidates = try await provider.search(intent)
                    guard let candidate = Self.best(candidates, for: intent) else { continue }
                    let track = try await provider.download(candidate)
                    if !downloaded.contains(where: { $0.id == track.id }) { downloaded.append(track) }
                    await health.recordSuccess(for: provider.identifier)
                } catch MusicLibraryError.duplicateSource {
                    continue
                } catch {
                    _ = await health.recordFailure(for: provider.identifier)
                    break
                }
            }
        }
        return downloaded
    }

    private func prepareBundledCatalogIfNeeded() async {
        guard !bundledPrepared else { return }
        bundledPrepared = true
        guard let provider = providers.first(where: { $0.sourceProvider == .bundled }) else { return }
        let intent = MusicIntent(directive: MusicDirective(style: .cinematic, bpm: 96))
        guard let catalog = try? await provider.search(intent) else { return }
        for candidate in catalog {
            _ = try? await provider.download(candidate)
        }
    }

    private func prefetchOnlineTrack(for intent: MusicIntent, key: String) async {
        defer { onlinePrefetchTasks[key] = nil }
        let existingIDs = Set(
            ((try? await localLibrary.tracks()) ?? [])
                .filter { $0.sourceProvider.isOnline }
                .compactMap(\.providerTrackID)
        )
        for provider in providers where provider.priority >= 100 {
            guard case .available = await health.availability(for: provider.identifier) else { continue }
            do {
                guard case .available = await provider.availability() else {
                    _ = await health.recordFailure(for: provider.identifier)
                    continue
                }
                let candidates = try await provider.search(intent).filter { !existingIDs.contains($0.id) }
                guard let candidate = Self.best(candidates, for: intent) else { continue }
                _ = try await provider.download(candidate)
                await health.recordSuccess(for: provider.identifier)
                return
            } catch MusicLibraryError.duplicateSource {
                continue
            } catch {
                _ = await health.recordFailure(for: provider.identifier)
            }
        }
    }

    private static func prefetchKey(for intent: MusicIntent) -> String {
        let bpm = Int(((intent.bpmRange.lowerBound + intent.bpmRange.upperBound) / 2).rounded())
        return "\(intent.searchQuery)|\(bpm)"
    }

    private static func best(_ candidates: [MusicProviderTrack], for intent: MusicIntent) -> MusicProviderTrack? {
        candidates.max { candidateScore($0, intent: intent) < candidateScore($1, intent: intent) }
    }

    private static func candidateScore(_ candidate: MusicProviderTrack, intent: MusicIntent) -> Double {
        let metadata = candidate.metadata
        let tokens = Set((metadata.genres + metadata.moods + metadata.tags).map { $0.lowercased() })
        let desired = intent.mood.union(intent.genres)
        let semantic = Double(tokens.intersection(desired).count) / Double(max(1, desired.count))
        let midpoint = (intent.bpmRange.lowerBound + intent.bpmRange.upperBound) / 2
        let bpm = max(0, 1 - abs(metadata.bpm - midpoint) / 80)
        let energy = max(0, 1 - abs(metadata.energy - intent.energy))
        let duration: Double
        if intent.durationRange.contains(metadata.duration) {
            duration = 1
        } else if metadata.duration < intent.durationRange.lowerBound {
            duration = min(1, metadata.duration / max(1, intent.durationRange.lowerBound))
        } else {
            duration = min(1, intent.durationRange.upperBound / max(1, metadata.duration))
        }
        let instrumental: Double = intent.instrumentalPreferred ? (metadata.instrumental == false ? 0 : 1) : 1
        let semanticScore = semantic * 0.42
        let rhythmScore = bpm * 0.18
        let energyScore = energy * 0.22
        let durationScore = duration * 0.10
        let vocalScore = instrumental * 0.08
        return semanticScore + rhythmScore + energyScore + durationScore + vocalScore
    }

    private static func defaultBPM(for style: MusicStyle) -> Double {
        switch style {
        case .energetic: return 124
        case .cinematic: return 88
        case .calm: return 72
        case .joyful: return 112
        case .electronic: return 120
        case .acoustic: return 94
        }
    }
}

private extension MusicIntent {
    var directive: MusicDirective {
        let desired = (bpmRange.lowerBound + bpmRange.upperBound) / 2
        let style: MusicStyle
        let tokens = mood.union(genres)
        if tokens.contains("acoustic") || tokens.contains("folk") { style = .acoustic }
        else if tokens.contains("electronic") || tokens.contains("synth") { style = .electronic }
        else if tokens.contains("calm") || tokens.contains("ambient") { style = .calm }
        else if tokens.contains("joyful") || tokens.contains("happy") { style = .joyful }
        else if tokens.contains("cinematic") || tokens.contains("dramatic") { style = .cinematic }
        else { style = energy >= 0.62 ? .energetic : .cinematic }
        return MusicDirective(style: style, bpm: desired)
    }
}
