import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import VeloEditCore

private func p2Embedding(_ values: [Float], confidence: Double = 0.92) -> VisualEmbedding {
    VisualEmbedding(modelIdentifier: "fixture", values: values, confidence: confidence)
}

private func p2Candidate(
    assetID: UUID,
    start: Double = 1,
    duration: Double = 6,
    tags: Set<String> = ["action", "outdoor"],
    embedding: VisualEmbedding? = nil,
    tracking: SubjectTrackingSummary? = nil,
    speech: SpeechEditingEvidence? = nil,
    events: [AudioEventObservation]? = nil,
    boundary: MomentBoundary? = nil,
    quality: Double = 0.8
) -> Candidate {
    Candidate(
        assetID: assetID,
        sourceStart: start,
        sourceDuration: duration,
        scores: ClipScores(quality: quality, interest: 0.82, action: 0.72, stability: 0.8, uniqueness: 0.82),
        tags: tags,
        insights: CandidateInsights(
            sceneSummary: tags.sorted().joined(separator: " "),
            dynamics: 0.72,
            visualAppeal: 0.82,
            composition: 0.78,
            sharpness: quality,
            exposureQuality: 0.82,
            originalAudioUsefulness: events?.isEmpty == false ? 0.88 : 0.35,
            storyValue: 0.82,
            roleScores: [.intro: 0.72, .climax: 0.92, .outro: 0.68],
            visualEmbedding: embedding,
            subjectTracking: tracking,
            speech: speech,
            audioEvents: events,
            audioQuality: 0.82
        ),
        momentBoundary: boundary
    )
}

@Test func localVisualEmbeddingSeparatesDifferentEventsWithTheSameSamplingContract() async throws {
    let bright = EmbeddingFrameDescriptor(
        timestamp: 1,
        histogram: [0, 0, 0, 0, 0, 0, 0, 0.1, 0.2, 0.3, 0.4, 0, 0, 0, 0, 0],
        luminanceFingerprint: (0..<576).map { UInt8(150 + $0 % 70) },
        labels: ["mountain", "bicycle"]
    )
    let dark = EmbeddingFrameDescriptor(
        timestamp: 1,
        histogram: [0.55, 0.30, 0.15] + Array(repeating: 0, count: 13),
        luminanceFingerprint: (0..<576).map { UInt8(($0 * 7) % 42) },
        labels: ["concert", "crowd"]
    )
    let model = LocalVisualEmbeddingModel()
    let first = try await model.embedding(for: EmbeddingInput(frames: [bright], semanticTokens: ["ride"]))
    let same = try await model.embedding(for: EmbeddingInput(frames: [bright], semanticTokens: ["ride"]))
    let different = try await model.embedding(for: EmbeddingInput(frames: [dark], semanticTokens: ["music"]))

    #expect(first.values.count == 64)
    #expect(first.cosineSimilarity(to: same) > 0.999)
    #expect(first.cosineSimilarity(to: different) < 0.80)
}

@Test func semanticIndexFindsNearDuplicatesAndChoosesTheTechnicallyBetterTake() {
    let firstAsset = UUID()
    let secondAsset = UUID()
    let thirdAsset = UUID()
    let vector = [Float(1)] + Array(repeating: Float(0), count: 63)
    var weak = p2Candidate(assetID: firstAsset, embedding: p2Embedding(vector), quality: 0.48)
    weak.scores.stability = 0.42
    let strong = p2Candidate(assetID: secondAsset, embedding: p2Embedding([0.995, 0.005] + Array(repeating: 0, count: 62)), quality: 0.94)
    let different = p2Candidate(assetID: thirdAsset, embedding: p2Embedding([0, 1] + Array(repeating: 0, count: 62)), quality: 0.92)
    let clusters = SemanticSceneIndex(candidates: [weak, strong, different]).clusters(threshold: 0.88)

    #expect(clusters.count == 1)
    #expect(clusters[0].candidateIDs.contains(weak.id))
    #expect(clusters[0].candidateIDs.contains(strong.id))
    #expect(clusters[0].bestCandidateID == strong.id)
    #expect(!clusters[0].candidateIDs.contains(different.id))
}

