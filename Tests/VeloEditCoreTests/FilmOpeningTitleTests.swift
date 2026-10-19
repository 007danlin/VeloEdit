import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import VeloEditCore

@Suite struct FilmOpeningTitleTests {
    private func fixture(duration: Double = 30, settings: FilmOpeningSettings? = .init()) -> (StoryPlan, Timeline) {
        let candidate = UUID()
        let plan = StoryPlan(prompt: "Собери фильм", preset: .cinematic,
            constraints: .init(targetDuration: duration), chapters: [.init(title: "Прогулка у реки", candidateIDs: [candidate])],
            directorBrief: .init(musicPolicy: .none, openingTitles: settings))
        let timeline = Timeline(storyPlanID: plan.id, items: [.init(candidateID: candidate, assetID: UUID(), kind: .video,
            sourceDuration: duration, timelineStart: 0, timelineDuration: duration)], originalAudioVolume: 0.37)
        return (plan, timeline)
    }

    @Test func automaticOpeningIsAnEditableOverlayAndIdempotent() throws {
        let (plan, source) = fixture()
        let result = FilmOpeningTitles.reconcile(source, plan: plan)
        let title = try #require(result.effectiveTitleItems.first)
        #expect(title.semanticRole == .filmOpening)
        #expect(title.startTime == 0.8)
        #expect(title.text == "Прогулка у реки")
        #expect(title.additionalText == nil && title.targetClipID == nil)
        #expect(TitleTemplateRegistry.all.contains { $0.id == title.templateID })
        #expect(result.duration == source.duration && result.items == source.items)
        #expect(result.originalAudioVolume == source.originalAudioVolume && result.music == source.music)
        #expect(result.openingTitleDecision?.warning == nil)
        #expect(FilmOpeningTitles.reconcile(result, plan: plan) == result)
        let reloaded = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(result))
        #expect(FilmOpeningTitles.reconcile(reloaded, plan: plan) == result)
    }

    @Test func oldDocumentsDoNotAcquireAnOpening() throws {
        let (plan, source) = fixture(settings: nil)
        let decoded = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(source))
        #expect(decoded.openingTitles == nil)
        #expect(FilmOpeningTitles.reconcile(decoded, plan: plan) == source)
        let decodedBrief = try JSONDecoder().decode(DirectorBrief.self, from: JSONEncoder().encode(plan.directorBrief!))
        #expect(decodedBrief.openingTitles == nil)
    }

    @Test func manualTextStyleAndTimingSurviveFirstClipReplacement() throws {
        let (plan, source) = fixture()
        var previous = FilmOpeningTitles.reconcile(source, plan: plan)
        let id = try #require(previous.effectiveTitleItems.first?.id)
        _ = TimelineMutationEngine.updateTitle(in: &previous, id: id) {
            $0.text = "Наше путешествие\nдомой 🏕"; $0.additionalText = ""
            $0.startTime = 1.7; $0.style.textColorHex = "#FFDDAA"
        }
        var generated = FilmOpeningTitles.reconcile(source, plan: plan)
        generated.items[0].id = UUID(); generated.items[0].assetID = UUID()
        let carried = TitleEditPreservation.applying(from: previous, to: generated, clipIDs: [:])
        let result = FilmOpeningTitles.reconcile(carried, plan: plan)
        #expect(result.effectiveTitleItems.filter { $0.semanticRole == .filmOpening } == previous.effectiveTitleItems)
    }

    @Test func deletionAndOffSurviveRebuildAndCanBeExplicitlyReenabled() throws {
        let (plan, source) = fixture()
        var previous = FilmOpeningTitles.reconcile(source, plan: plan)
        let id = try #require(previous.effectiveTitleItems.first?.id)
        FilmOpeningTitles.rememberDeletion(in: &previous, titleID: id)
        previous.titleItems?.removeAll { $0.id == id }
        let generated = FilmOpeningTitles.reconcile(source, plan: plan)
        let carried = TitleEditPreservation.applying(from: previous, to: generated, clipIDs: [:])
        #expect(FilmOpeningTitles.reconcile(carried, plan: plan).effectiveTitleItems.isEmpty)
        let on = FilmOpeningTitles.reconcile(carried, plan: plan, applying: .init())
        #expect(on.effectiveTitleItems.count == 1)
        #expect(on.effectiveTitleItems.first?.id == id)
    }

    @Test func otherTitlesDoNotSatisfyTheFilmOpeningRole() {
        var (plan, source) = fixture()
        source.titleItems = [.init(kind: .automaticSubtitles, text: "Речь", startTime: 0, duration: 3),
                             .init(kind: .chapter, text: "Позже", startTime: 20, duration: 4)]
        let result = FilmOpeningTitles.reconcile(source, plan: plan)
        #expect(result.effectiveTitleItems.count == 3)
        #expect(result.effectiveTitleItems.filter { $0.semanticRole == .filmOpening }.count == 1)
        #expect(source.effectiveTitleItems.allSatisfy { result.effectiveTitleItems.contains($0) })
    }

    @Test func chapterSchedulingStaysInsideItsPart() throws {
        var (plan, source) = fixture()
        plan.directorBrief?.titlePolicy = .keyOnly
        let result = EditorialIntentEnforcer.enforce(source, plan: plan)
        let opening = try #require(result.effectiveTitleItems.first { $0.semanticRole == .filmOpening })
        let chapter = try #require(result.effectiveTitleItems.first { $0.kind == .chapter })
        #expect(chapter.startTime >= opening.endTime + 0.14)
        #expect(chapter.endTime <= source.duration)
        #expect(EditorialPresentationPolicy.missingChapterTitles(in: result, plan: plan).isEmpty)
        #expect(EditorialIntentEnforcer.enforce(result, plan: plan) == result)
        plan.directorBrief?.openingTitles?.title = "Название всего фильма"
        source.items[0].timelineDuration = 3
        let conflict = EditorialIntentEnforcer.enforce(source, plan: plan)
        #expect(conflict.duration == 3)
        #expect(conflict.effectiveTitleItems.contains { $0.kind == .chapter && $0.enabled })
        #expect(conflict.openingTitleDecision?.warning != nil)
    }

    @Test func matchingOpeningCanFulfilAChapterWithoutDeletingThePart() throws {
        var (plan, source) = fixture(duration: 6)
        plan.directorBrief?.titlePolicy = .keyOnly
        let result = EditorialIntentEnforcer.enforce(source, plan: plan)
        let opening = try #require(result.effectiveTitleItems.first { $0.semanticRole == .filmOpening })
        #expect(opening.fulfilledChapterID != nil)
        #expect(result.effectiveTitleItems.filter(\.enabled).count == 1)
        #expect(EditorialPresentationPolicy.missingChapterTitles(in: result, plan: plan).isEmpty)
        #expect(EditorialIntentEnforcer.enforce(result, plan: plan) == result)
        source = FilmOpeningTitles.reconcile(result, plan: plan, applying: .init(policy: .off))
        #expect(source.effectiveTitleItems.contains { $0.kind == .chapter && $0.enabled })
    }

    @Test func noTitlesWinsAndManualNamesAreNeverShortened() throws {
        var (plan, source) = fixture(settings: .init(policy: .selected, title: String(repeating: "Очень длинное название фильма ", count: 30), templateID: "title.elegant.v1"))
        let result = FilmOpeningTitles.reconcile(source, plan: plan)
        #expect(result.effectiveTitleItems.first?.text == plan.directorBrief?.openingTitles?.title)
        #expect(result.openingTitleDecision?.warning != nil)
        #expect(result.effectiveTitleItems.first?.enabled == false)
        plan.directorBrief?.titlePolicy = .none
        #expect(FilmOpeningTitles.reconcile(result, plan: plan).effectiveTitleItems.isEmpty)
    }

    @Test func namingUsesAuthoredProjectOrWholeFilmEvidence() {
        var (plan, source) = fixture()
        #expect(FilmOpeningTitles.reconcile(source, plan: plan, projectName: "Семейные каникулы").effectiveTitleItems.first?.text == "Семейные каникулы")
        #expect(FilmOpeningTitles.meaningfulName("GX010620.MP4") == nil)
        plan.chapters.append(.init(title: "Рыбалка", candidateIDs: []))
        #expect(FilmOpeningTitles.reconcile(source, plan: plan).effectiveTitleItems.first?.text == "Прогулка у реки и Рыбалка")
        plan.directorBrief?.openingTitles?.title = "Своё название"
        #expect(FilmOpeningTitles.reconcile(source, plan: plan, projectName: "Имя проекта").effectiveTitleItems.first?.text == "Своё название")
    }

    @Test(arguments: [3.0, 8.0, 15.0, 30.0])
    func timingFitsTheOriginalRuntime(_ duration: Double) throws {
        let (plan, source) = fixture(duration: duration, settings: .init(title: "Наш день", subtitle: "Подпись"))
        let result = FilmOpeningTitles.reconcile(source, plan: plan)
        let title = try #require(result.effectiveTitleItems.first)
        #expect(title.endTime <= source.duration)
        #expect(result.duration == source.duration)
        if duration <= 15 { #expect(title.additionalText == nil) }
        if duration < 6 { #expect(title.animation.entrance == .none) }
    }

    @Test func realWeightsFallbackRunsAndLegacyAppearance() throws {
        let faces = TitleFontResolver.faces(family: "Avenir Next")
        #expect(Set(faces.map(\.id)).count >= 4)
        let names = [0.4, 0.55, 0.7, 0.85].map {
            CTFontCopyPostScriptName(TitleFontResolver.font(family: "Avenir Next", size: 72, weight: $0, version: 2)) as String
        }
        #expect(Set(names).count >= 3)
        let legacy = TitleFontResolver.font(family: "Avenir Next", size: 72, weight: 0.62)
        #expect(CTFontCopyPostScriptName(legacy) as String == "AvenirNext-Regular")
        for text in ["ДОРОГА ДОМОЙ", "ДОРОГА ДОМОЙ 🏕", "ДОРОГА\nДОМОЙ 👨‍👩‍👧‍👦"] {
            let font = TitleFontResolver.font(family: "Georgia", size: 72, weight: 0.4, version: 2)
            let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(string)) as! [CTRun]
            let first = try #require(runs.first)
            let attributes = CTRunGetAttributes(first) as NSDictionary
            let actual = try #require(attributes[kCTFontAttributeName] as! CTFont?)
            #expect(CTFontCopyFamilyName(actual) as String == "Georgia")
        }
        var missing = TitleStyle(fontFamily: "Nonexistent Velo Font")
        missing.typographyVersion = 2
        #expect(TitleFontResolver.replacementFamily(style: missing) == "Avenir Next")
    }

    @Test func revisionImprovesSecondaryTypographyWithoutRestylingSavedTitles() throws {
        for template in TitleTemplateRegistry.all where template.id != "title.chapter-compact.v1" {
            var new = template.previewItem()
            let revised = try #require(TitleTemplateRegistry.template(for: new))
            #expect(revised.layout.elements.filter { $0.content == .secondaryText }.allSatisfy { ($0.typography?.fontSize ?? 32) >= 32 })
            new.style.typographyVersion = nil
            #expect(TitleTemplateRegistry.template(for: new)?.layout == template.layout)
        }
    }

    @Test func libraryDoesNotInsertDemoDataAndCommandsKeepEmptyFields() throws {
        for template in TitleTemplateRegistry.all {
            let item = template.makeTimelineItem(text: "", startTime: 4)
            #expect(item.text == "Название" && item.startTime == 4)
            #expect(item.additionalText == nil && item.callToAction == nil)
            #expect(item.style == template.defaultStyle)
            let renamed = try #require(TitleEditInterpreter.applying("шаблон \(template.name)", to: item))
            #expect(renamed.item.additionalText == nil && renamed.item.callToAction == nil)
        }
        let original = TitleTemplateRegistry.all[0].makeTimelineItem(text: "Наш день", startTime: 0)
        #expect(TitleEditInterpreter.applying("кино без рамки", to: original)?.item.templateID == "title.cinematic-clean.v1")
        #expect(TitleEditInterpreter.applying("compact chapter", to: original)?.item.templateID == "title.chapter-compact.v1")
    }

    @Test func globalNoTitlesDoesNotRestoreACombinedChapter() {
        var (plan, source) = fixture(duration: 6)
        plan.directorBrief?.titlePolicy = .keyOnly
        source = EditorialIntentEnforcer.enforce(source, plan: plan)
        #expect(source.openingTitleDecision?.combinedChapter != nil)
        plan.directorBrief?.titlePolicy = DirectorTitlePolicy.none
        #expect(EditorialIntentEnforcer.enforce(source, plan: plan).effectiveTitleItems.isEmpty)
    }

    @Test func automaticOpeningRetainsIdentityWhenTheStoryIsRebuilt() throws {
        let (plan, source) = fixture()
        let previous = FilmOpeningTitles.reconcile(source, plan: plan, projectName: "Наши каникулы")
        var changedPlan = plan
        changedPlan.id = UUID()
        var changed = source
        changed.storyPlanID = changedPlan.id
        changed.items[0].id = UUID()
        let rebuilt = FilmOpeningTitles.reconcile(changed, plan: changedPlan)
        let carried = TitleEditPreservation.applying(from: previous, to: rebuilt, clipIDs: [:])
        let final = FilmOpeningTitles.reconcile(carried, plan: changedPlan)
        #expect(final.effectiveTitleItems.first?.id == previous.effectiveTitleItems.first?.id)
        #expect(final.effectiveTitleItems.first?.text == "Наши каникулы")
        #expect(final.openingTitleDecision?.titleSource == "project")
    }

    @Test func protectedCenterUsesAPublicPlacementAndRespectsExplicitDesign() throws {
        var (plan, source) = fixture()
        source.openingTitleEvidence = .init(spacious: false, busy: false, dynamics: 0.2, protectedCenter: true, protectedUpper: false)
        let result = FilmOpeningTitles.reconcile(source, plan: plan)
        let automatic = try #require(result.effectiveTitleItems.first)
        #expect(automatic.style.placement == .upper && automatic.enabled)
        let template = try #require(TitleTemplateRegistry.template(id: automatic.templateID))
        var manual = template.makeTimelineItem(text: automatic.text, startTime: automatic.startTime, duration: automatic.duration)
        manual.style.placement = .upper
        let size = CGSize(width: 640, height: 360)
        let a = TitleOverlayRenderer.cgImage(item: automatic, timelineTime: 2, renderSize: size)?.dataProvider?.data as Data?
        let b = TitleOverlayRenderer.cgImage(item: manual, timelineTime: 2, renderSize: size)?.dataProvider?.data as Data?
        #expect(a != nil && a == b)
        let chosen = FilmOpeningTitles.reconcile(source, plan: plan, applying: .init(policy: .selected, templateID: "title.elegant.v1"))
        #expect(chosen.effectiveTitleItems.first?.templateID == "title.elegant.v1")
        #expect(chosen.openingTitleDecision?.warning != nil)
    }

    @Test func rejectedOpeningLeavesAllExistingHeadingsUntouched() throws {
        var (plan, source) = fixture(settings: .init(title: String(repeating: "Очень длинное название ", count: 40)))
        let chapter = TitleTemplateRegistry.template(id: "title.chapter-compact.v1")!
            .makeTimelineItem(text: "Прогулка у реки", startTime: 0, duration: 5)
        source.titleItems = [chapter]
        let result = FilmOpeningTitles.reconcile(source, plan: plan)
        #expect(result.effectiveTitleItems.first { $0.id == chapter.id } == chapter)
        #expect(result.effectiveTitleItems.first { $0.semanticRole == .filmOpening }?.enabled == false)
        #expect(result.openingTitleDecision?.movedChapter == nil)
        #expect(result.openingTitleDecision?.combinedChapter == nil)
        #expect(FilmOpeningTitles.reconcile(result, plan: plan) == result)
    }

    @Test func publicPlacementKeepsFullCanvasBackgroundAndCompactTextInsideTheFrame() throws {
        for id in ["title.end-card.v1", "title.chapter-compact.v1"] {
            let template = try #require(TitleTemplateRegistry.template(id: id))
            for size in [CGSize(width: 640, height: 360), CGSize(width: 360, height: 640)] {
                let original = AdaptiveTitleLayout.resolve(template: template, renderSize: size)
                for placement in [TitlePlacement.upper, .center, .lower] {
                    var item = template.makeTimelineItem(text: "Наш день", startTime: 0)
                    item.style.placement = placement
                    let layout = AdaptiveTitleLayout.resolve(template: template, renderSize: size, item: item)
                    for element in template.layout.elements where !element.followsSafeArea {
                        #expect(layout.element(id: element.id)?.frame == original.element(id: element.id)?.frame)
                    }
                    let regions = TitleOverlayRenderer.textLayout(item: item, timelineTime: 2, renderSize: size)
                    #expect(!regions.isEmpty)
                    let canvas = CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1)
                    #expect(regions.allSatisfy { canvas.contains($0.bounds) })
                }
            }
        }
    }
}
