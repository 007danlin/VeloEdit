import Foundation
import Testing
@testable import VeloEditCore

@Suite struct CinematicKnowledgeTests {
    func fixture(hasAudio: Bool = false, fps: Double = 60) -> (ProjectManifest, Timeline) {
        let assets = (0..<3).map { i in
            MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/cinematic-\(i).mov"), kind: .video, byteSize: 100,
                       contentHash: "cinematic-\(i)", metadata: MediaMetadata(duration: 30, width: 1920, height: 1080, frameRate: fps, hasAudio: hasAudio))
        }
        let items = assets.map { asset in
            TimelineItem(assetID: asset.id, kind: .video, sourceStart: 2, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
        }
        let timeline = Timeline(storyPlanID: UUID(), items: TimelineTiming.retimed(items))
        return (ProjectManifest(name: "Cinematic fixture", assets: assets, timelines: [timeline]), timeline)
    }

    @Test func sourceAuditAndCardsAreCompleteAndUseRealIDsOffline() throws {
        let base = try CinematicKnowledgeBase.load()
        #expect(base.cards.count == 100)
        #expect(CinematicKnowledgeBase.audit.count == 424)
        #expect(base.cards.filter { ["editing", "framing", "composition"].contains($0.category) }.count == 80)
        #expect(base.cards.filter { $0.status == .applicable }.count == 8)
        for card in base.cards {
            #expect(!card.definition.isEmpty && !card.purpose.isEmpty && !card.negativeExample.isEmpty && !card.verification.isEmpty)
            #expect(card.retrievedOn == "2026-10-09")
            #expect(card.allowedCommands.allSatisfy(CinematicCapabilityCatalog.commandIDs.contains))
            #expect(card.transitionIDs.allSatisfy { TransitionStyle(rawValue: $0) != nil })
            #expect(card.effectIDs.allSatisfy { TimelineEffectType(rawValue: $0) != nil })
        }
        #expect(base.technique(id: "editing/match-cut")?.allowedCommands.isEmpty == true)
        #expect(!TimelineEffectType.allCases.contains { $0.rawValue == "match-cut" })
        #expect(base.retrieve(request: "Rule of Thirds", availableFeatures: [], limit: 3).first?.id == "composition/rule-of-thirds")
        #expect(base.matching("unmatched cutter").isEmpty)
    }

    @Test func namedDissolveTravelsThroughTheNaturalLanguageDirector() throws {
        var (project, timeline) = fixture()
        timeline.items.removeLast()
        project.timelines = [timeline]
        let input = NaturalLanguageDirectorInput(userRequest: "Добавь наплыв между клипами", currentProject: project, timeline: timeline)
        let director = NaturalLanguageDirector()
        let plan = director.plan(input: input, supplementalCommands: [.setSpeed(8, .all)])
        #expect(plan.cinematicPlan != nil && plan.commands.isEmpty)
        let result = director.execute(plan: plan, input: input)
        #expect(result.committed, "\(result.userSummary); \(result.toolReport.rejected)")
        #expect(result.toolReport.applied.count == 1)
        #expect(result.timeline.effectiveTransitionItems.count == 1)
        #expect(result.timeline.effectiveTransitionItems.allSatisfy { $0.style == .crossDissolve })
        #expect(result.timeline.items.map(\.sourceStart) == timeline.items.map(\.sourceStart))
        #expect(result.timeline.items.allSatisfy { $0.speed == 1 })
    }

    @Test(arguments: ["Сделай match cut между клипами", "Сделай graphic match между клипами", "Добавь морфинг между клипами",
                      "Примени Datamosh", "Примени Dolly Zoom", "Примени Earth Zoom", "Используй Rule of Thirds"])
    func unsupportedOrUnconfirmedTechniqueCannotFallThrough(_ request: String) {
        let (project, timeline) = fixture()
        let input = NaturalLanguageDirectorInput(userRequest: request, currentProject: project, timeline: timeline)
        let director = NaturalLanguageDirector()
        let plan = director.plan(input: input, supplementalCommands: [.addLibraryEffect(.glitch, .all)])
        #expect(plan.cinematicPlan != nil)
        let result = director.execute(plan: plan, input: input)
        #expect(!result.committed && result.timeline == timeline)
        #expect(result.toolReport.applied.isEmpty && !result.toolReport.rejected.isEmpty)
    }

