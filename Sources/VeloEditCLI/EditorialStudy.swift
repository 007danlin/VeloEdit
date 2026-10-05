import Foundation
import VeloEditCore

extension VeloEditCLI {
    static func renderEditorialStudy(_ arguments: [String]) async throws {
        guard arguments.count == 3 else { throw CLIError.usage("study-render <experiment.veloedit> <output.mp4>") }
        let package = URL(fileURLWithPath: arguments[1]), output = URL(fileURLWithPath: arguments[2])
        guard FileManager.default.fileExists(atPath: package.appendingPathComponent("study-input.json").path),
              !FileManager.default.fileExists(atPath: output.path) else {
            throw CLIError.verification("Нужна маркированная копия и новый путь экспорта")
        }
        let store = try ProjectStore(open: package, recoveryDirectory: package.appendingPathComponent("StudyRecovery"))
        let music = LocalMusicLibrary(rootURL: package.appendingPathComponent("MusicLibrary"))
        let pipeline = VeloEditPipeline(store: store, musicLibrary: music,
            musicSystem: MusicLibrary(localLibrary: music, providers: [BundledMusicProvider(library: music), LocalMusicProvider(library: music)]),
            musicSelectionHistory: LocalMusicSelectionHistoryStore(url: package.appendingPathComponent("study-music-history.json")),
            personalTasteStore: LocalPersonalTasteStore(url: package.appendingPathComponent("study-taste.json")))
        let timeline = await store.manifest.timelines.last
        let report = try await pipeline.render(to: output, quality: .final1080p,
            frameRate: timeline?.frameRate, progress: printProgress)
        print("Экспорт пользовательской версии: \(report.renderedItemCount) фрагментов; пропущено \(report.skippedItemIDs.count)")
    }

