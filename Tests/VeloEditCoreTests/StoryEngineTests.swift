import Foundation
import Testing
@testable import VeloEditCore

@Test(arguments: ["Без телеметрии", "Добавь титры. Без фильтров и телеметрии", "Убери телеметрию", "Without telemetry", "No filters and telemetry"])
func hidingTelemetryDoesNotExcludeTheCameraFootage(_ prompt: String) {
    var base = StoryConstraints(includeTags: ["telemetry-event"], excludeTags: ["telemetry-event"], preferredIntroTags: ["telemetry-event"])
    base.maximumTagShares["telemetry-event"] = 0
    let constraints = PromptInterpreter().interpret(prompt: prompt, preset: .story, base: base)
    #expect(!constraints.excludeTags.contains("telemetry-event"))
    #expect(!constraints.includeTags.contains("telemetry-event"))
    #expect(constraints.maximumTagShares["telemetry-event"] == nil)
    #expect(constraints.preferredIntroTags?.contains("telemetry-event") != true)
    #expect(!TelemetryOverlayRequestPolicy.requestsOverlay(in: prompt))
    let (assets, source) = storyFixture()
    var analyses = source
    for index in analyses.indices {
        for candidate in analyses[index].candidates.indices { analyses[index].candidates[candidate].tags.insert("telemetry-event") }
    }
    let plan = StoryEngine().createPlan(prompt: prompt, preset: .story, constraints: constraints, assets: assets, analyses: analyses)
    #expect(!plan.chapters.flatMap(\.candidateIDs).isEmpty)
}

@Test func explicitTelemetryEventSelectionRemainsAContentInstruction() {
    let constraints = PromptInterpreter().interpret(prompt: "Без телеметрических событий", preset: .story)
    #expect(constraints.excludeTags.contains("telemetry-event"))
}

private func storyFixture() -> ([MediaAsset], [AnalysisResult]) {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let assets = (0..<8).map { index in
        MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/\(index).mov"), kind: index == 7 ? .photo : .video, byteSize: 1, contentHash: "h\(index)", metadata: MediaMetadata(duration: 60, creationDate: date.addingTimeInterval(Double(index) * 60)))
    }
    let analyses = assets.enumerated().map { index, asset in
        let tag = index < 5 ? "bike" : (index < 7 ? "fishing" : "nature")
        let candidates = (0..<3).map { part in
            Candidate(assetID: asset.id, sourceStart: Double(part * 10), sourceDuration: 6, scores: ClipScores(quality: 0.7, interest: 0.6 + Double(index) / 30, action: 0.7, stability: 0.8), tags: [tag])
        }
        return AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, sceneTags: [tag], candidates: candidates)
    }
    return (assets, analyses)
}

@Test func russianPromptParsesDurationAndShare() {
    let c = PromptInterpreter().interpret(prompt: "Сделай фильм на 5 минут. Велосипеда максимум 30%, больше фотографий, без slow motion", preset: .summerFilm)
    #expect(c.targetDuration == 300)
    #expect(c.maximumTagShares["bike"] == 0.3)
    #expect(c.preferPhotos)
    #expect(!c.allowSlowMotion)
}

@Test func explicitTagNegationOverridesPositiveMentionsAndInheritedAnchors() {
    var base = PromptInterpreter.defaults(for: .story)
    base.includeTags = ["fishing", "buggy"]
    base.preferredIntroTags = ["fishing"]
    base.preferredClimaxTags = ["fishing", "buggy"]
    base.preferredOutroTags = ["buggy"]

    let constraints = PromptInterpreter().interpret(
        prompt: "Рыбалка как кульминация, но без рыбалки. Не показывай buggy.",
        preset: .story,
        base: base
    )

    #expect(constraints.excludeTags.isSuperset(of: ["fishing", "buggy"]))
    #expect(constraints.includeTags.isDisjoint(with: ["fishing", "buggy"]))
    #expect(constraints.preferredIntroTags?.isDisjoint(with: ["fishing", "buggy"]) == true)
    #expect(constraints.preferredClimaxTags?.isDisjoint(with: ["fishing", "buggy"]) == true)
    #expect(constraints.preferredOutroTags?.isDisjoint(with: ["fishing", "buggy"]) == true)

    let phrased = PromptInterpreter().interpret(
        prompt: "Не показывай поездку на багги; без кадров с велосипедами.",
        preset: .story
    )
    #expect(phrased.excludeTags.isSuperset(of: ["buggy", "bike"]))
    #expect(phrased.includeTags.isDisjoint(with: ["buggy", "bike"]))
}

