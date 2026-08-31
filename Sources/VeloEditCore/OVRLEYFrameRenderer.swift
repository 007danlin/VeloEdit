import Foundation
import CoreGraphics
import ImageIO

/// Adapter from VeloEdit's normalized timeline objects to OVRLEY's canonical
/// ParsedActivity + template contracts. The Rust core remains the owner of
/// widget geometry, formatting, fonts, gauges, plots and animation state.
enum OVRLEYFrameRenderer {
    private static let cache = OVRLEYFrameCache()

    static func frame(
        settings: TelemetryOverlaySettings,
        telemetry: TelemetrySummary,
        sourceTime: Double,
        renderSize: CGSize
    ) -> CGImage? {
        guard settings.effectiveStyle.isOVRLEYTemplate,
              let payload = activityPayload(telemetry),
              let config = renderTemplate(settings: settings, telemetry: telemetry, renderSize: renderSize) else { return nil }
        let width = Int(max(2, renderSize.width.rounded(.up)))
        let height = Int(max(2, renderSize.height.rounded(.up)))
        var hasher = Hasher()
        hasher.combine(settings)
        hasher.combine(telemetry)
        hasher.combine(Int((sourceTime * 30).rounded()))
        hasher.combine(width)
        hasher.combine(height)
        let key = hasher.finalize()
        if let cached = cache.image(for: key) { return cached }
        guard let png = try? OVRLEYBridge().renderFrame(payload: payload, config: config, second: sourceTime),
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        cache.insert(image, for: key)
        return image
    }

