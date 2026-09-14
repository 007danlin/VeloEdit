import Foundation
import AVFoundation
import Testing
@testable import VeloEditCore

@Suite(.serialized) struct DynamicMusicTests {
    @Test func namedTracksReachEverySearchProviderUnchanged() throws {
        let directive = try #require(MusicPromptInterpreter().interpret(prompt: "Поставь Imagine Dragons — Believer", preset: .adventure))
        let intent = MusicIntent(directive: directive)
        #expect(intent.searchQuery == "Imagine Dragons — Believer")
        #expect(intent.request?.exactTrack == true)
        #expect(MusicPromptInterpreter().interpret(prompt: "Энергичная музыка 150 BPM", preset: .adventure)?.bpm == 150)
        #expect(MusicSearchRequest.parse("Поставь Believer").first?.query == "Believer")
        #expect(intent.request?.matches(title: "Believer", artist: "Imagine Dragons") == true)
        #expect(intent.request?.matches(title: "Believer", artist: "Cover Band") == false)
        #expect(FreeToUseMusicProvider.searchQueries(for: intent) == [intent.searchQuery])
        let url = try #require(OpenverseMusicProvider.searchURL(for: intent))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value == intent.searchQuery)
    }

    @Test func sceneRequestsAndSeveralSongsSurvivePersistence() throws {
        let requests = MusicSearchRequest.parse("Для багги нужна агрессивная энергичная музыка; для рыбалки спокойная атмосферная музыка; для велосипеда лёгкий летний трек")
        #expect(requests.count == 3)
        #expect(requests[0].query.contains("aggressive"))
        #expect(requests[1].applies(to: "Рыбалка fishing"))
        #expect(!requests[1].applies(to: "Экшен action-vehicle"))
        let names = MusicSearchRequest.parse("Поставь «Imagine Dragons — Believer», «Coldplay — Paradise»")
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.exactTrack })
        let directive = MusicDirective(style: .energetic, bpm: 120, searchRequests: names)
        #expect(try JSONDecoder().decode(MusicDirective.self, from: JSONEncoder().encode(directive)).searchRequests == names)
        #expect(MusicSearchRequest.parse("Сделай фильм с титром «Наше лето»").isEmpty)
        let compound = MusicSearchRequest.parse("Добавь титр «Наше лето» в конце, поставь спокойную музыку")
        #expect(compound.map(\.query) == ["calm"])
    }

    @Test func archiveSkipsStreamingRestrictedAndIncompatibleLicenses() throws {
        func manifest(_ changes: [String: Any] = [:], fileChanges: [String: Any] = [:]) throws -> Data {
            var metadata: [String: Any] = ["title": "River", "creator": "Artist", "licenseurl": "https://creativecommons.org/licenses/by/4.0/"]
            metadata.merge(changes) { _, new in new }
            var file: [String: Any] = ["name": "River.flac", "size": "1000000", "length": "02:30"]
            file.merge(fileChanges) { _, new in new }
            return try JSONSerialization.data(withJSONObject: ["metadata": metadata, "files": [file]])
        }
        let valid = try InternetArchiveMusicProvider.candidates(data: manifest(), identifier: "river")
        #expect(valid.count == 1)
        #expect(valid.first?.metadata.duration == 150)
        #expect(valid.first?.license.requiresAttribution == true)
        #expect(try InternetArchiveMusicProvider.candidates(data: manifest(["nodownload": "true"]), identifier: "river").isEmpty)
        #expect(try InternetArchiveMusicProvider.candidates(data: manifest(fileChanges: ["private": true]), identifier: "river").isEmpty)
        #expect(try InternetArchiveMusicProvider.candidates(data: manifest(fileChanges: ["name": "playlist.m3u8"]), identifier: "river").isEmpty)
        #expect(try InternetArchiveMusicProvider.candidates(data: manifest(fileChanges: ["licenseurl": "https://creativecommons.org/licenses/by-nc/4.0/"]), identifier: "river").isEmpty)
        #expect(InternetArchiveMusicProvider.allowedLicense("https://creativecommons.org.evil.example/licenses/by/4.0/") == nil)
        #expect(!MusicAudioDownloader.publicHTTPS(URL(string: "https://127.0.0.1/audio.mp3")!))
        #expect(!MusicAudioDownloader.publicHTTPS(URL(string: "http://example.org/audio.mp3")!))
    }

    @Test func exactSearchDoesNotAcceptUnrelatedLocalMusicAndReusesDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dynamic-music-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = LocalMusicLibrary(rootURL: root.appendingPathComponent("project"))
        let provider = RecordingMusicProvider(library: local, fixture: try audioFixture(root))
        let system = MusicLibrary(localLibrary: local, providers: [provider])
        let request = MusicSearchRequest(query: "Artist — River", exactTrack: true)
        let intent = MusicIntent(directive: MusicDirective(style: .calm, bpm: 80, searchRequests: [request]))
        let first = await system.resolve(intent)
        #expect(first.track?.title == "River")
        #expect(first.track?.waveform?.isEmpty == false)
        let second = await system.resolve(intent)
        #expect(first.track?.id == second.track?.id)
        #expect(await provider.searches == 1)
        #expect(await provider.downloads == 1)
        #expect(first.track?.localFileURL.path.hasPrefix(root.appendingPathComponent("project").path) == true)
    }

    @Test func sharedCacheMaterializesIndependentProjectFileOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dynamic-music-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LocalMusicLibrary(rootURL: root.appendingPathComponent("shared"))
        let first = LocalMusicLibrary(rootURL: root.appendingPathComponent("first"))
        let provider = RecordingMusicProvider(library: first, fixture: try audioFixture(root))
        let online = MusicLibrary(localLibrary: first, providers: [provider], reusableCache: cache)
        let intent = MusicIntent(directive: MusicDirective(style: .calm, bpm: 80, searchRequests: [.init(query: "Artist River", exactTrack: true)]))
        let downloaded = await online.resolve(intent)
        #expect(downloaded.track != nil)
        let secondRoot = root.appendingPathComponent("second")
        let second = LocalMusicLibrary(rootURL: secondRoot)
        let offline = MusicLibrary(localLibrary: second, providers: [], reusableCache: cache)
        let resolved = await offline.resolve(intent)
        let track = try #require(resolved.track)
        #expect(track.localFileURL.path.hasPrefix(secondRoot.path))
        try FileManager.default.removeItem(at: root.appendingPathComponent("shared"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("first"))
        #expect(track.isPlayable)
        let reopened = try await LocalMusicLibrary(rootURL: secondRoot).tracks()
        #expect(reopened.first?.isPlayable == true)
        #expect(await provider.downloads == 1)
    }

    @Test func corruptDownloadFallsThroughToNextSourceCandidate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dynamic-music-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = LocalMusicLibrary(rootURL: root.appendingPathComponent("project"))
        let provider = RecordingMusicProvider(library: local, fixture: try audioFixture(root), brokenFirst: true)
        let result = await MusicLibrary(localLibrary: local, providers: [provider]).resolve(MusicIntent(directive: .init(style: .calm, bpm: 80)))
        #expect(result.track?.isPlayable == true)
        #expect(await provider.downloads == 2)
        #expect(try await local.tracks().count == 1)
    }

    @Test func webDiscoveryAcceptsIndependentArtistDomainsAndRejectsUnlicensedStreams() throws {
        let page = URL(string: "https://independent-artist.example/releases/river")!
        let html = #"<script type="application/ld+json">{"@context":"https://schema.org","@type":"MusicRecording","name":"River","byArtist":{"name":"Artist"},"license":"https://creativecommons.org/licenses/by/4.0/","encoding":{"@type":"AudioObject","contentUrl":"https://artist-cdn.example/files/river.flac"}}</script>"#
        let tracks = WebMusicProvider.candidates(html: html, page: page)
        #expect(tracks.count == 1)
        #expect(tracks.first?.downloadURL?.host == "artist-cdn.example")
        #expect(tracks.first?.sourcePageURL == page)
        #expect(tracks.first?.license.requiresAttribution == true)
        #expect(WebMusicProvider.candidates(html: html.replacingOccurrences(of: "river.flac", with: "stream.m3u8"), page: page).isEmpty)
        #expect(WebMusicProvider.candidates(html: html.replacingOccurrences(of: "licenses/by/4.0", with: "licenses/by-nd/4.0"), page: page).isEmpty)
        #expect(WebMusicProvider.candidates(html: #"<audio src="song.mp3"></audio><footer><a rel="license" href="https://creativecommons.org/licenses/by/4.0/">Article license</a></footer>"#, page: page).isEmpty)
    }

    @Test func webDiscoveryRespectsRobotsRules() {
        let rules = "User-agent: *\nDisallow: /private/\nAllow: /private/free/\nDisallow: /*?token=\n"
        #expect(!WebMusicProvider.robotsAllow(rules, path: "/private/song.mp3"))
        #expect(WebMusicProvider.robotsAllow(rules, path: "/private/free/song.mp3"))
        #expect(!WebMusicProvider.robotsAllow(rules, path: "/song.mp3?token=secret"))
        #expect(WebMusicProvider.robotsAllow(rules, path: "/music/song.mp3"))
        #expect(!WebMusicProvider.robotsAllow("User-agent: VeloEdit\nDisallow: /\n", path: "/song"))
    }

    @Test @MainActor func liveGeneralWebMusicSearchWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["VELOEDIT_LIVE_WEB_MUSIC_TEST"] == "1" else { return }
        let pages = try await BrowserMusicWebSearch().pages(for: "Kevin MacLeod music creative commons download")
        #expect(!pages.isEmpty)
        #expect(pages.contains { $0.host?.contains("freetouse.com") != true && $0.host?.contains("openverse.org") != true })
    }

    @Test func dynamicMusicRendersLocalSectionsWithCrossfadesOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dynamic-music-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalMusicLibrary(rootURL: root.appendingPathComponent("project"))
        var tracks: [LocalMusicTrack] = []
        for index in 0..<3 {
            let source = try audioFixture(root.appendingPathComponent("source-\(index)"), frequency: 220 + Double(index) * 110)
            let candidate = MusicProviderTrack(id: "tone-\(index)", sourceProvider: .web,
                metadata: .init(title: "Tone \(index)", artist: "Test fixture", genres: [], moods: [], energy: 0.5, bpm: 100, duration: 35, sourceName: "Test fixture"),
                license: .init(name: "Test fixture", url: URL(string: "https://example.org/license")!),
                sourcePageURL: URL(string: "https://example.org/tone-\(index)")!)
            tracks.append(try await library.importProviderTrack(candidate, downloadedFileURL: source))
            try FileManager.default.removeItem(at: source)
        }
        let items = (0..<3).map { TimelineItem(kind: .title, sourceDuration: 3, timelineStart: Double($0) * 3, timelineDuration: 3, title: "Part \($0 + 1)") }
        var timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 10, items: items,
            music: .init(style: .cinematic, bpm: 100, volume: 0.3, trackID: tracks[0].id))
        let segments = tracks.enumerated().map { index, track in
            AdaptiveMusicSegment(timelineStart: Double(index) * 3, timelineDuration: 3,
                directive: .init(style: .cinematic, bpm: 100, volume: 0.3, trackID: track.id),
                transitionDuration: index == 0 ? 0 : index == 1 ? 0.8 : 1.3, semanticLabel: "Part \(index)", energy: 0.5, confidence: 1)
        }
        timeline.adaptiveSoundtrack = .init(primaryTrackID: tracks[0].id, timelineDuration: 9,
            timelineFingerprint: timeline.adaptiveSoundtrackFingerprint, segments: segments, confidence: 1)
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [], musicTracks: tracks, derivedMediaCacheURL: root.appendingPathComponent("preview"))
        #expect((playback.audioMix?.inputParameters.count ?? 0) >= 3)
        let report = try await RenderEngine().render(timeline: timeline, assets: [], musicTracks: tracks,
            quality: .maximum, destination: root.appendingPathComponent("film.mp4"))
        let rendered = AVURLAsset(url: report.outputURL)
        #expect(!(try await rendered.loadTracks(withMediaType: .audio)).isEmpty)
        #expect(abs((try await rendered.load(.duration)).seconds - 9) < 0.2)
        let decoded = try #require(try await LocalAudioAnalyzer().analyze(url: report.outputURL, level: .deep))
        #expect(decoded.meanVolume > 0.005)
        for boundary in [3.0, 6.0] {
            let index = min(decoded.waveform.count - 1, Int(boundary / 9 * Double(decoded.waveform.count)))
            #expect(decoded.waveform[index] > 0.001)
        }
    }

    private func audioFixture(_ root: URL, frequency: Double = 220) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 280_000)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * frequency / 8_000) * 0.15)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

