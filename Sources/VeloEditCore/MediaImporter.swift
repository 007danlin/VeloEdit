import Foundation
import AVFoundation
import CryptoKit
import ImageIO

public enum MediaImportError: LocalizedError {
    case unsupported(URL)
    case unreadable(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let url): return "Формат не поддерживается: \(url.lastPathComponent)"
        case .unreadable(let url): return "Файл недоступен: \(url.path)"
        }
    }
}

public struct ImportProgress: Sendable {
    public var completed: Int
    public var total: Int
    public var currentName: String
    public var currentFileName: String?
    public var analysisStage: AnalysisStage?
    public var currentFileIndex: Int?
    public var fileCount: Int?
    public var currentSceneIndex: Int?
    public var sceneCount: Int?
    public var estimatedSecondsRemaining: TimeInterval?
    public var thermalThrottled: Bool
    public init(
        completed: Int,
        total: Int,
        currentName: String,
        currentFileName: String? = nil,
        analysisStage: AnalysisStage? = nil,
        currentFileIndex: Int? = nil,
        fileCount: Int? = nil,
        currentSceneIndex: Int? = nil,
        sceneCount: Int? = nil,
        estimatedSecondsRemaining: TimeInterval? = nil,
        thermalThrottled: Bool = false
    ) {
        self.completed = completed
        self.total = total
        self.currentName = currentName
        self.currentFileName = currentFileName
        self.analysisStage = analysisStage
        self.currentFileIndex = currentFileIndex
        self.fileCount = fileCount
        self.currentSceneIndex = currentSceneIndex
        self.sceneCount = sceneCount
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
        self.thermalThrottled = thermalThrottled
    }
}

