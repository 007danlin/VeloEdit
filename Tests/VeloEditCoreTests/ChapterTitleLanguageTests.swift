import Foundation
import Testing
@testable import VeloEditCore

private actor UnrestrictedTitleFixture: ChapterTitleModel {
    nonisolated let identity: String
    nonisolated let canGroundTitleCandidates = true
    var namesCalls = 0
    var languageCalls: [String] = []
    var verified: [String] = []
    let rejected: Set<String>
    let uncertain: Bool
    init(identity: String = "selected-weights-a", rejected: Set<String> = [], uncertain: Bool = false) {
        self.identity = identity; self.rejected = rejected; self.uncertain = uncertain
    }
    func reviewLanguage(_ title: String, maxCharacters: Int) async throws -> ChapterTitleLanguageAssessment {
        languageCalls.append(title)
        if uncertain { return .init(issue: .unclear, reason: "Fixture uncertainty", verdict: .uncertain) }
        if rejected.contains(title) { return .init(issue: .awkwardCollocation, reason: "Fixture non-idiomatic label", verdict: .revise) }
        return .init(issue: .none, reason: "Injected ordinary title for structural test", verdict: .natural)
    }
    func groundTitleCandidate(_ title: String, input: ChapterTitleInput) async throws -> ChapterTitleProposal? {
        .init(text: title, claims: [.init(text: title, kind: "setting", evidenceIDs: input.evidence.filter(\.selected).map(\.id))])
    }
    func verify(_ proposal: ChapterTitleProposal, input: ChapterTitleInput) async throws -> ChapterTitleVerification {
        verified.append(proposal.text)
        return .init(accepted: true, reasons: ["Injected content confirmation"], unsupportedClaims: [],
            evidenceIDs: proposal.claims.flatMap(\.evidenceIDs), coversWholePart: true)
    }
    func generate(_ input: ChapterTitleInput) async throws -> ChapterThemeProposal {
        namesCalls += 1
        let titles = ["У рояля", "Музыка"].map { name in
            ChapterTitleProposal(text: name, claims: [.init(text: name, kind: "setting", evidenceIDs: input.evidence.filter(\.selected).map(\.id))])
        }
        return .init(theme: "Музыка", setting: "У инструмента", secondaryActivities: [], contradictions: [], unknowns: [], titles: titles)
    }
}

extension SmartChapterTitlesTests {
    @Test func namesAreNotLimitedToTheNativeVocabularyAndStopAfterTheFirstVerifiedChoice() async throws {
        let (timeline, plan, assets, analyses) = fixture(partCount: 1)
        let model = UnrestrictedTitleFixture()
        let named = try await SmartChapterTitleEngine().applying(to: timeline, plan: plan,
            assets: assets, analyses: analyses, mode: .fast, model: model)
        let decision = try #require(named.chapterTitleDecisions?.first)
        #expect(decision.text == "У рояля" && decision.source == .model)
        #expect(await model.namesCalls == 1)
        #expect(await model.languageCalls == ["У рояля"])
        #expect(await model.verified == ["У рояля"])
        #expect(decision.modelCalls == 3)
        #expect(named.items == timeline.items)
    }

    @Test func readyCandidateCannotBypassIndependentLanguageReview() async throws {
        var (timeline, plan, assets, analyses) = fixture(partCount: 1)
        timeline.titleItems = [.init(kind: .chapter, text: "Музыкальная активность", startTime: 0,
                                    duration: 4, explanation: ["Editorial chapter"])]
        let model = UnrestrictedTitleFixture(rejected: ["Музыкальная активность"])
        let named = try await SmartChapterTitleEngine().applying(to: timeline, plan: plan,
            assets: assets, analyses: analyses, mode: .fast, model: model)
        #expect(named.chapterTitleDecisions?.first?.text == "У рояля")
        #expect(await model.languageCalls == ["Музыкальная активность", "У рояля"])
        #expect(await model.verified == ["У рояля"])
    }

    @Test func uncertaintyNeverBecomesAnApprovedTitleOrMeaningCertificate() async throws {
        let (timeline, plan, assets, analyses) = fixture(partCount: 1)
        let model = UnrestrictedTitleFixture(uncertain: true)
        let named = try await SmartChapterTitleEngine().applying(to: timeline, plan: plan,
            assets: assets, analyses: analyses, mode: .fast, model: model)
        #expect(named.chapterTitleDecisions?.first?.source == .fallback)
        #expect(await model.verified.isEmpty)
        // Repeated names do not cause repeated identical language judgements.
        #expect(await model.languageCalls == ["У рояля", "Музыка"])
        #expect(await model.namesCalls == 3)
        #expect(named.items == timeline.items)
        let report = AutomaticFilmDelivery.verifiedReport(for: named, plan: plan, assets: assets, analyses: analyses)
        let gate = try #require(report.requirements?.first { $0.rule == "chapterTitleMeaningAndLanguage" })
        #expect(gate.mandatory && !gate.passed)
    }