    static func activityPayload(_ telemetry: TelemetrySummary) -> Data? {
        var samples = (telemetry.timedSamples ?? []).sorted { $0.timestamp < $1.timestamp }
        guard !samples.isEmpty else { return nil }
        if samples.count == 1 {
            var duplicate = samples[0]
            duplicate.timestamp += 1.0 / 30.0
            samples.append(duplicate)
        }
        let elapsed = samples.map(\.timestamp)
        let end = max((elapsed.last ?? 0) + 1.0 / 30.0, 0.1)
        func series(_ keyPath: KeyPath<TelemetrySample, Double?>) -> [Any] {
            samples.map { sample -> Any in
                if let value = sample[keyPath: keyPath] { return value }
                return NSNull()
            }
        }
        let course: [Any] = samples.map { sample in
            guard let coordinate = sample.coordinate else { return [NSNull(), NSNull()] }
            return [coordinate.latitude, coordinate.longitude]
        }
        var object: [String: Any] = [
            "file_name": "VeloEdit normalized telemetry",
            "file_format": telemetry.sourceFormat ?? "veloedit",
            "metadata": ["renderer": "OVRLEY", "normalizer": "VeloEdit"],
            "sample_elapsed_seconds": elapsed,
            "trim_start_seconds": 0,
            "trim_end_seconds": end,
            "sample_course_points": course,
            "course": course,
            "sample_elevations": series(\.altitudeMeters),
            "elevation": series(\.altitudeMeters),
            "speed": series(\.speedMetersPerSecond),
            "distance": series(\.distanceMeters),
            "heartrate": series(\.heartRateBPM),
            "cadence": series(\.cadenceRPM),
            "power": series(\.powerWatts),
            "temperature": series(\.temperatureCelsius),
            "g_force": series(\.gForce),
            "g_force_x": series(\.gForceX),
            "g_force_y": series(\.gForceY),
            "g_force_z": series(\.gForceZ),
            "rpm": series(\.rpm),
            "throttle_position": series(\.throttlePercent),
            "brake_position": series(\.brakePercent),
            "lean_angle": series(\.leanAngleDegrees),
            "air_pressure": series(\.airPressureHPA),
            "ground_contact_time": series(\.groundContactTimeMilliseconds),
            "left_right_balance": series(\.leftRightBalancePercent),
            "stride_length": series(\.strideLengthMeters),
            "stroke_rate": series(\.strokeRate),
            "torque": series(\.torqueNewtonMeters),
            "vertical_speed": series(\.verticalSpeedMetersPerSecond),
            "iso": series(\.cameraISO),
            "aperture": series(\.cameraAperture),
            "shutter_speed": series(\.cameraShutterSeconds),
            "focal_length": series(\.cameraFocalLengthMM),
            "ev": series(\.cameraEV),
            "color_temperature": series(\.cameraColorTemperatureKelvin),
            "vertical_oscillation": series(\.verticalOscillationCentimeters),
            "gradient": series(\.gradientPercent),
            "heading": series(\.headingDegrees),
            "calories": series(\.calories),
            "lap_number": samples.map { Int($0.lapNumber ?? -1) },
            "lap_time_seconds": series(\.lapTimeSeconds),
            "gear_position": samples.map { sample -> Any in
                sample.gear.map { String(Int($0.rounded())) as Any } ?? NSNull()
            }
        ]
        let customKeys = Set(samples.flatMap { $0.customFields?.keys.map { $0 } ?? [] })
        for key in customKeys where object[key] == nil {
            object[key] = samples.map { sample -> Any in
                if let value = sample.customFields?[key] { return value }
                return NSNull()
            }
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func renderTemplate(
        settings: TelemetryOverlaySettings,
        telemetry: TelemetrySummary,
        renderSize: CGSize
    ) -> Data? {
        guard let rootURL = OVRLEYBridge.resourceRootURL,
              var wrapper = loadTemplate(style: settings.effectiveStyle, rootURL: rootURL),
              var config = wrapper["config"] as? [String: Any] else { return nil }
        let width = Int(max(2, renderSize.width.rounded(.up)))
        let height = Int(max(2, renderSize.height.rounded(.up)))
        let duration = max((telemetry.timedSamples?.last?.timestamp ?? 0) + 1.0 / 30.0, 0.1)
        var scene = config["scene"] as? [String: Any] ?? [:]
        scene["width"] = width
        scene["height"] = height
        scene["fps"] = 30
        scene["start"] = 0
        scene["end"] = duration
        scene.removeValue(forKey: "updateRate")
        scene["update_rate"] = 1
        scene["scale"] = 1
        config["scene"] = scene
        config["labels"] = []
        config["backdrops"] = []
        config["values"] = []
        config["plots"] = []

        let requested = settings.resolvedWidgets.filter {
            telemetry.supports($0.kind, presentation: $0.effectivePresentation)
        }
        guard !requested.isEmpty else { return nil }
        var values: [[String: Any]] = []
        var plots: [[String: Any]] = []
        for layout in requested {
            if layout.effectivePresentation == .routePlot,
               var plot = templatePlot(value: "course", style: settings.effectiveStyle, rootURL: rootURL) {
                placePlot(&plot, layout: layout, width: width, height: height, value: "course")
                plots.append(plot)
            } else if layout.effectivePresentation == .elevationPlot,
                      var plot = templatePlot(value: "elevation", style: settings.effectiveStyle, rootURL: rootURL) {
                placePlot(&plot, layout: layout, width: width, height: height, value: "elevation")
                plots.append(plot)
            } else if let metric = metricName(layout.kind),
                      var value = templateValue(
                        metric: metric,
                        displayType: displayType(layout.effectivePresentation),
                        style: settings.effectiveStyle,
                        rootURL: rootURL
                      ) {
                placeValue(&value, layout: layout, metric: metric, width: width, height: height)
                values.append(value)
            }
        }
        guard !values.isEmpty || !plots.isEmpty else { return nil }
        config["values"] = values
        config["plots"] = plots
        wrapper["config"] = config
        return try? JSONSerialization.data(withJSONObject: wrapper, options: [.sortedKeys])
    }

    private static func loadTemplate(style: TelemetryWidgetStyle, rootURL: URL) -> [String: Any]? {
        let name = style == .whiteVAM ? "white with VAM" : style.rawValue
        let url = rootURL.appendingPathComponent("templates").appendingPathComponent(name).appendingPathExtension("json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func allTemplates(rootURL: URL, preferred: TelemetryWidgetStyle) -> [[String: Any]] {
        var result: [[String: Any]] = []
        if let first = loadTemplate(style: preferred, rootURL: rootURL) { result.append(first) }
        let directory = rootURL.appendingPathComponent("templates")
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  !result.contains(where: { ($0["name"] as? String) == (value["name"] as? String) }) else { continue }
            result.append(value)
        }
        return result
    }

    private static func templateValue(metric: String, displayType: String, style: TelemetryWidgetStyle, rootURL: URL) -> [String: Any]? {
        let values = allTemplates(rootURL: rootURL, preferred: style).flatMap {
            (($0["config"] as? [String: Any])?["values"] as? [[String: Any]]) ?? []
        }
        return values.first { ($0["value"] as? String) == metric && (($0["display_type"] as? String) ?? "text") == displayType }
            ?? values.first { (($0["display_type"] as? String) ?? "text") == displayType }
            ?? (displayType == "text" ? values.first : nil)
    }

    private static func templatePlot(value: String, style: TelemetryWidgetStyle, rootURL: URL) -> [String: Any]? {
        let plots = allTemplates(rootURL: rootURL, preferred: style).flatMap {
            (($0["config"] as? [String: Any])?["plots"] as? [[String: Any]]) ?? []
        }
        return plots.first { ($0["value"] as? String) == value }
    }

    private static func placeValue(_ value: inout [String: Any], layout: TelemetryWidgetLayout, metric: String, width: Int, height: Int) {
        value["value"] = metric
        value["display_type"] = displayType(layout.effectivePresentation)
        value["x"] = Int(layout.x * Double(width))
        value["y"] = Int((1 - layout.y - layout.height) * Double(height))
        value["width"] = max(1, Int(layout.width * Double(width)))
        value["height"] = max(1, Int(layout.height * Double(height)))
        value["font_size"] = max(10, layout.height * Double(height) * 0.30)
        value["opacity"] = layout.opacity
        value["show_label"] = layout.showsLabel
        value["color"] = layout.foregroundHex
        value["icon_color"] = layout.accentHex
        value["unit_color"] = layout.foregroundHex
        value["display_unit"] = displayUnit(metric)
        if metric == "left_right_balance" { value["balance_format"] = "l_prefix" }
    }

    private static func placePlot(_ plot: inout [String: Any], layout: TelemetryWidgetLayout, width: Int, height: Int, value: String) {
        plot["value"] = value
        plot["x"] = Int(layout.x * Double(width))
        plot["y"] = Int((1 - layout.y - layout.height) * Double(height))
        plot["width"] = max(1, Int(layout.width * Double(width)))
        plot["height"] = max(1, Int(layout.height * Double(height)))
        plot["opacity"] = layout.opacity
        plot["show_full_activity"] = true
    }

    private static func displayType(_ presentation: TelemetryWidgetPresentation) -> String {
        switch presentation {
        case .linear, .linearSegmented: return "linear"
        case .arc, .arcReverse, .arcSegmented, .arcSegmentedDense: return "arc"
        case .corner: return "corner"
        case .headingTape: return "heading_tape"
        case .gForce: return "g_force"
        case .leanAngle: return "lean_angle"
        case .lapCurrent, .lapBest, .lapDelta, .lapLog: return "lap_timer"
        default: return "text"
        }
    }

    private static func metricName(_ kind: TelemetryWidgetKind) -> String? {
        switch kind {
        case .speedometer, .speedValue, .speedBar: return "speed"
        case .altitude: return "altitude"
        case .gForce, .gForceXY: return "g_force"
        case .heartRate: return "heartrate"
        case .cadence: return "cadence"
        case .power: return "power"
        case .rpm: return "rpm"
        case .throttle: return "throttle_position"
        case .brake: return "brake_position"
        case .leanAngle: return "lean_angle"
        case .lapTimer, .lapCounter: return "lap_timer"
        case .heading, .compass: return "heading"
        case .distance: return "distance"
        case .gradient: return "gradient"
        case .pace: return "pace"
        case .verticalSpeed: return "vertical_speed"
        case .temperature: return "temperature"
        case .enginePower: return "engine_power"
        case .torque: return "torque"
        case .gear: return "gear_position"
        case .coordinates: return "gps_coordinates"
        case .calories: return "calories"
        case .airPressure: return "air_pressure"
        case .leftRightBalance: return "left_right_balance"
        case .strideLength: return "stride_length"
        case .verticalOscillation: return "vertical_oscillation"
        case .groundContactTime: return "ground_contact_time"
        case .strokeRate: return "stroke_rate"
        case .cameraISO: return "iso"
        case .cameraAperture: return "aperture"
        case .cameraShutter: return "shutter_speed"
        case .cameraFocalLength: return "focal_length"
        case .cameraEV: return "ev"
        case .cameraColorTemperature: return "color_temperature"
        case .elapsedTime: return "time"
        case .routeMap, .routeProgress, .elevationProfile, .acceleration, .satelliteStatus: return nil
        }
    }

    private static func displayUnit(_ metric: String) -> String {
        switch metric {
        case "speed": return "kmh"
        case "altitude", "elevation", "distance", "stride_length": return "m"
        case "heartrate": return "bpm"
        case "cadence", "rpm": return "rpm"
        case "power", "engine_power": return "w"
        case "temperature", "core_temperature": return "c"
        case "g_force": return "g"
        case "heading", "lean_angle": return "degrees"
        case "air_pressure": return "bar"
        case "ground_contact_time": return "ms"
        case "torque": return "nm"
        default: return "percent"
        }
    }
}

private final class OVRLEYFrameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [Int: CGImage] = [:]
    private var order: [Int] = []
    private var bytes = 0
    private let byteLimit = 96 * 1_024 * 1_024

    func image(for key: Int) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return images[key]
    }

    func insert(_ image: CGImage, for key: Int) {
        lock.lock(); defer { lock.unlock() }
        let cost = image.bytesPerRow * image.height
        if let old = images[key] { bytes -= old.bytesPerRow * old.height }
        images[key] = image
        order.removeAll { $0 == key }
        order.append(key)
        bytes += cost
        while bytes > byteLimit, let first = order.first {
            order.removeFirst()
            if let removed = images.removeValue(forKey: first) { bytes -= removed.bytesPerRow * removed.height }
        }
    }
}