@Test func roleAnchorsBindOnlyToTagsInTheirLocalClause() {
    let constraints = PromptInterpreter().interpret(
        prompt: "Начни с природы, багги — кульминация, заверши закатом.",
        preset: .story
    )

    #expect(constraints.preferredIntroTags == ["nature"])
    #expect(constraints.preferredClimaxTags == ["buggy"])
    #expect(constraints.preferredOutroTags == ["sunset"])
}

@Test func latestPositiveOrNegativeTagInstructionWins() {
    let restored = PromptInterpreter().interpret(
        prompt: "Без багги. Теперь всё же багги — кульминация.",
        preset: .story
    )
    #expect(restored.includeTags.contains("buggy"))
    #expect(!restored.excludeTags.contains("buggy"))
    #expect(restored.preferredClimaxTags?.contains("buggy") == true)

    let excluded = PromptInterpreter().interpret(
        prompt: "Багги — кульминация. Теперь без кадров с багги.",
        preset: .story
    )
    #expect(excluded.excludeTags.contains("buggy"))
    #expect(!excluded.includeTags.contains("buggy"))
    #expect(excluded.preferredClimaxTags?.contains("buggy") != true)
}

@Test func naturalRussianPacingFormsAreUnderstood() {
    let energetic = PromptInterpreter().interpret(prompt: "Сделай динамично и энергично", preset: .story)
    let calm = PromptInterpreter().interpret(prompt: "Хочу спокойный медленный фильм", preset: .adventure)
    #expect(energetic.pacing > PromptInterpreter.defaults(for: .story).pacing)
    #expect(calm.pacing < PromptInterpreter.defaults(for: .adventure).pacing)
}

@Test func exactMomentCountIsUnderstoodAndApplied() {
    let (assets, analyses) = storyFixture()
    let constraints = PromptInterpreter().interpret(prompt: "Сделай связный фильм из 3 моментов", preset: .story)
    #expect(constraints.targetClipCount == 3)
    let plan = StoryEngine().createPlan(prompt: "из 3 моментов", preset: .story, constraints: constraints, assets: assets, analyses: analyses)
    let timeline = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    #expect(timeline.items.count == 3)
}

@Test func latestDirectorInstructionReplacesEarlierNumbersAndPacing() {
    let interpreter = PromptInterpreter()
    let constraints = interpreter.interpret(
        prompt: "Сначала сделай динамичный фильм из 3 моментов на 2 минуты. Теперь сделай спокойно из 5 моментов на 30 секунд.",
        preset: .story
    )

    #expect(constraints.targetClipCount == 5)
    #expect(constraints.targetDuration == 30)
    #expect(constraints.pacing < PromptInterpreter.defaults(for: .story).pacing)
}

