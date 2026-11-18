import Foundation
import Testing
import VeloEditCore
@testable import VeloEdit

@MainActor struct EverydayDirectorReliabilityTests {
    private var context: DirectorContext {
        DirectorContext(assetCount: 3, videoCount: 3, photoCount: 0, analyzedCount: 3, candidateCount: 3,
            currentTimelineItemCount: 3, targetDuration: 12, preset: .story, currentOperation: "test")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REAL_COMMENT_DIRECTOR"] == "1"))
    func liveDirectorInterpretsCameraMovementInOrder() async throws {
        let prompt = "Можешь оживить все пять планов движением камеры? Пусть она то приближается, то отъезжает, то уходит вбок. Хочется, чтобы это движение чередовалось по ходу ролика."
        let reply = await LocalDirectorAgent().respond(to: prompt, context: context)
        #expect(!reply.planningFailed)
        #expect(reply.commands.count == 1)
        guard case .setEffectPattern(let moves, .all) = reply.commands.first else {
            Issue.record("Ожидались чередующиеся движения для всего фильма: \(reply.commands)")
            return
        }
        #expect(moves.count >= 3)
        #expect([ClipEffect.pushIn, .zoomIn].contains(moves.first))
        #expect([ClipEffect.pullOut, .zoomOut].contains(moves.dropFirst().first))
        #expect(moves.contains(.panLeft) || moves.contains(.panRight))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REAL_COMMENT_DIRECTOR"] == "1"))
    func liveDirectorCombinesOpeningAndMusicEnding() async {
        let prompt = "Хочется сразу задать темп — сделай вступление поэнергичнее, а под конец пусть музыка постепенно сойдёт на нет."
        let parsed = EditorCommandParser().parse(prompt)
        let reply = await LocalDirectorAgent().respond(to: prompt, context: context)
        let plan = parsed + EditorCommand.supplemental(reply.commands, to: parsed)
        #expect(!reply.planningFailed)
        #expect(Set(plan) == [.tightenCut(.first), .setMusicEndingFade(4)])
        let timeline = Timeline(storyPlanID: UUID(), items: (0..<5).map {
            TimelineItem(kind: .video, sourceDuration: 3, timelineStart: Double($0 * 3), timelineDuration: 3)
        }, music: MusicDirective(style: .acoustic, bpm: 100))
        let input = NaturalLanguageDirectorInput(userRequest: prompt,
            currentProject: ProjectManifest(name: "Проверка", timelines: [timeline]), timeline: timeline)
        let director = NaturalLanguageDirector()
        let edit = director.plan(input: input, supplementalCommands: reply.commands)
        #expect(!edit.requiresBackgroundRefinement)
        let result = director.execute(plan: edit, input: input)
        #expect(result.committed && result.commandReport.applied.count == 2)
        #expect(result.timeline.items.map(\.timelineDuration) == [2.25, 3, 3, 3, 3])
        #expect(result.timeline.musicEndingFadeDuration == 4)
    }

    @Test func endingMusicEditsKeepTheTrackAndOpeningScope() {
        let parser = EditorCommandParser()
        #expect(parser.parseComplete("Сделай начало бодрее, а в конце плавно убери музыку", hasSelection: false)
            == [.tightenCut(.first), .setMusicEndingFade(4)])
        #expect(parser.parse("В конце плавно убери музыку") == [.setMusicEndingFade(4)])
        #expect(parser.parse("Убери музыку") == [.setMusic(nil)])
        #expect(parser.parseComplete("Пусть в конце музыка затихнет, если там есть диалог", hasSelection: false) == nil)
    }

    @Test func semanticVisualPlansCoverWholeSequencesAndDelegateOtherScope() throws {
        let motion = "Можешь оживить все пять планов движением камеры? Пусть она то приближается, то отъезжает, то уходит вбок. Хочется, чтобы это движение чередовалось по ходу ролика."
        #expect(FilmWideVisualPlan.canInterpret(motion, context: context))
        #expect(!FilmWideVisualPlan.canInterpret(motion + " Только в 00:04–00:06.", context: context))
        #expect(!FilmWideVisualPlan.canInterpret("Ускорь первый клип и добавь переходы во всем фильме", context: context))
        #expect(try FilmWideVisualPlan.commands(from: #"{"coverage":"whole-film","motion":["push-in","pull-out","pan-left"],"cuts":[]}"#) == [.setEffectPattern([.pushIn, .pullOut, .panLeft], .all)])
        #expect(try FilmWideVisualPlan.commands(from: #"{"coverage":"other","motion":["zoom-in"],"cuts":[]}"#) == nil)
        #expect(try FilmWideVisualPlan.commands(from: #"{"coverage":"whole-film","motion":[],"cuts":["cross-dissolve"]}"#) == [.setTransition(.crossDissolve, .all)])
    }

    @Test(arguments: [
        "еще хочу эффект камеры в первом видео", "Можешь добавить эффект видеокамеры во втором видео?",
        "Добавь эффект «Видеокамера» в первом видео; громкость музыки 20%",
        "Ускорь первый клип в 2 раза. Убери звук во втором видео.",
        "Пожалуйста, сделай первое видео чёрно-белым", "Убери музыку",
        "Добавь титр «Ещё хочу камеру!» в конце и добавь эффект камеры в первом видео"
    ])
    func ordinaryEditsDoNotNeedTheModel(_ prompt: String) async {
        var calls = 0
        let agent = LocalDirectorAgent { _, _, _, _ in
            calls += 1
            throw URLError(.cannotConnectToHost)
        }
        let reply = await agent.respond(to: prompt, context: context)
        #expect(calls == 0)
        #expect(!reply.commands.isEmpty)
        #expect(!reply.planningFailed && !reply.isFallback)
        #expect(reply.runtimeLabel == "Точная монтажная команда")
    }

    @Test func invalidPlanIsRetriedOnceAndOnlyCompleteReplyCanExecute() async {
        var calls = 0
        var updates: [String] = []
        let agent = LocalDirectorAgent { _, _, _, _ in
            calls += 1
            if calls == 1 { throw URLError(.cannotParseResponse) }
            return DirectorAIReply(text: "Применю", runtimeLabel: "test", normalizedBrief: nil,
                commands: [.setFilter(.monochrome, .first), .addLibraryEffect(.videoCamera, .first)])
        }
        let reply = await agent.respond(to: "Сделай начало похожим на запись старой камеры", context: context,
            onPartialReply: { updates.append($0) })
        #expect(calls == 2)
        #expect(updates == ["Уточняю команды правки"])
        #expect(!reply.planningFailed && reply.commands.count == 2)
    }

    @Test func repeatedlyMalformedCompoundPlanDoesNotApplyRecognizedPrefix() async {
        var calls = 0
        let agent = LocalDirectorAgent { _, _, _, _ in
            calls += 1
            return try LocalDirectorAgent.decodeReply(
                #"{"reply":"Применю","commands":[{"action":"set_music_volume","target":"all","value":"0.2","secondaryTarget":""},{"action":"imaginary_effect","target":"first","value":"","secondaryTarget":""}]}"#,
                userMessage: "Громкость музыки 20% и добавь неизвестный эффект", runtimeLabel: "test", allowsFootageReplacement: false)
        }
        let reply = await agent.respond(to: "Громкость музыки 20% и добавь неизвестный эффект", context: context)
        #expect(calls == 2)
        #expect(reply.planningFailed && reply.commands.isEmpty)
        #expect(reply.text.contains("после повторной попытки"))
    }

    @Test(arguments: [URLError.Code.timedOut, .cannotConnectToHost, .networkConnectionLost, .badServerResponse])
    func transportFailureExplainsTheCauseWithoutRepeatingLongGeneration(_ code: URLError.Code) async {
        var calls = 0
        let agent = LocalDirectorAgent { _, _, _, _ in calls += 1; throw URLError(code) }
        let reply = await agent.respond(to: "Сделай начало напряженнее", context: context)
        #expect(calls == 1)
        #expect(reply.planningFailed && reply.commands.isEmpty)
        #expect(reply.text.contains("Изменения не применены"))
        #expect(!reply.text.contains("полный план"))
        #expect(reply.text.contains(code == .timedOut ? "не успела" : code == .badServerResponse ? "вернула ошибку" : "связь"))
    }

    @Test func cancellationCannotTriggerRepairOrReturnCommands() async {
        var calls = 0
        let agent = LocalDirectorAgent { _, _, _, _ in calls += 1; throw CancellationError() }
        let reply = await agent.respond(to: "Сделай начало напряженнее", context: context)
        #expect(calls == 1 && reply.planningFailed && reply.commands.isEmpty)
        #expect(reply.runtimeLabel == "Отменено")
    }

    @Test func advisoryCannotUseTheExactEditingShortcut() async {
        var calls = 0
        let agent = LocalDirectorAgent { _, _, mode, _ in
            calls += 1
            #expect(mode == .advisory)
            return DirectorAIReply(text: "Это стилизация под запись камеры.", runtimeLabel: "test", normalizedBrief: nil,
                commands: [.addLibraryEffect(.videoCamera, .first)])
        }
        let reply = await agent.respond(to: "Добавь эффект камеры в первом видео", context: context, mode: .advisory)
        #expect(calls == 1 && reply.commands.isEmpty)
    }
}
