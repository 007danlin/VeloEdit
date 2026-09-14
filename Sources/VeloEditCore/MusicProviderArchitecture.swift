import Foundation

public enum MusicProviderAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
    case coolingDown(until: Date)
}

/// A provider-neutral request produced by Story Engine / AI Director.
/// Providers never need to know how the montage was planned.
public struct MusicIntent: Hashable, Sendable {
    public var request: MusicSearchRequest?
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
        self.request = nil
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
        request = directive.searchRequests?.first
        if let request, !request.exactTrack {
            let descriptors = MusicSearchRequest.words(request.query)
            mood.formUnion(descriptors)
            genres.formUnion(descriptors.intersection(["rock", "metal", "electronic", "acoustic", "jazz", "piano", "techno", "folk", "pop"]))
        }
    }

    public var searchQuery: String {
        if let request, !request.query.isEmpty { return request.query }
        // Automatic soundtracks should feel deliberately musical rather than
        // merely matching a technical genre tag. These leading terms also
        // steer providers away from harsh utility/background results.
        let lively = !mood.isDisjoint(with: ["energetic", "upbeat", "happy", "joyful", "bright"])
        let aestheticTerms: [String]
        if lively { aestheticTerms = ["bright", "upbeat", "groove", "instrumental"] }
        else if !mood.isDisjoint(with: ["calm", "ambient", "soft", "peaceful"]) {
            aestheticTerms = ["peaceful", "warm", "gentle", "instrumental"]
        } else if !mood.isDisjoint(with: ["cinematic", "inspiring", "hopeful"]) {
            aestheticTerms = ["inspiring", "hopeful", "cinematic", "instrumental"]
        } else { aestheticTerms = ["melodic", "instrumental"] }
        let contextualTerms = Array(mood.union(genres)).sorted()
        let additional = contextualTerms.filter { !aestheticTerms.contains($0) }
        return Array((aestheticTerms + additional).prefix(8)).joined(separator: " ")
    }

    private static func tokens(for style: MusicStyle) -> (moods: Set<String>, genres: Set<String>) {
        switch style {
        case .energetic: return (["energetic", "adventure", "upbeat", "travel"], ["electronic", "cinematic"])
        case .cinematic: return (["cinematic", "inspiring", "hopeful", "adventure"], ["cinematic", "orchestral"])
        case .calm: return (["calm", "peaceful", "warm", "soft"], ["ambient", "acoustic"])
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
    /// Online cascade stage; providers within one stage race each other.
    var fallbackTier: Int { get }
    func availability() async -> MusicProviderAvailability
    func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack]
    func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack
    func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata
    func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord
}

