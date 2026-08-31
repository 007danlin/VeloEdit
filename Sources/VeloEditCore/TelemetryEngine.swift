import Foundation
import AVFoundation

public enum TelemetryEngineError: LocalizedError {
    case unsupported(URL)
    case empty(URL)
    case malformed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let url): return "Формат телеметрии не поддерживается: \(url.lastPathComponent)"
        case .empty(let url): return "В \(url.lastPathComponent) не найдено пригодных данных телеметрии"
        case .malformed(let url, let message): return "Не удалось прочитать \(url.lastPathComponent): \(message)"
        }
    }
}

/// Unified, offline telemetry entry point. The vendored OVRLEY Rust process is
/// the primary parser for camera containers, CSV and VBO. Sidecar formats that
/// upstream parses in its browser layer are handled natively and normalized to
/// the same optional-sample contract (missing data never becomes a fake zero).
public struct TelemetryEngine: Sendable {
    public static let sidecarExtensions: Set<String> = ["gpx", "fit", "srt", "csv", "vbo"]

    private let ovrley = OVRLEYBridge()

    public init() {}

    public func importSource(url: URL, linkedAssetID: UUID? = nil) async throws -> TelemetrySource {
        let ext = url.pathExtension.lowercased()
        let parsed: ParsedTelemetry
        switch ext {
        case "csv", "vbo":
            do {
                parsed = try ParsedTelemetry(activity: await ovrley.parse(url: url), fallbackFormat: ext == "vbo" ? .vbo : .csv)
            } catch where ext == "csv" {
                parsed = try CSVTelemetryParser.parse(url: url)
            }
        case "gpx": parsed = try GPXTelemetryParser.parse(url: url)
        case "fit": parsed = try FITTelemetryParser.parse(url: url)
        case "srt": parsed = try SRTTelemetryParser.parse(url: url)
        default: throw TelemetryEngineError.unsupported(url)
        }
        return try makeSource(parsed: parsed, url: url, linkedAssetID: linkedAssetID)
    }

    public func embeddedSource(for asset: MediaAsset) async -> TelemetrySource? {
        guard asset.kind == .video else { return nil }
        if let activity = try? await ovrley.parse(url: asset.originalURL),
           let parsed = try? ParsedTelemetry(activity: activity, fallbackFormat: embeddedFormat(for: activity)),
           let source = try? makeSource(parsed: parsed, url: asset.originalURL, linkedAssetID: asset.id),
           source.summary.availableWidgetKinds.contains(where: { $0 != .elapsedTime }) {
            var namedSource = source
            namedSource.displayName = "\(asset.displayName) · \(activity.embeddedCameraName)"
            return namedSource
        }
        if let summary = await GPMFExtractor().summary(from: asset.originalURL), summary.hasTelemetry {
            return TelemetrySource(
                originalURL: asset.originalURL,
                bookmarkData: asset.bookmarkData,
                displayName: "\(asset.displayName) · GoPro GPMF",
                format: .embeddedGPMF,
                linkedAssetID: asset.id,
                startDate: asset.metadata.creationDate,
                summary: summary,
                synchronization: TelemetrySynchronization(offsetSeconds: 0, method: .embeddedTimecode, confidence: 1, frameRate: asset.metadata.frameRate)
            )
        }
        return await QuickTimeVideoTelemetryExtractor().source(for: asset)
    }

    public func synchronize(source: TelemetrySource, with asset: MediaAsset) -> TelemetrySynchronization {
        if source.format == .embeddedGPMF || source.format == .embeddedDJI || source.format == .embeddedInsta360 || source.format == .embeddedCamera || source.format == .embeddedQuickTime {
            return TelemetrySynchronization(offsetSeconds: 0, method: .embeddedTimecode, confidence: 1, frameRate: asset.metadata.frameRate)
        }
        if let videoDate = asset.metadata.creationDate, let telemetryDate = source.startDate {
            return TelemetrySynchronization(
                offsetSeconds: videoDate.timeIntervalSince(telemetryDate),
                method: .telemetryTimestamp,
                confidence: 0.92,
                frameRate: asset.metadata.frameRate
            )
        }
        if let videoDate = asset.metadata.creationDate,
           let telemetryDate = Self.dateInFilename(source.displayName) {
            return TelemetrySynchronization(
                offsetSeconds: videoDate.timeIntervalSince(telemetryDate),
                method: .filenameTimestamp,
                confidence: 0.55,
                frameRate: asset.metadata.frameRate
            )
        }
        return TelemetrySynchronization(offsetSeconds: 0, method: .manualOffset, confidence: 0, frameRate: asset.metadata.frameRate)
    }

