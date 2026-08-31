import Foundation
import Darwin

public enum OVRLEYBridgeError: LocalizedError {
    case unavailable
    case processFailed(String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Локальный движок OVRLEY не найден. Пересоберите полный VeloEdit.app."
        case .processFailed(let message):
            return "OVRLEY не смог обработать телеметрию: \(message)"
        case .malformedResponse(let message):
            return "OVRLEY вернул некорректные данные: \(message)"
        }
    }
}

/// Local-only process bridge to the actual vendored OVRLEY Rust core.
public struct OVRLEYBridge: Sendable {
    public init() {}

    public var isAvailable: Bool { Self.executableURL != nil }

    public func health() async throws -> String {
        let data = try await run(arguments: ["health"])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true else {
            throw OVRLEYBridgeError.malformedResponse(String(decoding: data, as: UTF8.self))
        }
        return "OVRLEY Rust core · GPL-3.0-or-later · local"
    }

    public func parse(url: URL) async throws -> OVRLEYActivity {
        var arguments = ["parse", "--input", url.path]
        if let root = Self.resourceRootURL { arguments += ["--resource-root", root.path] }
        let data = try await run(arguments: arguments)
        do {
            let response = try JSONDecoder().decode(OVRLEYEnvelope<OVRLEYFinalizeResponse>.self, from: data)
            guard response.ok, let activity = response.result?.parsedActivity else {
                throw OVRLEYBridgeError.processFailed(response.error ?? "неизвестная ошибка")
            }
            return activity
        } catch let error as OVRLEYBridgeError {
            throw error
        } catch {
            throw OVRLEYBridgeError.malformedResponse(error.localizedDescription)
        }
    }

