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
        guard let payload = activityPayload(telemetry),
              let png = try? OVRLEYBridge().renderFrame(payload: payload, config: config, second: sourceTime),
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
        func series(_ keyPath: KeyPath<TelemetrySample, Double?>, scale: Double = 1) -> [Any] {
            samples.map { sample -> Any in
                if let value = sample[keyPath: keyPath] { return value * scale }
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
            "pace": samples.map { sample -> Any in
                guard let speed = sample.speedMetersPerSecond, speed > 0 else { return NSNull() }
                return 1_000 / speed
            },
            "distance": series(\.distanceMeters),
            "heartrate": series(\.heartRateBPM),
            "cadence": series(\.cadenceRPM),
            "power": series(\.powerWatts),
            "engine_power": series(\.powerWatts),
            "temperature": series(\.temperatureCelsius),
            "g_force": series(\.gForce),
            "g_force_x": series(\.gForceX),
            "g_force_y": series(\.gForceY),
            "g_force_z": series(\.gForceZ),
            "rpm": series(\.rpm),
            "throttle_position": series(\.throttlePercent),
            "brake_position": series(\.brakePercent),
            "lean_angle": series(\.leanAngleDegrees),
            "air_pressure": series(\.airPressureHPA, scale: 0.001),
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
            "vertical_oscillation": series(\.verticalOscillationCentimeters, scale: 10),
            "gradient": series(\.gradientPercent),
            "heading": series(\.headingDegrees),
            "calories": series(\.calories),
            "gear_position": samples.map { sample -> Any in
                sample.gear.map { String(Int($0.rounded())) as Any } ?? NSNull()
            }
        ]
        // The normalized samples retain lap values, but not OVRLEY's complete
        // lap-boundary table. Supplying partial lap metadata invalidates even
        // unrelated speed/altitude widgets. Lap presentations use the shared
        // renderer and read the original samples directly.
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
        var labels: [[String: Any]] = []
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
                let labelColor = value["color"] ?? layout.accentHex
                placeValue(&value, layout: layout, metric: metric, width: width, height: height)
                values.append(value)
                if layout.showsLabel {
                    let rect = CGRect(x: layout.x * Double(width), y: layout.y * Double(height),
                                      width: layout.width * Double(width), height: layout.height * Double(height))
                    let region = TelemetryWidgetGeometry(rect: rect, presentation: layout.effectivePresentation, showsLabel: true).label
                    let text = layout.kind.localizedTitle.uppercased()
                    labels.append(["text": text, "x": region.minX, "y": Double(height) - region.maxY,
                                   "font": "Arial.ttf",
                                   "font_size": min(rect.height * 0.11, region.width / Double(max(1, text.count)) / 0.72),
                                   "color": labelColor, "opacity": layout.opacity])
                }
            }
        }
        // Never return a partial frame: the shared fallback must draw *all*
        // requested widgets when a template lacks one of the presentations.
        guard values.count + plots.count == requested.count else { return nil }
        config["labels"] = labels
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
        var candidate = values.first(where: { ($0["value"] as? String) == metric && (($0["display_type"] as? String) ?? "text") == displayType })
            ?? values.first(where: { (($0["display_type"] as? String) ?? "text") == displayType })
            ?? (displayType == "text" ? values.first : nil)
        // Bundled designs contain no heading tape, but OVRLEY ships its
        // canonical display defaults separately from those example designs.
        if candidate == nil, displayType == "heading_tape",
           let data = try? Data(contentsOf: rootURL.appendingPathComponent("assets/standard-metrics.json")),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let types = root["displayTypes"] as? [String: Any],
           let definitions = types["definitions"] as? [String: Any],
           let tape = definitions["heading_tape"] as? [String: Any],
           let defaults = tape["defaults"] as? [String: Any] {
            var value = values.first ?? [:]
            value.removeValue(forKey: "display_variants")
            value.merge(defaults) { _, tapeValue in tapeValue }
            candidate = value
        }
        guard var result = candidate else { return nil }
        let preferredValues = (loadTemplate(style: style, rootURL: rootURL)?["config"] as? [String: Any])?["values"] as? [[String: Any]] ?? []
        if let typography = preferredValues.first(where: { ($0["value"] as? String) == metric }) ?? preferredValues.first {
            // Reusing a metric's formatter must not import another design's
            // font and colors. Keep the selected template's visual identity.
            for key in ["font", "color", "unit_color", "icon_color"] {
                if let value = typography[key] { result[key] = value }
            }
        }
        return result
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
        let rect = CGRect(x: layout.x * Double(width), y: layout.y * Double(height),
                          width: layout.width * Double(width), height: layout.height * Double(height))
        if layout.effectivePresentation == .headingTape {
            let region = TelemetryWidgetGeometry(rect: rect, presentation: .headingTape, showsLabel: layout.showsLabel).graphic
            value["x"] = region.minX
            value["y"] = Double(height) - region.maxY
            value["width"] = max(1, Int(region.width))
            value["height"] = max(1, Int(region.height))
            value["pixels_per_degree"] = max(0.1, region.width / 120)
            value["major_tick_interval"] = 15
            value["minor_ticks_per_major"] = 3
            value["label_font_size"] = max(1, min(region.height * 0.22, region.width / 8 / 2.5))
            value["label_font"] = "Arial.ttf"
            value["label_offset"] = max(1, region.height * 0.05)
            value["indicator_size"] = max(1, region.height * 0.12)
            value["major_tick_thickness"] = max(1, region.width / 200)
            value["minor_tick_thickness"] = max(1, region.width / 300)
            value["show_minor_labels"] = false
            value["show_major_labels"] = true
            value["show_icon"] = false
            value["opacity"] = layout.opacity
            for key in ["tick_color", "label_color"] { value[key] = layout.foregroundHex }
            for key in ["cardinal_tick_color", "cardinal_label_color", "indicator_color"] { value[key] = layout.accentHex }
            return
        }
        let region = TelemetryWidgetGeometry(rect: rect, presentation: layout.effectivePresentation, showsLabel: layout.showsLabel).value
        let characters: Double = metric == "time" ? 12 : 10
        var fontSize = min(rect.height * 0.29, region.width / characters / 0.65, region.height * 0.7)
        if metric == "gps_coordinates" {
            // OVRLEY draws two coordinate rows at 40% of the base text size.
            fontSize = min(rect.height * 0.14, region.width / 18 / 0.65, region.height / 2.6) / 0.4
        }
        value["x"] = region.minX
        value["y"] = Double(height) - region.midY - fontSize / 2
        value["width"] = max(1, Int(layout.width * Double(width)))
        value["height"] = max(1, Int(layout.height * Double(height)))
        value["font_size"] = max(1, fontSize)
        value["show_icon"] = false
        value["icon_size"] = max(1, fontSize)
        value["icon_offset_x"] = 0
        value["icon_offset_y"] = 0
        value["opacity"] = layout.opacity
        value["show_label"] = layout.showsLabel
        value["color"] = layout.foregroundHex
        value["unit_color"] = layout.foregroundHex
        value["display_unit"] = displayUnit(metric)
        value.removeValue(forKey: "decimal_rounding")
        let precision: [String: Int] = ["vertical_speed": 2, "g_force": 2, "stride_length": 2, "distance": 2,
                                      "temperature": 1, "lean_angle": 1, "vertical_oscillation": 1,
                                      "left_right_balance": 1, "ev": 1]
        value["decimals"] = precision[metric] ?? 0
        if metric == "gps_coordinates" {
            value["coordinate_format"] = "ddm"
            // Display fonts often omit the degree/prime glyphs used by GPS.
            value["font"] = "Arial.ttf"
        }
        if metric == "distance" { value["show_full_distance"] = false }
        if metric == "left_right_balance" { value["balance_format"] = "l_prefix" }
    }

    private static func placePlot(_ plot: inout [String: Any], layout: TelemetryWidgetLayout, width: Int, height: Int, value: String) {
        let rect = CGRect(x: layout.x * Double(width), y: layout.y * Double(height),
                          width: layout.width * Double(width), height: layout.height * Double(height))
        let area = rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.16)
        let targetWidth = max(1, area.width)
        let targetHeight = max(1, area.height)
        let originalWidth = (plot["width"] as? NSNumber)?.doubleValue ?? targetWidth
        let originalHeight = (plot["height"] as? NSNumber)?.doubleValue ?? targetHeight
        let scale = min(targetWidth / max(1, originalWidth), targetHeight / max(1, originalHeight))
        // Templates were authored at 1080p/4K. Their pixel-sized markers and
        // strokes must follow the widget, not keep their original frame size.
        for key in ["completed_line_width", "remaining_line_width", "marker_size", "marker_variant_diameter"] {
            if let number = plot[key] as? NSNumber { plot[key] = max(1, number.doubleValue * scale) }
        }
        for key in ["metric_label_offset_x", "metric_label_offset_y", "imperial_label_offset_x", "imperial_label_offset_y"] {
            if let number = plot[key] as? NSNumber { plot[key] = number.doubleValue * scale }
        }
        if var label = plot["point_label"] as? [String: Any] {
            let fontSize = max(1, min(targetHeight * 0.16, targetWidth * 0.07))
            label["font_size"] = fontSize
            plot["point_label"] = label
            plot["metric_label_offset_x"] = -fontSize * 1.5
            plot["imperial_label_offset_x"] = -fontSize * 1.5
            plot["metric_label_offset_y"] = -fontSize * 1.4
            plot["imperial_label_offset_y"] = fontSize * 0.2
        }
        plot["value"] = value
        plot["x"] = area.minX
        plot["y"] = Double(height) - area.maxY
        // In upstream templates rotation is around the scene anchor, rather
        // than the widget center; carrying it over moves routes off screen.
        plot["rotation"] = 0
        plot["width"] = Int(targetWidth)
        plot["height"] = Int(targetHeight)
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
        case .gradient: return nil // Upstream gradient uses a separate, unbounded icon layout.
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
        case .elapsedTime: return nil // `time` is wall-clock time, not elapsed clip time.
        case .routeMap, .routeProgress, .elevationProfile, .acceleration, .satelliteStatus: return nil
        }
    }

    private static func displayUnit(_ metric: String) -> String {
        switch metric {
        case "speed": return "kmh"
        case "altitude", "elevation", "stride_length": return "m"
        case "distance": return "km"
        case "heartrate": return "bpm"
        case "cadence", "rpm": return "rpm"
        case "power", "engine_power": return "w"
        case "temperature", "core_temperature": return "celsius"
        case "g_force": return "g"
        case "heading", "lean_angle": return "degrees"
        case "air_pressure": return "hpa"
        case "ground_contact_time": return "ms"
        case "torque": return "nm"
        case "vertical_speed": return "mps"
        case "vertical_oscillation": return "cm"
        case "calories": return "kcal"
        case "pace": return "min_per_km"
        case "gps_coordinates": return "both"
        case "iso": return "iso"
        case "aperture": return "fnum"
        case "shutter_speed": return "seconds"
        case "focal_length": return "mm"
        case "ev": return "ev"
        case "color_temperature": return "kelvin"
        case "stroke_rate": return "spm"
        case "time", "lap_timer": return "s"
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
