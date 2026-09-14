import Foundation

/// Shared bounded transport for official music APIs. Retry temporary failures,
/// but never retry authentication errors, missing files or cancelled work.
enum MusicHTTPClient {
    struct HTTPError: LocalizedError {
        let status: Int
        let host: String
        let retryAfter: TimeInterval?
        var errorDescription: String? { "\(host): HTTP \(status)" }
    }

    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              let url = http.url, MusicAudioDownloader.publicHTTPS(url) else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError(status: http.statusCode, host: url.host ?? "Music",
                retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        }
    }

    static func retryDelay(for error: Error) -> TimeInterval? {
        if let error = error as? HTTPError {
            guard [408, 429, 500, 502, 503, 504].contains(error.status) else { return nil }
            // Long rate limits belong to the next request, not a blocked UI.
            if let delay = error.retryAfter, delay > 2 { return nil }
            return max(0.25, error.retryAfter ?? 0.5)
        }
        let error = error as NSError
        guard error.domain == NSURLErrorDomain,
              [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
               NSURLErrorDNSLookupFailed, NSURLErrorCannotFindHost].contains(error.code) else { return nil }
        return 0.5
    }

    static func data(at url: URL, session: URLSession, timeout: TimeInterval = 10, maximumBytes: Int = 8_000_000) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await data(for: request, session: session, maximumBytes: maximumBytes)
    }

    static func data(for original: URLRequest, session: URLSession, maximumBytes: Int = 8_000_000, minimumRetryDelay: TimeInterval = 0) async throws -> Data {
        guard let url = original.url, MusicAudioDownloader.publicHTTPS(url) else { throw URLError(.unsupportedURL) }
        var request = original
        request.setValue("VeloEdit/1.0 (music discovery)", forHTTPHeaderField: "User-Agent")
        for attempt in 0...1 {
            do {
                try Task.checkCancellation()
                let (bytes, response) = try await session.bytes(for: request)
                try validate(response)
                guard response.expectedContentLength <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return data
            } catch {
                guard !Task.isCancelled, attempt == 0, let delay = retryDelay(for: error) else { throw error }
                try await Task.sleep(for: .seconds(max(delay, minimumRetryDelay)))
            }
        }
        throw URLError(.resourceUnavailable)
    }
}
