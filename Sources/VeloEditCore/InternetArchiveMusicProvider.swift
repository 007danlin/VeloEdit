import Foundation
import AVFoundation

/// Searches the public audio index, then verifies each item's current file
/// manifest and license. No collection IDs, scraping, login or stream capture.
public actor InternetArchiveMusicProvider: MusicProvider {
    public nonisolated let identifier = "internet-archive"
    public nonisolated let sourceProvider: MusicSourceProvider = .internetArchive
    public nonisolated let fallbackTier = 2
    public nonisolated let priority = 120
    private let library: LocalMusicLibrary
    private let session: URLSession

    public init(library: LocalMusicLibrary, session: URLSession? = nil) {
        self.library = library
        self.session = session ?? MusicAudioDownloader.makeSession()
    }

    public func availability() async -> MusicProviderAvailability { .available }

    public func search(_ intent: MusicIntent) async throws -> [MusicProviderTrack] {
        let data = try await json(at: Self.searchURL(for: intent))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let response = root?["response"] as? [String: Any]
        let docs = response?["docs"] as? [[String: Any]] ?? []
        var results: [MusicProviderTrack] = []
        for doc in docs.prefix(6) {
            try Task.checkCancellation()
            guard let id = doc["identifier"] as? String,
                  id.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else { continue }
            do {
                let metadata = try await json(at: URL(string: "https://archive.org/metadata/")!.appendingPathComponent(id))
                results += try Self.candidates(data: metadata, identifier: id)
            } catch {
                if Task.isCancelled { throw error }
                // One unavailable item does not discard other search hits.
            }
        }
        return results
    }

    nonisolated static func searchURL(for intent: MusicIntent) -> URL {
        let terms = MusicSearchRequest.words(intent.request?.query ?? [intent.genres.sorted().first, intent.mood.sorted().first].compactMap { $0 }.joined(separator: " "))
            .sorted().prefix(12).map { "\"\($0)\"" }.joined(separator: " AND ")
        var url = URLComponents(string: "https://archive.org/advancedsearch.php")!
        url.queryItems = [
            URLQueryItem(name: "q", value: "mediatype:audio AND (\(terms.isEmpty ? "music" : terms)) AND licenseurl:(*creativecommons.org*)"),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "rows", value: "6"),
            URLQueryItem(name: "output", value: "json")
        ]
        return url.url!
    }

    nonisolated static func candidates(data: Data, identifier: String) throws -> [MusicProviderTrack] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = root["metadata"] as? [String: Any],
              let files = root["files"] as? [[String: Any]] else { return [] }
        func text(_ value: Any?) -> String {
            if let value = value as? String { return value }
            if let values = value as? [String] { return values.joined(separator: " ") }
            return ""
        }
        func restricted(_ object: [String: Any]) -> Bool {
            ["is_dark", "nodownload", "access-restricted-item", "private"].contains {
                object[$0] as? Bool == true || ["true", "1"].contains(text(object[$0]).lowercased())
            }
        }
        guard !restricted(root), !restricted(metadata) else { return [] }
        let source = URL(string: "https://archive.org/details/")!.appendingPathComponent(identifier)
        return files.compactMap { file in
            guard !restricted(file), let name = file["name"] as? String,
                  let licenseURL = Self.allowedLicense(text(file["licenseurl"] ?? metadata["licenseurl"])) else { return nil }
            let ext = (name as NSString).pathExtension.lowercased()
            guard MusicAudioDownloader.extensions.contains(ext),
                  !name.split(separator: "/").contains(".."),
                  !name.lowercased().contains("sample"), !name.lowercased().contains("preview") else { return nil }
            let size = Int64(text(file["size"])) ?? 0
            guard size > 0, size <= MusicAudioDownloader.maximumBytes else { return nil }
            let title = text(file["title"]).isEmpty ? text(metadata["title"]) : text(file["title"])
            let artist = text(file["artist"]).isEmpty ? text(metadata["creator"]) : text(file["artist"])
            guard !title.isEmpty, !artist.isEmpty else { return nil }
            let lengthParts = text(file["length"]).split(separator: ":").compactMap { Double($0) }
            let duration = lengthParts.isEmpty ? 180 : lengthParts.reduce(0) { $0 * 60 + $1 }
            guard duration.isFinite, duration >= 30, duration <= 1_800 else { return nil }
            let by = licenseURL.path.hasPrefix("/licenses/by/")
            let tags = text(metadata["subject"]).components(separatedBy: CharacterSet(charactersIn: ";,"))
            let url = URL(string: "https://archive.org/download/")!.appendingPathComponent(identifier).appendingPathComponent(name)
            return MusicProviderTrack(
                id: identifier + "/" + name,
                sourceProvider: .internetArchive,
                metadata: MusicTrackMetadata(title: title, artist: artist, genres: tags, moods: tags,
                    tags: tags + [ext == "flac" || ext == "wav" ? "lossless" : "audio"],
                    energy: 0.5, bpm: 100, duration: duration, sourceName: "Internet Archive"),
                license: MusicLicenseRecord(name: by ? "Creative Commons BY" : "Creative Commons Public Domain",
                    url: licenseURL, attributionText: by ? "\(title) — \(artist). \(source.absoluteString). \(licenseURL.absoluteString)" : nil,
                    sourceName: "Internet Archive", sourceURL: source, licenseCheckedAt: Date(), requiresAttribution: by),
                sourcePageURL: source, downloadURL: url
            )
        }
    }

    nonisolated static func allowedLicense(_ value: String) -> URL? {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              ["creativecommons.org", "www.creativecommons.org"].contains(components.host?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              components.path.range(of: "^/(licenses/by/[1-4]\\.0|publicdomain/(zero|mark)/1\\.0)/?(deed\\.[a-z_-]+)?$", options: .regularExpression) != nil else { return nil }
        components.scheme = "https"
        return components.url
    }

    private func json(at url: URL) async throws -> Data {
        try await MusicHTTPClient.data(at: url, session: session, timeout: 8, maximumBytes: 5_000_000)
    }

    public func download(_ track: MusicProviderTrack) async throws -> LocalMusicTrack {
        try await MusicAudioDownloader.download(track, into: library, session: session)
    }
    public func metadata(_ track: MusicProviderTrack) async throws -> MusicTrackMetadata { track.metadata }
    public func license(_ track: MusicProviderTrack) async throws -> MusicLicenseRecord { track.license }
}