@Test func feedbackReplacesEarlierExactMomentCountInTheActualTimeline() {
    let (assets, originalAnalyses) = storyFixture()
    // Five requested moments need five distinct setups, not five copies of bike.
    var analyses = originalAnalyses
    for i in analyses.indices {
        for j in analyses[i].candidates.indices {
            analyses[i].candidates[j].tags = ["activity-\(i)"]
        }
    }
    let originalConstraints = PromptInterpreter().interpret(prompt: "Фильм из 3 моментов", preset: .story)
    let original = StoryEngine().createPlan(
        prompt: "Фильм из 3 моментов",
        preset: .story,
        constraints: originalConstraints,
        assets: assets,
        analyses: analyses
    )
    var candidates = analyses.flatMap(\.candidates)
    let revisedSeed = FeedbackEngine().apply(
        feedback: "Теперь переделай из 5 моментов",
        to: original,
        candidates: &candidates
    )
    let revised = StoryEngine().createPlan(
        prompt: revisedSeed.prompt,
        preset: revisedSeed.preset,
        constraints: revisedSeed.constraints,
        assets: assets,
        analyses: analyses
    )
    let timeline = TimelineComposer().compose(plan: revised, assets: assets, analyses: analyses)

    #expect(revised.constraints.targetClipCount == 5)
    #expect(timeline.items.count == 5)
}

@Test func directorFallbackAlwaysAcknowledgesBriefAndReportsReadiness() {
    let context = DirectorContext(
        assetCount: 3,
        videoCount: 3,
        photoCount: 0,
        analyzedCount: 2,
        candidateCount: 24,
        currentTimelineItemCount: 0,
        targetDuration: 120,
        preset: .adventure,
        currentOperation: "анализ"
    )
    let reply = DirectorFallbackReply().make(userMessage: "Сделай динамично на 90 секунд без slow motion", context: context)
    #expect(reply.contains("динамичный темп"))
    #expect(reply.contains("1.5 минуты"))
    #expect(reply.contains("2 из 3"))
    #expect(reply.contains("без slow motion"))
}

@Test func fallbackDoesNotInventPacingAndAcknowledgesChangedClipCount() {
    let context = DirectorContext(
        assetCount: 3,
        videoCount: 3,
        photoCount: 0,
        analyzedCount: 3,
        candidateCount: 30,
        currentTimelineItemCount: 12,
        targetDuration: 120,
        preset: .adventure,
        currentOperation: "ожидание команды"
    )
    let reply = DirectorFallbackReply().make(userMessage: "Сделай связный фильм из 3 моментов", context: context)
    #expect(reply.contains("из 3 моментов"))
    #expect(reply.contains("текущих 12"))
    #expect(!reply.contains("динамичный"))
    #expect(!reply.contains("2.0 минуты"))
}

@Test func adviceRequestsAreReadOnlyEvenWhenTheyMentionMusicAndTitles() {
    let intent = DirectorRequestIntentInterpreter()
    #expect(intent.mode(for: "Посоветуй музыку и придумай название") == .advisory)
    #expect(intent.mode(for: "Подбери музыку, но ничего не меняй") == .advisory)
    #expect(intent.mode(for: "Добавь музыку и титр «Лето»") == .edit)
}

@Test func fallbackCanRecommendFromAnalysisWithoutPromisingAnEdit() {
    let context = DirectorContext(
        assetCount: 1,
        videoCount: 1,
        photoCount: 0,
        analyzedCount: 1,
        candidateCount: 8,
        currentTimelineItemCount: 0,
        targetDuration: 60,
        preset: .adventure,
        currentOperation: "ожидание команды",
        contentHints: ["велопрогулка"],
        audioHints: ["ветер/шум: 2 эпиз.", "речь: 1 эпиз."]
    )
    let reply = DirectorFallbackReply().make(
        userMessage: "Посоветуй музыку, название и скажи, что за шум — ничего не меняй",
        context: context
    )
    #expect(reply.contains("Велопрогулка"))
    #expect(reply.contains("ветер/шум"))
    #expect(reply.contains("Timeline не изменены"))
}

