import Foundation
import Testing
@testable import VeloEditCore

private actor IncompleteCitationTitleModel: ChapterTitleModel {
    nonisolated let identity = "incomplete-citation-fixture"
    var attempts = 0
    var receivedFeedback = false
    func generate(_ input: ChapterTitleInput) async throws -> ChapterThemeProposal {
        attempts += 1
        receivedFeedback = input.limitations.contains { $0.contains("Previous proposals failed verification") }
        let ids = input.evidence.filter(\.selected).map(\.id)
        return .init(theme: "Сплав", setting: "Река", secondaryActivities: [], contradictions: [], unknowns: [],
            titles: [.init(text: "Сплав по реке", claims: [.init(text: "Сплав по реке", kind: "activity",
                evidenceIDs: attempts == 1 ? Array(ids.prefix(1)) : ids)])])
    }
    func verify(_ proposal: ChapterTitleProposal, input: ChapterTitleInput) async throws -> ChapterTitleVerification {
        .init(accepted: true, reasons: ["Наблюдаемая гребля в выбранных планах всей части"], unsupportedClaims: [],
            evidenceIDs: proposal.claims.flatMap(\.evidenceIDs), coversWholePart: true)
    }
}

private actor TitleModelProbe: ChapterTitleModel {
    nonisolated let identity: String
    var calls = 0
    var receivedCacheIdentities: [String?] = []
    let text: String
    let kind: String
    let rejects: Bool
    let fails: Bool
    let delay: UInt64
    init(text: String = "Сплав по реке", kind: String = "activity", identity: String = "fixture@v1", rejects: Bool = false, fails: Bool = false, delay: UInt64 = 0) {
        self.text = text; self.kind = kind; self.identity = identity; self.rejects = rejects; self.fails = fails; self.delay = delay
    }
    func generate(_ input: ChapterTitleInput) async throws -> ChapterThemeProposal {
        calls += 1
        receivedCacheIdentities.append(input.responseCacheIdentity)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if fails { throw URLError(.cannotParseResponse) }
        return .init(theme: "Сплав", setting: "Река", secondaryActivities: ["Сборы", "Привал"], contradictions: [], unknowns: [],
            titles: [.init(text: text, claims: [.init(text: text, kind: kind, evidenceIDs: input.evidence.filter(\.selected).map(\.id))])])
    }
    func verify(_ proposal: ChapterTitleProposal, input: ChapterTitleInput) async throws -> ChapterTitleVerification {
        calls += 1
        return .init(accepted: !rejects, reasons: [rejects ? "Object without activity" : "Repeated movement on the river throughout the selected part"],
            unsupportedClaims: rejects ? [proposal.text] : [], evidenceIDs: proposal.claims.flatMap(\.evidenceIDs), coversWholePart: !rejects)
    }
}

@Suite(.serialized)
struct SmartChapterTitlesTests {
    private actor LanguageRepairModel: ChapterTitleModel {
        nonisolated let identity = "language-repair-fixture"
        var generated = 0
        var checked = 0
        var receivedSpecificFeedback = false
        func generate(_ input: ChapterTitleInput) async throws -> ChapterThemeProposal {
            generated += 1
            receivedSpecificFeedback = input.limitations.contains { $0.contains("synthetic grammar defect") }
            let title = generated == 1 ? "Лодка плывутся" : "Сплав по реке"
            return .init(theme: "Сплав", setting: "Река", secondaryActivities: [], contradictions: [], unknowns: [],
                titles: [.init(text: title, claims: [.init(text: title, kind: "activity",
                    evidenceIDs: input.evidence.filter(\.selected).map(\.id))])])
        }
        func verify(_ proposal: ChapterTitleProposal, input: ChapterTitleInput) async throws -> ChapterTitleVerification {
            checked += 1
            return .init(accepted: checked > 1,
                reasons: [checked == 1 ? "synthetic grammar defect: inconsistent word forms" : "Grounded, grammatical chapter title"],
                unsupportedClaims: [], evidenceIDs: proposal.claims.flatMap(\.evidenceIDs), coversWholePart: true)
        }
    }

    @Test func languageOnlyRejectionMustBeRepairedAndIndependentlyVerified() async throws {
        let (timeline, plan, assets, analyses) = fixture(partCount: 1)
        let model = LanguageRepairModel()
        let result = try await SmartChapterTitleEngine().applying(to: timeline, plan: plan,
            assets: assets, analyses: analyses, mode: .fast, model: model)
        #expect(await model.generated == 2)
        #expect(await model.checked == 2)
        #expect(await model.receivedSpecificFeedback)
        let decision = try #require(result.chapterTitleDecisions?.first)
        #expect(decision.text == "Сплав по реке")
        #expect(decision.verifications.map(\.accepted) == [false, true])
        #expect(decision.modelID == model.identity)
        #expect(result.items == timeline.items)
    }