enum MusicAudioDownloader {
    static let maximumBytes: Int64 = 200 * 1_024 * 1_024
    static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus"]

    static func publicHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return host != "localhost" && !host.hasSuffix(".local") && !host.hasSuffix(".localhost") &&
            !host.contains(":") && host.range(of: "^[0-9.]+$", options: .regularExpression) == nil
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration, delegate: MusicDownloadDelegate(), delegateQueue: nil)
    }

    static func download(_ candidate: MusicProviderTrack, into library: LocalMusicLibrary, session: URLSession, minimumDuration: TimeInterval = 0, minimumRetryDelay: TimeInterval = 0) async throws -> LocalMusicTrack {
        if let cached = try await library.tracks().first(where: {
            $0.sourceProvider == candidate.sourceProvider && $0.providerTrackID == candidate.id && $0.isPlayable && $0.duration >= minimumDuration
        }) { return cached }
        guard let url = candidate.downloadURL, publicHTTPS(url) else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("VeloEdit/1.0 (music download)", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await downloadWithRetry(request, session: session, minimumRetryDelay: minimumRetryDelay)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let finalURL = response.url, publicHTTPS(finalURL),
              response.mimeType != "text/html", response.mimeType != "application/json" else { throw URLError(.badServerResponse) }
        let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard response.expectedContentLength < 0 || size >= response.expectedContentLength else { throw URLError(.networkConnectionLost) }
        guard size > 0, size <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        let suggested = ((response.suggestedFilename ?? "") as NSString).pathExtension.lowercased()
        let mimeExtensions = ["audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/aac": "aac", "audio/wav": "wav", "audio/x-wav": "wav", "audio/flac": "flac", "audio/ogg": "ogg"]
        let ext = extensions.contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased()
            : extensions.contains(suggested) ? suggested : mimeExtensions[response.mimeType ?? ""] ?? "mp3"
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.moveItem(at: temporary, to: staged)
        if minimumDuration > 0 {
            let duration = try await AVURLAsset(url: staged).load(.duration).seconds
            guard duration.isFinite, duration >= minimumDuration else { throw MusicLibraryError.unreadableAudio }
        }
        return try await library.importProviderTrack(candidate, downloadedFileURL: staged)
    }

    private static func downloadWithRetry(_ request: URLRequest, session: URLSession, minimumRetryDelay: TimeInterval) async throws -> (URL, URLResponse) {
        for attempt in 0...1 {
            do {
                try Task.checkCancellation()
                let (file, response) = try await session.download(for: request)
                do { try MusicHTTPClient.validate(response); return (file, response) }
                catch { try? FileManager.default.removeItem(at: file); throw error }
            } catch {
                guard !Task.isCancelled, attempt == 0, let delay = MusicHTTPClient.retryDelay(for: error) else { throw error }
                try await Task.sleep(for: .seconds(max(delay, minimumRetryDelay)))
            }
        }
        throw URLError(.resourceUnavailable)
    }

}

private final class MusicDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(MusicAudioDownloader.publicHTTPS) == true ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > MusicAudioDownloader.maximumBytes { downloadTask.cancel() }
    }
}
