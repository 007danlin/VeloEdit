import Foundation

public protocol EditorialEvidenceAnalyzing: Sendable {
    func analyze(candidate: Candidate, asset: MediaAsset) async throws -> EditorialEvidence
}

public actor EditorialEvidenceCache {
    public static let version = 4
    private let root: URL
    public init(root: URL) { self.root = root }
    public static func key(contentHash: String, candidate: Candidate) -> String {
        EditorialIdentity.hash("\(contentHash)|\(candidate.sourceStart)|\(candidate.sourceDuration)|editorial:\(version)")
    }
    public func load(contentHash: String, candidate: Candidate) -> EditorialEvidence? {
        let url = root.appendingPathComponent(Self.key(contentHash: contentHash, candidate: candidate) + ".json")
        guard let data = try? Data(contentsOf: url), let evidence = try? JSONDecoder().decode(EditorialEvidence.self, from: data), evidence.analysisVersion == Self.version else { return nil }
        return evidence
    }
    public func store(_ evidence: EditorialEvidence, contentHash: String, candidate: Candidate) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(evidence).write(to: root.appendingPathComponent(Self.key(contentHash: contentHash, candidate: candidate) + ".json"), options: .atomic)
    }
}

public struct LocalEditorialEvidenceAnalyzer: EditorialEvidenceAnalyzing {
    private let cache: EditorialEvidenceCache
    private let frames: FrameCache
    public init(cacheURL: URL) {
        cache = EditorialEvidenceCache(root: cacheURL.appendingPathComponent("EditorialEvidence"))
        frames = FrameCache(rootURL: cacheURL.appendingPathComponent("EditorialFrames"))
    }

    public func analyze(candidate: Candidate, asset: MediaAsset) async throws -> EditorialEvidence {
        try Task.checkCancellation()
        if let cached = await cache.load(contentHash: asset.contentHash, candidate: candidate) { return cached }
        let samples: [VisualFrameSample]
        if asset.kind == .photo {
            samples = try await AdaptiveFrameSampler().samplePhoto(url: asset.originalURL, sourceHash: asset.contentHash, maximumSize: 384, frameCache: frames).samples
        } else {
            let count = candidate.sourceDuration > 12 ? 24 : 12
            let end = min(candidate.sourceStart + candidate.sourceDuration, asset.metadata.duration ?? .greatestFiniteMagnitude)
            let length = max(0, end - candidate.sourceStart - 1 / max(24, asset.metadata.frameRate ?? 30))
            let times = (0..<count).map { candidate.sourceStart + length * Double($0) / Double(count - 1) }
            samples = try await AdaptiveFrameSampler().editorialSamples(url: asset.originalURL, sourceHash: asset.contentHash, timestamps: times, frameCache: frames)
        }
        let evidence = Self.evidence(candidate: candidate, samples: samples, isPhoto: asset.kind == .photo)
        try Task.checkCancellation()
        try await cache.store(evidence, contentHash: asset.contentHash, candidate: candidate)
        return evidence
    }

