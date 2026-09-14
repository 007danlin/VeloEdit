import Foundation
import CoreGraphics
import Testing
@testable import VeloEditCore

@Suite struct DirectorVisualStyleTests {
    private func fixture(_ mood: DirectorNarrativeMood) -> (StoryPlan, Timeline) {
        let ids = (0..<4).map { _ in UUID() }, events = [UUID(), UUID()]
        let chapters = ids.enumerated().map { index, id in
            StoryChapter(title: index < 2 ? "Рыбалка" : "Поездка на багги", candidateIDs: [id],
                eventID: events[index / 2], eventSceneID: events[index / 2])
        }
        let plan = StoryPlan(prompt: "Титры: названия каждой части и ключевых событий.", preset: .adventure,
            constraints: StoryConstraints(targetDuration: 16), chapters: chapters,
            directorBrief: DirectorBrief(requestedDuration: 0, mood: mood, musicPolicy: .none, titlePolicy: .keyOnly))
        let items = ids.enumerated().map { index, id in
            TimelineItem(candidateID: id, assetID: UUID(), kind: .video, sourceDuration: 4,
                timelineStart: Double(index) * 4, timelineDuration: 4,
                eventID: events[index / 2], eventSceneID: events[index / 2])
        }
        return (plan, Timeline(storyPlanID: plan.id, items: items))
    }

    @Test(arguments: DirectorNarrativeMood.allCases)
    func everyPartGetsCompactReadableHeadingsAcrossMoods(_ mood: DirectorNarrativeMood) {
        let (plan, timeline) = fixture(mood)
        let result = EditorialIntentEnforcer.enforce(timeline, plan: plan)
        #expect(result.items == timeline.items)
        #expect(result.effectiveTitleItems.map(\.startTime) == [0, 8])
        #expect(result.effectiveTitleItems.allSatisfy { $0.duration >= 3.5 && $0.style.fontSize == 72 })
        #expect(result.effectiveTitleItems.allSatisfy { $0.animation.entrance == .none && $0.kind == .chapter })
        #expect(result.effectiveTitleItems.allSatisfy { $0.templateID == "title.minimal-clean.v1" })
        #expect(result.effectiveTitleItems[0].endTime <= 8)
        #expect(EditorialIntentEnforcer.enforce(result, plan: plan) == result)
        #expect(EditorialPresentationPolicy.missingChapterTitles(in: result, plan: plan).isEmpty)
        let delivery = TimelineDeliveryContract().validateAndRepair(timeline: result, plan: plan, assets: []).timeline
        #expect(delivery.effectiveTitleItems == result.effectiveTitleItems)
        #expect(result.effectiveEffects.isEmpty)
    }

    @Test func longerTextGetsMoreReadingTimeWithoutLeakingIntoTheNextPart() {
        var (plan, timeline) = fixture(.cinematic)
        for i in 0..<2 { plan.chapters[i].title = "Большое путешествие по северному побережью Байкала" }
        let result = EditorialIntentEnforcer.enforce(timeline, plan: plan)
        #expect(result.effectiveTitleItems[0].duration > 5.5)
        #expect(result.effectiveTitleItems[0].endTime <= 8)
        timeline.items = [timeline.items[0]]
        timeline.items[0].timelineDuration = 3
        timeline.items[0].sourceDuration = 3
        let short = EditorialIntentEnforcer.enforce(timeline, plan: plan)
        #expect(short.effectiveTitleItems.first?.duration == 3)
        #expect(short.duration == 3)
    }

    @Test func subtitlesAndManualTitleEditsKeepTheirOwnTimingAndTypography() {
        var (plan, timeline) = fixture(.cinematic)
        plan.directorBrief?.titlePolicy = .minimal
        plan.prompt = "Фильм"
        let manual = TitleTimelineItem(kind: .title, text: "Мой титр", startTime: 1, duration: 2, style: .init(fontSize: 56))
        let subtitle = TitleTimelineItem(kind: .automaticSubtitles, text: "Поехали!", startTime: 5, duration: 1,
            style: .init(fontSize: 58), explanation: ["Автоматические субтитры"])
        timeline.titleItems = [manual, subtitle]
        #expect(EditorialIntentEnforcer.enforce(timeline, plan: plan).effectiveTitleItems == timeline.effectiveTitleItems)
    }