    @Test func editedWordingMustPassIndependentVerificationAndCannotReuseTheOriginalVerdict() async throws {
        actor EditedModel: ChapterTitleModel {
            nonisolated let identity = "same-selected-model"
            nonisolated let requiresWordingEdit = true
            var checked: [String] = []
            func generate(_ input: ChapterTitleInput) async throws -> ChapterThemeProposal {
                .init(theme: "Сплав", setting: "Река", secondaryActivities: [], contradictions: [], unknowns: [],
                    titles: [.init(text: "Сплав по реке", claims: [.init(text: "Сплав по реке", kind: "activity", evidenceIDs: input.evidence.map(\.id))])])
            }
            func editWording(_ theme: ChapterThemeProposal, input: ChapterTitleInput) async throws -> ChapterThemeProposal {
                var edited = theme; edited.titles[0].text = "На Марсе"; return edited
            }
            func verify(_ proposal: ChapterTitleProposal, input: ChapterTitleInput) async throws -> ChapterTitleVerification {
                checked.append(proposal.text)
                return .init(accepted: false, reasons: ["The edit invents a place"], unsupportedClaims: ["Марс"],
                    evidenceIDs: input.evidence.map(\.id), coversWholePart: false)
            }
        }
        let (timeline, plan, assets, analyses) = fixture(partCount: 1)
        let model = EditedModel()
        let result = try await SmartChapterTitleEngine().applying(to: timeline, plan: plan,
            assets: assets, analyses: analyses, mode: .fast, model: model)
        #expect(await model.checked == ["На Марсе", "На Марсе", "На Марсе"])
        let decision = try #require(result.chapterTitleDecisions?.first)
        #expect(decision.source == .fallback && decision.text != "На Марсе")
        #expect(decision.modelCalls == 9)
        #expect(decision.verifications.allSatisfy { !$0.accepted })
        #expect(result.items == timeline.items)
    }

    @Test func rawTitleCacheProvenanceIgnoresOnlyNewAssemblyIDs() async throws {
        let (timeline, plan, assets, analyses) = fixture(partCount: 1)
        let model = TitleModelProbe()
        _ = try await SmartChapterTitleEngine().applying(to: timeline, plan: plan,
            assets: assets, analyses: analyses, mode: .balanced, model: model)
        var rebuilt = timeline
        for i in rebuilt.items.indices { rebuilt.items[i].id = UUID() }
        _ = try await SmartChapterTitleEngine().applying(to: rebuilt, plan: plan,
            assets: assets, analyses: analyses, mode: .balanced, model: model)
        let initial = await model.receivedCacheIdentities
        #expect(initial.count == 2 && initial[0] != nil && initial[0] == initial[1])
        rebuilt.items[0].sourceStart += 0.1
        _ = try await SmartChapterTitleEngine().applying(to: rebuilt, plan: plan,
            assets: assets, analyses: analyses, mode: .balanced, model: model)
        let changed = await model.receivedCacheIdentities
        #expect(changed.last! != initial[0])
    }

    private actor CachedTitleTransport {
        var calls = 0
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            calls += 1
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let generation = (messages[0]["content"] as! String).contains("Предложи название")
            let content = generation
                ? #"{"theme":"Река","setting":"Берег","secondaryActivities":[],"contradictions":[],"unknowns":[],"titles":[{"text":"У реки","claims":[{"text":"У реки","kind":"setting","evidenceIDs":["e0"]}]}]}"#
                : #"{"accepted":true,"reasons":["A river is visible throughout the selected part"],"unsupportedClaims":[],"evidenceIDs":["e0"],"coversWholePart":true}"#
            let bytes = try JSONSerialization.data(withJSONObject: ["model": body["model"]!, "done": true,
                "done_reason": "stop", "message": ["content": content]])
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func titleResponseCacheRetainsIndependentVerificationAndExactEvidenceAndWeights() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CachedTitleTransport()
        var model = LocalChapterTitleModel(model: "qwen3-vl:2b-instruct", digest: "weights-a", mode: .fast, responseCacheURL: root)
        model.answerTransport = { try await transport.send($0) }
        let evidence = ChapterTitleEvidence(id: "e0", assetID: UUID(), itemID: UUID(),
            sourceStart: 0, sourceEnd: 5, timelineStart: 0, timelineEnd: 5,
            origin: .visualSummary, observation: "A wide river runs between wooded banks", selected: true,
            frameTimes: [0, 1, 2, 3, 4], actionSequence: false)
        var input = ChapterTitleInput(partID: UUID(), ordinal: 1, duration: 5, language: "ru", maxCharacters: 48,
            evidence: [evidence], coverage: .init(selectedSeconds: 5, observedSeconds: 5,
                sampledEvidenceCount: 1, availableEvidenceCount: 1, beginning: true, middle: true, end: true),
            limitations: [], responseCacheIdentity: "exact-source-images-and-review-a")
        let first = try await model.generate(input)
        let verified = try await model.verify(first.titles[0], input: input)
        #expect(verified.accepted)
        #expect(await transport.calls == 2)
        input.partID = UUID(); input.evidence[0].itemID = UUID()
        let reused = try await model.generate(input)
        _ = try await model.verify(reused.titles[0], input: input)
        #expect(await transport.calls == 2)
        input.responseCacheIdentity = "same-words-but-different-source-images-or-review"
        _ = try await model.generate(input)
        #expect(await transport.calls == 3)
        input.evidence[0].observation += " A bird crosses the image."
        _ = try await model.generate(input)
        #expect(await transport.calls == 4)
        var changedModel = LocalChapterTitleModel(model: "qwen3-vl:2b-instruct", digest: "weights-b", mode: .fast, responseCacheURL: root)
        changedModel.answerTransport = { try await transport.send($0) }
        _ = try await changedModel.generate(input)
        #expect(await transport.calls == 5)
    }