    @Test(arguments: ["unknownCommand", "unknownCard", "unknownStyle", "negative", "nan", "infinite", "extraParameter", "missingParameter",
                      "unknownTarget", "outsideScope", "nonAdjacent", "lockedIncoming", "lockedOutgoing", "wrongProject", "wrongTimeline", "tooLong", "unrequested"])
    func malformedPlansAreAtomic(_ scenario: String) throws {
        var (project, timeline) = fixture()
        let ids = Set(timeline.items.map(\.id))
        var plan = try #require(CinematicDirector.plan(request: "Добавь наплыв между клипами", targetIDs: Array(ids), project: project, timeline: timeline))
        // Put a valid first step before the invalid one to check rollback.
        var step = plan.steps[1]
        var scope = ids
        switch scenario {
        case "unknownCommand": step.commandID = "match-cut"
        case "unknownCard": step.techniqueID = "unknown"
        case "unknownStyle": step.styleID = "morph"
        case "negative": step.parameters["duration"] = -1
        case "nan": step.parameters["duration"] = .nan
        case "infinite": step.parameters["duration"] = .infinity
        case "extraParameter": step.parameters["invented"] = 1
        case "missingParameter": step.parameters = [:]
        case "unknownTarget": step.itemID = UUID()
        case "outsideScope": scope.remove(step.itemID)
        case "nonAdjacent": step.relatedItemID = timeline.items[0].id
        case "lockedIncoming": timeline.items[2].locked = true
        case "lockedOutgoing": timeline.items[1].locked = true
        case "wrongProject": plan.projectID = UUID()
        case "wrongTimeline": plan.timelineID = UUID()
        case "tooLong": step.parameters["duration"] = 3
        case "unrequested": plan.request = "Оставь как есть"
        default: break
        }
        plan.steps[1] = step
        project.timelines = [timeline]
        let result = CinematicDirector.execute(plan, project: project, timeline: timeline, authorizedScope: scope)
        #expect(result.timeline == timeline)
        #expect(result.report.applied.isEmpty && !result.report.rejected.isEmpty)
    }

    @Test func slowMotionRequiresMeasuredFPSAndProtectsUnknownAudio() throws {
        for (fps, hasAudio, accepted) in [(60.0, false, true), (30.0, false, false), (60.0, true, false)] {
            let (project, timeline) = fixture(hasAudio: hasAudio, fps: fps)
            let id = timeline.items[0].id
            let plan = try #require(CinematicDirector.plan(request: "Добавь slow motion", targetIDs: [id], project: project, timeline: timeline))
            let result = CinematicDirector.execute(plan, project: project, timeline: timeline, authorizedScope: [id])
            #expect(result.report.rejected.isEmpty == accepted)
            #expect(accepted ? result.timeline.items[0].speed == 0.5 : result.timeline == timeline)
        }
    }

