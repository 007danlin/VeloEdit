import Foundation
import Testing
import VeloEditCore
@testable import VeloEdit

/// Opt-in runtime study. Synthetic context is explicitly labelled; this is not
/// a human quality assessment or a playback/UI performance measurement.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_LIVE_STUDY_OUTPUT"] != nil))
func measureDirectorLiveAdvice() async throws {
    let output = try #require(ProcessInfo.processInfo.environment["VELOEDIT_LIVE_STUDY_OUTPUT"])
    let questions = ["Здесь затянуто?", "Как тебе этот момент?", "Что здесь не так?", "Почему так резко?", "Этот кадр плохой?", "Убрать паузу?", "Слишком медленно?", "Какой дубль лучше?", "Мне не нравится конец", "Оставить этот план?", "Что слышно?", "Какая музыка подойдёт?", "Почему ты убрал конец?", "Как назвать фильм?", "Пауза хорошая?", "Склейка удачная?", "Нужен переход?", "Что скажешь о начале?", "Речь не обрезана?", "Где лучше закончить?", "Не слишком быстро?", "Нравится ли тебе цвет?", "Звук мешает?", "Можно оставить тишину?", "Что думаешь о всём фильме?", "Не меняй ничего, оцени конец", "Сравни первые два клипа", "Зачем здесь эффект?", "Кадр стоит сохранить?", "Можно обойтись без музыки?"]
    let basicContext = DirectorContext(assetCount: 3, videoCount: 3, photoCount: 0, analyzedCount: 3,
        candidateCount: 12, currentTimelineItemCount: 3, targetDuration: 30, preset: .story,
        currentOperation: "Ожидание", selectedItemSummary: "Второй клип, 5 секунд", playheadTime: 8,
        neighboringItemSummaries: ["Вступление, 3 секунды", "Финал, 4 секунды"], contentHints: ["велосипед"], audioHints: ["смех: 1 эпиз."])
    struct Row: Codable { let index: Int; let repetition: Int; let variant: String; let request: String; let seconds: Double; let runtime: String; let reply: String; let commands: Int; let contextSeconds: Double; let evidenceCount: Int; let fallback: Bool }
    var sourceProjects: [ProjectManifest] = []
    let paths: [String]
    if let list = ProcessInfo.processInfo.environment["VELOEDIT_LIVE_STUDY_PROJECTS"] {
        paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: list)))
    } else { paths = ProcessInfo.processInfo.environment["VELOEDIT_LIVE_STUDY_PROJECT"].map { [$0] } ?? [] }
    for source in paths {
        sourceProjects.append(try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: URL(fileURLWithPath: source))))
    }
    let indices = sourceProjects.map { DirectorMomentIndex(project: $0, revision: 1) }
    if ProcessInfo.processInfo.environment["VELOEDIT_LIVE_STUDY_WARM"] == "1" {
        try await LocalAIModelManager.shared.warmUp(model: LocalDirectorAgent.ollamaModel)
    }
    var corpus: [DirectorMomentContext] = []
    var rows: [Row] = []
    let repetitions = Int(ProcessInfo.processInfo.environment["VELOEDIT_LIVE_STUDY_REPEATS"] ?? "3") ?? 3
    let limit = Int(ProcessInfo.processInfo.environment["VELOEDIT_LIVE_STUDY_LIMIT"] ?? "30") ?? 30
    let selectedIndices = ProcessInfo.processInfo.environment["VELOEDIT_LIVE_STUDY_INDICES"].map {
        Set($0.split(separator: ",").compactMap { Int($0) })
    }
    for repetition in 0..<repetitions {
        for (index, prompt) in questions.prefix(limit).enumerated() {
            if let selectedIndices, !selectedIndices.contains(index) { continue }
            let sourceProject = sourceProjects.isEmpty ? nil : sourceProjects[index % sourceProjects.count]
            let momentIndex = indices.isEmpty ? nil : indices[index % indices.count]
            var context = basicContext
            let contextStart = ProcessInfo.processInfo.systemUptime
            if let project = sourceProject, let timeline = project.timelines.last, !timeline.items.isEmpty {
                let selected = timeline.items[index % timeline.items.count]
                context = DirectorContext(assetCount: project.assets.count, videoCount: project.assets.filter { $0.kind == .video }.count,
                    photoCount: project.assets.filter { $0.kind == .photo }.count, analyzedCount: project.analyses.count,
                    candidateCount: project.analyses.reduce(0) { $0 + $1.candidates.count }, currentTimelineItemCount: timeline.items.count,
                    currentMusicTrackTitle: timeline.music?.trackTitle, targetDuration: timeline.duration, preset: .story,
                    currentOperation: "Ожидание", selectedItemSummary: "\(selected.storyRole?.rawValue ?? selected.kind.rawValue), \(selected.timelineDuration) секунд",
                    playheadTime: selected.timelineStart, contentHints: Array(Set(project.analyses.flatMap { $0.sceneTags })).sorted().prefix(10).map { $0 })
                context.moment = momentIndex?.resolve(prompt: prompt, selectedID: selected.id, playhead: selected.timelineStart)
                if repetition == 0, let moment = context.moment { corpus.append(moment) }
            }
            let contextSeconds = ProcessInfo.processInfo.systemUptime - contextStart
            let paired = ProcessInfo.processInfo.environment["VELOEDIT_LIVE_STUDY_PAIRED"] == "1"
            let variants = paired ? ((index + repetition) % 2 == 0 ? ["baseline", "new"] : ["new", "baseline"])
                : [ProcessInfo.processInfo.environment["VELOEDIT_LIVE_STUDY_BASELINE"] == "1" ? "baseline" : "new"]
            for variant in variants {
                let trace = PerformanceTrace(name: "director.runtime-study.\(variant)", projectID: sourceProject?.id)
                let started = ProcessInfo.processInfo.systemUptime
                let reply = await PerformanceTrace.$current.withValue(trace) {
                    if variant == "baseline" {
                        return await BaselineDirectorStudyAgent().respond(to: prompt, context: context, mode: .advisory)
                    }
                    return await LocalDirectorAgent().respond(to: prompt, context: context, mode: .advisory)
                }
                trace.finish(status: reply.isFallback ? "fallback" : "success")
                rows.append(Row(index: index, repetition: repetition, variant: variant, request: prompt,
                    seconds: ProcessInfo.processInfo.systemUptime - started, runtime: reply.runtimeLabel,
                    reply: reply.text, commands: reply.commands.count, contextSeconds: contextSeconds,
                    evidenceCount: context.moment?.facts.count ?? 0,
                    fallback: reply.isFallback || !reply.runtimeLabel.contains("Qwen")))
                try JSONEncoder().encode(rows).write(to: URL(fileURLWithPath: output), options: .atomic)
                #expect(reply.commands.isEmpty)
            }
            if !corpus.isEmpty {
                try JSONEncoder().encode(corpus).write(to: URL(fileURLWithPath: output + ".contexts.json"), options: .atomic)
            }
        }
    }
}
