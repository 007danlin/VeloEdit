import Foundation

/// Read the ISO-BMFF movie clock without decoding or loading the media payload.
/// Cameras commonly store it in mvhd but expose no AVMetadataItem for it.
enum MediaCaptureClock {
    static func movieDate(at url: URL) -> Date? {
        guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        func bytes(_ offset: UInt64, _ count: Int) -> [UInt8]? {
            guard offset <= size, UInt64(count) <= size - offset else { return nil }
            do {
                try handle.seek(toOffset: offset)
                guard let data = try handle.read(upToCount: count), data.count == count else { return nil }
                return Array(data)
            } catch { return nil }
        }
        func number(_ data: ArraySlice<UInt8>) -> UInt64 { data.reduce(0) { ($0 << 8) | UInt64($1) } }
        func scan(_ start: UInt64, _ end: UInt64, inMovie: Bool) -> Date? {
            var cursor = start
            var count = 0
            while cursor <= end, end - cursor >= 8, count < 10_000 {
                count += 1
                guard let header = bytes(cursor, 8) else { return nil }
                let type = String(bytes: header[4..<8], encoding: .ascii)
                var length = number(header[0..<4])
                var headerSize: UInt64 = 8
                if length == 1 {
                    guard let extended = bytes(cursor + 8, 8) else { return nil }
                    length = number(extended[...]); headerSize = 16
                } else if length == 0 { length = end - cursor }
                guard length >= headerSize, length <= end - cursor else { return nil }
                let payload = cursor + headerSize
                if type == "moov", !inMovie {
                    if let date = scan(payload, cursor + length, inMovie: true) { return date }
                } else if type == "mvhd", inMovie, length - headerSize >= 12,
                          let version = bytes(payload, 4), version[0] <= 1 {
                    let width = version[0] == 1 ? 8 : 4
                    guard length - headerSize >= UInt64(4 + width), let value = bytes(payload + 4, width) else { return nil }
                    let seconds = number(value[...])
                    let date = Date(timeIntervalSince1970: Double(seconds) - 2_082_844_800)
                    // Zero/uninitialized camera clocks are not capture evidence.
                    if date >= Date(timeIntervalSince1970: 946_684_800), date <= Date().addingTimeInterval(86_400) { return date }
                }
                cursor += length
            }
            return nil
        }
        return scan(0, size, inMovie: false)
    }

    static func metadata(for asset: MediaAsset) -> MediaMetadata {
        var metadata = asset.metadata
        if asset.kind == .video, metadata.dateSource != .embeddedMetadata,
           let date = movieDate(at: asset.originalURL) {
            metadata.creationDate = date
            metadata.dateSource = .embeddedMetadata
            metadata.dateConfidence = 0.98
        }
        return metadata
    }
}