    public func applyingCSVMapping(
        to source: TelemetrySource,
        mapping: [String: TelemetryCSVField]
    ) -> TelemetrySource {
        guard source.format == .csv, var samples = source.summary.timedSamples, !samples.isEmpty else { return source }
        for index in samples.indices {
            let custom = samples[index].customFields ?? [:]
            var latitude = samples[index].coordinate?.latitude
            var longitude = samples[index].coordinate?.longitude
            for (column, target) in mapping {
                guard target != .ignore, let value = custom[column] else { continue }
                switch target {
                case .ignore: break
                case .timestamp: samples[index].timestamp = value
                case .latitude: latitude = value
                case .longitude: longitude = value
                case .speedMetersPerSecond: samples[index].speedMetersPerSecond = value
                case .speedKilometersPerHour: samples[index].speedMetersPerSecond = value / 3.6
                case .altitudeMeters: samples[index].altitudeMeters = value
                case .distanceMeters: samples[index].distanceMeters = value
                case .headingDegrees: samples[index].headingDegrees = value
                case .gForce: samples[index].gForce = value
                case .heartRate: samples[index].heartRateBPM = value
                case .cadence: samples[index].cadenceRPM = value
                case .powerWatts: samples[index].powerWatts = value
                }
            }
            if let latitude, let longitude {
                samples[index].coordinate = TelemetryCoordinate(latitude: latitude, longitude: longitude)
            }
        }
        var result = source
        if mapping.values.contains(.timestamp), let first = samples.map(\.timestamp).min() {
            if first > 100_000_000 { result.startDate = Date(timeIntervalSince1970: first) }
            for index in samples.indices { samples[index].timestamp = max(0, samples[index].timestamp - first) }
        }
        result.summary = TelemetryNormalizer.summary(samples: samples, format: .csv)
        return result
    }

    private func makeSource(parsed: ParsedTelemetry, url: URL, linkedAssetID: UUID?) throws -> TelemetrySource {
        let summary = TelemetryNormalizer.summary(samples: parsed.samples, format: parsed.format)
        guard summary.hasTelemetry else { throw TelemetryEngineError.empty(url) }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return TelemetrySource(
            originalURL: url,
            bookmarkData: bookmark,
            displayName: url.lastPathComponent,
            format: parsed.format,
            linkedAssetID: linkedAssetID,
            startDate: parsed.startDate,
            summary: summary,
            synchronization: TelemetrySynchronization(
                offsetSeconds: 0,
                method: linkedAssetID == nil ? .manualOffset : .embeddedTimecode,
                confidence: linkedAssetID == nil ? 0 : 1
            )
        )
    }

    private func embeddedFormat(for activity: OVRLEYActivity) -> TelemetrySourceFormat {
        let value = activity.metadata?.cameraType?.lowercased() ?? ""
        if value.contains("dji") { return .embeddedDJI }
        if value.contains("insta") { return .embeddedInsta360 }
        if value.contains("gopro") { return .embeddedGPMF }
        return .embeddedCamera
    }

    private static func dateInFilename(_ name: String) -> Date? {
        let regex = try? NSRegularExpression(pattern: #"(20\d{2})[-_]?([01]\d)[-_]?([0-3]\d)[ T_-]?([0-2]\d)[-_:]?([0-5]\d)[-_:]?([0-5]\d)"#)
        guard let match = regex?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)), match.numberOfRanges == 7 else { return nil }
        let parts = (1..<7).compactMap { index -> Int? in
            guard let range = Range(match.range(at: index), in: name) else { return nil }
            return Int(name[range])
        }
        guard parts.count == 6 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
        components.hour = parts[3]; components.minute = parts[4]; components.second = parts[5]
        return components.date
    }
}

/// Reads location stored by iPhone and many Android camera applications in
/// the QuickTime/MP4 metadata atom. Phone camera files usually contain one
/// capture location rather than a moving GPS track, so it is intentionally
/// exposed as coordinates/altitude and never promoted to a route or speed.
struct QuickTimeVideoTelemetryExtractor: Sendable {
    func source(for asset: MediaAsset) async -> TelemetrySource? {
        let avAsset = AVURLAsset(url: asset.originalURL)
        guard let location = await locationString(in: avAsset) else { return nil }
        let loadedDuration = try? await avAsset.load(.duration)
        let duration = loadedDuration.map { $0.seconds.isFinite ? $0.seconds : (asset.metadata.duration ?? 0) }
            ?? (asset.metadata.duration ?? 0)
        guard let summary = Self.summary(iso6709: location, duration: duration) else { return nil }
        return TelemetrySource(
            originalURL: asset.originalURL,
            bookmarkData: asset.bookmarkData,
            displayName: "\(asset.displayName) · смартфон",
            format: .embeddedQuickTime,
            linkedAssetID: asset.id,
            startDate: asset.metadata.creationDate,
            summary: summary,
            synchronization: TelemetrySynchronization(
                offsetSeconds: 0,
                method: .embeddedTimecode,
                confidence: 1,
                frameRate: asset.metadata.frameRate
            )
        )
    }

