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
    #expect(profile.ollamaModelID == "qwen3-vl:2b-instruct")
    #expect(profile.maximumVLMScenes == 2)
}

@Test func maximumDoesNotSelectThirtyBillionParametersOnBaseMemory() {
    let baseMemory = AIAnalysisProfile.resolve(mode: .maximum, physicalMemory: 16 * 1_073_741_824, thermalState: .nominal)
    let largeMemory = AIAnalysisProfile.resolve(mode: .maximum, physicalMemory: 32 * 1_073_741_824, thermalState: .nominal)
    #expect(baseMemory.ollamaModelID == "qwen3-vl:8b-instruct")
    #expect(baseMemory.quantization == .q4)
    #expect(largeMemory.ollamaModelID == "qwen3-vl:30b-a3b-instruct")
}

@Test func friendlyModesUseExplicitInstructVisionModels() {
    let expected: [AIPowerMode: String] = [
        .fast: "qwen3-vl:2b-instruct",
        .balanced: "qwen3-vl:4b-instruct",
        .quality: "qwen3-vl:8b-instruct",
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

@Test func manualModelUsesItsInstalledQuantization() {
    let advanced = AdvancedAISettings(enabled: true, runtime: .ollama, modelID: "my-local-vlm", quantization: .q8)
    let profile = AIAnalysisProfile.resolve(mode: .fast, advanced: advanced, physicalMemory: 16 * 1_073_741_824, thermalState: .nominal)
    #expect(profile.modelID == "my-local-vlm")
    #expect(profile.quantization == .modelProvided)
    #expect(profile.mode == .fast)
}