@Test func storyRespectsDiversityAndCreatesTimeline() {
    let (assets, analyses) = storyFixture()
    var constraints = PromptInterpreter.defaults(for: .highlight)
    constraints.targetDuration = 45
    constraints.maximumTagShares["bike"] = 0.3
    let plan = StoryEngine().createPlan(prompt: "Больше рыбалки", preset: .highlight, constraints: constraints, assets: assets, analyses: analyses)
    let timeline = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    #expect(!timeline.items.isEmpty)
    #expect(timeline.duration <= 45.001)
    let candidateByID = Dictionary(uniqueKeysWithValues: analyses.flatMap(\.candidates).map { ($0.id, $0) })
    let bikeDuration = timeline.items.filter { item in item.candidateID.flatMap { candidateByID[$0] }?.tags.contains("bike") == true }.reduce(0) { $0 + $1.timelineDuration }
    #expect(bikeDuration <= 45 * 0.3 + 0.001)
}

@Test func technicalTagsDoNotCollapseTimelineToOneClip() {
    let assets = (0..<3).map { index in
        MediaAsset(
            originalURL: URL(fileURLWithPath: "/tmp/camera-\(index).mov"),
            kind: .video,
            byteSize: 1,
            contentHash: "camera-\(index)",
            metadata: MediaMetadata(duration: 300)
        )
    }
    let analyses = assets.map { asset in
        AnalysisResult(
            assetID: asset.id,
            analyzedContentHash: asset.contentHash,
            sceneTags: ["4k", "horizontal"],
            candidates: (0..<10).map { part in
                Candidate(
                    assetID: asset.id,
                    sourceStart: Double(part * 20),
                    sourceDuration: 6,
                    scores: ClipScores(quality: 0.8, interest: 0.75, action: 0.7, stability: 0.8),
                    tags: ["4k", "horizontal"]
                )
            }
        )
    }
    var constraints = PromptInterpreter.defaults(for: .highlight)
    constraints.targetDuration = 60
    let plan = StoryEngine().createPlan(prompt: "Лучшие моменты", preset: .highlight, constraints: constraints, assets: assets, analyses: analyses)
    let timeline = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    #expect(timeline.items.count >= 10)
    #expect(Set(timeline.items.compactMap(\.assetID)).count >= 2)
    #expect(timeline.duration > 50)
}

@Test func shortTargetStillSelectsAPlayableClipWithoutPaddingTheSource() {
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/short-target.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "short-target",
        metadata: MediaMetadata(duration: 120)
    )
    let analysis = AnalysisResult(
        assetID: asset.id,
        analyzedContentHash: asset.contentHash,
        candidates: [Candidate(assetID: asset.id, sourceStart: 20, sourceDuration: 8, scores: ClipScores(quality: 0.8, interest: 0.8, action: 0.8, stability: 0.8), tags: ["4k", "horizontal"])]
    )
    var constraints = PromptInterpreter.defaults(for: .highlight)
    constraints.targetDuration = 5
    let plan = StoryEngine().createPlan(prompt: "5 секунд", preset: .highlight, constraints: constraints, assets: [asset], analyses: [analysis])
    let timeline = TimelineComposer().compose(plan: plan, assets: [asset], analyses: [analysis])
    #expect(timeline.items.count == 1)
    #expect(timeline.duration > 0)
    #expect(timeline.duration <= plan.constraints.targetDuration)
    #expect(timeline.duration <= analysis.candidates[0].sourceDuration)
    #expect(!AutomaticFilmDurationPolicy.meetsMinimum(timeline))
}

@Test func excludedAssetsNeverParticipateInStorySelection() {
    let excluded = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/excluded.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "excluded",
        metadata: MediaMetadata(duration: 30),
        excluded: true
    )
    let available = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/available.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "available",
        metadata: MediaMetadata(duration: 30)
    )
    let excludedCandidate = Candidate(
        assetID: excluded.id,
        sourceStart: 0,
        sourceDuration: 6,
        scores: ClipScores(quality: 1, interest: 1, action: 1, stability: 1)
    )
    let availableCandidate = Candidate(
        assetID: available.id,
        sourceStart: 0,
        sourceDuration: 6,
        scores: ClipScores(quality: 0.5, interest: 0.5, action: 0.5, stability: 0.5)
    )
    let analyses = [
        AnalysisResult(assetID: excluded.id, analyzedContentHash: excluded.contentHash, candidates: [excludedCandidate]),
        AnalysisResult(assetID: available.id, analyzedContentHash: available.contentHash, candidates: [availableCandidate])
    ]
    var constraints = PromptInterpreter.defaults(for: .highlight)
    constraints.targetClipCount = 1
    let plan = StoryEngine().createPlan(
        prompt: "Лучший момент",
        preset: .highlight,
        constraints: constraints,
        assets: [excluded, available],
        analyses: analyses
    )

    #expect(plan.chapters.flatMap(\.candidateIDs) == [availableCandidate.id])
}