public struct MediaImporter: Sendable {
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "insv", "360"]
    public static let photoExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "dng", "cr2", "nef", "arw"]
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"]

    public init() {}

    public func expand(_ inputURLs: [URL]) -> [URL] {
        expand(inputURLs, allowedExtensions: Self.videoExtensions.union(Self.photoExtensions))
    }

    public func expandAudio(_ inputURLs: [URL]) -> [URL] {
        expand(inputURLs, allowedExtensions: Self.audioExtensions)
    }

    public func expandTelemetry(_ inputURLs: [URL]) -> [URL] {
        expand(inputURLs, allowedExtensions: TelemetryEngine.sidecarExtensions)
    }

    private func expand(_ inputURLs: [URL], allowedExtensions: Set<String>) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        for url in inputURLs {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
                let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let candidate = enumerator?.nextObject() as? URL {
                    if allowedExtensions.contains(candidate.pathExtension.lowercased()) { results.append(candidate) }
                }
            } else if allowedExtensions.contains(url.pathExtension.lowercased()) {
                results.append(url)
            }
        }
        return Array(Set(results.map { $0.standardizedFileURL })).sorted { $0.path < $1.path }
    }

    public func importAssets(from inputURLs: [URL], existing: [MediaAsset] = [], progress: (@Sendable (ImportProgress) -> Void)? = nil) async -> [Result<MediaAsset, Error>] {
        progress?(ImportProgress(completed: 0, total: 0, currentName: "Сканирую выбранные файлы"))
        let urls = expand(inputURLs)
        progress?(ImportProgress(completed: 0, total: urls.count, currentName: "Подготавливаю метаданные"))
        let existingByURL = Dictionary(uniqueKeysWithValues: existing.map { ($0.originalURL.standardizedFileURL, $0) })
        var indexed: [(Int, Result<MediaAsset, Error>)] = []
        indexed.reserveCapacity(urls.count)
        let pending = urls.enumerated().filter { index, url in
            if let old = existingByURL[url] {
                indexed.append((index, .success(old)))
                return false
            }
            return true
        }
        var completed = indexed.count
        // Bounded batches avoid opening hundreds of camera files at once while
        // letting Apple Silicon parse several metadata headers concurrently.
        var batchStart = 0
        var resourcePacer = ResourceWorkPacer()
        while batchStart < pending.count {
            while ProcessInfo.processInfo.thermalState == .critical {
                if Task.isCancelled { break }
                progress?(ImportProgress(completed: completed, total: urls.count, currentName: "Охлаждаю Mac — импорт приостановлен"))
                try? await Task.sleep(for: .seconds(2))
            }
            if Task.isCancelled { break }
            do { try await resourcePacer.checkpoint() }
            catch { break }
            let resources = await SystemResourceMonitor.shared.snapshot()
            let batchSize = resources.workLimit == .unrestricted ? Self.recommendedImportConcurrency : 1
            let batch = Array(pending[batchStart..<min(pending.count, batchStart + batchSize)])
            if let first = batch.first {
                progress?(ImportProgress(completed: completed, total: urls.count, currentName: "Читаю: \(first.element.lastPathComponent)"))
            }
            await withTaskGroup(of: (Int, URL, Result<MediaAsset, Error>).self) { group in
                for (index, url) in batch {
                    group.addTask {
                        do { return (index, url, .success(try await makeAsset(url: url))) }
                        catch { return (index, url, .failure(error)) }
                    }
                }
                for await (index, url, result) in group {
                    indexed.append((index, result))
                    completed += 1
                    progress?(ImportProgress(completed: completed, total: urls.count, currentName: url.lastPathComponent))
                }
            }
            batchStart += batch.count
        }
        progress?(ImportProgress(completed: completed, total: urls.count, currentName: Task.isCancelled ? "Импорт отменён" : "Готово"))
        return indexed.sorted { $0.0 < $1.0 }.map(\.1)
    }

    public func makeAsset(url: URL) async throws -> MediaAsset {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw MediaImportError.unreadable(url) }
        guard let kind = kind(for: url) else { throw MediaImportError.unsupported(url) }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        // Import must not read a multi-gigabyte video end to end. This bounded
        // fingerprint reads metadata plus at most 128 KiB from the file.
        let hash = try Self.quickFingerprint(
            url: url,
            byteSize: Int64(values.fileSize ?? 0),
            modificationDate: values.contentModificationDate
        )
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let metadata: MediaMetadata
        switch kind {
        case .video:
            metadata = try await videoMetadata(
                url: url,
                fileCreationDate: values.creationDate,
                modificationDate: values.contentModificationDate
            )
        case .photo:
            metadata = try photoMetadata(
                url: url,
                fileCreationDate: values.creationDate,
                modificationDate: values.contentModificationDate
            )
        }
        return MediaAsset(originalURL: url.standardizedFileURL, bookmarkData: bookmark, kind: kind, byteSize: Int64(values.fileSize ?? 0), contentHash: hash, metadata: metadata)
    }

    public func kind(for url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if Self.videoExtensions.contains(ext) { return .video }
        if Self.photoExtensions.contains(ext) { return .photo }
        return nil
    }

    private static var recommendedImportConcurrency: Int {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 1 }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return 4
        case .fair: return 2
        case .serious, .critical: return 1
        @unknown default: return 1
        }
    }

    private func videoMetadata(url: URL, fileCreationDate: Date?, modificationDate: Date?) async throws -> MediaMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let video = videoTracks.first else { throw MediaImportError.unsupported(url) }
        let naturalSize = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let frameRate = try await video.load(.nominalFrameRate)
        let descriptions = try await video.load(.formatDescriptions)
        let transformed = naturalSize.applying(transform)
        let dimensions = (width: Int(abs(transformed.width).rounded()), height: Int(abs(transformed.height).rounded()))
        let codec = descriptions.first.map { Self.fourCC(CMFormatDescriptionGetMediaSubType($0)) }
        let orientation: Int
        if transform.b == 1 && transform.c == -1 { orientation = 90 }
        else if transform.a == -1 && transform.d == -1 { orientation = 180 }
        else if transform.b == -1 && transform.c == 1 { orientation = 270 }
        else { orientation = 0 }
        let colorDescriptions = descriptions.map(Self.colorDescription)
        let colorDescription = colorDescriptions.first(where: \.isHDR) ?? colorDescriptions.first ?? .unknown
        let embeddedDate = await Self.videoCaptureDate(in: asset) ?? MediaCaptureClock.movieDate(at: url)
        let captureDate = embeddedDate ?? fileCreationDate ?? modificationDate
        let dateSource: MediaDateSource? = embeddedDate != nil
            ? .embeddedMetadata
            : fileCreationDate != nil ? .fileCreationDate
            : modificationDate != nil ? .fileModificationDate : nil
        return MediaMetadata(
            duration: duration.seconds.isFinite ? duration.seconds : nil,
            width: dimensions.width,
            height: dimensions.height,
            frameRate: Double(frameRate),
            codec: codec,
            dynamicRange: colorDescription.isHDR ? .hdr : .sdr,
            colorPrimaries: colorDescription.primaries,
            transferFunction: colorDescription.transfer,
            yCbCrMatrix: colorDescription.matrix,
            bitDepth: colorDescription.bitDepth,
            hasAudio: !audioTracks.isEmpty,
            creationDate: captureDate,
            modificationDate: modificationDate,
            dateSource: dateSource,
            dateConfidence: dateSource == .embeddedMetadata ? 0.98 : dateSource == .fileCreationDate ? 0.68 : 0.32,
            orientationDegrees: orientation
        )
    }

    private struct VideoColorDescription {
        var primaries: String?
        var transfer: String?
        var matrix: String?
        var bitDepth: Int?
        var isHDR: Bool

        static let unknown = VideoColorDescription(
            primaries: nil, transfer: nil, matrix: nil, bitDepth: nil, isHDR: false
        )
    }

    /// Normalizes the deliberately inconsistent strings emitted by camera
    /// vendors and AVFoundation. GoPro files can identify HLG as either
    /// ITU-R 2100 or ARIB STD-B67, while PQ is normally SMPTE ST 2084.
    private static func colorDescription(_ description: CMFormatDescription) -> VideoColorDescription {
        guard let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] else {
            return .unknown
        }
        let text = String(describing: extensions).lowercased()
        let isPQ = text.contains("2084") || text.contains("pq")
        let isHLG = text.contains("hlg") || text.contains("arib_std_b67") || text.contains("itur_2100")
        let is2020 = text.contains("2020") || isPQ || isHLG
        let tenBit = text.contains("10bit") || text.contains("10-bit") || text.contains("420v10") || text.contains("xf44")
        return VideoColorDescription(
            primaries: is2020 ? "ITU_R_2020" : "ITU_R_709_2",
            transfer: isPQ ? "SMPTE_ST_2084_PQ" : isHLG ? "ITU_R_2100_HLG" : "ITU_R_709_2",
            matrix: is2020 ? "ITU_R_2020" : "ITU_R_709_2",
            bitDepth: tenBit || isPQ || isHLG ? 10 : 8,
            isHDR: isPQ || isHLG
        )
    }

    private func photoMetadata(url: URL, fileCreationDate: Date?, modificationDate: Date?) throws -> MediaMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw MediaImportError.unreadable(url)
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let lat = Self.coordinate(gps?[kCGImagePropertyGPSLatitude], reference: gps?[kCGImagePropertyGPSLatitudeRef])
        let lon = Self.coordinate(gps?[kCGImagePropertyGPSLongitude], reference: gps?[kCGImagePropertyGPSLongitudeRef])
        let utcOffset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
        let embeddedDate = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap {
            Self.exifDate($0, utcOffset: utcOffset)
        }
        let date = embeddedDate ?? fileCreationDate ?? modificationDate
        let dateSource: MediaDateSource? = embeddedDate != nil
            ? .embeddedMetadata
            : fileCreationDate != nil ? .fileCreationDate
            : modificationDate != nil ? .fileModificationDate : nil
        return MediaMetadata(
            width: width,
            height: height,
            dynamicRange: .sdr,
            creationDate: date,
            modificationDate: modificationDate,
            timeZoneIdentifier: utcOffset,
            dateSource: dateSource,
            dateConfidence: dateSource == .embeddedMetadata ? 0.98 : dateSource == .fileCreationDate ? 0.68 : 0.32,
            latitude: lat,
            longitude: lon,
            cameraMake: tiff?[kCGImagePropertyTIFFMake] as? String,
            cameraModel: tiff?[kCGImagePropertyTIFFModel] as? String,
            orientationDegrees: Self.orientationDegrees(exifOrientation: orientation)
        )
    }

    private static func videoCaptureDate(in asset: AVURLAsset) async -> Date? {
        guard let formats = try? await asset.load(.availableMetadataFormats) else { return nil }
        for format in formats {
            guard let items = try? await asset.loadMetadata(for: format) else { continue }
            for item in items {
                let identifier = item.identifier?.rawValue.lowercased() ?? ""
                guard identifier.contains("creationdate") || identifier.contains("creation-date") else { continue }
                if let date = try? await item.load(.dateValue) { return date }
                if let value = try? await item.load(.stringValue), let date = isoDate(value) { return date }
            }
        }
        return nil
    }

    private static func isoDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    public static func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func quickFingerprint(url: URL, byteSize: Int64, modificationDate: Date?) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let sampleSize = 65_536
        var hasher = SHA256()
        hasher.update(data: Data("veloedit-fast-v1|\(byteSize)|\(modificationDate?.timeIntervalSince1970 ?? 0)".utf8))
        let head = try handle.read(upToCount: sampleSize) ?? Data()
        hasher.update(data: head)
        if byteSize > Int64(sampleSize) {
            try handle.seek(toOffset: UInt64(max(0, byteSize - Int64(sampleSize))))
            let tail = try handle.read(upToCount: sampleSize) ?? Data()
            hasher.update(data: tail)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", value)
    }

    private static func coordinate(_ value: Any?, reference: Any?) -> Double? {
        guard var coordinate = value as? Double else { return nil }
        if let ref = reference as? String, ref == "S" || ref == "W" { coordinate *= -1 }
        return coordinate
    }

    private static func exifDate(_ value: String, utcOffset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let utcOffset, let timeZone = exifTimeZone(utcOffset) {
            formatter.timeZone = timeZone
        }
        return formatter.date(from: value)
    }

    private static func exifTimeZone(_ value: String) -> TimeZone? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 3 else { return nil }
        let sign = clean.hasPrefix("-") ? -1 : 1
        let digits = clean.dropFirst().filter(\.isNumber)
        guard digits.count >= 2, let hours = Int(digits.prefix(2)) else { return nil }
        let minutes = digits.count >= 4 ? Int(digits.dropFirst(2).prefix(2)) ?? 0 : 0
        return TimeZone(secondsFromGMT: sign * (hours * 3_600 + minutes * 60))
    }

    private static func orientationDegrees(exifOrientation: Int) -> Int {
        switch exifOrientation { case 3, 4: return 180; case 5, 6: return 90; case 7, 8: return 270; default: return 0 }
    }
}