    static func exportDecisionExamples(_ arguments: [String]) async throws {
        guard arguments.count == 3 else { throw CLIError.usage("decision-examples <experiment.veloedit> <examples.json>") }
        let package = URL(fileURLWithPath: arguments[1])
        let project = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: package.appendingPathComponent("project.json")))
        guard let original = project.timelines.last,
              let plan = project.storyPlans.first(where: { $0.id == original.storyPlanID }) else {
            throw CLIError.verification("Нет фильма с планом")
        }
        struct Example: Codable {
            var name: String
            var provenance: String
            var features: EditingDecisionFeatures
            var legacyScore: Double
            var chronology: EditorialChronologyReport
            var timeline: Timeline
        }
        struct Export: Codable {
            var schemaVersion = EditingDecisionFeatures.schemaVersion
            var projectID: UUID
            var sourceHashes: [String]
            var featureNames: [String]
            var examples: [Example]
        }
        var variants: [(String, String, Timeline)] = [("production", "actual exported production timeline", original)]
        let primary = original.items.filter { $0.overlay == nil && $0.kind != .title }
        if primary.count >= 2 {
            var reverse = original
            reverse.items = Array(primary.reversed())
            var repeatShot = original
            repeatShot.items = primary
            var duplicate = primary[0]; duplicate.id = UUID()
            repeatShot.items[1] = duplicate
            var shortened = original
            shortened.items = primary.map { item in
                var copy = item
                copy.sourceStart += item.sourceDuration * 0.25
                copy.sourceDuration *= 0.5
                copy.timelineDuration *= 0.5
                return copy
            }
            for (name, var timeline) in [("reversed-order", reverse), ("repeated-source-range", repeatShot), ("cut-boundaries", shortened)] {
                var cursor = 0.0
                for i in timeline.items.indices {
                    timeline.items[i].timelineStart = cursor
                    timeline.items[i].transition = nil
                    cursor += timeline.items[i].timelineDuration
                }
                timeline.editorialReview = nil
                timeline.filmDeliveryReport = nil
                variants.append((name, "controlled counterfactual; not a human preference; not rendered", timeline))
            }
        }
        let examples = variants.map { name, provenance, timeline in
            Example(name: name, provenance: provenance,
                features: .extract(timeline: timeline, assets: project.assets, analyses: project.analyses),
                legacyScore: DefaultMontageGlobalScorer().score(plan: plan, timeline: timeline, assets: project.assets, analyses: project.analyses).total,
                chronology: .inspect(timeline: timeline, assets: project.assets), timeline: timeline)
        }
        let export = Export(projectID: project.id, sourceHashes: project.assets.map { $0.fullContentHash ?? $0.contentHash },
            featureNames: EditingDecisionFeatures.names, examples: examples)
        try JSONEncoder.veloEdit.encode(export).write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
        print("Экспортировано примеров: \(examples.count); человеческих оценок: 0")
    }

    /// Uses the production pipeline with isolated, offline music/taste stores.
    /// The marker prevents accidentally running a study against a user project.
    static func runEditorialStudy(_ arguments: [String]) async throws {
        guard arguments.count == 3 else {
            throw CLIError.usage("study-film <experiment.veloedit> <output.mp4>")
        }
        let package = URL(fileURLWithPath: arguments[1])
        guard FileManager.default.fileExists(atPath: package.appendingPathComponent("study-input.json").path) else {
            throw CLIError.verification("Требуется отдельная копия проекта с study-input.json")
        }
        let output = URL(fileURLWithPath: arguments[2])
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw CLIError.verification("Существующий экспорт сохранён: \(output.path)")
        }
        let store = try ProjectStore(open: package, recoveryDirectory: package.appendingPathComponent("StudyRecovery"))
        let music = LocalMusicLibrary(rootURL: package.appendingPathComponent("MusicLibrary"))
        let pipeline = VeloEditPipeline(store: store, musicLibrary: music,
            musicSystem: MusicLibrary(localLibrary: music, providers: [BundledMusicProvider(library: music), LocalMusicProvider(library: music)]),
            musicSelectionHistory: LocalMusicSelectionHistoryStore(url: package.appendingPathComponent("study-music-history.json")),
            personalTasteStore: LocalPersonalTasteStore(url: package.appendingPathComponent("study-taste.json")))
        let initial = await store.manifest
        let prompt = initial.workspaceState?.prompt ?? "Сделай связный фильм из лучших моментов. Начни спокойно, затем добавь динамики и закончи красивым финалом."
        let brief = initial.workspaceState?.directorBrief
        let started = ProcessInfo.processInfo.systemUptime
        var rows: [[String: Any]] = []
        var stage = "film"
        var stageStarted = started
        func save(_ error: String? = nil) throws {
            var result: [String: Any] = ["schemaVersion": 1, "prompt": prompt, "stages": rows,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "musicProviders": ["bundled", "local"], "taste": "isolated-empty; no human labels",
                "quality": "final1080p", "humanFullPlaybackReview": false]
            if let error { result["error"] = error }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: package.appendingPathComponent("study-result.json"), options: .atomic)
        }
        do {
            let timeline = try await pipeline.createFilm(prompt: prompt,
                preset: initial.workspaceState?.preset ?? .adventure,
                targetDuration: brief?.explicitRequestedDuration, directorBrief: brief, progress: printFilmProgress)
            rows.append(["stage": stage, "seconds": ProcessInfo.processInfo.systemUptime - stageStarted,
                "duration": timeline.duration, "items": timeline.items.count, "status": "success"])
            try save()
            stage = "export"; stageStarted = ProcessInfo.processInfo.systemUptime
            let report = try await pipeline.render(to: output, quality: .final1080p, frameRate: timeline.frameRate, progress: printProgress)
            rows.append(["stage": stage, "seconds": ProcessInfo.processInfo.systemUptime - stageStarted,
                "items": report.renderedItemCount, "skipped": report.skippedItemIDs.count, "status": "success"])
            try save()
        } catch {
            rows.append(["stage": stage, "seconds": ProcessInfo.processInfo.systemUptime - stageStarted, "status": "failed"])
            try? save(error.localizedDescription)
            throw error
        }
    }
}
