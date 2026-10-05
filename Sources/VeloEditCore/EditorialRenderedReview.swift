import Foundation

/// Injectable decoding/vision boundary. Production always probes the actual
/// composition; deterministic test doubles are supplied explicitly by tests.
public protocol EditorialRenderedProbing: Sendable {
    func frames(timeline: Timeline, assets: [MediaAsset], tracks: [LocalMusicTrack], telemetry: [UUID: TelemetrySummary], cacheURL: URL) async throws -> [PerceptualRenderedFrameEvidence]
}

public struct LocalEditorialRenderedProber: EditorialRenderedProbing {
    public var verifyExport: Bool
    public var maximumSamples: Int
    public init(verifyExport: Bool = true, maximumSamples: Int = 4096) {
        self.verifyExport = verifyExport
        self.maximumSamples = max(4, maximumSamples)
    }
    public func frames(timeline: Timeline, assets: [MediaAsset], tracks: [LocalMusicTrack], telemetry: [UUID: TelemetrySummary], cacheURL: URL) async throws -> [PerceptualRenderedFrameEvidence] {
        // Completed preview inspection survives a later interruption during
        // the much longer control export. It is not production evidence until
        // independent delivery verification has also succeeded.
        let previewCache = RenderedProbeCache(directory: cacheURL.appendingPathComponent("EditorialPreviewFrames-\(maximumSamples)"), visualOnly: true)
        let cachePaths = CachePaths(root: cacheURL.deletingLastPathComponent().deletingLastPathComponent())
        let stableSources = cachePaths.stableRenderSources(for: assets)
        let sourceWarnings = stableSources.keys.compactMap { id in
            assets.first(where: { $0.id == id }).map { "\($0.displayName): production-проверка использует декодируемую копию" }
        }
        let cachedFrames = await previewCache.load(timeline: timeline, assets: assets, tracks: tracks, telemetry: telemetry, preferredVideoSources: stableSources)
        var frames: [PerceptualRenderedFrameEvidence]
        var audioReport: EditorialAudioMasteringReport?
        if let cachedFrames {
            frames = cachedFrames
            await FilmBuildReporting.report(FilmBuildProgress(.previewFrames, completed: frames.count, total: frames.count, detail: "Использую сохранённую проверку кадров"))
        } else {
          let playback: TimelinePlayback
          do {
            playback = try await PerformanceTrace.measure(name: "composition.build", fields: ["signature": EditorialRenderSignature.signature(timeline)]) {
              try await PlaybackEngine().build(timeline: timeline, assets: assets, musicTracks: tracks, telemetry: telemetry, preferredVideoSources: stableSources, sourceWarnings: sourceWarnings, derivedMediaCacheURL: cacheURL, forceVideoComposition: true)
            }
          } catch {
            let value = error as NSError
            throw EditorialGenerationError.unsatisfiedIntent("Playback build: \(value.domain) \(value.code): \(value.localizedDescription)")
        }
          audioReport = playback.audioMasteringReport
            frames = await PerceptualRenderInspector().inspectAsync(playback: playback, timeline: timeline, maximumSamples: maximumSamples)
            try Task.checkCancellation()
            try await previewCache.store(frames, timeline: timeline, assets: assets, tracks: tracks, telemetry: telemetry, preferredVideoSources: stableSources)
        }
        if !frames.isEmpty {
            frames[0].audioMasteringReport = audioReport
            if verifyExport {
                do {
                    frames[0].exportVerification = try await EditorialDeliveryVerifier.verify(timeline: timeline, assets: assets, tracks: tracks, telemetry: telemetry, preview: frames, cacheURL: cacheURL, preferredVideoSources: stableSources, sourceWarnings: sourceWarnings)
                    frames[0].audioMasteringReport = frames[0].exportVerification?.encodedAudio
                } catch {
                    let value = error as NSError
                    throw EditorialGenerationError.unsatisfiedIntent("Delivery verify: \(value.domain) \(value.code): \(value.localizedDescription)")
                }
            }
        }
        return frames
    }
}

