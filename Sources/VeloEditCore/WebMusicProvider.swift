import Foundation
import WebKit
import AppKit

public protocol MusicWebSearching: Sendable {
    func pages(for query: String) async throws -> [URL]
}

/// A normal web search, with no domain/collection whitelist and no API key.
/// Search pages are rendered by WebKit; challenges are never solved or bypassed.
public struct BrowserMusicWebSearch: MusicWebSearching {
    public init() {}
    @MainActor public func pages(for query: String) async throws -> [URL] {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let browser = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        defer { browser.stopLoading() }
        var url = URLComponents(string: "https://duckduckgo.com/")!
        url.queryItems = [URLQueryItem(name: "q", value: query)]
        browser.load(URLRequest(url: url.url!))
        let probe = WebSearchProbe()
        let deadline = Date().addingTimeInterval(14)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 350_000_000)
            if !probe.pending {
                probe.pending = true
                browser.evaluateJavaScript("""
                JSON.stringify({
                  blocked: !!document.querySelector('form[action*="anomaly"], #challenge-form'),
                  links: Array.from(document.querySelectorAll('a[data-testid="result-title-a"], a.result__a'))
                    .map(a => a.href).slice(0, 12)
                })
                """) { value, _ in
                    probe.result = value as? String
                    probe.pending = false
                }
            }
            guard let result = probe.result, let data = result.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if object["blocked"] as? Bool == true { throw URLError(.userAuthenticationRequired) }
            let links = (object["links"] as? [String] ?? []).compactMap { raw -> URL? in
                guard let url = URL(string: raw) else { return nil }
                if let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "uddg" })?.value {
                    return URL(string: redirect)
                }
                return url
            }.filter { MusicAudioDownloader.publicHTTPS($0) && $0.host?.hasSuffix("duckduckgo.com") != true }
            if !links.isEmpty { return links }
        }
        throw URLError(.timedOut)
    }
}

@MainActor private final class WebSearchProbe {
    var pending = false
    var result: String?
}

