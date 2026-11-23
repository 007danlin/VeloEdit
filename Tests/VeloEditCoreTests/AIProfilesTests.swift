import Foundation
import Testing
@testable import VeloEditCore

@Test func fastInstructModeIsTheEffectiveDefault() {
    let preferences = UserPreferences()
    #expect(preferences.effectiveAIPowerMode == .fast)
    let profile = AIAnalysisProfile.resolve(mode: preferences.effectiveAIPowerMode, physicalMemory: 16 * 1_073_741_824, thermalState: .nominal)
    #expect(profile.targetDepth == .quick)
    #expect(profile.proxyPolicy == .avoidFullEncode)
    #expect(profile.audioAnalysisLevel == .none)
    #expect(profile.ollamaModelID == "qwen3.5:2b-q4_K_M")
    #expect(profile.maximumVLMScenes == 2)
}

@Test func retiredModeIsAvailableOnlyToPreviouslyStartedJobs() throws {
    #expect(AIPowerMode.allCases == [.fast, .balanced, .quality])
    var preferences = UserPreferences()
    preferences.aiPowerMode = .maximum
    let restored = try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(preferences))
    #expect(restored.effectiveAIPowerMode == .quality)
    let job = FilmProcessProfile(analysis: .resolve(mode: .maximum))
    let saved = try JSONDecoder().decode(FilmProcessProfile.self, from: JSONEncoder().encode(job))
    #expect(saved == job)
}

@Test func maximumKeepsItsModelAndReportsUnsupportedMemory() {
    let baseMemory = AIAnalysisProfile.resolve(mode: .maximum, physicalMemory: 16 * 1_073_741_824, thermalState: .nominal)
    let largeMemory = AIAnalysisProfile.resolve(mode: .maximum, physicalMemory: 32 * 1_073_741_824, thermalState: .nominal)
    #expect(baseMemory.ollamaModelID == "qwen3-vl:30b-a3b-instruct")
    #expect(throws: FilmProcessProfileError.self) { try FilmProcessProfile(analysis: baseMemory).validateDevice(physicalMemory: 16 * 1_073_741_824) }
    #expect(baseMemory.quantization == .q4)
    #expect(largeMemory.ollamaModelID == "qwen3-vl:30b-a3b-instruct")
}

@Test func friendlyModesUseExplicitInstructVisionModels() {
    let expected: [AIPowerMode: String] = [
        .fast: "qwen3.5:2b-q4_K_M",
        .balanced: "qwen3.5:4b-q4_K_M",
        .quality: "qwen3.5:9b-q4_K_M",
        .maximum: "qwen3-vl:30b-a3b-instruct"
    ]
    for (mode, modelID) in expected {
        let profile = AIAnalysisProfile.resolve(mode: mode, physicalMemory: 32 * 1_073_741_824, thermalState: .nominal)
        #expect(profile.ollamaModelID == modelID)
        #expect(!profile.thinkingEnabled)
    }
}

@Test func thermalPressurePreservesSamplingAndLimitsConcurrency() {
    let cool = AIAnalysisProfile.resolve(mode: .quality, physicalMemory: 24 * 1_073_741_824, thermalState: .nominal)
    let hot = AIAnalysisProfile.resolve(mode: .quality, physicalMemory: 24 * 1_073_741_824, thermalState: .critical)
    #expect(hot.maximumCoarseFrames == cool.maximumCoarseFrames)
    #expect(hot.framesPerCandidate == cool.framesPerCandidate)
    #expect(hot.aiConcurrency == 1)
    #expect(hot.cacheKey == cool.cacheKey)
}

@Test func adaptivePlanIsSparseThenAddsDenseCandidateFrames() {
    let profile = AIAnalysisProfile.resolve(mode: .balanced, physicalMemory: 16 * 1_073_741_824, thermalState: .nominal)
    let plan = AdaptiveSamplingPlan(duration: 120, profile: profile)
    let dense = plan.denseTimestamps(around: [30, 80], duration: 120, interval: profile.denseInterval, framesPerCandidate: profile.framesPerCandidate)
    #expect(plan.coarseTimestamps.count < 120)
    #expect(dense.count > plan.coarseTimestamps.count)
    #expect(dense.allSatisfy { $0 >= 0 && $0 < 120 })
}

