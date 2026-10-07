import Foundation
import Testing
@testable import VeloEditCore

struct DirectorLiveJudgmentTests {
    static let advice = [
        "Как тебе?", "Здесь затянуто?", "Почему так?", "Что здесь не так?", "Мне не нравится конец",
        "Убрать паузу?", "Этот кадр плохой?", "Какой дубль лучше?", "Почему так резко?", "Слишком медленно?",
        "Нет, мне как раз нравится эта пауза", "Что слышно?", "Какая музыка подойдёт?", "Как назвать фильм?",
        "Нужен переход?", "Речь не обрезана?", "Что скажешь о начале?", "Кадр стоит сохранить?",
        "Как тебе весь фильм?", "Сравни клип 1 и клип 2", "Почему ты убрал конец?", "Пауза хорошая?",
        "Готово?", "Какая громкость музыки?", "Не меняй цвет", "Не добавляй музыку", "Не сокращай паузу",
        "Ничего не меняй, только оцени", "Только предложи название", "Без изменений, посоветуй музыку",
        "Да, сделай", "Да сделай", "Давай так", "Продолжи ожидание", "Объясни подробнее",
        "Проанализируй этот момент", "Только совет, сделай вывод", "Не трогай монтаж", "Что тут не так?", "Можно оставить тишину?"
    ]
    static let edits = [
        "Музыку на 20%", "громкость музыки 20,5%", "Убери переход", "Обрежь конец", "Переставь клип 2",
        "Сделай ярче", "Почему так резко и убери этот переход", "Не меняй цвет, убери переход",
        "Не трогай музыку, добавь титр", "Сократи клип 1 до 4 секунд", "Поставь музыку на 20%",
        "Раздели клип", "Вставь фон небо", "Замени дубль", "Увеличь громкость",
        "Убери дрожание и замени дубль", "Добавь титр «Пауза?»", "Собери фильм", "Поверни кадр", "Включи субтитры"
    ]

    @Test(arguments: advice) func questionsDoNotAuthorizeMutation(_ prompt: String) {
        #expect(DirectorRequestIntentInterpreter().mode(for: prompt) == .advisory)
    }
    @Test(arguments: edits) func explicitAndMixedRequestsRetainActions(_ prompt: String) {
        #expect(DirectorRequestIntentInterpreter().mode(for: prompt) == .edit)
    }