    static func summary(iso6709: String, duration: Double) -> TelemetrySummary? {
        guard let location = parseISO6709(iso6709) else { return nil }
        let end = max(0.001, duration.isFinite ? duration : 0)
        let samples = [0.0, end].map { timestamp in
            TelemetrySample(
                timestamp: timestamp,
                altitudeMeters: location.altitude,
                coordinate: location.coordinate
            )
        }
        return TelemetryNormalizer.summary(samples: samples, format: .embeddedQuickTime)
    }

    static func parseISO6709(_ rawValue: String) -> (coordinate: TelemetryCoordinate, altitude: Double?)? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = try? NSRegularExpression(
            pattern: #"^([+-]\d{2}(?:\.\d+)?)([+-]\d{3}(?:\.\d+)?)([+-]\d+(?:\.\d+)?)?/?$"#
        )
        guard let match = expression?.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let latitudeRange = Range(match.range(at: 1), in: value),
              let longitudeRange = Range(match.range(at: 2), in: value),
              let latitude = Double(value[latitudeRange]),
              let longitude = Double(value[longitudeRange]),
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        let altitude: Double? = {
            guard match.range(at: 3).location != NSNotFound,
                  let range = Range(match.range(at: 3), in: value) else { return nil }
            return Double(value[range])
        }()
        return (TelemetryCoordinate(latitude: latitude, longitude: longitude), altitude)
    }

    private func locationString(in asset: AVURLAsset) async -> String? {
        guard let formats = try? await asset.load(.availableMetadataFormats) else { return nil }
        for format in formats {
            guard let items = try? await asset.loadMetadata(for: format) else { continue }
            for item in items {
                let identifier = item.identifier?.rawValue.lowercased() ?? ""
                guard identifier.contains("location.iso6709") else { continue }
                if let value = try? await item.load(.stringValue), Self.parseISO6709(value) != nil {
                    return value
                }
            }
        }
        return nil
    }
}

private struct ParsedTelemetry {
    var format: TelemetrySourceFormat
    var startDate: Date?
    var samples: [TelemetrySample]

    init(format: TelemetrySourceFormat, startDate: Date? = nil, samples: [TelemetrySample]) {
        self.format = format
        self.startDate = startDate
        self.samples = samples
    }

    init(activity: OVRLEYActivity, fallbackFormat: TelemetrySourceFormat) throws {
        format = fallbackFormat
        startDate = activity.syncTime.flatMap(TelemetryDate.parse)
        let count = activity.elapsed.count
        guard count > 0 else { throw TelemetryEngineError.empty(URL(fileURLWithPath: activity.fileName ?? "OVRLEY")) }
        samples = (0..<count).map { index in
            let coordinate: TelemetryCoordinate? = {
                guard let pair = activity.course[safe: index], pair.count >= 2,
                      let latitude = pair[0], let longitude = pair[1] else { return nil }
                return TelemetryCoordinate(latitude: latitude, longitude: longitude)
            }()
            let customFields = Dictionary(uniqueKeysWithValues: activity.customSeries.compactMap { name, series -> (String, Double)? in
                guard let value = series[safe: index] ?? nil else { return nil }
                return (name, value)
            })
            return TelemetrySample(
                timestamp: activity.elapsed[index],
                speedMetersPerSecond: activity.speed[safe: index] ?? nil,
                altitudeMeters: activity.elevation[safe: index] ?? nil,
                gForce: activity.gForce[safe: index] ?? nil,
                coordinate: coordinate,
                distanceMeters: activity.distance[safe: index] ?? nil,
                gForceX: activity.gForceX[safe: index] ?? nil,
                gForceY: activity.gForceY[safe: index] ?? nil,
                gForceZ: activity.gForceZ[safe: index] ?? nil,
                headingDegrees: activity.heading[safe: index] ?? nil,
                heartRateBPM: activity.heartRate[safe: index] ?? nil,
                cadenceRPM: activity.cadence[safe: index] ?? nil,
                powerWatts: activity.power[safe: index] ?? activity.enginePower[safe: index] ?? nil,
                leanAngleDegrees: activity.leanAngle[safe: index] ?? nil,
                rpm: activity.rpm[safe: index] ?? nil,
                throttlePercent: activity.throttle[safe: index] ?? nil,
                brakePercent: activity.brake[safe: index] ?? nil,
                lapNumber: activity.lapNumber[safe: index].map(Double.init),
                lapTimeSeconds: activity.lapTime[safe: index] ?? nil,
                temperatureCelsius: activity.temperature[safe: index] ?? nil,
                gradientPercent: activity.gradient[safe: index] ?? nil,
                verticalSpeedMetersPerSecond: activity.verticalSpeed[safe: index] ?? nil,
                torqueNewtonMeters: activity.torque[safe: index] ?? nil,
                gear: activity.gearPosition[safe: index].flatMap { $0 }.flatMap(Double.init),
                airPressureHPA: activity.airPressure[safe: index] ?? nil,
                strideLengthMeters: activity.strideLength[safe: index] ?? nil,
                verticalOscillationCentimeters: activity.verticalOscillation[safe: index] ?? nil,
                groundContactTimeMilliseconds: activity.groundContactTime[safe: index] ?? nil,
                leftRightBalancePercent: activity.leftRightBalance[safe: index] ?? nil,
                strokeRate: activity.strokeRate[safe: index] ?? nil,
                cameraISO: activity.iso[safe: index] ?? nil,
                cameraAperture: activity.aperture[safe: index] ?? nil,
                cameraShutterSeconds: activity.shutterSpeed[safe: index] ?? nil,
                cameraFocalLengthMM: activity.focalLength[safe: index] ?? nil,
                cameraEV: activity.ev[safe: index] ?? nil,
                cameraColorTemperatureKelvin: activity.colorTemperature[safe: index] ?? nil,
                customFields: customFields
            )
        }
    }
}