public extension MusicProvider {
    var fallbackTier: Int { 0 }
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

private enum OnlineProviderAttempt: Sendable {
    case success(provider: String, track: LocalMusicTrack)
    case failure(MusicProviderFailure, tier: Int)
    case cancelled(tier: Int)
    case deadline
    case advanceCascade(Int)
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

/// Provider orchestrator: suitable local files first, public downloadable
/// sources next, and a relaxed local fallback when acquisition fails.
public actor MusicLibrary {
    private let localLibrary: LocalMusicLibrary
    private let reusableCache: LocalMusicLibrary?
    private let providers: [any MusicProvider]
    private let onlineTimeout: TimeInterval
    private let cascadeDelay: TimeInterval
    private let health: MusicProviderHealthRegistry
    private var bundledPrepared = false
    private var onlinePrefetchTasks: [String: Task<Void, Never>] = [:]

    public init(
        localLibrary: LocalMusicLibrary,
        providers: [any MusicProvider],
        health: MusicProviderHealthRegistry = MusicProviderHealthRegistry(),
        reusableCache: LocalMusicLibrary? = nil,
        onlineTimeout: TimeInterval = 45,
        cascadeDelay: TimeInterval = 3
    ) {
        self.localLibrary = localLibrary
        self.reusableCache = reusableCache
        self.providers = providers.sorted { $0.priority < $1.priority }
        self.health = health
        self.onlineTimeout = max(0.05, onlineTimeout)
        self.cascadeDelay = max(0.01, cascadeDelay)
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
        excludingIdentities: Set<String> = [],
        preferCachedOnline: Bool = false,
        preferFreshOnline: Bool = false
    ) async -> MusicResolution {
        await prepareBundledCatalogIfNeeded()
        var localTracks = ((try? await localLibrary.tracks()) ?? []).filter(\.isPlayable)
        if let requestedTrackID, let requested = localTracks.first(where: { $0.id == requestedTrackID }) {
            await remember(requested)
            return MusicResolution(track: requested, catalog: localTracks)
        }

        // A named recording is resolved before mood matching. Novelty history
        // never overrides an explicit user request for a previously used song.
        if let request = intent.request, request.exactTrack,
           let exact = localTracks.first(where: { request.matches(title: $0.title, artist: $0.author) }) {
            await remember(exact)
            return MusicResolution(track: exact, catalog: localTracks)
        }
        let preferences = await ExplicitEditorialPreferenceStore.shared.snapshot()
        let excludingIdentities = intent.request?.exactTrack == true ? excludingIdentities : excludingIdentities.union(preferences.excludedIdentities)
        if intent.request?.exactTrack != true { localTracks.removeAll { preferences.excludes($0) } }
        if let reusableCache, !preferFreshOnline || intent.request?.exactTrack == true {
            let cached = ((try? await reusableCache.tracks()) ?? []).filter { $0.isPlayable && (intent.request?.exactTrack == true || $0.noveltyIdentities.isDisjoint(with: excludingIdentities)) }
            let chosen: LocalMusicTrack?
            if let request = intent.request, request.exactTrack {
                chosen = cached.first { request.matches(title: $0.title, artist: $0.author) }
            } else {
                chosen = Self.suitableLocalTrack(for: intent, tracks: cached, preferences: preferences)
            }
            if let chosen, let imported = try? await localLibrary.importProviderTrack(MusicProviderTrack(local: chosen), downloadedFileURL: chosen.localFileURL) {
                localTracks = ((try? await localLibrary.tracks()) ?? localTracks).filter(\.isPlayable)
                return MusicResolution(track: imported, catalog: localTracks)
            }
        }
        let eligible = localTracks.filter {
            $0.id != excludedID && $0.noveltyIdentities.isDisjoint(with: excludingIdentities)
        }
        let preferredLocal = preferCachedOnline ? Self.suitableLocalTrack(for: intent, tracks: eligible.filter { $0.sourceProvider.isOnline }, preferences: preferences) : nil
        if !preferFreshOnline, intent.request?.exactTrack != true,
           let local = preferredLocal ?? Self.suitableLocalTrack(for: intent, tracks: eligible, preferences: preferences) {
            await remember(local)
            return MusicResolution(track: local, catalog: localTracks)
        }
        if Task.isCancelled { return MusicResolution(track: nil, catalog: localTracks) }
        var onlineExclusions = excludingIdentities
        if let excluded = localTracks.first(where: { $0.id == excludedID }) { onlineExclusions.formUnion(excluded.noveltyIdentities) }
        // An explicit title overrides novelty, including when only a remote
        // source still has the requested recording.
        if intent.request?.exactTrack == true { onlineExclusions = [] }
        var online = await firstOnlineTrack(for: intent, excludingIdentities: onlineExclusions)
        if online.track == nil, intent.request != nil, !Task.isCancelled {
            // Exhaust exact sources first, then ask every provider for an
            // alternative. Preserve the failed request in diagnostics.
            online.failures.append(MusicProviderFailure(provider: "music-search", reason: "Не найден доступный аудиофайл по запросу «\(intent.searchQuery)»; подобрана альтернатива."))
            var alternative = intent
            alternative.request = nil
            let fallback = await firstOnlineTrack(for: alternative, excludingIdentities: excludingIdentities)
            online.track = fallback.track
            online.failures += fallback.failures
        }
        if let downloaded = online.track {
            localTracks = ((try? await localLibrary.tracks()) ?? localTracks).filter(\.isPlayable)
            if !localTracks.contains(where: { $0.id == downloaded.id }) { localTracks.append(downloaded) }
            return MusicResolution(track: downloaded, catalog: localTracks, failures: online.failures)
        }
        if Task.isCancelled { return MusicResolution(track: nil, catalog: localTracks, failures: online.failures) }
        // Fresh-online mode must still be able to use an unheard cached track
        // when all networks fail. Materialize a project-owned copy.
        if let reusableCache {
            let cached = ((try? await reusableCache.tracks()) ?? []).filter {
                $0.isPlayable && $0.noveltyIdentities.isDisjoint(with: onlineExclusions)
            }
            let ranked = Self.ranked(cached.map(MusicProviderTrack.init(local:)), for: intent, preferences: preferences)
            for candidate in ranked.prefix(5) {
                guard let file = candidate.localFileURL else { continue }
                if let imported = try? await localLibrary.importProviderTrack(candidate, downloadedFileURL: file) {
                    localTracks = ((try? await localLibrary.tracks()) ?? localTracks).filter(\.isPlayable)
                    return MusicResolution(track: imported, catalog: localTracks, failures: online.failures)
                }
            }
        }
        let fallback = Self.localFallback(for: intent.directive, tracks: localTracks, excluding: excludedID, excludingIdentities: onlineExclusions)
        if let fallback { await remember(fallback) }
        return MusicResolution(
            track: fallback,
            catalog: localTracks,
            failures: online.failures
        )
    }

    static func suitableLocalTrack(for intent: MusicIntent, tracks: [LocalMusicTrack], preferences: ExplicitEditorialPreferenceSnapshot = .init()) -> LocalMusicTrack? {
        let candidates = tracks.filter { track in
            guard AutomaticSoundtrackSuitability.accepts(MusicProviderTrack(local: track), intent: intent) else { return false }
            if let request = intent.request {
                if request.exactTrack { return request.matches(title: track.title, artist: track.author) }
                let desired = MusicSearchRequest.words(request.query)
                let known = MusicSearchRequest.words((track.genres + track.moods + (track.tags ?? [])).joined(separator: " "))
                guard !desired.isEmpty, Double(desired.intersection(known).count) / Double(desired.count) >= 0.5 else { return false }
            }
            return abs(track.energy - intent.energy) <= 0.30 && track.duration >= min(30, intent.durationRange.lowerBound)
        }
        let ranked = candidates.sorted { candidateScore(MusicProviderTrack(local: $0), intent: intent) + preferences.musicAdjustment($0, style: intent.directive.style) > candidateScore(MusicProviderTrack(local: $1), intent: intent) + preferences.musicAdjustment($1, style: intent.directive.style) }
        guard let best = ranked.first, candidateScore(MusicProviderTrack(local: best), intent: intent) >= 0.52 else { return nil }
        return best
    }

    /// Starts an optional network fetch without making film creation wait for
    /// DNS, a blocked provider, or a slow download. A completed track is kept
    /// in the project cache and can be selected by the current film if it is
    /// ready in time, or by the next film otherwise.
    public func scheduleOnlineTrack(for intent: MusicIntent, excludingIdentities: Set<String> = []) {
        let key = Self.prefetchKey(for: intent)
        guard onlinePrefetchTasks[key] == nil else { return }
        onlinePrefetchTasks[key] = Task { [weak self] in
            await self?.prefetchOnlineTrack(for: intent, excludingIdentities: excludingIdentities, key: key)
        }
    }

    /// Explicit online refresh for the UI. It is optional and never required
    /// for Story Engine to create a film.
    public func prepareOnlineCatalog(styles: [MusicStyle] = MusicStyle.allCases) async -> [LocalMusicTrack] {
        await prepareBundledCatalogIfNeeded()
        var downloaded: [LocalMusicTrack] = []
        var excludedIdentities = Set(
            ((try? await localLibrary.tracks()) ?? [])
                .filter { $0.sourceProvider.isOnline }
                .flatMap { $0.noveltyIdentities }
        )
        for style in styles {
            let directive = MusicDirective(style: style, bpm: Self.defaultBPM(for: style))
            let result = await firstOnlineTrack(
                for: MusicIntent(directive: directive),
                excludingIdentities: excludedIdentities
            )
            guard let track = result.track else { continue }
            if !downloaded.contains(where: { $0.id == track.id }) { downloaded.append(track) }
            excludedIdentities.formUnion(track.noveltyIdentities)
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

    private func prefetchOnlineTrack(
        for intent: MusicIntent,
        excludingIdentities: Set<String>,
        key: String
    ) async {
        defer { onlinePrefetchTasks[key] = nil }
        let cachedIdentities = Set(
            ((try? await localLibrary.tracks()) ?? [])
                .filter { $0.sourceProvider.isOnline }
                .flatMap { $0.noveltyIdentities }
        )
        _ = await firstOnlineTrack(
            for: intent,
            excludingIdentities: excludingIdentities.union(cachedIdentities)
        )
    }

    /// Cascade through independent sources. Failures advance immediately; a
    /// slow stage gets a bounded head start before the next stage joins it.
    /// Only a complete playable download wins and cancels the remaining work.
    private func firstOnlineTrack(
        for intent: MusicIntent,
        excludingIdentities: Set<String>
    ) async -> (track: LocalMusicTrack?, failures: [MusicProviderFailure]) {
        var eligible: [any MusicProvider] = []
        var failures: [MusicProviderFailure] = []
        for provider in providers where provider.priority >= 100 {
            if case .coolingDown(let until) = await health.availability(for: provider.identifier) {
                failures.append(MusicProviderFailure(
                    provider: provider.identifier,
                    reason: "временно недоступен до \(until.formatted())"
                ))
            } else {
                eligible.append(provider)
            }
        }
        guard !eligible.isEmpty else { return (nil, failures) }

        let health = self.health
        let onlineTimeout = self.onlineTimeout
        let cascadeDelay = self.cascadeDelay
        let raced = await withTaskGroup(
            of: OnlineProviderAttempt.self,
            returning: (LocalMusicTrack?, [MusicProviderFailure]).self
        ) { group in
            group.addTask {
                do { try await Task.sleep(for: .seconds(onlineTimeout)); return .deadline }
                catch { return .advanceCascade(-1) }
            }
            let grouped = Dictionary(grouping: eligible, by: { $0.fallbackTier })
            let stages = grouped.keys.sorted().compactMap { grouped[$0] }
            var nextStage = 0
            var pending = 0
            var pendingByTier: [Int: Int] = [:]
            func launchNextStage(in group: inout TaskGroup<OnlineProviderAttempt>) {
                guard nextStage < stages.count, !Task.isCancelled else { return }
                let stage = stages[nextStage]
                nextStage += 1
                pending += stage.count
                if let tier = stage.first?.fallbackTier { pendingByTier[tier] = stage.count }
                for provider in stage {
                    group.addTask {
                        await Self.onlineAttempt(provider: provider, intent: intent,
                            excludingIdentities: excludingIdentities, health: health)
                    }
                }
                if nextStage < stages.count {
                    let token = nextStage
                    group.addTask {
                        do { try await Task.sleep(for: .seconds(cascadeDelay)); return .advanceCascade(token) }
                        catch { return .advanceCascade(-1) }
                    }
                }
            }
            launchNextStage(in: &group)

            var attemptFailures: [MusicProviderFailure] = []
            while let result = await group.next() {
                if Task.isCancelled { group.cancelAll(); return (nil, attemptFailures) }
                switch result {
                case .success(_, let track):
                    group.cancelAll()
                    return (track, attemptFailures)
                case .failure(let failure, let tier):
                    pending -= 1
                    pendingByTier[tier, default: 0] -= 1
                    attemptFailures.append(failure)
                case .cancelled(let tier):
                    pending -= 1
                    pendingByTier[tier, default: 0] -= 1
                case .advanceCascade(let token):
                    if token == nextStage { launchNextStage(in: &group) }
                case .deadline:
                    group.cancelAll()
                    attemptFailures.append(MusicProviderFailure(provider: "music-search", reason: "Превышено время ожидания источников; используется локальная музыка."))
                    return (nil, attemptFailures)
                }
                if nextStage < stages.count,
                   let latestTier = stages[nextStage - 1].first?.fallbackTier,
                   pendingByTier[latestTier] == 0 {
                    launchNextStage(in: &group)
                } else if pending <= 0 {
                    group.cancelAll(); break
                }
            }
            return (nil, attemptFailures)
        }
        failures.append(contentsOf: raced.1)
        failures.sort { $0.provider < $1.provider }
        if let track = raced.0 { await remember(track) }
        return (raced.0, failures)
    }

    private static func onlineAttempt(
        provider: any MusicProvider,
        intent: MusicIntent,
        excludingIdentities: Set<String>,
        health: MusicProviderHealthRegistry
    ) async -> OnlineProviderAttempt {
        do {
            guard case .available = await provider.availability() else {
                _ = await health.recordFailure(for: provider.identifier)
                return .failure(MusicProviderFailure(
                    provider: provider.identifier,
                    reason: "источник недоступен"
                ), tier: provider.fallbackTier)
            }
            let candidates = try await provider.search(intent).filter {
                $0.noveltyIdentities.isDisjoint(with: excludingIdentities) &&
                    (intent.request?.exactTrack != true || intent.request!.matches(title: $0.metadata.title, artist: $0.metadata.artist))
            }
            let preferences = await ExplicitEditorialPreferenceStore.shared.snapshot()
            let rankedCandidates = Self.ranked(candidates, for: intent, preferences: preferences)
            guard !rankedCandidates.isEmpty else {
                return .failure(MusicProviderFailure(
                    provider: provider.identifier,
                    reason: "подходящих треков нет"
                ), tier: provider.fallbackTier)
            }
            var lastDownloadError: Error?
            for candidate in rankedCandidates.prefix(5) {
                do {
                    try Task.checkCancellation()
                    let track = try await provider.download(candidate)
                    guard track.isPlayable, track.duration.isFinite, track.duration > 0 else { throw MusicLibraryError.unreadableAudio }
                    try Task.checkCancellation()
                    await health.recordSuccess(for: provider.identifier)
                    return .success(provider: provider.identifier, track: track)
                } catch {
                    if Task.isCancelled || Self.isCancellation(error) { return .cancelled(tier: provider.fallbackTier) }
                    lastDownloadError = error
                }
            }
            _ = await health.recordFailure(for: provider.identifier)
            return .failure(MusicProviderFailure(
                provider: provider.identifier,
                reason: lastDownloadError?.localizedDescription ?? "не удалось скачать подходящий трек"
            ), tier: provider.fallbackTier)
        } catch {
            if Task.isCancelled || Self.isCancellation(error) { return .cancelled(tier: provider.fallbackTier) }
            _ = await health.recordFailure(for: provider.identifier)
            return .failure(MusicProviderFailure(
                provider: provider.identifier,
                reason: error.localizedDescription
            ), tier: provider.fallbackTier)
        }
    }

    private func remember(_ track: LocalMusicTrack) async {
        guard let reusableCache, track.sourceProvider != .bundled, !Task.isCancelled else { return }
        _ = try? await reusableCache.importProviderTrack(MusicProviderTrack(local: track), downloadedFileURL: track.localFileURL)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }

    private static func prefetchKey(for intent: MusicIntent) -> String {
        let bpm = Int(((intent.bpmRange.lowerBound + intent.bpmRange.upperBound) / 2).rounded())
        return "\(intent.searchQuery)|\(bpm)"
    }

    private static func best(_ candidates: [MusicProviderTrack], for intent: MusicIntent) -> MusicProviderTrack? {
        ranked(candidates, for: intent).first
    }

    private static func ranked(_ candidates: [MusicProviderTrack], for intent: MusicIntent, preferences: ExplicitEditorialPreferenceSnapshot = .init()) -> [MusicProviderTrack] {
        candidates.filter { AutomaticSoundtrackSuitability.accepts($0, intent: intent) }
            .sorted { candidateScore($0, intent: intent) + preferences.musicAdjustment($0, style: intent.directive.style) > candidateScore($1, intent: intent) + preferences.musicAdjustment($1, style: intent.directive.style) }
    }

    static func candidateScore(_ candidate: MusicProviderTrack, intent: MusicIntent) -> Double {
        let metadata = candidate.metadata
        let tokens = MusicSearchRequest.words((metadata.genres + metadata.moods).joined(separator: " "))
        let desired = intent.mood.union(intent.genres)
        let semantic = AutomaticSoundtrackSuitability.semanticMatch(genres: metadata.genres, moods: metadata.moods, tags: metadata.tags, desired: desired)
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
        let aestheticTokens: Set<String> = [
            "beautiful", "melodic", "inspiring", "emotional", "cinematic",
            "uplifting", "atmospheric", "warm", "dreamy", "elegant"
        ]
        let harshTokens: Set<String> = [
            "aggressive", "hard", "heavy", "metal", "trap", "dubstep", "intense"
        ]
        let aesthetic = min(1, Double(tokens.intersection(aestheticTokens).count) / 3)
        let harshness = min(1, Double(tokens.intersection(harshTokens).count) / 2)
        let semanticScore = semantic * 0.42
        let rhythmScore = bpm * 0.15
        let energyScore = energy * 0.18
        let durationScore = duration * 0.10
        let vocalScore = instrumental * 0.08
        let aestheticScore = aesthetic * 0.12
        let explicit = intent.request.map { MusicSearchRequest.words($0.query) } ?? []
        let harshnessPenalty = !explicit.isDisjoint(with: harshTokens) ? 0 : harshness * 0.12
        let character = AutomaticSoundtrackSuitability.characterAdjustment(genres: metadata.genres, moods: metadata.moods, tags: metadata.tags, desired: desired, request: intent.request)
        return semanticScore + rhythmScore + energyScore + durationScore + vocalScore + aestheticScore + character - harshnessPenalty
    }

    private static func localFallback(
        for directive: MusicDirective,
        tracks: [LocalMusicTrack],
        excluding excludedID: UUID?,
        excludingIdentities: Set<String>
    ) -> LocalMusicTrack? {
        LocalMusicSelector().select(
            for: directive,
            from: tracks.filter { $0.noveltyIdentities.isDisjoint(with: excludingIdentities) },
            excluding: excludedID,
            excludingIdentities: excludingIdentities
        ) ?? LocalMusicSelector().select(for: directive, from: tracks, excluding: excludedID)
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
        return MusicDirective(style: style, bpm: desired, searchRequests: request.map { [$0] })
    }
}