    @Test func rejectedSingleShotCitationGetsOneGroundedRetryBeforeNumberedFallback() async throws {
        let (timeline, plan, assets, analyses) = fixture(partCount: 1)
        let model = IncompleteCitationTitleModel()
        let result = try await SmartChapterTitleEngine().applying(to: timeline, plan: plan, assets: assets,
            analyses: analyses, mode: .balanced, model: model)
        #expect(await model.attempts == 2)
        #expect(await model.receivedFeedback)
        #expect(result.chapterTitleDecisions?.first?.source == .model)
        #expect(result.chapterTitleDecisions?.first?.modelCalls == 3)
        #expect(result.items == timeline.items)
    }

    func fixture(partCount: Int = 2, withActions: Bool = true) -> (Timeline, StoryPlan, [MediaAsset], [AnalysisResult]) {
        var items: [TimelineItem] = [], chapters: [StoryChapter] = [], assets: [MediaAsset] = [], analyses: [AnalysisResult] = []
        for partIndex in 0..<partCount {
            let event = UUID()
            // Multiple files and technical scenes in each established part.
            for index in 0..<3 {
                let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/source-\(partIndex)-\(index).mov"), kind: .video,
                    byteSize: 10, contentHash: "bytes-\(partIndex)-\(index)", metadata: .init(duration: 10))
                var insights = CandidateInsights(sceneSummary: withActions ? "Люди гребут на байдарках по реке" : "Велосипед стоит у стены")
                if withActions {
                    insights.editorialEvidence = .init(samples: [1, 4, 8].map { .init(sourceTime: $0, actionState: ["rowing"], confidence: 0.9) }, usableRange: .init(start: 0, end: 10))
                }
                let candidate = Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 10, scores: .init(quality: 0.8, interest: 0.8, action: 0.8, stability: 0.8),
                    tags: withActions ? ["kayak", "river"] : ["bicycle"], insights: insights)
                let scene = UUID()
                items.append(.init(candidateID: candidate.id, assetID: asset.id, kind: .video, sourceDuration: 10,
                    timelineStart: Double(items.count * 10), timelineDuration: 10, eventID: event, eventSceneID: scene))
                chapters.append(.init(title: index == 1 ? "Действие" : "Сборы", candidateIDs: [candidate.id], eventID: event, eventSceneID: scene))
                assets.append(asset)
                analyses.append(.init(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [candidate]))
            }
        }
        let plan = StoryPlan(prompt: "Титр в начале каждой части", preset: .story, constraints: PromptInterpreter.defaults(for: .story), chapters: chapters,
            directorBrief: DirectorBrief(titlePolicy: .keyOnly))
        return (Timeline(storyPlanID: plan.id, items: items), plan, assets, analyses)
    }

    @Test func wholePartsKeepMembershipAndEqualNamesAcrossScenesAndFiles() async throws {
        let (before, plan, assets, analyses) = fixture()
        let model = TitleModelProbe()
        let after = try await SmartChapterTitleEngine().applying(to: before, plan: plan, assets: assets, analyses: analyses, mode: .balanced, model: model)
        #expect(after.items == before.items)
        #expect(after.music == before.music && after.duration == before.duration)
        #expect(after.filmParts?.count == 2)
        #expect(after.filmParts?.allSatisfy { $0.itemIDs.count == 3 } == true)
        #expect(after.effectiveTitleItems.map(\.text) == ["Сплав по реке", "Сплав по реке"])
        #expect(after.effectiveTitleItems.map(\.startTime) == [0, 30])
        #expect(after.effectiveTitleItems.allSatisfy { $0.targetClipID == nil && $0.filmPartID != nil })
        #expect(await model.calls == 4)
        #expect(EditorialPresentationPolicy.missingChapterTitles(in: after, plan: plan).isEmpty)
        var changedPlan = plan
        for i in changedPlan.chapters.indices { changedPlan.chapters[i].title = "Иное название \(i)" }
        #expect(FilmPartPolicy.parts(in: after, plan: changedPlan) == after.filmParts)
    }

    @Test func persistedCacheDoesNotCallModelAndRenamingFilesDoesNotInvalidateIt() async throws {
        let (before, plan, originalAssets, analyses) = fixture()
        let model = TitleModelProbe()
        let generated = try await SmartChapterTitleEngine().applying(to: before, plan: plan, assets: originalAssets, analyses: analyses, mode: .fast, model: model)
        let saved = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(generated))
        var assets = originalAssets
        for i in assets.indices { assets[i].displayName = "Переименовано"; assets[i].originalURL = URL(fileURLWithPath: "/tmp/new-name\(i)") }
        for _ in 0..<5 {
            let cached = try await SmartChapterTitleEngine().applying(to: saved, plan: plan, assets: assets, analyses: analyses, mode: .fast, model: model)
            #expect(cached == generated)
        }
        #expect(await model.calls == 4)
    }

    @Test func onlyAffectedPartRecomputesAndModelVersionInvalidatesCache() async throws {
        let (before, plan, assets, originalAnalyses) = fixture()
        let model = TitleModelProbe()
        let generated = try await SmartChapterTitleEngine().applying(to: before, plan: plan, assets: assets, analyses: originalAnalyses, mode: .quality, model: model)
        var analyses = originalAnalyses
        analyses[0].candidates[0].insights?.sceneSummary = "Две байдарки движутся по реке"
        let changed = try await SmartChapterTitleEngine().applying(to: generated, plan: plan, assets: assets, analyses: analyses, mode: .quality, model: model)
        #expect(await model.calls == 6)
        #expect(changed.chapterTitleDecisions?[1] == generated.chapterTitleDecisions?[1])
        let updated = TitleModelProbe(identity: "fixture@v2")
        _ = try await SmartChapterTitleEngine().applying(to: changed, plan: plan, assets: assets, analyses: analyses, mode: .quality, model: updated)
        #expect(await updated.calls == 4)
    }

    @Test func manualTextStyleAndReferenceHavePriority() async throws {
        var (before, plan, assets, analyses) = fixture()
        var title = TitleTimelineItem(kind: .chapter, text: "Наш сплав", startTime: 0, duration: 5, style: .init(fontSize: 60, textColorHex: "#FF0000"))
        title.userEdited = true
        before.titleItems = [title]
        plan.approvedSourceChapterLabels = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, ChapterTitleReference.Label(text: "Эталон", order: 0)) })
        let model = TitleModelProbe()
        let generated = try await SmartChapterTitleEngine().applying(to: before, plan: plan, assets: assets, analyses: analyses, mode: .balanced, model: model)
        #expect(generated.effectiveTitleItems.map(\.text) == ["Наш сплав", "Эталон"])
        #expect(generated.effectiveTitleItems[0].style == title.style)
        #expect(generated.effectiveTitleItems[0].duration == title.duration)
        #expect(generated.chapterTitleDecisions?.map(\.source) == [.user, .reference])
        #expect(await model.calls == 0)
    }

    @Test func objectOnlyEvidenceCannotProveAnActionAndVerifierCanRejectIt() async throws {
        let (before, plan, assets, analyses) = fixture(partCount: 1, withActions: false)
        let model = TitleModelProbe(text: "Велопрогулка", rejects: true)
        let after = try await SmartChapterTitleEngine().applying(to: before, plan: plan, assets: assets, analyses: analyses, mode: .fast, model: model)
        #expect(after.effectiveTitleItems.map(\.text) == ["Часть 1"])
        #expect(after.chapterTitleDecisions?.first?.source == .fallback)
        #expect(after.chapterTitleDecisions?.first?.verifications.first?.accepted == false)
    }

    @Test func outOfCutEventAndSpeechAreNotVisualProof() async throws {
        var (before, plan, assets, analyses) = fixture(partCount: 1)
        // Selected trims contain no temporal action observations. The original
        // whole-candidate summary still mentions the excluded river trip.
        for i in before.items.indices {
            before.items[i].sourceDuration = 0.8
            before.items[i].timelineDuration = 0.8
            before.items[i].timelineStart = Double(i) * 0.8
            analyses[i].candidates[0].insights?.speech = .init(text: "Завтра пойдём в сплав", phraseStart: 0, phraseEnd: 0.7, confidence: 1, startsAtPhraseBoundary: true, endsAtPhraseBoundary: true)
        }
        let model = TitleModelProbe()
        let after = try await SmartChapterTitleEngine().applying(to: before, plan: plan, assets: assets, analyses: analyses, mode: .fast, model: model)
        #expect(after.effectiveTitleItems.first?.text == "Часть 1")
        #expect(await model.calls == 0)
    }

    @Test func malformedResponseCannotRetainAnUnverifiedAutomaticTitle() async throws {
        var (before, plan, assets, analyses) = fixture(partCount: 1)
        before.titleItems = [.init(kind: .chapter, text: "Сохранённый титр", startTime: 0, duration: 4, explanation: ["Editorial chapter"]) ]
        let after = try await SmartChapterTitleEngine().applying(to: before, plan: plan, assets: assets, analyses: analyses, mode: .fast, model: TitleModelProbe(fails: true))
        #expect(after.effectiveTitleItems.first?.text == "Часть 1")
        #expect(after.chapterTitleDecisions?.first?.source == .fallback)
        #expect(after.chapterTitleDecisions?.first?.fallbackReason != nil)
        #expect(after.items == before.items)
    }

    private func exactReviews(_ timeline: Timeline, assets: [MediaAsset]) -> [ShotContentAssessment] {
        timeline.items.map { item in
            let asset = assets.first { $0.id == item.assetID }!
            return .init(itemID: item.id, assetID: asset.id, sourceContentHash: asset.contentHash,
                sourceStart: item.sourceStart, sourceDuration: item.sourceDuration,
                sampleTimes: [0.02, 0.25, 0.5, 0.75, 0.98].map { item.sourceStart + item.sourceDuration * $0 },
                phase: "source", model: "fixture", cacheKey: "exact", status: .usable, confidence: 0.95,
                obstructedSamples: [], observation: "People paddle kayaks along the river", activity: "paddling",
                editorialPurpose: "action", actionBoundary: .init(startObservation: "People paddle along river",
                    endObservation: "People continue paddling downstream", followingObservation: "Unselected landing outside the cut",
                    verdict: .continuous, confidence: 0.95))
        }
    }

    @Test func exactSelectedContentSupersedesOldLabelsAndExcludesFollowingContext() async throws {
        let (before, plan, assets, analyses) = fixture(partCount: 1, withActions: false)
        let after = try await SmartChapterTitleEngine().applying(to: before, plan: plan, assets: assets,
            analyses: analyses, mode: .balanced, model: TitleModelProbe(), sourceAssessments: exactReviews(before, assets: assets))
        #expect(after.effectiveTitleItems.first?.text == "Сплав по реке")
        let evidence = after.chapterTitleDecisions!.flatMap(\.evidence)
        #expect(evidence.allSatisfy { !$0.observation.contains("bicycle") && !$0.observation.contains("Велосипед") && !$0.observation.contains("landing") })
        #expect(after.items == before.items)
    }

    @Test func lateFrameAndBoundaryFactsSurviveTitleCollectionAndCompaction() async throws {
        let (before, plan, assets, analyses) = fixture(partCount: 1)
        var reviews = exactReviews(before, assets: assets)
        let longBeginning = String(repeating: "People paddle beside the trees. ", count: 60)
        let lastFrame = "FRAME 4: The boats are now beside a concrete landing."
        let endState = "At the selected end the paddles rest across the boats."
        for i in reviews.indices {
            reviews[i].observation = longBeginning + lastFrame
            reviews[i].actionBoundary?.startObservation = longBeginning
            reviews[i].actionBoundary?.endObservation = endState
        }
        let after = try await SmartChapterTitleEngine().applying(to: before, plan: plan, assets: assets,
            analyses: analyses, mode: .fast, model: TitleModelProbe(), sourceAssessments: reviews)
        let decision = try #require(after.chapterTitleDecisions?.first)
        let input = ChapterTitleInput(partID: decision.partID, ordinal: 0, duration: 30, language: "ru",
            maxCharacters: 60, evidence: decision.evidence, coverage: decision.coverage, limitations: [])
        let compact = LocalChapterTitleModel.compact(input)
        #expect(compact.evidence.map(\.id) == input.evidence.map(\.id))
        for item in before.items {
            let evidence = compact.evidence.filter { $0.itemID == item.id }
            #expect(evidence.contains { $0.origin == .visualSummary && $0.observation.hasSuffix(lastFrame) })
            #expect(evidence.contains { $0.origin == .visualSequence && $0.observation.hasSuffix(endState) })
            #expect(evidence.allSatisfy { !$0.observation.contains("Unselected landing") })
            #expect(evidence.allSatisfy { $0.selected && $0.frameTimes.count == 5 })
        }
    }

    @Test func failedExactProbesCannotBorrowOldSceneCertainty() async throws {
        let (before, plan, assets, analyses) = fixture(partCount: 1)
        var reviews = exactReviews(before, assets: assets)
        for i in reviews.indices { reviews[i].status = .uncertain; reviews[i].confidence = 0 }
        let model = TitleModelProbe()
        let after = try await SmartChapterTitleEngine().applying(to: before, plan: plan, assets: assets,
            analyses: analyses, mode: .balanced, model: model, sourceAssessments: reviews)
        #expect(after.effectiveTitleItems.first?.text == "Часть 1")
        #expect(await model.calls == 0)
    }

    @Test func changedExactReceiptRechecksTitlesEvenWhenItsDescriptionIsUnchanged() async throws {
        let (before, plan, assets, analyses) = fixture(partCount: 1)
        let model = TitleModelProbe()
        var reviews = exactReviews(before, assets: assets)
        let generated = try await SmartChapterTitleEngine().applying(to: before, plan: plan, assets: assets,
            analyses: analyses, mode: .balanced, model: model, sourceAssessments: reviews)
        #expect(await model.calls == 2)
        #expect(SmartChapterTitleEngine.hasAutomaticTitles(generated))
        let cached = try await SmartChapterTitleEngine().applying(to: generated, plan: plan, assets: assets,
            analyses: analyses, mode: .balanced, model: model, sourceAssessments: reviews)
        #expect(await model.calls == 2)
        #expect(cached == generated)
        // The receipt binds rules, exact images and weights. Identical prose
        // from a different receipt must not inherit the previous title check.
        reviews[0].cacheKey = "changed-images-or-rules-or-weights"
        let refreshed = try await SmartChapterTitleEngine().applying(to: cached, plan: plan, assets: assets,
            analyses: analyses, mode: .balanced, model: model, sourceAssessments: reviews)
        #expect(await model.calls == 4)
        let responseScopes = await model.receivedCacheIdentities
        #expect(responseScopes.count == 2 && responseScopes[0] != responseScopes[1])
        #expect(refreshed.chapterTitleDecisions?.first?.inputSignature != generated.chapterTitleDecisions?.first?.inputSignature)
        #expect(refreshed.items == generated.items)
        for i in reviews.indices { reviews[i].status = .uncertain; reviews[i].confidence = 0 }
        let uncertain = try await SmartChapterTitleEngine().applying(to: refreshed, plan: plan, assets: assets,
            analyses: analyses, mode: .balanced, model: model, sourceAssessments: reviews)
        #expect(uncertain.chapterTitleDecisions?.first?.source == .fallback)
        #expect(uncertain.effectiveTitleItems.first?.text == "Часть 1")
        #expect(await model.calls == 4)
    }

    @Test func manualOnlyRecoveredTitlesDoNotRequestAutomaticChapterCreation() {
        var (timeline, _, _, _) = fixture(partCount: 1)
        timeline.titleItems = [.init(kind: .chapter, text: "Наше название", startTime: 1, duration: 5)]
        #expect(!SmartChapterTitleEngine.hasAutomaticTitles(timeline))
    }

    @Test func staleHashAndChangedSourceRangeCannotSupplyExactTitleEvidence() async throws {
        let (before, plan, assets, analyses) = fixture(partCount: 1, withActions: false)
        var reviews = exactReviews(before, assets: assets)
        reviews[0].sourceContentHash = "other source"
        reviews[1].sourceStart += 1
        reviews[2].sourceDuration -= 1
        let after = try await SmartChapterTitleEngine().applying(to: before, plan: plan, assets: assets,
            analyses: analyses, mode: .balanced, model: TitleModelProbe(rejects: true), sourceAssessments: reviews)
        #expect(after.chapterTitleDecisions!.flatMap(\.evidence).allSatisfy { !$0.observation.contains("People paddle") })
    }

    @Test func unknownTimezoneAndCopyDatesCannotAppearAsCaptureDates() async throws {
        let (before, plan, originalAssets, _) = fixture(partCount: 1)
        for provenance in [MediaDateSource.fileCreationDate, .fileModificationDate, .importDate, .embeddedMetadata] {
            var assets = originalAssets
            for i in assets.indices { assets[i].metadata.creationDate = Date(); assets[i].metadata.dateSource = provenance; assets[i].metadata.dateConfidence = 1 }
            let after = try await SmartChapterTitleEngine().applying(to: before, plan: plan, assets: assets, analyses: [], mode: .fast, model: TitleModelProbe())
            #expect(after.effectiveTitleItems.first?.text == "Часть 1")
        }
        var assets = originalAssets
        for i in assets.indices {
            assets[i].metadata.creationDate = Date(timeIntervalSince1970: 1_700_000_000)
            assets[i].metadata.dateSource = .embeddedMetadata; assets[i].metadata.dateConfidence = 1; assets[i].metadata.timeZoneIdentifier = "UTC"
        }
        let after = try await SmartChapterTitleEngine().applying(to: before, plan: plan, assets: assets, analyses: [], mode: .fast, model: TitleModelProbe())
        #expect(after.effectiveTitleItems.first?.text == "14 ноября 2023")
        #expect(after.chapterTitleDecisions?.first?.evidence.contains { $0.origin == .metadata } == true)
    }

    @Test func titlesForbiddenAndTooShortPartFollowExistingRules() async throws {
        var (before, plan, assets, analyses) = fixture(partCount: 1)
        plan.prompt = "Без титров"; plan.directorBrief?.titlePolicy = .none
        let model = TitleModelProbe()
        let unchanged = try await SmartChapterTitleEngine().applying(to: before, plan: plan, assets: assets, analyses: analyses, mode: .fast, model: model)
        #expect(unchanged == before && unchanged.filmParts == nil)
        #expect(await model.calls == 0)
        plan.prompt = "Титры частей"; plan.directorBrief?.titlePolicy = .keyOnly
        before.items = [before.items[0]]; before.items[0].timelineDuration = 0.8
        let short = try await SmartChapterTitleEngine().applying(to: before, plan: plan, assets: assets, analyses: analyses, mode: .fast, model: model)
        #expect(short.effectiveTitleItems.isEmpty)
        #expect(short.duration == 0.8)
        // The mandatory title contract must report an unreadably short part.
        #expect(EditorialPresentationPolicy.missingChapterTitles(in: short, plan: plan).count == 1)
        #expect(short.chapterTitleDecisions?.first?.fallbackReason?.contains("1.25") == true)
    }

    @Test func unknownLegacyFieldsDecodeAndNewDecisionsSurviveRoundTrip() throws {
        let (timeline, _, _, _) = fixture()
        let bytes = try JSONEncoder().encode(timeline)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("filmParts"))
        let legacy = try JSONDecoder().decode(Timeline.self, from: bytes)
        #expect(legacy.filmParts == nil && legacy.chapterTitleDecisions == nil)
    }

    @Test func lateModelResultCannotOverwriteManualEditAndCancellationDoesNotCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SmartTitles-\(UUID()).veloedit")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root, name: "Title safety", recoveryDirectory: root.appendingPathComponent("Recovery"))
        let (timeline, plan, assets, analyses) = fixture(partCount: 1)
        try await store.update { $0.timelines = [timeline]; $0.storyPlans = [plan]; $0.assets = assets; $0.analyses = analyses }
        let pipeline = VeloEditPipeline(store: store)
        let model = TitleModelProbe(delay: 200_000_000)
        let task = Task { try await pipeline.refreshChapterTitles(model: model) }
        while await model.calls == 0 { await Task.yield() }
        try await store.update { $0.timelines[0].titleItems = [.init(kind: .chapter, text: "Свежая правка", startTime: 0, duration: 4)] }
        do { _ = try await task.value; Issue.record("Stale rename committed") } catch { #expect(error is ProjectStoreError) }
        #expect(await store.manifest.timelines[0].effectiveTitleItems.first?.text == "Свежая правка")
        try await store.update { $0.timelines[0].titleItems = [] }
        let cancelled = Task { try await pipeline.refreshChapterTitles(model: TitleModelProbe(delay: 1_000_000_000)) }
        try await Task.sleep(nanoseconds: 20_000_000); cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancelled rename committed") } catch { #expect(error is CancellationError) }
        #expect(await store.manifest.timelines[0].filmParts == nil)
    }
}

