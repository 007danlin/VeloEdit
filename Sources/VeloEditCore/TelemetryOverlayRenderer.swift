import Foundation
import CoreGraphics
import CoreImage
import CoreText

public enum TelemetryOverlayRenderer {
    public static func image(
        settings: TelemetryOverlaySettings,
        telemetry: TelemetrySummary,
        progress: Double,
        sourceTime: Double? = nil,
        renderSize: CGSize
    ) -> CIImage? {
        guard let raster = rasterImage(
            settings: settings,
            telemetry: telemetry,
            progress: progress,
            sourceTime: sourceTime,
            renderSize: renderSize
        ) else { return nil }
        var result = CIImage(cgImage: raster.image).transformed(
            by: CGAffineTransform(translationX: raster.origin.x, y: raster.origin.y)
        )
        if settings.effectiveOpacity < 0.999 {
            result = result.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: settings.effectiveOpacity)
            ])
        }
        return result
    }

    struct RasterImage {
        let image: CGImage
        let origin: CGPoint
    }

    static func rasterImage(
        settings: TelemetryOverlaySettings,
        telemetry: TelemetrySummary,
        progress: Double,
        sourceTime: Double? = nil,
        renderSize: CGSize
    ) -> RasterImage? {
        guard telemetry.hasTelemetry else { return nil }
        let time = max(0, sourceTime ?? progress * (telemetry.timedSamples?.last?.timestamp ?? 0))
        if let image = OVRLEYFrameRenderer.frame(
            settings: settings,
            telemetry: telemetry,
            sourceTime: time,
            renderSize: renderSize
        ) {
            return RasterImage(image: image, origin: .zero)
        }
        let sample = telemetry.sample(at: time)
        let sourceProgress = min(max(0, time / max(0.001, telemetry.timedSamples?.last?.timestamp ?? 1)), 1)
        let widgets = layouts(for: settings).filter { telemetry.supports($0.kind, presentation: $0.effectivePresentation) }
        guard !widgets.isEmpty else { return nil }
        let scale: CGFloat = 1
        let pixelRects = widgets.map { layout in
            CGRect(
                x: layout.x * renderSize.width,
                y: layout.y * renderSize.height,
                width: layout.width * renderSize.width,
                height: layout.height * renderSize.height
            ).integral
        }
        let bounds = pixelRects.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -18, dy: -18).intersection(CGRect(origin: .zero, size: renderSize))
        guard !bounds.isNull, bounds.width > 1, bounds.height > 1,
              let context = CGContext(
                data: nil,
                width: Int(bounds.width * scale),
                height: Int(bounds.height * scale),
                bitsPerComponent: 8,
                bytesPerRow: Int(bounds.width * scale) * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        for (layout, rect) in zip(widgets, pixelRects) {
            drawWidget(
                layout,
                settings: settings,
                telemetry: telemetry,
                sample: sample,
                time: time,
                progress: sourceProgress,
                rect: rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY),
                context: context
            )
        }
        guard let cgImage = context.makeImage() else { return nil }
        return RasterImage(image: cgImage, origin: bounds.origin)
    }

    /// Catalogue thumbnails use the production renderer, so every card is a
    /// faithful miniature of the overlay that will be composited into video.
    public static func previewCGImage(
        kind: TelemetryWidgetKind,
        presentation: TelemetryWidgetPresentation,
        style: TelemetryWidgetStyle,
        size: CGSize
    ) -> CGImage? {
        guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1 else { return nil }
        let summary = catalogueTelemetry
        var layout = TelemetryWidgetLayout.presetLayout(kind: kind, presentation: presentation)
        layout.x = 0.04
        layout.y = 0.04
        layout.width = 0.92
        layout.height = 0.92
        let settings = TelemetryOverlaySettings(metrics: kind.metric.map { [$0] } ?? [], style: style, widgets: [layout])
        let renderSize = CGSize(width: max(2, size.width.rounded(.up)), height: max(2, size.height.rounded(.up)))
        guard let preview = image(settings: settings, telemetry: summary, progress: 0.5, sourceTime: 2.5, renderSize: renderSize) else { return nil }
        return CIContext(options: nil).createCGImage(preview, from: CGRect(origin: .zero, size: renderSize))
    }

    static let catalogueTelemetry: TelemetrySummary = {
        let route = [
            TelemetryCoordinate(latitude: 55.7500, longitude: 37.6100),
            TelemetryCoordinate(latitude: 55.7508, longitude: 37.6120),
            TelemetryCoordinate(latitude: 55.7496, longitude: 37.6142),
            TelemetryCoordinate(latitude: 55.7514, longitude: 37.6160),
            TelemetryCoordinate(latitude: 55.7520, longitude: 37.6135)
        ]
        let sample = TelemetrySample(
            timestamp: 5,
            speedMetersPerSecond: 10.6,
            altitudeMeters: 842,
            gForce: 1.2,
            coordinate: route[2],
            distanceMeters: 24_800,
            accelerationMetersPerSecondSquared: 3.8,
            gForceX: 0.38,
            gForceY: -0.22,
            headingDegrees: 318,
            heartRateBPM: 148,
            cadenceRPM: 92,
            powerWatts: 322,
            leanAngleDegrees: 42,
            rpm: 6_840,
            throttlePercent: 76,
            brakePercent: 34,
            lapNumber: 3,
            lapTimeSeconds: 102.36,
            temperatureCelsius: 18,
            gradientPercent: 8.4,
            verticalSpeedMetersPerSecond: 0.28,
            torqueNewtonMeters: 94,
            gear: 4,
            calories: 684,
            airPressureHPA: 1_012,
            strideLengthMeters: 1.24,
            verticalOscillationCentimeters: 8.6,
            groundContactTimeMilliseconds: 242,
            leftRightBalancePercent: 52,
            strokeRate: 32,
            cameraISO: 400,
            cameraAperture: 2.8,
            cameraShutterSeconds: 1 / 240,
            cameraFocalLengthMM: 24,
            cameraEV: 0.7,
            cameraColorTemperatureKelvin: 5_600
        )
        let speeds = [4.0, 8, 10.6, 12, 14]
        let altitudes = [780.0, 805, 798, 842, 920]
        let samples = route.enumerated().map { index, coordinate in
            var point = sample
            point.timestamp = Double(index) * 1.25
            point.coordinate = coordinate
            point.speedMetersPerSecond = speeds[index]
            point.altitudeMeters = altitudes[index]
            return point
        }
        return TelemetrySummary(
            hasGPMF: true,
            sampleCount: samples.count,
            maxSpeedMetersPerSecond: 16,
            distanceMeters: 24_800,
            minAltitudeMeters: 780,
            maxAltitudeMeters: 920,
            maxGForce: 2,
            route: route,
            speedSamplesMetersPerSecond: speeds,
            altitudeSamplesMeters: altitudes,
            timedSamples: samples
        )
    }()

    private static func layouts(for settings: TelemetryOverlaySettings) -> [TelemetryWidgetLayout] {
        if let custom = settings.widgets, !custom.isEmpty { return custom }
        let base = settings.resolvedWidgets
        let columns = min(2, max(1, base.count))
        let width = settings.scale
        let cellWidth = width / Double(columns)
        let rows = Int(ceil(Double(base.count) / Double(columns)))
        let cellHeight = min(0.18, 0.40 / Double(max(1, rows)))
        let totalHeight = cellHeight * Double(rows)
        let originX: Double = settings.corner == .topRight || settings.corner == .bottomRight ? 0.96 - width : 0.04
        let originY: Double = settings.corner == .topLeft || settings.corner == .topRight ? 0.96 - totalHeight : 0.04
        return base.enumerated().map { index, source in
            var layout = source
            layout.x = originX + Double(index % columns) * cellWidth
            layout.y = originY + Double(index / columns) * cellHeight
            layout.width = max(0.08, cellWidth - 0.008)
            layout.height = max(0.06, cellHeight - 0.008)
            return layout
        }
    }

    private static func drawWidget(
        _ layout: TelemetryWidgetLayout,
        settings: TelemetryOverlaySettings,
        telemetry: TelemetrySummary,
        sample: TelemetrySample?,
        time: Double,
        progress: Double,
        rect: CGRect,
        context: CGContext
    ) {
        let style = settings.effectiveStyle
        let palette = colors(layout: layout, style: style)
        let presentation = layout.effectivePresentation
        let geometry = TelemetryWidgetGeometry(rect: rect, presentation: presentation, showsLabel: layout.showsLabel)
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(layout.opacity)
        if palette.background.alpha > 0.01 || layout.borderWidth > 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -2), blur: layout.shadowRadius, color: CGColor(gray: 0, alpha: 0.5))
            context.setFillColor(palette.background.copy(alpha: palette.background.alpha) ?? palette.background)
            let radius = style == .circular ? min(rect.width, rect.height) / 2 : min(18, rect.height * 0.16)
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(path); context.fillPath()
            if layout.borderWidth > 0 {
                context.addPath(path); context.setStrokeColor(palette.accent)
                context.setLineWidth(layout.borderWidth); context.strokePath()
            }
            context.restoreGState()
        }
        context.clip(to: rect)

        if layout.showsLabel {
            draw(lapLabel(presentation) ?? layout.kind.localizedTitle.uppercased(), context: context,
                 rect: geometry.label, fontName: fontName(for: style, fallback: layout.fontName),
                 fontSize: rect.height * 0.11, color: palette.accent)
        }
        if presentation == .routePlot {
            guard let route = telemetry.route, route.count > 1 else { return }
            drawRoute(route, context: context, rect: geometry.graphic, coordinate: sample?.coordinate, color: palette.accent)
            return
        }
        if presentation == .elevationPlot {
            guard let values = telemetry.altitudeSamplesMeters, values.count > 1 else { return }
            drawSeries(values, context: context, rect: geometry.graphic, progress: progress, color: palette.accent)
            return
        }
        guard let display = displayValue(for: layout.kind, sample: sample, telemetry: telemetry, time: time) else { return }
        let gaugeRect = geometry.graphic
        switch presentation {
        case .linear:
            drawBar(value: display.normalized, context: context, rect: gaugeRect, color: palette.accent, segmented: false)
        case .linearSegmented:
            drawBar(value: display.normalized, context: context, rect: gaugeRect, color: palette.accent, segmented: true)
        case .arc:
            drawArcGauge(value: display.normalized, context: context, rect: gaugeRect, color: palette.accent, reverse: false, segments: 0)
        case .arcReverse:
            drawArcGauge(value: display.normalized, context: context, rect: gaugeRect, color: palette.accent, reverse: true, segments: 0)
        case .arcSegmented:
            drawArcGauge(value: display.normalized, context: context, rect: gaugeRect, color: palette.accent, reverse: false, segments: 22)
        case .arcSegmentedDense:
            drawArcGauge(value: display.normalized, context: context, rect: gaugeRect, color: palette.accent, reverse: false, segments: 34)
        case .corner:
            drawCornerGauge(value: display.normalized, context: context, rect: gaugeRect, color: palette.accent)
        case .headingTape:
            drawHeadingTape(heading: sample?.headingDegrees ?? 0, context: context, rect: gaugeRect, color: palette.accent, labelColor: palette.foreground)
        case .gForce:
            drawGForce(x: sample?.gForceX ?? 0, y: sample?.gForceY ?? 0, context: context, rect: gaugeRect, color: palette.accent, foreground: palette.foreground)
        case .leanAngle:
            drawLeanAngle(value: sample?.leanAngleDegrees ?? 0, context: context, rect: gaugeRect, color: palette.accent)
        case .lapCurrent, .lapBest, .lapDelta, .lapLog, .text:
            break
        case .routePlot, .elevationPlot:
            break
        }
        if presentation == .lapLog {
            let laps = recordedLaps(telemetry, at: time).suffix(3).reversed()
            for (index, lap) in laps.enumerated() {
                let row = CGRect(x: geometry.value.minX, y: geometry.value.maxY - CGFloat(index + 1) * geometry.value.height / 3,
                                 width: geometry.value.width, height: geometry.value.height / 3)
                draw(String(format: "L%d   %.2f s", lap.number, lap.seconds), context: context, rect: row,
                     fontName: fontName(for: style, fallback: layout.fontName), fontSize: rect.height * 0.13,
                     color: index == 0 ? palette.accent : palette.foreground)
            }
        } else if presentation != .headingTape {
            var text = display.text
            let completed = recordedLaps(telemetry, at: time).filter { $0.number < Int(sample?.lapNumber ?? 0) }
            if presentation == .lapBest {
                text = completed.map(\.seconds).min().map { String(format: "%.2f s", $0) } ?? "—"
            } else if presentation == .lapDelta {
                // A live delta requires a reference at the same position on the lap.
                // Only show the measured difference between completed laps here.
                text = completed.last.flatMap { last in
                    completed.map(\.seconds).min().map { String(format: "%+.2f s", last.seconds - $0) }
                } ?? "—"
            }
            draw(text, context: context, rect: geometry.value, fontName: fontName(for: style, fallback: layout.fontName),
                 fontSize: rect.height * 0.29, color: palette.foreground)
        }
    }

    private static func recordedLaps(_ telemetry: TelemetrySummary, at time: Double) -> [(number: Int, seconds: Double)] {
        var laps: [Int: Double] = [:]
        for sample in telemetry.timedSamples ?? [] where sample.timestamp <= time {
            guard let number = sample.lapNumber, let seconds = sample.lapTimeSeconds, number > 0 else { continue }
            laps[Int(number)] = max(laps[Int(number)] ?? 0, seconds)
        }
        return laps.keys.sorted().map { ($0, laps[$0]!) }
    }

    private struct Display { var text: String; var normalized: Double }
    private static func displayValue(for kind: TelemetryWidgetKind, sample: TelemetrySample?, telemetry: TelemetrySummary, time: Double) -> Display? {
        func display(_ value: Double?, _ format: String, normalized: Double) -> Display? { value.map { Display(text: String(format: format, $0), normalized: min(max(0, normalized), 1)) } }
        switch kind {
        case .speedometer, .speedValue, .speedBar: return display(sample?.speedMetersPerSecond.map { $0 * 3.6 }, "%.0f km/h", normalized: (sample?.speedMetersPerSecond ?? 0) / max(1, telemetry.maxSpeedMetersPerSecond ?? 1))
        case .altitude:
            let minimum = telemetry.minAltitudeMeters ?? 0
            let span = max(1, (telemetry.maxAltitudeMeters ?? minimum + 1) - minimum)
            return display(sample?.altitudeMeters, "%.0f m", normalized: ((sample?.altitudeMeters ?? minimum) - minimum) / span)
        case .gForce:
            let scalar = sample?.gForce ?? {
                guard let x = sample?.gForceX, let y = sample?.gForceY else { return nil }
                return hypot(x, y)
            }()
            return display(scalar, "%.2f g", normalized: abs(scalar ?? 0) / max(1, telemetry.maxGForce ?? 1))
        case .gForceXY: return display(sample?.gForceX ?? sample?.gForceY, "%.2f g", normalized: (sample?.gForceX ?? 0) * 0.5 + 0.5)
        case .acceleration: return display(sample?.accelerationMetersPerSecondSquared, "%.2f m/s²", normalized: abs(sample?.accelerationMetersPerSecondSquared ?? 0) / 12)
        case .heartRate: return display(sample?.heartRateBPM, "%.0f bpm", normalized: (sample?.heartRateBPM ?? 0) / 220)
        case .cadence: return display(sample?.cadenceRPM, "%.0f rpm", normalized: (sample?.cadenceRPM ?? 0) / 180)
        case .power, .enginePower: return display(sample?.powerWatts, "%.0f W", normalized: (sample?.powerWatts ?? 0) / 1_000)
        case .rpm: return display(sample?.rpm, "%.0f rpm", normalized: (sample?.rpm ?? 0) / 12_000)
        case .throttle: return display(sample?.throttlePercent, "%.0f %%", normalized: (sample?.throttlePercent ?? 0) / 100)
        case .brake: return display(sample?.brakePercent, "%.0f %%", normalized: (sample?.brakePercent ?? 0) / 100)
        case .leanAngle: return display(sample?.leanAngleDegrees, "%.1f°", normalized: (sample?.leanAngleDegrees ?? 0) / 120 + 0.5)
        case .lapTimer: return display(sample?.lapTimeSeconds, "%.2f s", normalized: 0.5)
        case .lapCounter: return display(sample?.lapNumber, "Lap %.0f", normalized: 0.5)
        case .heading, .compass: return display(sample?.headingDegrees, "%.0f°", normalized: (sample?.headingDegrees ?? 0) / 360)
        case .distance: return display(sample?.distanceMeters.map { $0 / 1_000 } ?? telemetry.distanceMeters.map { $0 / 1_000 }, "%.2f km", normalized: (sample?.distanceMeters ?? 0) / max(1, telemetry.distanceMeters ?? 1))
        case .gradient: return display(sample?.gradientPercent, "%.1f %%", normalized: (sample?.gradientPercent ?? 0) / 40 + 0.5)
        case .pace:
            guard let speed = sample?.speedMetersPerSecond, speed > 0 else { return nil }
            let seconds = 1_000 / speed; return Display(text: String(format: "%d:%02d /km", Int(seconds) / 60, Int(seconds) % 60), normalized: min(1, speed / 8))
        case .verticalSpeed: return display(sample?.verticalSpeedMetersPerSecond, "%.2f m/s", normalized: (sample?.verticalSpeedMetersPerSecond ?? 0) / 10 + 0.5)
        case .temperature: return display(sample?.temperatureCelsius, "%.1f °C", normalized: ((sample?.temperatureCelsius ?? 0) + 20) / 80)
        case .torque: return display(sample?.torqueNewtonMeters, "%.0f Nm", normalized: (sample?.torqueNewtonMeters ?? 0) / 1_000)
        case .gear: return display(sample?.gear, "Gear %.0f", normalized: (sample?.gear ?? 0) / 8)
        case .coordinates: return sample?.coordinate.map { Display(text: String(format: "%.5f, %.5f", $0.latitude, $0.longitude), normalized: 0.5) }
        case .calories: return display(sample?.calories, "%.0f kcal", normalized: (sample?.calories ?? 0) / 2_000)
        case .airPressure: return display(sample?.airPressureHPA, "%.0f hPa", normalized: ((sample?.airPressureHPA ?? 900) - 800) / 300)
        case .leftRightBalance: return display(sample?.leftRightBalancePercent, "%.1f %%", normalized: (sample?.leftRightBalancePercent ?? 50) / 100)
        case .strideLength: return display(sample?.strideLengthMeters, "%.2f m", normalized: (sample?.strideLengthMeters ?? 0) / 3)
        case .verticalOscillation: return display(sample?.verticalOscillationCentimeters, "%.1f cm", normalized: (sample?.verticalOscillationCentimeters ?? 0) / 20)
        case .groundContactTime: return display(sample?.groundContactTimeMilliseconds, "%.0f ms", normalized: (sample?.groundContactTimeMilliseconds ?? 0) / 500)
        case .strokeRate: return display(sample?.strokeRate, "%.0f spm", normalized: (sample?.strokeRate ?? 0) / 100)
        case .cameraISO: return display(sample?.cameraISO, "ISO %.0f", normalized: log10(max(1, sample?.cameraISO ?? 1)) / 5)
        case .cameraAperture: return display(sample?.cameraAperture, "f/%.1f", normalized: (sample?.cameraAperture ?? 0) / 22)
        case .cameraShutter:
            guard let shutter = sample?.cameraShutterSeconds, shutter > 0 else { return nil }
            return Display(text: shutter < 1 ? String(format: "1/%.0f s", 1 / shutter) : String(format: "%.1f s", shutter), normalized: min(1, shutter))
        case .cameraFocalLength: return display(sample?.cameraFocalLengthMM, "%.0f mm", normalized: (sample?.cameraFocalLengthMM ?? 0) / 600)
        case .cameraEV: return display(sample?.cameraEV, "%.1f EV", normalized: (sample?.cameraEV ?? 0) / 20 + 0.5)
        case .cameraColorTemperature: return display(sample?.cameraColorTemperatureKelvin, "%.0f K", normalized: ((sample?.cameraColorTemperatureKelvin ?? 2_000) - 2_000) / 10_000)
        case .elapsedTime: return Display(text: String(format: "%02d:%02d.%02d", Int(time) / 60, Int(time) % 60, Int(time * 100) % 100), normalized: 0.5)
        case .satelliteStatus: return telemetry.route?.isEmpty == false ? Display(text: "GPS ACTIVE", normalized: 1) : nil
        case .routeMap, .routeProgress, .elevationProfile: return nil
        }
    }

    private static func drawArcGauge(value: Double, context: CGContext, rect: CGRect, color: CGColor, reverse: Bool, segments: Int) {
        let center = CGPoint(x: rect.midX, y: rect.midY), radius = min(rect.width, rect.height) * 0.42
        let start = CGFloat.pi * (reverse ? -0.2 : 0.8)
        let sweep = CGFloat.pi * 1.4
        let clamped = min(max(0, value), 1)
        context.setLineWidth(max(3, radius * 0.10)); context.setLineCap(.round)
        if segments > 0 {
            let gap = sweep / CGFloat(segments) * 0.34
            for index in 0..<segments {
                let fraction = CGFloat(index) / CGFloat(max(1, segments - 1))
                let a = start + (reverse ? -1 : 1) * sweep * fraction
                let b = a + (reverse ? -1 : 1) * max(0.01, sweep / CGFloat(segments) - gap)
                context.setStrokeColor(fraction <= clamped ? color : CGColor(gray: 1, alpha: 0.18))
                context.addArc(center: center, radius: radius, startAngle: a, endAngle: b, clockwise: reverse)
                context.strokePath()
            }
        } else {
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.18)); context.addArc(center: center, radius: radius, startAngle: start, endAngle: start + (reverse ? -sweep : sweep), clockwise: reverse); context.strokePath()
            context.setStrokeColor(color); context.addArc(center: center, radius: radius, startAngle: start, endAngle: start + (reverse ? -sweep * clamped : sweep * clamped), clockwise: reverse); context.strokePath()
        }
    }

    private static func drawBar(value: Double, context: CGContext, rect: CGRect, color: CGColor, segmented: Bool) {
        let clamped = min(max(0, value), 1)
        if segmented {
            let count = 24
            let gap = max(1, rect.width * 0.008)
            let width = (rect.width - gap * CGFloat(count - 1)) / CGFloat(count)
            for index in 0..<count {
                context.setFillColor(Double(index) / Double(count) <= clamped ? color : CGColor(gray: 1, alpha: 0.18))
                context.fill(CGRect(x: rect.minX + CGFloat(index) * (width + gap), y: rect.minY, width: width, height: rect.height))
            }
        } else {
            let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
            context.addPath(path); context.setFillColor(CGColor(gray: 1, alpha: 0.18)); context.fillPath()
            let filled = CGRect(x: rect.minX, y: rect.minY, width: rect.width * clamped, height: rect.height)
            context.addPath(CGPath(roundedRect: filled, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)); context.setFillColor(color); context.fillPath()
        }
    }

    private static func drawCornerGauge(value: Double, context: CGContext, rect: CGRect, color: CGColor) {
        let clamped = min(max(0, value), 1)
        context.setLineWidth(max(4, min(rect.width, rect.height) * 0.10)); context.setLineCap(.round)
        let corner = CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.18)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.18)); context.move(to: CGPoint(x: corner.x, y: rect.maxY)); context.addLine(to: corner); context.addLine(to: CGPoint(x: rect.maxX, y: corner.y)); context.strokePath()
        context.setStrokeColor(color); context.move(to: CGPoint(x: corner.x, y: corner.y + rect.height * 0.82 * clamped)); context.addLine(to: corner); context.addLine(to: CGPoint(x: corner.x + rect.width * 0.82 * clamped, y: corner.y)); context.strokePath()
    }

    private static func drawHeadingTape(heading: Double, context: CGContext, rect: CGRect, color: CGColor, labelColor: CGColor) {
        let center = rect.midX
        let slotWidth = rect.width / 9
        let labelFontSize = min(rect.height * 0.22, slotWidth / 2.5)
        for offset in -4...4 {
            let x = center + CGFloat(offset) * rect.width / 9
            context.setStrokeColor(offset == 0 ? color : labelColor.copy(alpha: 0.65) ?? labelColor)
            context.setLineWidth(offset == 0 ? 3 : 1.5)
            context.move(to: CGPoint(x: x, y: rect.maxY - rect.height * 0.25)); context.addLine(to: CGPoint(x: x, y: rect.maxY)); context.strokePath()
            let value = (Int(heading.rounded()) + offset * 15 + 360) % 360
            draw(value % 90 == 0 ? [0: "N", 90: "E", 180: "S", 270: "W"][value] ?? "\(value)" : "\(value)", context: context, rect: CGRect(x: x - slotWidth * 0.45, y: rect.minY + rect.height * 0.18, width: slotWidth * 0.9, height: rect.height * 0.28), fontName: "Helvetica Neue", fontSize: labelFontSize, color: offset == 0 ? color : labelColor)
        }
    }

    private static func drawGForce(x: Double, y: Double, context: CGContext, rect: CGRect, color: CGColor, foreground: CGColor) {
        let center = CGPoint(x: rect.midX, y: rect.midY), radius = min(rect.width, rect.height) * 0.38
        context.setStrokeColor(foreground.copy(alpha: 0.45) ?? foreground); context.setLineWidth(2)
        context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)); context.strokePath()
        context.move(to: CGPoint(x: center.x - radius, y: center.y)); context.addLine(to: CGPoint(x: center.x + radius, y: center.y)); context.move(to: CGPoint(x: center.x, y: center.y - radius)); context.addLine(to: CGPoint(x: center.x, y: center.y + radius)); context.strokePath()
        let marker = CGPoint(x: center.x + CGFloat(min(max(-1, x), 1)) * radius * 0.72, y: center.y + CGFloat(min(max(-1, y), 1)) * radius * 0.72)
        context.setFillColor(color); context.fillEllipse(in: CGRect(x: marker.x - radius * 0.10, y: marker.y - radius * 0.10, width: radius * 0.20, height: radius * 0.20))
    }

    private static func drawLeanAngle(value: Double, context: CGContext, rect: CGRect, color: CGColor) {
        let center = CGPoint(x: rect.midX, y: rect.midY), radius = min(rect.width, rect.height) * 0.42
        context.setLineWidth(max(4, radius * 0.12)); context.setLineCap(.round)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.18)); context.addArc(center: center, radius: radius, startAngle: .pi, endAngle: 0, clockwise: false); context.strokePath()
        let normalized = min(max(-1, value / 60), 1)
        context.setStrokeColor(color); context.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - CGFloat(normalized) * .pi / 2, clockwise: normalized > 0); context.strokePath()
    }

    private static func lapLabel(_ presentation: TelemetryWidgetPresentation) -> String? {
        switch presentation {
        case .lapCurrent: return "CURRENT LAP"
        case .lapBest: return "BEST LAP"
        case .lapDelta: return "DELTA"
        case .lapLog: return "LAP LOG"
        default: return nil
        }
    }

    private static func drawSeries(_ values: [Double], context: CGContext, rect: CGRect, progress: Double, color: CGColor) {
        guard let minValue = values.min(), let maxValue = values.max() else { return }
        let span = max(0.000_001, maxValue - minValue), count = max(2, min(values.count, Int(Double(values.count) * progress)))
        context.beginPath()
        for (index, value) in values.prefix(count).enumerated() {
            let point = CGPoint(x: rect.minX + CGFloat(index) / CGFloat(max(1, values.count - 1)) * rect.width, y: rect.minY + CGFloat((value - minValue) / span) * rect.height)
            index == 0 ? context.move(to: point) : context.addLine(to: point)
        }
        context.setStrokeColor(color); context.setLineWidth(max(2, rect.height * 0.025)); context.strokePath()
    }

    private static func drawRoute(_ route: [TelemetryCoordinate], context: CGContext, rect: CGRect, coordinate: TelemetryCoordinate?, color: CGColor) {
        guard let minLat = route.map(\.latitude).min(), let maxLat = route.map(\.latitude).max(),
              let minLon = route.map(\.longitude).min(), let maxLon = route.map(\.longitude).max() else { return }
        let longitudeScale = max(0.01, cos((minLat + maxLat) / 2 * .pi / 180))
        let latSpan = max(0.000001, maxLat - minLat), lonSpan = max(0.000001, (maxLon - minLon) * longitudeScale)
        let area = rect.insetBy(dx: 4, dy: 4)
        let scale = min(area.width / lonSpan, area.height / latSpan)
        func point(_ coordinate: TelemetryCoordinate) -> CGPoint {
            CGPoint(x: area.midX + (coordinate.longitude - (minLon + maxLon) / 2) * longitudeScale * scale,
                    y: area.midY + (coordinate.latitude - (minLat + maxLat) / 2) * scale)
        }
        context.beginPath()
        for (index, coordinate) in route.enumerated() {
            index == 0 ? context.move(to: point(coordinate)) : context.addLine(to: point(coordinate))
        }
        context.setStrokeColor(color.copy(alpha: 0.5) ?? color)
        context.setLineWidth(max(1.5, rect.height * 0.025)); context.setLineCap(.round); context.setLineJoin(.round); context.strokePath()
        if let coordinate {
            let location = point(coordinate), radius = max(2.5, min(rect.width, rect.height) * 0.045)
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: location.x - radius, y: location.y - radius, width: radius * 2, height: radius * 2))
        }
    }

    private static func draw(_ text: String, context: CGContext, rect: CGRect, fontName: String, fontSize: CGFloat, color: CGColor) {
        guard rect.width > 0, rect.height > 0 else { return }
        func line(at size: CGFloat) -> CTLine {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(fontName as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ]
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        let original = line(at: fontSize)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(original, &ascent, &descent, nil)
        let scale = min(1, rect.width / max(1, width), rect.height / max(1, ascent + descent))
        let fitted = line(at: fontSize * scale)
        _ = CTLineGetTypographicBounds(fitted, &ascent, &descent, nil)
        context.saveGState()
        context.clip(to: rect)
        context.textPosition = CGPoint(x: rect.minX, y: rect.midY - (ascent + descent) / 2 + descent)
        CTLineDraw(fitted, context)
        context.restoreGState()
    }

    private struct Palette { var foreground: CGColor; var background: CGColor; var accent: CGColor }
    private static func colors(layout: TelemetryWidgetLayout, style: TelemetryWidgetStyle) -> Palette {
        switch style {
        case .acidTitanium: return Palette(foreground: color("#DCE2E8", fallback: .white), background: color("#08101500", fallback: .clear), accent: color("#D6FF40", fallback: .white))
        case .breezeBlue: return Palette(foreground: color("#FFFFFF", fallback: .white), background: color("#0B2C4A18", fallback: .clear), accent: color("#D4E8FF", fallback: .white))
        case .burntOrange: return Palette(foreground: color("#FFFFFF", fallback: .white), background: color("#1A080000", fallback: .clear), accent: color("#E85D00", fallback: .white))
        case .champagneBasic: return Palette(foreground: color("#FFF3C9", fallback: .white), background: color("#11111100", fallback: .clear), accent: color("#FFF1D4", fallback: .white))
        case .champagneBorders: return Palette(foreground: color("#FFF7E6", fallback: .white), background: color("#15110A55", fallback: .clear), accent: color("#FFF7E6", fallback: .white))
        case .champagneShadows: return Palette(foreground: color("#FFF7E6", fallback: .white), background: color("#00000000", fallback: .clear), accent: color("#FFF7E6", fallback: .white))
        case .futuristicHUD: return Palette(foreground: color("#D1FEFF", fallback: .white), background: color("#00273544", fallback: .clear), accent: color("#65EBFC", fallback: .white))
        case .lavenderGradient: return Palette(foreground: color("#E4CFFA", fallback: .white), background: color("#251A3544", fallback: .clear), accent: color("#D3BCF7", fallback: .white))
        case .safaBrian: return Palette(foreground: .white, background: .clear, accent: .white)
        case .whiteVAM: return Palette(foreground: .white, background: .clear, accent: .white)
        case .whiteOpacity: return Palette(foreground: .white, background: color("#00000033", fallback: .clear), accent: color("#FFFFFFCC", fallback: .white))
        case .whiteShadows: return Palette(foreground: .white, background: .clear, accent: color("#C9FFE7", fallback: .white))
        case .racing: return Palette(foreground: color(layout.foregroundHex, fallback: .white), background: color(layout.backgroundHex, fallback: .clear), accent: CGColor(red: 1, green: 0.18, blue: 0.12, alpha: 1))
        case .action, .goPro: return Palette(foreground: color(layout.foregroundHex, fallback: .white), background: color(layout.backgroundHex, fallback: .clear), accent: CGColor(red: 0.10, green: 0.72, blue: 1, alpha: 1))
        case .cinematic: return Palette(foreground: color(layout.foregroundHex, fallback: .white), background: color(layout.backgroundHex, fallback: .clear), accent: CGColor(red: 1, green: 0.72, blue: 0.25, alpha: 1))
        default: return Palette(foreground: color(layout.foregroundHex, fallback: .white), background: color(layout.backgroundHex, fallback: CGColor(gray: 0.03, alpha: 0.8)), accent: color(layout.accentHex, fallback: CGColor(red: 0.26, green: 0.85, blue: 1, alpha: 1)))
        }
    }

    private static func fontName(for style: TelemetryWidgetStyle, fallback: String) -> String {
        switch style {
        case .acidTitanium: return "Menlo-Bold"
        case .breezeBlue: return "Avenir Next Heavy"
        case .burntOrange: return "Avenir Next Condensed Heavy"
        case .futuristicHUD: return "Avenir Next Demi Bold"
        case .champagneBasic, .lavenderGradient: return "Avenir Next"
        case .champagneBorders, .champagneShadows, .whiteOpacity: return "HelveticaNeue-CondensedBold"
        case .whiteShadows: return "Menlo-Bold"
        case .safaBrian, .whiteVAM: return "Avenir Next Condensed Heavy"
        case .digital: return "Menlo-Bold"
        default: return fallback + " Bold"
        }
    }

    private static func color(_ text: String, fallback: CGColor) -> CGColor {
        let value = text.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard (value.count == 6 || value.count == 8), let number = UInt64(value, radix: 16) else { return fallback }
        let alpha: CGFloat = value.count == 8 ? CGFloat(number & 0xFF) / 255 : 1
        let rgb = value.count == 8 ? number >> 8 : number
        return CGColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}

private extension CGColor {
    var alpha: CGFloat { components?.last ?? 1 }
}
