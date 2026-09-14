import Foundation
import Testing
@testable import VeloEditCore

private actor CascadeFixtureProvider: MusicProvider {
    enum Behavior: Sendable { case empty, failure, slow, brokenDownload, success }
    nonisolated let identifier: String
    nonisolated let sourceProvider: MusicSourceProvider = .other
    nonisolated let priority = 100
    nonisolated let fallbackTier: Int
    private let behavior: Behavior
    private let track: LocalMusicTrack
    private var searches = 0
    private var cancellations = 0

    init(_ name: String, tier: Int, behavior: Behavior) {
        identifier = name; fallbackTier = tier; self.behavior = behavior
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Music/holiznacc0-dangerous-voyage.mp3")
        track = LocalMusicTrack(title: name, author: "Fixture", bpm: 100, genres: ["cinematic"], moods: ["emotional"], energy: 0.6, duration: 120,
            license: .userFile(), sourceProvider: .other, sourcePageURL: file, localFileURL: file, originalFileName: file.lastPathComponent)
    }

    func availability() async -> MusicProviderAvailability { .available }
    func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack] {
        searches += 1
        switch behavior {
        case .empty: return []
        case .failure: throw MusicHTTPClient.HTTPError(status: 403, host: identifier, retryAfter: nil)
        case .slow:
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancellations += 1; throw error }
            throw URLError(.timedOut)
        case .success, .brokenDownload: return [MusicProviderTrack(local: track)]
        }
    }
    func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack {
        if case .brokenDownload = behavior { throw URLError(.cannotDecodeContentData) }
        return self.track
    }
    func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata { track.metadata }
    func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord { track.license }
    func counts() -> (searches: Int, cancellations: Int) { (searches, cancellations) }
}