private actor RecordingMusicProvider: MusicProvider {
    nonisolated let identifier = "fixture"
    nonisolated let sourceProvider: MusicSourceProvider = .openverse
    nonisolated let priority = 100
    let library: LocalMusicLibrary
    let fixture: URL
    let brokenFirst: Bool
    var searches = 0
    var downloads = 0
    init(library: LocalMusicLibrary, fixture: URL, brokenFirst: Bool = false) {
        self.library = library; self.fixture = fixture; self.brokenFirst = brokenFirst
    }
    func availability() async -> MusicProviderAvailability { .available }
    func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack] {
        searches += 1
        let candidate = MusicProviderTrack(id: "river", sourceProvider: .openverse,
            metadata: .init(title: "River", artist: "Artist", genres: ["ambient"], moods: ["calm"], energy: 0.28, bpm: 80, duration: 35, sourceName: "Fixture"),
            license: .init(name: "CC0", url: URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")!),
            sourcePageURL: URL(string: "https://example.org/river")!)
        guard brokenFirst else { return [candidate] }
        var broken = candidate; broken.id = "broken"; broken.metadata.energy = intent.energy
        return [broken, candidate]
    }
    func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack {
        downloads += 1
        if track.id == "broken" {
            let invalid = fixture.deletingLastPathComponent().appendingPathComponent("broken.mp3")
            try Data("<html>not audio</html>".utf8).write(to: invalid)
            return try await library.importProviderTrack(track, downloadedFileURL: invalid)
        }
        return try await library.importProviderTrack(track, downloadedFileURL: fixture)
    }
    func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata { track.metadata }
    func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord { track.license }
}
