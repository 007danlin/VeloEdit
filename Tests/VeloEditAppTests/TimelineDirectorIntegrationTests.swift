import AVFoundation
import Combine
import Foundation
import Testing
@testable import VeloEditCore
@testable import VeloEdit

@Suite(.serialized) @MainActor
struct TimelineDirectorIntegrationTests {
    @Test(arguments: ["накидай всяких переходов", "на весь интервал видео", "00:01–00:05"])
    func conversationalEditsReachRealTimeline(_ message: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        if message != "накидай всяких переходов" {
            // Reopen an exchange saved by the version that mistook the edit for advice.
            var unanswered = DirectorMessage(role: .assistant, text: "Укажите клип или таймкод")
            unanswered.response = .init(state: .proposed, projectID: model.project?.id, advisory: true, fallback: true)
            model.directorMessages.append(DirectorMessage(role: .user, text: "накидай всяких переходов"))
            model.directorMessages.append(unanswered)
            if message.contains(":") {
                model.directorMessages.append(DirectorMessage(role: .user, text: "на весь интервал видео"))
                model.directorMessages.append(unanswered)
            }
        }
        model.directorInput = message
        model.sendDirectorMessage()
        try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
        let updated = try #require(model.timeline)
        let transition = try #require(updated.effectiveTransitionItems.first)
        #expect(updated.effectiveTransitionItems.count == 1)
        #expect(transition.startTime == 3)
        #expect(transition.style == .crossDissolve)
        #expect(model.directorMessages.last?.response?.saved == true)
        #expect(model.directorMessages.last?.response?.previewReady == true)
        #expect(model.directorMessages.dropLast().last?.text == message)
        #expect(fixture.requests.values.isEmpty)
        model.undoTimelineEdit()
        try await wait { model.timeline == original }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REAL_COMMENT_DIRECTOR"] == "1"), arguments: [
        ["Первая глава", "Вторая глава"],
        ["Осуществление посадки пассажиров в поезд", "Прибытие поезда к месту назначения"]
    ])
    func realDirectorRewritesExistingTitlesAndExplainsWhatChanged(_ titleTexts: [String]) async throws {
        let fixture = try await Fixture(realDirector: true, titleTexts: titleTexts)
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        model.selectTitleTimelineItem(fixture.secondTitleID)
        model.directorInput = "Переделай титры на понятные"
        model.sendDirectorMessage()
        try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
        let updated = try #require(model.timeline)
        print("Результат правки титров:", model.directorMessages.last?.text ?? "")
        #expect(updated.effectiveTitleItems.map(\.id) == original.effectiveTitleItems.map(\.id))
        #expect(zip(updated.effectiveTitleItems, original.effectiveTitleItems).allSatisfy { $0.text != $1.text })
        #expect(Set(updated.effectiveTitleItems.map(\.text)).count == 2)
        #expect(updated.items == original.items)
        #expect(model.directorMessages.last?.response?.saved == true)
        model.directorInput = "Что?"
        model.sendDirectorMessage()
        try await wait { !model.isDirectorResponding }
        print("Пояснение:", model.directorMessages.last?.text ?? "")
        #expect(updated.effectiveTitleItems.allSatisfy { model.directorMessages.last?.text.contains($0.text) == true })
        #expect(model.directorMessages.last?.response?.range == nil)
        #expect(model.timeline == updated)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REAL_COMMENT_DIRECTOR"] == "1"))
    func realDialogueRoutesAnIndirectMusicRequestThroughTheEditor() async throws {
        let fixture = try await Fixture(realDirector: true)
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        let request = "Пускай фоновая мелодия звучит на 17%"
        #expect(DirectorRequestIntentInterpreter().route(for: request) == .interpret)
        model.directorInput = request
        model.sendDirectorMessage()
        try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
        print("Ответ на просьбу о музыке:", model.directorMessages.last?.text ?? "")
        #expect(model.directorMessages.filter { $0.role == .user }.map(\.text) == [request])
        #expect(model.timeline?.music?.trackID == original.music?.trackID)
        #expect(model.timeline?.music?.volume == 0.17)
        #expect(model.timeline?.items == original.items)
        #expect(model.directorMessages.last?.response?.saved == true)
    }

    @Test(arguments: [false, true]) func transitionsCanBeNarrowedAndRestored(whileApplying: Bool) async throws {
        let fixture = try await Fixture(clipCount: 4)
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        model.directorInput = "Поменяй переходы"
        model.sendDirectorMessage()
        if !whileApplying {
            try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
            #expect(model.timeline?.effectiveTransitionItems.count == 3)
        }
        model.directorInput = "Только в конце"
        model.sendDirectorMessage()
        try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
        let saved = try #require(model.timeline)
        #expect(saved.effectiveTransitionItems.map(\.incomingClipID) == [original.items[3].id])
        #expect(saved.items.dropLast() == original.items.dropLast())
        #expect(model.directorMessages.last?.response?.saved == true)
        let reopened = try ProjectStore(open: fixture.url)
        let persisted = try #require(await reopened.manifest.timelines.last)
        #expect(persisted.items == saved.items)
        #expect(persisted.effectiveTransitionItems == saved.effectiveTransitionItems)
        for (message, count) in [("Нет, верни как было", 3), ("Верни отменённую правку", 1)] {
            model.directorInput = message
            model.sendDirectorMessage()
            try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
            #expect(model.timeline?.effectiveTransitionItems.count == count)
        }
    }

    @Test(arguments: [false, true]) func namedTransitionCorrectionKeepsInterveningMusic(queued: Bool) async throws {
        let fixture = try await Fixture(clipCount: 4)
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        let music = try #require(original.music)
        func send(_ text: String) { model.directorInput = text; model.sendDirectorMessage() }
        func settle() async throws {
            try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
        }
        var quieterRMS: Double?
        send("Поменяй переходы")
        if !queued { try await settle() }
        send("Сделай музыку потише")
        if !queued {
            try await settle()
            #expect(model.timeline?.effectiveTransitionItems.count == 3)
            #expect((model.timeline?.music?.volume ?? 1) < music.volume)
            let preview = try #require(model.previewPlayer?.currentItem)
            quieterRMS = try await audioSignature(preview, start: 0.25, duration: 0.5).rms
        }
        send("А переходы оставь только в конце")
        try await settle()
        let corrected = try #require(model.timeline)
        #expect(model.directorMessages.last?.response?.saved == true)
        #expect(corrected.effectiveTransitionItems.map(\.incomingClipID) == [original.items[3].id])
        #expect(corrected.items.dropLast() == original.items.dropLast())
        let quieter = try #require(corrected.music)
        #expect(quieter.trackID == music.trackID && quieter.volume > 0 && quieter.volume < music.volume)
        if let quieterRMS {
            let preview = try #require(model.previewPlayer?.currentItem)
            let correctedRMS = try await audioSignature(preview, start: 0.25, duration: 0.5).rms
            #expect(quieterRMS > 0 && abs(correctedRMS / quieterRMS - 1) < 0.01)
        }
        let saved = try ProjectStore(open: fixture.url)
        #expect(await saved.manifest.timelines.last?.music == quieter)
        #expect(await saved.manifest.timelines.last?.effectiveTransitionItems == corrected.effectiveTransitionItems)
        send("Отмени последнюю правку")
        try await settle()
        #expect(model.timeline?.effectiveTransitionItems.count == 3)
        #expect(model.timeline?.music == quieter)
        send("Верни отменённую правку")
        try await settle()
        #expect(model.timeline?.effectiveTransitionItems == corrected.effectiveTransitionItems)
        send("Верни прежнюю громкость музыки")
        try await settle()
        #expect(model.timeline?.music == original.music)
        #expect(model.timeline?.effectiveTransitionItems == corrected.effectiveTransitionItems)
    }

    @Test(arguments: [false, true]) func reopenedProjectRemembersTransitionsAndKeepsQuieterSoundtrack(legacy: Bool) async throws {
        let fixture = try await Fixture(clipCount: 4)
        defer { fixture.remove() }
        func send(_ text: String, to model: AppModel) async throws {
            model.directorInput = text
            model.sendDirectorMessage()
            try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
        }
        func reopen() async throws -> AppModel {
            let model = AppModel(defaults: UserDefaults(suiteName: fixture.suite)!, startBackgroundServices: false)
            model.openRecentProject(fixture.url)
            try await wait { model.projectURL == fixture.url && model.openingProjectURL == nil }
            return model
        }
        let initial = try #require(fixture.model.timeline)
        try await send("Поменяй переходы", to: fixture.model)
        try await send("Сделай музыку потише", to: fixture.model)
        let edited = try #require(fixture.model.timeline)
        let quieter = try #require(edited.music)
        #expect(quieter.trackID == initial.music?.trackID && quieter.volume < (initial.music?.volume ?? 0))
        #expect(edited.effectiveTransitionItems.count == 3)
        let beforePlayer = try #require(fixture.model.previewPlayer?.currentItem)
        let beforeRMS = try await audioSignature(beforePlayer, start: 0.25, duration: 0.5).rms
        #expect(await fixture.model.stopForApplicationTermination())
        #expect(await fixture.model.flushAutosave())

        let receipts = fixture.model.directorMessages.compactMap { $0.response?.revisionLink }
        #expect(receipts.count == 2)
        if legacy {
            let old = try ProjectStore(open: fixture.url)
            try await old.update { project in
                guard var state = project.workspaceState, var messages = state.directorMessages else { return }
                for i in messages.indices { messages[i].response?.revisionLink = nil }
                state.directorMessages = messages
                project.workspaceState = state
            }
        }
        let reopened = try await reopen()
        #expect(reopened.directorMessages.contains { $0.text == "Поменяй переходы" })
        #expect(reopened.timeline?.effectiveTransitionItems == edited.effectiveTransitionItems)
        try await send("А переходы оставь только в конце", to: reopened)
        #expect(reopened.directorMessages.last?.response?.saved == true)
        #expect(reopened.timeline?.effectiveTransitionItems == Array(edited.effectiveTransitionItems.suffix(1)))
        #expect(reopened.timeline?.items.dropLast() == initial.items.dropLast())
        #expect(reopened.timeline?.music == quieter)
        let afterPlayer = try #require(reopened.previewPlayer?.currentItem)
        let afterRMS = try await audioSignature(afterPlayer, start: 0.25, duration: 0.5).rms
        #expect(beforeRMS > 0 && abs(afterRMS / beforeRMS - 1) < 0.01)
        #expect(await reopened.stopForApplicationTermination())
        #expect(await reopened.flushAutosave())

        let again = try await reopen()
        #expect(again.timeline?.effectiveTransitionItems == Array(edited.effectiveTransitionItems.suffix(1)))
        try await send("Верни прежние переходы", to: again)
        #expect(again.timeline?.effectiveTransitionItems == initial.effectiveTransitionItems)
        #expect(again.timeline?.music == quieter)
        #expect(await again.stopForApplicationTermination())
    }

    @Test func reopenedProjectRejectsScopeWhenSavedTimelineNoLongerMatchesChat() async throws {
        let fixture = try await Fixture(clipCount: 4)
        defer { fixture.remove() }
        for text in ["Поменяй переходы", "Сделай музыку потише"] {
            fixture.model.directorInput = text
            fixture.model.sendDirectorMessage()
            try await wait { !fixture.model.isWorking && !fixture.model.isDirectorResponding && fixture.model.queuedTimelineAIEditCount == 0 }
        }
        #expect(await fixture.model.stopForApplicationTermination())
        #expect(await fixture.model.flushAutosave())
        let store = try ProjectStore(open: fixture.url)
        try await store.update { project in project.timelines[0].items[0].locked.toggle() }
        let manuallyEdited = try #require(await store.manifest.timelines.last)
        let reopened = AppModel(defaults: UserDefaults(suiteName: fixture.suite)!, startBackgroundServices: false)
        reopened.openRecentProject(fixture.url)
        try await wait { reopened.projectURL == fixture.url && reopened.openingProjectURL == nil }
        reopened.directorInput = "А переходы оставь только в конце"
        reopened.sendDirectorMessage()
        try await wait { !reopened.isWorking && !reopened.isDirectorResponding && reopened.queuedTimelineAIEditCount == 0 }
        #expect(reopened.directorMessages.last?.response?.saved == false)
        #expect(reopened.timeline?.items == manuallyEdited.items)
        #expect(reopened.timeline?.effectiveTransitionItems == manuallyEdited.effectiveTransitionItems)
        #expect(reopened.timeline?.music == manuallyEdited.music)
        #expect(await reopened.stopForApplicationTermination())
    }

    @Test func missingSavedMusicDoesNotSelectAnotherTrackOnOpen() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let pipeline = try #require(fixture.model.pipeline)
        var timeline = try #require(fixture.model.timeline)
        timeline.music?.trackID = UUID()
        timeline.music?.trackTitle = "Отсутствующий трек"
        try await pipeline.replaceLatestTimeline(with: timeline)
        await #expect(throws: FreeToUseAPIError.self) { try await pipeline.resolvePendingMusic() }
        #expect(await pipeline.store.manifest.timelines.last?.music == timeline.music)
    }

    @Test func namedFilterScopePreservesIndependentCameraEffects() async throws {
        let fixture = try await Fixture(clipCount: 4)
        defer { fixture.remove() }
        let model = fixture.model
        var effects: [EffectTimelineItem] = []
        for request in ["Сделай все клипы чёрно-белыми", "Добавь эффект камеры на все клипы", "А фильтр оставь только в начале"] {
            model.directorInput = request
            model.sendDirectorMessage()
            try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
            if request.contains("камеры") { effects = model.timeline?.effectiveEffects ?? [] }
        }
        let timeline = try #require(model.timeline)
        #expect(timeline.items.map { $0.effectiveVideoAdjustments.filter } == [.monochrome, .none, .none, .none])
        #expect(effects.count == 4 && timeline.effectiveEffects == effects)
    }

    @Test func modelSwitchLeavesCompletedFilmReady() async throws {
        let fixture = try await Fixture(completedFilm: true)
        defer { fixture.remove() }
        let model = fixture.model
        model.renderPreview()
        try await wait { !model.isWorking }
        let player = try #require(model.previewPlayer?.currentItem)
        let project = try #require(model.project)
        #expect(model.montageReady)
        model.setAIPowerMode(.balanced)
        try await wait { model.project?.preferences.effectiveAIPowerMode == .balanced }
        model.setAdvancedAISettings(.init(enabled: true, runtime: .ollama))
        try await wait { model.project?.preferences.effectiveAdvancedAISettings.enabled == true }
        #expect(!model.hasPendingFilmChanges && model.montageReady && !model.isCreatingFilm)
        #expect(model.previewPlayer?.currentItem === player)
        #expect(model.project?.timelines == project.timelines)
        #expect(model.project?.autonomousJob?.id == project.autonomousJob?.id)
        #expect(model.project?.autonomousJob?.state == .completed)
        #expect(model.project?.autonomousJob?.processProfile?.mode == .fast)
        #expect(model.project?.timelineCheckpoints?.count == project.timelineCheckpoints?.count)
        #expect(await model.flushAutosave())
        let persisted = try ProjectStore(open: fixture.url)
        #expect(await persisted.manifest.preferences.effectiveAIPowerMode == .balanced)
        #expect(await persisted.manifest.workspaceState?.hasPendingFilmChanges != true)
        model.directorInput = "Предложи название для фильма"
        model.sendDirectorMessage()
        try await wait { !model.isDirectorResponding && !fixture.requests.values.isEmpty }
        #expect(fixture.requests.values.last?.1.aiPowerMode == .balanced)
        model.selectPreset(.vlog)
        model.setAIPowerMode(.quality)
        try await wait { model.project?.preferences.effectiveAIPowerMode == .quality }
        #expect(model.hasPendingFilmChanges)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REAL_COMMENT_DIRECTOR"] == "1"))
    func newModelHandlesNextRequestAfterFilmCompletion() async throws {
        let fixture = try await Fixture(realDirector: true, completedFilm: true)
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        model.setAIPowerMode(.balanced)
        try await wait { model.project?.preferences.effectiveAIPowerMode == .balanced }
        #expect(model.timeline == original && model.montageReady)
        model.directorInput = "Переделай титры на понятные"
        model.sendDirectorMessage()
        try await wait { !model.isDirectorResponding && !model.isWorking && model.queuedTimelineAIEditCount == 0 }
        print("Новая модель:", model.directorRuntimeStatus, model.directorMessages.last?.text ?? "")
        #expect(model.directorRuntimeStatus.hasPrefix(AIAnalysisProfile.resolve(mode: .balanced).modelID))
        #expect(model.timeline?.effectiveTitleItems.map(\.text) != original.effectiveTitleItems.map(\.text))
        #expect(model.timeline?.music == original.music)
        #expect(model.timeline?.items == original.items)
        #expect(model.project?.autonomousJob?.state == .completed)
    }

    @Test func scopeAfterAnInterveningManualEditCannotRestoreAnOlderSnapshot() async throws {
        let fixture = try await Fixture(clipCount: 4)
        defer { fixture.remove() }
        let model = fixture.model
        model.directorInput = "Поменяй переходы"
        model.sendDirectorMessage()
        try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
        var manuallyEdited = try #require(model.timeline)
        manuallyEdited.items[0].locked.toggle()
        try await model.pipeline?.replaceLatestTimeline(with: manuallyEdited)
        model.project = await model.pipeline?.snapshot()
        model.directorInput = "Только в конце"
        model.sendDirectorMessage()
        try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
        #expect(model.timeline?.items == manuallyEdited.items)
        #expect(model.timeline?.effectiveTransitionItems == manuallyEdited.effectiveTransitionItems)
        #expect(model.directorMessages.last?.response?.saved == false)
    }

    @Test func previousTransitionsSurviveScopeCorrectionAndNamedRestore() async throws {
        let fixture = try await Fixture(clipCount: 4)
        defer { fixture.remove() }
        let model = fixture.model
        // A pre-existing transition at the first cut must survive both narrowing and restore.
        let baseline = try #require(model.timeline)
        let seeded = EditorCommandExecutor().apply([.setTransition(.fade, .number(2))], to: baseline).timeline
        try await model.pipeline?.replaceLatestTimeline(with: seeded)
        model.project = await model.pipeline?.snapshot()
        for message in ["Поменяй переходы", "Только в конце", "Верни прежние переходы"] {
            model.directorInput = message
            model.sendDirectorMessage()
            try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
            if message == "Только в конце" {
                let transitions = try #require(model.timeline?.effectiveTransitionItems)
                #expect(transitions.count == 2)
                #expect(transitions.first == seeded.effectiveTransitionItems.first)
                #expect(transitions.last?.incomingClipID == seeded.items.last?.id)
            }
        }
        #expect(model.timeline?.effectiveTransitionItems == seeded.effectiveTransitionItems)
        #expect(model.timeline?.items == seeded.items)
    }

    @Test func musicVolumeFollowsCorrectionsAndKeepsTheTrack() async throws {
        let fixture = try await Fixture(clipCount: 4)
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        for (message, expected) in [("Поставь громкость музыки на 20%", 0.2), ("А лучше на 35%", 0.35),
                                    ("Нет, верни как было", 0.2)] {
            model.directorInput = message
            model.sendDirectorMessage()
            try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
            #expect(model.timeline?.music?.volume == expected)
            #expect(model.timeline?.music?.trackID == original.music?.trackID)
            #expect(model.timeline?.items == original.items)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REAL_COMMENT_DIRECTOR"] == "1"))
    func liveDirectorCanNarrowADescribedLook() async throws {
        let fixture = try await Fixture(realDirector: true, clipCount: 4)
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        model.renderPreview()
        try await wait { !model.isWorking }
        let initial = try #require(model.previewPlayer?.currentItem)
        let firstFrame = try await frame(initial, at: 0.75)
        let lastFrame = try await frame(initial, at: 5.25)
        let script = ["Сделай так, чтобы весь ролик выглядел как запись на старую видеокассету",
                      "Я передумал, оставь это только на последнем плане", "А что именно поменялось?"]
        for (index, message) in script.enumerated() {
            let timeline = try await sendAndReopen(message, in: fixture)
            let clips = index == 0 ? original.items[...] : original.items.suffix(1)
            #expect(timeline.effectiveEffects.map(\.effectType) == Array(repeating: .vhsDistortion, count: clips.count))
            #expect(timeline.effectiveEffects.compactMap(\.targetClipID) == clips.map(\.id))
            #expect(timeline.items == original.items)
            #expect(timeline.music == original.music)
            let preview = try #require(model.previewPlayer?.currentItem)
            #expect(try await (frame(preview, at: 0.75) == firstFrame) == (index != 0))
            #expect(try await frame(preview, at: 5.25) != lastFrame)
            if index == 2 {
                let explanation = try #require(model.directorMessages.last?.text)
                #expect(explanation.contains("VHS"))
                #expect(explanation.contains("0:04,5–0:06"))
                #expect(DirectorEditScope("0:04,5–0:06") == .interval(4.5...6))
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REAL_COMMENT_DIRECTOR"] == "1"))
    func liveDirectorEditsTwoTracksThenUndoesTogether() async throws {
        let fixture = try await Fixture(realDirector: true, clipCount: 4)
        defer { fixture.remove() }
        let original = try #require(fixture.model.timeline)
        for (message, undo) in [("Поставь музыку на 12 процентов и переименуй первый титр в «Новый день»", false),
                                ("Нет, передумал, отмени последнее изменение", true)] {
            let timeline = try await sendAndReopen(message, in: fixture)
            var expectedMusic = try #require(original.music)
            if !undo { expectedMusic.volume = 0.12 }
            #expect(timeline.music == expectedMusic)
            #expect(timeline.effectiveTitleItems.map(\.text) == (undo ? ["Первая глава", "Вторая глава"] : ["Новый день", "Вторая глава"]))
            #expect(timeline.effectiveTitleItems.map(\.id) == original.effectiveTitleItems.map(\.id))
            #expect(timeline.items == original.items)
            #expect(fixture.model.directorMessages.last?.response?.saved == true)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REAL_COMMENT_DIRECTOR"] == "1"))
    func liveDirectorBuildsAndExportsAcrossLibraries() async throws {
        let fixture = try await Fixture(realDirector: true)
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        let pipeline = try #require(model.pipeline)
        let intro = try await sendAndReopen("Добавь в начале фон небо с титром «Наш маршрут»", in: fixture)
        let opening = try #require(intro.items.first)
        let title = try #require(intro.effectiveTitleItems.first { $0.text == "Наш маршрут" })
        #expect(title.targetClipID == opening.id)
        #expect(intro.items.dropFirst().map(\.id) == original.items.map(\.id))
        let asset = try #require(model.project?.assets.first { $0.id == opening.assetID })
        #expect(BackgroundPreset.preset(for: asset) == .clouds)

        let transitions = try await sendAndReopen("Хочу, чтобы на каждой склейке один кадр плавно перетекал в следующий", in: fixture)
        #expect(transitions.effectiveTransitionItems.map(\.incomingClipID) == intro.items.dropFirst().map(\.id))
        #expect(transitions.effectiveTransitionItems.allSatisfy { $0.style == .crossDissolve })
        let before = try #require(model.previewPlayer?.currentItem)
        let duration = try await before.asset.load(.duration).seconds
        let lastTime = duration - 1
        let openingFrame = try await frame(before, at: 1)
        let originalFrame = try await frame(before, at: lastTime)
        let sound = try await audioSignature(before, start: 1.2, duration: 0.5)

        let edited = try await sendAndReopen("Добавь эффект видеокамеры на последний клип и поставь громкость музыки на 9%", in: fixture)
        let camera = edited.effectiveEffects.filter { $0.effectType == .videoCamera }
        #expect(camera.count == 1 && camera.first?.targetClipID == original.items.last?.id)
        #expect(edited.music?.trackID == original.music?.trackID && edited.music?.volume == 0.09)
        #expect(edited.effectiveTitleItems == intro.effectiveTitleItems)
        #expect(edited.effectiveTransitionItems == transitions.effectiveTransitionItems)
        let preview = try #require(model.previewPlayer?.currentItem)
        #expect(try await frame(preview, at: 1) == openingFrame)
        #expect(try await frame(preview, at: lastTime) != originalFrame)
        let output = fixture.root.appendingPathComponent("director.mp4")
        let report = try await pipeline.render(to: output, quality: .maximum)
        #expect(report.skippedItemIDs.isEmpty)
        let exported = AVPlayerItem(url: output)
        let audio = try await audioSignature(exported, start: 1.2, duration: 0.5)
        #expect(abs(audio.frequency - sound.frequency) < 8)
        #expect(abs(audio.rms / sound.rms - 0.5) < 0.07)
        if let path = ProcessInfo.processInfo.environment["VELOEDIT_DIRECTOR_PROOF_MOVIE"] {
            try FileManager.default.copyItem(at: output, to: URL(fileURLWithPath: path))
        }
        let undone = try await sendAndReopen("Нет, передумал, отмени последнее изменение", in: fixture)
        #expect(undone.effectiveEffects == transitions.effectiveEffects)
        #expect(undone.music == transitions.music && undone.items == transitions.items)
        #expect(undone.effectiveTransitionItems == transitions.effectiveTransitionItems)
        #expect(undone.effectiveTitleItems == transitions.effectiveTitleItems)
        let restored = try #require(model.previewPlayer?.currentItem)
        #expect(try await frame(restored, at: lastTime) == originalFrame)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REAL_COMMENT_DIRECTOR"] == "1"))
    func liveDirectorAddsMatchingMediaMusicAndMeasuredSpeed() async throws {
        let fixture = try await Fixture(realDirector: true)
        defer { fixture.remove() }
        let model = fixture.model
        let pipeline = try #require(model.pipeline)
        let store = await pipeline.store
        let url = try await TitleCardVideoGenerator().generate(text: "ДОРОГА", style: TitleStyle(backgroundColorHex: "#176035"),
            duration: 2, width: 640, height: 360, frameRate: 20, destination: fixture.root.appendingPathComponent("road.mov"), codec: .jpeg)
        let asset = try await MediaImporter().makeAsset(url: url)
        let road = Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 2,
            scores: ClipScores(quality: 0.9, interest: 0.7, action: 0.6, stability: 0.8), tags: ["дорога", "road"])
        let summary = TelemetrySummary(sampleCount: 2, maxSpeedMetersPerSecond: 12,
            timedSamples: [.init(timestamp: 0, speedMetersPerSecond: 10), .init(timestamp: 2, speedMetersPerSecond: 12)])
        try await store.update {
            $0.timelines[0].music = nil
            $0.assets.append(asset)
            $0.analyses.append(.init(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [road], telemetry: summary))
        }
        model.project = await pipeline.snapshot()
        let media = try await sendAndReopen("Добавь в конец фрагмент из исходников, где дорога", in: fixture)
        let last = try #require(media.items.last)
        #expect(last.candidateID == road.id && last.assetID == asset.id)
        let music = try await sendAndReopen("Поставь музыку повеселее", in: fixture)
        #expect(music.music?.trackID == fixture.joyfulTrackID)
        let before = try #require(model.previewPlayer?.currentItem)
        let shot = try await frame(before, at: 7)
        let request = "Покажи скорость на последнем клипе"
        let plan = NaturalLanguageDirector().plan(input: NaturalLanguageDirectorInput(
            userRequest: request, currentProject: await pipeline.snapshot(), timeline: music))
        try #require(!plan.requiresBackgroundRefinement)
        let measured = try await sendAndReopen(request, in: fixture)
        #expect(measured.items.map(\.timelineDuration) == music.items.map(\.timelineDuration))
        #expect(measured.effectiveTelemetryItems.count == 1)
        #expect(measured.effectiveTelemetryItems.first?.targetClipID == last.id)
        let preview = try #require(model.previewPlayer?.currentItem)
        #expect(try await frame(preview, at: 7) != shot)
        let output = fixture.root.appendingPathComponent("road-with-speed.mp4")
        let exported = try await pipeline.render(to: output, quality: .maximum)
        #expect(exported.skippedItemIDs.isEmpty)
        let movie = AVPlayerItem(url: output)
        let sound = try await audioSignature(movie, start: 7, duration: 0.5)
        #expect(abs(sound.frequency - 440) < 8)
        let unavailable = try await sendAndReopen("Покажи скорость на первом клипе", in: fixture)
        #expect(unavailable.items == measured.items)
        #expect(unavailable.effectiveTelemetryItems == measured.effectiveTelemetryItems)
        #expect(model.directorMessages.last?.response?.saved == false)
        #expect(model.directorMessages.last?.text.localizedCaseInsensitiveContains("недоступ") == true)
    }

    private func sendAndReopen(_ message: String, in fixture: Fixture) async throws -> Timeline {
        let model = fixture.model
        model.directorInput = message
        model.sendDirectorMessage()
        try await wait { !model.isDirectorResponding && !model.isWorking && model.queuedTimelineAIEditCount == 0 }
        print("Чат монтажёра:", message, "→", model.directorMessages.last?.text ?? "")
        #expect(await model.flushAutosave())
        let store = try ProjectStore(open: fixture.url)
        return try #require(await store.manifest.timelines.last)
    }

    @Test func explicitChatTargetWinsOverSelectionAndCanExpandImmediately() async throws {
        let fixture = try await Fixture(clipCount: 4)
        defer { fixture.remove() }
        fixture.model.selectTitleTimelineItem(fixture.secondTitleID)
        let titleEdit = try await sendAndReopen("Переименуй первый титр в «Сборы»", in: fixture)
        #expect(titleEdit.effectiveTitleItems.map(\.text) == ["Сборы", "Вторая глава"])
        let first = try await sendAndReopen("Сделай первый клип чёрно-белым", in: fixture)
        #expect(first.items.filter { $0.effectiveVideoAdjustments.filter == .monochrome }.count == 1)
        let film = try await sendAndReopen("А лучше на весь фильм", in: fixture)
        #expect(film.items.allSatisfy { $0.effectiveVideoAdjustments.filter == .monochrome })
        #expect(film.effectiveTitleItems == titleEdit.effectiveTitleItems)
    }

    @Test func effectCanMoveBetweenClipsWithoutAccumulatingCopies() async throws {
        let fixture = try await Fixture(clipCount: 4)
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        for (message, indices) in [("Добавь эффект камеры на все клипы", [0, 1, 2, 3]),
                                   ("Нет, только во втором клипе", [1]), ("Только в начале", [0])] {
            model.directorInput = message
            model.sendDirectorMessage()
            try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
            #expect(model.timeline?.effectiveEffects.compactMap(\.targetClipID) == indices.map { original.items[$0].id })
            #expect(model.timeline?.items == original.items)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REAL_COMMENT_DIRECTOR"] == "1"))
    func liveMusicRequestThenOnlyTheFinalSeconds() async throws {
        let fixture = try await Fixture(realDirector: true, clipCount: 4)
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        let script = ["Пускай фоновая мелодия звучит на 17%", "Только последние 2 секунды", "А лучше на 30%", "Нет, лучше на 25%", "Что?", "Передумал, откати последнее изменение"]
        for (index, message) in script.enumerated() {
            model.directorInput = message
            model.sendDirectorMessage()
            try await wait { !model.isDirectorResponding && !model.isWorking && model.queuedTimelineAIEditCount == 0 }
            print("Диалог со звуком:", message, "→", model.directorMessages.last?.text ?? "")
            let timeline = try #require(model.timeline)
            #expect(timeline.items == original.items)
            #expect(timeline.music?.trackID == original.music?.trackID)
            if index == 0 {
                #expect(timeline.music?.volume == 0.17)
            } else {
                let segments = try #require(timeline.effectiveAdaptiveSoundtrack?.segments)
                #expect(segments.first?.timelineStart == 0)
                #expect(segments.first?.directive.volume == original.music?.volume)
                #expect(segments.last?.timelineStart == 4)
                #expect(segments.last?.directive.volume == [1: 0.17, 2: 0.30, 3: 0.25, 4: 0.25, 5: 0.30][index])
                #expect(segments.allSatisfy { $0.directive.trackID == original.music?.trackID })
            }
        }
    }

    @Test func monochromeScopeMatchesSavedClipsPreviewPixelsAndExport() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.model
        let all = try await sendAndReopen("Сделай все клипы чёрно-белыми", in: fixture)
        #expect(all.items.map(\.effectiveVideoAdjustments.filter) == [.monochrome, .monochrome])
        let allPreview = try #require(model.previewPlayer?.currentItem)
        try await checkFrameColor(allPreview, at: 1, monochrome: true)
        try await checkFrameColor(allPreview, at: 4, monochrome: true)
        let last = try await sendAndReopen("Я передумал, оставь это только на последнем плане", in: fixture)
        #expect(last.items.map(\.effectiveVideoAdjustments.filter) == [.none, .monochrome])
        #expect(model.directorMessages.last?.response?.previewReady == true)
        let lastPreview = try #require(model.previewPlayer?.currentItem)
        let output = fixture.root.appendingPathComponent("scope.mp4")
        let pipeline = try #require(model.pipeline)
        _ = try await pipeline.render(to: output, quality: .maximum)
        for item in [lastPreview, AVPlayerItem(url: output)] {
            try await checkFrameColor(item, at: 1, monochrome: false)
            try await checkFrameColor(item, at: 4, monochrome: true)
        }
    }

    private func checkFrameColor(_ item: AVPlayerItem, at seconds: Double, monochrome: Bool) async throws {
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        // Sample the solid background away from both title overlays.
        let patch = try #require(image.cropping(to: CGRect(x: image.width / 8, y: image.height / 8, width: 8, height: 8)))
        var rgb = [UInt8](repeating: 0, count: 4)
        try rgb.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let channels = rgb.prefix(3)
        let maximum = Int(channels.max()!)
        let chroma = maximum - Int(channels.min()!)
        #expect(maximum > 40)
        #expect(monochrome ? chroma < 8 : chroma > 60)
    }

    @Test func missingLastShotReportsASavedEditWithoutClaimingPreviewSuccess() async throws {
        let fixture = try await Fixture(sourceDuration: 0.95)
        defer { fixture.remove() }
        let model = fixture.model
        for message in ["Сделай все клипы чёрно-белыми", "Я передумал, оставь это только на последнем плане"] {
            _ = try await sendAndReopen(message, in: fixture)
            let reply = try #require(model.directorMessages.last)
            #expect(reply.response?.saved == true)
            #expect(reply.response?.previewReady == false)
            #expect(reply.response?.state == .partial)
            #expect(reply.text.contains("source.mov"))
        }
        #expect(model.timeline?.items.map(\.effectiveVideoAdjustments.filter) == [.none, .monochrome])
    }

    @Test(arguments: [false, true]) func filterFollowsFirstClipThenWholeFilm(startOnOneClip: Bool) async throws {
        let fixture = try await Fixture(clipCount: 4)
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        let initial = startOnOneClip ? ("Сделай первый клип чёрно-белым", 1) : ("Сделай все клипы чёрно-белыми", 4)
        for (message, count) in [initial, ("А лучше только на первом", 1),
                                 ("На весь фильм", 4), ("Отмени последнюю правку", 1)] {
            model.directorInput = message
            model.sendDirectorMessage()
            try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
            let current = try #require(model.timeline)
            #expect(current.items.filter { $0.effectiveVideoAdjustments.filter == .monochrome }.map(\.id)
                == Array(original.items.prefix(count)).map(\.id))
            #expect(current.music?.trackID == original.music?.trackID)
        }
    }

    @Test func scopeAfterSavedInsertionDoesNotDuplicateTitle() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.submitTimelineAIEdit("Убери все титры")
        try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
        #expect(model.timeline?.effectiveTitleItems.isEmpty == true)
        model.directorInput = "Докинь титр «Поехали» в конце"
        model.sendDirectorMessage()
        try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
        let titles = try #require(model.timeline?.effectiveTitleItems)
        #expect(titles.filter { $0.text == "Поехали" }.count == 1)
        model.directorInput = "на весь интервал видео"
        model.sendDirectorMessage()
        #expect(model.directorMessages.last?.text.contains("уже сохранена") == true)
        #expect(model.timeline?.effectiveTitleItems == titles)
        #expect(!model.isWorking && !model.isDirectorResponding)
    }

    @Test func chatUndoAndRedoRestoreTheSavedTitleAndLeaveOtherItemsAlone() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        for (message, expected) in [
            ("Нет, давай в последнем титре напишем «До новых встреч».", "До новых встреч"),
            ("Я передумал, отмени последнюю правку.", "Вторая глава"),
            ("Ладно, верни отменённую правку.", "До новых встреч")
        ] {
            model.directorInput = message
            model.sendDirectorMessage()
            try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
            let reopened = try ProjectStore(open: fixture.url)
            let saved = try #require(await reopened.manifest.timelines.last)
            #expect(saved.effectiveTitleItems.last?.text == expected)
            #expect(saved.effectiveTitleItems.last?.id == fixture.secondTitleID)
            #expect(saved.effectiveTitleItems.first == original.effectiveTitleItems.first)
            #expect(saved.items == original.items)
            #expect(model.directorMessages.last?.response?.saved == true)
        }
    }

    @Test func inlineRangeLimitsOrdinaryEffectsToRequestedClips() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        model.submitTimelineAIEdit("Накинь эффект камеры 00:03–00:06")
        try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
        #expect(model.timeline?.effectiveEffects.map(\.targetClipID) == [original.items[1].id])
        #expect(model.directorMessages.last?.response?.range == 3...6)
        #expect(fixture.requests.values.isEmpty)
    }

    @Test func pronounAfterNamedClipDoesNotRequireUnrelatedSelection() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        model.submitTimelineAIEdit("Добавь эффект камеры во втором видео и убери у него звук")
        try await wait { !model.isWorking && model.queuedTimelineAIEditCount == 0 }
        #expect(fixture.requests.values.isEmpty)
        #expect(model.timeline?.effectiveEffects.first { $0.effectType == .videoCamera }?.targetClipID == original.items[1].id)
        #expect(model.timeline?.items[1].effectiveAudioAdjustments.muted == true)
        #expect(model.timeline?.items[0].audioAdjustments == original.items[0].audioAdjustments)
        #expect(model.directorMessages.last?.response?.saved == true)
    }

    @Test(arguments: [false, true]) func everydayCameraRequestSavesPreviewsAndUndoesWithoutModel(throughDirector: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        model.selectTimelineItem(original.items.last!.id)
        let request = "еще хочу эффект камеры в первом видео"
        if throughDirector {
            model.directorInput = request
            model.sendDirectorMessage()
        } else {
            model.submitTimelineAIEdit(request)
        }
        try await wait { !model.isWorking && !model.isDirectorResponding && model.queuedTimelineAIEditCount == 0 }
        #expect(fixture.requests.values.isEmpty)
        let updated = try #require(model.timeline)
        #expect(updated.items == original.items)
        let cameras = updated.effectiveEffects.filter { $0.effectType == .videoCamera }
        #expect(cameras.count == 1)
        #expect(cameras.first?.targetClipID == original.items.first?.id)
        #expect(cameras.first?.duration == original.items.first?.timelineDuration)
        #expect(model.previewPlayer?.currentItem != nil)
        #expect(model.directorMessages.last?.response?.saved == true)
        #expect(model.directorMessages.last?.response?.previewReady == true)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        #expect(await reopened.manifest.timelines.last?.effectiveEffects.filter { $0.effectType == .videoCamera }.count == 1)
        model.undoTimelineEdit()
        try await wait { !model.isWorking && model.timeline?.effectiveEffects == original.effectiveEffects }
        #expect(model.timeline?.items == original.items)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_DIRECTOR_UI_FIXTURE"] != nil))
    func prepareDirectorLiveUIFixture() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let destination = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_DIRECTOR_UI_FIXTURE"]))
        try FileManager.default.copyItem(at: fixture.root, to: destination)
        let files = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "json" {
            let text = try String(contentsOf: file, encoding: .utf8)
            try text.replacingOccurrences(of: fixture.root.path, with: destination.path).write(to: file, atomically: true, encoding: .utf8)
        }
    }

    @Test(arguments: [false, true]) func screenshotRequestUpdatesPreviewAndUndoesAsOneEdit(throughDirector: Bool) async throws {
        let fixture = try await Fixture(commands: [.setOverlay(.greenScreen, .first, .first), .addTitle("путешествие", .beginning)])
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        let request = "добавь в начале фон небо с титром путешествие"
        if throughDirector {
            model.directorInput = request
            model.sendDirectorMessage()
            #expect(model.directorInput.isEmpty)
        } else {
            model.submitTimelineAIEdit(request)
        }
        try await wait { !model.isWorking && model.queuedTimelineAIEditCount == 0 }
        let updated = try #require(model.timeline)
        #expect(updated.items.count == original.items.count + 1)
        #expect(updated.items.dropFirst().map(\.id) == original.items.map(\.id))
        #expect(updated.duration == original.duration + 4)
        #expect(updated.effectiveTitleItems.filter { $0.text == "путешествие" }.count == 1)
        #expect(updated.effectiveTitleItems.first { $0.text == "путешествие" }?.targetClipID == updated.items.first?.id)
        #expect(model.previewPlayer?.currentItem != nil)
        #expect(model.directorMessages.last?.text.contains("Облака") == true)
        #expect(model.directorMessages.last?.text.contains("основной клип для наложения") == false)
        #expect(model.canUndoTimelineEdit)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        #expect(await reopened.manifest.timelines.last?.items == updated.items)
        model.undoTimelineEdit()
        try await wait { !model.isWorking && model.timeline?.items.count == original.items.count }
        #expect(model.timeline?.items == original.items)
        #expect(model.timeline?.effectiveTitleItems == original.effectiveTitleItems)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REAL_COMMENT_DIRECTOR"] == "1"))
    func realLocalDirectorAppliesCompoundMontageAndBrush() async throws {
        let fixture = try await Fixture(realDirector: true)
        defer { fixture.remove() }
        let model = fixture.model
        model.selectTitleTimelineItem(fixture.secondTitleID)
        model.submitTimelineAIEdit("Музыку повеселее и переименуй титр на «Наш маршрут» и добавь крутые эффекты")
        try await wait { !model.isWorking }
        #expect(model.directorRuntimeStatus.hasPrefix(AIAnalysisProfile.resolve(mode: model.aiPowerMode).modelID))
        #expect(model.timeline?.music?.style == .joyful)
        #expect(model.timeline?.effectiveTitleItems.last?.text == "Наш маршрут")
        #expect(model.timeline?.items.allSatisfy { $0.effect == ClipEffect.pushIn.rawValue } == true)
        let outsideAdjustments = model.timeline?.items.last?.effectiveVideoAdjustments
        model.submitTimelineAIEdit("Переименуй титр на «Локальная сцена» и сделай выбранный фрагмент чёрно-белым", range: 0...3)
        try await wait { !model.isWorking }
        #expect(model.directorRuntimeStatus == "Точная монтажная команда")
        #expect(model.timeline?.effectiveTitleItems.first?.text == "Локальная сцена")
        #expect(model.timeline?.effectiveTitleItems.last?.text == "Наш маршрут")
        #expect(model.timeline?.items.first?.effectiveVideoAdjustments.filter == .monochrome)
        #expect(model.timeline?.items.last?.effectiveVideoAdjustments == outsideAdjustments)
        #expect(model.previewPlayer?.currentItem != nil)
        #expect(model.directorMessages.filter { $0.role == .user }.count == 2)
        model.submitTimelineAIEdit("Убери все титры; добавь титр «Старт»; разрежь клип; ускорь в 2 раза; громкость музыки 10%", range: 0...3)
        try await wait { !model.isWorking }
        #expect(model.timeline?.items.count == 3)
        #expect(model.timeline?.items.prefix(2).allSatisfy { $0.speed == 2 } == true)
        #expect(model.timeline?.effectiveTitleItems.filter { $0.startTime < 1.5 }.allSatisfy { $0.text == "Старт" } == true)
        #expect(model.timeline?.effectiveAdaptiveSoundtrack?.segments.first?.directive.volume == 0.1)
        #expect(model.previewPlayer?.currentItem != nil)
        print("REAL COMMENT DIRECTOR: \(model.directorRuntimeStatus); montage and brush applied; preview available")
    }

    @Test func compoundMontageReachesDirectorUpdatesPlaybackAndSurvivesReopen() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.renderPreview()
        try await wait { !model.isWorking }
        let originalPlayerItem = try #require(model.previewPlayer?.currentItem)
        let beforeFrame = try await frame(originalPlayerItem, at: 4)
        model.selectTitleTimelineItem(fixture.secondTitleID)
        let request = "Музыку повеселее и переименуй титр на «Поехали, друзья» и добавь крутые эффекты"
        model.submitTimelineAIEdit(request)
        #expect(model.directorMessages.contains { $0.role == .user && $0.text == request })
        try await wait { !model.isWorking && model.queuedTimelineAIEditCount == 0 }
        #expect(fixture.requests.values.map(\.0) == [request])
        #expect(fixture.requests.values.first?.1.selectedItemSummary?.contains("Титр") == true)
        #expect(model.timeline?.effectiveTitleItems.map(\.text) == ["Первая глава", "Поехали, друзья"])
        #expect(model.timeline?.music?.style == .joyful)
        #expect(model.timeline?.music?.trackID == fixture.joyfulTrackID)
        #expect(model.timeline?.items.allSatisfy { $0.effect == ClipEffect.pushIn.rawValue } == true)
        let updatedPlayerItem = try #require(model.previewPlayer?.currentItem)
        #expect(updatedPlayerItem !== originalPlayerItem)
        #expect(try await frame(updatedPlayerItem, at: 4) != beforeFrame)
        #expect(try await updatedPlayerItem.asset.loadTracks(withMediaType: .audio).isEmpty == false)
        #expect(model.canUndoTimelineEdit)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        let saved = await reopened.manifest
        // Project dates use the manifest's ISO precision; compare through the
        // same codec so subsecond audit timestamps do not hide content parity.
        let visible = try #require(model.timeline)
        let persistedVisible = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(visible))
        #expect(saved.timelines.last == persistedVisible)
        #expect(model.hasUnreadDirectorReply)
        #expect(saved.workspaceState?.hasUnreadDirectorReply == true)
        #expect(saved.workspaceState?.directorMessages?.filter { $0.role == .user && $0.text == request }.count == 1)
        #expect(saved.workspaceState?.directorMessages?.last?.response?.saved == true)
        #expect(saved.workspaceState?.directorMessages?.last?.response?.previewReady == true)
    }

    @Test func conversationalBrushAppliesNamedLookAcrossTwoShotsAndUndoes() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        model.renderPreview()
        try await wait { !model.isWorking }
        let before = try #require(model.previewPlayer?.currentItem)
        let inside = try await frame(before, at: 2)
        let outside = try await frame(before, at: 5.5)
        model.submitTimelineAIEdit("добавь тут фильтр пикселизация", range: 1...5)
        try await wait { !model.isWorking && !model.isDirectorResponding }
        let updated = try #require(model.timeline)
        let effects = updated.effectiveEffects.sorted { $0.startTime < $1.startTime }
        #expect(effects.map(\.effectType) == [.pixelate, .pixelate])
        #expect(effects.map(\.startTime) == [1, 3] && effects.map(\.endTime) == [3, 5])
        #expect(model.directorMessages.last?.response?.saved == true)
        #expect(model.directorMessages.last?.response?.previewReady == true)
        let after = try #require(model.previewPlayer?.currentItem)
        #expect(try await frame(after, at: 2) != inside)
        #expect(try await frame(after, at: 5.5) == outside)
        #expect(fixture.requests.values.isEmpty)
        let reopened = try ProjectStore(open: fixture.url)
        #expect(await reopened.manifest.timelines.last?.effectiveEffects == updated.effectiveEffects)
        model.directorInput = "А что именно поменялось?"
        model.sendDirectorMessage()
        try await wait { !model.isDirectorResponding }
        #expect(model.directorMessages.last?.text.contains("Пикселизация") == true)
        #expect(model.timeline == updated)
        model.directorInput = "Отмени последнюю правку"
        model.sendDirectorMessage()
        try await wait { !model.isWorking && !model.isDirectorResponding }
        #expect(model.timeline?.effectiveEffects == original.effectiveEffects)
        #expect(model.timeline?.items == original.items)
    }

    @Test func directorResolvesHereAtThePlayheadAndKeepsLaterEditsLocal() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.seekTimeline(to: 4)
        model.directorInput = "Накинь тут сепию"
        model.sendDirectorMessage()
        try await wait { !model.isWorking && !model.isDirectorResponding }
        #expect(model.timeline?.items.map { $0.effectiveVideoAdjustments.filter } == [.none, .sepia])
        model.submitTimelineAIEdit("Сделай тут без звука и добавь глитч", range: 1...2)
        try await wait { !model.isWorking && !model.isDirectorResponding }
        let timeline = try #require(model.timeline)
        #expect(timeline.items.filter { $0.effectiveAudioAdjustments.muted }.map(\.timelineStart) == [1])
        let effect = try #require(timeline.effectiveEffects.first)
        #expect(effect.effectType == .glitch && effect.startTime == 1 && effect.endTime == 2)
        #expect(timeline.items.last?.effectiveVideoAdjustments.filter == .sepia)
        model.submitTimelineAIEdit("блюр", range: 4...5)
        try await wait { !model.isWorking && !model.isDirectorResponding }
        let blur = try #require(model.timeline?.effectiveEffects.first { $0.effectType == .blur })
        #expect(blur.startTime == 4 && blur.endTime == 5)
        #expect(model.directorMessages.dropLast().last?.text == "блюр")
        #expect(fixture.requests.values.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REAL_COMMENT_DIRECTOR"] == "1"))
    func realBrushInterpretsAnAppearanceWithoutAnEffectName() async throws {
        let fixture = try await Fixture(realDirector: true)
        defer { fixture.remove() }
        let model = fixture.model
        model.submitTimelineAIEdit("Оставь в этом куске только серые тона, пусть все цвета исчезнут", range: 0...3)
        try await wait { !model.isWorking && !model.isDirectorResponding }
        let timeline = try #require(model.timeline)
        print("Режиссёр о серых тонах:", model.directorMessages.last?.text ?? "")
        let shot = try #require(timeline.items.first)
        #expect(shot.effectiveVideoAdjustments.filter == .monochrome || shot.effectiveVideoAdjustments.saturation == 0)
        #expect(timeline.items.last?.effectiveVideoAdjustments == VideoAdjustments())
        #expect(model.directorMessages.last?.response?.saved == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REAL_COMMENT_DIRECTOR"] == "1"))
    func realBrushFindsAnOpticalEffectForAPeephole() async throws {
        let fixture = try await Fixture(realDirector: true)
        defer { fixture.remove() }
        let model = fixture.model
        model.submitTimelineAIEdit("Сделай картинку выпуклой, словно смотришь через дверной глазок", range: 3...5)
        try await wait { !model.isWorking && !model.isDirectorResponding }
        print("Режиссёр о дверном глазке:", model.directorMessages.last?.text ?? "")
        let effects = try #require(model.timeline).effectiveEffects
        #expect(effects.count == 1)
        let optical: Set<TimelineEffectType> = [.fisheye, .barrelDistortion, .lensDistortion]
        #expect(effects.contains { optical.contains($0.effectType) && $0.startTime == 3 && $0.endTime == 5 })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REAL_COMMENT_DIRECTOR"] == "1"))
    func realBrushChoosesCassetteEffectFromDescriptionThenHandlesMusic() async throws {
        let fixture = try await Fixture(realDirector: true)
        defer { fixture.remove() }
        let model = fixture.model
        model.submitTimelineAIEdit("Добавь такой эффект, будто смотришь затёртую видеокассету из девяностых", range: 1...2)
        try await wait { !model.isWorking && !model.isDirectorResponding }
        print("Режиссёр о видеокассете:", model.directorMessages.last?.text ?? "")
        let timeline = try #require(model.timeline)
        let effect = try #require(timeline.effectiveEffects.first { $0.effectType == .vhsDistortion })
        #expect(effect.startTime == 1 && effect.endTime == 2)
        #expect(timeline.items.allSatisfy { $0.effect == nil })
        model.submitTimelineAIEdit("Музыку на 12%", range: 1...2)
        try await wait { !model.isWorking && !model.isDirectorResponding }
        #expect(model.timeline?.effectiveAdaptiveSoundtrack?.segments.map(\.directive.volume) == [0.18, 0.12, 0.18])
        #expect(model.timeline?.effectiveEffects == timeline.effectiveEffects)
        model.submitTimelineAIEdit("Какая громкость музыки?", range: 1...2)
        try await wait { !model.isDirectorResponding }
        #expect(model.directorMessages.last?.text.contains("12%") == true)
    }

    @Test func brushChangesMusicOnlyInsideRangeAndRecordsItInDirectorChat() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.model
        let originalMusic = model.timeline?.music
        let request = "Переименуй титр на «Здесь» и добавь крутые эффекты; музыку повеселее"
        model.section = .timeline
        model.submitTimelineAIEdit(request, range: 1...2)
        #expect(!model.hasUnreadDirectorReply)
        try await wait { !model.isWorking }
        #expect(model.hasUnreadDirectorReply)
        model.openSection(.director)
        #expect(!model.hasUnreadDirectorReply)
        model.section = .timeline
        #expect(!model.hasUnreadDirectorReply)
        #expect(fixture.requests.values.map(\.0) == [request])
        #expect(fixture.requests.values.first?.1.selectedItemSummary?.contains("Только выделенный диапазон") == true)
        let timeline = try #require(model.timeline)
        #expect(timeline.music == originalMusic)
        let regions = try #require(timeline.effectiveAdaptiveSoundtrack?.segments)
        #expect(regions.count == 3)
        #expect(regions.map(\.timelineStart) == [0, 1, 2])
        #expect(regions.map(\.directive.trackID) == [originalMusic?.trackID, fixture.joyfulTrackID, originalMusic?.trackID])
        for item in timeline.items {
            #expect((item.effect == ClipEffect.pushIn.rawValue) == (item.timelineStart >= 1 && item.timelineStart < 2))
        }
        #expect(timeline.effectiveTitleItems.contains { $0.text == "Здесь" && $0.startTime >= 1 && $0.endTime <= 2 })
        #expect(timeline.effectiveTitleItems.contains { $0.text == "Вторая глава" })
        #expect(model.previewPlayer?.currentItem != nil)
        #expect(model.directorMessages.last?.response?.range == 1...2)
        #expect(model.directorMessages.last?.text.contains("Только в выделенном диапазоне") == true)
        let playerItem = try #require(model.previewPlayer?.currentItem)
        let audioTracks = try await playerItem.asset.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == 3)
        let selectedSound = try await audioSignature(playerItem, start: 1.2, duration: 0.5)
        let outsideSound = try await audioSignature(playerItem, start: 3.2, duration: 0.5)
        #expect(selectedSound.frequency > 420 && selectedSound.frequency < 460)
        #expect(outsideSound.frequency > 200 && outsideSound.frequency < 240)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        #expect(await reopened.manifest.workspaceState?.hasUnreadDirectorReply != true)
        #expect(await reopened.manifest.workspaceState?.directorMessages?.last?.text == model.directorMessages.last?.text)
        model.submitTimelineAIEdit("Какая громкость музыки?")
        try await wait { !model.isDirectorResponding }
        #expect(model.hasUnreadDirectorReply)
        model.openSection(.director)
        model.submitTimelineAIEdit("Какая громкость музыки?")
        try await wait { !model.isDirectorResponding }
        model.section = .timeline
        #expect(!model.hasUnreadDirectorReply)
    }

    @Test func semanticBrushUsesModelCommandsAndCancelledQueueStaysInHistory() async throws {
        let fixture = try await Fixture(commands: [.setFilter(.monochrome, .all)])
        defer { fixture.remove() }
        fixture.model.submitTimelineAIEdit("Сделай здесь как в старом кино", range: 0...3)
        try await wait { !fixture.model.isWorking }
        #expect(fixture.model.timeline?.items.first?.effectiveVideoAdjustments.filter == .monochrome)
        #expect(fixture.model.timeline?.items.last?.effectiveVideoAdjustments.filter == VideoFilter.none)
        fixture.model.isWorking = true
        fixture.model.submitTimelineAIEdit("громкость музыки 20%")
        fixture.model.cancelOperation()
        fixture.model.isWorking = false
        #expect(fixture.model.directorMessages.last?.text.contains("отменена до выполнения") == true)
        #expect(fixture.model.queuedTimelineAIEditCount == 0)
    }

    @Test func brushVolumeChangesRenderedAudioOnlyInsideSelection() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.model.submitTimelineAIEdit("громкость музыки 5%", range: 1...2)
        try await wait { !fixture.model.isWorking }
        let item = try #require(fixture.model.previewPlayer?.currentItem)
        let inside = try await audioSignature(item, start: 1.2, duration: 0.5)
        let outside = try await audioSignature(item, start: 2.2, duration: 0.5)
        print("LOCAL AUDIO MIX: inside \(inside), outside \(outside), regions \(String(describing: fixture.model.timeline?.effectiveAdaptiveSoundtrack?.segments.map { $0.directive.volume }))")
        #expect(inside.rms > 0)
        #expect(abs(inside.rms / outside.rms - 0.05 / 0.18) < 0.03)
        #expect(fixture.model.directorMessages.last?.response?.previewReady == true)
    }

    private func audioSignature(_ item: AVPlayerItem, start: Double, duration: Double) async throws -> (rms: Double, frequency: Double) {
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: item.asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVNumberOfChannelsKey: 1, AVSampleRateKey: 8_000
        ])
        output.audioMix = item.audioMix
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
        #expect(reader.startReading())
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetDataBuffer(sample) {
            let count = CMBlockBufferGetDataLength(buffer) / MemoryLayout<Float>.size
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            #expect(status == kCMBlockBufferNoErr)
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let lower = min(chunk.count, max(0, Int(ceil((start - time) * 8_000))))
            let upper = min(chunk.count, max(lower, Int(floor((start + duration - time) * 8_000))))
            samples += chunk[lower..<upper]
        }
        #expect(reader.status == .completed)
        #expect(!samples.isEmpty)
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count)))
        let crossings = zip(samples, samples.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
        return (rms, Double(crossings) * 8_000 / Double(max(1, samples.count)))
    }

    private func frame(_ item: AVPlayerItem, at seconds: Double) async throws -> Data {
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return try #require(result.image.dataProvider?.data) as Data
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(90)
        repeat {
            try await Task.sleep(for: .milliseconds(20))
            if predicate() { return }
        } while Date() < deadline
        throw WaitError.timeout
    }
    private enum WaitError: Error { case timeout }

    private final class Requests { var values: [(String, DirectorContext)] = [] }
    @MainActor private struct Fixture {
        let root: URL
        let url: URL
        let suite: String
        let model: AppModel
        let requests: Requests
        let secondTitleID: UUID
        let joyfulTrackID: UUID
        private let mutePreview: AnyCancellable

        init(commands: [EditorCommand] = [], realDirector: Bool = false, titleTexts: [String] = ["Первая глава", "Вторая глава"], clipCount: Int = 2, completedFilm: Bool = false, sourceDuration: Double = 6) async throws {
            suite = "VeloEdit.timeline-director.\(UUID())"
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            url = root.appendingPathComponent("test.veloedit")
            let store = try ProjectStore(createAt: url, name: "Director integration")
            let source = try await TitleCardVideoGenerator().generate(text: "SOURCE", style: TitleStyle(backgroundColorHex: "#cc5520"), duration: sourceDuration,
                width: 640, height: 360, frameRate: 20, destination: root.appendingPathComponent("source.mov"), codec: .jpeg)
            let asset = MediaAsset(originalURL: source, kind: .video, byteSize: 1, contentHash: UUID().uuidString,
                metadata: MediaMetadata(duration: 6, width: 640, height: 360, frameRate: 20, hasAudio: false))
            let library = LocalMusicLibrary(rootURL: store.musicLibraryURL)
            let calm = try await Self.track(root: root, library: library, title: "Calm", mood: "calm", frequency: 220)
            let happy = try await Self.track(root: root, library: library, title: "Happy", mood: "joyful", frequency: 440)
            joyfulTrackID = happy.id
            let titles = [TitleTimelineItem(kind: .title, text: titleTexts[0], startTime: 0, duration: 3),
                          TitleTimelineItem(kind: .title, text: titleTexts[1], startTime: 3, duration: 3)]
            secondTitleID = titles[1].id
            let clipDuration = 6 / Double(clipCount)
            let items: [TimelineItem] = (0..<clipCount).map { index in
                let start = Double(index) * clipDuration
                return TimelineItem(assetID: asset.id, kind: .video, sourceStart: start, sourceDuration: clipDuration, timelineStart: start, timelineDuration: clipDuration)
            }
            var music = MusicDirective(style: .calm, bpm: 68)
            music.trackID = calm.id
            music.trackTitle = calm.title
            let timeline = Timeline(storyPlanID: UUID(), width: 640, height: 360, frameRate: 20,
                items: items, titleItems: titles, music: music)
            try await store.update { $0.assets = [asset]; $0.timelines = [timeline] }
            if completedFilm {
                _ = try await store.beginAutonomousJob(kind: .film)
                try await store.updateAutonomousJob {
                    $0.state = .completed
                    $0.processProfile = FilmProcessProfile(analysis: AIAnalysisProfile.resolve(mode: .fast))
                    $0.resultTimelineID = timeline.id
                }
            }
            let recorder = Requests()
            requests = recorder
            let agent = LocalDirectorAgent { message, context, _, _ in
                recorder.values.append((message, context))
                return DirectorAIReply(text: "План", runtimeLabel: "Test director", normalizedBrief: nil, commands: commands)
            }
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(true, forKey: "freeToUseLicenseAccepted.v1")
            let taste = LocalPersonalTasteStore(url: root.appendingPathComponent("taste.json"))
            model = AppModel(defaults: defaults, startBackgroundServices: false, personalTasteStore: taste, directorAgent: realDirector ? LocalDirectorAgent() : agent)
            // Exercise real playback without sending the fixture's sine waves to the speakers.
            mutePreview = model.$previewPlayer.sink { $0?.isMuted = true }
            model.pipeline = VeloEditPipeline(store: store, musicLibrary: library,
                musicSystem: MusicLibrary(localLibrary: library, providers: [LocalMusicProvider(library: library)]),
                musicSelectionHistory: LocalMusicSelectionHistoryStore(url: root.appendingPathComponent("history.json")), personalTasteStore: taste)
            model.projectURL = url
            model.project = await store.manifest
        }

        private static func track(root: URL, library: LocalMusicLibrary, title: String, mood: String, frequency: Double) async throws -> LocalMusicTrack {
            let url = root.appendingPathComponent(title + ".wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000)!
            buffer.frameLength = buffer.frameCapacity
            for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * frequency / 8_000) * 0.15) }
            try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
            return try await library.importExistingTrack(LocalMusicTrack(title: title, author: "Test", bpm: mood == "calm" ? 68 : 112,
                genres: ["instrumental"], moods: [mood], energy: mood == "calm" ? 0.2 : 0.62, duration: 10,
                license: .userFile(), sourceProvider: .user, sourcePageURL: url, localFileURL: url, originalFileName: url.lastPathComponent))
        }

        func remove() {
            model.cancelOperation()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
