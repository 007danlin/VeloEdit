import Foundation
import Testing
import VeloEditCore
@testable import VeloEdit

@MainActor struct EverydayDirectorReliabilityTests {
    private var context: DirectorContext {
        DirectorContext(assetCount: 3, videoCount: 3, photoCount: 0, analyzedCount: 3, candidateCount: 3,
            currentTimelineItemCount: 3, targetDuration: 12, preset: .story, currentOperation: "test")
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
