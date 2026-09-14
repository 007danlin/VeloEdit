import Foundation
import AVFoundation
import Testing
@testable import VeloEditCore

private actor FailingMusicProvider: MusicProvider {
    nonisolated let identifier: String
    nonisolated let sourceProvider: MusicSourceProvider
    nonisolated let priority: Int
    private var searches = 0

    init(identifier: String, sourceProvider: MusicSourceProvider, priority: Int) {
        self.identifier = identifier
        self.sourceProvider = sourceProvider
        self.priority = priority
    }

    func availability() async -> MusicProviderAvailability { .available }
    func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack] {
        searches += 1
        throw URLError(.notConnectedToInternet)
    }
    func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack {
        throw URLError(.notConnectedToInternet)
    }
    func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata { track.metadata }
    func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord { track.license }
    func searchCount() -> Int { searches }
}

private actor DownloadableMusicProvider: MusicProvider {
    nonisolated let identifier = "downloadable-openverse"
    nonisolated let sourceProvider: MusicSourceProvider = .openverse
    nonisolated let priority = 100
    private let library: LocalMusicLibrary
    private let sourceURL: URL
    private let candidateIDs: [String]
    private let failingCandidateIDs: Set<String>
    private var searches = 0
    private var downloads = 0

    init(
        library: LocalMusicLibrary,
        sourceURL: URL,
        candidateIDs: [String] = ["10000000-0000-4000-8000-000000000001"],
        failingCandidateIDs: Set<String> = []
    ) {
        self.library = library
        self.sourceURL = sourceURL
        self.candidateIDs = candidateIDs
        self.failingCandidateIDs = failingCandidateIDs
    }

    func availability() async -> MusicProviderAvailability { .available }

    func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack] {
        searches += 1
        return candidateIDs.enumerated().map { index, id in
            MusicProviderTrack(
                id: id,
                sourceProvider: .openverse,
                metadata: MusicTrackMetadata(
                    title: index == 0 ? "Fresh online track" : "Fresh online track \(index + 1)",
                    artist: "Open artist",
                    genres: ["electronic"],
                    moods: ["energetic", "adventure"],
                    tags: index == 0 ? ["travel", "instrumental"] : ["instrumental"],
                    energy: index == 0 ? 0.84 : 0.70,
                    bpm: 126,
                    duration: 177.744,
                    sourceName: "Openverse",
                    instrumental: true
                ),
                license: MusicLicenseRecord(
                    name: "CC0 1.0 Universal",
                    url: URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")!,
                    sourceName: "Openverse",
                    sourceURL: URL(string: "https://openverse.org")!,
                    licenseCheckedAt: Date(),
                    requiresAttribution: false
                ),
                sourcePageURL: URL(string: "https://openverse.org")!,
                localFileURL: sourceURL
            )
        }
    }

    func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack {
        downloads += 1
        if failingCandidateIDs.contains(track.id) { throw URLError(.cannotDecodeContentData) }
        return try await library.importProviderTrack(track, downloadedFileURL: sourceURL)
    }

    func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata { track.metadata }
    func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord { track.license }
    func counts() -> (searches: Int, downloads: Int) { (searches, downloads) }
}

private actor SlowFailingMusicProvider: MusicProvider {
    nonisolated let identifier = "slow-free-to-use"
    nonisolated let sourceProvider: MusicSourceProvider = .freeToUse
    nonisolated let priority = 100
    private var searches = 0
    private var cancellations = 0

    func availability() async -> MusicProviderAvailability { .available }

    func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack] {
        searches += 1
        do {
            try await Task.sleep(for: .seconds(2))
        } catch {
            cancellations += 1
            throw error
        }
        throw URLError(.timedOut)
    }

    func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack {
        throw URLError(.timedOut)
    }

    func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata { track.metadata }
    func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord { track.license }
    func counts() -> (searches: Int, cancellations: Int) { (searches, cancellations) }
}

private func musicFixtureRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/Music", isDirectory: true)
}

private func temporaryMusicLibrary() -> (URL, LocalMusicLibrary) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("VeloEdit-MusicTests-\(UUID().uuidString)", isDirectory: true)
    return (root, LocalMusicLibrary(rootURL: root))
}

private func energeticDirective() -> MusicDirective {
    MusicDirective(style: .energetic, bpm: 128)
}

