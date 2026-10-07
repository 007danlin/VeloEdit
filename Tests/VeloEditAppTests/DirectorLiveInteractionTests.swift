import Foundation
import Testing
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized) @MainActor
struct DirectorLiveInteractionTests {
    private func fixture(agent: LocalDirectorAgent) -> AppModel {
        let defaults = UserDefaults(suiteName: "VeloEdit.LiveTests.\(UUID())")!
        let model = AppModel(defaults: defaults, startBackgroundServices: false, directorAgent: agent)
        let items = [TimelineItem(kind: .video, sourceDuration: 5, timelineStart: 0, timelineDuration: 5),
                     TimelineItem(kind: .video, sourceStart: 5, sourceDuration: 5, timelineStart: 5, timelineDuration: 5)]
        model.project = ProjectManifest(name: "read-only", timelines: [Timeline(storyPlanID: UUID(), items: items)])
        return model
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test(arguments: [0, 1, 2]) func discussionAcrossAllComposersCannotEdit(_ surface: Int) async throws {
        var received: DirectorContext?
        var mode: DirectorRequestMode?
        let agent = LocalDirectorAgent { _, context, requestMode, _ in
            received = context; mode = requestMode
            return DirectorAIReply(text: "Для вывода пока мало данных.", runtimeLabel: "test", normalizedBrief: "Не применять", commands: [.delete(.all)])
        }
        let model = fixture(agent: agent)
        let before = model.timeline
        model.selectTimelineItem(before!.items[0].id)
        if surface == 0 { model.directorInput = "Что здесь не так?"; model.sendDirectorMessage() }
        else { model.submitTimelineAIEdit("Что здесь не так?", range: surface == 2 ? 1...3 : nil) }
        model.selectTimelineItem(before!.items[1].id)
        try await wait { !model.isDirectorResponding }
        #expect(mode == .advisory)
        #expect(model.timeline == before)
        #expect(!model.hasPendingFilmChanges)
        #expect(model.queuedTimelineAIEditCount == 0)
        #expect(received?.moment?.objects.first?.itemID == before?.items.first?.id)
        if surface == 2 { #expect(received?.moment?.objects.first?.filmRange == 1...3) }
        #expect(model.directorMessages.last?.response?.advisory == true)
        #expect(agent.recentConversationContext.contains("Для вывода пока мало данных"))
    }

    @Test func lateAnswerCannotReachReplacedProject() async throws {
        var resume: CheckedContinuation<Void, Never>?
        let agent = LocalDirectorAgent { _, _, _, _ in
            await withCheckedContinuation { resume = $0 }
            return DirectorAIReply(text: "Старый ответ", runtimeLabel: "test", normalizedBrief: nil)
        }
        let model = fixture(agent: agent)
        model.directorInput = "Как тебе?"; model.sendDirectorMessage()
        try await wait { resume != nil }
        model.project = ProjectManifest(name: "Другой")
        resume?.resume()
        try await Task.sleep(for: .milliseconds(40))
        #expect(!model.directorMessages.contains { $0.text == "Старый ответ" })
        model.cancelOperation()
    }

    @Test func extendedWaitKeepsOriginalQuestionAndBrushRange() async throws {
        var calls: [(String, DirectorContext)] = []
        let agent = LocalDirectorAgent { prompt, context, _, _ in
            calls.append((prompt, context))
            return DirectorAIReply(text: calls.count == 1 ? "Не успел подготовить оценку." : "Оценка исходного фрагмента.",
                runtimeLabel: "test", normalizedBrief: nil, isFallback: calls.count == 1)
        }
        let model = fixture(agent: agent)
        let original = model.timeline!.items[0].id
        model.selectTimelineItem(original)
        model.submitTimelineAIEdit("Как тебе этот момент?", range: 1...3)
        try await wait { !model.isDirectorResponding }
        model.selectTimelineItem(model.timeline!.items[1].id)
        model.directorInput = "Продолжи ожидание"; model.sendDirectorMessage()
        try await wait { !model.isDirectorResponding }
        #expect(calls.count == 2)
        #expect(calls.last?.0.contains("Как тебе этот момент?") == true)
        #expect(calls.last?.0.contains("Продолжи ожидание") == true)
        #expect(calls.last?.1.moment?.objects.first?.itemID == original)
        #expect(calls.last?.1.moment?.objects.first?.filmRange == 1...3)
        #expect(model.directorMessages.last?.response?.range == 1...3)
        #expect(model.directorMessages[model.directorMessages.count - 2].text == "Продолжи ожидание")
    }

    @Test func continuationCannotReuseFactsAfterProjectChanges() async throws {
        var calls = 0
        let agent = LocalDirectorAgent { _, _, _, _ in
            calls += 1
            return DirectorAIReply(text: "Предлагаю название.", runtimeLabel: "test", normalizedBrief: nil)
        }
        let model = fixture(agent: agent)
        model.directorInput = "Как назвать фильм?"; model.sendDirectorMessage()
        try await wait { !model.isDirectorResponding }
        model.project?.timelines[0].items[0].sourceStart = 1
        model.directorInput = "Подробнее"; model.sendDirectorMessage()
        try await wait { !model.isDirectorResponding }
        #expect(calls == 1)
        #expect(model.directorMessages.last?.text.contains("Повторите вопрос") == true)
    }

    @Test func discussionCannotCancelAuthorizedInitialDirectorTask() async throws {
        var resume: CheckedContinuation<Void, Never>?
        var cancelled = false
        var calls = 0
        let agent = LocalDirectorAgent { _, _, _, _ in
            calls += 1
            await withCheckedContinuation { resume = $0 }
            cancelled = Task.isCancelled
            return DirectorAIReply(text: "План подготовлен", runtimeLabel: "test", normalizedBrief: nil)
        }
        let model = fixture(agent: agent)
        model.project?.timelines = []
        model.directorInput = "Собери фильм"; model.sendDirectorMessage()
        try await wait { resume != nil }
        model.directorInput = "Как тебе этот момент?"; model.sendDirectorMessage()
        #expect(model.isDirectorResponding)
        #expect(model.directorMessages.last?.response?.advisory == true)
        resume?.resume()
        try await wait { !model.isDirectorResponding }
        #expect(calls == 1)
        #expect(!cancelled)
        model.cancelOperation()
    }

    @Test func deadlineDoesNotWaitForUncooperativeRuntimeOrPublishLateResult() async throws {
        var resume: CheckedContinuation<Void, Never>?
        let fallback = DirectorAIReply(text: "Ограниченный ответ", runtimeLabel: "fallback", normalizedBrief: nil)
        let start = ProcessInfo.processInfo.systemUptime
        let reply = await DirectorReplyDeadline.run(seconds: 0.04, fallback: fallback) {
            await withCheckedContinuation { resume = $0 }
            return DirectorAIReply(text: "Поздний результат", runtimeLabel: "test", normalizedBrief: nil, commands: [.delete(.all)])
        }
        #expect(reply.text == fallback.text)
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.3)
        resume?.resume()
        await Task.yield()
        #expect(reply.commands.isEmpty)
    }

    @Test func onlyOneGenerationCanBeActiveAndExpiredQueueDoesNotGenerate() async throws {
        var active = 0, maximum = 0, calls = 0
        let agent = LocalDirectorAgent { _, _, _, _ in
            calls += 1; active += 1; maximum = max(maximum, active)
            try? await Task.sleep(for: .milliseconds(100))
            active -= 1
            return DirectorAIReply(text: "Ответ", runtimeLabel: "test", normalizedBrief: nil)
        }
        let context = DirectorContext(assetCount: 0, videoCount: 0, photoCount: 0, analyzedCount: 0,
            candidateCount: 0, currentTimelineItemCount: 0, targetDuration: 30, preset: .story, currentOperation: "test")
        async let a = agent.respond(to: "Как тебе?", context: context, mode: .advisory)
        async let b = agent.respond(to: "Здесь затянуто?", context: context, mode: .advisory, submittedAt: ProcessInfo.processInfo.systemUptime - 5.97)
        let replies = await [a, b]
        #expect(maximum == 1)
        #expect(calls == 1)
        #expect(replies.filter(\.isFallback).count == 1)
    }

    @Test func exactCommandNeverCallsLanguageModel() async {
        var calls = 0
        let agent = LocalDirectorAgent { _, _, _, _ in
            calls += 1; return DirectorAIReply(text: "wrong", runtimeLabel: "wrong", normalizedBrief: nil)
        }
        let context = DirectorContext(assetCount: 0, videoCount: 0, photoCount: 0, analyzedCount: 0,
            candidateCount: 0, currentTimelineItemCount: 0, targetDuration: 30, preset: .story, currentOperation: "test")
        let reply = await agent.respond(to: "Музыку на 20%", context: context)
        #expect(calls == 0)
        #expect(reply.commands == [.setMusicVolume(0.2)])
    }

    static let dialogues = [
        ["Здесь затянуто?", "Нет, мне нравится эта пауза", "Почему так?"],
        ["Как тебе клип 1?", "Мне нравится спокойный темп", "А клип 2?"],
        ["Какой дубль лучше?", "Сравни клип 1 и клип 2", "А что с речью?"],
        ["Что слышно?", "Мне нравится тишина", "Какая музыка подойдет?"],
        ["Почему так резко?", "Не меняй переход", "Что скажешь о цвете?"],
        ["Убрать паузу?", "Не сокращай паузу", "Она слишком длинная?"],
        ["Что здесь не так?", "Как тебе весь фильм?", "А начало?"],
        ["Мне не нравится конец", "Что скажешь о начале?", "Почему так?"],
        ["Какая музыка подойдет?", "Не добавляй музыку", "Можно оставить тишину?"],
        ["Как назвать фильм?", "Только предложи название", "А другой вариант?"],
        ["Этот кадр плохой?", "Мне нравится этот момент", "Оставить?"],
        ["Почему ты убрал конец?", "Объясни подробнее", "Речь не обрезана?"],
        ["Речь не обрезана?", "Мне нравится эта фраза", "Что слышно в клипе 2?"],
        ["Слишком медленно?", "Мне нравится медленное начало", "Как тебе финал?"],
        ["Нужен переход?", "Ничего не меняй", "Что здесь удачно?"]
    ]

    @Test(arguments: dialogues) func followUpKeepsFinalAdviceAndObjection(_ dialogue: [String]) async throws {
        let agent = LocalDirectorAgent { message, _, _, _ in
            DirectorAIReply(text: message.contains("нравится") ? "Учту это в следующих советах." : "Пока оставил бы этот момент.", runtimeLabel: "test", normalizedBrief: nil)
        }
        let model = fixture(agent: agent)
        for prompt in dialogue {
            model.submitTimelineAIEdit(prompt)
            try await wait { !model.isDirectorResponding }
        }
        #expect(model.directorMessages.filter { $0.role == .user }.count == 3)
        #expect(agent.recentConversationContext.contains(dialogue[1]))
        #expect(agent.recentConversationContext.contains(dialogue[2]))
        #expect(!model.hasPendingFilmChanges)
        model.cancelOperation()
    }

    @Test func advicePayloadHasSeparateBudgetAndNoEditingCatalog() throws {
        let context = DirectorContext(assetCount: 0, videoCount: 0, photoCount: 0, analyzedCount: 0,
            candidateCount: 0, currentTimelineItemCount: 0, targetDuration: 30, preset: .story, currentOperation: "test")
        let data = try JSONEncoder().encode(DirectorAdviceRequest(prompt: "Как тебе?", context: context, history: "", detailed: false))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["options"] as? [String: Any])?["num_predict"] as? Int == 256)
        #expect(json["think"] as? Bool == false)
        #expect(!String(decoding: data, as: UTF8.self).contains("set_transition_pattern"))
    }
}
