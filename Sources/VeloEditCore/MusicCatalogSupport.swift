import Foundation

/// Small public-catalog parser; no browser execution or embedded page scripts.
enum MusicCatalogText {
    static let licenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!

    static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        for match in captures("&#(x[0-9a-f]+|[0-9]+);", in: text) {
            let value = match[0]
            let number = value.lowercased().hasPrefix("x") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
            if let number, let scalar = UnicodeScalar(number) {
                text = text.replacingOccurrences(of: "&#\(value);", with: String(scalar))
            }
        }
        for (entity, value) in [("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&ndash;", "–"), ("&mdash;", "—"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func descriptors(_ text: String) -> Set<String> {
        var tokens = MusicSearchRequest.words(text)
        let aliases: [(Set<String>, Set<String>)] = [
            (["calming", "relaxing", "meditation", "meditative", "gentle"], ["calm", "soft", "ambient"]),
            (["uplifting", "bouncy", "bright", "cheerful"], ["happy", "joyful", "upbeat"]),
            (["driving", "action", "powerful", "epic"], ["energetic", "adventure"]),
            (["strings", "orchestral", "orchestra", "symphony", "soundtrack"], ["cinematic", "emotional"]),
            (["guitar", "folk"], ["acoustic"]), (["synth", "synths", "electronica"], ["electronic"])
        ]
        for (terms, additions) in aliases where !tokens.isDisjoint(with: terms) { tokens.formUnion(additions) }
        return tokens
    }

    static func energy(_ tags: Set<String>) -> Double {
        if !tags.isDisjoint(with: ["energetic", "fast", "rock", "techno", "dance"]) { return 0.78 }
        if !tags.isDisjoint(with: ["joyful", "upbeat", "happy"]) { return 0.62 }
        if !tags.isDisjoint(with: ["calm", "soft", "ambient", "slow", "piano"]) { return 0.30 }
        return 0.5
    }

    static func titleQuery(_ intent: MusicIntent, removing artist: String) -> String? {
        guard let request = intent.request, request.exactTrack else { return nil }
        return request.query.replacingOccurrences(of: artist, with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "—–-")))
    }

    static func license(title: String, artist: String, source: String, page: URL) -> MusicLicenseRecord {
        MusicLicenseRecord(name: "Creative Commons BY 4.0", url: licenseURL,
            attributionText: "\(title) — \(artist). \(page.absoluteString). CC BY 4.0: \(licenseURL.absoluteString). Музыка смонтирована для видео.",
            usageRestrictions: "Укажите автора, ссылку на источник, лицензию и изменения. Для YouTube укажите атрибуцию в описании видео.",
            sourceName: source, sourceURL: page, licenseCheckedAt: Date(), requiresAttribution: true)
    }
}

/// Respect public catalogue access rules and Audionautix's three-second crawl delay.
actor MusicCatalogAccess {
    private let host: String
    private let session: URLSession
    private let delay: TimeInterval
    private var robots: (text: String, date: Date)?
    private var nextRequest = ContinuousClock.now

    init(host: String, session: URLSession, delay: TimeInterval = 0) {
        self.host = host; self.session = session; self.delay = delay
    }

    private func reserve() async throws {
        let start = max(.now, nextRequest)
        nextRequest = start.advanced(by: .seconds(delay))
        try await ContinuousClock().sleep(until: start)
        try Task.checkCancellation()
    }

    func authorize(_ url: URL) async throws {
        guard url.host == host, MusicAudioDownloader.publicHTTPS(url) else { throw URLError(.unsupportedURL) }
        if robots == nil || Date().timeIntervalSince(robots!.date) > 21_600 {
            try await reserve()
            var request = URLRequest(url: URL(string: "https://\(host)/robots.txt")!)
            request.timeoutInterval = 5
            request.setValue("text/plain", forHTTPHeaderField: "Accept")
            do {
                let data = try await MusicHTTPClient.data(for: request, session: session, maximumBytes: 500_000, minimumRetryDelay: delay)
                guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
                robots = (text, Date())
            } catch let error as MusicHTTPClient.HTTPError where error.status == 404 {
                robots = ("", Date())
            }
        }
        let path = url.path + (url.query.map { "?" + $0 } ?? "")
        guard WebMusicProvider.robotsAllow(robots?.text ?? "", path: path) else { throw URLError(.noPermissionsToReadFile) }
        try await reserve()
    }
}
