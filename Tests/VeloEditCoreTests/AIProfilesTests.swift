import Foundation
import Testing
@testable import VeloEditCore

@Test func bundledFastModeIsTheEffectiveDefault() {
    let preferences = UserPreferences()
    #expect(preferences.effectiveAIPowerMode == .fast)
    let profile = AIAnalysisProfile.resolve(mode: preferences.effectiveAIPowerMode, physicalMemory: 16 * 1_073_741_824, thermalState: .nominal)
    #expect(profile.targetDepth == .quick)
    #expect(profile.proxyPolicy == .avoidFullEncode)
    #expect(profile.audioAnalysisLevel == .none)
}

@Test func maximumDoesNotSelectThirtyBillionParametersOnBaseMemory() {
    let baseMemory = AIAnalysisProfile.resolve(mode: .maximum, physicalMemory: 16 * 1_073_741_824, thermalState: .nominal)
    let largeMemory = AIAnalysisProfile.resolve(mode: .maximum, physicalMemory: 32 * 1_073_741_824, thermalState: .nominal)
    #expect(baseMemory.ollamaModelID == "qwen3-vl:8b")
    #expect(baseMemory.quantization == .q8)
    #expect(largeMemory.ollamaModelID == "qwen3-vl:30b")
}

@Test func thermalPressureReducesSamplingWithoutInvalidatingCacheIdentity() {
    let cool = AIAnalysisProfile.resolve(mode: .quality, physicalMemory: 24 * 1_073_741_824, thermalState: .nominal)
    let hot = AIAnalysisProfile.resolve(mode: .quality, physicalMemory: 24 * 1_073_741_824, thermalState: .critical)
    #expect(hot.maximumCoarseFrames < cool.maximumCoarseFrames)
    #expect(hot.framesPerCandidate < cool.framesPerCandidate)
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

@Test func manualModelAndQuantizationOverrideTheFriendlyMode() {
    let advanced = AdvancedAISettings(enabled: true, runtime: .ollama, modelID: "my-local-vlm", quantization: .q8)
    let profile = AIAnalysisProfile.resolve(mode: .fast, advanced: advanced, physicalMemory: 16 * 1_073_741_824, thermalState: .nominal)
    #expect(profile.modelID == "my-local-vlm")
    #expect(profile.quantization == .q8)
    #expect(profile.mode == .fast)
}