    /// Uses OVRLEY's original Skia renderer for the exact same transparent
    /// frame consumed by Viewer, Timeline thumbnails and export compositors.
    func renderFrame(payload: Data, config: Data, second: Double) throws -> Data {
        guard let executable = Self.executableURL else { throw OVRLEYBridgeError.unavailable }
        var hasher = Hasher()
        hasher.combine(payload)
        hasher.combine(config)
        let sessionID = String(hasher.finalize())
        if let rendered = try? OVRLEYRenderServer.shared.render(
            executable: executable,
            resourceRoot: Self.resourceRootURL,
            sessionID: sessionID,
            payload: payload,
            config: config,
            second: second
        ) {
            return rendered
        }
        // One-shot fallback preserves rendering if the long-lived helper was
        // interrupted by App Nap, signing or a development rebuild.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("veloedit-ovrley-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payloadURL = directory.appendingPathComponent("activity.json")
        let configURL = directory.appendingPathComponent("config.json")
        let outputURL = directory.appendingPathComponent("frame.png")
        try payload.write(to: payloadURL, options: .atomic)
        try config.write(to: configURL, options: .atomic)
        var arguments = [
            "render-frame",
            "--payload", payloadURL.path,
            "--config", configURL.path,
            "--out", outputURL.path,
            "--second", String(format: "%.6f", max(0, second))
        ]
        if let root = Self.resourceRootURL { arguments += ["--resource-root", root.path] }
        _ = try Self.runSynchronously(arguments: arguments)
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw OVRLEYBridgeError.malformedResponse("OVRLEY не создал PNG кадра")
        }
        return try Data(contentsOf: outputURL)
    }

    private func run(arguments: [String]) async throws -> Data {
        guard let executable = Self.executableURL else { throw OVRLEYBridgeError.unavailable }
        return try await Task.detached(priority: .userInitiated) {
            // File Provider can attach com.apple.provenance to the nested
            // executable after the signed app is copied into Documents. macOS
            // may then SIGKILL that ad-hoc signed helper before main(). The
            // helper is part of our already verified bundle, so remove only
            // this asynchronous package marker immediately before launch.
            Self.removeFileProviderProvenance(from: executable)
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                if let response = try? JSONDecoder().decode(OVRLEYEnvelope<EmptyResult>.self, from: data),
                   let message = response.error {
                    throw OVRLEYBridgeError.processFailed(message)
                }
                let message = String(decoding: errorData.isEmpty ? data : errorData, as: UTF8.self)
                throw OVRLEYBridgeError.processFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return data
        }.value
    }

    private static func runSynchronously(arguments: [String]) throws -> Data {
        guard let executable = executableURL else { throw OVRLEYBridgeError.unavailable }
        removeFileProviderProvenance(from: executable)
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            if let response = try? JSONDecoder().decode(OVRLEYEnvelope<EmptyResult>.self, from: data),
               let message = response.error {
                throw OVRLEYBridgeError.processFailed(message)
            }
            let message = String(decoding: errorData.isEmpty ? data : errorData, as: UTF8.self)
            throw OVRLEYBridgeError.processFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    fileprivate static func removeFileProviderProvenance(from url: URL) {
        url.path.withCString { path in
            "com.apple.provenance".withCString { name in
                _ = removexattr(path, name, 0)
            }
        }
    }

    fileprivate static var executableURL: URL? {
        if let override = ProcessInfo.processInfo.environment["VELOEDIT_OVRLEY_BRIDGE"] {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        if let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("VeloEditOVRLEY"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let externalBuildCache = ProcessInfo.processInfo.environment["VELOEDIT_BUILD_CACHE_ROOT"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("VeloEditBuild", isDirectory: true)
        if let external = externalBuildCache?
            .appendingPathComponent("ovrley-rust/release/veloedit_ovrley_bridge"),
           FileManager.default.isExecutableFile(atPath: external.path) {
            return external
        }
        let legacyDevelopment = repositoryRoot
            .appendingPathComponent(".build/ovrley-rust/release/veloedit_ovrley_bridge")
        return FileManager.default.isExecutableFile(atPath: legacyDevelopment.path) ? legacyDevelopment : nil
    }

    static var resourceRootURL: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("OVRLEY-Source"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let development = repositoryRoot.appendingPathComponent("ThirdParty/OVRLEY")
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class OVRLEYRenderServer: @unchecked Sendable {
    static let shared = OVRLEYRenderServer()

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var knownSessions = Set<String>()

    func render(
        executable: URL,
        resourceRoot: URL?,
        sessionID: String,
        payload: Data,
        config: Data,
        second: Double
    ) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        try ensureRunning(executable: executable, resourceRoot: resourceRoot)
        do {
            return try renderLocked(sessionID: sessionID, payload: payload, config: config, second: second)
        } catch {
            // The Rust cache is bounded and can evict an old session. Resend
            // its immutable preparation payload once before giving up.
            knownSessions.remove(sessionID)
            return try renderLocked(sessionID: sessionID, payload: payload, config: config, second: second)
        }
    }

    private func ensureRunning(executable: URL, resourceRoot: URL?) throws {
        if process?.isRunning == true, input != nil, output != nil { return }
        stopLocked()
        OVRLEYBridge.removeFileProviderProvenance(from: executable)
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["render-server"] + (resourceRoot.map { ["--resource-root", $0.path] } ?? [])
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        knownSessions.removeAll()
    }

    private func renderLocked(sessionID: String, payload: Data, config: Data, second: Double) throws -> Data {
        guard let input, let output else { throw OVRLEYBridgeError.unavailable }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("veloedit-ovrley-server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("frame.png")
        var request: [String: Any] = [
            "session_id": sessionID,
            "out_path": outputURL.path,
            "second": max(0, second)
        ]
        if !knownSessions.contains(sessionID) {
            let payloadURL = directory.appendingPathComponent("activity.json")
            let configURL = directory.appendingPathComponent("config.json")
            try payload.write(to: payloadURL, options: .atomic)
            try config.write(to: configURL, options: .atomic)
            request["payload_path"] = payloadURL.path
            request["config_path"] = configURL.path
        }
        var line = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        line.append(0x0A)
        try input.write(contentsOf: line)
        let responseData = try readLine(from: output)
        guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              response["ok"] as? Bool == true else {
            let response = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
            throw OVRLEYBridgeError.processFailed(response?["error"] as? String ?? String(decoding: responseData, as: UTF8.self))
        }
        knownSessions.insert(sessionID)
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw OVRLEYBridgeError.malformedResponse("OVRLEY render server не создал PNG кадра")
        }
        return try Data(contentsOf: outputURL)
    }

    private func readLine(from handle: FileHandle) throws -> Data {
        var data = Data()
        while true {
            guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
                stopLocked()
                throw OVRLEYBridgeError.processFailed("OVRLEY render server завершился")
            }
            if byte[byte.startIndex] == 0x0A { return data }
            data.append(byte)
            if data.count > 1_048_576 {
                throw OVRLEYBridgeError.malformedResponse("Слишком большой ответ render server")
            }
        }
    }

    private func stopLocked() {
        input?.closeFile()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        knownSessions.removeAll()
    }
}

private struct EmptyResult: Decodable {}

private struct OVRLEYEnvelope<Result: Decodable>: Decodable {
    var ok: Bool
    var result: Result?
    var error: String?
}

private struct OVRLEYFinalizeResponse: Decodable {
    var parsedActivity: OVRLEYActivity

    enum CodingKeys: String, CodingKey, CaseIterable {
        case parsedActivity = "parsed_activity"
    }
}

public struct OVRLEYActivity: Decodable, Sendable {
    public var fileName: String?
    public var fileFormat: String?
    public var metadata: OVRLEYActivityMetadata?
    public var syncTime: String?
    public var elapsed: [Double]
    public var course: [[Double?]]
    public var elevation: [Double?]
    public var speed: [Double?]
    public var distance: [Double?]
    public var heartRate: [Double?]
    public var cadence: [Double?]
    public var power: [Double?]
    public var enginePower: [Double?]
    public var temperature: [Double?]
    public var gForce: [Double?]
    public var gForceX: [Double?]
    public var gForceY: [Double?]
    public var gForceZ: [Double?]
    public var rpm: [Double?]
    public var throttle: [Double?]
    public var brake: [Double?]
    public var leanAngle: [Double?]
    public var airPressure: [Double?]
    public var groundContactTime: [Double?]
    public var leftRightBalance: [Double?]
    public var strideLength: [Double?]
    public var strokeRate: [Double?]
    public var torque: [Double?]
    public var verticalSpeed: [Double?]
    public var iso: [Double?]
    public var aperture: [Double?]
    public var shutterSpeed: [Double?]
    public var focalLength: [Double?]
    public var ev: [Double?]
    public var colorTemperature: [Double?]
    public var verticalOscillation: [Double?]
    public var gradient: [Double?]
    public var heading: [Double?]
    public var lapNumber: [Int]
    public var lapTime: [Double?]
    public var gearPosition: [String?]
    public var customSeries: [String: [Double?]]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case fileName = "file_name", fileFormat = "file_format", metadata, syncTime = "sync_time"
        case elapsed = "sample_elapsed_seconds", course, elevation, speed, distance
        case heartRate = "heartrate", cadence, power, enginePower = "engine_power", temperature
        case gForce = "g_force", gForceX = "g_force_x", gForceY = "g_force_y", gForceZ = "g_force_z"
        case rpm, throttle = "throttle_position", brake = "brake_position", leanAngle = "lean_angle"
        case airPressure = "air_pressure", groundContactTime = "ground_contact_time"
        case leftRightBalance = "left_right_balance", strideLength = "stride_length", strokeRate = "stroke_rate"
        case torque, verticalSpeed = "vertical_speed", iso, aperture, shutterSpeed = "shutter_speed"
        case focalLength = "focal_length", ev, colorTemperature = "color_temperature"
        case verticalOscillation = "vertical_oscillation", gradient, heading
        case lapNumber = "lap_number", lapTime = "lap_time_seconds", gearPosition = "gear_position"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try values.decodeIfPresent(String.self, forKey: .fileName)
        fileFormat = try values.decodeIfPresent(String.self, forKey: .fileFormat)
        metadata = try values.decodeIfPresent(OVRLEYActivityMetadata.self, forKey: .metadata)
        syncTime = try values.decodeIfPresent(String.self, forKey: .syncTime)
        elapsed = try values.decodeIfPresent([Double].self, forKey: .elapsed) ?? []
        course = try values.decodeIfPresent([[Double?]].self, forKey: .course) ?? []
        elevation = Self.series(values, .elevation)
        speed = Self.series(values, .speed)
        distance = Self.series(values, .distance)
        heartRate = Self.series(values, .heartRate)
        cadence = Self.series(values, .cadence)
        power = Self.series(values, .power)
        enginePower = Self.series(values, .enginePower)
        temperature = Self.series(values, .temperature)
        gForce = Self.series(values, .gForce)
        gForceX = Self.series(values, .gForceX)
        gForceY = Self.series(values, .gForceY)
        gForceZ = Self.series(values, .gForceZ)
        rpm = Self.series(values, .rpm)
        throttle = Self.series(values, .throttle)
        brake = Self.series(values, .brake)
        leanAngle = Self.series(values, .leanAngle)
        airPressure = Self.series(values, .airPressure)
        groundContactTime = Self.series(values, .groundContactTime)
        leftRightBalance = Self.series(values, .leftRightBalance)
        strideLength = Self.series(values, .strideLength)
        strokeRate = Self.series(values, .strokeRate)
        torque = Self.series(values, .torque)
        verticalSpeed = Self.series(values, .verticalSpeed)
        iso = Self.series(values, .iso)
        aperture = Self.series(values, .aperture)
        shutterSpeed = Self.series(values, .shutterSpeed)
        focalLength = Self.series(values, .focalLength)
        ev = Self.series(values, .ev)
        colorTemperature = Self.series(values, .colorTemperature)
        verticalOscillation = Self.series(values, .verticalOscillation)
        gradient = Self.series(values, .gradient)
        heading = Self.series(values, .heading)
        lapNumber = try values.decodeIfPresent([Int].self, forKey: .lapNumber) ?? []
        lapTime = Self.series(values, .lapTime)
        gearPosition = try values.decodeIfPresent([String?].self, forKey: .gearPosition) ?? []
        let dynamic = try decoder.container(keyedBy: OVRLEYDynamicCodingKey.self)
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        customSeries = Dictionary(uniqueKeysWithValues: dynamic.allKeys.compactMap { key -> (String, [Double?])? in
            guard !known.contains(key.stringValue),
                  let series = try? dynamic.decode([Double?].self, forKey: key),
                  !series.isEmpty else { return nil }
            return (key.stringValue, series)
        })
    }

    public var embeddedCameraName: String {
        let type = metadata?.cameraType?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = metadata?.cameraModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = [type, model].compactMap { value in
            value.flatMap { $0.isEmpty ? nil : $0 }
        }
        return values.isEmpty ? "камера OVRLEY" : values.joined(separator: " ")
    }

    private static func series(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [Double?] {
        (try? container.decodeIfPresent([Double?].self, forKey: key)) ?? []
    }
}

public struct OVRLEYActivityMetadata: Decodable, Sendable {
    public var cameraType: String?
    public var cameraModel: String?
    public var telemetrySource: String?
    public var gpsSampleCount: Int?
    public var imuSampleCount: Int?
    public var cameraSampleCount: Int?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case cameraType = "camera_type"
        case cameraModel = "camera_model"
        case telemetrySource = "telemetry_source"
        case gpsSampleCount = "gps_sample_count"
        case imuSampleCount = "imu_sample_count"
        case cameraSampleCount = "camera_sample_count"
    }
}

private struct OVRLEYDynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}
