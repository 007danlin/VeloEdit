import Foundation

public enum DirectorSubtitlePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, on, off
    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self { case .automatic: return "Автоматически для влога"; case .on: return "Включены"; case .off: return "Выключены" }
    }
}
public extension DirectorBrief {
    func subtitlesEnabled(preset: FilmPreset) -> Bool {
        guard sourceAudioPolicy != .mute || subtitlesWithoutAudio == true else { return false }
        switch subtitlePolicy { case .off: return false; case .on: return true; case .automatic: return preset == .vlog; case nil: return preset == .vlog && titlePolicy != .none }
    }
    func applyingSubtitleCommand(_ command: String) -> Self {
        var result = self
        let text = command.lowercased()
        if text.contains("без субтитров") || text.contains("убери субтитры") { result.subtitlePolicy = .off }
        else if text.contains("добавь субтитры") || text.contains("включи субтитры") || text.contains("оставь субтитры") { result.subtitlePolicy = .on }
        if text.contains("субтитры без звука") { result.subtitlesWithoutAudio = true; result.subtitlePolicy = .on }
        if text.contains("без титров") || text.contains("убери все надписи") { result.titlePolicy = .none; result.subtitlePolicy = .off }
        if text.contains("убери только названия частей") { result.titlePolicy = .none; if result.subtitlePolicy == nil { result.subtitlePolicy = .automatic } }
        return result
    }
}

public enum SpeechRecognitionStatus: String, Codable, Sendable { case ready, noSpeech, partial, modelUnavailable, failed, cancelled }
public struct SpeechProvenance: Codable, Hashable, Sendable {
    public var schemaVersion = 1
    public var runtime: String
    public var model: String
    public var modelHash: String
    public var vad: String
    public var alignment: String
    public var preparation: String
    public var sourceHash: String
    public var audioTrack = 0
    public var channel = "mono-downmix"
    public init(manifest: SpeechPackageManifest, sourceHash: String) {
        runtime = manifest.runtime; model = manifest.model; modelHash = manifest.identity
        vad = "silero-" + manifest.vadRevision; alignment = "whisper-cross-attention-word-v1"
        preparation = manifest.preprocessing; self.sourceHash = sourceHash
    }
}
public struct SpeechSourceRecord: Codable, Hashable, Sendable {
    public var assetID: UUID
    public var status: SpeechRecognitionStatus
    public var transcript: SpeechTranscript
    public var warnings: [String]
    public init(assetID: UUID, transcript: SpeechTranscript) {
        self.assetID = assetID; self.transcript = transcript
        status = transcript.status ?? (transcript.sentences.isEmpty ? .noSpeech : .ready)
        warnings = transcript.warnings ?? []
    }
}
public struct SpeechWorkerRequest: Codable, Sendable {
    public var sourceURL: URL
    public var packageURL: URL
    public var cacheURL: URL
    public var outputURL: URL
    public var locale: String
    public var sourceHash: String
    public init(sourceURL: URL, packageURL: URL, cacheURL: URL, outputURL: URL, locale: String, sourceHash: String) {
        self.sourceURL = sourceURL; self.packageURL = packageURL; self.cacheURL = cacheURL
        self.outputURL = outputURL; self.locale = locale; self.sourceHash = sourceHash
    }
}