@Test func activityCompatibilityContractIsFamilyBasedAndConservative() {
    let compatibleAliases: [(Set<String>, Set<String>)] = [
        (["cycling"], ["bicycle"]),
        (["buggy"], ["utv"]),
        (["rafting"], ["kayak"]),
        (["hiking"], ["trekking"]),
        (["running"], ["jogging"]),
        (["swimming"], ["плавание"]),
        (["skiing"], ["snowboard"]),
        (["surfing"], ["surfer"]),
        (["climbing"], ["bouldering"]),
        (["horseback"], ["equestrian"])
    ]
    for (first, second) in compatibleAliases {
        let lhs = ActivityCompatibilityContract.evidence(in: first)
        let rhs = ActivityCompatibilityContract.evidence(in: second)
        #expect(lhs.compatibility(with: rhs) == .compatible)
    }

    let incompatibleFamilies: [(Set<String>, Set<String>)] = [
        (["cycling"], ["buggy"]),
        (["fishing"], ["rafting"]),
        (["hiking"], ["running"]),
        (["swimming"], ["skiing"]),
        (["surfing"], ["climbing"]),
        (["equestrian"], ["cycling"])
    ]
    for (first, second) in incompatibleFamilies {
        let lhs = ActivityCompatibilityContract.evidence(in: first)
        let rhs = ActivityCompatibilityContract.evidence(in: second)
        #expect(lhs.compatibility(with: rhs) == .incompatible)
    }

    // These words are intentionally unsupported: treating them as generic is
    // safer than inventing a family from one ambiguous object or fitness label.
    let deliberatelyInsufficient = [
        "walking", "skating", "skateboard", "diving",
        "sailing", "boating", "dancing", "fitness"
    ]
    for token in deliberatelyInsufficient {
        #expect(ActivityCompatibilityContract.evidence(in: [token]).family == nil)
        let first = p2Candidate(assetID: UUID(), tags: [token])
        let second = p2Candidate(assetID: UUID(), tags: [token])
        #expect(SemanticSceneIndex(candidates: [first, second]).clusters(threshold: 0.88).isEmpty)
    }

    let cyclingWithStrayCar = ActivityCompatibilityContract.evidence(
        in: ["cycling", "cyclist", "bicycle", "car"]
    )
    #expect(cyclingWithStrayCar.family == .cycling)
    #expect(cyclingWithStrayCar.compatibility(
        with: ActivityCompatibilityContract.evidence(in: ["mountain_bike", "mtb"])
    ) == .compatible)
    let contradictoryLabels = ActivityCompatibilityContract.evidence(in: ["buggy", "bicycle"])
    #expect(contradictoryLabels.family == nil)
    #expect(contradictoryLabels.isAmbiguous)
    let identicalEmbedding = p2Embedding([1] + Array(repeating: 0, count: 63))
    let ambiguousTake = p2Candidate(
        assetID: UUID(),
        tags: ["buggy", "bicycle", "outdoor"],
        embedding: identicalEmbedding
    )
    let cyclingTake = p2Candidate(
        assetID: UUID(),
        tags: ["cycling", "bicycle", "outdoor"],
        embedding: identicalEmbedding
    )
    #expect(SemanticSceneIndex(candidates: [ambiguousTake, cyclingTake]).clusters(threshold: 0.88).isEmpty)
}

@Test func crossAssetNearDuplicatesRequireSemanticCorroborationAndRepairLegacyClusters() throws {
    let vector = [Float(1)] + Array(repeating: Float(0), count: 63)
    var cycling = p2Candidate(
        assetID: UUID(),
        tags: ["outdoor", "cycling", "cyclist", "bicycle"],
        embedding: p2Embedding(vector)
    )
    var buggy = p2Candidate(
        assetID: UUID(),
        tags: ["outdoor", "buggy", "vehicle", "helmet", "tire"],
        embedding: p2Embedding(vector)
    )
    cycling.scores.uniqueness = 0.10
    buggy.scores.uniqueness = 0.10
    cycling.insights?.semanticEventID = "legacy-outdoor-cluster"
    buggy.insights?.semanticEventID = "legacy-outdoor-cluster"
    cycling.explanation.append("Near-duplicate события; более сильный дубль доступен AI Director")
    buggy.explanation.append("Embedding index: near-duplicate события в другом ролике; выбран более сильный дубль.")

    #expect(SemanticSceneIndex(candidates: [cycling, buggy]).clusters(threshold: 0.88).isEmpty)

    let refined = CrossVideoRelationshipAnalyzer().refine([
        AnalysisResult(assetID: cycling.assetID, analyzedContentHash: "cycling", candidates: [cycling]),
        AnalysisResult(assetID: buggy.assetID, analyzedContentHash: "buggy", candidates: [buggy])
    ]).flatMap(\.candidates)
    #expect(refined.allSatisfy { $0.insights?.semanticEventID == nil })
    #expect(refined.allSatisfy { $0.scores.uniqueness > 0.50 })
    #expect(refined.allSatisfy { candidate in
        candidate.explanation.allSatisfy { !$0.lowercased().contains("near-duplicate") }
    })
}