private enum TelemetryNormalizer {
    static func summary(samples input: [TelemetrySample], format: TelemetrySourceFormat) -> TelemetrySummary {
        let ordered = input.filter { $0.timestamp.isFinite }.sorted { $0.timestamp < $1.timestamp }
        guard !ordered.isEmpty else { return TelemetrySummary(sourceFormat: format.rawValue) }
        var output: [TelemetrySample] = []
        output.reserveCapacity(ordered.count)
        var cumulativeDistance = 0.0
        var previous: TelemetrySample?
        for var sample in ordered {
            if let previous {
                let dt = max(0.001, sample.timestamp - previous.timestamp)
                if sample.distanceMeters == nil, let a = previous.coordinate, let b = sample.coordinate {
                    cumulativeDistance += haversine(a, b)
                    sample.distanceMeters = cumulativeDistance
                } else if let distance = sample.distanceMeters {
                    cumulativeDistance = max(cumulativeDistance, distance)
                }
                if sample.speedMetersPerSecond == nil, let distance = sample.distanceMeters, let old = previous.distanceMeters {
                    sample.speedMetersPerSecond = max(0, (distance - old) / dt)
                }
                if sample.accelerationMetersPerSecondSquared == nil, let speed = sample.speedMetersPerSecond, let oldSpeed = previous.speedMetersPerSecond {
                    sample.accelerationMetersPerSecondSquared = (speed - oldSpeed) / dt
                }
                if sample.headingDegrees == nil, let a = previous.coordinate, let b = sample.coordinate {
                    sample.headingDegrees = bearing(a, b)
                }
                if sample.verticalSpeedMetersPerSecond == nil, let altitude = sample.altitudeMeters, let oldAltitude = previous.altitudeMeters {
                    sample.verticalSpeedMetersPerSecond = (altitude - oldAltitude) / dt
                }
                if sample.gradientPercent == nil, let altitude = sample.altitudeMeters, let oldAltitude = previous.altitudeMeters,
                   let distance = sample.distanceMeters, let oldDistance = previous.distanceMeters, distance > oldDistance {
                    sample.gradientPercent = (altitude - oldAltitude) / (distance - oldDistance) * 100
                }
            } else if sample.distanceMeters == nil {
                sample.distanceMeters = 0
            }
            output.append(sample)
            previous = sample
        }
        var streams = Set<String>()
        func mark(_ name: String, _ present: (TelemetrySample) -> Bool) { if output.contains(where: present) { streams.insert(name) } }
        mark("GPS") { $0.coordinate != nil }; mark("SPEED") { $0.speedMetersPerSecond != nil }
        mark("ALTITUDE") { $0.altitudeMeters != nil }; mark("G-FORCE") { $0.gForce != nil || $0.gForceX != nil }
        mark("HEART_RATE") { $0.heartRateBPM != nil }; mark("CADENCE") { $0.cadenceRPM != nil }
        mark("POWER") { $0.powerWatts != nil }; mark("RPM") { $0.rpm != nil }
        mark("CAMERA") { $0.cameraISO != nil || $0.cameraAperture != nil || $0.cameraShutterSeconds != nil }
        mark("CUSTOM") { $0.customFields?.isEmpty == false }
        let speed = output.compactMap(\.speedMetersPerSecond)
        let altitude = output.compactMap(\.altitudeMeters)
        let g = output.compactMap { $0.gForce ?? [$0.gForceX, $0.gForceY, $0.gForceZ].compactMap { $0 }.map(abs).max() }
        return TelemetrySummary(
            hasGPMF: format == .embeddedGPMF,
            sampleCount: output.count,
            maxSpeedMetersPerSecond: speed.max(),
            distanceMeters: output.compactMap(\.distanceMeters).max(),
            minAltitudeMeters: altitude.min(),
            maxAltitudeMeters: altitude.max(),
            maxGForce: g.max(),
            route: output.compactMap(\.coordinate),
            speedSamplesMetersPerSecond: speed,
            altitudeSamplesMeters: altitude,
            timedSamples: output,
            streams: streams,
            sourceFormat: format.rawValue
        )
    }

