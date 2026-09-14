import Foundation
import AVFoundation
import Testing
@testable import VeloEditCore

private final class MusicFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var replies: [(Int, Data)] = []
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        var reply = Self.replies.isEmpty ? (500, Data()) : Self.replies.removeFirst()
        // Reproduce Audionautix's Apache content negotiation: its PHP route
        // rejects strict text/html, while the resulting resource is HTML.
        if request.url?.host == "audionautix.com", request.url?.path.hasPrefix("/free-music/") == true,
           request.value(forHTTPHeaderField: "Accept")?.contains("*/*") != true {
            reply = (406, Data("Not Acceptable".utf8))
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct MusicNetworkReliabilityTests {
    private func session(_ replies: [(Int, Data)]) -> URLSession {
        MusicFixtureProtocol.replies = replies
        MusicFixtureProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MusicFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func temporaryHTTPFailureRetriesButForbiddenDoesNot() async throws {
        let session = session([(503, Data()), (200, Data("{}".utf8))])
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://music.example/catalog.json")!
        #expect(try await MusicHTTPClient.data(at: url, session: session) == Data("{}".utf8))
        #expect(MusicFixtureProtocol.requests.count == 2)
        MusicFixtureProtocol.replies = [(403, Data())]
        await #expect(throws: MusicHTTPClient.HTTPError.self) { try await MusicHTTPClient.data(at: url, session: session) }
        #expect(MusicFixtureProtocol.requests.count == 3)
        #expect(MusicHTTPClient.retryDelay(for: URLError(.cancelled)) == nil)
        #expect(MusicHTTPClient.retryDelay(for: MusicHTTPClient.HTTPError(status: 429, host: "api", retryAfter: 120)) == nil)
    }

    @Test func oversizedAPIResponseIsRejected() async throws {
        let session = session([(200, Data(repeating: 65, count: 100))])
        defer { session.invalidateAndCancel() }
        await #expect(throws: URLError.self) {
            try await MusicHTTPClient.data(at: URL(string: "https://music.example/catalog")!, session: session, maximumBytes: 10)
        }
        #expect(MusicFixtureProtocol.requests.count == 1)
    }

    @Test func oneBrokenFreeToUseRecordDoesNotDiscardValidResults() async throws {
        let data = Data(#"{"ok":true,"data":[{"id":"broken"},{"id":"10000000-0000-4000-8000-000000000099","title":"New Music","duration":120,"is_premium":false,"files":{"mp3":"https://data.freetouse.com/music/new.mp3"}}]}"#.utf8)
        let session = session([(200, data)])
        defer { session.invalidateAndCancel() }
        let provider = FreeToUseMusicProvider(session: session)
        let tracks = try await provider.search(query: "cinematic")
        #expect(tracks.map(\.title) == ["New Music"])
        let url = try #require(MusicFixtureProtocol.requests.first?.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains { $0.name == "order" && $0.value == "random" })
        #expect(query.contains { $0.name == "limit" && $0.value == "60" })
    }

    @Test func incompetechCataloguePreservesLicenseAndRejectsInvalidFiles() throws {
        let row: [String: Any] = ["uuid": "123", "isrc": "USUAN1234567", "title": "Test & Travel", "filename": "Test & Travel.mp3", "length": "00:02:15", "bpm": "120", "genre": "7", "feel": "Driving, Uplifting", "instruments": "Synths"]
        var invalid = row; invalid["filename"] = "../private.mp3"
        var short = row; short["length"] = "00:00:03"
        var malformed = row; malformed["length"] = "unknown"
        let tracks = try IncompetechMusicProvider.candidates(data: JSONSerialization.data(withJSONObject: [row, invalid, short, malformed]), genreData: Data(#"[{"id":7,"genre":"Electronica"}]"#.utf8))
        let track = try #require(tracks.first)
        #expect(tracks.count == 1)
        #expect(track.id == "USUAN1234567")
        #expect(track.metadata.duration == 135)
        #expect(track.metadata.tags.contains("electronic"))
        #expect(track.downloadURL?.lastPathComponent == "Test & Travel.mp3")
        #expect(track.license.requiresAttribution == true)
        #expect(track.license.attributionText?.contains("Kevin MacLeod") == true)
        #expect(track.license.url.absoluteString == "https://creativecommons.org/licenses/by/4.0/")
    }

    @Test func audionautixNegotiatesPublicPHPRouteAndCachesCatalogue() async throws {
        let html = #"<div class="single-song"><h3>New Acoustic (2:30)</h3><a href="/Music/NewAcoustic.mp3">Download</a></div><a href="https://creativecommons.org/licenses/by/4.0/legalcode">License</a>"#
        let session = session([(200, Data("User-agent: *\nCrawl-delay: 3\nDisallow: /Insiders/\n".utf8)), (200, Data(html.utf8))])
        defer { session.invalidateAndCancel() }
        let provider = AudionautixMusicProvider(session: session)
        let intent = MusicIntent(directive: .init(style: .acoustic, bpm: 90))
        let tracks = try await provider.search(intent)
        #expect(tracks.map(\.metadata.title) == ["New Acoustic"])
        #expect(try await provider.search(intent) == tracks)
        #expect(MusicFixtureProtocol.requests.count == 2)
    }

    @Test func liveIndependentProviderDownloadsTwoDifferentPlayableTracks() async throws {
        guard ProcessInfo.processInfo.environment["VELOEDIT_LIVE_INCOMPETECH_TEST"] == "1" else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VeloEdit-LiveMusic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = LocalMusicLibrary(rootURL: root)
        let provider = IncompetechMusicProvider(library: local)
        let system = MusicLibrary(localLibrary: local, providers: [provider])
        let intent = MusicIntent(directive: .init(style: .joyful, bpm: 112))
        let firstResult = await system.resolve(intent, preferFreshOnline: true)
        print("Live music first diagnostics: \(firstResult.failures)")
        let first = try #require(firstResult.track)
        let second = try #require(await system.resolve(intent, excludingIdentities: first.noveltyIdentities, preferFreshOnline: true).track)
        #expect(first.sourceProvider == .incompetech)
        #expect(second.sourceProvider == .incompetech)
        #expect(first.selectionIdentity != second.selectionIdentity)
        #expect(first.title != second.title)
        #expect(first.duration >= 45 && second.duration >= 45)
        #expect(first.waveform?.isEmpty == false && second.waveform?.isEmpty == false)
        let a = try Data(contentsOf: first.localFileURL), b = try Data(contentsOf: second.localFileURL)
        #expect(a.count > 100_000 && b.count > 100_000 && a != b)
        print("Live music verified: \(first.title) (\(a.count) bytes); \(second.title) (\(b.count) bytes)")
    }
}