@Test func genericContextCannotTransitivelyBridgeDifferentActivityFamilies() {
    let embedding = p2Embedding([1] + Array(repeating: 0, count: 63))
    let familyPairs: [(Set<String>, Set<String>)] = [
        (["cycling"], ["buggy"]),
        (["fishing"], ["rafting"]),
        (["hiking"], ["running"]),
        (["swimming"], ["skiing"]),
        (["surfing"], ["climbing"])
    ]
    for (leftActivity, rightActivity) in familyPairs {
        let left = p2Candidate(
            assetID: UUID(),
            tags: leftActivity.union(["red_jacket", "marker_left"]),
            embedding: embedding
        )
        let contextBridge = p2Candidate(
            assetID: UUID(),
            tags: ["outdoor", "red_jacket", "marker_left", "yellow_flag", "marker_right"],
            embedding: embedding
        )
        let right = p2Candidate(
            assetID: UUID(),
            tags: rightActivity.union(["yellow_flag", "marker_right"]),
            embedding: embedding
        )
        let permutations = [
            [left, contextBridge, right], [left, right, contextBridge],
            [contextBridge, left, right], [contextBridge, right, left],
            [right, left, contextBridge], [right, contextBridge, left]
        ]
        for candidates in permutations {
            let clusters = SemanticSceneIndex(candidates: candidates).clusters(threshold: 0.88)
            #expect(!clusters.contains { cluster in
                cluster.candidateIDs.contains(left.id) && cluster.candidateIDs.contains(right.id)
            })
        }
    }
}

@Test func validCrossCameraSameTakeClustersAcrossActivityAliasesAndPreservesLegacyID() throws {
    let embedding = p2Embedding([1] + Array(repeating: 0, count: 63))
    var first = p2Candidate(
        assetID: UUID(),
        tags: ["cycling", "rider", "red_jacket", "forest_marker"],
        embedding: embedding,
        quality: 0.94
    )
    var second = p2Candidate(
        assetID: UUID(),
        tags: ["bicycle", "cyclist", "red_jacket", "forest_marker"],
        embedding: embedding,
        quality: 0.72
    )
    first.insights?.semanticEventID = "legacy-valid-same-take"
    second.insights?.semanticEventID = "legacy-valid-same-take"

    let cluster = try #require(SemanticSceneIndex(candidates: [first, second]).clusters(threshold: 0.88).first)
    #expect(Set(cluster.candidateIDs) == Set([first.id, second.id]))

    let refined = CrossVideoRelationshipAnalyzer().refine([
        AnalysisResult(assetID: first.assetID, analyzedContentHash: "same-take-a", candidates: [first]),
        AnalysisResult(assetID: second.assetID, analyzedContentHash: "same-take-b", candidates: [second])
    ]).flatMap(\.candidates)
    #expect(refined.count == 2)
    #expect(refined.allSatisfy { $0.insights?.semanticEventID == "legacy-valid-same-take" })
}

@Test func crossVideoRefinementPreservesValidSameAssetSemanticGroup() {
    let localAssetID = UUID()
    let otherAssetID = UUID()
    let localEmbedding = p2Embedding([1] + Array(repeating: 0, count: 63))
    var firstLocal = p2Candidate(assetID: localAssetID, start: 1, embedding: localEmbedding)
    var secondLocal = p2Candidate(assetID: localAssetID, start: 8, embedding: localEmbedding)
    let unrelated = p2Candidate(
        assetID: otherAssetID,
        tags: ["buggy", "helmet"],
        embedding: p2Embedding([0, 1] + Array(repeating: 0, count: 62))
    )
    firstLocal.insights?.semanticEventID = "local-take"
    secondLocal.insights?.semanticEventID = "local-take"

    let refined = CrossVideoRelationshipAnalyzer().refine([
        AnalysisResult(assetID: localAssetID, analyzedContentHash: "local", candidates: [firstLocal, secondLocal]),
        AnalysisResult(assetID: otherAssetID, analyzedContentHash: "other", candidates: [unrelated])
    ])
    let local = refined.first(where: { $0.assetID == localAssetID })?.candidates ?? []

    #expect(local.count == 2)
    #expect(local.allSatisfy { $0.insights?.semanticEventID == "local-take" })
}