@Test func testAOfflineFilmResolutionUsesBundledMusicWithoutTouchingNetwork() async throws {
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundled = BundledMusicProvider(library: local, rootURL: musicFixtureRoot())
    let online = FailingMusicProvider(identifier: "offline", sourceProvider: .freeToUse, priority: 100)
    let system = MusicLibrary(localLibrary: local, providers: [bundled, online])

    let result = await system.resolve(MusicIntent(directive: energeticDirective()))

    #expect(result.track?.sourceProvider == .bundled)
    #expect(result.track?.isPlayable == true)
    #expect(await online.searchCount() == 0)
}

@Test func pipelineResolvesMusicAtFilmBuildStageWithoutNetworkDependency() async throws {
    let projectURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("VeloEdit-OfflinePipeline-\(UUID().uuidString)")
        .appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: projectURL) }
    let store = try ProjectStore(createAt: projectURL, name: "Offline")
    // This offline fixture must not inherit the user's downloaded soundtrack
    // cache; a valid cached online track otherwise makes the assertion flaky.
    let pipeline = VeloEditPipeline(store: store, musicLibrary: LocalMusicLibrary(rootURL: store.musicLibraryURL))

    let track = try await pipeline.prepareMusicTrack(for: energeticDirective())

    #expect(track.sourceProvider == .bundled)
    #expect(track.isPlayable)
}

@Test func newProjectRotationAvoidsRecentlySelectedRealTracksAndPersistsHistory() async throws {
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundled = BundledMusicProvider(library: local, rootURL: musicFixtureRoot())
    let online = FailingMusicProvider(identifier: "offline", sourceProvider: .freeToUse, priority: 100)
    let system = MusicLibrary(localLibrary: local, providers: [bundled, online])
    let historyURL = root.appendingPathComponent("recent-music.json")
    let history = LocalMusicSelectionHistoryStore(url: historyURL)

    let first = try #require(await system.resolve(MusicIntent(directive: energeticDirective())).track)
    try await history.record(first, selectedAt: Date(timeIntervalSince1970: 1))
    let recent = await history.recentIdentities()
    let second = try #require(await system.resolve(
        MusicIntent(directive: energeticDirective()),
        excludingIdentities: recent
    ).track)

    #expect(first.sourceProvider == .bundled)
    #expect(second.sourceProvider == .bundled)
    #expect(second.selectionIdentity != first.selectionIdentity)
    #expect(second.author == "HoliznaCC0")

    let reopenedHistory = LocalMusicSelectionHistoryStore(url: historyURL)
    #expect(await reopenedHistory.recentSelections().map(\.identity) == [first.selectionIdentity])
}

@Test func exhaustedRotationFallsBackToAPlayableAuthoredTrackOffline() async throws {
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundled = BundledMusicProvider(library: local, rootURL: musicFixtureRoot())
    let online = FailingMusicProvider(identifier: "offline", sourceProvider: .freeToUse, priority: 100)
    let system = MusicLibrary(localLibrary: local, providers: [bundled, online])
    let allBundledIdentities = Set(try await system.tracks().filter { $0.sourceProvider == .bundled }.map(\.selectionIdentity))

    let fallback = try #require(await system.resolve(
        MusicIntent(directive: energeticDirective()),
        excludingIdentities: allBundledIdentities,
        preferCachedOnline: true
    ).track)

    #expect(fallback.isPlayable)
    #expect(fallback.sourceProvider == .bundled)
    #expect(fallback.author == "HoliznaCC0")
}

@Test func everyBundledTrackIsAReadableHoliznaCC0AudioAsset() async throws {
    let manifestData = try Data(contentsOf: musicFixtureRoot().appendingPathComponent("manifest.json"))
    let json = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
    let tracks = try #require(json["tracks"] as? [[String: Any]])
    #expect(tracks.count == 12)
    for track in tracks {
        let file = try #require(track["file"] as? String)
        let artist = try #require(track["artist"] as? String)
        let license = try #require(track["license"] as? String)
        let sourceURL = try #require(track["sourceURL"] as? String)
        let declaredDuration = try #require(track["duration"] as? Double)
        let asset = AVURLAsset(url: musicFixtureRoot().appendingPathComponent(file))
        let measuredDuration = try await asset.load(.duration).seconds
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty == false)
        #expect(file.hasPrefix("holiznacc0-"))
        #expect(file.hasSuffix(".mp3"))
        #expect(artist == "HoliznaCC0")
        #expect(license == "CC0 1.0 Universal")
        #expect(sourceURL.contains("freemusicarchive.org/music/holiznacc0/"))
        #expect(measuredDuration > 90)
        #expect(abs(measuredDuration - declaredDuration) < 0.05)
    }
}

