import Foundation

public struct FCPXMLCapabilities: Sendable {
    public var supportedEffects: Set<String> = []
    public var supportedTransitions: Set<String> = ["cross-dissolve"]
    public var supportsTransform = true
    public var supportsConstantSpeed = true
    public var supportsMetadata = true
    public init() {}
}

public enum FCPXMLExportMode: String, Codable, Sendable { case edit, selects }

public enum FCPXMLExportError: LocalizedError {
    case missingAsset(UUID)
    case invalidTimeline(String)
    case malformedXML
    public var errorDescription: String? {
        switch self {
        case .missingAsset(let id): return "Не найден исходный материал \(id)"
        case .invalidTimeline(let reason): return "Монтажная шкала некорректна: \(reason)"
        case .malformedXML: return "Сгенерирован некорректный файл проекта для Final Cut Pro"
        }
    }
}

public struct FCPXMLExporter: Sendable {
    public let capabilities: FCPXMLCapabilities
    public init(capabilities: FCPXMLCapabilities = FCPXMLCapabilities()) { self.capabilities = capabilities }

    public func xml(timeline: Timeline, assets: [MediaAsset], mode: FCPXMLExportMode = .edit, renderedFallbackURL: URL? = nil) throws -> String {
        guard timeline.frameRate > 0, timeline.width > 0, timeline.height > 0 else { throw FCPXMLExportError.invalidTimeline("неверное разрешение или количество кадров в секунду") }
        let assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let usedIDs = Array(Set(timeline.items.compactMap(\.assetID))).sorted { $0.uuidString < $1.uuidString }
        for id in usedIDs where assetByID[id] == nil { throw FCPXMLExportError.missingAsset(id) }
        let fps = Int32(timeline.frameRate.rounded())
        let frameDuration = "1/\(fps)s"
        let formatID = "r_format"
        var resources = "<format id=\"\(formatID)\" name=\"FFVideoFormat\(timeline.height)p\(fps)\" frameDuration=\"\(frameDuration)\" width=\"\(timeline.width)\" height=\"\(timeline.height)\" colorSpace=\"1-1-1 (Rec. 709)\"/>"
        var resourceID: [UUID: String] = [:]
        for (index, id) in usedIDs.enumerated() {
            guard let asset = assetByID[id] else { continue }
            let rid = "r_asset_\(index + 1)"
            resourceID[id] = rid
            let duration = rational(asset.metadata.duration ?? 86_400, fps: fps)
            let audio = asset.metadata.hasAudio ? " hasAudio=\"1\" audioSources=\"1\" audioChannels=\"2\"" : ""
            resources += "<asset id=\"\(rid)\" name=\"\(escape(asset.displayName))\" start=\"0s\" duration=\"\(duration)\" hasVideo=\"1\"\(audio) format=\"\(formatID)\"><media-rep kind=\"original-media\" src=\"\(escape(asset.originalURL.absoluteString))\"/></asset>"
        }
        if let renderedFallbackURL {
            let renderedHasAudio = timeline.music != nil || !timeline.effectiveAudioClips.isEmpty || timeline.items.contains { item in
                guard timeline.effectiveOriginalAudioVolume > 0.0001,
                      item.effectiveAudioAdjustments.effectiveVolume > 0.0001,
                      let assetID = item.assetID else { return false }
                return assetByID[assetID]?.metadata.hasAudio == true
            }
            let audio = renderedHasAudio ? " hasAudio=\"1\" audioSources=\"1\" audioChannels=\"2\"" : ""
            resources += "<asset id=\"r_rendered\" name=\"VeloEdit Rendered Reference\" start=\"0s\" duration=\"\(rational(timeline.duration, fps: fps))\" hasVideo=\"1\"\(audio) format=\"\(formatID)\"><media-rep kind=\"original-media\" src=\"\(escape(renderedFallbackURL.absoluteString))\"/></asset>"
        }
        var modernTitleStyleResources = ""
        var modernTitleStyleID: [UUID: String] = [:]
        for (index, title) in timeline.effectiveTitleItems.enumerated() {
            let styleID = "ts_modern_\(index + 1)"
            modernTitleStyleID[title.id] = styleID
            modernTitleStyleResources += "<text-style-def id=\"\(styleID)\"><text-style font=\"\(escape(title.style.effectiveFontFamily))\" fontSize=\"\(decimal(title.style.fontSize))\" fontFace=\"\(title.style.effectiveFontWeight >= 0.72 ? "Bold" : "Regular")\" fontColor=\"\(fcpxColor(title.style.textColorHex, alpha: title.style.effectiveOpacity))\" alignment=\"\(title.style.alignment.rawValue)\"/></text-style-def>"
        }
        var spine = ""
        for item in timeline.items {
            if item.kind == .title {
                spine += "<title name=\"\(escape(item.title ?? "Title"))\" ref=\"r_title\" offset=\"\(rational(item.timelineStart, fps: fps))\" start=\"0s\" duration=\"\(rational(item.timelineDuration, fps: fps))\"><text><text-style ref=\"ts1\">\(escape(item.title ?? ""))</text-style></text>"
                if capabilities.supportsMetadata {
                    spine += "<metadata><md key=\"com.veloedit.kind\" value=\"title-card\"/><md key=\"com.veloedit.title.background\" value=\"\(escape(item.effectiveTitleStyle.backgroundColorHex))\"/></metadata>"
                }
                spine += "</title>"
                continue
            }
            guard let assetID = item.assetID, let ref = resourceID[assetID] else { continue }
            let name = assetByID[assetID]?.displayName ?? "Clip"
            let lane = item.overlay == nil ? "" : " lane=\"1\""
            spine += "<asset-clip name=\"\(escape(name))\" ref=\"\(ref)\"\(lane) offset=\"\(rational(item.timelineStart, fps: fps))\" start=\"\(rational(item.sourceStart, fps: fps))\" duration=\"\(rational(item.timelineDuration, fps: fps))\">"
            if capabilities.supportsConstantSpeed,
               abs(item.sourceDuration - item.timelineDuration) > 0.001 || item.isReversed || item.isFreezeFrame || item.speedRamp != nil {
                spine += timeMap(for: item, fps: fps)
            }
            let video = item.effectiveVideoAdjustments
            if capabilities.supportsTransform {
                spine += "<adjust-conform type=\"\(video.crop.rawValue)\"/>"
                let mirrored = item.effect == ClipEffect.mirror.rawValue
                if video.rotationQuarterTurns != 0 || mirrored || video.subjectReframe != nil {
                    let rotation = -video.rotationQuarterTurns * 90
                    if let reframe = video.subjectReframe {
                        let scale = (reframe.startScale + reframe.endScale) / 2
                        let centerX = (reframe.startCenterX + reframe.endCenterX) / 2
                        let centerY = (reframe.startCenterY + reframe.endCenterY) / 2
                        let x = (0.5 - centerX) * 100
                        let y = (centerY - 0.5) * 100
                        spine += "<adjust-transform position=\"\(decimal(x)) \(decimal(y))\" scale=\"\(mirrored ? "-\(decimal(scale)) \(decimal(scale))" : "\(decimal(scale)) \(decimal(scale))")\" rotation=\"\(rotation)\"/>"
                    } else {
                        // Keep the pre-P2 serialization stable for ordinary
                        // rotation/mirror-only edits and existing FCPXML tools.
                        spine += "<adjust-transform position=\"0 0\" scale=\"\(mirrored ? "-1 1" : "1 1")\" rotation=\"\(rotation)\"/>"
                    }
                }
                if video.opacity < 0.999 {
                    spine += "<adjust-blend amount=\"\(decimal(video.opacity))\"/>"
                }
            }
            let audio = item.effectiveAudioAdjustments
            let volume = timeline.effectiveOriginalAudioVolume * audio.effectiveVolume
            if abs(volume - 1) > 0.001 {
                spine += "<adjust-volume amount=\"\(decibels(volume))dB\"/>"
            }
            if capabilities.supportsMetadata {
                let reason = item.explanation.joined(separator: "; ")
                spine += "<metadata>"
                spine += "<md key=\"com.veloedit.locked\" value=\"\(item.locked ? "true" : "false")\"/>"
                spine += "<md key=\"com.veloedit.reason\" value=\"\(escape(reason))\"/>"
                spine += "<md key=\"com.veloedit.speed\" value=\"\(decimal(item.speed))\"/>"
                spine += "<md key=\"com.veloedit.freezeFrame\" value=\"\(item.isFreezeFrame)\"/>"
                spine += "<md key=\"com.veloedit.reverse\" value=\"\(item.isReversed)\"/>"
                spine += "<md key=\"com.veloedit.crop\" value=\"\(video.crop.rawValue)\"/>"
                spine += "<md key=\"com.veloedit.filter\" value=\"\(video.filter.rawValue)\"/>"
                spine += "<md key=\"com.veloedit.color\" value=\"brightness=\(decimal(video.brightness));contrast=\(decimal(video.contrast));saturation=\(decimal(video.saturation));warmth=\(decimal(video.warmth));tint=\(decimal(video.tint ?? 0));exposure=\(decimal(video.exposure ?? 0));highlights=\(decimal(video.highlights ?? 0));shadows=\(decimal(video.shadows ?? 0));vignette=\(decimal(video.vignette ?? 0));grain=\(decimal(video.grain ?? 0));sharpening=\(decimal(video.sharpening ?? 0));denoise=\(decimal(video.denoise ?? 0));blur=\(decimal(video.blur ?? 0));filterIntensity=\(decimal(video.filterIntensity ?? 1));stabilization=\(decimal(video.stabilization ?? 0));rollingShutter=\(video.rollingShutterCorrection ?? false);smoothSlowMotion=\(video.smoothSlowMotion ?? false)\"/>"
                if let reframe = video.subjectReframe {
                    spine += "<md key=\"com.veloedit.subjectReframe\" value=\"start=\(decimal(reframe.startCenterX)),\(decimal(reframe.startCenterY)),\(decimal(reframe.startScale));end=\(decimal(reframe.endCenterX)),\(decimal(reframe.endCenterY)),\(decimal(reframe.endScale));aspect=\(decimal(reframe.targetAspectRatio));confidence=\(decimal(reframe.confidence))\"/>"
                }
                spine += "<md key=\"com.veloedit.audio\" value=\"volume=\(decimal(audio.volume));muted=\(audio.muted);fadeIn=\(decimal(audio.fadeIn));fadeOut=\(decimal(audio.fadeOut));noiseReduction=\(decimal(audio.noiseReduction ?? 0));eq=\((audio.eqPreset ?? .flat).rawValue);normalize=\(audio.normalize ?? false);duckOthers=\(audio.duckOthers ?? false);duckingAmount=\(decimal(audio.duckingAmount ?? 0.5));preservePitch=\(audio.preservePitch ?? true);effect=\((audio.effect ?? AudioEffect.none).rawValue)\"/>"
                if let ramp = item.speedRamp {
                    let value = ramp.normalizedPoints.map { "\(decimal($0.position)):\(decimal($0.rate))" }.joined(separator: ",")
                    spine += "<md key=\"com.veloedit.speedRamp\" value=\"\(value)\"/>"
                }
                if let effect = item.effect { spine += "<md key=\"com.veloedit.effect\" value=\"\(escape(effect))\"/>" }
                if let transition = item.transition { spine += "<md key=\"com.veloedit.transition\" value=\"\(escape(transition))\"/>" }
                let objectEffects = timeline.effectiveEffects.filter { effect in
                    (effect.targetClipID == nil || effect.targetClipID == item.id) &&
                    effect.startTime < item.timelineStart + item.timelineDuration && effect.endTime > item.timelineStart
                }
                if !objectEffects.isEmpty {
                    spine += "<md key=\"com.veloedit.timelineEffects\" value=\"\(encodedMetadata(objectEffects))\"/>"
                }
                if let transitionObject = timeline.effectiveTransitionItems.first(where: { $0.incomingClipID == item.id }) {
                    spine += "<md key=\"com.veloedit.transitionObject\" value=\"\(encodedMetadata(transitionObject))\"/>"
                }
                if let overlay = item.overlay {
                    spine += "<md key=\"com.veloedit.overlay\" value=\"style=\(overlay.style.rawValue);base=\(overlay.baseItemID?.uuidString ?? "");corner=\(overlay.corner.rawValue);scale=\(decimal(overlay.scale));startOffset=\(decimal(overlay.effectiveStartOffset))\"/>"
                }
                if let telemetry = item.telemetryOverlay {
                    let metrics = telemetry.metrics.map(\.rawValue).sorted().joined(separator: ",")
                    spine += "<md key=\"com.veloedit.telemetry\" value=\"metrics=\(metrics);corner=\(telemetry.corner.rawValue);scale=\(decimal(telemetry.scale))\"/>"
                }
                spine += "</metadata>"
            }
            if mode == .edit, item.transition == "cross-dissolve", capabilities.supportedTransitions.contains("cross-dissolve") {
                spine += "<marker start=\"0s\" value=\"VeloEdit: cross-dissolve\"/>"
            }
            spine += "</asset-clip>"
        }
        for telemetry in timeline.effectiveTelemetryItems {
            let widgets = telemetry.settings.resolvedWidgets.map { $0.kind.rawValue }.joined(separator: ",")
            let source = telemetry.sourceID?.uuidString ?? ""
            let asset = telemetry.linkedAssetID?.uuidString ?? ""
            spine += "<gap name=\"VeloEdit Telemetry: \(escape(widgets))\" lane=\"3\" offset=\"\(rational(telemetry.timelineStart, fps: fps))\" start=\"0s\" duration=\"\(rational(telemetry.timelineDuration, fps: fps))\">"
            spine += "<marker start=\"0s\" value=\"Telemetry sync \(decimal(telemetry.syncOffset))s · \(escape(widgets))\"/>"
            spine += "<metadata><md key=\"com.veloedit.telemetry.sourceID\" value=\"\(source)\"/><md key=\"com.veloedit.telemetry.assetID\" value=\"\(asset)\"/><md key=\"com.veloedit.telemetry.widgets\" value=\"\(escape(widgets))\"/><md key=\"com.veloedit.telemetry.style\" value=\"\(telemetry.settings.effectiveStyle.rawValue)\"/><md key=\"com.veloedit.telemetry.syncOffset\" value=\"\(decimal(telemetry.syncOffset))\"/></metadata></gap>"
        }
        for title in timeline.effectiveTitleItems where title.enabled {
            let styleID = modernTitleStyleID[title.id] ?? "ts1"
            spine += "<title name=\"\(escape(title.kind.localizedTitle))\" ref=\"r_title\" lane=\"\(2 + title.track)\" offset=\"\(rational(title.startTime, fps: fps))\" start=\"0s\" duration=\"\(rational(title.duration, fps: fps))\"><text><text-style ref=\"\(styleID)\">\(escape(title.text))</text-style></text>"
            if capabilities.supportsMetadata {
                spine += "<metadata>"
                spine += "<md key=\"com.veloedit.titleObject.id\" value=\"\(title.id.uuidString)\"/>"
                spine += "<md key=\"com.veloedit.titleObject.kind\" value=\"\(title.kind.rawValue)\"/>"
                spine += "<md key=\"com.veloedit.titleObject.templateID\" value=\"\(escape(title.effectiveTemplateID ?? ""))\"/>"
                spine += "<md key=\"com.veloedit.titleObject.renderer\" value=\"\(escape(TitleTemplateRegistry.template(for: title)?.renderer ?? ""))\"/>"
                spine += "<md key=\"com.veloedit.titleObject.style\" value=\"\(encodedMetadata(title.style))\"/>"
                spine += "<md key=\"com.veloedit.titleObject.animation\" value=\"\(encodedMetadata(title.animation))\"/>"
                spine += "<md key=\"com.veloedit.titleObject.words\" value=\"\(encodedMetadata(title.words))\"/>"
                spine += "<md key=\"com.veloedit.titleObject.additionalText\" value=\"\(escape(title.additionalText ?? ""))\"/>"
                spine += "<md key=\"com.veloedit.titleObject.callToAction\" value=\"\(escape(title.callToAction ?? ""))\"/>"
                spine += "<md key=\"com.veloedit.reason\" value=\"\(escape(title.explanation.joined(separator: "; ")))\"/>"
                spine += "</metadata>"
            }
            spine += "</title>"
        }
        for effect in timeline.effectiveEffects {
            let definition = EffectPresetRegistry.preset(for: effect.effectType)
            spine += "<gap name=\"VeloEdit Effect: \(escape(effect.effectType.localizedTitle))\" lane=\"\(10 + effect.track)\" offset=\"\(rational(effect.startTime, fps: fps))\" start=\"0s\" duration=\"\(rational(effect.duration, fps: fps))\">"
            spine += "<marker start=\"0s\" value=\"Editable effect · \(escape(effect.effectType.rawValue))\"/>"
            spine += "<metadata><md key=\"com.veloedit.effectObject\" value=\"\(encodedMetadata(effect))\"/><md key=\"com.veloedit.effectCapability\" value=\"\(definition.fcpxmlCapability.rawValue)\"/><md key=\"com.veloedit.effectRegistryVersion\" value=\"\(definition.version)\"/></metadata></gap>"
        }
        for transition in timeline.effectiveTransitionItems where transition.enabled {
            spine += "<gap name=\"VeloEdit Transition: \(escape(transition.style.localizedTitle))\" lane=\"6\" offset=\"\(rational(transition.startTime, fps: fps))\" start=\"0s\" duration=\"\(rational(transition.duration, fps: fps))\">"
            spine += "<metadata><md key=\"com.veloedit.transitionObject\" value=\"\(encodedMetadata(transition))\"/></metadata></gap>"
        }
        let titleStyle = "<effect id=\"r_title\" name=\"Basic Title\" uid=\".../Titles.localized/Bumper\\/Opener.localized/Basic Title.localized/Basic Title.moti\"/><text-style-def id=\"ts1\"><text-style font=\"Helvetica Neue\" fontSize=\"64\" fontFace=\"Regular\" fontColor=\"1 1 1 1\" alignment=\"center\"/></text-style-def>\(modernTitleStyleResources)"
        let projectName = mode == .edit ? "VeloEdit Film" : "VeloEdit Selects"
        let editableProject = "<project name=\"\(projectName) — Editable\"><sequence format=\"\(formatID)\" duration=\"\(rational(timeline.duration, fps: fps))\" tcStart=\"0s\" tcFormat=\"NDF\" audioLayout=\"stereo\" audioRate=\"48k\"><spine>\(spine)</spine></sequence></project>"
        let renderedProject = renderedFallbackURL.map { _ in
            "<project name=\"\(projectName) — Rendered Reference\"><sequence format=\"\(formatID)\" duration=\"\(rational(timeline.duration, fps: fps))\" tcStart=\"0s\" tcFormat=\"NDF\" audioLayout=\"stereo\" audioRate=\"48k\"><spine><asset-clip name=\"VeloEdit Rendered Reference\" ref=\"r_rendered\" offset=\"0s\" start=\"0s\" duration=\"\(rational(timeline.duration, fps: fps))\"/></spine></sequence></project>"
        } ?? ""
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE fcpxml><fcpxml version=\"1.11\"><resources>\(resources)\(titleStyle)</resources><library><event name=\"VeloEdit\">\(editableProject)\(renderedProject)</event></library></fcpxml>"
        guard (try? XMLDocument(xmlString: xml)) != nil else { throw FCPXMLExportError.malformedXML }
        return xml
    }