@Test func crossVideoEmbeddingClusterBecomesOneStoryEventAndDiscardsTheWeakerTake() throws {
    let firstAsset = UUID()
    let secondAsset = UUID()
    let embedding = p2Embedding([1] + Array(repeating: 0, count: 63))
    let strong = p2Candidate(assetID: firstAsset, embedding: embedding, quality: 0.94)
    let weak = p2Candidate(assetID: secondAsset, embedding: embedding, quality: 0.46)
    let diagnostics = DeepMediaDiagnostics(embeddedCandidateCount: 1)
    let refined = CrossVideoRelationshipAnalyzer().refine([
        AnalysisResult(assetID: firstAsset, analyzedContentHash: "one", candidates: [strong], deepMediaDiagnostics: diagnostics),
        AnalysisResult(assetID: secondAsset, analyzedContentHash: "two", candidates: [weak], deepMediaDiagnostics: diagnostics)
    ])
    let values = refined.flatMap(\.candidates)
    let discardedIDs = refined.flatMap { $0.deepMediaDiagnostics?.discardedCandidateIDs ?? [] }
    let selectedStrong = try #require(values.first(where: { $0.id == strong.id }))
    let rejectedWeak = try #require(values.first(where: { $0.id == weak.id }))

    #expect(selectedStrong.insights?.semanticEventID == rejectedWeak.insights?.semanticEventID)
    #expect(rejectedWeak.scores.uniqueness <= 0.24)
    #expect(discardedIDs.contains(weak.id))
}

@Test func subjectTrackingSelectsThePersistentCyclistAndReframeLeavesMotionLeadRoom() throws {
    let frames = (0..<5).map { index in
        SubjectFrameDescriptor(timestamp: Double(index), observations: [
            FrameSubjectObservation(
                kind: .cyclist,
                label: "cyclist",
                region: NormalizedRegion(x: 0.18 + Double(index) * 0.09, y: 0.30, width: 0.18, height: 0.34),
                confidence: 0.94
            ),
            FrameSubjectObservation(
                kind: .salientObject,
                label: "background",
                region: NormalizedRegion(x: 0.76, y: 0.12, width: 0.08, height: 0.10),
                confidence: 0.42
            )
        ])
    }
    let tracking = LocalSubjectTracker().track(frames: frames)
    let plan = try #require(SubjectAwareReframeEngine().plan(
        tracking: tracking,
        sourceAspectRatio: 16.0 / 9.0,
        targetAspectRatio: 9.0 / 16.0
    ))

    #expect(tracking.mainSubject?.kind == .cyclist)
    #expect((tracking.mainSubject?.movementX ?? 0) > 0.25)
    #expect(plan.endCenterX > plan.startCenterX)
    #expect(plan.startCenterX > frames[0].observations[0].region.centerX)
    #expect(plan.targetAspectRatio == 9.0 / 16.0)
    #expect(plan.reasons.contains(where: { $0.contains("движения") }))
}

@Test func matchingAspectVideoDoesNotReceiveAnUnnecessaryDigitalReframe() {
    let tracking = LocalSubjectTracker().track(frames: (0..<4).map { index in
        SubjectFrameDescriptor(timestamp: Double(index), observations: [
            FrameSubjectObservation(
                kind: .person,
                label: "person",
                region: NormalizedRegion(x: 0.12 + Double(index) * 0.04, y: 0.24, width: 0.16, height: 0.32),
                confidence: 0.95
            )
        ])
    })

    let plan = SubjectAwareReframeEngine().plan(
        tracking: tracking,
        sourceAspectRatio: 16.0 / 9.0,
        targetAspectRatio: 16.0 / 9.0
    )

    #expect(plan == nil)
}