@Test func existingProjectBundledRecordsMigrateToHoliznaCatalog() async throws {
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let audioURL = musicFixtureRoot().appendingPathComponent("holiznacc0-lost-on-the-freeway.mp3")
    let stale = MusicProviderTrack(
        id: "b0000000-0000-4000-8000-000000000001",
        sourceProvider: .bundled,
        metadata: MusicTrackMetadata(
            title: "Old synthetic track",
            artist: "VeloEdit Studio",
            genres: ["synthetic"],
            moods: ["synthetic"],
            energy: 0.5,
            bpm: 120,
            duration: 177.744,
            sourceName: "Old catalog",
            instrumental: true
        ),
        license: MusicLicenseRecord(
            name: "Old license",
            url: URL(string: "about:blank")!,
            sourceName: "Old catalog"
        ),
        sourcePageURL: URL(string: "about:blank")!,
        localFileURL: audioURL
    )
    _ = try await local.importProviderTrack(stale, downloadedFileURL: audioURL)
    let bundled = BundledMusicProvider(library: local, rootURL: musicFixtureRoot())
    let system = MusicLibrary(localLibrary: local, providers: [bundled])

    let migrated = try #require(try await system.tracks().first(where: { $0.id.uuidString.lowercased() == stale.id }))

    #expect(migrated.title == "Lost On The Freeway")
    #expect(migrated.author == "HoliznaCC0")
    #expect(migrated.license.name == "CC0 1.0 Universal")
}

@Test func testBFreeToUseFailureFallsBackWithoutMontageError() async throws {
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundled = BundledMusicProvider(library: local, rootURL: musicFixtureRoot())
    let freeToUse = FailingMusicProvider(identifier: "free-to-use", sourceProvider: .freeToUse, priority: 100)
    let system = MusicLibrary(localLibrary: local, providers: [bundled, freeToUse])

    let result = await system.resolve(MusicIntent(directive: MusicDirective(style: .calm, bpm: 72)))

    #expect(result.track != nil)
    #expect(result.track?.sourceProvider == .bundled)
    #expect(result.failures.isEmpty)
}

@Test func testCAllOnlineProvidersUnavailableStillReturnsOfflineTrack() async throws {
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundled = BundledMusicProvider(library: local, rootURL: musicFixtureRoot())
    let first = FailingMusicProvider(identifier: "first", sourceProvider: .freeToUse, priority: 100)
    let second = FailingMusicProvider(identifier: "second", sourceProvider: .openverse, priority: 110)
    let system = MusicLibrary(localLibrary: local, providers: [bundled, first, second])

    let result = await system.resolve(MusicIntent(directive: MusicDirective(style: .cinematic, bpm: 88)))

    #expect(result.track?.sourceProvider == .bundled)
    #expect(await first.searchCount() == 0)
    #expect(await second.searchCount() == 0)
}

@Test func testDUserFolderTrackIsIndexedAndSelectableLikeBundledMusic() async throws {
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = musicFixtureRoot().appendingPathComponent("holiznacc0-finding-yourself.mp3")
    let imported = try await local.importUserTrack(source)
    let localProvider = LocalMusicProvider(library: local)
    let system = MusicLibrary(localLibrary: local, providers: [localProvider])

    let result = await system.resolve(MusicIntent(directive: MusicDirective(style: .calm, bpm: 72)))

    #expect(imported.sourceProvider == .user)
    #expect(imported.duration > 100)
    #expect(imported.waveform?.isEmpty == false)
    #expect(result.track?.id == imported.id)
}

