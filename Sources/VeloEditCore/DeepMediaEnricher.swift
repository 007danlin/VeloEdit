import Foundation
import CryptoKit

struct DeepMediaEnrichmentResult: Sendable {
    var candidates: [Candidate]
    var transcript: SpeechTranscript?
    var audioEvents: [AudioEventObservation]
    var diagnostics: DeepMediaDiagnostics
}

/// Runs only after adaptive candidate detection. It reuses decoded key-frame
/// descriptors and never scans every source frame, which keeps P2 bounded for
/// large action-camera libraries.
struct DeepMediaCandidateEnricher: Sendable {
    let embeddingModel: any EmbeddingModelProtocol
    let speechRecognizer: any LocalSpeechRecognizing

    init(
        embeddingModel: any EmbeddingModelProtocol = LocalVisualEmbeddingModel(),
        speechRecognizer: any LocalSpeechRecognizing = AppleOnDeviceSpeechRecognizer()
    ) {
        self.embeddingModel = embeddingModel
        self.speechRecognizer = speechRecognizer
    }

    func enrich(
        candidates input: [Candidate],
        samples: [VisualFrameSample],
        asset: MediaAsset,
        profile: AIAnalysisProfile,
        audio: AudioAnalysisSummary?,
        telemetryMoments: [TelemetryMoment] = [],
        cache: DeepAnalysisCache?
    ) async -> DeepMediaEnrichmentResult {
        let totalStarted = Date()
        var candidates = input
        let sourceIdentity = FrameCacheKey.sourceIdentity(url: asset.originalURL, contentHash: asset.contentHash)
        let stored = await cache?.load(contentHash: asset.contentHash)
        var cacheRecord = stored?.sourceIdentity == sourceIdentity ? stored! : DeepMediaCacheRecord(contentHash: asset.contentHash)
        cacheRecord.sourceIdentity = sourceIdentity
        if let audio, cacheRecord.audioAnalysis != audio {
            cacheRecord.audioEvents = []
            cacheRecord.audioAnalysis = audio
        }
        var reports: [DeepAnalysisStageReport] = []

        let audioStarted = Date()
        let audioCacheHit = !(cacheRecord.audioEvents.isEmpty)
        var audioEvents = cacheRecord.audioEvents
        if audioEvents.isEmpty {
            audioEvents = audio?.events ?? DSPAudioEventClassifier().classify(
                windows: audio?.featureWindows ?? [],
                speechProbability: audio?.speechProbability ?? 0,
                musicProbability: audio?.musicProbability ?? 0
            )
            cacheRecord.audioEvents = audioEvents
        }
        reports.append(DeepAnalysisStageReport(
            stage: .audioEvents,
            ran: !audioEvents.isEmpty,
            cacheHit: audioCacheHit,
            itemCount: audioEvents.count,
            confidence: mean(audioEvents.map(\.confidence)),
            duration: Date().timeIntervalSince(audioStarted),
            reason: audioEvents.isEmpty ? "Аудиособытия недоступны; сохранён fallback" : "DSP-анализ звука (правила обработки сигнала, без отдельной нейросети)"
        ))

        let embeddingStarted = Date()
        var embeddingCacheHits = 0
        for index in candidates.indices {
            let key = stableKey(for: candidates[index])
            let frames = nearbySamples(for: candidates[index], samples: samples, limit: max(3, min(8, profile.framesPerCandidate)))
            let tokens = semanticTokens(candidates[index])
            let inputSignature = Self.frameEvidenceSignature(frames, context: embeddingModel.modelIdentifier + "|" + tokens.sorted().joined(separator: "|"))
            let cached = cacheRecord.candidates[key]?.embedding
            let embedding: VisualEmbedding?
            if let cached, cached.modelIdentifier == embeddingModel.modelIdentifier, !cached.values.isEmpty,
               cacheRecord.candidates[key]?.embeddingInputSignature == inputSignature {
                embedding = cached
                embeddingCacheHits += 1
            } else {
                let descriptors = frames.map {
                    EmbeddingFrameDescriptor(timestamp: $0.timestamp, histogram: $0.histogram, luminanceFingerprint: $0.luminanceFingerprint, labels: $0.labels)
                }
                embedding = try? await embeddingModel.embedding(for: EmbeddingInput(frames: descriptors, semanticTokens: tokens))
            }
            var insights = ensuredInsights(for: candidates[index])
            insights.visualEmbedding = embedding
            candidates[index].insights = insights
            var cachedEvidence = cacheRecord.candidates[key] ?? CachedCandidateDeepEvidence(sourceStart: candidates[index].sourceStart, sourceDuration: candidates[index].sourceDuration)
            cachedEvidence.embedding = embedding
            cachedEvidence.embeddingInputSignature = inputSignature
            cacheRecord.candidates[key] = cachedEvidence
        }
        let embeddings = candidates.compactMap { $0.insights?.visualEmbedding }.filter { !$0.values.isEmpty }
        reports.append(DeepAnalysisStageReport(
            stage: .embeddings,
            ran: !embeddings.isEmpty,
            cacheHit: embeddingCacheHits > 0,
            itemCount: embeddings.count,
            confidence: mean(embeddings.map(\.confidence)),
            duration: Date().timeIntervalSince(embeddingStarted),
            reason: "Локальные дескрипторы изображения и меток (без отдельной нейросети); cache hits \(embeddingCacheHits)"
        ))

        let trackingStarted = Date()
        // Canvas orientation is chosen after analysis. Every candidate must
        // therefore carry the inexpensive track assembled from already sampled
        // subject observations; otherwise a later 9:16 build would fall back
        // to a blind center crop for candidates outside the old fast-mode cap.
        let trackingLimit = candidates.count
        let trackingIndices = Set(candidates.indices.sorted {
            SemanticSceneIndex.bestTakeScore(candidates[$0]) > SemanticSceneIndex.bestTakeScore(candidates[$1])
        }.prefix(trackingLimit))
        var trackingCacheHits = 0
        for index in candidates.indices where trackingIndices.contains(index) {
            let key = stableKey(for: candidates[index])
            let frames = nearbySamples(for: candidates[index], samples: samples, limit: max(3, min(10, profile.framesPerCandidate + 2)))
            let inputSignature = Self.frameEvidenceSignature(frames, context: "subject-tracker-v1")
            let tracking: SubjectTrackingSummary?
            if let cached = cacheRecord.candidates[key]?.subjectTracking, cached.analyzedFrameCount > 0,
               cacheRecord.candidates[key]?.trackingInputSignature == inputSignature {
                tracking = cached
                trackingCacheHits += 1
            } else {
                let descriptors = frames.map { SubjectFrameDescriptor(timestamp: $0.timestamp, observations: $0.subjects ?? []) }
                let value = LocalSubjectTracker().track(frames: descriptors)
                tracking = value.tracks.isEmpty ? nil : value
            }
            var insights = ensuredInsights(for: candidates[index])
            insights.subjectTracking = tracking
            if let tracking {
                insights.composition = (insights.composition * 0.56 + tracking.compositionQuality * 0.44).clamped01
                if let subject = tracking.mainSubject {
                    candidates[index].tags.insert(subject.kind.rawValue)
                    candidates[index].explanation.append("Главный объект: \(subject.label), visibility \(Int((subject.visibility * 100).rounded()))%")
                }
            }
            candidates[index].insights = insights
            var cachedEvidence = cacheRecord.candidates[key] ?? CachedCandidateDeepEvidence(sourceStart: candidates[index].sourceStart, sourceDuration: candidates[index].sourceDuration)
            cachedEvidence.subjectTracking = tracking
            cachedEvidence.trackingInputSignature = inputSignature
            cacheRecord.candidates[key] = cachedEvidence
        }
        let tracked = candidates.compactMap { $0.insights?.subjectTracking }
        reports.append(DeepAnalysisStageReport(
            stage: .subjectTracking,
            ran: !tracked.isEmpty,
            cacheHit: trackingCacheHits > 0,
            itemCount: tracked.count,
            confidence: mean(tracked.map(\.confidence)),
            duration: Date().timeIntervalSince(trackingStarted),
            reason: "Tracking выполнен только для \(trackingLimit) shortlist-кандидатов; cache hits \(trackingCacheHits)"
        ))

        let asrStarted = Date()
        let cachedTranscript = cacheRecord.transcriptModelIdentity == speechRecognizer.modelIdentifier ? cacheRecord.transcript : nil
        var transcript = cachedTranscript
        let shouldRunASR = profile.audioAnalysisLevel == .deep
            && asset.metadata.hasAudio
            && (audio?.speechProbability ?? 0) >= 0.28
            && !candidates.isEmpty
        if transcript == nil, shouldRunASR {
            transcript = try? await speechRecognizer.transcribe(url: asset.originalURL, localeIdentifier: nil)
            cacheRecord.transcript = transcript
            cacheRecord.transcriptModelIdentity = speechRecognizer.modelIdentifier
        }
        var transcribedCandidates = 0
        for index in candidates.indices {
            let range = candidates[index].sourceStart...(candidates[index].sourceStart + candidates[index].sourceDuration)
            var speech = transcript.flatMap { TranscriptEvidenceBuilder().evidence(for: range, transcript: $0) }
            if speech == nil,
               let event = audioEvents.filter({ $0.kind == .speech && $0.overlaps(range) }).max(by: { $0.confidence < $1.confidence }) {
                speech = SpeechEditingEvidence(
                    text: "",
                    phraseStart: max(range.lowerBound, event.startTime),
                    phraseEnd: min(range.upperBound, event.endTime),
                    confidence: event.confidence * 0.62,
                    startsAtPhraseBoundary: range.lowerBound <= event.startTime + 0.12,
                    endsAtPhraseBoundary: range.upperBound >= event.endTime - 0.12
                )
            }
            var insights = ensuredInsights(for: candidates[index])
            insights.speech = speech
            if speech != nil {
                transcribedCandidates += 1
                candidates[index].tags.insert("speech")
                let importance = speech!.editorialImportance
                insights.originalAudioUsefulness = max(insights.originalAudioUsefulness, speech!.confidence * (0.52 + importance * 0.40))
                insights.storyValue = max(insights.storyValue, importance * 0.82)
                if importance >= 0.52 { candidates[index].tags.insert("dialogue") }
                if speech!.text.contains("!") || speech!.text.contains("?") { candidates[index].tags.insert("reaction") }
                if importance < 0.24 { candidates[index].explanation.append("Речь распознана как низкоинформативная; selection boost не применяется") }
            }
            candidates[index].insights = insights
        }
        reports.append(DeepAnalysisStageReport(
            stage: .asr,
            ran: transcript != nil,
            cacheHit: cachedTranscript != nil,
            itemCount: transcript?.words.count ?? 0,
            confidence: transcript?.confidence ?? mean(candidates.compactMap { $0.insights?.speech?.confidence }),
            duration: Date().timeIntervalSince(asrStarted),
            reason: transcript != nil
                ? "Локальный on-device ASR; word/sentence timestamps сохранены"
                : shouldRunASR ? "On-device ASR недоступен; использованы DSP speech/silence boundaries" : "ASR пропущен: нет вероятной речи среди shortlist-кандидатов"
        ))

        for index in candidates.indices {
            let range = candidates[index].sourceStart...(candidates[index].sourceStart + candidates[index].sourceDuration)
            let events = audioEvents.filter { $0.overlaps(range) && $0.confidence >= 0.36 }
            var insights = ensuredInsights(for: candidates[index])
            insights.audioEvents = events
            insights.audioQuality = audio?.originalSoundQuality
            if !events.isEmpty {
                let useful = events.filter { ![.silence, .wind].contains($0.kind) }.map { $0.confidence * $0.intensity }.max() ?? 0
                insights.originalAudioUsefulness = max(insights.originalAudioUsefulness, useful)
                for event in events where event.confidence >= 0.55 { candidates[index].tags.insert("audio:\(event.kind.rawValue)") }
                if events.contains(where: { [.impact, .splash, .scream, .applause].contains($0.kind) && $0.confidence >= 0.54 }) {
                    candidates[index].scores.interest = min(1, candidates[index].scores.interest + 0.08)
                    candidates[index].scores.action = min(1, candidates[index].scores.action + 0.07)
                }
            }
            candidates[index].insights = insights
        }

        var nearDuplicates: [UUID] = []
        let index = SemanticSceneIndex(candidates: candidates)
        for cluster in index.clusters(threshold: 0.88) {
            for candidateIndex in candidates.indices where cluster.candidateIDs.contains(candidates[candidateIndex].id) {
                var insights = ensuredInsights(for: candidates[candidateIndex])
                insights.semanticEventID = cluster.id
                insights.bestTakeScore = SemanticSceneIndex.bestTakeScore(candidates[candidateIndex])
                if candidates[candidateIndex].id == cluster.bestCandidateID {
                    candidates[candidateIndex].scores.uniqueness = max(candidates[candidateIndex].scores.uniqueness, 0.82)
                    candidates[candidateIndex].explanation.append("Лучший дубль семантически сгруппированного события")
                } else {
                    candidates[candidateIndex].scores.uniqueness = min(candidates[candidateIndex].scores.uniqueness, max(0.12, 1 - cluster.meanSimilarity))
                    candidates[candidateIndex].explanation.append("Near-duplicate события; более сильный дубль доступен AI Director")
                    nearDuplicates.append(candidates[candidateIndex].id)
                }
                candidates[candidateIndex].insights = insights
            }
        }

        let boundaryStarted = Date()
        let sourceDuration = max(0.1, asset.metadata.duration ?? candidates.map { $0.sourceStart + $0.sourceDuration }.max() ?? 0.1)
        if asset.kind == .video {
        for index in candidates.indices {
            let original = candidates[index]
            let peak = original.momentBoundary?.peakTime ?? original.sourceStart + original.sourceDuration / 2
            let candidateEvents = original.insights?.audioEvents ?? candidates[index].insights?.audioEvents ?? []
            let subjectTracking = candidates[index].insights?.subjectTracking
            let speech = candidates[index].insights?.speech
            let signals = nearbySamples(for: candidates[index], samples: samples, limit: max(5, profile.framesPerCandidate + 2)).map { sample in
                let audioEvent = candidateEvents.filter { $0.startTime <= sample.timestamp && $0.endTime >= sample.timestamp }
                    .map { event in
                        let boost: Double = [.impact, .splash, .scream, .applause].contains(event.kind) ? 1 : event.kind == .speech ? 0.58 : 0.34
                        return event.confidence * boost
                    }.max() ?? 0
                let subject = (sample.subjects ?? []).map { $0.confidence * min(1, $0.region.area / 0.16) }.max() ?? 0
                let phraseBoundary = speech.map { value in
                    let distance = min(abs(sample.timestamp - value.phraseStart), abs(sample.timestamp - value.phraseEnd))
                    return max(0, 1 - distance / 0.65) * value.confidence
                } ?? 0
                return MomentSignal(
                    timestamp: sample.timestamp,
                    motion: sample.motion,
                    interest: sample.interest,
                    semantic: sample.semanticPotential,
                    audioOnset: audioOnset(at: sample.timestamp, duration: sourceDuration, summary: audio),
                    telemetry: TelemetryHighlightDetector().strongestMoment(
                        in: max(0, sample.timestamp - 0.75)...min(sourceDuration, sample.timestamp + 0.75),
                        moments: telemetryMoments
                    )?.score ?? 0,
                    audioEvent: audioEvent,
                    subject: subject,
                    speechBoundary: phraseBoundary,
                    vlm: candidates[index].insights?.storyValue ?? 0
                )
            }
            var refined = MomentBoundaryRefiner().refine(
                around: peak,
                signals: signals,
                sourceDuration: sourceDuration,
                nominalDuration: original.sourceDuration
            )
            if let speech, speech.confidence >= 0.48 {
                refined.anticipationStart = min(refined.anticipationStart, speech.phraseStart)
                refined.completionEnd = max(refined.completionEnd, speech.phraseEnd)
                refined.evidence.append("ASR phrase boundaries preserved")
            }
            if subjectTracking?.confidence ?? 0 >= 0.42 { refined.evidence.append("subject tracking observed; action semantics unverified") }
            if refined.confidence < 0.42 {
                refined.anticipationStart = min(refined.anticipationStart, original.sourceStart)
                refined.completionEnd = max(refined.completionEnd, original.sourceStart + original.sourceDuration)
                refined.evidence.append("low confidence: conservative source handles")
            }
            refined.completionEnd = min(sourceDuration, refined.completionEnd)
            candidates[index].momentBoundary = refined
            candidates[index].sourceStart = max(0, refined.anticipationStart)
            candidates[index].sourceDuration = max(0.05, refined.completionEnd - refined.anticipationStart)
        }
        }
        reports.append(DeepAnalysisStageReport(
            stage: .momentRefinement,
            ran: asset.kind == .video && !candidates.isEmpty,
            itemCount: candidates.count,
            confidence: mean(candidates.compactMap { $0.momentBoundary?.confidence }),
            duration: Date().timeIntervalSince(boundaryStarted),
            reason: asset.kind == .video
                ? "visual + motion + telemetry + audio onset/events + ASR + subject + VLM evidence"
                : "Для фото временные границы момента не применяются"
        ))

        try? await cache?.store(cacheRecord)
        let discarded = candidates.filter { $0.scores.uniqueness <= 0.16 && !$0.locked }.map(\.id)
        let diagnostics = DeepMediaDiagnostics(
            stages: reports,
            embeddedCandidateCount: embeddings.count,
            trackedCandidateCount: tracked.count,
            transcribedCandidateCount: transcribedCandidates,
            audioEventCandidateCount: candidates.filter { !($0.insights?.audioEvents ?? []).isEmpty }.count,
            nearDuplicateCandidateIDs: nearDuplicates,
            discardedCandidateIDs: discarded,
            totalDuration: Date().timeIntervalSince(totalStarted)
        )
        return DeepMediaEnrichmentResult(candidates: candidates, transcript: transcript, audioEvents: audioEvents, diagnostics: diagnostics)
    }