    static func evidence(candidate: Candidate, samples: [VisualFrameSample], isPhoto: Bool = false) -> EditorialEvidence {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        let temporal = sorted.map { sample in
            EditorialTemporalSample(sourceTime: sample.timestamp, subjectRegions: (sample.subjects ?? []).map(\.region), subjectKinds: (sample.subjects ?? []).map(\.kind), actionState: sample.labels.intersection(Self.actionStates), composition: sample.histogram, motionEnergy: sample.motion, quality: sample.technicalQuality, confidence: sample.labelConfidence)
        }
        var visualChange = 0.0, unchanged = 0.0, longestUnchanged = 0.0
        var stableStates: [(Set<String>, Int, Double)] = []
        for sample in temporal {
            if stableStates.last?.0 == sample.actionState {
                stableStates[stableStates.count - 1].1 += 1
                stableStates[stableStates.count - 1].2 = min(stableStates.last?.2 ?? 0, sample.confidence)
            } else { stableStates.append((sample.actionState, 1, sample.confidence)) }
        }
        // Empty detections and label flicker are unknown, not an action change.
        // Each side of a transition needs three consecutive observations.
        let confirmed = stableStates.filter { !$0.0.isEmpty && $0.1 >= 3 && $0.2 >= 0.65 }
        let transitions = zip(confirmed, confirmed.dropFirst()).filter { $0.0 != $1.0 }.count
        for (a, b) in zip(temporal, temporal.dropFirst()) {
            let delta = zip(a.composition, b.composition).reduce(0) { $0 + abs($1.0 - $1.1) } / 2
            visualChange += delta
            if a.actionState == b.actionState || a.actionState.isEmpty || b.actionState.isEmpty { unchanged += b.sourceTime - a.sourceTime } else { unchanged = 0 }
            longestUnchanged = max(longestUnchanged, unchanged)
        }
        let count = max(1, temporal.count - 1)
        let action = min(1, Double(transitions) * 0.35)
        // Histogram L1 distance is numerically small even for a visibly
        // changing wide-angle ride. Calibrate that measured signal and combine
        // it with optical motion instead of classifying all unlabeled travel
        // as a static twelve-second camera setup.
        let histogramChange = min(1, visualChange / Double(count) * 5)
        let meanMotion = temporal.isEmpty
            ? 0
            : temporal.reduce(0) { $0 + $1.motionEnergy } / Double(temporal.count)
        let visual = (histogramChange * 0.65 + meanMotion * 0.35).clamped01
        let boundary = candidate.momentBoundary
        let completion = boundary.map { $0.confidence >= 0.65 && action >= 0.18 ? $0.confidence : 0 } ?? 0
        let good = temporal.filter { $0.quality >= 0.38 }
        let start = good.first?.sourceTime ?? candidate.sourceStart
        let end = min(candidate.sourceStart + candidate.sourceDuration, (good.last?.sourceTime ?? start) + 0.05)
        let region = temporal.flatMap(\.subjectRegions).max { $0.area < $1.area }
        let scale: EditorialShotScale = region.map { $0.area > 0.35 ? .close : $0.area > 0.12 ? .medium : .wide } ?? .unknown
        let sufficient = isPhoto || temporal.count >= (candidate.sourceDuration > 12 ? 24 : 12)
        let meanQuality = temporal.isEmpty ? candidate.scores.quality : temporal.reduce(0) { $0 + $1.quality } / Double(temporal.count)
        let informationGain = action >= 0.18
            ? (action * 0.8 + visual * 0.2).clamped01
            : (visual * 0.70).clamped01
        let atmosphere = action >= 0.18 ? 0 : (
            candidate.scores.interest * 0.35 + meanQuality * 0.25 +
            candidate.scores.stability * 0.20 + visual * 0.20
        ).clamped01
        return EditorialEvidence(samples: temporal, usableRange: .init(start: isPhoto ? candidate.sourceStart : start, end: isPhoto ? candidate.sourceStart + candidate.sourceDuration : max(start, end)), actionDelta: action, visualDelta: visual, informationGain: informationGain, completion: completion, entryQuality: good.first?.quality ?? candidate.scores.quality, exitQuality: good.last?.quality ?? candidate.scores.quality, unchangedSeconds: longestUnchanged, atmosphereValue: atmosphere, shotScale: scale, confidence: sufficient ? 0.62 : 0.25, provenance: ["persistent action-class transitions + local subject observations", "measured visual change informs atmosphere and information gain", "\(temporal.count) decoded samples", "action change is conservative; no pose model", "foreground occlusion unknown without dedicated evidence"])
    }

    private static let actionStates: Set<String> = [
        "running", "walking", "cycling", "swimming", "jumping", "landing", "falling", "climbing", "rowing", "fishing", "casting", "catching", "laughing", "crying", "hugging", "waving", "departing", "arriving"
    ]

    public func enrich(analyses: [AnalysisResult], assets: [MediaAsset]) async throws -> [AnalysisResult] {
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var result = analyses
        // Decode sequentially: bound working memory and AVFoundation readers.
        for i in result.indices {
            guard let asset = byID[result[i].assetID], !asset.missing, !asset.excluded else { continue }
            for j in result[i].candidates.indices {
                try Task.checkCancellation()
                let candidate = result[i].candidates[j]
                do {
                    let evidence: EditorialEvidence
                    if let existing = candidate.insights?.editorialEvidence, existing.analysisVersion == EditorialEvidenceCache.version { evidence = existing }
                    else { evidence = try await analyze(candidate: candidate, asset: asset) }
                    var insights = candidate.insights ?? CandidateInsights()
                    insights.editorialEvidence = evidence
                    insights.subjectTracking = Self.tracking(existing: insights.subjectTracking, evidence: evidence)
                    result[i].candidates[j].insights = insights
                } catch is CancellationError { throw CancellationError() }
                catch { result[i].warnings.append("Editorial evidence unavailable for \(candidate.id): \(error.localizedDescription)") }
            }
        }
        return result
    }

