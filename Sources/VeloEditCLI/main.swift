import Foundation
import AVFoundation
import VeloEditCore

@main
struct VeloEditCLI {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("Ошибка: \(error.localizedDescription)\n".utf8))
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
            let timeline = try await pipeline.createFilm(prompt: rest.joined(separator: " "), preset: .story)
            print("Timeline: \(timeline.items.count) фрагментов, \(String(format: "%.1f", timeline.duration)) сек")
        case "regenerate":
            let (pipeline, rest) = try openPipeline(arguments, minimum: 3, usage: "regenerate <project.veloedit> <feedback>")
            let timeline = try await pipeline.regenerate(feedback: rest.joined(separator: " "))
            print("Timeline пересобран без повторного анализа: \(timeline.items.count) фрагментов")
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
          create <project.veloedit> [media ...]
          import <project.veloedit> <media ...>
          analyze <project.veloedit>
          benchmark <project.veloedit> <fast|balanced|quality|maximum|all>
          thumbnails <project.veloedit>
          verify <project.veloedit>
          film <project.veloedit> <prompt>
          regenerate <project.veloedit> <feedback>
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
    var errorDescription: String? { if case .usage(let text) = self { return "Использование: \(text)" }; return nil }
}