@Test func testEAndFDownloadedOnlineTrackUsesCacheAcrossRepeatedResolution() async throws {
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = musicFixtureRoot().appendingPathComponent("holiznacc0-lost-on-the-freeway.mp3")
    let candidate = MusicProviderTrack(
        id: UUID().uuidString,
        sourceProvider: .openverse,
        metadata: MusicTrackMetadata(
            title: "Cached adventure",
            artist: "Test artist",
            genres: ["electronic"],
            moods: ["energetic", "adventure"],
            tags: ["travel"],
            energy: 0.86,
            bpm: 128,
            duration: 177.744,
            sourceName: "Openverse",
            instrumental: true
        ),
        license: MusicLicenseRecord(
            name: "CC BY 4.0",
            url: URL(string: "https://creativecommons.org/licenses/by/4.0/")!,
            attributionText: "Cached adventure — Test artist (CC BY 4.0)",
            sourceName: "Openverse",
            sourceURL: URL(string: "https://openverse.org")!,
            licenseCheckedAt: Date(),
            requiresAttribution: true
        ),
        sourcePageURL: URL(string: "https://openverse.org")!,
        localFileURL: source
    )
    let cached = try await local.importProviderTrack(candidate, downloadedFileURL: source)
    let online = FailingMusicProvider(identifier: "network", sourceProvider: .openverse, priority: 110)
    let system = MusicLibrary(localLibrary: local, providers: [online])

    let first = await system.resolve(MusicIntent(directive: energeticDirective()))
    let second = await system.resolve(MusicIntent(directive: energeticDirective()))

    #expect(first.track?.id == cached.id)
    #expect(second.track?.id == cached.id)
    #expect(await online.searchCount() == 0)
}

@Test func freshFilmDownloadsInBackgroundAndPrefersCachedOnlineTrack() async throws {
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundled = BundledMusicProvider(library: local, rootURL: musicFixtureRoot())
    let online = DownloadableMusicProvider(
        library: local,
        sourceURL: musicFixtureRoot().appendingPathComponent("holiznacc0-lost-on-the-freeway.mp3")
    )
    let system = MusicLibrary(localLibrary: local, providers: [bundled, online])
    let intent = MusicIntent(directive: energeticDirective())

    await system.scheduleOnlineTrack(for: intent)
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
        if try await system.tracks().contains(where: { $0.sourceProvider == .openverse }) { break }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    let result = await system.resolve(intent, preferCachedOnline: true)

    #expect(result.track?.sourceProvider == .openverse)
    #expect(result.track?.title == "Fresh online track")
    #expect(result.catalog.filter { $0.sourceProvider == .bundled }.count == 12)
    let counts = await online.counts()
    #expect(counts.searches == 1)
    #expect(counts.downloads == 1)
}

@Test func onlineProvidersRaceAndCancelAStalledServiceAfterFastFallbackSucceeds() async throws {
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let stalled = SlowFailingMusicProvider()
    let fallback = DownloadableMusicProvider(
        library: local,
        sourceURL: musicFixtureRoot().appendingPathComponent("holiznacc0-lost-on-the-freeway.mp3")
    )
    // Decode the real fixture before timing provider coordination; concurrent
    // audio-analysis tests can otherwise dominate this network-race check.
    let intent = MusicIntent(directive: energeticDirective())
    let cached = try #require(try await fallback.search(intent).first)
    _ = try await fallback.download(cached)
    let system = MusicLibrary(localLibrary: local, providers: [stalled, fallback])
    let clock = ContinuousClock()
    let started = clock.now

    let result = await system.resolve(intent, preferFreshOnline: true)
    let elapsed = started.duration(to: clock.now)

    #expect(result.track?.sourceProvider == .openverse)
    #expect(result.track?.title == "Fresh online track")
    #expect(elapsed < .seconds(1))
    let stalledCounts = await stalled.counts()
    #expect(stalledCounts.searches == 1)
    #expect(stalledCounts.cancellations == 1)
}

@Test func newAutomaticFilmDownloadsFreshOnlineMusicBeforeUsingPlayableLocalTracks() async throws {
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundled = BundledMusicProvider(library: local, rootURL: musicFixtureRoot())
    let online = DownloadableMusicProvider(
        library: local,
        sourceURL: musicFixtureRoot().appendingPathComponent("holiznacc0-lost-on-the-freeway.mp3")
    )
    let system = MusicLibrary(localLibrary: local, providers: [bundled, online])

    let result = await system.resolve(
        MusicIntent(directive: energeticDirective()),
        preferCachedOnline: true,
        preferFreshOnline: true
    )

    #expect(result.track?.sourceProvider == .openverse)
    #expect(result.track?.title == "Fresh online track")
    #expect(await online.counts().searches == 1)
}

@Test func onlineReplacementExcludesThePreviouslyDownloadedProviderTrack() async throws {
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let online = DownloadableMusicProvider(
        library: local,
        sourceURL: musicFixtureRoot().appendingPathComponent("holiznacc0-lost-on-the-freeway.mp3"),
        candidateIDs: [
            "10000000-0000-4000-8000-000000000001",
            "10000000-0000-4000-8000-000000000002"
        ]
    )
    let system = MusicLibrary(localLibrary: local, providers: [online])
    let intent = MusicIntent(directive: energeticDirective())

    let first = try #require(await system.resolve(intent, preferFreshOnline: true).track)
    let second = try #require(await system.resolve(
        intent,
        excludingIdentities: [first.selectionIdentity],
        preferFreshOnline: true
    ).track)

    #expect(second.selectionIdentity != first.selectionIdentity)
    #expect(second.providerTrackID != first.providerTrackID)
    #expect(await online.counts().downloads == 2)
}