@Test func productionDirectorCommitsSubjectReframeAndFCPXMLPreservesTheIntent() throws {
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/p2-reframe.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "p2-reframe",
        metadata: MediaMetadata(duration: 12, width: 1920, height: 1080, frameRate: 60)
    )
    let tracking = LocalSubjectTracker().track(frames: (0..<5).map { index in
        SubjectFrameDescriptor(timestamp: Double(index), observations: [
            FrameSubjectObservation(kind: .cyclist, label: "cyclist", region: NormalizedRegion(x: 0.18 + Double(index) * 0.08, y: 0.28, width: 0.2, height: 0.38), confidence: 0.95)
        ])
    })
    let boundary = MomentBoundary(anticipationStart: 1, peakTime: 4, completionEnd: 7, confidence: 0.9)
    let candidate = p2Candidate(assetID: asset.id, start: 1, duration: 6, tracking: tracking, boundary: boundary)
    let plan = StoryPlan(prompt: "Вертикальный экшен", preset: .adventure, constraints: StoryConstraints(targetDuration: 6, targetClipCount: 1), chapters: [
        StoryChapter(title: "Кульминация", candidateIDs: [candidate.id], role: .climax)
    ])
    let initial = Timeline(
        storyPlanID: plan.id,
        width: 1080,
        height: 1920,
        items: [TimelineItem(candidateID: candidate.id, assetID: asset.id, kind: .video, sourceStart: 1, sourceDuration: 6, timelineStart: 0, timelineDuration: 6, storyRole: .climax)]
    )
    let analysis = AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [candidate])
    let directed = AIDirectorEngine().direct(plan: plan, initialTimeline: initial, assets: [asset], analyses: [analysis])
    let reframe = try #require(directed.items.first?.effectiveVideoAdjustments.subjectReframe)
    let xml = try FCPXMLExporter().xml(timeline: directed, assets: [asset])

    #expect(reframe.targetAspectRatio == 9.0 / 16.0)
    #expect(AdjustedClipGenerator.needsRender(directed.items[0].effectiveVideoAdjustments))
    #expect(xml.contains("com.veloedit.subjectReframe"))
    #expect(xml.contains("adjust-transform"))
}

private struct FixtureSpeechRecognizer: LocalSpeechRecognizing {
    let modelIdentifier = "fixture-asr"
    func transcribe(url: URL, localeIdentifier: String?) async throws -> SpeechTranscript? {
        let words = [
            TranscriptWord(text: "Смотри", startTime: 1.5, duration: 0.6, confidence: 0.94),
            TranscriptWord(text: "прыжок!", startTime: 2.2, duration: 1.1, confidence: 0.96),
            TranscriptWord(text: "Получилось.", startTime: 4.5, duration: 1.5, confidence: 0.91)
        ]
        return SpeechTranscript(
            localeIdentifier: "ru-RU",
            words: words,
            sentences: [
                TranscriptSentence(text: "Смотри прыжок!", startTime: 1.5, endTime: 3.3, confidence: 0.95),
                TranscriptSentence(text: "Получилось.", startTime: 4.5, endTime: 6.0, confidence: 0.91)
            ],
            silenceBoundaries: [0...1.5, 3.3...4.5, 6.0...6.8],
            confidence: 0.93
        )
    }
}

@Test func productionEnricherUsesASRAudioTelemetryAndVisualEvidenceForBoundaries() async throws {
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/p2-asr-fixture.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "p2-asr-fixture",
        metadata: MediaMetadata(duration: 9, width: 1920, height: 1080, frameRate: 60, hasAudio: true)
    )
    let original = p2Candidate(assetID: asset.id, start: 2, duration: 3.2, boundary: MomentBoundary(anticipationStart: 2, peakTime: 3.4, completionEnd: 5.2, confidence: 0.55))
    let samples = (1...7).map { second in
        let isPeak = second == 3
        return VisualFrameSample(
            timestamp: Double(second),
            motion: isPeak ? 0.92 : (second == 2 || second == 4 ? 0.52 : 0.12),
            exposure: 0.82,
            detail: 0.84,
            labels: ["cyclist", "jump"],
            labelConfidence: 0.9,
            faceCount: 0,
            jpegBase64: "",
            histogram: [0.1, 0.3, 0.4, 0.2] + Array(repeating: 0, count: 12),
            luminanceFingerprint: (0..<576).map { UInt8((second * 23 + $0) % 255) },
            subjects: [FrameSubjectObservation(kind: .cyclist, label: "cyclist", region: NormalizedRegion(x: 0.25 + Double(second) * 0.03, y: 0.3, width: 0.2, height: 0.35), confidence: 0.9)]
        )
    }
    let impact = AudioEventObservation(kind: .impact, startTime: 2.9, endTime: 3.25, confidence: 0.96, intensity: 0.94)
    let audio = AudioAnalysisSummary(
        analyzedDuration: 9,
        meanVolume: 0.18,
        peakVolume: 0.94,
        silenceRatio: 0.08,
        speechProbability: 0.92,
        onsetRate: 1.8,
        originalSoundQuality: 0.84,
        waveform: [0.1, 0.2, 0.9, 0.3, 0.2],
        onsetEnvelope: [0.1, 0.2, 1, 0.2, 0.1],
        featureWindows: [AudioFeatureWindow(startTime: 2.9, duration: 0.35, rms: 0.4, peak: 0.94, zeroCrossingRate: 0.05, onsetStrength: 0.95)],
        events: [impact]
    )
    let result = await DeepMediaCandidateEnricher(speechRecognizer: FixtureSpeechRecognizer()).enrich(
        candidates: [original],
        samples: samples,
        asset: asset,
        profile: AIAnalysisProfile.resolve(mode: .quality, thermalState: .nominal),
        audio: audio,
        telemetryMoments: [TelemetryMoment(timestamp: 3, score: 0.96, tags: ["g-force"])],
        cache: nil
    )
    let candidate = try #require(result.candidates.first)
    let boundary = try #require(candidate.momentBoundary)

    #expect(candidate.insights?.speech?.text.contains("прыжок") == true)
    #expect(candidate.sourceStart <= 1.5)
    #expect(candidate.sourceStart + candidate.sourceDuration >= 6.0)
    #expect(boundary.evidence.contains("telemetry-confirmed peak"))
    #expect(boundary.evidence.contains("audio-event-confirmed peak"))
    #expect(boundary.evidence.contains("ASR phrase boundaries preserved"))
    #expect(result.diagnostics.embeddedCandidateCount == 1)
    #expect(result.diagnostics.trackedCandidateCount == 1)
    #expect(result.diagnostics.transcribedCandidateCount == 1)
    #expect(result.diagnostics.audioEventCandidateCount == 1)
}