    @Test func exactGoodTitleIsRetainedAndLegacyMeaningOnlyNeedsTheNewLanguageGate() async throws {
        let (timeline, plan, assets, analyses) = fixture(partCount: 1)
        let model = UnrestrictedTitleFixture()
        var named = try await SmartChapterTitleEngine().applying(to: timeline, plan: plan,
            assets: assets, analyses: analyses, mode: .fast, model: model)
        named.chapterTitleDecisions?[0].languageReceipts = nil
        named.chapterTitleDecisions?[0].rulesVersion = 12
        let legacyReport = AutomaticFilmDelivery.verifiedReport(for: named, plan: plan, assets: assets, analyses: analyses)
        #expect(legacyReport.requirements?.first { $0.rule == "chapterTitleMeaningAndLanguage" }?.passed == false)
        let upgraded = try await SmartChapterTitleEngine().applying(to: named, plan: plan,
            assets: assets, analyses: analyses, mode: .fast, model: model)
        #expect(upgraded.effectiveTitleItems == named.effectiveTitleItems)
        #expect(await model.namesCalls == 1)
        #expect(await model.verified.count == 1)
        #expect(await model.languageCalls == ["У рояля", "У рояля"])
        #expect(upgraded.chapterTitleDecisions?.first?.rulesVersion == SmartChapterTitleEngine.rulesVersion)
        _ = try await SmartChapterTitleEngine().applying(to: upgraded, plan: plan,
            assets: assets, analyses: analyses, mode: .fast, model: model)
        #expect(await model.languageCalls.count == 2)
        #expect(await model.verified.count == 1)
    }

    @Test func languageReceiptCannotCrossToDifferentModelWeights() async throws {
        let (timeline, plan, assets, analyses) = fixture(partCount: 1)
        let first = UnrestrictedTitleFixture()
        let named = try await SmartChapterTitleEngine().applying(to: timeline, plan: plan,
            assets: assets, analyses: analyses, mode: .fast, model: first)
        let changed = UnrestrictedTitleFixture(identity: "selected-weights-b")
        _ = try await SmartChapterTitleEngine().applying(to: named, plan: plan,
            assets: assets, analyses: analyses, mode: .fast, model: changed)
        #expect(await changed.languageCalls == ["У рояля"])
        #expect(await changed.verified == ["У рояля"])
    }

    @Test func structuralPartNumberCannotBecomeAModelApprovedEpisodeTitle() async throws {
        var (timeline, plan, assets, analyses) = fixture(partCount: 1)
        timeline.titleItems = [.init(kind: .chapter, text: "Часть 1", startTime: 0,
                                    duration: 4, explanation: ["Editorial chapter"])]
        let model = UnrestrictedTitleFixture()
        var named = try await SmartChapterTitleEngine().applying(to: timeline, plan: plan,
            assets: assets, analyses: analyses, mode: .fast, model: model)
        #expect(named.chapterTitleDecisions?.first?.text == "У рояля")
        #expect(await model.namesCalls == 1)
        #expect(await model.languageCalls == ["У рояля"])
        #expect(await model.verified == ["У рояля"])
        // A legacy positive model verdict cannot certify a numbered fallback.
        named.titleItems?[0].text = "Часть 1"
        named.chapterTitleDecisions?[0].text = "Часть 1"
        named.chapterTitleDecisions?[0].languageReceipts = [.init(text: "Часть 1", modelID: model.identity,
            rulesVersion: ChapterTitleLanguagePolicy.version,
            assessment: .init(issue: .none, reason: "Injected false approval", verdict: .natural))]
        let report = AutomaticFilmDelivery.verifiedReport(for: named, plan: plan, assets: assets, analyses: analyses)
        #expect(report.requirements?.first { $0.rule == "chapterTitleMeaningAndLanguage" }?.passed == false)
        #expect(SmartTitleEngine.isPlaceholderTitle("Part 17"))
        #expect(!SmartTitleEngine.isPlaceholderTitle("Часть пути"))
    }
}

struct ChapterTitleLanguageContractTests {
    @Test func languageRequestIsBlindToVisualFactsAndUsesExactlyTheSelectedModel() async throws {
        var model = LocalChapterTitleModel(model: "qwen3-vl:4b-instruct", mode: .balanced)
        model.answerTransport = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            #expect(body["model"] as? String == "qwen3-vl:4b-instruct")
            let messages = body["messages"] as! [[String: Any]]
            let payload = messages[1]["content"] as! String
            #expect(payload.contains("Приготовление ужина"))
            #expect(!payload.contains("evidence") && !payload.contains("confidence") && !payload.contains("facts"))
            #expect(messages.allSatisfy { $0["images"] == nil })
            let bytes = try JSONSerialization.data(withJSONObject: ["model": body["model"]!, "done": true,
                "done_reason": "stop", "message": ["content": #"{"issue":"none","reason":"Обычное название занятия","verdict":"natural"}"#]])
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let answer = try await model.reviewLanguage("Приготовление ужина", maxCharacters: 48)
        #expect(answer.accepted)
    }

    @Test func contradictoryOrUncertainLanguageVerdictsAreNotSuccessful() {
        #expect(!ChapterTitleLanguageAssessment(issue: .grammar, reason: "Wrong form", verdict: .natural).accepted)
        #expect(!ChapterTitleLanguageAssessment(issue: .none, reason: "", verdict: .natural).accepted)
        #expect(!ChapterTitleLanguageAssessment(issue: .none, reason: "Unsure", verdict: .uncertain).accepted)
        let receipt = ChapterTitleLanguageReceipt(text: "У рояля", modelID: "weights-a", rulesVersion: 1,
            assessment: .init(issue: .none, reason: "Fixture", verdict: .natural))
        #expect(!receipt.approves("На сцене", modelID: "weights-a"))
        #expect(!receipt.approves("У рояля", modelID: "weights-b"))
    }
}