public protocol RenderedTimelineReviewing: Sendable {
    func review(timeline: Timeline, plan: StoryPlan, playback: TimelinePlayback, analyses: [AnalysisResult]) async -> EditorialReview
}

public struct RenderedEditorialReviewer: RenderedTimelineReviewing {
    public init() {}
    public func review(timeline: Timeline, plan: StoryPlan, playback: TimelinePlayback, analyses: [AnalysisResult]) async -> EditorialReview {
        let probes = await PerceptualRenderInspector().inspectAsync(playback: playback, timeline: timeline)
        return EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses, renderedFrames: probes, requireRenderedEvidence: true)
    }
}

enum EditorialRenderDependencies {
    // Track allocation is part of the render contract, including the audio
    // tracks used by connected clips. Old probes/mixes must be recomputed.
    // v5 also preserves requested source attenuation through export mastering.
    static let compositionVersion = 10
    static func signature(timeline: Timeline, assets: [MediaAsset], tracks: [LocalMusicTrack], telemetry: [UUID: TelemetrySummary] = [:], preferredVideoSources: [UUID: URL] = [:], visualOnly: Bool = false) -> String {
        var timeline = timeline
        if visualOnly {
            timeline.music = nil; timeline.adaptiveSoundtrack = nil; timeline.audioClips = []
            timeline.originalAudioVolume = 0; timeline.audioDucking = nil
            for index in timeline.items.indices { timeline.items[index].audioAdjustments = nil }
        }
        let used = Set(timeline.items.compactMap(\.assetID) + timeline.effectiveAudioClips.map(\.assetID))
        let hashes = assets.filter { used.contains($0.id) }.map { asset in
            "\(asset.id)|\(FrameCacheKey.sourceIdentity(url: asset.originalURL, contentHash: asset.contentHash))|" +
                (preferredVideoSources[asset.id].map { FrameCacheKey.sourceIdentity(url: $0, contentHash: "render-source") } ?? "original")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let telemetryKey = telemetry.keys.sorted { $0.uuidString < $1.uuidString }.map { id in
            var summary = telemetry[id]!
            let streams = summary.streams.sorted()
            // Codable represents a Set as an array; sortedKeys does not sort
            // its elements. Strip and encode it separately in stable order.
            summary.streams = []
            let data = (try? encoder.encode(summary)) ?? Data()
            let streamData = (try? encoder.encode(streams)) ?? Data()
            return id.uuidString + ":" + EditorialIdentity.hash((data + streamData).base64EncodedString())
        }.joined(separator: "|")
        let musicIDs = Set([timeline.music?.trackID].compactMap { $0 } + (timeline.effectiveAdaptiveSoundtrack?.segments.compactMap(\.directive.trackID) ?? []) + timeline.effectiveAudioClips.compactMap(\.trackID))
        let music = tracks.filter { musicIDs.contains($0.id) }.map { track in
            // URL.resourceValues caches metadata on the URL instance. Stat the
            // current file so replacing it invalidates the review immediately.
            let values = try? FileManager.default.attributesOfItem(atPath: track.localFileURL.path)
            let size = (values?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (values?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(track.id)|\(track.localFileURL.path)|\(size)|\(modified)|\(MusicStructureCache.contentIdentity(track.localFileURL))"
        }
        return EditorialIdentity.hash("composition-\(compositionVersion)|canvas-\(timeline.width)x\(timeline.height)|evidence-\(EditorialEvidenceVerifier.version)|" + EditorialRenderSignature.signature(timeline) + "|" + (hashes + music).sorted().joined(separator: "|") + "|telemetry:" + telemetryKey)
    }
}

public actor RenderedProbeCache {
    public static let version = 13
    private struct Record: Codable {
        var version: Int
        var signature: String
        var digest: String
        var payload: Data
    }
    private let directory: URL
    private let visualOnly: Bool
    public init(directory: URL, visualOnly: Bool = false) { self.directory = directory; self.visualOnly = visualOnly }
    private func signature(timeline: Timeline, assets: [MediaAsset], tracks: [LocalMusicTrack], telemetry: [UUID: TelemetrySummary], preferredVideoSources: [UUID: URL]) -> String {
        EditorialRenderDependencies.signature(timeline: timeline, assets: assets, tracks: tracks, telemetry: telemetry,
            preferredVideoSources: preferredVideoSources, visualOnly: visualOnly)
    }
    public func load(timeline: Timeline, assets: [MediaAsset], tracks: [LocalMusicTrack] = [], telemetry: [UUID: TelemetrySummary] = [:], preferredVideoSources: [UUID: URL] = [:]) -> [PerceptualRenderedFrameEvidence]? {
        let key = signature(timeline: timeline, assets: assets, tracks: tracks, telemetry: telemetry, preferredVideoSources: preferredVideoSources)
        func miss(_ reason: String) {
            PerformanceTrace.current?.event("cache.result", fields: ["cache": directory.lastPathComponent, "result": "miss", "reason": reason, "signature": key])
        }
        let url = directory.appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: url) else { miss("dependency-changed-or-absent"); return nil }
        guard let record = try? JSONDecoder().decode(Record.self, from: data), record.version == Self.version else { miss("incompatible-version"); return nil }
        guard record.signature == key, record.digest == EditorialIdentity.hash(record.payload.base64EncodedString()),
              var frames = try? JSONDecoder().decode([PerceptualRenderedFrameEvidence].self, from: record.payload), !frames.isEmpty else { miss("corrupt"); return nil }
        for index in frames.indices {
            if visualOnly {
                // Visual dependency equality is proven above. Rebind only these
                // pixels; never carry semantic, audio or MP4 receipts across edits.
                for titleIndex in frames[index].titleEvidence?.indices ?? 0..<0 {
                    frames[index].titleEvidence?[titleIndex].renderSignature = EditorialRenderSignature.signature(timeline)
                }
                frames[index].editorialClaims = nil
                frames[index].audioMasteringReport = nil
                frames[index].exportVerification = nil
                continue
            }
            guard var export = frames[index].exportVerification,
                  export.outputURL != nil || export.provenance.contains("RenderEngine control MP4") else { continue }
            guard export.videoDuration != nil, export.artifactIsCurrent,
                  export.outputURL.map({ url in export.artifactSHA256 == MusicStructureCache.contentIdentity(url) }) == true else { miss("artifact-changed-or-corrupt"); return nil }
            export.fileModifiedTime = export.fileModifiedTime ?? export.fileModified?.timeIntervalSince1970
            frames[index].exportVerification = export
        }
        PerformanceTrace.current?.event("cache.result", fields: ["cache": directory.lastPathComponent, "result": "hit", "signature": key])
        return frames
    }
    public func store(_ frames: [PerceptualRenderedFrameEvidence], timeline: Timeline, assets: [MediaAsset], tracks: [LocalMusicTrack] = [], telemetry: [UUID: TelemetrySummary] = [:], preferredVideoSources: [UUID: URL] = [:]) throws {
        try Task.checkCancellation()
        guard !frames.isEmpty, frames.allSatisfy({ $0.decodeFailed != true }) else { return }
        let key = signature(timeline: timeline, assets: assets, tracks: tracks, telemetry: telemetry, preferredVideoSources: preferredVideoSources)
        var frames = frames
        // Newly written receipts enroll an intact artifact in the current
        // integrity contract, including callers that omit optional hash fields.
        for index in frames.indices {
            guard var receipt = frames[index].exportVerification, let output = receipt.outputURL,
                  receipt.artifactIsCurrent else { continue }
            receipt.artifactSHA256 = MusicStructureCache.contentIdentity(output)
            receipt.artifactFileIdentity = FrameCacheKey.sourceIdentity(url: output, contentHash: "export")
            frames[index].exportVerification = receipt
        }
        let payload = try JSONEncoder().encode(frames)
        let record = Record(version: Self.version, signature: key, digest: EditorialIdentity.hash(payload.base64EncodedString()), payload: payload)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
    }
}

extension VeloEditPipeline {
    static func editorialRenderReview(timeline source: Timeline, plan inputPlan: StoryPlan, assets: [MediaAsset], analyses: [AnalysisResult], tracks: [LocalMusicTrack], telemetry: [UUID: TelemetrySummary], cacheURL: URL, prober: any EditorialRenderedProbing = LocalEditorialRenderedProber(), repairsRemaining suppliedRepairBudget: Int? = nil, events: [Event] = [], analyzeChapterTransitions: Bool = false, normalizePresentation: Bool = true) async -> Timeline {
        var plan = inputPlan
        // Materialize legacy/default framing before deriving the render
        // signature or decoding a preview. RenderEngine applies the same
        // migration before export; persisting it here makes preview, evidence
        // and delivery operate on one exact composition instead of allowing
        // nil adjustments to mean fill in one path and fit in another.
        var timeline = normalizePresentation ? AutomaticFramingPolicy.applying(to: source, assets: assets, analyses: analyses) : source
        if analyzeChapterTransitions {
            timeline = await NaturalChapterTransitionPlanner().applying(to: timeline, plan: plan, assets: assets, analyses: analyses)
        }
        // Structural repair can trim or remove shots. Re-anchor generated
        // headings before deriving a signature or inspecting pixels, keeping
        // any presentation that already received a rendered readability fix.
        if normalizePresentation { timeline = EditorialPresentationPolicy.ensuringChapterTitles(in: timeline, plan: plan, preserveExistingPresentation: true) }
        timeline = TitleTimelineAnchoring.reconcile(timeline)
        let cache = RenderedProbeCache(directory: cacheURL.appendingPathComponent("EditorialProbes"))
        // A deliberately sparse ranking probe is not production evidence and
        // must never poison the full-render cache used by the final winner.
        let isPreliminaryProbe = (prober as? LocalEditorialRenderedProber)?.verifyExport == false
        let stableSources = CachePaths(root: cacheURL.deletingLastPathComponent().deletingLastPathComponent()).stableRenderSources(for: assets)
        var frames = isPreliminaryProbe
            ? nil
            : await cache.load(timeline: timeline, assets: assets, tracks: tracks, telemetry: telemetry, preferredVideoSources: stableSources)
        var recoveryNotes: [String] = []
        if frames == nil {
            for attempt in 1...2 {
                do {
                    try Task.checkCancellation()
                    let probed = try await PerformanceTrace.measure(name: "render.review", fields: ["attempt": String(attempt), "signature": EditorialRenderSignature.signature(timeline)]) {
                      try await prober.frames(timeline: timeline, assets: assets, tracks: tracks, telemetry: telemetry, cacheURL: cacheURL)
                    }
                    try Task.checkCancellation()
                    frames = probed
                    if probed.isEmpty || probed.contains(where: { $0.decodeFailed == true }) {
                        recoveryNotes.append("Проверка кадров, попытка \(attempt): декодирование неполное")
                        continue
                    }
                    if !isPreliminaryProbe {
                        try? await cache.store(probed, timeline: timeline, assets: assets, tracks: tracks, telemetry: telemetry, preferredVideoSources: stableSources)
                    }
                    break
                } catch is CancellationError {
                    // Cancellation is a user action, not a recoverable fault.
                    return timeline
                } catch {
                    let value = error as NSError
                    recoveryNotes.append("Проверка кадров, попытка \(attempt): \(value.domain) \(value.code): \(value.localizedDescription)")
                    if Task.isCancelled { return timeline }
                }
            }
        }
        if var verifiedFrames = frames, !verifiedFrames.isEmpty,
           !verifiedFrames.contains(where: { !($0.editorialClaims?.isEmpty ?? true) }) {
            // Production semantic evidence is derived here because this layer
            // owns both the rendered probes and the actual plan/analysis used
            // to build the candidate. The low-level decoder stays reusable.
            verifiedFrames[0].editorialClaims = EditorialLocalSemanticVerifier.claims(
                timeline: timeline,
                plan: plan,
                analyses: analyses,
                frames: verifiedFrames,
                tracks: tracks
            )
            frames = verifiedFrames
        }
        let fallback = timeline.editorialReview?.conservativeFallback ?? false
        timeline.editorialReview = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses, renderedFrames: frames, requireRenderedEvidence: true, requireCompleteEvidence: !isPreliminaryProbe, musicTracks: tracks)
        timeline.editorialReview?.conservativeFallback = fallback
        for note in recoveryNotes {
            timeline.directorRun?.rejectedOperations.append(note)
            if frames?.isEmpty != false || frames?.contains(where: { $0.decodeFailed == true }) == true {
                timeline.editorialReview?.findings.append(.init(kind: .renderedEvidenceUnavailable, severity: 1, itemIDs: [], repair: .technical, reason: note))
            }
        }
        timeline.directorRun?.editorialReview = timeline.editorialReview
        // Removing a measured duplicate can expose another duplicate at the
        // newly-created cut. Give the verifier enough bounded passes to reach
        // a fixed point instead of stopping after two otherwise-successful
        // repairs. Every recursive pass below must change the render signature,
        // so this budget cannot turn into an unchanged retry loop.
        // A source-edge framing defect legitimately needs two distinct states:
        // fill/reframe -> full fit -> exclusion if the complete source remains
        // unsafe. Duplicate removal needs at most one state per primary.
        let repairsRemaining = min(6, suppliedRepairBudget ?? 6)
        if !Task.isCancelled, repairsRemaining > 0,
           timeline.editorialReview?.findings.contains(where: { [.unreadableTitle, .unsafeReframe, .hardDuplicate].contains($0.kind) }) == true {
            var repaired = timeline
            let unsafeIDs = Set(timeline.editorialReview?.findings.filter { $0.kind == .unsafeReframe }.flatMap(\.itemIDs) ?? [])
            var unrepairableUnsafeIDs = Set<UUID>()
            for index in repaired.items.indices where unsafeIDs.contains(repaired.items[index].id) {
                var adjustments = repaired.items[index].effectiveVideoAdjustments
                if adjustments.crop == .fit && adjustments.subjectReframe == nil {
                    // The complete source frame was already shown and the
                    // rendered detector still sees an unsafe body cut. Pixels
                    // outside the source do not exist, so this shot cannot be
                    // repaired by another framing pass.
                    unrepairableUnsafeIDs.insert(repaired.items[index].id)
                    continue
                }
                // Restoring a nil subject plan still leaves a wide source in
                // center-crop fill. The independent rendered detector has
                // already proved that this loses a person, so the safe repair
                // is an explicit full-frame fit.
                adjustments.crop = .fit
                adjustments.subjectReframe = nil
                repaired.items[index].videoAdjustments = adjustments
                repaired.items[index].explanation.append("Rendered safety repair: сохранён полный исходный кадр")
            }
            let duplicateIDs = Set(timeline.editorialReview?.findings.filter { $0.kind == .hardDuplicate }.flatMap(\.itemIDs) ?? [])
            let removalIDs = duplicateIDs.union(unrepairableUnsafeIDs)
            if !removalIDs.isEmpty {
                var pendingDuplicateIDs = removalIDs
                var removedCandidateIDs = Set<UUID>()
                let maximumStructuralPasses = max(1, repaired.items.filter { $0.overlay == nil && $0.kind != .title }.count)
                for _ in 0..<maximumStructuralPasses {
                    removedCandidateIDs.formUnion(repaired.items.filter { pendingDuplicateIDs.contains($0.id) }.compactMap(\.candidateID))
                    let removedPrimaryIDs = Set(repaired.items.filter { pendingDuplicateIDs.contains($0.id) && $0.overlay == nil }.map(\.id))
                    let previousCount = repaired.items.count
                    repaired.items.removeAll { item in
                        pendingDuplicateIDs.contains(item.id) || item.overlay?.baseItemID.map(removedPrimaryIDs.contains) == true
                    }
                    guard repaired.items.count < previousCount else { break }
                    repaired.items = TimelineTiming.retimed(repaired.items)
                    // The measured removal changes neighbourhoods. Eliminate
                    // any newly-exposed deterministic shot-family duplicate
                    // before paying for another full control export.
                    let structural = EditorialQualityGate().review(timeline: repaired, plan: plan, analyses: analyses)
                    pendingDuplicateIDs = Set(structural.findings.filter { $0.kind == .hardDuplicate }.flatMap(\.itemIDs))
                    if pendingDuplicateIDs.isEmpty { break }
                }
                if var beatPlan = repaired.editorialBeatPlan, !removedCandidateIDs.isEmpty {
                    beatPlan.beats.removeAll { removedCandidateIDs.contains($0.candidateID) }
                    beatPlan.reasons.append(EditorialContentBudgetPolicy.renderedSafetyRepairMarker)
                    repaired.editorialBeatPlan = beatPlan
                }
                // Recover only unused, analysed source range on surviving
                // unique clips. This keeps the honest content floor without
                // loops, duplicated shots or manufactured freeze-frame padding.
                let requiredDuration = min(timeline.duration, plan.contentBudget?.budget.safeRange.lowerBound ?? timeline.duration)
                var missingDuration = max(0, requiredDuration - repaired.duration)
                if missingDuration > 0.000_1 {
                    let units = Dictionary(uniqueKeysWithValues: EditorialAnalysisContext(analyses: analyses).units.map { ($0.id, $0) })
                    for index in repaired.items.indices.reversed() where missingDuration > 0.000_1 && repaired.items[index].overlay == nil && repaired.items[index].kind != .title {
                        guard let candidateID = repaired.items[index].candidateID,
                              let unit = units[candidateID] else { continue }
                        let candidate = unit.candidate
                        let availableInCandidate = max(0, candidate.sourceStart + candidate.sourceDuration - repaired.items[index].sourceStart - repaired.items[index].sourceDuration)
                        let availableInUsableRange = max(0, unit.usableDuration - repaired.items[index].sourceDuration)
                        let availableSource = min(availableInCandidate, availableInUsableRange)
                        let sourcePerTimelineSecond = repaired.items[index].sourceDuration / max(0.000_1, repaired.items[index].timelineDuration)
                        let addedTimeline = min(missingDuration, availableSource / max(0.000_1, sourcePerTimelineSecond))
                        guard addedTimeline > 0.000_1 else { continue }
                        repaired.items[index].sourceDuration += addedTimeline * sourcePerTimelineSecond
                        repaired.items[index].timelineDuration += addedTimeline
                        repaired.items[index].explanation.append("Content-budget repair: использован дополнительный подтверждённый source range")
                        missingDuration -= addedTimeline
                    }
                    repaired.items = TimelineTiming.retimed(repaired.items)
                }
                if var beatPlan = repaired.editorialBeatPlan {
                    let primaryByCandidate: [UUID: TimelineItem] = Dictionary(uniqueKeysWithValues: repaired.items.compactMap { item -> (UUID, TimelineItem)? in
                        guard item.overlay == nil, item.kind != .title, let candidateID = item.candidateID else { return nil }
                        return (candidateID, item)
                    })
                    for index in beatPlan.beats.indices {
                        if let item = primaryByCandidate[beatPlan.beats[index].candidateID] {
                            beatPlan.beats[index].allocatedDuration = item.timelineDuration
                        }
                    }
                    repaired.editorialBeatPlan = beatPlan
                }
                if repaired.editorialBeatPlan?.reasons.contains(AutomaticEditorialAssembly.marker) == true {
                    let assembled = AutomaticEditorialAssembly.prepare(timeline: repaired, plan: plan, analyses: analyses, events: events, assets: assets, excluded: removedCandidateIDs)
                    repaired = assembled.timeline
                    plan = assembled.plan
                }
                let survivingIDs = Set(repaired.items.map(\.id))
                repaired.transitionItems = repaired.effectiveTransitionItems.filter {
                    survivingIDs.contains($0.incomingClipID) && survivingIDs.contains($0.outgoingClipID)
                }
                if let firstPrimary = repaired.items.firstIndex(where: { $0.overlay == nil }) {
                    repaired.items[firstPrimary].transition = nil
                }
                // A duration-bound multi-track soundtrack is no longer valid
                // after a redundant shot is removed. Keep the selected music
                // itself and let normal single-track looping cover the result.
                repaired.adaptiveSoundtrack = nil
                repaired = await applyingAdaptiveSoundtrack(to: repaired, plan: plan, tracks: tracks, analyses: analyses)
                let newDuration = repaired.duration
                repaired.titleItems = repaired.effectiveTitleItems.compactMap { title in
                    guard newDuration >= 0.05 else { return nil }
                    var value = title
                    value.startTime = min(value.startTime, max(0, newDuration - value.duration))
                    value.duration = min(value.duration, max(0.05, newDuration - value.startTime))
                    return value
                }
            }
            if timeline.editorialReview?.findings.contains(where: { $0.kind == .unreadableTitle }) == true {
                let failedIDs = Set(timeline.editorialReview?.findings.filter { $0.kind == .unreadableTitle }.flatMap(\.itemIDs) ?? [])
                repaired.titleItems = timeline.effectiveTitleItems.map { title in
                    failedIDs.contains(title.id) ? EditorialPresentationPolicy.hardeningReadability(title) : title
                }
            }
            PerformanceTrace.current?.event("repair.proposed", fields: ["before": EditorialRenderSignature.signature(timeline),
                "after": EditorialRenderSignature.signature(repaired), "remaining": String(repairsRemaining),
                "reason": timeline.editorialReview?.findings.map { $0.kind.rawValue }.joined(separator: ",") ?? ""])

            guard AutomaticFilmDelivery.preservesDelivery(repaired, original: timeline, plan: plan),
                  EditorialRenderSignature.signature(repaired) != EditorialRenderSignature.signature(timeline) else { return timeline }
            if let store = AutonomousJobContext.store,
               (try? await store.claimCompositionRepair(signature: EditorialRenderSignature.signature(repaired))) != true { return timeline }
            repaired = await editorialRenderReview(timeline: repaired, plan: plan, assets: assets, analyses: analyses, tracks: tracks, telemetry: telemetry, cacheURL: cacheURL, prober: prober, repairsRemaining: repairsRemaining - 1, events: events, analyzeChapterTransitions: analyzeChapterTransitions)
            if let before = timeline.editorialReview, let after = repaired.editorialReview,
               after.criticalCount < before.criticalCount ||
               after.criticalCount == before.criticalCount &&
                   (after.blockingUnknowns.count < before.blockingUnknowns.count || after.highCount < before.highCount || after.candidateEligible) {
                return repaired
            }
        }
        if ProcessInfo.processInfo.environment["VELOEDIT_EDITORIAL_DIAGNOSTICS"] == "1",
           timeline.editorialReview?.candidateEligible != true,
           let data = try? JSONEncoder().encode(timeline) {
            let directory = cacheURL.appendingPathComponent("EditorialRejected", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let signature = EditorialRenderSignature.signature(timeline)
            try? data.write(to: directory.appendingPathComponent(signature + ".json"), options: .atomic)
        }
        return timeline
    }
}