@Test func audioEventClassifierSeparatesSilenceImpactAndWind() {
    let events = DSPAudioEventClassifier().classify(windows: [
        AudioFeatureWindow(startTime: 0, duration: 0.2, rms: 0.004, peak: 0.008, zeroCrossingRate: 0.01, onsetStrength: 0),
        AudioFeatureWindow(startTime: 0.3, duration: 0.2, rms: 0.20, peak: 0.94, zeroCrossingRate: 0.05, onsetStrength: 0.92, spectralFlux: 0.8),
        AudioFeatureWindow(startTime: 0.6, duration: 0.2, rms: 0.10, peak: 0.18, zeroCrossingRate: 0.31, onsetStrength: 0.04, spectralFlux: 0.12)
    ], speechProbability: 0.1, musicProbability: 0.1)

    #expect(events.map(\.kind).contains(.silence))
    #expect(events.map(\.kind).contains(.impact))
    #expect(events.map(\.kind).contains(.wind))
}

@Test func measuredMusicAnalysisFindsNonFourFourMeterPhrasesAndDropConfidence() {
    let count = 121
    let onsets = (0..<count).map { index in index.isMultiple(of: 3) ? 1.0 : (index.isMultiple(of: 1) ? 0.08 : 0) }
    let energy = (0..<count).map { index -> Double in
        if index < 30 { return 0.20 }
        if index < 60 { return 0.48 }
        if index < 96 { return 0.92 }
        return 0.28
    }
    let structure = MusicSyncEngine().analyze(
        bpm: 118,
        duration: 60,
        energy: 0.7,
        energyEnvelope: energy,
        onsetEnvelope: onsets,
        measuredBPM: 120,
        tempoConfidence: 0.94
    )
    let kinds = Set(structure.accents?.map(\.kind) ?? [])

    #expect(structure.analysisIsMeasured == true)
    #expect(structure.bpm == 120)
    #expect(structure.beatsPerBar == 3)
    #expect((structure.downbeatConfidence ?? 0) > 0.45)
    #expect((structure.phraseConfidence ?? 0) > 0.45)
    #expect((structure.dropConfidence ?? 0) > 0.30)
    #expect(kinds.isSuperset(of: [.beat, .downbeat, .phrase, .drop, .transition]))
}