    public func export(timeline: Timeline, assets: [MediaAsset], mode: FCPXMLExportMode = .edit, renderedFallbackURL: URL? = nil, to destination: URL) throws {
        let content = try xml(timeline: timeline, assets: assets, mode: mode, renderedFallbackURL: renderedFallbackURL)
        try content.data(using: .utf8)?.write(to: destination, options: .atomic)
    }

    public func requiresRenderedFallback(for timeline: Timeline) -> Bool {
        if timeline.music != nil || !timeline.effectiveAudioClips.isEmpty || !timeline.effectiveTelemetryItems.isEmpty ||
            !timeline.effectiveEffects.isEmpty || !timeline.effectiveTitleItems.isEmpty || !timeline.effectiveTransitionItems.isEmpty { return true }
        return timeline.items.contains { item in
            let video = item.effectiveVideoAdjustments
            let audio = item.effectiveAudioAdjustments
            let hasUnsupportedImage = video.filter != .none || abs(video.brightness) > 0.0001 ||
                abs(video.contrast - 1) > 0.0001 || abs(video.saturation - 1) > 0.0001 ||
                abs(video.warmth) > 0.0001 || abs(video.exposure ?? 0) > 0.0001 ||
                abs(video.highlights ?? 0) > 0.0001 || abs(video.shadows ?? 0) > 0.0001 ||
                abs(video.vignette ?? 0) > 0.0001 || abs(video.grain ?? 0) > 0.0001 ||
                abs(video.tint ?? 0) > 0.0001 || abs(video.stabilization ?? 0) > 0.0001 ||
                abs(video.sharpening ?? 0) > 0.0001 || abs(video.denoise ?? 0) > 0.0001 ||
                abs(video.blur ?? 0) > 0.0001 || (video.rollingShutterCorrection ?? false) ||
                (video.smoothSlowMotion ?? false)
            let hasUnsupportedAudio = audio.fadeIn > 0.0001 || audio.fadeOut > 0.0001 ||
                (audio.noiseReduction ?? 0) > 0.0001 || (audio.eqPreset ?? .flat) != .flat ||
                (audio.normalize ?? false) || (audio.duckOthers ?? false) ||
                (audio.effect ?? AudioEffect.none) != AudioEffect.none
            let hasDynamicSubjectReframe = video.subjectReframe.map { reframe in
                abs(reframe.startCenterX - reframe.endCenterX) > 0.0001 ||
                    abs(reframe.startCenterY - reframe.endCenterY) > 0.0001 ||
                    abs(reframe.startScale - reframe.endScale) > 0.0001
            } ?? false
            return item.effect != nil || item.transition != nil || item.overlay != nil || item.telemetryOverlay != nil ||
                (item.kind == .title && item.titleStyle != nil) ||
                hasUnsupportedImage || hasUnsupportedAudio || hasDynamicSubjectReframe
        }
    }