@Test func onlineProviderTriesTheNextCandidateWhenTheBestDownloadIsBroken() async throws {
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let brokenID = "10000000-0000-4000-8000-000000000001"
    let fallbackID = "10000000-0000-4000-8000-000000000002"
    let online = DownloadableMusicProvider(
        library: local,
        sourceURL: musicFixtureRoot().appendingPathComponent("holiznacc0-lost-on-the-freeway.mp3"),
        candidateIDs: [brokenID, fallbackID],
        failingCandidateIDs: [brokenID]
    )
    let system = MusicLibrary(localLibrary: local, providers: [online])

    let result = await system.resolve(
        MusicIntent(directive: energeticDirective()),
        preferFreshOnline: true
    )

    #expect(result.track?.providerTrackID == fallbackID)
    #expect(await online.counts().downloads == 2)
}

@Test func anonymousOpenverseSearchUsesSupportedPageSize() throws {
    let url = try #require(OpenverseMusicProvider.searchURL(
        for: MusicIntent(directive: MusicDirective(style: .cinematic, bpm: 88))
    ))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

    #expect(query["page_size"] == "20")
    #expect(query["categories"] == "music")
}

@Test func freeToUseSearchStartsWithShortProviderSpecificQuery() {
    let intent = MusicIntent(directive: MusicDirective(style: .cinematic, bpm: 88))
    let queries = FreeToUseMusicProvider.searchQueries(for: intent)

    #expect(queries.first == "cinematic")
    #expect(queries.count >= 1)
    #expect(queries.allSatisfy { !$0.isEmpty })
}

@Test func liveOnlineReplacementDownloadsTwoDifferentAudioFilesWhenEnabled() async throws {
    guard ProcessInfo.processInfo.environment["VELOEDIT_LIVE_MUSIC_TEST"] == "1" else { return }
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let system = MusicLibrary(
        localLibrary: local,
        providers: [
            OpenverseMusicProvider(library: local),
            FreeToUseMusicProvider(library: local),
            IncompetechMusicProvider(library: local),
            InternetArchiveMusicProvider(library: local),
            WebMusicProvider(library: local)
        ]
    )
    let intent = MusicIntent(directive: MusicDirective(style: .cinematic, bpm: 88))

    let first = try #require(await system.resolve(intent, preferFreshOnline: true).track)
    let second = try #require(await system.resolve(
        intent,
        excludingIdentities: [first.selectionIdentity],
        preferFreshOnline: true
    ).track)
    let firstAudio = try Data(contentsOf: first.localFileURL)
    let secondAudio = try Data(contentsOf: second.localFileURL)

    print("Live provider race: \(first.sourceProvider.rawValue): \(first.title) / \(second.sourceProvider.rawValue): \(second.title)")
    #expect(first.sourceProvider.isOnline)
    #expect(second.sourceProvider.isOnline)
    #expect(first.selectionIdentity != second.selectionIdentity)
    #expect(firstAudio.count > 100_000)
    #expect(secondAudio.count > 100_000)
    #expect(firstAudio != secondAudio)
}

@Test func newAutomaticFilmUsesLocalMusicOnlyAfterEveryOnlineProviderFails() async throws {
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundled = BundledMusicProvider(library: local, rootURL: musicFixtureRoot())
    let first = FailingMusicProvider(identifier: "free-to-use", sourceProvider: .freeToUse, priority: 100)
    let second = FailingMusicProvider(identifier: "openverse", sourceProvider: .openverse, priority: 110)
    let system = MusicLibrary(localLibrary: local, providers: [bundled, first, second])

    let result = await system.resolve(
        MusicIntent(directive: energeticDirective()),
        preferCachedOnline: true,
        preferFreshOnline: true
    )

    #expect(result.track?.sourceProvider == .bundled)
    #expect(result.failures.count == 2)
    #expect(await first.searchCount() == 1)
    #expect(await second.searchCount() == 1)
}