    private static func haversine(_ a: TelemetryCoordinate, _ b: TelemetryCoordinate) -> Double {
        let radius = 6_371_000.0
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = (b.latitude - a.latitude) * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        let value = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return radius * 2 * atan2(sqrt(value), sqrt(max(0, 1 - value)))
    }

    private static func bearing(_ a: TelemetryCoordinate, _ b: TelemetryCoordinate) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        let value = atan2(sin(dl) * cos(p2), cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)) * 180 / .pi
        return (value + 360).truncatingRemainder(dividingBy: 360)
    }
}

private enum TelemetryDate {
    static func parse(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = iso.date(from: text) { return value }
        iso.formatOptions = [.withInternetDateTime]
        if let value = iso.date(from: text) { return value }
        for format in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy:MM:dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let value = formatter.date(from: text) { return value }
        }
        return nil
    }
}

private enum GPXTelemetryParser {
    static func parse(url: URL) throws -> ParsedTelemetry {
        let delegate = GPXDelegate()
        let parser = XMLParser(contentsOf: url)
        parser?.delegate = delegate
        guard parser?.parse() == true else {
            throw TelemetryEngineError.malformed(url, parser?.parserError?.localizedDescription ?? "некорректный XML")
        }
        guard !delegate.points.isEmpty else { throw TelemetryEngineError.empty(url) }
        let dated = delegate.points.compactMap(\.date)
        let start = dated.first
        let samples = delegate.points.enumerated().map { index, point in
            let timestamp = point.date.flatMap { pointDate in start.map { $0.distance(to: pointDate) } } ?? Double(index)
            return TelemetrySample(
                timestamp: max(0, timestamp), speedMetersPerSecond: point.speed,
                altitudeMeters: point.elevation, coordinate: TelemetryCoordinate(latitude: point.latitude, longitude: point.longitude),
                heartRateBPM: point.heartRate, cadenceRPM: point.cadence, powerWatts: point.power,
                temperatureCelsius: point.temperature, customFields: point.customFields
            )
        }
        return ParsedTelemetry(format: .gpx, startDate: start, samples: samples)
    }

    private final class GPXDelegate: NSObject, XMLParserDelegate {
        struct Point { var latitude: Double; var longitude: Double; var elevation: Double?; var date: Date?; var speed: Double?; var heartRate: Double?; var cadence: Double?; var power: Double?; var temperature: Double?; var customFields: [String: Double] = [:] }
        var points: [Point] = []
        private var current: Point?
        private var element = ""
        private var text = ""
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            element = elementName.lowercased(); text = ""
            if element.hasSuffix("trkpt"), let lat = attributeDict["lat"].flatMap(Double.init), let lon = attributeDict["lon"].flatMap(Double.init) {
                current = Point(latitude: lat, longitude: lon)
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard var point = current else { return }
            let name = elementName.lowercased(), value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasSuffix("ele") { point.elevation = Double(value) }
            else if name.hasSuffix("time") { point.date = TelemetryDate.parse(value) }
            else if name.hasSuffix("speed") { point.speed = Double(value) }
            else if name.hasSuffix("hr") || name.hasSuffix("heartrate") { point.heartRate = Double(value) }
            else if name.hasSuffix("cad") || name.hasSuffix("cadence") { point.cadence = Double(value) }
            else if name.hasSuffix("power") || name.hasSuffix("watts") { point.power = Double(value) }
            else if name.hasSuffix("atemp") || name.hasSuffix("temp") { point.temperature = Double(value) }
            else if let number = Double(value), !name.hasSuffix("trkpt") {
                point.customFields[name.replacingOccurrences(of: ":", with: "_")] = number
            }
            current = point
            if name.hasSuffix("trkpt") { points.append(point); current = nil }
        }
    }
}