extension SmartChapterTitlesTests {
    @Test func insertingShotInsideSavedPartDoesNotCreateAnActionTitle() async throws {
        let (source, plan, assets, analyses) = fixture()
        let named = try await SmartChapterTitleEngine().applying(to: source, plan: plan, assets: assets, analyses: analyses, mode: .fast, model: TitleModelProbe())
        var edited = named
        edited.items[1].id = UUID()
        let parts = FilmPartPolicy.parts(in: edited, plan: plan)
        #expect(parts.count == 2)
        #expect(parts.map(\.id) == named.filmParts?.map(\.id))
        #expect(parts[0].itemIDs.contains(edited.items[1].id))
    }

    @Test func broadAndRareThemesAreNotLimitedToActivityDictionary() async throws {
        let scenarios = ["Сплав", "Велопрогулка", "Пешая прогулка", "Прогулка по городу", "Семейный праздник", "Готовим вместе", "Игра с собакой", "Веломастерская", "На лыжах", "День на даче", "Гончарная мастерская"]
        for text in scenarios {
            let (source, plan, assets, analyses) = fixture(partCount: 1)
            let model = TitleModelProbe(text: text, kind: "setting")
            let result = try await SmartChapterTitleEngine().applying(to: source, plan: plan, assets: assets, analyses: analyses, mode: .balanced, model: model)
            #expect(result.effectiveTitleItems.first?.text == text)
        }
        // This checks routing and schema flexibility, NOT human semantic quality.
    }