/// Deliberately conservative: preserve all source material except an acoustically
/// confirmed, long silence between two complete recognized sentences.
public enum VlogAssembly {
    public static func retainedRanges(duration: Double, transcript: SpeechTranscript?) -> [ClosedRange<Double>] {
        guard duration > 0 else { return [] }
        guard let transcript else { return [0...duration] }
        let phrases = transcript.sentences.sorted { $0.startTime < $1.startTime }
        var removed: [ClosedRange<Double>] = []
        for (a, b) in zip(phrases, phrases.dropFirst()) {
            guard b.startTime - a.endTime > 0.9, a.text.last.map({ ".!?…".contains($0) }) == true,
                  let silence = transcript.silenceBoundaries.first(where: { $0.lowerBound <= a.endTime + 0.15 && $0.upperBound >= b.startTime - 0.15 }),
                  silence.upperBound - silence.lowerBound > 0.9 else { continue }
            let start = max(a.endTime + 0.16, silence.lowerBound + 0.12)
            let end = min(b.startTime - 0.16, silence.upperBound - 0.12)
            if end > start { removed.append(start...end) }
        }
        var cursor = 0.0; var result: [ClosedRange<Double>] = []
        for gap in removed where gap.lowerBound >= cursor && gap.upperBound <= duration {
            if gap.lowerBound > cursor { result.append(cursor...gap.lowerBound) }; cursor = gap.upperBound
        }
        if cursor < duration { result.append(cursor...duration) }
        return result
    }
    public static func assemble(assets: [MediaAsset], records: [SpeechSourceRecord], plan: StoryPlan) -> Timeline {
        var items: [TimelineItem] = []
        let sourceMap = SourceTimelineAnalyzer().analyze(assets: assets, analyses: [])
        let order = Dictionary(sourceMap.entries.map { ($0.assetID, $0.order) }, uniquingKeysWith: { first, _ in first })
        let ordered = assets.sorted { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
        for asset in ordered where !asset.excluded && !asset.missing {
            let length = asset.kind == .photo ? 4.0 : (asset.metadata.duration ?? 0)
            let transcript = records.first { $0.assetID == asset.id }?.transcript
            for range in retainedRanges(duration: length, transcript: transcript) {
                items.append(TimelineItem(assetID: asset.id, kind: asset.kind == .photo ? .photo : .video,
                    sourceStart: range.lowerBound, sourceDuration: range.upperBound - range.lowerBound,
                    timelineStart: 0, timelineDuration: range.upperBound - range.lowerBound,
                    transition: TransitionStyle.cut.rawValue,
                    explanation: ["Влог: исходный порядок, скорость голоса 1×, сохранены фразы"]))
            }
        }
        let brief = plan.directorBrief ?? .legacyDefault
        var result = Timeline(storyPlanID: plan.id, width: brief.canvasFormat.width, height: brief.canvasFormat.height,
            items: TimelineTiming.retimed(items), originalAudioVolume: brief.sourceAudioPolicy.volume,
            audioDucking: AudioDuckingSettings(enabled: brief.sourceAudioPolicy != .mute))
        result.speechRecords = records
        result.automaticallySelectFrameRate = true
        return TimelineFrameRatePolicy.applying(to: result, assets: assets)
    }
}

public enum VlogSpeechEvidence {
    public static func enrich(_ analyses: [AnalysisResult], assets: [MediaAsset], records: [SpeechSourceRecord], schemaVersion: Int) -> [AnalysisResult] {
        var results = analyses
        for record in records {
            guard let asset = assets.first(where: { $0.id == record.assetID }) else { continue }
            var analysis = results.first { $0.assetID == asset.id } ?? AnalysisResult(assetID: asset.id, schemaVersion: schemaVersion, analyzedContentHash: asset.contentHash, candidates: [])
            analysis.candidates.removeAll { $0.explanation.contains("vlog-speech-candidate-v1") }
            for sentence in record.transcript.sentences {
                let a = max(0, sentence.startTime - 0.12); let b = min(asset.metadata.duration ?? sentence.endTime, sentence.endTime + 0.12)
                guard b > a else { continue }
                let speech = TranscriptEvidenceBuilder().evidence(for: a...b, transcript: record.transcript)
                analysis.candidates.append(Candidate(assetID: asset.id, sourceStart: a, sourceDuration: b - a,
                    scores: ClipScores(quality: 0.5, interest: 0.5, action: 0, stability: 0.5), tags: ["speech", "dialogue"],
                    explanation: ["vlog-speech-candidate-v1", "Подтверждённая фраза; визуальная оценка не измерена"],
                    insights: CandidateInsights(originalAudioUsefulness: 1, storyValue: 0.7, speech: speech)))
            }
            if let index = results.firstIndex(where: { $0.assetID == asset.id }) { results[index] = analysis }
            else { results.append(analysis) }
        }
        return results
    }
}

public enum VlogSubtitleCoverage {
    /// Coverage of recognized intervals only. This is deliberately not WER or
    /// a claim about the amount of intelligible speech in the original audio.
    public static func requirement(timeline: Timeline, brief: DirectorBrief, preset: FilmPreset) -> FilmRequirementResult {
        let enabled = brief.subtitlesEnabled(preset: preset)
        var expected = 0.0; var covered = 0.0
        for item in timeline.items where item.overlay == nil && !item.isReversed {
            guard let record = timeline.speechRecords?.first(where: { $0.assetID == item.assetID }) else { continue }
            for phrase in record.transcript.sentences {
                let lo = max(item.sourceStart, phrase.startTime); let hi = min(item.sourceStart + item.sourceDuration, phrase.endTime)
                guard hi > lo else { continue }
                expected += hi - lo
                let ranges = timeline.effectiveTitleItems.filter { $0.targetClipID == item.id && $0.enabled }.compactMap(\.speechAnchor).map { max(lo, $0.sourceStart)...max(max(lo, $0.sourceStart), min(hi, $0.sourceEnd)) }.sorted { $0.lowerBound < $1.lowerBound }
                var end = lo
                for range in ranges { covered += max(0, range.upperBound - max(end, range.lowerBound)); end = max(end, range.upperBound) }
            }
        }
        let ratio = expected > 0 ? min(1, covered / expected) : 1
        return FilmRequirementResult(sourcePhrase: "Субтитры речи", rule: "vlogSubtitles", verificationMethod: "Покрытие подтверждённых фраз сохранённого монтажа; без оценки правильности текста", passed: enabled ? ratio >= 0.98 : !timeline.effectiveTitleItems.contains { $0.speechAnchor != nil && $0.enabled }, evidence: enabled ? "Подтверждённый текст: \(Int((ratio * 100).rounded()))%; не является WER" : "Субтитры отключены по настройкам")
    }
}

/// Raw engine scores are retained independently from normalized UI confidence.
public struct SpeechSegmentDiagnostic: Codable, Hashable, Sendable {
    public var start, end, averageLogProbability, noSpeechProbability, compressionRatio: Double
    public var text, decision: String
    public var attempt: Int
    public init(start: Double, end: Double, averageLogProbability: Double, noSpeechProbability: Double, compressionRatio: Double, text: String, decision: String, attempt: Int) {
        self.start = start; self.end = end; self.averageLogProbability = averageLogProbability
        self.noSpeechProbability = noSpeechProbability; self.compressionRatio = compressionRatio
        self.text = text; self.decision = decision; self.attempt = attempt
    }
}
public struct SpeechRuntimeMetrics: Codable, Hashable, Sendable {
    public var warmupSeconds, decodeSeconds, vadSeconds, asrAndAlignmentSeconds: Double
    public var peakResidentBytes: UInt64
    public var resumedChunks: Int
    public init(warmupSeconds: Double, decodeSeconds: Double, vadSeconds: Double, asrAndAlignmentSeconds: Double, peakResidentBytes: UInt64, resumedChunks: Int) {
        self.warmupSeconds = warmupSeconds; self.decodeSeconds = decodeSeconds; self.vadSeconds = vadSeconds
        self.asrAndAlignmentSeconds = asrAndAlignmentSeconds; self.peakResidentBytes = peakResidentBytes; self.resumedChunks = resumedChunks
    }
}