    @Test func opticalOverlapCannotTreatMissingSpeechAnalysisAsSilence() throws {
        var (project, timeline) = fixture(hasAudio: true)
        timeline.items.removeLast()
        let scope = Set(timeline.items.map(\.id))
        let plan = try #require(CinematicDirector.plan(request: "Добавь наплыв между клипами", targetIDs: Array(scope), project: project, timeline: timeline))
        for mutedCount in 0...2 {
            for index in timeline.items.indices { timeline.items[index].audioAdjustments = AudioAdjustments(muted: index < mutedCount) }
            project.timelines = [timeline]
            let result = CinematicDirector.execute(plan, project: project, timeline: timeline, authorizedScope: scope)
            if mutedCount == 2 { #expect(result.report.applied.count == 1 && result.report.rejected.isEmpty) }
            else { #expect(result.timeline == timeline && result.report.applied.isEmpty && !result.report.rejected.isEmpty) }
        }
    }

    @Test func speechNoEffectsAndSelectedScopeOverrideKnowledge() throws {
        var (project, timeline) = fixture(hasAudio: true)
        var plan = try #require(CinematicDirector.plan(request: "Добавь наплыв между клипами", targetIDs: timeline.items.map(\.id), project: project, timeline: timeline))
        let source = timeline.items[1]
        let candidate = Candidate(assetID: source.assetID!, sourceStart: 2, sourceDuration: 4,
                                  scores: ClipScores(quality: 1, interest: 1, action: 0, stability: 1, uniqueness: 1),
                                  insights: CandidateInsights(speech: SpeechEditingEvidence(text: "Целая фраза", phraseStart: 2, phraseEnd: 6,
                                      confidence: 0.95, startsAtPhraseBoundary: true, endsAtPhraseBoundary: true)))
        project.analyses = [AnalysisResult(assetID: source.assetID!, analyzedContentHash: project.assets[1].contentHash,
                                           candidates: [candidate], deepMediaVersion: DeepAnalysisCache.version)]
        let speechResult = CinematicDirector.execute(plan, project: project, timeline: timeline, authorizedScope: Set(timeline.items.map(\.id)))
        #expect(speechResult.timeline == timeline && speechResult.report.applied.isEmpty)
        plan.request += ". Без эффектов"
        #expect(!CinematicDirector.execute(plan, project: project, timeline: timeline, authorizedScope: Set(timeline.items.map(\.id))).report.rejected.isEmpty)
        timeline.items[0].locked = true
        let input = NaturalLanguageDirectorInput(userRequest: "Добавь наплыв в этот кадр", currentProject: project, timeline: timeline,
                                                selectedItemID: timeline.items[1].id)
        let result = NaturalLanguageDirector().execute(plan: NaturalLanguageDirector().plan(input: input), input: input)
        #expect(!result.committed && result.timeline == timeline)
    }

    @Test func contextualTechniqueNamesDoNotReplaceAnOrdinaryRequest() {
        let (project, timeline) = fixture()
        for request in ["Добавь титр Интервью", "Сделай музыку для интервью тише", "Покажи информацию о симметрии"] {
            let input = NaturalLanguageDirectorInput(userRequest: request, currentProject: project, timeline: timeline)
            #expect(NaturalLanguageDirector().plan(input: input).cinematicPlan == nil)
        }
    }

    @Test func timingCannotShiftALockedNeighborAndMixedPlansCannotExecute() throws {
        var (project, timeline) = fixture()
        timeline.items[1].locked = true
        project.timelines = [timeline]
        let plan = try #require(CinematicDirector.plan(request: "Добавь Slow Motion", targetIDs: [timeline.items[0].id], project: project, timeline: timeline))
        let result = CinematicDirector.execute(plan, project: project, timeline: timeline, authorizedScope: [timeline.items[0].id])
        #expect(result.timeline == timeline && result.report.applied.isEmpty && !result.report.rejected.isEmpty)
        let input = NaturalLanguageDirectorInput(userRequest: "Добавь Slow Motion", currentProject: project, timeline: timeline, selectedItemID: timeline.items[0].id)
        var mixed = NaturalLanguageDirector().plan(input: input)
        mixed.commands = [.setSpeed(8, .all)]
        let executed = NaturalLanguageDirector().execute(plan: mixed, input: input)
        #expect(executed.timeline == timeline && !executed.committed)
    }

    @Test func semanticParametersAndFixedDurationAreMandatory() throws {
        let (initialProject, initialTimeline) = fixture()
        let id = initialTimeline.items[0].id
        for (request, rate) in [("Добавь Slow Motion", 2.0), ("Добавь Fast Motion", 0.5)] {
            var plan = try #require(CinematicDirector.plan(request: request, targetIDs: [id], project: initialProject, timeline: initialTimeline))
            plan.steps[0].parameters["rate"] = rate
            let result = CinematicDirector.execute(plan, project: initialProject, timeline: initialTimeline, authorizedScope: [id])
            #expect(result.timeline == initialTimeline && result.report.applied.isEmpty && !result.report.rejected.isEmpty)
        }
        var project = initialProject
        var timeline = initialTimeline
        timeline.items.removeLast()
        let scope = Set(timeline.items.map(\.id))
        var wipe = try #require(CinematicDirector.plan(request: "Добавь шторку вправо между клипами", targetIDs: Array(scope), project: project, timeline: timeline))
        wipe.steps[0].styleID = "wipe-left"
        #expect(!CinematicDirector.execute(wipe, project: project, timeline: timeline, authorizedScope: scope).report.rejected.isEmpty)
        let dissolve = try #require(CinematicDirector.plan(request: "Добавь наплыв между клипами", targetIDs: Array(scope), project: project, timeline: timeline))
        project.workspaceState = ProjectWorkspaceState(prompt: "", preset: .cinematic, targetMinutes: 1,
                                                      directorBrief: DirectorBrief(requestedDuration: 8))
        let fixed = CinematicDirector.execute(dissolve, project: project, timeline: timeline, authorizedScope: scope)
        #expect(fixed.timeline == timeline && fixed.report.applied.isEmpty && !fixed.report.rejected.isEmpty)
        project.workspaceState = nil
        timeline.items = initialTimeline.items
        timeline.items[2].locked = true
        let locked = CinematicDirector.execute(dissolve, project: project, timeline: timeline, authorizedScope: scope)
        #expect(locked.timeline == timeline && locked.report.applied.isEmpty && !locked.report.rejected.isEmpty)
    }
}