    @Test func repeatedPerformanceScenariosRecordCallsAndLocalInvalidation() async throws {
        struct Sample: Codable { var scenario: String; var iteration: Int; var seconds: Double; var modelCalls: Int; var extraDecodedFrames: Int }
        var measurements: [Sample] = []
        for iteration in 1...5 {
            let (source, plan, assets, analyses) = fixture()
            let model = TitleModelProbe()
            var time = ProcessInfo.processInfo.systemUptime
            let first = try await SmartChapterTitleEngine().applying(to: source, plan: plan, assets: assets, analyses: analyses, mode: .balanced, model: model)
            measurements.append(.init(scenario: "cold-injected-model", iteration: iteration, seconds: ProcessInfo.processInfo.systemUptime - time, modelCalls: await model.calls, extraDecodedFrames: 0))
            time = ProcessInfo.processInfo.systemUptime
            let cached = try await SmartChapterTitleEngine().applying(to: first, plan: plan, assets: assets, analyses: analyses, mode: .balanced, model: model)
            measurements.append(.init(scenario: "warm", iteration: iteration, seconds: ProcessInfo.processInfo.systemUptime - time, modelCalls: await model.calls - 4, extraDecodedFrames: 0))
            #expect(await model.calls == 4)
            var changed = analyses
            changed[0].candidates[0].insights?.sceneSummary = "Люди гребут вдоль берега реки"
            time = ProcessInfo.processInfo.systemUptime
            let revised = try await SmartChapterTitleEngine().applying(to: cached, plan: plan, assets: assets, analyses: changed, mode: .balanced, model: model)
            measurements.append(.init(scenario: "one-part-changed", iteration: iteration, seconds: ProcessInfo.processInfo.systemUptime - time, modelCalls: await model.calls - 4, extraDecodedFrames: 0))
            #expect(await model.calls == 6)
            #expect(revised.chapterTitleDecisions?[1] == cached.chapterTitleDecisions?[1])
        }
        if let output = ProcessInfo.processInfo.environment["VELOEDIT_SMART_TITLE_METRICS"] {
            try JSONEncoder.veloEdit.encode(measurements).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

    @Test func oneFileCanContainTwoPartsAndReanalysisDoesNotInvalidateUnchangedIntervals() async throws {
        var (source, plan, assets, analyses) = fixture()
        let assetID = assets[0].id
        for i in source.items.indices {
            source.items[i].assetID = assetID
            source.items[i].sourceStart = Double(i * 10)
            analyses[i].candidates[0].assetID = assetID
            analyses[i].candidates[0].sourceStart = Double(i * 10)
            analyses[i].candidates[0].insights?.editorialEvidence = nil
        }
        analyses[0].candidates = analyses.flatMap(\.candidates)
        analyses = [analyses[0]]; assets = [assets[0]]
        let model = TitleModelProbe()
        let first = try await SmartChapterTitleEngine().applying(to: source, plan: plan, assets: assets, analyses: analyses, mode: .balanced, model: model)
        #expect(first.filmParts?.count == 2)
        analyses[0].analyzedAt = Date().addingTimeInterval(300)
        analyses[0].candidates[0].insights?.sceneSummary = "Байдарки движутся вдоль берега реки"
        _ = try await SmartChapterTitleEngine().applying(to: first, plan: plan, assets: assets, analyses: analyses, mode: .balanced, model: model)
        #expect(await model.calls == 6)
    }
}

extension SmartChapterTitlesTests {
    @Test func speechCaptionAtBeginningDoesNotReplacePartTitle() async throws {
        var (timeline, plan, assets, analyses) = fixture(partCount: 1)
        var caption = TitleTimelineItem(kind: .subtitle, text: "Сплав по реке", startTime: 0, duration: 4)
        caption.userEdited = true
        timeline.titleItems = [caption]
        let named = try await SmartChapterTitleEngine().applying(to: timeline, plan: plan, assets: assets, analyses: analyses, mode: .fast, model: TitleModelProbe())
        #expect(named.effectiveTitleItems.filter { $0.kind == .chapter }.count == 1)
        #expect(named.effectiveTitleItems.first { $0.id == caption.id } == caption)
    }
}

extension SmartChapterTitlesTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_SMART_TITLE_LIVE_MODEL"] != nil))
    func installedModelGeneratesAndIndependentlyVerifiesRussianTitle() async throws {
        let (timeline, plan, assets, analyses) = fixture(partCount: 1)
        var preferences = UserPreferences(); preferences.aiPowerMode = .balanced
        let model = await LocalChapterTitleModel.configured(preferences: preferences)
        let named = try await SmartChapterTitleEngine().applying(to: timeline, plan: plan, assets: assets, analyses: analyses, mode: .balanced, model: model)
        if let output = ProcessInfo.processInfo.environment["VELOEDIT_SMART_TITLE_LIVE_MODEL"] {
            try JSONEncoder.veloEdit.encode(named.chapterTitleDecisions).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        #expect(named.chapterTitleDecisions?.first?.source == .model)
        #expect(named.chapterTitleDecisions?.first?.modelCalls == 3)
    }
}

extension SmartChapterTitlesTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_SMART_TITLE_CONTROL"] != nil))
    func savedControlKeepsEveryCutAndExistingEventMembershipWithUnavailableModel() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VELOEDIT_SMART_TITLE_CONTROL"])
        let project = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let source = try #require(project.timelines.last)
        let plan = try #require(project.storyPlans.last { $0.id == source.storyPlanID })
        let expected = FilmPartPolicy.parts(in: source, plan: plan)
        let named = try await SmartChapterTitleEngine().applying(to: source, plan: plan, assets: project.assets,
            analyses: project.analyses, mode: .balanced, model: TitleModelProbe(fails: true))
        #expect(named.items == source.items)
        #expect(named.music == source.music && named.adaptiveSoundtrack == source.adaptiveSoundtrack)
        #expect(named.originalAudioVolume == source.originalAudioVolume && named.transitionItems == source.transitionItems)
        #expect(named.filmParts == expected)
        #expect(named.effectiveTitleItems.filter { $0.kind == .chapter }.count == 7)
        #expect(EditorialPresentationPolicy.missingChapterTitles(in: named, plan: plan).isEmpty)
        if let output = ProcessInfo.processInfo.environment["VELOEDIT_SMART_TITLE_CONTROL_OUTPUT"] {
            struct Report: Encodable { var parts: [FilmPart]; var titles: [TitleTimelineItem]; var decisions: [ChapterTitleDecision]; var unchangedMontage: Bool; var model: String }
            try JSONEncoder.veloEdit.encode(Report(parts: expected, titles: named.effectiveTitleItems, decisions: named.chapterTitleDecisions ?? [],
                unchangedMontage: named.items == source.items, model: "Injected unavailable model: verifies safety and membership, not semantics"))
                .write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}


extension SmartChapterTitlesTests {
    @Test func stalledTitleModelWaitsInsteadOfFallingBackToUnverifiedText() async throws {
        struct StalledModel: ChapterTitleModel {
            let identity = "unchanged-title-model"
            func generate(_ input: ChapterTitleInput) async throws -> ChapterThemeProposal {
                throw LocalAIInferenceFailure(model: identity, reason: "No response")
            }
            func verify(_ proposal: ChapterTitleProposal, input: ChapterTitleInput) async throws -> ChapterTitleVerification {
                throw LocalAIInferenceFailure(model: identity, reason: "No response")
            }
        }
        let (timeline, plan, assets, analyses) = fixture(partCount: 1)
        await #expect(throws: LocalAIInferenceFailure.self) {
            _ = try await SmartChapterTitleEngine().applying(to: timeline, plan: plan, assets: assets,
                analyses: analyses, mode: .balanced, model: StalledModel())
        }
    }
}