@Test func testGAttributionSurvivesProjectMetadataRoundTrip() throws {
    let audioURL = musicFixtureRoot().appendingPathComponent("holiznacc0-dangerous-voyage.mp3")
    let track = LocalMusicTrack(
        title: "Attribution track",
        author: "Creator",
        bpm: 82,
        genres: ["cinematic"],
        moods: ["emotional"],
        energy: 0.52,
        duration: 120,
        license: MusicLicenseRecord(
            name: "CC BY 4.0",
            url: URL(string: "https://creativecommons.org/licenses/by/4.0/")!,
            attributionText: "Attribution track — Creator (CC BY 4.0)",
            sourceName: "Openverse",
            sourceURL: URL(string: "https://openverse.org")!,
            licenseCheckedAt: Date(),
            requiresAttribution: true
        ),
        sourceProvider: .openverse,
        sourcePageURL: URL(string: "https://openverse.org")!,
        localFileURL: audioURL,
        originalFileName: audioURL.lastPathComponent
    )
    var project = ProjectManifest(name: "Credits")
    project.musicCredits = [MusicCredit(track: track)]

    let decoded = try JSONDecoder.veloEdit.decode(
        ProjectManifest.self,
        from: JSONEncoder.veloEdit.encode(project)
    )

    #expect(decoded.effectiveMusicCredits.first?.license.requiresAttribution == true)
    #expect(decoded.effectiveMusicCredits.first?.license.attributionText?.contains("Creator") == true)
}

@Test func unavailableProviderCircuitBreakerTemporarilyStopsRepeatedRequests() async {
    let health = MusicProviderHealthRegistry(failureThreshold: 2, cooldown: 60)
    #expect(await health.availability(for: "provider") == .available)
    _ = await health.recordFailure(for: "provider")
    #expect(await health.availability(for: "provider") == .available)
    _ = await health.recordFailure(for: "provider")
    if case .coolingDown = await health.availability(for: "provider") {
        #expect(Bool(true))
    } else {
        Issue.record("Provider должен перейти в cooldown после двух ошибок")
    }
}


@Test func onlineDeadlineCancelsSlowProviderAndUsesLocalAudio() async throws {
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let stalled = SlowFailingMusicProvider()
    let system = MusicLibrary(localLibrary: local, providers: [BundledMusicProvider(library: local, rootURL: musicFixtureRoot()), stalled], onlineTimeout: 0.1)
    let result = await system.resolve(MusicIntent(directive: energeticDirective()), preferFreshOnline: true)
    #expect(result.track?.isPlayable == true)
    #expect(result.failures.contains { $0.provider == "music-search" })
    #expect(await stalled.counts().cancellations == 1)
}

@Test func freshOnlineFailureStillImportsUnheardSharedCache() async throws {
    let (root, cache) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = DownloadableMusicProvider(library: cache, sourceURL: musicFixtureRoot().appendingPathComponent("holiznacc0-dangerous-voyage.mp3"))
    let intent = MusicIntent(directive: energeticDirective())
    let candidate = try #require(try await provider.search(intent).first)
    let original = try await provider.download(candidate)
    let project = LocalMusicLibrary(rootURL: root.appendingPathComponent("new-project"))
    let failed = FailingMusicProvider(identifier: "offline", sourceProvider: .openverse, priority: 100)
    let system = MusicLibrary(localLibrary: project, providers: [failed], reusableCache: cache)
    let result = await system.resolve(intent, preferFreshOnline: true)
    let recovered = try #require(result.track)
    #expect(recovered.selectionIdentity == original.selectionIdentity)
    #expect(recovered.localFileURL != original.localFileURL)
    #expect(recovered.isPlayable)
    #expect(await failed.searchCount() == 1)
}

@Test func historyRecognizesTheSameRecordingFromAnotherProvider() async throws {
    let (root, local) = temporaryMusicLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = DownloadableMusicProvider(library: local, sourceURL: musicFixtureRoot().appendingPathComponent("holiznacc0-dangerous-voyage.mp3"), candidateIDs: ["first", "second"])
    let intent = MusicIntent(directive: energeticDirective())
    let first = try #require(try await provider.search(intent).first)
    var prior = try await provider.download(first)
    prior.sourceProvider = .web
    prior.providerTrackID = "another-service-id"
    let history = LocalMusicSelectionHistoryStore(url: root.appendingPathComponent("history.json"))
    try await history.record(prior)
    let system = MusicLibrary(localLibrary: local, providers: [provider])
    let selected = await system.resolve(intent, excludingIdentities: await history.recentIdentities(), preferFreshOnline: true)
    #expect(selected.track?.providerTrackID == "second")
}