@Test func expandedGlobalScorerRewardsSpeechSubjectAudioAndDropClimaxEvidence() throws {
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/p2-score.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "p2-score",
        metadata: MediaMetadata(duration: 20, width: 1920, height: 1080, hasAudio: true)
    )
    let tracking = LocalSubjectTracker().track(frames: (0..<4).map { index in
        SubjectFrameDescriptor(timestamp: Double(index), observations: [
            FrameSubjectObservation(kind: .person, label: "person", region: NormalizedRegion(x: 0.25 + Double(index) * 0.04, y: 0.24, width: 0.22, height: 0.42), confidence: 0.95)
        ])
    })
    let speech = SpeechEditingEvidence(text: "Важная целая фраза", phraseStart: 2, phraseEnd: 7, confidence: 0.94, startsAtPhraseBoundary: true, endsAtPhraseBoundary: true, silenceBefore: 0.3, silenceAfter: 0.4)
    let event = AudioEventObservation(kind: .applause, startTime: 4.8, endTime: 5.4, confidence: 0.9, intensity: 0.86)
    let boundary = MomentBoundary(anticipationStart: 1, peakTime: 5, completionEnd: 8, confidence: 0.92)
    let candidate = p2Candidate(assetID: asset.id, start: 1, duration: 7, embedding: p2Embedding([1] + Array(repeating: 0, count: 63)), tracking: tracking, speech: speech, events: [event], boundary: boundary)
    let plan = StoryPlan(prompt: "История с репликой и кульминацией", preset: .story, constraints: StoryConstraints(targetDuration: 7, targetClipCount: 1), chapters: [])
    let structure = MusicStructure(
        bpm: 120,
        beatInterval: 0.5,
        sections: [MusicSection(kind: .climax, start: 0, duration: 7, energy: 0.9, confidence: 0.9)],
        drops: [3.2],
        downbeatTimestamps: [0, 2, 4, 6],
        phraseBoundaries: [0, 4, 7],
        accents: [MusicAccent(time: 3.2, strength: 1, kind: .drop, confidence: 0.94)],
        beatsPerBar: 4,
        tempoConfidence: 0.9,
        downbeatConfidence: 0.9,
        phraseConfidence: 0.9,
        sectionConfidence: 0.9,
        dropConfidence: 0.94,
        analysisIsMeasured: true
    )
    let reframe = try #require(SubjectAwareReframeEngine().plan(tracking: tracking, sourceAspectRatio: 16.0 / 9.0, targetAspectRatio: 9.0 / 16.0))
    let complete = Timeline(
        storyPlanID: plan.id,
        width: 1080,
        height: 1920,
        items: [TimelineItem(candidateID: candidate.id, assetID: asset.id, kind: .video, sourceStart: 1, sourceDuration: 7, timelineStart: 0, timelineDuration: 7, videoAdjustments: VideoAdjustments(subjectReframe: reframe), audioAdjustments: AudioAdjustments(volume: 0.9), storyRole: .climax)],
        music: MusicDirective(style: .cinematic, bpm: 120, structure: structure)
    )
    let cutOff = Timeline(
        storyPlanID: plan.id,
        width: 1080,
        height: 1920,
        items: [TimelineItem(candidateID: candidate.id, assetID: asset.id, kind: .video, sourceStart: 4.9, sourceDuration: 1.2, timelineStart: 0, timelineDuration: 1.2, audioAdjustments: AudioAdjustments(volume: 0.1), storyRole: .climax)],
        music: MusicDirective(style: .cinematic, bpm: 120, structure: structure)
    )
    let analysis = AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [candidate])
    let scorer = DefaultMontageGlobalScorer()
    let good = scorer.score(plan: plan, timeline: complete, assets: [asset], analyses: [analysis])
    let poor = scorer.score(plan: plan, timeline: cutOff, assets: [asset], analyses: [analysis])

    #expect(good.subjectComposition > poor.subjectComposition)
    #expect(good.speechContinuity > poor.speechContinuity)
    #expect(good.audioEventCoherence > poor.audioEventCoherence)
    #expect(good.dropClimaxAlignment > poor.dropClimaxAlignment)
    #expect(good.total > poor.total)
}

@Test func persistentDeepCacheRoundTripsAllExpensiveFeatures() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = DeepAnalysisCache(rootURL: root)
    let embedding = p2Embedding([1] + Array(repeating: 0, count: 63))
    let audio = AudioAnalysisSummary(analyzedDuration: 3, meanVolume: 0.2, peakVolume: 0.8, silenceRatio: 0.1, speechProbability: 0.7, originalSoundQuality: 0.8, waveform: [0.1, 0.8])
    let transcript = try #require(await FixtureSpeechRecognizer().transcribe(url: URL(fileURLWithPath: "/tmp/unused"), localeIdentifier: nil))
    let evidence = CachedCandidateDeepEvidence(sourceStart: 1, sourceDuration: 3, embedding: embedding)
    try await cache.store(DeepMediaCacheRecord(
        contentHash: "cache-fixture",
        candidates: [evidence.stableKey: evidence],
        transcript: transcript,
        audioEvents: [AudioEventObservation(kind: .speech, startTime: 1, endTime: 3, confidence: 0.8, intensity: 0.6)],
        audioAnalysis: audio
    ))
    await cache.removeMemoryEntries()
    let restored = try #require(await cache.load(contentHash: "cache-fixture"))

    #expect(restored.candidates[evidence.stableKey]?.embedding == embedding)
    #expect(restored.transcript == transcript)
    #expect(restored.audioEvents.first?.kind == .speech)
    #expect(restored.audioAnalysis == audio)
}