private enum CSVTelemetryParser {
    static func parse(url: URL) throws -> ParsedTelemetry {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let headerLine = lines.first else { throw TelemetryEngineError.empty(url) }
        let delimiter: Character = headerLine.filter { $0 == ";" }.count > headerLine.filter { $0 == "," }.count ? ";" : ","
        let headers = fields(headerLine, delimiter: delimiter).map(normalize)
        func index(_ names: [String]) -> Int? { headers.firstIndex { header in names.contains(where: { header.contains($0) }) } }
        let timeIndex = index(["elapsed", "timestamp", "time", "seconds"])
        let latIndex = index(["latitude", "lat"]), lonIndex = index(["longitude", "lon", "lng"])
        let speedIndex = index(["speed", "velocity"]), altitudeIndex = index(["elevation", "altitude", "alt"])
        let distanceIndex = index(["distance"]), heartIndex = index(["heartrate", "heart_rate", "hr"])
        let cadenceIndex = index(["cadence"]), powerIndex = index(["power", "watts"])
        let rpmIndex = index(["rpm"]), throttleIndex = index(["throttle"]), brakeIndex = index(["brake"])
        let recognized = Set([
            timeIndex, latIndex, lonIndex, speedIndex, altitudeIndex, distanceIndex,
            heartIndex, cadenceIndex, powerIndex, rpmIndex, throttleIndex, brakeIndex
        ].compactMap { $0 })
        var absoluteStart: Date?
        var samples: [TelemetrySample] = []
        for (row, line) in lines.dropFirst().enumerated() {
            let values = fields(line, delimiter: delimiter)
            func number(_ index: Int?) -> Double? { index.flatMap { values[safe: $0] }.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) } }
            var time = timeIndex.flatMap { values[safe: $0] }
            var timestamp = time.flatMap(Double.init)
            if timestamp == nil, let dateText = time, let date = TelemetryDate.parse(dateText) {
                if absoluteStart == nil { absoluteStart = date }
                timestamp = absoluteStart?.distance(to: date)
            }
            let coordinate = coordinate(latitude: number(latIndex), longitude: number(lonIndex))
            let customPairs = headers.indices.compactMap { column -> (String, Double)? in
                guard !recognized.contains(column), let value = number(column) else { return nil }
                return (headers[column], value)
            }
            let customFields = Dictionary(customPairs, uniquingKeysWith: { _, newest in newest })
            samples.append(TelemetrySample(
                timestamp: timestamp ?? Double(row), speedMetersPerSecond: number(speedIndex), altitudeMeters: number(altitudeIndex),
                coordinate: coordinate, distanceMeters: number(distanceIndex), heartRateBPM: number(heartIndex), cadenceRPM: number(cadenceIndex),
                powerWatts: number(powerIndex), rpm: number(rpmIndex), throttlePercent: number(throttleIndex), brakePercent: number(brakeIndex),
                customFields: customFields
            ))
            time = nil
        }
        return ParsedTelemetry(format: .csv, startDate: absoluteStart, samples: samples)
    }

    private static func normalize(_ text: String) -> String { text.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_") }
    private static func fields(_ line: String, delimiter: Character) -> [String] {
        var result: [String] = [], current = "", quoted = false
        for character in line {
            if character == "\"" { quoted.toggle() }
            else if character == delimiter && !quoted { result.append(current.trimmingCharacters(in: .whitespacesAndNewlines)); current = "" }
            else { current.append(character) }
        }
        result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return result
    }
}