    private func rational(_ seconds: Double, fps: Int32) -> String {
        let frames = max(0, Int64((seconds * Double(fps)).rounded()))
        return "\(frames)/\(fps)s"
    }

    private func timeMap(for item: TimelineItem, fps: Int32) -> String {
        if let ramp = item.speedRamp, !item.isReversed, !item.isFreezeFrame {
            let points = ramp.normalizedPoints
            var rawTimes = [0.0]
            for (from, to) in zip(points, points.dropFirst()) {
                let sourcePart = item.sourceDuration * max(0, to.position - from.position)
                let averageRate = max(0.1, (from.rate + to.rate) * 0.5)
                rawTimes.append((rawTimes.last ?? 0) + sourcePart / averageRate)
            }
            let rawDuration = max(0.0001, rawTimes.last ?? item.timelineDuration)
            let scale = item.timelineDuration / rawDuration
            let entries = zip(points, rawTimes).map { point, rawTime in
                let sourceValue = item.sourceStart + item.sourceDuration * point.position
                return "<timept time=\"\(rational(rawTime * scale, fps: fps))\" value=\"\(rational(sourceValue, fps: fps))\" interp=\"smooth2\"/>"
            }.joined()
            let preservesPitch = item.effectiveAudioAdjustments.preservePitch ?? true
            return "<timeMap frameSampling=\"frame-blending\" preservesPitch=\"\(preservesPitch ? 1 : 0)\">\(entries)</timeMap>"
        }
        let firstValue = item.isReversed ? item.sourceStart + item.sourceDuration : item.sourceStart
        let lastValue = item.isReversed ? item.sourceStart : item.sourceStart + item.sourceDuration
        let preservesPitch = item.effectiveAudioAdjustments.preservePitch ?? true
        return "<timeMap frameSampling=\"frame-blending\" preservesPitch=\"\(preservesPitch ? 1 : 0)\"><timept time=\"0s\" value=\"\(rational(firstValue, fps: fps))\" interp=\"linear\"/><timept time=\"\(rational(item.timelineDuration, fps: fps))\" value=\"\(rational(lastValue, fps: fps))\" interp=\"linear\"/></timeMap>"
    }