/// Discovers artist sites, labels and repositories through the web, then
/// resolves their published audio metadata. A domain never needs a new adapter
/// if it publishes standard MusicRecording/AudioObject or a licensed audio tag.
public actor WebMusicProvider: MusicProvider {
    public nonisolated let identifier = "web-search"
    public nonisolated let sourceProvider: MusicSourceProvider = .web
    public nonisolated let fallbackTier = 3
    public nonisolated let priority = 100
    private let library: LocalMusicLibrary
    private let searcher: any MusicWebSearching
    private let session: URLSession
    private var robots: [String: String] = [:]

    public init(library: LocalMusicLibrary, searcher: any MusicWebSearching = BrowserMusicWebSearch(), session: URLSession? = nil) {
        self.library = library
        self.searcher = searcher
        self.session = session ?? MusicAudioDownloader.makeSession()
    }
    public func availability() async -> MusicProviderAvailability { .available }

    public func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack] {
        let query = intent.searchQuery + (intent.request?.exactTrack == true ? " official audio download" : " music download creative commons")
        let pages = try await searcher.pages(for: query)
        var candidates: [MusicProviderTrack] = []
        let deadline = Date().addingTimeInterval(30)
        for page in pages.prefix(10) {
            try Task.checkCancellation()
            guard Date() < deadline else { break }
            do {
                guard try await allowedByRobots(page) else { continue }
                let (data, response) = try await boundedData(page)
                guard let final = response.url, try await allowedByRobots(final),
                      response.mimeType == "text/html", let html = String(data: data, encoding: .utf8) else { continue }
                candidates += Self.candidates(html: html, page: final)
            } catch {
                if Task.isCancelled { throw error }
            }
        }
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.id).inserted }
    }

    public func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack {
        guard track.sourceProvider == .web, let url = track.downloadURL,
              try await allowedByRobots(url) else { throw URLError(.noPermissionsToReadFile) }
        return try await MusicAudioDownloader.download(track, into: library, session: session)
    }
    public func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata { track.metadata }
    public func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord { track.license }

    private func boundedData(_ url: URL) async throws -> (Data, URLResponse) {
        guard MusicAudioDownloader.publicHTTPS(url) else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        request.setValue("VeloEdit/1.0 (music discovery)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let final = response.url, MusicAudioDownloader.publicHTTPS(final) else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            if data.count >= 2_000_000 { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return (data, response)
    }

    private func allowedByRobots(_ url: URL) async throws -> Bool {
        guard MusicAudioDownloader.publicHTTPS(url), let host = url.host else { return false }
        if robots[host] == nil {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.path = "/robots.txt"; components.query = nil; components.fragment = nil
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 5
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 404 { robots[host] = "" }
            else if http.statusCode == 200, data.count < 500_000, let text = String(data: data, encoding: .utf8) { robots[host] = text }
            else { return false }
        }
        return Self.robotsAllow(robots[host] ?? "", path: url.path + (url.query.map { "?" + $0 } ?? ""))
    }

    nonisolated static func robotsAllow(_ text: String, path: String) -> Bool {
        var groups: [(agents: [String], rules: [(String, Bool)])] = []
        var agents: [String] = []
        var rules: [(String, Bool)] = []
        for line in text.components(separatedBy: .newlines) + ["User-agent: __end__"] {
            let pieces = line.components(separatedBy: "#")[0].split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count == 2 else { continue }
            let key = pieces[0].lowercased(), value = pieces[1]
            if key == "user-agent" {
                if !rules.isEmpty { groups.append((agents, rules)); agents = []; rules = [] }
                agents.append(value.lowercased())
            } else if ["allow", "disallow"].contains(key), !value.isEmpty { rules.append((value, key == "allow")) }
        }
        let specific = groups.filter { $0.agents.contains(where: { $0 != "*" && "veloedit".contains($0) }) }
        let matching = specific.isEmpty ? groups.filter { $0.agents.contains("*") } : specific
        let applicable = matching.flatMap(\.rules).filter { pattern, _ in
            let anchored = pattern.hasSuffix("$")
            let raw = anchored ? String(pattern.dropLast()) : pattern
            let regex = "^" + raw.components(separatedBy: "*").map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".*") + (anchored ? "$" : "")
            return path.range(of: regex, options: .regularExpression) != nil
        }.sorted { $0.0.count == $1.0.count ? $0.1 && !$1.1 : $0.0.count > $1.0.count }
        return applicable.first?.1 ?? true
    }

    nonisolated static func candidates(html: String, page: URL) -> [MusicProviderTrack] {
        var results: [MusicProviderTrack] = []
        func string(_ value: Any?) -> String? {
            if let value = value as? String { return value }
            if let object = value as? [String: Any] { return object["name"] as? String ?? object["@id"] as? String ?? object["url"] as? String }
            return nil
        }
        func candidate(_ object: [String: Any]) -> MusicProviderTrack? {
            guard let title = string(object["name"]), !title.isEmpty,
                  let artist = string(object["byArtist"] ?? object["creator"] ?? object["author"]), !artist.isEmpty,
                  let rawLicense = string(object["license"]), let license = InternetArchiveMusicProvider.allowedLicense(rawLicense) else { return nil }
            let media = object["encoding"] ?? object["associatedMedia"] ?? object["audio"]
            let encodings = media as? [[String: Any]] ?? (media as? [String: Any]).map { [$0] } ?? []
            let contents = [string(object["contentUrl"])] + encodings.map { string($0["contentUrl"]) }
            guard let audio = contents.compactMap({ $0.flatMap { URL(string: $0, relativeTo: page)?.absoluteURL } }).first(where: {
                MusicAudioDownloader.publicHTTPS($0) && !["m3u8", "m3u", "mpd"].contains($0.pathExtension.lowercased())
            }) else { return nil }
            let by = license.path.hasPrefix("/licenses/by/")
            let tags = string(object["genre"])?.components(separatedBy: ",") ?? []
            let description = string(object["description"]) ?? ""
            return MusicProviderTrack(id: audio.absoluteString, sourceProvider: .web,
                metadata: MusicTrackMetadata(title: title, artist: artist, genres: tags, moods: [],
                    tags: MusicSearchRequest.translatedDescriptors(description.lowercased()), energy: 0.5, bpm: 100,
                    duration: 180, sourceName: page.host ?? "Web"),
                license: MusicLicenseRecord(name: by ? "Creative Commons BY" : "Creative Commons Public Domain", url: license,
                    attributionText: by ? "\(title) — \(artist). \(page.absoluteString). \(license.absoluteString)" : nil,
                    sourceName: page.host, sourceURL: page, licenseCheckedAt: Date(), requiresAttribution: by),
                sourcePageURL: page, downloadURL: audio)
        }
        func visit(_ value: Any) {
            if let array = value as? [Any] { array.forEach(visit); return }
            guard let object = value as? [String: Any] else { return }
            let types = (object["@type"] as? [String]) ?? [string(object["@type"])].compactMap { $0 }
            if !Set(types).isDisjoint(with: ["MusicRecording", "AudioObject"]), let track = candidate(object) { results.append(track) }
            for nested in object.values where nested is [String: Any] || nested is [Any] { visit(nested) }
        }
        let scripts = captures("(?is)<script\\b[^>]*type\\s*=\\s*['\"]application/ld\\+json['\"][^>]*>(.*?)</script>", in: html)
        for script in scripts {
            if let data = script.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) { visit(value) }
        }
        // Only a single-recording page may inherit a document-level license.
        // Footer licenses on articles and multi-track catalogues are not used.
        if results.isEmpty {
            let audioTags = captures("(?is)(<audio\\b[^>]*>.*?</audio>)", in: html)
            if audioTags.count == 1 {
                let licenseTag = captures("(?is)(<(?:a|link)\\b[^>]*rel=['\"]license['\"][^>]*>)", in: html).first
                let license = licenseTag.flatMap { captures("(?i)href=['\"]([^'\"]+)['\"]", in: $0).first }
                let title = captures("(?is)<title[^>]*>(.*?)</title>", in: html).first
                let author = captures("(?is)<meta\\b[^>]*name=['\"]author['\"][^>]*content=['\"]([^'\"]+)['\"]", in: html).first
                let url = captures("(?i)src=['\"]([^'\"]+)['\"]", in: audioTags[0]).first
                if let license, let title, let author, let url,
                   let track = candidate(["name": title, "author": author, "license": license, "contentUrl": url]) { results.append(track) }
            }
        }
        return results
    }

    private nonisolated static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