@Test func favoriteAssetsReceiveARealSelectionBoost() {
    let favorite = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/favorite.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "favorite",
        metadata: MediaMetadata(duration: 30),
        favorite: true
    )
    let regular = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/regular.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "regular",
        metadata: MediaMetadata(duration: 30)
    )
    let favoriteCandidate = Candidate(
        assetID: favorite.id,
        sourceStart: 0,
        sourceDuration: 6,
        scores: ClipScores(quality: 0.6, interest: 0.6, action: 0.6, stability: 0.6)
    )
    let regularCandidate = Candidate(
        assetID: regular.id,
        sourceStart: 0,
        sourceDuration: 6,
        scores: ClipScores(quality: 0.7, interest: 0.7, action: 0.7, stability: 0.7)
    )
    let analyses = [
        AnalysisResult(assetID: favorite.id, analyzedContentHash: favorite.contentHash, candidates: [favoriteCandidate]),
        AnalysisResult(assetID: regular.id, analyzedContentHash: regular.contentHash, candidates: [regularCandidate])
    ]
    var constraints = PromptInterpreter.defaults(for: .highlight)
    constraints.targetClipCount = 1
    let plan = StoryEngine().createPlan(
        prompt: "Самое интересное",
        preset: .highlight,
        constraints: constraints,
        assets: [favorite, regular],
        analyses: analyses
    )

    #expect(plan.chapters.flatMap(\.candidateIDs) == [favoriteCandidate.id])
}

@Test func feedbackLocksSelectedCandidateWithoutReanalysis() {
    let (_, analyses) = storyFixture()
    var candidates = analyses.flatMap(\.candidates)
    let selected = candidates[0].id
    let original = StoryPlan(prompt: "Фильм", preset: .story, constraints: .init(), chapters: [])
    let updated = FeedbackEngine().apply(feedback: "Этот момент обязательно оставь", to: original, candidates: &candidates, selectedCandidateID: selected)
    #expect(candidates.first(where: { $0.id == selected })?.locked == true)
    #expect(updated.version == 2)
}

@Test func timecodeRoundTrip() {
    let timecode = Timecode(seconds: 65.5, frameRate: 30)
    #expect(timecode.description == "00:01:05:15")
    #expect(abs(timecode.seconds - 65.5) < 0.0001)
}

@Test func contextualRankerChangesPreferenceWithFilmIntent() {
    let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/context.mov"), kind: .video, byteSize: 1, contentHash: "context", metadata: MediaMetadata(duration: 30, hasAudio: true))
    let action = Candidate(
        assetID: asset.id,
        sourceStart: 0,
        sourceDuration: 5,
        scores: ClipScores(quality: 0.72, interest: 0.82, action: 0.98, stability: 0.62),
        tags: ["action"],
        insights: CandidateInsights(dynamics: 0.98, visualAppeal: 0.76, composition: 0.68, storyValue: 0.70)
    )
    let memory = Candidate(
        assetID: asset.id,
        sourceStart: 10,
        sourceDuration: 5,
        scores: ClipScores(quality: 0.80, interest: 0.70, action: 0.12, stability: 0.92),
        tags: ["people"],
        insights: CandidateInsights(emotion: "joy", dynamics: 0.15, visualAppeal: 0.80, composition: 0.82, originalAudioUsefulness: 0.88, storyValue: 0.94)
    )
    let ranker = ContextualHighlightRanker()
    let highlight = HighlightRankingContext(prompt: "Экшен", preset: .highlight, constraints: StoryConstraints())
    let memories = HighlightRankingContext(prompt: "Воспоминания", preset: .memories, constraints: StoryConstraints())
    #expect(ranker.score(action, asset: asset, context: highlight) > ranker.score(memory, asset: asset, context: highlight))
    #expect(ranker.score(memory, asset: asset, context: memories) > ranker.score(action, asset: asset, context: memories))
}