    private func decimal(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func decibels(_ linear: Double) -> String {
        guard linear > 0.00001 else { return "-96" }
        return decimal(max(-96, 20 * log10(linear)))
    }

    private func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private func encodedMetadata<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "" }
        return escape(text)
    }

    private func fcpxColor(_ hex: String, alpha: Double) -> String {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let number = Int(value, radix: 16) else { return "1 1 1 \(decimal(alpha))" }
        let red = Double((number >> 16) & 0xFF) / 255
        let green = Double((number >> 8) & 0xFF) / 255
        let blue = Double(number & 0xFF) / 255
        return "\(decimal(red)) \(decimal(green)) \(decimal(blue)) \(decimal(alpha))"
    }
}

public struct FCPXMLFixtureFactory: Sendable {
    public init() {}
    public static let names = ["test_01_basic_cut", "test_02_multiple_ranges", "test_03_speed", "test_04_audio", "test_05_transition", "test_06_titles", "test_07_metadata", "test_08_hdr", "test_09_vertical", "test_10_telemetry"]

    public func writeAll(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/VeloEdit-fixture.mov"), kind: .video, byteSize: 0, contentHash: "fixture", metadata: MediaMetadata(duration: 60, width: 1920, height: 1080, frameRate: 30, codec: "avc1", hasAudio: true))
        var outputs: [URL] = []
        for (index, name) in Self.names.enumerated() {
            let planID = UUID()
            var items = [TimelineItem(assetID: asset.id, kind: .video, sourceStart: Double(index), sourceDuration: 4, timelineStart: 0, timelineDuration: 4, speed: index == 2 ? 2 : 1, transition: index == 4 ? "cross-dissolve" : nil, explanation: ["Fixture \(index + 1)"])]
            if index == 1 { items.append(TimelineItem(assetID: asset.id, kind: .video, sourceStart: 12, sourceDuration: 3, timelineStart: 4, timelineDuration: 3)) }
            if index == 5 { items.insert(TimelineItem(kind: .title, sourceDuration: 2, timelineStart: 0, timelineDuration: 2, title: "VeloEdit"), at: 0) }
            let timeline = Timeline(storyPlanID: planID, width: index == 8 ? 1080 : 1920, height: index == 8 ? 1920 : 1080, items: items)
            let url = directory.appendingPathComponent(name).appendingPathExtension("fcpxml")
            try FCPXMLExporter().export(timeline: timeline, assets: [asset], to: url)
            outputs.append(url)
        }
        return outputs
    }
}