private enum SRTTelemetryParser {
    static func parse(url: URL) throws -> ParsedTelemetry {
        let text = try String(contentsOf: url, encoding: .utf8)
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        let timestampRegex = try NSRegularExpression(pattern: #"(\d{2}):(\d{2}):(\d{2})[,\.](\d{3})\s*-->"#)
        let pairs: [(String, String)] = [
            ("latitude", #"(?i)(?:latitude|lat)\s*[:=]?\s*(-?\d+(?:\.\d+)?)"#),
            ("longitude", #"(?i)(?:longitude|lon|lng)\s*[:=]?\s*(-?\d+(?:\.\d+)?)"#),
            ("altitude", #"(?i)(?:altitude|alt|height)\s*[:=]?\s*(-?\d+(?:\.\d+)?)"#),
            ("speed", #"(?i)(?:speed|velocity)\s*[:=]?\s*(-?\d+(?:\.\d+)?)"#),
            ("iso", #"(?i)iso\s*[:=]?\s*(\d+(?:\.\d+)?)"#),
            ("shutter", #"(?i)(?:shutter|shutter_speed)\s*[:=]?\s*(?:1/)?(\d+(?:\.\d+)?)"#),
            ("fnum", #"(?i)(?:fnum|aperture|f/)\s*[:=]?\s*(\d+(?:\.\d+)?)"#),
            ("ev", #"(?i)ev\s*[:=]?\s*(-?\d+(?:\.\d+)?)"#)
        ]
        let regexes = Dictionary(uniqueKeysWithValues: try pairs.map { pair in (pair.0, try NSRegularExpression(pattern: pair.1)) })
        let customPairRegex = try NSRegularExpression(pattern: #"(?im)([A-Za-z][A-Za-z0-9 _-]{1,40})\s*[:=]\s*(-?\d+(?:\.\d+)?)"#)
        let standardNames = Set(["latitude", "lat", "longitude", "lon", "lng", "altitude", "alt", "height", "speed", "velocity", "iso", "shutter", "shutter_speed", "fnum", "aperture", "ev"])
        var samples: [TelemetrySample] = []
        var startDate: Date?
        for block in blocks {
            guard let match = timestampRegex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)) else { continue }
            let values = (1...4).compactMap { index -> Double? in
                guard let range = Range(match.range(at: index), in: block) else { return nil }
                return Double(block[range])
            }
            guard values.count == 4 else { continue }
            let timestamp = values[0] * 3600 + values[1] * 60 + values[2] + values[3] / 1000
            func number(_ name: String) -> Double? {
                guard let regex = regexes[name], let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
                      let range = Range(match.range(at: 1), in: block) else { return nil }
                return Double(block[range])
            }
            if startDate == nil {
                let dateRegex = try? NSRegularExpression(pattern: #"20\d{2}[-\.]\d{2}[-\.]\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?"#)
                if let match = dateRegex?.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)), let range = Range(match.range, in: block) {
                    var dateText = String(block[range])
                    if dateText.count >= 10 {
                        let split = dateText.index(dateText.startIndex, offsetBy: 10)
                        dateText = dateText[..<split].replacingOccurrences(of: ".", with: "-") + dateText[split...]
                    }
                    startDate = TelemetryDate.parse(dateText)
                }
            }
            let coordinate = coordinate(latitude: number("latitude"), longitude: number("longitude"))
            let rawSpeed = number("speed")
            let speed = block.lowercased().contains("km/h") || block.lowercased().contains("kmh") ? rawSpeed.map { $0 / 3.6 } : rawSpeed
            let shutterRaw = number("shutter")
            let shutter = block.lowercased().contains("1/") ? shutterRaw.flatMap { $0 == 0 ? nil : 1 / $0 } : shutterRaw
            let customPairs = customPairRegex.matches(in: block, range: NSRange(block.startIndex..., in: block)).compactMap { match -> (String, Double)? in
                guard let nameRange = Range(match.range(at: 1), in: block),
                      let valueRange = Range(match.range(at: 2), in: block),
                      let value = Double(block[valueRange]) else { return nil }
                let name = block[nameRange].lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: " ", with: "_")
                    .replacingOccurrences(of: "-", with: "_")
                guard !standardNames.contains(name) else { return nil }
                return (name, value)
            }
            let customFields = Dictionary(customPairs, uniquingKeysWith: { _, newest in newest })
            samples.append(TelemetrySample(timestamp: timestamp, speedMetersPerSecond: speed, altitudeMeters: number("altitude"), coordinate: coordinate,
                                             cameraISO: number("iso"), cameraAperture: number("fnum"), cameraShutterSeconds: shutter, cameraEV: number("ev"),
                                             customFields: customFields))
        }
        guard !samples.isEmpty else { throw TelemetryEngineError.empty(url) }
        let zero = samples.first?.timestamp ?? 0
        for index in samples.indices { samples[index].timestamp -= zero }
        return ParsedTelemetry(format: .srt, startDate: startDate, samples: samples)
    }
}

/// FIT decoder for the standard File ID/Record stream. It follows FIT's local
/// message definitions, endian flag and scale/offset rules instead of assuming
/// a fixed byte layout, so files from Garmin/Wahoo/Coros remain interoperable.
private enum FITTelemetryParser {
    private struct Field { var number: UInt8; var size: Int; var baseType: UInt8 }
    private struct Definition { var global: UInt16; var bigEndian: Bool; var fields: [Field] }

    static func parse(url: URL) throws -> ParsedTelemetry {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 14 else { throw TelemetryEngineError.malformed(url, "слишком короткий FIT-файл") }
        let headerSize = Int(data[0]), bodySize = Int(readUInt32(data, at: 4, bigEndian: false))
        guard headerSize >= 12, headerSize + bodySize <= data.count, String(decoding: data[8..<12], as: UTF8.self) == ".FIT" else {
            throw TelemetryEngineError.malformed(url, "неверный FIT-заголовок")
        }
        var definitions: [UInt8: Definition] = [:], offset = headerSize, samples: [TelemetrySample] = []
        var startDate: Date?, lastTimestamp: Date?
        let end = headerSize + bodySize
        while offset < end {
            let recordHeader = data[offset]; offset += 1
            let compressed = recordHeader & 0x80 != 0
            let local = compressed ? (recordHeader >> 5) & 0x03 : recordHeader & 0x0F
            if !compressed && recordHeader & 0x40 != 0 {
                guard offset + 5 <= end else { break }
                offset += 1
                let architecture = data[offset]; offset += 1
                let big = architecture == 1
                let global = readUInt16(data, at: offset, bigEndian: big); offset += 2
                let count = Int(data[offset]); offset += 1
                guard offset + count * 3 <= end else { break }
                var fields: [Field] = []
                for _ in 0..<count { fields.append(Field(number: data[offset], size: Int(data[offset + 1]), baseType: data[offset + 2])); offset += 3 }
                if recordHeader & 0x20 != 0, offset < end {
                    let developerCount = Int(data[offset]); offset += 1
                    offset = min(end, offset + developerCount * 3)
                }
                definitions[local] = Definition(global: global, bigEndian: big, fields: fields)
                continue
            }
            guard let definition = definitions[local] else { break }
            var values: [UInt8: Double] = [:]
            for field in definition.fields {
                guard offset + field.size <= end else { offset = end; break }
                if let value = numeric(data, at: offset, field: field, bigEndian: definition.bigEndian) { values[field.number] = value }
                offset += field.size
            }
            guard definition.global == 20 else { continue }
            let fitTimestamp = values[253].map { Date(timeIntervalSince1970: $0 + 631_065_600) }
            if startDate == nil { startDate = fitTimestamp }
            if let fitTimestamp { lastTimestamp = fitTimestamp }
            let timestamp = fitTimestamp.flatMap { recordDate in startDate.map { $0.distance(to: recordDate) } } ?? Double(samples.count)
            let lat = values[0].map { $0 * 180 / 2_147_483_648 }, lon = values[1].map { $0 * 180 / 2_147_483_648 }
            let coordinate = coordinate(latitude: lat, longitude: lon)
            let standardFields: Set<UInt8> = [253, 0, 1, 73, 6, 78, 2, 5, 3, 4, 7, 13, 32]
            let customFields = Dictionary(uniqueKeysWithValues: values.compactMap { field, value -> (String, Double)? in
                guard !standardFields.contains(field) else { return nil }
                return ("fit_record_\(field)", value)
            })
            samples.append(TelemetrySample(
                timestamp: timestamp,
                speedMetersPerSecond: values[73].map { $0 / 1000 } ?? values[6].map { $0 / 1000 },
                altitudeMeters: values[78].map { $0 / 5 - 500 } ?? values[2].map { $0 / 5 - 500 },
                coordinate: coordinate, distanceMeters: values[5].map { $0 / 100 },
                heartRateBPM: values[3], cadenceRPM: values[4], powerWatts: values[7],
                temperatureCelsius: values[13], verticalSpeedMetersPerSecond: values[32].map { $0 / 1000 },
                customFields: customFields
            ))
        }
        _ = lastTimestamp
        guard !samples.isEmpty else { throw TelemetryEngineError.empty(url) }
        return ParsedTelemetry(format: .fit, startDate: startDate, samples: samples)
    }

    private static func numeric(_ data: Data, at offset: Int, field: Field, bigEndian: Bool) -> Double? {
        let type = field.baseType & 0x1F
        switch type {
        case 0, 2, 10, 13: let value = data[offset]; return value == 0xFF ? nil : Double(value)
        case 1: let value = Int8(bitPattern: data[offset]); return value == 0x7F ? nil : Double(value)
        case 3: let raw = readUInt16(data, at: offset, bigEndian: bigEndian); let value = Int16(bitPattern: raw); return value == 0x7FFF ? nil : Double(value)
        case 4, 11: let value = readUInt16(data, at: offset, bigEndian: bigEndian); return value == 0xFFFF ? nil : Double(value)
        case 5: let raw = readUInt32(data, at: offset, bigEndian: bigEndian); let value = Int32(bitPattern: raw); return value == 0x7FFF_FFFF ? nil : Double(value)
        case 6, 12: let value = readUInt32(data, at: offset, bigEndian: bigEndian); return value == 0xFFFF_FFFF ? nil : Double(value)
        default: return nil
        }
    }

    private static func readUInt16(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt16 {
        let a = UInt16(data[offset]), b = UInt16(data[offset + 1]); return bigEndian ? (a << 8 | b) : (a | b << 8)
    }
    private static func readUInt32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32 {
        let bytes = (0..<4).map { UInt32(data[offset + $0]) }
        return bigEndian ? (bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]) : (bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

private func coordinate(latitude: Double?, longitude: Double?) -> TelemetryCoordinate? {
    guard let latitude, let longitude else { return nil }
    return TelemetryCoordinate(latitude: latitude, longitude: longitude)
}