@Test func preP2GlobalScoreDecodesWithNeutralNewComponents() throws {
    let json = """
    {"total":0.72,"highlightQuality":0.8,"storyArc":0.7,"diversity":0.6,"durationFit":0.9,"musicalAlignment":0.7,"reviewQuality":0.8,"semanticDiversity":0.65,"sourceDiversity":0.75,"momentCompleteness":0.7,"energyCurve":0.6,"audioContinuity":0.7,"dropClimaxAlignment":0.5,"continuity":0.6,"rhythmQuality":0.8,"technicalQuality":0.9}
    """
    let score = try JSONDecoder().decode(MontageGlobalScore.self, from: Data(json.utf8))

    #expect(score.total == 0.72)
    #expect(score.subjectComposition == 0.5)
    #expect(score.speechContinuity == 0.5)
    #expect(score.audioEventCoherence == 0.5)
    #expect(score.visualSemanticQuality == 0.5)
    #expect(score.musicStructureQuality == 0.5)
}

@Test func semanticIndexStaysBoundedForThreeHundredCameraFiles() {
    let started = ContinuousClock.now
    let candidates = (0..<(300 * 8)).map { index -> Candidate in
        let assetIndex = index / 8
        let vector = [Float(1), Float(assetIndex % 3) * 0.001] + Array(repeating: 0, count: 62)
        return p2Candidate(assetID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", assetIndex)) ?? UUID(), start: Double(index % 8) * 8, embedding: p2Embedding(vector))
    }
    let clusters = SemanticSceneIndex(candidates: candidates).clusters(threshold: 0.88)
    let elapsed = started.duration(to: .now)

    #expect(!clusters.isEmpty)
    #expect(elapsed < .seconds(5))
}

private func writeP2PhotoFixture(to url: URL) throws {
    let width = 640
    let height = 360
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    context.setFillColor(CGColor(red: 0.08, green: 0.22, blue: 0.48, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.96, green: 0.68, blue: 0.12, alpha: 1))
    context.fillEllipse(in: CGRect(x: 190, y: 105, width: 210, height: 160))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

@Test func productionPhotoPathPreservesAShortFilmAndReportsUnmetDuration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
    let photoURL = root.deletingLastPathComponent().appendingPathComponent("p2-fixture-\(UUID().uuidString).jpg")
    defer { try? FileManager.default.removeItem(at: photoURL) }
    try writeP2PhotoFixture(to: photoURL)
    let store = try ProjectStore(createAt: root, name: "P2 production fixture")
    let asset = MediaAsset(
        originalURL: photoURL,
        kind: .photo,
        byteSize: Int64((try? photoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1),
        contentHash: "p2-photo-\(UUID().uuidString)",
        metadata: MediaMetadata(width: 640, height: 360)
    )
    try await store.update { $0.assets = [asset] }
    try await store.update { $0.editorialDevelopmentEnabled = true }
    let pipeline = VeloEditPipeline(store: store)

    #expect(try await pipeline.analyzeMissing() == 1)
    let analyzed = await pipeline.snapshot()
    let result = try #require(analyzed.analyses.first)
    #expect(result.deepMediaVersion == DeepAnalysisCache.version)
    #expect(result.directorCandidates.first?.insights?.visualEmbedding?.values.count == 64)
    #expect(result.deepMediaDiagnostics?.embeddedCandidateCount == 1)

    // Delivery retains the available film; verification must still expose
    // insufficient content rather than inventing padding or claiming success.
    let film = try await pipeline.createFilm(prompt: "Фильм ровно 60 секунд. Без музыки. Один выразительный кадр. Добавь титры.", preset: .memories, targetDuration: 60)
    #expect(film.duration > 0 && film.duration < 10)
    #expect(film.items.filter { $0.kind == .photo && $0.overlay == nil }.count == 1)
    #expect(film.filmDeliveryReport?.status == .savedWithUnmetRequirements)
    #expect(film.filmDeliveryReport?.requirements?.contains { $0.rule == "duration" && !$0.passed } == true)
    let committed = await pipeline.snapshot()
    #expect(committed.timelines.last?.id == film.id)
    let generation = committed.intentLedger?.entries.last { $0.normalizedIntent == .createFilm }
    #expect(generation?.status == .fulfilled)
    #expect(committed.analyses.first?.deepMediaVersion == DeepAnalysisCache.version)
}
