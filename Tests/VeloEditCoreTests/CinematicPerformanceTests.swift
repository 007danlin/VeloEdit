import AVFoundation
import Foundation
import Testing
@testable import VeloEditCore

/// Opt-in reproducible measurements. The original search is retained here as
/// an equivalence oracle and a same-process baseline, not a production path.
@Suite(.serialized) struct CinematicPerformanceTests {
    func legacyMatching(_ request: String, base: CinematicKnowledgeBase) -> [CinematicTechnique] {
        let text = CinematicKnowledgeBase.normalized(request)
        return base.cards.filter { card in
            card.aliases.contains { alias in
                (" " + text + " ").contains(" " + CinematicKnowledgeBase.normalized(alias) + " ")
            }
        }.sorted { $0.id < $1.id }
    }

    func legacyRetrieve(_ request: String, base: CinematicKnowledgeBase, features: Set<String>) -> [CinematicTechnique] {
        let explicit = legacyMatching(request, base: base)
        let words = Set(CinematicKnowledgeBase.normalized(request).split(separator: " ").filter { $0.count >= 4 }.map(String.init))
        var ranked: [(card: CinematicTechnique, score: Int)] = []
        for card in base.cards {
            let tokens = Set(CinematicKnowledgeBase.normalized(card.name + " " + card.englishName + " " + card.purpose).split(separator: " ").map(String.init))
            let relevance = words.intersection(tokens).count
            var score = explicit.contains(where: { $0.id == card.id }) ? 100 : 0
            score += relevance * 4
            if relevance > 0 && Set(card.requiredFeatures).isSubset(of: features) { score += 2 }
            if score > 0 { ranked.append((card, score)) }
        }
        ranked.sort { a, b in a.score == b.score ? a.card.id < b.card.id : a.score > b.score }
        return ranked.prefix(3).map(\.card)
    }