@Test func legacyManualModelCannotRedefineNamedMode() {
    let advanced = AdvancedAISettings(enabled: true, runtime: .ollama, modelID: "my-local-vlm", quantization: .q8)
    let profile = AIAnalysisProfile.resolve(mode: .fast, advanced: advanced, physicalMemory: 16 * 1_073_741_824, thermalState: .nominal)
    #expect(profile.modelID == "qwen3.5:2b-q4_K_M")
    #expect(profile.quantization == .modelProvided)
    #expect(profile.mode == .fast)
}

@Test func savedV1JobsKeepTheirExactVLWeights() throws {
    for (mode, oldTag) in [(AIPowerMode.fast, "qwen3-vl:2b-instruct"),
                           (.balanced, "qwen3-vl:4b-instruct"), (.quality, "qwen3-vl:8b-instruct")] {
        let current = FilmProcessProfile(analysis: .resolve(mode: mode), modelDigest: "original")
        var data = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        data["version"] = 1
        var analysis = try #require(data["analysis"] as? [String: Any])
        analysis["ollamaModelID"] = oldTag
        data["analysis"] = analysis
        let saved = try JSONDecoder().decode(FilmProcessProfile.self, from: JSONSerialization.data(withJSONObject: data))
        try saved.validateDevice()
        try saved.validate(model: oldTag, digest: "original")
        #expect(throws: FilmProcessProfileError.self) { try saved.validate(model: current.modelID) }
        #expect(throws: FilmProcessProfileError.self) { try current.validate(model: oldTag) }
    }
}

@Test func visualTitleUsesOneShortRussianLine() {
    #expect(LocalChapterTitleModel.displayTitle("«Путешествие к воде»", maximum: 30) == "Путешествие к воде")
    #expect(LocalChapterTitleModel.displayTitle(#"{"observation":"Люди на берегу","title":"Остановка у воды"}"#, maximum: 30) == "Остановка у воды")
    #expect(LocalChapterTitleModel.displayTitle(#"{"title":"Остановка у воды"}"#, maximum: 30) == nil)
    for invalid in ["", "Следующий кадр", "Название кадра", "Chapter 1", "Первый\nВторой", "Заголовок: дорога", "Раз два три четыре пять шесть"] {
        #expect(LocalChapterTitleModel.displayTitle(invalid, maximum: 48) == nil)
    }
}

@Test func visualTitleChecksClaimsBeforeShowingThem() {
    func reason(_ title: String, _ note: String, event: String? = nil) -> String? {
        let data = try! JSONEncoder().encode(["title": title, "observation": note])
        return LocalChapterTitleModel.rejectionReason(for: title, answer: String(decoding: data, as: UTF8.self),
            event: event, observations: [])
    }
    #expect(reason("Велосипедист ждёт", "На дорожке стоит велосипед") != nil)
    #expect(reason("Велосипедист ждёт", "Велосипедист рядом с мостом") == nil)
    #expect(reason("Парковка с отдыха", "Два человека отдыхают на лавочке") != nil)
    #expect(reason("Возвращение с отдыха", "Люди возвращаются домой по дороге") == nil)
    #expect(reason("Вид с берега", "С берега видны лодки") == nil)
    #expect(reason("Прогулка с другом", "Два человека идут по тропе") == nil)
    #expect(reason("Екатеринбургская дорога", "По дороге едет автомобиль") != nil)
    #expect(reason("Дорога в Москве", "По дороге едет автомобиль") != nil)
    #expect(reason("Семейный отдых", "Два человека сидят на стульях") != nil)
    #expect(reason("Солнечный берег", "Река в ясный день") == nil)
    #expect(reason("Заброшенный дом", "Позади машины бетонная стена") != nil)
    #expect(reason("Джип на трассе", "Машина на дороге", event: "Поездка на багги") != nil)
    #expect(reason("Путешествие к воде", "Дорога и остановка у реки", event: "Поездка на багги") == nil)
}
