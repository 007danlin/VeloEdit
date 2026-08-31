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
    private var searches = 0
    private var downloads = 0

    init(library: LocalMusicLibrary, sourceURL: URL) {
        self.library = library
        self.sourceURL = sourceURL
    }

    func availability() async -> MusicProviderAvailability { .available }

    func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack] {
        searches += 1
        return [MusicProviderTrack(
            id: "10000000-0000-4000-8000-000000000001",
            sourceProvider: .openverse,
            metadata: MusicTrackMetadata(
                title: "Fresh online track",
                artist: "Open artist",
                genres: ["electronic"],
                moods: ["energetic", "adventure"],
                tags: ["travel", "instrumental"],
                energy: 0.84,
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
        )]
    }

    func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack {
        downloads += 1
        return try await library.importProviderTrack(track, downloadedFileURL: sourceURL)
    }

    func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata { track.metadata }
    func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord { track.license }
    func counts() -> (searches: Int, downloads: Int) { (searches, downloads) }
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
    let pipeline = VeloEditPipeline(store: store)

    let track = try await pipeline.prepareMusicTrack(for: energeticDirective())

    #expect(track.sourceProvider == .bundled)
    #expect(track.isPlayable)
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
    for _ in 0..<80 {
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