    @Test func indexPreservesPhraseMatchingRankingAndCodableUpdates() throws {
        var base = try CinematicKnowledgeBase.load()
        let queries = base.cards.compactMap { $0.aliases.first }.map { "Примени \($0.uppercased()) между клипами" }
            + ["unmatched cutter", "Добавь титр интервью", "Нужна спокойная история", "Без эффектов", ""]
        for query in queries {
            #expect(base.matching(query) == legacyMatching(query, base: base))
            #expect(base.retrieve(request: query, availableFeatures: ["metadata"], limit: 3)
                == legacyRetrieve(query, base: base, features: ["metadata"]))
        }
        base.cards[0].aliases = ["новый уникальный приём"]
        #expect(base.matching("Примени новый уникальный приём").map(\.id) == [base.cards[0].id])
        let restored = try JSONDecoder().decode(CinematicKnowledgeBase.self, from: JSONEncoder().encode(base))
        #expect(restored.matching("Примени новый уникальный приём") == base.matching("Примени новый уникальный приём"))
        for query in queries {
            #expect(CinematicKnowledgeBase.promptContext(request: query, moment: nil).utf8.count <= 1_400)
        }
        #expect(CinematicKnowledgeBase.promptContext(request: "xyzzy", moment: nil).isEmpty)
        let unavailable = CinematicKnowledgeBase.promptContext(request: "Примени Rule of Thirds", moment: nil)
        #expect(unavailable.contains("analysisOnly") && unavailable.contains("allowedCommands"))
    }

    @Test func measureKnowledgeAndAutomaticStyling() throws {
        guard let path = ProcessInfo.processInfo.environment["VELOEDIT_CINEMATIC_PERFORMANCE_OUTPUT"] else { return }
        let loadStart = Date()
        let base = try CinematicKnowledgeBase.load()
        let loadMS = Date().timeIntervalSince(loadStart) * 1_000
        let queries = ["Добавь наплыв между клипами", "Примени Rule of Thirds", "Добавь титр Интервью",
                       "Хочу плёночное зерно", "Нужна связная спокойная история", "Сделай match cut между клипами"]
        func measure(_ count: Int, _ body: (Int) -> Void) -> [String: Double] {
            var samples: [Double] = []
            for index in 0..<count {
                let start = Date(); body(index)
                samples.append(Date().timeIntervalSince(start) * 1_000)
            }
            samples.sort()
            return ["medianMS": samples[samples.count / 2], "p95MS": samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))]]
        }
        var consumed = 0
        let legacy = measure(60) { index in consumed += legacyRetrieve(queries[index % queries.count], base: base, features: []).count }
        let indexed = measure(240) { index in consumed += base.retrieve(request: queries[index % queries.count], availableFeatures: [], limit: 3).count }
        _ = CinematicKnowledgeBase.auditedMatches(queries[0])
        let audit = measure(240) { index in consumed += CinematicKnowledgeBase.auditedMatches(queries[index % queries.count]).count }
        let context = measure(240) { index in consumed += CinematicKnowledgeBase.promptContext(request: queries[index % queries.count], moment: nil).utf8.count }
        let fixture = CinematicAutomaticStylingTests()
        let (plan, timeline, assets, analyses) = fixture.fixture(count: 200)
        let choices = measure(60) { _ in consumed += CinematicAutomaticStyling.choices(plan: plan, assets: assets, analyses: analyses).count }
        let styling = measure(60) { _ in consumed += fixture.decorate(timeline, plan, assets, analyses).effectiveEffects.count }
        let (project, edit) = CinematicKnowledgeTests().fixture()
        let scoped = measure(60) { _ in
            if let plan = CinematicDirector.plan(request: "Добавь виньетку", targetIDs: [edit.items[0].id], project: project, timeline: edit) {
                consumed += CinematicDirector.execute(plan, project: project, timeline: edit, authorizedScope: [edit.items[0].id]).report.applied.count
            }
        }
        let report: [String: Any] = ["edition": base.edition, "configuration": "Swift tests; same-process legacy/indexed comparison",
            "coldLoadIncludingIndexMS": loadMS, "legacyRetrieval": legacy, "indexedRetrieval": indexed,
            "auditMatching": audit, "promptContext": context, "automaticChoices200Clips": choices,
            "automaticDecoration200Clips": styling, "scopedVignettePlanAndExecution": scoped, "consumed": consumed,
            "modelContextSamples": Dictionary(uniqueKeysWithValues: queries.map {
                ($0, CinematicKnowledgeBase.promptContext(request: $0, moment: nil))
            }),
            "retrievalSpeedup": legacy["medianMS"]! / max(0.000001, indexed["medianMS"]!)]
        let destination = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
        print("Cinematic performance: \(report)")
        // Generous bounds catch accidental model/IO/media work in the hot
        // path without pretending that a shared runner is a precision clock.
        #expect(indexed["p95MS"]! < 20)
        #expect(styling["p95MS"]! < 100)
        #expect(scoped["p95MS"]! < 100)
    }

    @Test func measureRealFootageRenderAndPreview() async throws {
        guard let input = ProcessInfo.processInfo.environment["VELOEDIT_CINEMATIC_MEDIA"],
              let reportPath = ProcessInfo.processInfo.environment["VELOEDIT_CINEMATIC_PERFORMANCE_OUTPUT"] else { return }
        let output = URL(fileURLWithPath: reportPath).deletingLastPathComponent().appendingPathComponent("render-comparison")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let asset = try await MediaImporter().makeAsset(url: URL(fileURLWithPath: input).appendingPathComponent("GX010487.MP4"))
        let candidates = (0..<4).map { index in
            Candidate(assetID: asset.id, sourceStart: 2 + Double(index) * 3, sourceDuration: 3,
                scores: .init(quality: 0.9, interest: 0.9, action: 0.1, stability: 0.9),
                insights: .init(dynamics: 0.1, noise: 0.05, shake: 0.05, exposureQuality: 0.9))
        }
        let analysis = AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash,
            candidates: candidates, deepMediaVersion: DeepAnalysisCache.version)
        let plan = StoryPlan(prompt: "Фильм о поездке", preset: .cinematic, constraints: .init(targetDuration: 12), chapters: [],
            directorBrief: .init(requestedDuration: 12, mood: .cinematic, musicPolicy: .none,
                sourceAudioPolicy: .mute, titlePolicy: .none, effectsPolicy: .normal))
        let source = Timeline(storyPlanID: plan.id, width: 1280, height: 720, frameRate: 30,
            items: candidates.enumerated().map { index, candidate in
                .init(candidateID: candidate.id, assetID: asset.id, kind: .video,
                    sourceStart: candidate.sourceStart, sourceDuration: 3, timelineStart: Double(index) * 3,
                    timelineDuration: 3, videoAdjustments: .init(crop: .fit), audioAdjustments: .init(muted: true))
            }, originalAudioVolume: 0, endingFadeDuration: 0)
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let baseline = DirectorEffectsPolicyEngine.decorate(source, plan: plan, candidates: byID)
        let knowledge = DirectorEffectsPolicyEngine.decorate(source, plan: plan, candidates: byID, assets: [asset], analyses: [analysis])
        #expect(baseline.effectiveEffects.first?.effectType == .pushIn)
        #expect(knowledge.effectiveEffects.first?.effectType == .filmGrain)
        var rows: [[String: Any]] = []
        // Alternate order to expose decoder/GPU warm-up instead of attributing
        // all first-run cost to one implementation. No quality setting changes.
        for (index, name) in ["baseline", "knowledge", "knowledge", "baseline", "baseline", "knowledge"].enumerated() {
            let timeline = name == "baseline" ? baseline : knowledge
            let destination = output.appendingPathComponent("\(index)-\(name).mp4")
            try? FileManager.default.removeItem(at: destination)
            let start = Date()
            let playback = try await PlaybackEngine().build(timeline: timeline, assets: [asset], preferStableRealtimePreview: true)
            let previewMS = Date().timeIntervalSince(start) * 1_000
            let renderStart = Date()
            let rendered = try await RenderEngine().render(timeline: timeline, assets: [asset], quality: .preview720p, destination: destination)
            let renderSeconds = Date().timeIntervalSince(renderStart)
            #expect(rendered.skippedItemIDs.isEmpty)
            let movieAsset = AVURLAsset(url: destination)
            let duration = try await movieAsset.load(.duration).seconds
            #expect(abs(duration - 12) < 0.08)
            let live = AVAssetImageGenerator(asset: playback.composition)
            live.videoComposition = playback.videoComposition
            let movie = AVAssetImageGenerator(asset: movieAsset)
            for generator in [live, movie] {
                generator.maximumSize = CGSize(width: 128, height: 72)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
            }
            var errors: [Double] = []
            for time in [0.5, 1.5, 2.5, 7.5, 11.5] {
                let a = try pixels(live, time: time), b = try pixels(movie, time: time)
                let error = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count * 255)
                #expect(error < 0.08, "\(name): \(error)")
                errors.append(error)
            }
            rows.append(["case": name, "previewBuildMS": previewMS, "renderSeconds": renderSeconds,
                "duration": duration, "previewExportError": errors, "effectCount": timeline.effectiveEffects.count,
                "export": destination.lastPathComponent])
        }
        func median(_ name: String) -> Double {
            let times = rows.filter { $0["case"] as? String == name }.compactMap { $0["renderSeconds"] as? Double }.sorted()
            return times[times.count / 2]
        }
        let report: [String: Any] = ["source": asset.displayName, "sourceHash": asset.contentHash,
            "quality": "preview720p; 1280x720; 30fps; 12s; same source ranges and encoder",
            "evidence": "Controlled candidate quality fixture, not a new content-analysis/ASR claim. Source audio explicitly muted in both cases.",
            "scope": "Real decode, preview composition, effects and MP4 encoding. Does not measure source-wide initial AI analysis.",
            "runs": rows, "baselineMedianSeconds": median("baseline"), "knowledgeMedianSeconds": median("knowledge"),
            "relativeRenderChange": median("knowledge") / median("baseline") - 1]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("results.json"), options: .atomic)
        print("Cinematic render performance: baseline \(median("baseline"))s; knowledge \(median("knowledge"))s")
    }

    private func pixels(_ generator: AVAssetImageGenerator, time: Double) throws -> [UInt8] {
        let image = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 60_000), actualTime: nil)
        var data = [UInt8](repeating: 0, count: 128 * 72 * 4)
        let context = CGContext(data: &data, width: 128, height: 72, bitsPerComponent: 8, bytesPerRow: 128 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 72))
        return data
    }
}
