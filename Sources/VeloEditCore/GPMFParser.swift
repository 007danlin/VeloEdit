import Foundation
import AVFoundation

public struct GPMFRecord: Hashable, Sendable {
    public var key: String
    public var type: UInt8
    public var structureSize: Int
    public var repeatCount: Int
    public var payload: Data
    public var children: [GPMFRecord]

    public init(key: String, type: UInt8, structureSize: Int, repeatCount: Int, payload: Data, children: [GPMFRecord] = []) {
        self.key = key
        self.type = type
        self.structureSize = structureSize
        self.repeatCount = repeatCount
        self.payload = payload
        self.children = children
    }
}

public enum GPMFParserError: LocalizedError {
    case truncated(offset: Int)
    case invalidKey(offset: Int)
    public var errorDescription: String? {
        switch self {
        case .truncated(let offset): return "Обрезанный пакет телеметрии камеры около байта \(offset)"
        case .invalidKey(let offset): return "Некорректный ключ телеметрии камеры около байта \(offset)"
        }
    }
}

public struct GPMFParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> [GPMFRecord] {
        try parseRange(data, baseOffset: 0)
    }

    public func summary(_ records: [GPMFRecord]) -> TelemetrySummary {
        let flat = flatten(records)
        let streams = Set(flat.map(\.key))
        let sampleCount = flat.filter { ["GPS5", "ACCL", "GYRO", "CORI"].contains($0.key) }.reduce(0) { $0 + $1.repeatCount }
        var route: [TelemetryCoordinate] = []
        var speeds: [Double] = []
        var altitudes: [Double] = []
        var maxGForce: Double?

        for stream in flat where stream.key == "STRM" {
            let scaleRecord = stream.children.first(where: { $0.key == "SCAL" })
            let scales = scaleRecord.map(decodeNumbers) ?? []
            for record in stream.children {
                if record.key == "GPS5" {
                    let values = decodeNumbers(record)
                    let width = max(5, record.structureSize / max(1, scalarByteWidth(record.type)))
                    guard width >= 5 else { continue }
                    for index in stride(from: 0, to: values.count - 4, by: width) {
                        let latitude = scaled(values[index], index: 0, scales: scales)
                        let longitude = scaled(values[index + 1], index: 1, scales: scales)
                        let altitude = scaled(values[index + 2], index: 2, scales: scales)
                        let speed = scaled(values[index + 3], index: 3, scales: scales)
                        guard latitude.isFinite, longitude.isFinite,
                              (-90...90).contains(latitude), (-180...180).contains(longitude) else { continue }
                        route.append(TelemetryCoordinate(latitude: latitude, longitude: longitude))
                        if altitude.isFinite { altitudes.append(altitude) }
                        if speed.isFinite && speed >= 0 { speeds.append(speed) }
                    }
                } else if record.key == "ACCL" {
                    let values = decodeNumbers(record)
                    let width = max(3, record.structureSize / max(1, scalarByteWidth(record.type)))
                    for index in stride(from: 0, to: values.count - 2, by: width) {
                        let x = scaled(values[index], index: 0, scales: scales)
                        let y = scaled(values[index + 1], index: 1, scales: scales)
                        let z = scaled(values[index + 2], index: 2, scales: scales)
                        let magnitude = sqrt(x * x + y * y + z * z) / 9.80665
                        if magnitude.isFinite { maxGForce = max(maxGForce ?? 0, magnitude) }
                    }
                }
            }
        }
        // Some test and camera payloads expose sensor records without STRM.
        // They still count as GPMF, while numeric summaries remain optional.
        let distance = zip(route, route.dropFirst()).reduce(0.0) { $0 + haversine($1.0, $1.1) }
        return TelemetrySummary(
            hasGPMF: !records.isEmpty,
            sampleCount: sampleCount,
            maxSpeedMetersPerSecond: speeds.max(),
            distanceMeters: route.count > 1 ? distance : nil,
            minAltitudeMeters: altitudes.min(),
            maxAltitudeMeters: altitudes.max(),
            maxGForce: maxGForce,
            route: route.isEmpty ? nil : route,
            speedSamplesMetersPerSecond: speeds.isEmpty ? nil : speeds,
            altitudeSamplesMeters: altitudes.isEmpty ? nil : altitudes,
            streams: streams
        )
    }

    /// Decodes one metadata packet and distributes its sensor readings across
    /// the packet's source-timeline interval. High-rate accelerometer streams
    /// are peak-preserving downsampled to keep project manifests compact.
    public func timedSamples(
        _ records: [GPMFRecord],
        startTime: Double,
        duration: Double,
        maximumPoints: Int = 32
    ) -> [TelemetrySample] {
        guard maximumPoints > 0 else { return [] }
        var gps: [(coordinate: TelemetryCoordinate, altitude: Double, speed: Double)] = []
        var forces: [Double] = []
        for stream in flatten(records) where stream.key == "STRM" {
            let scales = stream.children.first(where: { $0.key == "SCAL" }).map(decodeNumbers) ?? []
            for record in stream.children {
                if record.key == "GPS5" {
                    let values = decodeNumbers(record)
                    let width = max(5, record.structureSize / max(1, scalarByteWidth(record.type)))
                    guard values.count >= 5 else { continue }
                    for index in stride(from: 0, through: values.count - 5, by: width) {
                        let latitude = scaled(values[index], index: 0, scales: scales)
                        let longitude = scaled(values[index + 1], index: 1, scales: scales)
                        let altitude = scaled(values[index + 2], index: 2, scales: scales)
                        let speed = scaled(values[index + 3], index: 3, scales: scales)
                        guard latitude.isFinite, longitude.isFinite, altitude.isFinite, speed.isFinite,
                              (-90...90).contains(latitude), (-180...180).contains(longitude), speed >= 0 else { continue }
                        gps.append((TelemetryCoordinate(latitude: latitude, longitude: longitude), altitude, speed))
                    }
                } else if record.key == "ACCL" {
                    let values = decodeNumbers(record)
                    let width = max(3, record.structureSize / max(1, scalarByteWidth(record.type)))
                    guard values.count >= 3 else { continue }
                    for index in stride(from: 0, through: values.count - 3, by: width) {
                        let x = scaled(values[index], index: 0, scales: scales)
                        let y = scaled(values[index + 1], index: 1, scales: scales)
                        let z = scaled(values[index + 2], index: 2, scales: scales)
                        let magnitude = sqrt(x * x + y * y + z * z) / 9.80665
                        if magnitude.isFinite { forces.append(magnitude) }
                    }
                }
            }
        }
        let count = min(maximumPoints, max(gps.count, forces.count))
        guard count > 0 else { return [] }
        let safeStart = startTime.isFinite ? max(0, startTime) : 0
        let safeDuration = duration.isFinite && duration > 0 ? duration : 1
        return (0..<count).map { index in
            let valueFraction = count == 1 ? 0.5 : Double(index) / Double(count - 1)
            let timeFraction = (Double(index) + 0.5) / Double(count)
            let gpsPoint = interpolatedGPS(gps, fraction: valueFraction)
            return TelemetrySample(
                timestamp: safeStart + timeFraction * safeDuration,
                speedMetersPerSecond: gpsPoint?.speed,
                altitudeMeters: gpsPoint?.altitude,
                gForce: peakPreservingSample(forces, index: index, outputCount: count),
                coordinate: gpsPoint?.coordinate
            )
        }
    }

    private func parseRange(_ data: Data, baseOffset: Int) throws -> [GPMFRecord] {
        var records: [GPMFRecord] = []
        var offset = 0
        while offset < data.count {
            if data.count - offset < 8 {
                if data[offset...].allSatisfy({ $0 == 0 }) { break }
                throw GPMFParserError.truncated(offset: baseOffset + offset)
            }
            let keyData = data[offset..<(offset + 4)]
            guard let key = String(data: keyData, encoding: .ascii), key.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }) else { throw GPMFParserError.invalidKey(offset: baseOffset + offset) }
            let type = data[offset + 4]
            let structureSize = Int(data[offset + 5])
            let repeatCount = Int(data[offset + 6]) << 8 | Int(data[offset + 7])
            let payloadSize = structureSize * repeatCount
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + payloadSize
            guard payloadEnd <= data.count else { throw GPMFParserError.truncated(offset: baseOffset + offset) }
            let payload = data[payloadStart..<payloadEnd]
            let children: [GPMFRecord]
            if key == "DEVC" || key == "STRM" {
                children = (try? parseRange(Data(payload), baseOffset: baseOffset + payloadStart)) ?? []
            } else { children = [] }
            records.append(GPMFRecord(key: key, type: type, structureSize: structureSize, repeatCount: repeatCount, payload: Data(payload), children: children))
            offset = payloadStart + ((payloadSize + 3) / 4 * 4)
        }
        return records
    }

    private func flatten(_ records: [GPMFRecord]) -> [GPMFRecord] {
        records.flatMap { [$0] + flatten($0.children) }
    }

    private func scalarByteWidth(_ type: UInt8) -> Int {
        switch Character(UnicodeScalar(type)) {
        case "b", "B": return 1
        case "s", "S": return 2
        case "l", "L", "f": return 4
        case "j", "J", "d": return 8
        default: return 1
        }
    }

    private func decodeNumbers(_ record: GPMFRecord) -> [Double] {
        let bytes = [UInt8](record.payload)
        let width = scalarByteWidth(record.type)
        guard width > 0 else { return [] }
        return stride(from: 0, through: max(-1, bytes.count - width), by: width).compactMap { offset in
            guard offset >= 0, offset + width <= bytes.count else { return nil }
            switch Character(UnicodeScalar(record.type)) {
            case "b": return Double(Int8(bitPattern: bytes[offset]))
            case "B": return Double(bytes[offset])
            case "s":
                let raw = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
                return Double(Int16(bitPattern: raw))
            case "S":
                return Double(UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
            case "l":
                let raw = bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return Double(Int32(bitPattern: raw))
            case "L":
                let raw = bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return Double(raw)
            case "f":
                let raw = bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return Double(Float(bitPattern: raw))
            case "d":
                let raw = bytes[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                return Double(bitPattern: raw)
            default: return nil
            }
        }
    }

    private func scaled(_ value: Double, index: Int, scales: [Double]) -> Double {
        let scale = scales.indices.contains(index) ? scales[index] : (scales.first ?? 1)
        return abs(scale) > 0.0000001 ? value / scale : value
    }

    private func interpolatedGPS(
        _ values: [(coordinate: TelemetryCoordinate, altitude: Double, speed: Double)],
        fraction: Double
    ) -> (coordinate: TelemetryCoordinate, altitude: Double, speed: Double)? {
        guard let first = values.first else { return nil }
        guard values.count > 1 else { return first }
        let position = min(1, max(0, fraction)) * Double(values.count - 1)
        let lower = Int(floor(position))
        let upper = min(values.count - 1, lower + 1)
        let blend = position - Double(lower)
        let lhs = values[lower]
        let rhs = values[upper]
        return (
            TelemetryCoordinate(
                latitude: lhs.coordinate.latitude + (rhs.coordinate.latitude - lhs.coordinate.latitude) * blend,
                longitude: lhs.coordinate.longitude + (rhs.coordinate.longitude - lhs.coordinate.longitude) * blend
            ),
            lhs.altitude + (rhs.altitude - lhs.altitude) * blend,
            lhs.speed + (rhs.speed - lhs.speed) * blend
        )
    }

    private func peakPreservingSample(_ values: [Double], index: Int, outputCount: Int) -> Double? {
        guard !values.isEmpty, outputCount > 0 else { return nil }
        let lower = min(values.count - 1, index * values.count / outputCount)
        let upper = min(values.count, max(lower + 1, (index + 1) * values.count / outputCount))
        return values[lower..<upper].max { abs($0 - 1) < abs($1 - 1) }
    }

    private func haversine(_ lhs: TelemetryCoordinate, _ rhs: TelemetryCoordinate) -> Double {
        let radius = 6_371_000.0
        let lat1 = lhs.latitude * .pi / 180
        let lat2 = rhs.latitude * .pi / 180
        let dLat = (rhs.latitude - lhs.latitude) * .pi / 180
        let dLon = (rhs.longitude - lhs.longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}

/// Reads only the GoPro metadata track. It never scans or decodes the original
/// video frames, so telemetry remains a cheap first stage before proxy work.
public struct GPMFExtractor: Sendable {
    public init() {}

    /// The default covers up to roughly two hours for cameras that emit one
    /// GPMF packet per second, instead of silently ignoring everything after
    /// the first few minutes of a long ride.
    public func summary(from url: URL, maximumSamples: Int = 7_200) async -> TelemetrySummary? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .metadata), !tracks.isEmpty else { return nil }
        var records: [GPMFRecord] = []
        var chunks: [(start: Double, duration: Double?, records: [GPMFRecord])] = []
        for track in tracks {
            guard let reader = try? AVAssetReader(asset: asset) else { continue }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            guard reader.startReading() else { continue }
            var count = 0
            while count < maximumSamples, let sample = output.copyNextSampleBuffer() {
                defer { count += 1 }
                guard let buffer = CMSampleBufferGetDataBuffer(sample) else { continue }
                let length = CMBlockBufferGetDataLength(buffer)
                guard length > 8 else { continue }
                var data = Data(count: length)
                let status = data.withUnsafeMutableBytes { bytes in
                    guard let destination = bytes.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
                    return CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: length, destination: destination)
                }
                guard status == kCMBlockBufferNoErr else { continue }
                if let parsed = try? GPMFParser().parse(data) {
                    records.append(contentsOf: parsed)
                    let presentation = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                    let rawDuration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
                    chunks.append((
                        start: presentation.isFinite ? presentation : Double(count),
                        duration: rawDuration.isFinite && rawDuration > 0 ? rawDuration : nil,
                        records: parsed
                    ))
                }
            }
            reader.cancelReading()
        }
        guard !records.isEmpty else { return nil }
        let parser = GPMFParser()
        var result = parser.summary(records)
        let sorted = chunks.sorted { $0.start < $1.start }
        let origin = sorted.first?.start ?? 0
        let gaps = zip(sorted, sorted.dropFirst()).map { $1.start - $0.start }.filter { $0.isFinite && $0 > 0 }
        let fallbackDuration = gaps.sorted().dropFirst(gaps.count / 2).first ?? 1
        var timed: [TelemetrySample] = []
        for index in sorted.indices {
            let inferred = index + 1 < sorted.count ? sorted[index + 1].start - sorted[index].start : fallbackDuration
            let chunkDuration = sorted[index].duration ?? (inferred.isFinite && inferred > 0 ? inferred : fallbackDuration)
            timed.append(contentsOf: parser.timedSamples(
                sorted[index].records,
                startTime: max(0, sorted[index].start - origin),
                duration: chunkDuration,
                maximumPoints: 12
            ))
        }
        result.timedSamples = timed.sorted { $0.timestamp < $1.timestamp }
        return result
    }
}