    static func tracking(existing: SubjectTrackingSummary?, evidence: EditorialEvidence) -> SubjectTrackingSummary? {
        let prefix = "editorial-temporal:"
        let frames = evidence.samples.map { sample in
            SubjectFrameDescriptor(timestamp: sample.sourceTime, observations: zip(sample.subjectKinds, sample.subjectRegions).map { kind, region in
                FrameSubjectObservation(kind: kind, label: prefix + kind.rawValue, region: region, confidence: sample.confidence)
            })
        }
        guard frames.contains(where: { !$0.observations.isEmpty }) else { return existing }
        var refreshed = LocalSubjectTracker().track(frames: frames)
        // Preserve prior detections between the new samples. Re-enrichment
        // replaces its own tracks rather than accumulating copies forever.
        refreshed.tracks += (existing?.tracks ?? []).filter { !$0.label.hasPrefix(prefix) }
        refreshed.confidence = max(refreshed.confidence, existing?.confidence ?? 0)
        return refreshed
    }
}

public struct EditorialCandidateMiner: Sendable {
    public static let completionMarker = "editorial-expanded-mining-v5-source-wide-complete"
    public init() {}
    public static func requiresProductionization(_ analyses: [AnalysisResult]) -> Bool {
        !analyses.allSatisfy { $0.warnings.contains(completionMarker) }
    }
    public func expandIfNeeded(analyses: [AnalysisResult], assets: [MediaAsset], requestedDuration: Double?, force: Bool = false, analyzer: any EditorialEvidenceAnalyzing) async throws -> [AnalysisResult] {
        // Completed source-wide mining cannot add any candidates. Check this
        // before the expensive provisional sequence search, especially when
        // reopening a project with hundreds of measured visual embeddings.
        guard !analyses.allSatisfy({ $0.warnings.contains(Self.completionMarker) }) else { return analyses }
        let context = EditorialAnalysisContext(analyses: analyses)
        let budget = ContentBudgetEngine().budget(units: context.units, families: context.families, requestedDuration: requestedDuration, requestIsExplicit: true, style: DirectorStyleVector())
        let provisional = EditorialSequenceSearch().sequence(hypothesis: .init(pattern: .minimalMontage, evidenceCoverage: 0, reasons: ["capacity preflight"]), units: context.units, families: context.families, target: budget.budget.idealDuration, pacing: 0.5)
        let selectedDuration = provisional.beatPlan.beats.reduce(0) { $0 + $1.allocatedDuration }
        let belowMinimum = selectedDuration + 0.05 < budget.budget.safeRange.lowerBound
        guard force || budget.requiresExpandedMining || belowMinimum,
              !analyses.allSatisfy({ $0.warnings.contains(Self.completionMarker) }) else { return analyses }
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var result = analyses
        // Exhaust the available quality windows before declaring insufficient
        // material. A budget-limited prefix used to mark long sources complete
        // even though later scenes had never been inspected.
        struct MiningSeed {
            var start: Double
            var end: Double
            var scene: SceneAnalysis
        }
        var queues: [Int: [MiningSeed]] = [:]
        for i in result.indices {
            guard let asset = byID[result[i].assetID], asset.kind == .video, !asset.missing, !asset.excluded,
                  !result[i].warnings.contains(Self.completionMarker) else { continue }
            // Boundary confidence describes how certain the cut between two
            // analysis windows is; it is not a quality score for the footage
            // inside that window. Rejecting ordinary 0.35 windows previously
            // restricted long GoPro sources to their first ~48 seconds.
            var investigated = (result[i].scenes ?? []).sorted { $0.startTime < $1.startTime }
            var coveredEnd = 0.0
            var gaps: [SceneAnalysis] = []
            for scene in investigated {
                if scene.startTime - coveredEnd >= 1 { gaps.append(.init(startTime: coveredEnd, endTime: scene.startTime)) }
                coveredEnd = max(coveredEnd, scene.endTime)
            }
            if let end = asset.metadata.duration, end - coveredEnd >= 1 { gaps.append(.init(startTime: coveredEnd, endTime: end)) }
            investigated += gaps
            let scenes = investigated.filter {
                $0.qualityScore >= 0.5 && $0.duration >= 1
            }.sorted { $0.startTime < $1.startTime }
            for scene in scenes {
                let existing = result[i].candidates
                let overlaps = existing.filter { $0.sourceStart < scene.endTime && $0.sourceStart + $0.sourceDuration > scene.startTime }
                var anchors = [scene.startTime, max(scene.startTime, scene.endTime - 12)]
                if overlaps.isEmpty { anchors.append((scene.startTime + scene.endTime) / 2) }
                anchors += stride(from: scene.startTime + 6, to: scene.endTime - 1, by: 6)
                anchors = Array(Set(anchors)).sorted()
                for start in anchors {
                    let end = min(scene.endTime, start + 12, asset.metadata.duration ?? scene.endTime)
                    guard end - start >= 1, !existing.contains(where: { abs($0.sourceStart - start) < 0.1 && abs($0.sourceDuration - (end - start)) < 0.1 }) else { continue }
                    queues[i, default: []].append(.init(start: start, end: end, scene: scene))
                }
            }
        }
        var cursors = Dictionary(uniqueKeysWithValues: queues.keys.map { ($0, 0) })
        var failedAnalysisIndices = Set<Int>()
        let total = queues.values.reduce(0) { $0 + $1.count }
        var remaining = total
        await FilmBuildReporting.report(FilmBuildProgress(.moments, completed: 0, total: total))
        while remaining > 0 {
            var advanced = false
            for i in queues.keys.sorted() where remaining > 0 {
                guard let asset = byID[result[i].assetID], let seeds = queues[i],
                      let cursor = cursors[i], cursor < seeds.count else { continue }
                try Task.checkCancellation()
                advanced = true
                let seed = seeds[cursor]
                cursors[i] = cursor + 1
                var candidate = Candidate(id: EditorialIdentity.uuid("mining-v4|\(asset.id)|\(asset.contentHash)|\(seed.start)|\(seed.end)"), assetID: asset.id, sourceStart: seed.start, sourceDuration: seed.end - seed.start, scores: ClipScores(quality: seed.scene.qualityScore, interest: seed.scene.beautyScore, action: seed.scene.actionScore, stability: seed.scene.stabilityScore), tags: Set(seed.scene.objects + seed.scene.people), insights: CandidateInsights(sceneSummary: seed.scene.semanticDescription))
                    do {
                        let evidence = try await analyzer.analyze(candidate: candidate, asset: asset)
                        candidate.insights?.editorialEvidence = evidence
                        if evidence.confidence >= 0.55 {
                            let measuredQuality = evidence.samples.isEmpty
                                ? (evidence.entryQuality + evidence.exitQuality) / 2
                                : evidence.samples.reduce(0) { $0 + $1.quality } / Double(evidence.samples.count)
                            candidate.insights?.bestTakeScore = measuredQuality
                        }
                        if EditorialUnit(candidate: candidate).usableDuration >= 1 { result[i].candidates.append(candidate) }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        failedAnalysisIndices.insert(i)
                        result[i].warnings.append("Expanded editorial mining: \(error.localizedDescription)")
                    }
                    remaining -= 1
                    await FilmBuildReporting.report(FilmBuildProgress(.moments, completed: total - remaining, total: total, detail: asset.displayName))
            }
            if !advanced { break }
        }
        for i in result.indices where byID[result[i].assetID] != nil && !failedAnalysisIndices.contains(i) && (cursors[i] ?? 0) == (queues[i]?.count ?? 0) {
            guard let asset = byID[result[i].assetID], !asset.excluded, !asset.missing,
                  asset.kind == .photo || (asset.metadata.duration ?? 0) > 0 else { continue }
            if !result[i].warnings.contains(Self.completionMarker) {
                result[i].warnings.append(Self.completionMarker)
            }
        }
        return result
    }
}