    static func project() -> ProjectManifest {
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/unreadable/never-open.mov"), kind: .video,
            byteSize: 1, contentHash: "hash", metadata: MediaMetadata(duration: 20, width: 1920, height: 1080, frameRate: 30, hasAudio: true))
        let speech = SpeechEditingEvidence(text: "Слово целиком", phraseStart: 1, phraseEnd: 6, confidence: 0.9,
            startsAtPhraseBoundary: true, endsAtPhraseBoundary: true,
            words: [TranscriptWord(text: "целиком", startTime: 4, duration: 2, confidence: 0.9)])
        var insights = CandidateInsights(sceneSummary: "Человек открывает дверь", speech: speech,
            audioEvents: [AudioEventObservation(kind: .laughter, startTime: 2, endTime: 3, confidence: 0.95, intensity: 1, evidence: ["local DSP: rms"])])
        insights.editorialEvidence = EditorialEvidence(samples: [EditorialTemporalSample(sourceTime: 2, actionState: ["walking"], confidence: 0.9)], usableRange: EditorialSourceRange(start: 0, end: 6))
        let candidates = [Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 6, scores: ClipScores(quality: 0.8, interest: 0.7, action: 0.6, stability: 0.9), insights: insights),
                          Candidate(assetID: asset.id, sourceStart: 10, sourceDuration: 5, scores: ClipScores(quality: 0.8, interest: 0.7, action: 0.6, stability: 0.9), insights: CandidateInsights(sceneSummary: "Море"))]
        let analysis = AnalysisResult(assetID: asset.id, analyzedContentHash: "hash", sceneTags: ["велосипед", "смех"], candidates: candidates, deepMediaVersion: DeepAnalysisCache.version)
        let items = [TimelineItem(candidateID: candidates[0].id, assetID: asset.id, kind: .video, sourceDuration: 5, timelineStart: 0, timelineDuration: 5),
                     TimelineItem(candidateID: candidates[1].id, assetID: asset.id, kind: .video, sourceStart: 10, sourceDuration: 5, timelineStart: 5, timelineDuration: 5)]
        return ProjectManifest(name: "Fixture", assets: [asset], analyses: [analysis], timelines: [Timeline(storyPlanID: UUID(), items: items)])
    }

    @Test func localEvidenceDoesNotBorrowGlobalTagsOrDSPLabels() {
        let p = Self.project()
        let moment = DirectorMomentIndex(project: p, revision: 1).resolve(prompt: "Здесь затянуто?", selectedID: nil, playhead: 2)
        #expect(moment.objects.count == 1)
        #expect(moment.objects[0].facts.contains { $0.kind == .cutSpeech })
        #expect(!moment.objects[0].facts.contains { $0.kind == .audio })
        let scene = moment.objects[0].facts.first { $0.kind == .scene }
        #expect(scene?.sourceRange == 0...6) // Never relabel episode coverage as the shorter cut.
        #expect(scene?.limitations.contains("часть") == true)
        #expect(!moment.modelData.contains("велосипед"))
        #expect(!moment.modelData.contains("local DSP: rms"))
    }

    @Test func sceneDescriptionsCannotResolveTimingOrAudioQuestions() {
        var p = Self.project()
        p.analyses[0].candidates[0].insights?.speech = nil
        p.analyses[0].candidates[0].insights?.editorialEvidence = nil
        let moment = DirectorMomentIndex(project: p, revision: 1).resolve(prompt: "Здесь", selectedID: nil, playhead: 1)
        for prompt in ["Почему так резко?", "Слишком медленно?", "Звук мешает?", "Речь не обрезана?", "Убрать паузу?"] {
            #expect(moment.adviceEvidenceGap(for: prompt) != nil)
        }
        #expect(moment.adviceEvidenceGap(for: "Мне как раз нравится эта пауза") == nil)
        #expect(moment.adviceEvidenceGap(for: "Как тебе этот момент?") == nil)
        let speech = DirectorMomentIndex(project: Self.project(), revision: 1).resolve(prompt: "Здесь", selectedID: nil, playhead: 1)
        #expect(speech.adviceEvidenceGap(for: "Речь не обрезана?") == nil)
    }

    @Test(arguments: 0..<16) func missingContradictoryOrStaleEvidenceStaysLimited(_ change: Int) {
        var p = Self.project()
        switch change {
        case 0: p.analyses = []
        case 1: p.analyses[0].analyzedContentHash = "old"
        case 2: p.analyses[0].schemaVersion += 1
        case 3: p.analyses[0].deepMediaVersion = nil
        case 4: p.analyses[0].deepMediaVersion = -1
        case 5: p.analyses[0].candidates[0].insights = nil
        case 6: p.analyses[0].candidates[0].insights?.speech?.confidence = 0.1
        case 7: p.analyses[0].candidates[0].insights?.speech?.words = []
        case 8: p.timelines[0].items[0].reversePlayback = true
        case 9: p.timelines[0].items[0].freezeFrame = true
        case 10: p.timelines[0].items[0].sourceStart = 7
        case 11: p.timelines[0].items[0].candidateID = UUID()
        case 12: p.analyses[0].candidates[0].assetID = UUID()
        case 13: p.timelines[0].items[0].sourceDuration = 3
        case 14: p.analyses[0].candidates[0].insights?.speech = nil
        default: p.analyses[0].candidates[0].insights?.speech?.words?[0].confidence = 0.2
        }
        let moment = DirectorMomentIndex(project: p, revision: 2).resolve(prompt: "Речь обрезана?", selectedID: nil, playhead: 1)
        #expect(!moment.objects.flatMap(\.facts).contains { $0.kind == .cutSpeech })
        #expect(!moment.objects.flatMap(\.facts).contains { $0.kind == .audio })
    }

    @Test func targetsRespectExplicitObjectClockAndWholeFilm() {
        let p = Self.project(), first = p.timelines[0].items[0], second = p.timelines[0].items[1]
        let index = DirectorMomentIndex(project: p, revision: 42)
        #expect(index.resolve(prompt: "На 00:06", selectedID: first.id, playhead: 1).objects.first?.itemID == second.id)
        #expect(index.resolve(prompt: "клип 2", selectedID: first.id, playhead: 1).objects.first?.itemID == second.id)
        #expect(index.resolve(prompt: "клип 88", selectedID: first.id, playhead: 1).objects.isEmpty)
        #expect(index.resolve(prompt: "Клип \(UUID())", selectedID: first.id, playhead: 1).objects.isEmpty)
        #expect(index.resolve(prompt: "Сравни \(first.id) и \(UUID())", selectedID: first.id, playhead: 1).objects.isEmpty)
        #expect(index.resolve(prompt: "Конец этого клипа", selectedID: first.id, playhead: 1).objects.first?.itemID == first.id)
        #expect(index.resolve(prompt: "Начало выбранного клипа", selectedID: second.id, playhead: 1).objects.first?.itemID == second.id)
        #expect(index.resolve(prompt: "Клип 1 и клип 1", selectedID: first.id, playhead: 1).objects.count == 1)
        #expect(index.resolve(prompt: "00:59", selectedID: first.id, playhead: 1).objects.isEmpty)
        #expect(index.resolve(prompt: "Весь фильм", selectedID: first.id, playhead: 1).scope == "film")
        #expect(index.resolve(prompt: "Как назвать фильм?", selectedID: first.id, playhead: 1).scope == "film")
        #expect(index.resolve(prompt: "Эти два дубля", selectedID: first.id, playhead: 1).limitations.contains { $0.contains("два") })
        #expect(index.resolve(prompt: "Здесь", selectedID: nil, playhead: 6).objects.first?.itemID == second.id)
    }

    @Test func duplicateAnalysisCannotRelabelOldCandidateAsCurrentEvidence() {
        var p = Self.project()
        var old = p.analyses[0]
        old.analyzedAt = old.analyzedAt.addingTimeInterval(-60)
        old.candidates[0].insights?.sceneSummary = "Устаревший сюжет"
        p.analyses.append(old)
        let moment = DirectorMomentIndex(project: p, revision: 1).resolve(prompt: "Здесь", selectedID: nil, playhead: 1)
        #expect(moment.facts.contains { $0.text == "Человек открывает дверь" })
        #expect(!moment.facts.contains { $0.text == "Устаревший сюжет" })
    }

    @Test(arguments: [false, true]) func rangeUsesExistingSpeedRampAndReverseClock(_ reversed: Bool) {
        var p = Self.project()
        p.timelines[0].items[0].speedRamp = .action
        p.timelines[0].items[0].reversePlayback = reversed
        let item = p.timelines[0].items[0]
        let context = DirectorMomentIndex(project: p, revision: 1).resolve(prompt: "Здесь", selectedID: nil, playhead: 1, range: 1...3)
        let a = item.sourceTime(atTimelineTime: 1), b = item.sourceTime(atTimelineTime: 3)
        #expect(context.objects[0].sourceRange == min(a, b)...max(a, b))
        #expect(context.objects[0].facts.allSatisfy { $0.sourceRange.lowerBound >= min(a, b) && $0.sourceRange.upperBound <= max(a, b) })
        #expect(!context.objects[0].facts.contains { $0.kind == .cutSpeech })
    }

    @Test func cacheBudgetAndSnapshotInvalidation() {
        var p = Self.project()
        let original = DirectorMomentIndex(project: p, revision: 1)
        let low = DirectorMomentIndex(project: p, revision: 1, byteLimit: 10)
        #expect(low.estimatedBytes <= 10)
        #expect(low.resolve(prompt: "Здесь", selectedID: nil, playhead: 1).objects.isEmpty)
        p.assets[0].contentHash = "replaced"
        let changed = DirectorMomentIndex(project: p, revision: 2)
        #expect(!original.resolve(prompt: "Здесь", selectedID: nil, playhead: 1).facts.isEmpty)
        #expect(changed.resolve(prompt: "Здесь", selectedID: nil, playhead: 1).facts.isEmpty)
    }

    @Test func judgmentValidatesObjectCoverageVersionAndClaimType() throws {
        let context = DirectorMomentIndex(project: Self.project(), revision: 1).resolve(prompt: "Здесь", selectedID: nil, playhead: 1)
        let fact = try #require(context.objects[0].facts.first { $0.kind == .cutSpeech })
        var judgment = DirectorJudgment(reply: "Граница попала внутрь слова. Я бы сохранил слово целиком.", stance: .keep, targetID: context.targetID, evidenceIDs: [fact.id])
        #expect(judgment.validated(in: context))
        judgment.targetID = UUID().uuidString; #expect(!judgment.validated(in: context))
        judgment.targetID = context.targetID
        judgment.reply = "Я бы обрезал до 99 секунд."; #expect(!judgment.validated(in: context))
        judgment.reply = "Поставил музыку на 20%."; #expect(!judgment.validated(in: context))
        judgment.reply = "Кадр сохраняется."; #expect(!judgment.validated(in: context))
        judgment.reply = "Смех делает паузу удачной."; #expect(!judgment.validated(in: context))
        judgment.reply = "Второй дубль лучше."; judgment.stance = .compare; #expect(!judgment.validated(in: context))
        judgment.stance = .keep; judgment.reply = "Я бы оставил."; judgment.evidenceIDs = ["missing"]
        #expect(!judgment.validated(in: context))
        var stale = context
        stale.objects[0].analysisVersion = "changed"
        judgment.evidenceIDs = [fact.id]; #expect(!judgment.validated(in: stale))
    }

    @Test func originalTitleIsNotMistakenForAnInventedTranscriptQuote() throws {
        let context = DirectorMomentIndex(project: Self.project(), revision: 1).resolve(prompt: "Здесь", selectedID: nil, playhead: 1)
        let fact = try #require(context.objects[0].facts.first { $0.kind == .scene })
        let title = DirectorJudgment(reply: "Предлагаю «За порогом»: в описании эпизода человек открывает дверь.", stance: .keep,
            targetID: context.targetID, evidenceIDs: [fact.id])
        #expect(!title.validated(in: context))
        #expect(title.validated(in: context, allowsProposedTitle: true))
    }

    @Test func receiptsDistinguishSavePreviewPartialAndCancellation() {
        #expect(DirectorResponseComposer.asksForPastEditReason("Почему ты убрал конец?"))
        #expect(DirectorResponseComposer.asksForPastEditReason("Зачем здесь эффект?"))
        #expect(!DirectorResponseComposer.asksForPastEditReason("Почему ты так считаешь?"))
        let saved = DirectorExecutionReceipt(requested: [.setMusicVolume(0.205)], applied: ["громкость"], saved: true, previewReady: true)
        #expect(DirectorResponseComposer.execution(saved) == "Поставил музыку на 20.5%.")
        var partial = saved; partial.omitted = ["другой дубль не найден"]
        #expect(partial.state == .partial)
        #expect(DirectorResponseComposer.execution(partial).contains("другой дубль не найден"))
        var cancelled = saved; cancelled.cancelled = true; cancelled.previewReady = false
        #expect(cancelled.state == .applied)
        #expect(DirectorResponseComposer.execution(cancelled).contains("после сохранения"))
        #expect(DirectorResponseComposer.execution(cancelled).contains("Просмотр пока не обновлён"))
        #expect(DirectorExecutionReceipt(cancelled: true).state == .cancelled)
        #expect(DirectorExecutionReceipt(failure: "disk full").state == .failed)
        #expect(DirectorExecutionReceipt().state == .noChange)
    }

    @Test func acceptedProposalStaysBoundToOriginalObjectAndAnalysis() throws {
        var p = Self.project()
        let item = p.timelines[0].items[0]
        let proposal = try #require(DirectorEditProposal.completingCutWord(project: p, targetID: item.id))
        #expect(proposal.duration == 6)
        #expect(proposal.isApplicable(to: p, selectedID: item.id))
        #expect(!proposal.isApplicable(to: p, selectedID: p.timelines[0].items[1].id))
        p.timelines[0].items[0].sourceStart = 0.5
        #expect(!proposal.isApplicable(to: p, selectedID: item.id))
        p.timelines[0].items[0] = item
        p.assets[0].contentHash = "changed"
        #expect(!proposal.isApplicable(to: p, selectedID: item.id))
    }

    @Test func oldMessagesDecodeWithoutNewFields() throws {
        let data = Data("{\"id\":\"\(UUID())\",\"role\":\"assistant\",\"text\":\"Ответ\",\"createdAt\":0}".utf8)
        #expect(try JSONDecoder().decode(ProjectDirectorMessage.self, from: data).response == nil)
    }
}