struct MusicCascadeTests {
    private let intent = MusicIntent(directive: .init(style: .cinematic, bpm: 100))
    private func local() -> (URL, LocalMusicLibrary) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VeloEdit-Cascade-\(UUID())")
        return (root, LocalMusicLibrary(rootURL: root))
    }

    @Test func successfulPrimaryDoesNotStartLaterStages() async throws {
        let (root, local) = local(); defer { try? FileManager.default.removeItem(at: root) }
        let primary = CascadeFixtureProvider("primary", tier: 0, behavior: .success)
        let reserve = CascadeFixtureProvider("reserve", tier: 1, behavior: .success)
        let result = await MusicLibrary(localLibrary: local, providers: [reserve, primary], cascadeDelay: 10).resolve(intent, preferFreshOnline: true)
        #expect(result.track?.title == "primary")
        #expect(await reserve.counts().searches == 0)
    }

    @Test func failuresAndEmptyCataloguesAdvanceWithoutWaitingForTimers() async throws {
        let (root, local) = local(); defer { try? FileManager.default.removeItem(at: root) }
        let providers = [CascadeFixtureProvider("forbidden", tier: 0, behavior: .failure),
                         CascadeFixtureProvider("empty", tier: 1, behavior: .empty),
                         CascadeFixtureProvider("bad-audio", tier: 2, behavior: .brokenDownload),
                         CascadeFixtureProvider("last-resort", tier: 3, behavior: .success)]
        let start = ContinuousClock.now
        let result = await MusicLibrary(localLibrary: local, providers: providers, onlineTimeout: 2, cascadeDelay: 10).resolve(intent, preferFreshOnline: true)
        #expect(result.track?.title == "last-resort")
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(Set(result.failures.map(\.provider)) == ["forbidden", "empty", "bad-audio"])
        for provider in providers { #expect(await provider.counts().searches == 1) }
    }

    @Test func slowPrimaryStartsReserveAndIsCancelledAfterSuccess() async throws {
        let (root, local) = local(); defer { try? FileManager.default.removeItem(at: root) }
        let slow = CascadeFixtureProvider("slow", tier: 0, behavior: .slow)
        let reserve = CascadeFixtureProvider("reserve", tier: 1, behavior: .success)
        let last = CascadeFixtureProvider("unused", tier: 2, behavior: .success)
        let result = await MusicLibrary(localLibrary: local, providers: [slow, reserve, last], onlineTimeout: 2, cascadeDelay: 0.1).resolve(intent, preferFreshOnline: true)
        #expect(result.track?.title == "reserve")
        #expect(await slow.counts().cancellations == 1)
        #expect(await reserve.counts().searches == 1)
        #expect(await last.counts().searches == 0)
    }

    @Test func globalDeadlineStopsCascadeBeforeUnneededStages() async throws {
        let (root, local) = local(); defer { try? FileManager.default.removeItem(at: root) }
        let slow = CascadeFixtureProvider("slow", tier: 0, behavior: .slow)
        let reserve = CascadeFixtureProvider("reserve", tier: 1, behavior: .success)
        let result = await MusicLibrary(localLibrary: local, providers: [slow, reserve], onlineTimeout: 0.1, cascadeDelay: 1).resolve(intent, preferFreshOnline: true)
        #expect(result.track == nil)
        #expect(result.failures.contains { $0.provider == "music-search" })
        #expect(await slow.counts().cancellations == 1)
        #expect(await reserve.counts().searches == 0)
    }

    @Test func failedReserveAdvancesEvenWhileEarlierStageIsStillStalled() async throws {
        let (root, local) = local(); defer { try? FileManager.default.removeItem(at: root) }
        let slow = CascadeFixtureProvider("slow", tier: 0, behavior: .slow)
        let empty = CascadeFixtureProvider("empty", tier: 1, behavior: .empty)
        let last = CascadeFixtureProvider("last", tier: 2, behavior: .success)
        // Waiting for the older stalled request or for a second hedge timer
        // would hit the deadline before the final stage can succeed.
        let result = await MusicLibrary(localLibrary: local, providers: [slow, empty, last], onlineTimeout: 0.8, cascadeDelay: 0.5).resolve(intent, preferFreshOnline: true)
        #expect(result.track?.title == "last")
        #expect(await slow.counts().cancellations == 1)
    }

    @Test func cancellationDoesNotStartRemainingCascade() async throws {
        let (root, local) = local(); defer { try? FileManager.default.removeItem(at: root) }
        let slow = CascadeFixtureProvider("slow", tier: 0, behavior: .slow)
        let reserve = CascadeFixtureProvider("reserve", tier: 1, behavior: .success)
        let system = MusicLibrary(localLibrary: local, providers: [slow, reserve], cascadeDelay: 2)
        let task = Task { await system.resolve(intent, preferFreshOnline: true) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value.track == nil)
        #expect(await reserve.counts().searches == 0)
    }

    @Test func defaultSourcesFormFourCascadeStages() {
        let sources: [any MusicProvider] = [FreeToUseMusicProvider(), IncompetechMusicProvider(library: .shared), AudionautixMusicProvider(), ScottBuckleyMusicProvider(), OpenverseMusicProvider(library: .shared), InternetArchiveMusicProvider(library: .shared), WebMusicProvider(library: .shared)]
        #expect(sources.map(\.fallbackTier) == [0, 0, 1, 1, 2, 2, 3])
        #expect(Set(sources.map(\.sourceProvider)).count == 7)
        #expect(sources.allSatisfy { $0.sourceProvider.isOnline })
    }

    @Test func audionautixParsesRealMarkupAndSkipsShortOrForeignFiles() throws {
        let page = URL(string: "https://audionautix.com/free-music/acoustic")!
        let row = #"<div class="single-song"><h3>Warm &amp; Bright (2:54)</h3><table><tr><td>Genre:</td><td><a>ACOUSTIC</a></td></tr><tr><td>Tempo:</td><td>Medium</td></tr><tr><td>Mood:</td><td>Calming, Relaxing</td></tr></table><a href="/Music/Warm.mp3">Listen Now</a><a href="/Music/Warm.mp3" download>Download Mp3</a></div>"#
        let license = #"<a href="https://creativecommons.org/licenses/by/4.0/legalcode">License</a>"#
        let tracks = AudionautixMusicProvider.candidates(html: row + row + row.replacingOccurrences(of: "Warm.mp3", with: "Short.mp3").replacingOccurrences(of: "2:54", with: ":05") + row.replacingOccurrences(of: "/Music/Warm.mp3", with: "https://foreign.example/music.mp3") + license, page: page)
        let track = try #require(tracks.first)
        #expect(tracks.count == 1)
        #expect(track.metadata.title == "Warm & Bright")
        #expect(track.metadata.duration == 174)
        #expect(track.metadata.moods == ["calming", "relaxing"])
        #expect(track.metadata.genres == ["acoustic"])
        #expect(track.license.attributionText?.contains("Jason Shaw") == true)
        #expect(AudionautixMusicProvider.candidates(html: row, page: page).isEmpty)
        #expect(AudionautixMusicProvider.candidates(html: row + license, page: URL(string: "https://foreign.example/")!).isEmpty)
    }

    @Test func scottBuckleyRequiresPerTrackLicenseAndFullMix() throws {
        let html = #"<p>Gentle solo piano &amp; strings.</p><a href="https://www.scottbuckley.com.au/library/wp-content/uploads/stem.mp3">MP3 (Piano Stem)</a><a href="https://www.scottbuckley.com.au/library/wp-content/uploads/song.mp3">MP3 (Full Mix)</a><a href="http://creativecommons.org/licenses/by/4.0/" rel="license">CC BY</a><p>Patrons: MetalRockDance</p>"#
        func row(_ id: Int, _ html: String, protected: Bool = false) -> [String: Any] {
            ["id": id, "link": "https://www.scottbuckley.com.au/library/test/", "title": ["rendered": "Warm &#8217; Light"], "content": ["rendered": html, "protected": protected]]
        }
        let rows = [row(1, html), row(2, html, protected: true), row(3, html.replacingOccurrences(of: "/by/", with: "/by-nc/")),
                    row(4, html.replacingOccurrences(of: "Full Mix", with: "Preview")), row(5, html.replacingOccurrences(of: "www.scottbuckley.com.au/library/wp-content", with: "foreign.example/library/wp-content")), ["id": 6]]
        let tracks = try ScottBuckleyMusicProvider.candidates(data: JSONSerialization.data(withJSONObject: rows))
        let track = try #require(tracks.first)
        #expect(tracks.count == 1)
        #expect(track.metadata.title == "Warm ’ Light")
        #expect(track.downloadURL?.lastPathComponent == "song.mp3")
        #expect(track.metadata.tags.contains("piano"))
        #expect(!track.metadata.tags.contains("metalrockdance"))
        #expect(track.license.requiresAttribution == true)
        #expect(track.license.attributionText?.contains("Scott Buckley") == true)
        #expect(track.license.usageRestrictions?.contains("YouTube") == true)
    }

    @Test func liveNewSourcesEachDownloadTwoDifferentFullTracksThroughCascade() async throws {
        guard ProcessInfo.processInfo.environment["VELOEDIT_LIVE_CASCADE_MUSIC_TEST"] == "1" else { return }
        for source in [MusicSourceProvider.audionautix, .scottBuckley] {
            let (root, local) = local(); defer { try? FileManager.default.removeItem(at: root) }
            let primary = CascadeFixtureProvider("failed-primary", tier: 0, behavior: .failure)
            let provider: any MusicProvider = source == .audionautix ? AudionautixMusicProvider(library: local) : ScottBuckleyMusicProvider(library: local)
            let system = MusicLibrary(localLibrary: local, providers: [primary, provider])
            let request = MusicIntent(directive: .init(style: .acoustic, bpm: 90))
            let firstResult = await system.resolve(request, preferFreshOnline: true)
            print("Live cascade \(source): \(firstResult.failures)")
            let first = try #require(firstResult.track)
            let secondResult = await system.resolve(request, excludingIdentities: first.noveltyIdentities, preferFreshOnline: true)
            print("Live cascade second \(source): \(secondResult.failures)")
            let second = try #require(secondResult.track)
            #expect(first.sourceProvider == source && second.sourceProvider == source)
            #expect(first.noveltyIdentities.isDisjoint(with: second.noveltyIdentities))
            #expect(first.duration >= 45 && second.duration >= 45)
            #expect(first.waveform?.isEmpty == false && second.waveform?.isEmpty == false)
            let a = try Data(contentsOf: first.localFileURL), b = try Data(contentsOf: second.localFileURL)
            #expect(a.count > 100_000 && b.count > 100_000 && a != b)
            #expect(first.license.requiresAttribution == true && second.license.requiresAttribution == true)
            print("LIVE VERIFIED \(source): \(first.title) | \(first.duration)s | \(a.count) bytes; \(second.title) | \(second.duration)s | \(b.count) bytes")
        }
    }
}