@Test func storyEngineExposesCompleteVariantsForGlobalEvaluation() {
    let (assets, analyses) = storyFixture()
    let constraints = StoryConstraints(targetDuration: 18, targetClipCount: 3, pacing: 0.7)
    let variants = StoryEngine().createPlanVariants(
        prompt: "Динамичная история с людьми и природой",
        preset: .story,
        constraints: constraints,
        assets: assets,
        analyses: analyses
    )
    #expect(!variants.isEmpty)
    #expect(variants.count <= 10)
    #expect(variants.allSatisfy { $0.plan.chapters.flatMap(\.candidateIDs).count == 3 })
    #expect(variants.allSatisfy { !$0.strategy.isEmpty })
}

@Test func directorBriefOverridesEveryStoryVariantAndComposerDeliveryChoices() throws {
    let (assets, analyses) = storyFixture()
    let brief = DirectorBrief(
        canvasFormat: .portrait9x16,
        requestedDuration: 37,
        mood: .dynamic,
        musicPolicy: .none,
        sourceAudioPolicy: .duck,
        titlePolicy: .none
    )
    let variants = StoryEngine().createPlanVariants(
        prompt: "Сделай фильм",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 12, pacing: 0.1),
        assets: assets,
        analyses: analyses,
        limit: 3,
        directorBrief: brief
    )
    let plan = try #require(variants.first?.plan)
    let timeline = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)

    #expect(variants.allSatisfy { $0.plan.directorBrief == brief })
    #expect(variants.allSatisfy { $0.plan.contentBudget?.requestedDuration == 37 && $0.plan.constraints.targetDuration <= 37 })
    #expect(variants.allSatisfy { abs($0.plan.constraints.pacing - DirectorNarrativeMood.dynamic.pacing) < 0.000_1 })
    #expect(timeline.width == 1080)
    #expect(timeline.height == 1920)
    #expect(abs(timeline.effectiveOriginalAudioVolume - DirectorSourceAudioPolicy.duck.volume) < 0.000_1)
    #expect(timeline.music == nil)
    #expect(timeline.effectiveTitleItems.isEmpty)
}

@Test func composerPreservesSpecificTrackFromDirectorBrief() throws {
    let (assets, analyses) = storyFixture()
    let trackID = UUID()
    let brief = DirectorBrief(
        requestedDuration: 20,
        musicPolicy: .specificTrack,
        musicTrackID: trackID
    )
    let plan = StoryEngine().createPlan(
        prompt: "История поездки",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 20),
        assets: assets,
        analyses: analyses,
        directorBrief: brief
    )
    let timeline = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    let music = try #require(timeline.music)

    #expect(music.trackID == trackID)
}