    @Test func inspectorEditsSurviveAutomaticChapterReviewAndProjectReload() throws {
        let (plan, source) = fixture(.cinematic)
        var timeline = EditorialIntentEnforcer.enforce(source, plan: plan)
        let id = try #require(timeline.effectiveTitleItems.first?.id)
        #expect(TimelineMutationEngine.updateTitle(in: &timeline, id: id) {
            $0.templateID = "title.modern.v1"
            $0.kind = .title
            $0.text = "Мой первый день"
            $0.style.fontSize = 58
            $0.style.textColorHex = "#FF00CC"
            $0.style.opacity = 0.4
        })
        let edited = try #require(timeline.effectiveTitleItems.first { $0.id == id })
        #expect(edited.userEdited == true)
        let reloaded = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(timeline))
        let enforced = EditorialIntentEnforcer.enforce(reloaded, plan: plan)
        #expect(enforced.effectiveTitleItems.first { $0.id == id } == edited)
        #expect(enforced.effectiveTitleItems.count == 2)
        let delivery = TimelineDeliveryContract().validateAndRepair(timeline: enforced, plan: plan, assets: []).timeline
        #expect(delivery.effectiveTitleItems.first { $0.id == id } == edited)
        #expect(EditorialPresentationPolicy.hardeningReadability(edited) == edited)
        #expect(DirectorTitlePolicyEngine.applying(.none, to: [edited], timelineDuration: timeline.duration).isEmpty)
    }

    @Test func rebuildingFilmCarriesEditedTitlesWithTheirSourceClips() throws {
        let (plan, source) = fixture(.calm)
        var previous = EditorialIntentEnforcer.enforce(source, plan: plan)
        let titleID = try #require(previous.effectiveTitleItems.first?.id)
        _ = TimelineMutationEngine.updateTitle(in: &previous, id: titleID) {
            $0.style.textColorHex = "#00CCFF"
            $0.style.opacity = 0.3
            $0.style.fontSize = 60
        }
        var rebuilt = EditorialIntentEnforcer.enforce(source, plan: plan)
        for index in rebuilt.items.indices { rebuilt.items[index].id = UUID() }
        let result = VeloEditPipeline.carryEditorAdjustments(from: previous, to: rebuilt)
        let expected = try #require(previous.effectiveTitleItems.first)
        #expect(result.effectiveTitleItems.first { $0.id == titleID } == expected)
        let reviewed = EditorialIntentEnforcer.enforce(result, plan: plan)
        #expect(reviewed.effectiveTitleItems.first { $0.id == titleID } == expected)
        #expect(reviewed.effectiveTitleItems.count == 2)
    }

    @Test func cinematicChoiceOverridesAnAdventurePresetForTitlesAndTransitions() throws {
        let (plan, _) = fixture(.cinematic)
        let chosen = try #require(SmartTitleEngine().decide(.init(purpose: .chapter, requestedText: "Рыбалка",
            tags: ["action", "speed"], preferredTemplateID: "title.chapter.v1", mood: plan.directorBrief?.mood)))
        #expect(chosen.templateID == "title.minimal-clean.v1")
        #expect(chosen.duration == 5.5)
        var styles: [TransitionStyle?] = []
        for mood in DirectorNarrativeMood.allCases {
            let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/visual-style.mov"), kind: .video,
                byteSize: 1, contentHash: "visual-style", metadata: .init(duration: 30, width: 1920, height: 1080))
            let candidates = [0.0, 15].map { start in
                Candidate(assetID: asset.id, sourceStart: start, sourceDuration: 12,
                    scores: ClipScores(quality: 0.9, interest: 0.8, action: 0.3, stability: 0.9))
            }
            let chapters = candidates.enumerated().map { index, candidate in
                StoryChapter(title: index == 0 ? "Рыбалка" : "Поездка на багги", candidateIDs: [candidate.id], eventID: UUID())
            }
            var current = StoryPlan(prompt: "Фильм", preset: .adventure, constraints: .init(targetDuration: 20), chapters: chapters,
                directorBrief: .init(requestedDuration: 100, mood: mood, musicPolicy: .none, titlePolicy: .none))
            let analyses = [AnalysisResult(assetID: asset.id, analyzedContentHash: "visual-style", sceneTags: [], candidates: candidates)]
            let composed = TimelineComposer().compose(plan: current, assets: [asset], analyses: analyses)
            styles.append(composed.effectiveTransitionItems.first?.style)
            if let transition = composed.effectiveTransitionItems.first {
                #expect(transition.duration == DirectorVisualStyle(mood: mood).transitionDuration(for: transition.style))
            }
            current.prompt = "Без переходов"
            let cuts = TimelineComposer().compose(plan: current, assets: [asset], analyses: analyses)
            #expect(cuts.effectiveTransitionItems.isEmpty)
        }
        #expect(styles == [.crossDissolve, .fadeThroughBlack, nil])
    }

    @Test func chapterHeadingOccupiesLessPictureAndHoldsForReading() throws {
        let (plan, timeline) = fixture(.cinematic)
        let title = try #require(EditorialIntentEnforcer.enforce(timeline, plan: plan).effectiveTitleItems.first)
        var large = title
        large.style.fontSize = 136
        let size = CGSize(width: 1280, height: 720)
        let larger = try #require(TitleOverlayRenderer.cgImage(item: large, timelineTime: 0, renderSize: size))
        let smaller = try #require(TitleOverlayRenderer.cgImage(item: title, timelineTime: 0, renderSize: size))
        #expect(opaquePixels(larger) > opaquePixels(smaller) * 1.5)
        let held = try #require(TitleOverlayRenderer.cgImage(item: title, timelineTime: 3.3, renderSize: size))
        #expect(opaquePixels(held) > 1_000)
        #expect(TitleOverlayRenderer.cgImage(item: title, timelineTime: 4, renderSize: size) == nil)
    }

    @Test func generatedChapterPixelsMatchTheApprovedReferenceAndMigrateThePreviousAutomaticStyle() throws {
        let (plan, timeline) = fixture(.dynamic)
        let generated = EditorialIntentEnforcer.enforce(timeline, plan: plan)
        let actual = try #require(generated.effectiveTitleItems.first)
        let reference = TitleTimelineItem(kind: .chapter, templateID: "title.minimal-clean.v1", text: "Рыбалка", startTime: 0, duration: 3.5,
            style: TitleStyle(fontSize: 72, backgroundColorHex: "#111111", alignment: .left,
                fontFamily: "Avenir Next", fontWeight: 0.88, xPosition: 0.36, yPosition: 0.78, shadow: 0.25, backgroundOpacity: 0.75),
            animation: TitleAnimation(entrance: .none, exit: .none, duration: 0))
        #expect(actual.targetClipID == nil)
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720)] {
            for time in [0.0, 1, 3.3] {
                let a = try #require(TitleOverlayRenderer.cgImage(item: actual, timelineTime: time, renderSize: size)?.dataProvider?.data)
                let b = try #require(TitleOverlayRenderer.cgImage(item: reference, timelineTime: time, renderSize: size)?.dataProvider?.data)
                #expect((a as Data) == (b as Data))
            }
        }
        var legacy = generated
        legacy.titleItems?[0].style = TitleStyle(fontSize: 72, backgroundColorHex: "#101010", xPosition: 0.36, yPosition: 0.78, backgroundOpacity: 0.75)
        let migrated = EditorialPresentationPolicy.ensuringChapterTitles(in: legacy, plan: plan, preserveExistingPresentation: true)
        #expect(migrated.effectiveTitleItems.first?.style == reference.style)
        #expect(EditorialPresentationPolicy.ensuringChapterTitles(in: migrated, plan: plan, preserveExistingPresentation: true) == migrated)
    }

    private func opaquePixels(_ image: CGImage) -> Double {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let count: Int = bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress!, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return stride(from: 3, to: buffer.count, by: 4).reduce(0) { $0 + (buffer[$1] > 128 ? 1 : 0) }
        }
        return Double(count)
    }
}
