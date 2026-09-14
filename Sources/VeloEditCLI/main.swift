import Foundation
import AVFoundation
import VeloEditCore

@main
struct VeloEditCLI {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            let nsError = error as NSError
            let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map {
                " [\($0.domain) \($0.code): \($0.localizedDescription)]"
            } ?? ""
            FileHandle.standardError.write(Data("Ошибка: \(error.localizedDescription) [\(nsError.domain) \(nsError.code)]\(underlying)\n".utf8))
            exit(1)
        }
    }

    static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else { printHelp(); return }
        switch command {
        case "help", "--help", "-h": printHelp()
        case "create":
            guard arguments.count >= 2 else { throw CLIError.usage("create <project.veloedit> [media ...]") }
            let url = projectURL(arguments[1])
            let store = try ProjectStore(createAt: url, name: url.deletingPathExtension().lastPathComponent)
            let pipeline = VeloEditPipeline(store: store)
            if arguments.count > 2 {
                let errors = try await pipeline.importMedia(arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }, progress: printProgress)
                errors.forEach { print("Пропущено: \($0)") }
            }
            print("Создан проект: \(url.path)")
        case "import":
            let (pipeline, rest) = try openPipeline(arguments, minimum: 3, usage: "import <project.veloedit> <media ...>")
            let errors = try await pipeline.importMedia(rest.map { URL(fileURLWithPath: $0) }, progress: printProgress)
            print(errors.isEmpty ? "Импорт завершён" : "Импорт завершён с ошибками: \(errors.count)")
        case "analyze":
            let (pipeline, _) = try openPipeline(arguments, minimum: 2, usage: "analyze <project.veloedit>")
            let count = try await pipeline.analyzeMissing(progress: printProgress)
            print("Проанализировано новых файлов: \(count)")
        case "prepare-editorial":
            let (pipeline, rest) = try openPipeline(arguments, minimum: 2, usage: "prepare-editorial <project.veloedit> [duration-seconds]")
            let duration = rest.first.flatMap(Double.init)
            let count = try await pipeline.prepareEditorialIntelligence(requestedDuration: duration)
            let current = await pipeline.store.manifest
            let context = EditorialAnalysisContext(analyses: current.analyses)
            let target = duration
                ?? current.workspaceState?.directorBrief?.explicitRequestedDuration
                ?? current.storyPlans.last?.directorBrief?.requestedDuration
            let budget = ContentBudgetEngine().budget(
                units: context.units,
                families: context.families,
                requestedDuration: target,
                requestIsExplicit: target != nil,
                style: DirectorStyleVector()
            )
            print("Editorial evidence подготовлено; добавлено монтажных диапазонов: \(count)")
            print("Всего диапазонов: \(context.units.count); подтверждённая ёмкость: \(String(format: "%.1f", budget.supportedDuration)) сек; целевой монтаж: \(String(format: "%.1f", budget.budget.idealDuration)) сек")
        case "benchmark":
            try await benchmark(arguments)
        case "thumbnails":
            let (pipeline, _) = try openPipeline(arguments, minimum: 2, usage: "thumbnails <project.veloedit>")
            let errors = await pipeline.generateThumbnails(progress: printProgress)
            errors.forEach { print("Предупреждение: \($0)") }
            print(errors.isEmpty ? "Превью исходников готовы" : "Превью готовы с предупреждениями: \(errors.count)")
        case "verify":
            let (pipeline, _) = try openPipeline(arguments, minimum: 2, usage: "verify <project.veloedit>")
            let count = try await pipeline.verifyFullHashes(progress: printProgress)
            print("Полный SHA-256 проверен для файлов: \(count)")
        case "film":
            let (pipeline, rest) = try openPipeline(arguments, minimum: 3, usage: "film <project.veloedit> <prompt>")
            let current = await pipeline.store.manifest
            let savedBrief = current.workspaceState?.directorBrief
            let timeline = try await pipeline.createFilm(
                prompt: rest.joined(separator: " "),
                preset: current.workspaceState?.preset ?? .story,
                targetDuration: savedBrief?.explicitRequestedDuration,
                directorBrief: savedBrief,
                progress: printFilmProgress
            )
            print("Timeline: \(timeline.items.count) фрагментов, \(String(format: "%.1f", timeline.duration)) сек")
        case "save-video":
            let (pipeline, _) = try openPipeline(arguments, minimum: 2, usage: "save-video <project.veloedit>")
            let destination = await pipeline.defaultVideoDestination()
            let timeline = await pipeline.store.manifest.timelines.last
            let report = try await pipeline.render(to: destination, quality: .maximum, frameRate: timeline?.frameRate, progress: printProgress)
            print("Проверенное видео: \(report.outputURL.path)")
        case "resume-export":
            let (pipeline, _) = try openPipeline(arguments, minimum: 2, usage: "resume-export <project.veloedit>")
            if let report = try await pipeline.resumeExport(progress: printProgress) { print("Видео сохранено: \(report.outputURL.path)") }
        case "collect":
            let (pipeline, rest) = try openPipeline(arguments, minimum: 3, usage: "collect <project.veloedit> <copy.veloedit>")
            let output = try await pipeline.collectProjectCopy(to: projectURL(rest[0]), progress: printProgress)
            print("Копия проекта: \(output.path)")
        case "resume-film":
            let (pipeline, _) = try openPipeline(arguments, minimum: 2, usage: "resume-film <project.veloedit>")
            let timeline = try await pipeline.resumeFilmBuild(progress: printFilmProgress)
            print("Timeline восстановлен: \(timeline.items.count) фрагментов, \(String(format: "%.1f", timeline.duration)) сек")
        case "use-title-reference":
            let (pipeline, rest) = try openPipeline(arguments, minimum: 3, usage: "use-title-reference <project.veloedit> <reference.veloedit> [name]")
            guard let referencePath = rest.first else { throw CLIError.usage("Укажите проект-образец") }
            let referenceStore = try ProjectStore(open: projectURL(referencePath))
            let referenceProject = await referenceStore.manifest
            guard let timeline = referenceProject.timelines.last,
                  let reference = ChapterTitleReference(name: rest.dropFirst().first ?? referenceProject.name,
                    timeline: timeline, assets: referenceProject.assets) else {
                throw CLIError.verification("В образце нет единообразных титров глав")
            }
            try await pipeline.store.update { $0.preferences.chapterTitleReference = reference }
            print("Образец титров «\(reference.name)» сохранён; распознано исходников: \(reference.labelsByContentHash.count)")
        case "learn-approved-reference":
            guard arguments.count >= 2 else { throw CLIError.usage("learn-approved-reference <approved-project.veloedit> [taste-profile.json]") }
            // Decode read-only: learning must not migrate or mutate the example.
            let data = try Data(contentsOf: projectURL(arguments[1]).appendingPathComponent("project.json"))
            let project = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: data)
            guard let timeline = project.timelines.last,
                  let example = ApprovedReferenceLearning(timeline: timeline, assets: project.assets, analyses: project.analyses) else {
                throw CLIError.verification("В одобренном проекте нет пригодного примера монтажа")
            }
            let tasteURL = arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : LocalPersonalTasteStore.defaultURL
            let taste = LocalPersonalTasteStore(url: tasteURL)
            let result = try await taste.recordValidated(example.signals, regressionSample: nil, approvedReferenceFingerprint: example.fingerprint)
            print(result.report.committed ? "Одобренный пример учтён: \(example.signals.count) наблюдений. Профиль: \(tasteURL.path)" : result.report.reasons.joined(separator: "; "))
        case "regenerate":
            let (pipeline, rest) = try openPipeline(arguments, minimum: 3, usage: "regenerate <project.veloedit> <feedback>")
            let timeline = try await pipeline.regenerate(feedback: rest.joined(separator: " "))
            print("Timeline пересобран без повторного анализа: \(timeline.items.count) фрагментов")
        case "productionize":
            guard arguments.count >= 3 else { throw CLIError.usage("productionize <project.veloedit> <backup-directory>") }
            let package = projectURL(arguments[1])
            let backupRoot = URL(fileURLWithPath: arguments[2])
            let backup = try EditorialProjectMigration.prepare(packageURL: package, backupRoot: backupRoot)
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("VeloEditProduction-\(UUID().uuidString).veloedit")
            try FileManager.default.copyItem(at: backup.backupURL, to: staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            let store = try ProjectStore(open: staging)
            let pipeline = VeloEditPipeline(store: store)
            _ = try await pipeline.analyzeMissing(progress: printProgress)
            let current = await store.manifest
            let prompt = current.workspaceState?.prompt ?? current.storyPlans.last?.prompt ?? "Создай законченный фильм из лучших неповторяющихся моментов"
            let timeline = try await pipeline.createFilm(
                prompt: prompt,
                preset: current.workspaceState?.preset ?? .story,
                targetDuration: current.workspaceState?.directorBrief?.explicitRequestedDuration,
                directorBrief: current.workspaceState?.directorBrief
            )
            guard timeline.editorialReview?.productionEligible == true,
                  timeline.editorialReview?.blockingUnknowns.isEmpty == true else {
                throw CLIError.verification("Новый Timeline не прошёл автоматическую production-проверку")
            }
            let staged = await store.manifest
            guard let plan = staged.storyPlans.first(where: { $0.id == timeline.storyPlanID }) else {
                throw CLIError.verification("Для проверенного Timeline отсутствует StoryPlan")
            }
            try EditorialProjectMigration.activateAutomatically(candidate: timeline, plan: plan, analyses: staged.analyses, backup: backup)
            let activated = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: package.appendingPathComponent("project.json")))
            guard activated.timelines.last?.id == timeline.id,
                  activated.timelines.last?.editorialRegeneration?.activationMethod == "automated-rendered-verifier" else {
                throw CLIError.verification("Проверенный Timeline не стал новой активной версией")
            }
            print("Активирован Editorial V2: \(timeline.items.count) фрагментов, \(String(format: "%.1f", timeline.duration)) сек")
            print("Backup: \(backup.backupURL.path)")
        case "activate-verified":
            guard arguments.count >= 4 else {
                throw CLIError.usage("activate-verified <verified-project.veloedit> <project.veloedit> <backup-directory>")
            }
            let verifiedPackage = projectURL(arguments[1])
            let destinationPackage = projectURL(arguments[2])
            let backupRoot = URL(fileURLWithPath: arguments[3])
            let verifiedData = try Data(contentsOf: verifiedPackage.appendingPathComponent("project.json"))
            let verified = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: verifiedData)
            guard let timeline = verified.timelines.last,
                  let plan = verified.storyPlans.first(where: { $0.id == timeline.storyPlanID }),
                  timeline.editorialReview?.productionEligible == true,
                  timeline.editorialReview?.blockingUnknowns.isEmpty == true,
                  timeline.editorialReview?.editorialSignature == EditorialRenderSignature.signature(timeline) else {
                throw CLIError.verification("Источник не содержит последний Timeline с действующей production-проверкой")
            }
            let destinationData = try Data(contentsOf: destinationPackage.appendingPathComponent("project.json"))
            let destination = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: destinationData)
            guard destination.id == verified.id else {
                throw CLIError.verification("Проверенный Timeline относится к другому проекту")
            }
            let backup = try EditorialProjectMigration.prepare(packageURL: destinationPackage, backupRoot: backupRoot)
            try EditorialProjectMigration.activateAutomatically(candidate: timeline, plan: plan, analyses: verified.analyses, backup: backup)
            let activated = try JSONDecoder.veloEdit.decode(
                ProjectManifest.self,
                from: Data(contentsOf: destinationPackage.appendingPathComponent("project.json"))
            )
            guard activated.timelines.last?.id == timeline.id,
                  activated.timelines.last?.editorialRegeneration?.activationMethod == "automated-rendered-verifier" else {
                throw CLIError.verification("Проверенный Timeline не стал новой активной версией")
            }
            print("Перенесён и активирован проверенный Editorial V2: \(timeline.items.count) фрагментов, \(String(format: "%.1f", timeline.duration)) сек")
            print("Backup: \(backup.backupURL.path)")
        case "edit":
            let (pipeline, rest) = try openPipeline(arguments, minimum: 3, usage: "edit <project.veloedit> <request>")
            let report = try await pipeline.applyEditorCommands(rest.joined(separator: " "))
            print(report.chatSummary)
            print("Распознано: \(report.recognizedCount); изменено элементов: \(report.affectedItemIDs.count)")
        case "fcpxml":
            let (pipeline, rest) = try openPipeline(arguments, minimum: 3, usage: "fcpxml <project.veloedit> <output.fcpxml>")
            guard let outputPath = rest.first else { throw CLIError.usage("fcpxml <project.veloedit> <output.fcpxml>") }
            let output = URL(fileURLWithPath: outputPath)
            try await pipeline.exportFCPXML(to: output)
            print("FCPXML: \(output.path)")
        case "render":
            let (pipeline, rest) = try openPipeline(arguments, minimum: 3, usage: "render <project.veloedit> <output.mp4>")
            guard let outputPath = rest.first else { throw CLIError.usage("render <project.veloedit> <output.mp4>") }
            let report = try await pipeline.render(to: URL(fileURLWithPath: outputPath), quality: .preview720p, progress: printProgress)
            print("Видео: \(report.outputURL.path); clips: \(report.renderedItemCount); skipped: \(report.skippedItemIDs.count)")
        case "playback":
            let (pipeline, _) = try openPipeline(arguments, minimum: 2, usage: "playback <project.veloedit>")
            let playback = try await pipeline.makePlayback(progress: printProgress)
            let geometry = playback.videoComposition == nil ? "native-track" : "per-clip-transform"
            print("Просмотр: \(playback.renderedItemCount) фрагментов, \(String(format: "%.1f", playback.duration)) сек; пропущено: \(playback.skippedItemIDs.count); геометрия: \(geometry)")
        case "playback-frame":
            let (pipeline, _) = try openPipeline(arguments, minimum: 2, usage: "playback-frame <project.veloedit>")
            let playback = try await pipeline.makePlayback(progress: printProgress)
            let generator = AVAssetImageGenerator(asset: playback.composition)
            generator.videoComposition = playback.videoComposition
            generator.appliesPreferredTrackTransform = playback.videoComposition == nil
            let second = min(max(0.1, playback.duration * 0.12), max(0.1, playback.duration - 0.1))
            let image = try generator.copyCGImage(
                at: CMTime(seconds: second, preferredTimescale: 600),
                actualTime: nil
            )
            print("Кадр просмотра готов: \(image.width)×\(image.height), \(String(format: "%.1f", second)) сек")
        case "fixtures":
            guard arguments.count >= 2 else { throw CLIError.usage("fixtures <directory>") }
            let outputs = try FCPXMLFixtureFactory().writeAll(to: URL(fileURLWithPath: arguments[1]))
            print("Создано FCPXML fixtures: \(outputs.count)")
        case "diagnose":
            let (pipeline, _) = try openPipeline(arguments, minimum: 2, usage: "diagnose <project.veloedit>")
            print(await pipeline.diagnostics())
        default: throw CLIError.usage("Неизвестная команда: \(command)")
        }
    }

    static func openPipeline(_ arguments: [String], minimum: Int, usage: String) throws -> (VeloEditPipeline, ArraySlice<String>) {
        guard arguments.count >= minimum else { throw CLIError.usage(usage) }
        let store = try ProjectStore(open: projectURL(arguments[1]))
        return (VeloEditPipeline(store: store), arguments.dropFirst(2))
    }

    static func projectURL(_ path: String) -> URL {
        let url = URL(fileURLWithPath: path)
        return url.pathExtension == ProjectStore.packageExtension ? url : url.appendingPathExtension(ProjectStore.packageExtension)
    }

    static let printProgress: @Sendable (ImportProgress) -> Void = { progress in
        var context: [String] = []
        if let file = progress.currentFileIndex, let count = progress.fileCount { context.append("файл \(file)/\(count)") }
        if let scene = progress.currentSceneIndex, let count = progress.sceneCount { context.append("сцена \(scene)/\(count)") }
        if let eta = progress.estimatedSecondsRemaining { context.append(String(format: "ETA %.0f s", eta)) }
        let suffix = context.isEmpty ? "" : " · " + context.joined(separator: " · ")
        FileHandle.standardError.write(Data("[\(progress.completed)/\(progress.total)] \(progress.currentName)\(suffix)\n".utf8))
    }

    static let printFilmProgress: FilmBuildProgressHandler = { update in
        let parts = [update.stage.title, update.countLabel, update.detail ?? ""].filter { !$0.isEmpty }
        FileHandle.standardOutput.write(Data((parts.joined(separator: " · ") + "\n").utf8))
    }

    static func benchmark(_ arguments: [String]) async throws {
        guard arguments.count >= 3 else { throw CLIError.usage("benchmark <project.veloedit> <fast|balanced|quality|maximum|all>") }
        let store = try ProjectStore(open: projectURL(arguments[1]))
        let original = await store.manifest
        let modes: [AIPowerMode]
        if arguments[2] == "all" {
            modes = AIPowerMode.allCases
        } else if let mode = AIPowerMode(rawValue: arguments[2]) {
            modes = [mode]
        } else {
            throw CLIError.usage("benchmark <project.veloedit> <fast|balanced|quality|maximum|all>")
        }
        var rows: [AnalysisBenchmarkRow] = []
        do {
            for mode in modes {
                try await store.update { project in
                    project.preferences.aiPowerMode = mode
                    project.analyses = []
                    project.analysisQueue = []
                }
                let pipeline = VeloEditPipeline(store: store)
                _ = try await pipeline.analyzeMissing(progress: printProgress)
                let measured = await pipeline.snapshot()
                if let row = AnalysisBenchmarkRow(mode: mode, assets: measured.assets, analyses: measured.analyses) {
                    rows.append(row)
                }
            }
        } catch {
            try? await restoreBenchmarkState(original, in: store)
            throw error
        }
        try await restoreBenchmarkState(original, in: store)
        print(AnalysisBenchmarkReport(rows: rows).tabSeparatedText)
    }

    static func restoreBenchmarkState(_ original: ProjectManifest, in store: ProjectStore) async throws {
        try await store.update { project in
            project.preferences = original.preferences
            project.analyses = original.analyses
            project.analysisQueue = original.analysisQueue
            project.sourceMap = original.sourceMap
            project.events = original.events
        }
    }

    static func printHelp() {
        print("""
        VeloEdit CLI
          use-title-reference <project.veloedit> <reference.veloedit> [name]
          learn-approved-reference <approved-project.veloedit> [taste-profile.json]
          create <project.veloedit> [media ...]
          import <project.veloedit> <media ...>
          analyze <project.veloedit>
          prepare-editorial <project.veloedit> [duration-seconds]
          benchmark <project.veloedit> <fast|balanced|quality|maximum|all>
          thumbnails <project.veloedit>
          verify <project.veloedit>
          film <project.veloedit> <prompt>
          resume-film <project.veloedit>
          save-video <project.veloedit>
          resume-export <project.veloedit>
          collect <project.veloedit> <copy.veloedit>
          regenerate <project.veloedit> <feedback>
          productionize <project.veloedit> <backup-directory>
          activate-verified <verified-project.veloedit> <project.veloedit> <backup-directory>
          edit <project.veloedit> <request>
          render <project.veloedit> <output.mp4>
          playback <project.veloedit>
          playback-frame <project.veloedit>
          fcpxml <project.veloedit> <output.fcpxml>
          fixtures <directory>
          diagnose <project.veloedit>
        """)
    }
}

enum CLIError: LocalizedError {
    case usage(String)
    case verification(String)
    var errorDescription: String? {
        switch self {
        case .usage(let text): return "Использование: \(text)"
        case .verification(let text): return text
        }
    }
}