@Test func portraitBriefRanksNativeAndSafelyReframedFootageAheadOfUnsafeLandscape() throws {
    func asset(_ name: String, width: Int, height: Int) -> MediaAsset {
        MediaAsset(
            originalURL: URL(fileURLWithPath: "/tmp/\(name).mov"),
            kind: .video,
            byteSize: 1,
            contentHash: name,
            metadata: MediaMetadata(duration: 20, width: width, height: height)
        )
    }
    func tracking() -> SubjectTrackingSummary {
        let track = SubjectTrack(
            kind: .person,
            label: "person",
            observations: [
                SubjectTrackObservation(
                    timestamp: 0,
                    region: NormalizedRegion(x: 0.42, y: 0.30, width: 0.12, height: 0.28),
                    confidence: 0.92
                ),
                SubjectTrackObservation(
                    timestamp: 5,
                    region: NormalizedRegion(x: 0.45, y: 0.30, width: 0.12, height: 0.28),
                    confidence: 0.92
                )
            ],
            meanConfidence: 0.92,
            visibility: 0.9,
            compositionQuality: 0.9,
            movementX: 0.03
        )
        return SubjectTrackingSummary(
            tracks: [track],
            mainSubjectID: track.id,
            confidence: 0.92,
            analyzedFrameCount: 2
        )
    }
    let portrait = asset("portrait", width: 1080, height: 1920)
    let safeLandscape = asset("safe-landscape", width: 1920, height: 1080)
    let unsafeLandscape = asset("unsafe-landscape", width: 1920, height: 1080)
    let scores = ClipScores(quality: 0.8, interest: 0.8, action: 0.7, stability: 0.8)
    let portraitCandidate = Candidate(assetID: portrait.id, sourceStart: 0, sourceDuration: 6, scores: scores)
    let safeCandidate = Candidate(
        assetID: safeLandscape.id,
        sourceStart: 0,
        sourceDuration: 6,
        scores: scores,
        insights: CandidateInsights(subjectTracking: tracking())
    )
    let unsafeCandidate = Candidate(assetID: unsafeLandscape.id, sourceStart: 0, sourceDuration: 6, scores: scores)
    let analyses = [
        AnalysisResult(assetID: portrait.id, analyzedContentHash: portrait.contentHash, candidates: [portraitCandidate]),
        AnalysisResult(assetID: safeLandscape.id, analyzedContentHash: safeLandscape.contentHash, candidates: [safeCandidate]),
        AnalysisResult(assetID: unsafeLandscape.id, analyzedContentHash: unsafeLandscape.contentHash, candidates: [unsafeCandidate])
    ]
    let brief = DirectorBrief(
        canvasFormat: .portrait9x16,
        requestedDuration: 6,
        musicPolicy: .none,
        titlePolicy: .none
    )
    let constraints = StoryConstraints(targetDuration: 6, targetClipCount: 1)

    let nativeFirst = StoryEngine().createPlanVariants(
        prompt: "Лучший кадр",
        preset: .story,
        constraints: constraints,
        assets: [portrait, safeLandscape, unsafeLandscape],
        analyses: analyses,
        limit: 1,
        directorBrief: brief
    )
    let nativePlan = try #require(nativeFirst.first?.plan)
    #expect(nativePlan.chapters.flatMap(\.candidateIDs) == [portraitCandidate.id])

    let safeFirst = StoryEngine().createPlanVariants(
        prompt: "Лучший кадр",
        preset: .story,
        constraints: constraints,
        assets: [safeLandscape, unsafeLandscape],
        analyses: Array(analyses.dropFirst()),
        limit: 1,
        directorBrief: brief
    )
    let safePlan = try #require(safeFirst.first?.plan)
    #expect(safePlan.chapters.flatMap(\.candidateIDs) == [safeCandidate.id])
}

@Test func legacyCandidateDecodesWithoutMomentBoundaryEvidence() throws {
    let json = """
    {
      "id":"00000000-0000-0000-0000-000000000001",
      "assetID":"00000000-0000-0000-0000-000000000002",
      "sourceStart":2,"sourceDuration":4,
      "scores":{"quality":0.7,"interest":0.6,"action":0.5,"stability":0.8,"uniqueness":1},
      "tags":[],"explanation":[],"locked":false,"excluded":false
    }
    """
    let candidate = try JSONDecoder().decode(Candidate.self, from: Data(json.utf8))
    #expect(candidate.momentBoundary == nil)
    #expect(candidate.sourceStart == 2)
}
