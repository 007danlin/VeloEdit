import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import VeloEditCore

/// Explicit opt-in corpus test. Does not copy/modify originals, call a website,
/// infer action sequences from stills, or pretend annotations are model output.
@Suite(.serialized) struct CinematicAcceptanceTests {
    @Test func typedApplicationOperationsExecuteAndExport() async throws {
        guard let path = ProcessInfo.processInfo.environment["VELOEDIT_CINEMATIC_MEDIA"],
              let outputPath = ProcessInfo.processInfo.environment["VELOEDIT_CINEMATIC_OUTPUT"] else { return }
        let output = URL(fileURLWithPath: outputPath).appendingPathComponent("TypedOperations")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var assets: [MediaAsset] = []
        for name in ["GX010487.MP4", "GX010492.MP4"] {
            assets.append(try await MediaImporter().makeAsset(url: URL(fileURLWithPath: path).appendingPathComponent(name)))
        }
        let candidates = assets.map { Candidate(assetID: $0.id, sourceStart: 2, sourceDuration: 2,
            scores: ClipScores(quality: 1, interest: 1, action: 0, stability: 1, uniqueness: 1)) }
        let telemetrySource = await TelemetryEngine().embeddedSource(for: assets[0])
        let analyses = assets.enumerated().map { index, asset in
            AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [candidates[index]],
                           telemetry: index == 0 ? telemetrySource?.summary : nil)
        }
        let items = TimelineTiming.retimed(assets.map {
            TimelineItem(assetID: $0.id, kind: .video, sourceStart: 2, sourceDuration: 2, timelineStart: 0, timelineDuration: 2)
        })
        let source = Timeline(storyPlanID: UUID(), width: 640, height: 360, frameRate: 30_000 / 1_001, items: items, endingFadeDuration: 0)
        let a = items[0].id, b = items[1].id, reason = "Explicit typed application capability audit"
        let effect = EffectTimelineItem(effectType: .brightness, startTime: 0, duration: 2,
                                       keyframes: [.init(parameter: "intensity", time: 0, value: 0.2)], targetClipID: a)
        let frame = try #require(effect.keyframes.first)
        let title = TitleTimelineItem(kind: .title, text: "Аудит", startTime: 0, duration: 1)
        let transition = TimelineTransitionItem(style: .crossDissolve, outgoingClipID: a, incomingClipID: b, startTime: 2, duration: 0.5)
        var cases: [(String, DirectorToolCall, Timeline)] = []
        func add(_ name: String, _ call: DirectorToolCall, _ fixture: Timeline? = nil) { cases.append((name, call, fixture ?? source)) }
        add("split", .split(itemID: a, fraction: 0.5, reason: reason))
        add("trim", .trim(itemID: a, sourceStart: 2.3, sourceDuration: 1.4, reason: reason))
        add("rippleDelete", .rippleDelete(itemID: a, reason: reason))
        add("reorder", .reorder(itemID: b, beforeItemID: a, reason: reason))
        add("swap", .swap(itemID: a, withItemID: b, reason: reason))
        add("insert", .insert(candidateID: candidates[0].id, sourceStart: 2, sourceDuration: 1, afterItemID: a, role: .bRoll, reason: reason))
        add("replace", .replace(itemID: a, candidateID: candidates[1].id, sourceStart: 2, sourceDuration: 1, role: .bRoll, reason: reason))
        add("duplicate", .duplicate(itemID: a, afterItemID: b, reason: reason))
        add("setCrop", .setCrop(itemID: a, crop: .fit, reason: reason))
        add("setMotion", .setMotion(itemID: a, effect: .zoomIn, reason: reason))
        add("setSpeed", .setSpeed(itemID: a, rate: 1.5, reason: reason))
        add("setSpeedRamp", .setSpeedRamp(itemID: a, ramp: .action, reason: reason))
        add("freezeFrame", .freezeFrame(itemID: a, duration: 0.5, reason: reason))
        add("setVideoAdjustments", .setVideoAdjustments(itemID: a, adjustments: VideoAdjustments(exposure: 0.2), reason: reason))
        add("setTransition", .setTransition(itemID: b, transition: .crossDissolve, reason: reason))
        add("setAudioAdjustments", .setAudioAdjustments(itemID: a, adjustments: AudioAdjustments(volume: 0.5), reason: reason))
        add("setDucking", .setDucking(AudioDuckingSettings(), reason: reason))
        add("detachAudio", .detachAudio(itemID: a, reason: reason))
        // Unmuted PIP hit an existing AAC failure/hang in the broad audit.
        // Certify its visual operation separately; retain that audio limitation
        // in the report rather than calling the unmuted operation verified.
        var overlayFixture = source; overlayFixture.originalAudioVolume = 0
        add("insertOverlay", .insertOverlay(candidateID: candidates[1].id, baseItemID: a, sourceStart: 2, sourceDuration: 1, style: .pictureInPicture, reason: reason), overlayFixture)
        // Clearing a real existing object is also an actual operation when a
        // camera contains no usable telemetry. Never manufacture sensor data.
        var telemetryFixture = source
        telemetryFixture.items[0].telemetryOverlay = TelemetryOverlaySettings()
        add("setTelemetry", .setTelemetry(itemID: a, settings: telemetrySource == nil ? nil : TelemetryOverlaySettings(), reason: reason), telemetryFixture)
        add("addTitle", .addTitle(text: "Река", atEnd: false, reason: reason))
        add("addEffect", .addEffect(type: .brightness, startTime: 0, duration: 2, targetClipID: a, reason: reason))
        add("addAnimatedEffect", .addAnimatedEffect(type: .brightness, startTime: 0, duration: 2, targetClipID: a,
            keyframes: [.init(parameter: "intensity", time: 0, value: 0.2), .init(parameter: "intensity", time: 2, value: 0.7)], reason: reason))
        add("applyEffectPreset", .applyEffectPreset(presetID: "travel", startTime: 0, duration: 2, targetClipID: a, reason: reason))
        var effectFixture = source; effectFixture.effects = [effect]
        add("removeEffect", .removeEffect(effectID: effect.id, reason: reason), effectFixture)
        add("moveEffect", .moveEffect(effectID: effect.id, startTime: 0.2, reason: reason), effectFixture)
        add("trimEffect", .trimEffect(effectID: effect.id, duration: 1, reason: reason), effectFixture)
        add("setEffectParameter", .setEffectParameter(effectID: effect.id, name: "intensity", value: 0.7, reason: reason), effectFixture)
        add("animateParameter", .animateParameter(effectID: effect.id, parameter: "intensity", fromValue: 0.2, toValue: 0.7, startTime: 0, endTime: 2, easing: .linear, reason: reason), effectFixture)
        add("addEffectKeyframe", .addEffectKeyframe(effectID: effect.id, keyframe: .init(parameter: "intensity", time: 1, value: 0.7), reason: reason), effectFixture)
        add("removeEffectKeyframe", .removeEffectKeyframe(effectID: effect.id, keyframeID: frame.id, reason: reason), effectFixture)
        add("addTitleObject", .addTitleObject(text: "Река", kind: .title, templateID: "title.minimal-clean.v1", startTime: 0, duration: 1, reason: reason))
        var titleFixture = source; titleFixture.titleItems = [title]
        add("editTitleObject", .editTitleObject(titleID: title.id, text: "Вода", style: nil, animation: nil, reason: reason), titleFixture)
        add("removeTitleObject", .removeTitleObject(titleID: title.id, reason: reason), titleFixture)
        add("addTransitionObject", .addTransitionObject(outgoingClipID: a, incomingClipID: b, style: .crossDissolve, duration: 0.5, reason: reason))
        var transitionFixture = source; transitionFixture.transitionItems = [transition]
        add("editTransitionObject", .editTransitionObject(transitionID: transition.id, duration: 0.7, intensity: 0.6, direction: nil, easing: .linear, reason: reason), transitionFixture)
        add("removeTransitionObject", .removeTransitionObject(transitionID: transition.id, reason: reason), transitionFixture)
        add("syncToBeat", .syncToBeat(bpm: 120, reason: reason))
        add("setCanvas", .setCanvas(width: 360, height: 640, subjectAware: false, reason: reason))
        add("replaceSubtitles", .replaceSubtitles(items: [.init(kind: .automaticSubtitles, text: "Проверочный текст", startTime: 0.2, duration: 1)], reason: reason))
        #expect(cases.count == 40 && Set(cases.map { $0.0 }).count == 40)
        let telemetry = telemetrySource.map { [assets[0].id: $0.summary] } ?? [:]
        var rows: [[String: Any]] = []
        for (name, call, fixture) in cases {
            let result = DirectorEditingTools().apply([call], to: fixture, assets: assets, analyses: analyses)
            #expect(result.report.rejected.isEmpty && result.report.applied == [call], "\(name): \(result.report.rejected)")
            let preview = try await PlaybackEngine().build(timeline: result.timeline, assets: assets, telemetry: telemetry, preferStableRealtimePreview: true)
            try JSONEncoder.veloEdit.encode(result.timeline).write(to: output.appendingPathComponent(name + "-timeline.json"))
            let destination = output.appendingPathComponent(name + ".mp4")
            try? FileManager.default.removeItem(at: destination)
            let report = try await RenderEngine().render(timeline: result.timeline, assets: assets, telemetry: telemetry, quality: .preview720p, destination: destination)
            #expect(report.skippedItemIDs.isEmpty)
            let movie = AVURLAsset(url: destination)
            let duration = try await movie.load(.duration).seconds
            #expect(abs(duration - preview.duration) < 0.08)
            let live = AVAssetImageGenerator(asset: preview.composition); live.videoComposition = preview.videoComposition
            let encoded = AVAssetImageGenerator(asset: movie)
            for generator in [live, encoded] {
                generator.maximumSize = CGSize(width: 128, height: 72); generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            }
            let a = try pixels(live, time: 0.5), b = try pixels(encoded, time: 0.5)
            let error = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count * 255)
            #expect(error < 0.09, "\(name): \(error)")
            rows.append(["id": name, "executed": result.report.applied.count == 1, "exportVerified": true,
                         "export": destination.lastPathComponent, "duration": duration, "previewExportPixelError": error,
                         "fixtureAudioPolicy": name == "insertOverlay" ? "explicitly muted; unmuted AAC export not certified" : "preserve source audio",
                         "telemetrySourceAvailable": telemetrySource != nil])
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
    }

    @Test func allRegisteredTransitionsExecutePreviewAndExport() async throws {
        guard let path = ProcessInfo.processInfo.environment["VELOEDIT_CINEMATIC_MEDIA"],
              let outputPath = ProcessInfo.processInfo.environment["VELOEDIT_CINEMATIC_OUTPUT"] else { return }
        let output = URL(fileURLWithPath: outputPath).appendingPathComponent("CatalogTransitions")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var assets: [MediaAsset] = []
        for name in ["GX010487.MP4", "GX010492.MP4"] {
            assets.append(try await MediaImporter().makeAsset(url: URL(fileURLWithPath: path).appendingPathComponent(name)))
        }
        let items = TimelineTiming.retimed(assets.map { asset in
            TimelineItem(assetID: asset.id, kind: .video, sourceStart: 2, sourceDuration: 2, timelineStart: 0, timelineDuration: 2,
                         audioAdjustments: AudioAdjustments(muted: true))
        })
        let source = Timeline(storyPlanID: UUID(), width: 640, height: 360, frameRate: 30_000 / 1_001, items: items, endingFadeDuration: 0)
        var rows: [[String: Any]] = []
        for style in TransitionStyle.allCases {
            let duration = TransitionPresetRegistry.preset(for: style).defaultDuration
            let executed = DirectorEditingTools().apply([
                .addTransitionObject(outgoingClipID: items[0].id, incomingClipID: items[1].id, style: style, duration: duration, reason: "Explicit catalogue execution audit")
            ], to: source, assets: assets, analyses: [])
            #expect(executed.report.applied.count == 1 && executed.report.rejected.isEmpty)
            let timeline = executed.timeline
            let preview = try await PlaybackEngine().build(timeline: timeline, assets: assets, preferStableRealtimePreview: true)
            let destination = output.appendingPathComponent(style.rawValue + ".mp4")
            try? FileManager.default.removeItem(at: destination)
            let report = try await RenderEngine().render(timeline: timeline, assets: assets, quality: .preview720p, destination: destination)
            #expect(report.skippedItemIDs.isEmpty)
            let encoded = AVURLAsset(url: destination)
            let actualDuration = try await encoded.load(.duration).seconds
            #expect(abs(actualDuration - preview.duration) < 0.08)
            let live = AVAssetImageGenerator(asset: preview.composition); live.videoComposition = preview.videoComposition
            let movie = AVAssetImageGenerator(asset: encoded)
            for generator in [live, movie] {
                generator.maximumSize = CGSize(width: 128, height: 72); generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            }
            let time = floor((2 - duration / 2) * timeline.frameRate) / timeline.frameRate
            let a = try pixels(live, time: time), b = try pixels(movie, time: time)
            let error = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count * 255)
            #expect(error < 0.09, "\(style.rawValue): preview/export error \(error)")
            rows.append(["id": style.rawValue, "executed": true, "previewExportPixelError": error, "duration": actualDuration])
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
    }

    @Test func realCorpusAndKnowledgeActionsMatchEncodedOutput() async throws {
        guard let path = ProcessInfo.processInfo.environment["VELOEDIT_CINEMATIC_MEDIA"],
              let outputPath = ProcessInfo.processInfo.environment["VELOEDIT_CINEMATIC_OUTPUT"] else { return }
        let folder = URL(fileURLWithPath: path)
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mp4" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(urls.count == 29)
        var assets: [MediaAsset] = []
        var rows: [[String: Any]] = []
        for url in urls {
            let asset = try await MediaImporter().makeAsset(url: url)
            assets.append(asset)
            let item = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 1, sourceDuration: 2, timelineStart: 0, timelineDuration: 2)
            let timeline = Timeline(storyPlanID: UUID(), frameRate: 30_000 / 1_001, items: [item])
            let project = ProjectManifest(name: "Read-only cinematic corpus", assets: [asset], timelines: [timeline])
            var refused = 0
            for request in ["Примени Match Cut", "Примени Datamosh", "Примени Rule of Thirds", "Добавь Slow Motion"] {
                let input = NaturalLanguageDirectorInput(userRequest: request, currentProject: project, timeline: timeline, selectedItemID: item.id)
                let result = NaturalLanguageDirector().execute(plan: NaturalLanguageDirector().plan(input: input), input: input)
                #expect(!result.committed && result.timeline == timeline)
                #expect(result.toolReport.applied.isEmpty && !result.toolReport.rejected.isEmpty)
                refused += 1
            }
            rows.append(["file": asset.displayName, "duration": asset.metadata.duration ?? 0,
                         "fps": asset.metadata.frameRate ?? 0, "contentHash": asset.contentHash,
                         "annotation": "Неполный анализ: нет локальных соответствий, композиционных измерений и ASR. Замедление исходного звука запрещено.",
                         "expected": "refuse", "refusedScenarios": refused])
        }
        // One source for visible grading; two independently labelled landscapes
        // for optical joins. Muting is an explicit test fixture choice, not a
        // claim that the source is silent or free of speech.
        let landscape = try #require(assets.first { $0.displayName == "GX010487.MP4" })
        let pov = try #require(assets.first { $0.displayName == "GX010492.MP4" })
        let lowFPS = try #require(assets.first { $0.displayName == "GX010476.MP4" })
        let cases: [(String, String, String?, Double?)] = [
            ("dissolve", "Добавь наплыв между клипами", "cross-dissolve", nil),
            ("wipe-left", "Добавь шторка между клипами", "wipe-left", nil),
            ("wipe-right", "Добавь шторка вправо между клипами", "wipe-right", nil),
            ("wipe-up", "Добавь шторка вверх между клипами", "wipe-up", nil),
            ("wipe-down", "Добавь шторка вниз между клипами", "wipe-down", nil),
            ("iris", "Добавь iris между клипами", "iris", nil),
            ("grain", "Добавь плёночное зерно", nil, nil),
            ("vignette", "Добавь виньетка", nil, nil),
            ("slow-motion", "Добавь Slow Motion", nil, 0.5),
            ("fast-motion", "Добавь Fast Motion", nil, 2),
            ("freeze-frame", "Добавь Freeze Frame", nil, nil)
        ]
        for (name, request, transitionID, speed) in cases {
            let clips = [landscape, pov].map { asset in
                TimelineItem(assetID: asset.id, kind: .video, sourceStart: 2, sourceDuration: 2,
                             timelineStart: 0, timelineDuration: 2, audioAdjustments: AudioAdjustments(muted: true))
            }
            let timeline = Timeline(storyPlanID: UUID(), width: 640, height: 360, frameRate: 30_000 / 1_001,
                                    items: TimelineTiming.retimed(clips), endingFadeDuration: 0)
            let project = ProjectManifest(name: "Cinematic optical acceptance", assets: [landscape, pov], timelines: [timeline])
            let input = NaturalLanguageDirectorInput(userRequest: request, currentProject: project, timeline: timeline,
                                                    selectedItemID: transitionID == nil ? clips[0].id : nil)
            let director = NaturalLanguageDirector()
            let planned = director.plan(input: input)
            let result = director.execute(plan: planned, input: input)
            #expect(result.committed, "\(name): \(result.userSummary)")
            #expect(result.toolReport.rejected.isEmpty)
            if let transitionID { #expect(result.timeline.effectiveTransitionItems.first?.style.rawValue == transitionID) }
            if let speed { #expect(result.timeline.items[0].speed == speed) }
            for original in timeline.items {
                #expect(result.timeline.items.first { $0.id == original.id }?.sourceStart == original.sourceStart)
            }
            let preview = try await PlaybackEngine().build(timeline: result.timeline, assets: project.assets, preferStableRealtimePreview: true)
            let destination = output.appendingPathComponent(name + ".mp4")
            try? FileManager.default.removeItem(at: destination)
            let rendered = try await RenderEngine().render(timeline: result.timeline, assets: project.assets,
                                                           quality: .preview720p, destination: destination)
            #expect(rendered.skippedItemIDs.isEmpty)
            let encoded = AVURLAsset(url: destination)
            let duration = try await encoded.load(.duration).seconds
            #expect(abs(duration - preview.duration) < 0.08)
            let live = AVAssetImageGenerator(asset: preview.composition)
            live.videoComposition = preview.videoComposition
            live.maximumSize = CGSize(width: 128, height: 72)
            live.appliesPreferredTrackTransform = true
            let movie = AVAssetImageGenerator(asset: encoded)
            movie.maximumSize = CGSize(width: 128, height: 72)
            movie.appliesPreferredTrackTransform = true
            live.requestedTimeToleranceBefore = .zero; live.requestedTimeToleranceAfter = .zero
            movie.requestedTimeToleranceBefore = .zero; movie.requestedTimeToleranceAfter = .zero
            var differences: [Double] = []
            let sampleTimes = transitionID == nil ? [0.5, min(duration - 0.1, 1.5), duration - 0.3]
                : [0.5, 2 - (result.timeline.effectiveTransitionItems.first?.duration ?? 0.5) / 2, duration - 0.3]
            for time in sampleTimes {
                let a = try pixels(live, time: time), b = try pixels(movie, time: time)
                let error = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count * 255)
                #expect(error < 0.08, "\(name) preview/export mismatch \(error)")
                differences.append(error)
            }
            try JSONEncoder.veloEdit.encode(result.timeline).write(to: output.appendingPathComponent(name + "-timeline.json"))
            if let plan = planned.cinematicPlan { try JSONEncoder.veloEdit.encode(plan).write(to: output.appendingPathComponent(name + "-plan.json")) }
            rows.append(["case": name, "expected": "apply", "applied": result.toolReport.applied.count,
                         "sourceRanges": ["GX010487.MP4:2...4", "GX010492.MP4:2...4"],
                         "annotation": "Явно запрошенная оптическая операция; не утверждает сюжетную связь. Исходный звук явно отключён в проверочном примере.",
                         "previewExportPixelError": differences, "duration": duration, "export": destination.lastPathComponent])
        }
        // A 29.97 FPS source cannot supply 29.97 output frames after 2x slow down.
        let item = TimelineItem(assetID: lowFPS.id, kind: .video, sourceDuration: 2, timelineStart: 0, timelineDuration: 2, audioAdjustments: AudioAdjustments(muted: true))
        let timeline = Timeline(storyPlanID: UUID(), frameRate: 30_000 / 1_001, items: [item])
        let project = ProjectManifest(name: "Insufficient FPS", assets: [lowFPS], timelines: [timeline])
        let plan = try #require(CinematicDirector.plan(request: "Добавь Slow Motion", targetIDs: [item.id], project: project, timeline: timeline))
        let result = CinematicDirector.execute(plan, project: project, timeline: timeline, authorizedScope: [item.id])
        #expect(result.report.applied.isEmpty && result.timeline == timeline)
        rows.append(["case": "low-fps-slow-motion", "file": lowFPS.displayName, "expected": "refuse", "reasons": result.report.rejected])
        try JSONSerialization.data(withJSONObject: ["corpusCount": assets.count, "checks": rows, "unknownActionsExecuted": 0], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("acceptance-results.json"))
        try JSONSerialization.data(withJSONObject: CinematicCapabilityCatalog.inventory, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("capabilities.json"))
    }

    private func pixels(_ generator: AVAssetImageGenerator, time: Double) throws -> [UInt8] {
        let image = try generator.copyCGImage(at: CMTime(seconds: max(0, time), preferredTimescale: 60_000), actualTime: nil)
        var data = [UInt8](repeating: 0, count: 128 * 72 * 4)
        let context = CGContext(data: &data, width: 128, height: 72, bitsPerComponent: 8, bytesPerRow: 128 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 72))
        return data
    }
}