    static func frameEvidenceSignature(_ frames: [VisualFrameSample], context: String) -> String {
        // Sorted labels make the digest stable across process launches. Include
        // temporal neighbours, pixels, transform output, observations and model.
        struct Evidence: Encodable {
            var timestamp: Double
            var actual: Double?
            var labels: [String]
            var histogram: [Double]
            var fingerprint: [UInt8]
            var subjects: [FrameSubjectObservation]?
            var width: Int?
            var height: Int?
        }
        let values = frames.map { Evidence(timestamp: $0.timestamp, actual: $0.actualTimestamp,
            labels: $0.labels.sorted(), histogram: $0.histogram, fingerprint: $0.luminanceFingerprint,
            subjects: $0.subjects, width: $0.pixelWidth, height: $0.pixelHeight) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(values) else { return UUID().uuidString }
        data.append(Data(context.utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func stableKey(for candidate: Candidate) -> String {
        CachedCandidateDeepEvidence(sourceStart: candidate.sourceStart, sourceDuration: candidate.sourceDuration).stableKey
    }

    private func nearbySamples(for candidate: Candidate, samples: [VisualFrameSample], limit: Int) -> [VisualFrameSample] {
        let start = candidate.sourceStart - 0.45
        let end = candidate.sourceStart + candidate.sourceDuration + 0.45
        let inRange = samples.filter { $0.timestamp >= start && $0.timestamp <= end }
        let center = candidate.sourceStart + candidate.sourceDuration / 2
        return Array((inRange.isEmpty ? samples : inRange)
            .sorted { abs($0.timestamp - center) < abs($1.timestamp - center) }
            .prefix(max(1, limit)))
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func semanticTokens(_ candidate: Candidate) -> Set<String> {
        var values = Set(candidate.tags.map { $0.lowercased() })
        if let summary = candidate.insights?.sceneSummary {
            values.formUnion(summary.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        }
        return values
    }

    private func ensuredInsights(for candidate: Candidate) -> CandidateInsights {
        candidate.insights ?? CandidateInsights(
            sceneSummary: candidate.tags.sorted().prefix(4).joined(separator: ", "),
            dynamics: candidate.scores.action,
            visualAppeal: candidate.scores.interest,
            composition: candidate.scores.quality,
            sharpness: candidate.scores.quality,
            exposureQuality: candidate.scores.quality,
            originalAudioUsefulness: 0,
            storyValue: candidate.scores.interest
        )
    }

    private func audioOnset(at timestamp: Double, duration: Double, summary: AudioAnalysisSummary?) -> Double {
        let values = summary?.onsetEnvelope ?? summary?.waveform ?? []
        guard values.count > 1, duration > 0 else { return 0 }
        let index = min(values.count - 1, max(0, Int((timestamp / duration * Double(values.count - 1)).rounded())))
        return values[index].clamped01
    }

    private func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}
