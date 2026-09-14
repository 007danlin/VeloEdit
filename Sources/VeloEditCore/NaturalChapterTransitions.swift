import Foundation

public enum NaturalChapterTransitionKind: String, Codable, Hashable, Sendable {
    case occlusion, motion, dynamicMotion, composition, ordinary
}

/// Evidence is persisted with the incoming edit for inspection/recovery, and
/// is invalidated when either source range, framing or adjacent clip changes.
public struct NaturalChapterTransitionEvidence: Codable, Hashable, Sendable {
    public var kind: NaturalChapterTransitionKind
    public var inputSignature: String
    public var sampledFrameCount: Int
    public var outgoingOffset: Double
    public var incomingOffset: Double
    public var method: String
    public var editSignature: String? = nil
    public var coveredFrameTimes: [Double]? = nil
    public var darkFrameTimes: [Double]? = nil
}

/// Final AI Director pass. A natural transition is a precisely placed cut
/// through source motion/coverage/shape, with no synthetic mask or preset.
/// Clip durations and the film's clock remain unchanged.
struct NaturalChapterTransitionPlanner: Sendable {
    var prober: any NaturalTransitionFrameProbing = LocalNaturalTransitionFrameProber()
    static let version = "Natural chapter transitions v1"

    func applying(to source: Timeline, plan: StoryPlan, assets: [MediaAsset], analyses: [AnalysisResult]) async -> Timeline {
        let prompt = plan.prompt.lowercased()
        guard !["без переход", "убери переход", "никаких переход", "no transition", "without transition", "только прямые склейки"].contains(where: prompt.contains) else { return source }
        var timeline = source
        let byAsset = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let candidates = Dictionary(uniqueKeysWithValues: analyses.flatMap(\.directorCandidates).map { ($0.id, $0) })
        let blocks = EditorialPresentationPolicy.chapterBlocks(in: source, plan: plan)
        let majorIncomingIDs = Set(blocks.indices.dropFirst().compactMap { index -> UUID? in
            isMajorBoundary(blocks[index - 1], blocks[index]) ? blocks[index].items.first?.id : nil
        })
        for index in timeline.items.indices {
            if timeline.items[index].incomingEditDecision?.naturalTransition != nil,
               !majorIncomingIDs.contains(timeline.items[index].id) {
                timeline.items[index].incomingEditDecision = nil
            }
        }
        var lastNaturalBoundary = -Double.greatestFiniteMagnitude
        // The limit bounds work on very long archives as well as visual density.
        var inspected = 0
        for index in blocks.indices.dropFirst() {
            if Task.isCancelled { return source }
            let previousBlock = blocks[index - 1], nextBlock = blocks[index]
            guard isMajorBoundary(previousBlock, nextBlock),
                  let outgoingID = previousBlock.items.last?.id, let incomingID = nextBlock.items.first?.id,
                  let li = timeline.items.firstIndex(where: { $0.id == outgoingID }),
                  let ri = timeline.items.firstIndex(where: { $0.id == incomingID }) else { continue }
            let left = timeline.items[li], right = timeline.items[ri]
            guard eligible(left), eligible(right),
                  abs(left.timelineStart + left.timelineDuration - right.timelineStart) < 0.001,
                  let la = left.assetID.flatMap({ byAsset[$0] }), let ra = right.assetID.flatMap({ byAsset[$0] }),
                  let lc = left.candidateID.flatMap({ candidates[$0] }), let rc = right.candidateID.flatMap({ candidates[$0] }),
                  !lc.excluded, !rc.excluded, !lc.locked, !rc.locked,
                  !timeline.items.contains(where: { $0.overlay != nil && $0.timelineStart < right.timelineStart + 0.4 && $0.timelineStart + $0.timelineDuration > right.timelineStart - 0.4 }),
                  !timeline.effectiveEffects.contains(where: { $0.enabled && $0.startTime < right.timelineStart + 0.4 && $0.startTime + $0.duration > right.timelineStart - 0.4 }),
                  timeline.effectiveAudioClips.isEmpty else { continue }
            let inputSignature = signature(left, right, assets: [la, ra], timeline: timeline)
            if let prior = right.incomingEditDecision?.naturalTransition, prior.inputSignature == inputSignature, prior.sampledFrameCount >= 8 {
                if prior.kind != .ordinary { lastNaturalBoundary = right.timelineStart }
                continue
            }
            guard inspected < 24 else { continue }
            inspected += 1
            // A disabled transition is an explicit edit. Do not override it.
            if timeline.effectiveTransitionItems.contains(where: { $0.incomingClipID == right.id && !$0.enabled }) { continue }
            let fps = min(120, max(10, timeline.frameRate))
            let hasMatchedEntry = left.incomingEditDecision?.naturalTransition.map { $0.kind != .ordinary } == true
            let leftStarts = hasMatchedEntry ? [left.sourceStart] : starts(for: left, candidate: lc, asset: la, in: timeline, fps: fps)
            let rightStarts = starts(for: right, candidate: rc, asset: ra, in: timeline, fps: fps)
            let leftTimes = times(starts: leftStarts, duration: left.sourceDuration, outgoing: true, fps: fps)
            let rightTimes = times(starts: rightStarts, duration: right.sourceDuration, outgoing: false, fps: fps)
            var count = 0
            var sampledTail: [NaturalTransitionFrame] = [], sampledHead: [NaturalTransitionFrame] = []
            var best: (match: NaturalTransitionMatch, left: Double, right: Double, score: Double)?
            var fallbackReason = "На границе частей нет убедительного совпадения изображения и движения; сохранена аккуратная склейка"
            do {
                // Decode sequentially: AVFoundation shares its media services.
                let tailFrames = try await prober.frames(asset: la, times: leftTimes, frameRate: fps)
                let headFrames = try await prober.frames(asset: ra, times: rightTimes, frameRate: fps)
                sampledTail = tailFrames; sampledHead = headFrames
                count = tailFrames.count + headFrames.count
                try Task.checkCancellation()
                for ls in leftStarts { for rs in rightStarts {
                    let tail = window(tailFrames, start: ls, duration: left.sourceDuration, outgoing: true, fps: fps)
                    let head = window(headFrames, start: rs, duration: right.sourceDuration, outgoing: false, fps: fps)
                    guard let a = tail.last, let b = head.first,
                          abs(a.aspectRatio / (Double(timeline.width) / Double(max(1, timeline.height))) - 1) < 0.03,
                          abs(a.aspectRatio / b.aspectRatio - 1) < 0.03,
                          let match = NaturalTransitionVision.match(tail: tail, head: head) else { continue }
                    let score = match.confidence - (abs(ls - left.sourceStart) + abs(rs - right.sourceStart)) * 0.06
                    if best == nil || score > best!.score { best = (match, ls, rs, score) }
                } }
            } catch is CancellationError { return source }
            catch { fallbackReason = "Точные кадры границы недоступны; сохранена обычная склейка без предположений о визуальном совпадении" }
            if right.timelineStart - lastNaturalBoundary < 8 {
                best = nil
                fallbackReason = "Соседние части расположены близко; обычная склейка сохраняет сдержанность монтажа"
            }
            var kind = NaturalChapterTransitionKind.ordinary
            if let best {
                timeline.items[li].sourceStart = best.left
                timeline.items[ri].sourceStart = best.right
                timeline.items[ri].transition = nil
                timeline.transitionItems = timeline.effectiveTransitionItems.filter { $0.incomingClipID != right.id }
                timeline.items[ri].incomingEditDecision = .init(choice: .cut, motivation: best.match.reason, confidence: best.match.confidence)
                kind = best.match.kind
                lastNaturalBoundary = right.timelineStart
            } else {
                // Preserve a normal existing dissolve/fade. Exact-duration
                // assembly already uses cuts and must not acquire overlaps.
                let style = right.transition.flatMap(TransitionStyle.init(rawValue:))
                let ordinary = style == .crossDissolve || style == .fadeThroughBlack
                if !ordinary {
                    timeline.items[ri].transition = nil
                    timeline.transitionItems = timeline.effectiveTransitionItems.filter { $0.incomingClipID != right.id }
                }
                timeline.items[ri].incomingEditDecision = .init(choice: ordinary ? .transition : .cut,
                    motivation: fallbackReason, confidence: 0.9, transitionStyle: ordinary ? style : nil)
            }
            var evidence = NaturalChapterTransitionEvidence(kind: kind,
                inputSignature: signature(timeline.items[li], timeline.items[ri], assets: [la, ra], timeline: timeline),
                sampledFrameCount: count, outgoingOffset: timeline.items[li].sourceStart - left.sourceStart,
                incomingOffset: timeline.items[ri].sourceStart - right.sourceStart,
                method: Self.version + "; oriented source frames; temporal coverage, block motion and spatial correlation")
            if kind == .occlusion {
                let finalLeft = timeline.items[li], finalRight = timeline.items[ri]
                let tail = window(sampledTail, start: finalLeft.sourceStart, duration: finalLeft.sourceDuration, outgoing: true, fps: fps)
                let head = window(sampledHead, start: finalRight.sourceStart, duration: finalRight.sourceDuration, outgoing: false, fps: fps)
                let samples = tail.map { ($0, finalLeft.timelineStart + $0.time - finalLeft.sourceStart) }
                    + head.map { ($0, finalRight.timelineStart + $0.time - finalRight.sourceStart) }
                evidence.editSignature = Self.editSignature(finalLeft, finalRight, timeline: timeline)
                evidence.coveredFrameTimes = samples.filter { NaturalTransitionVision.isCovered($0.0) }.map(\.1).sorted()
                evidence.darkFrameTimes = samples.filter {
                    FrameQualityInspector.assess(luma: $0.0.luma.map { UInt8(min(255, max(0, $0 * 255))) }).isBlack
                }.map(\.1).sorted()
            }
            timeline.items[ri].incomingEditDecision?.naturalTransition = evidence
        }
        return timeline
    }

    private func isMajorBoundary(_ a: EditorialPresentationPolicy.ChapterBlock, _ b: EditorialPresentationPolicy.ChapterBlock) -> Bool {
        guard a.end - a.start >= 3, b.end - b.start >= 3 else { return false }
        if let x = a.eventID, let y = b.eventID, x != y { return true }
        // Narrative roles (setup/climax/reaction) are not semantic parts. A
        // scene split with the same activity label alone is insufficient.
        guard a.text != b.text, !SmartTitleEngine.isPlaceholderTitle(a.text), !SmartTitleEngine.isPlaceholderTitle(b.text),
              !a.text.hasPrefix("Часть "), !b.text.hasPrefix("Часть ") else { return false }
        return a.sceneID != b.sceneID || a.sceneID == nil || b.sceneID == nil
    }

    private func eligible(_ item: TimelineItem) -> Bool {
        guard item.kind == .video, !item.locked, item.overlay == nil, !item.isFreezeFrame, !item.isReversed,
              item.speedRamp == nil, abs(item.speed - 1) < 0.001, item.effect == nil,
              item.sourceStart.isFinite, item.sourceDuration.isFinite, item.timelineDuration.isFinite,
              item.sourceDuration >= 1.2, abs(item.timelineDuration - item.sourceDuration) < 0.001 else { return false }
        // Analysing untransformed source pixels is only valid for neutral
        // framing. Other edits keep their existing transition.
        guard let v = item.videoAdjustments else { return true }
        var neutral = VideoAdjustments(crop: v.crop)
        // Optional nil defaults in legacy projects mean neutral as well.
        neutral.exposure = v.exposure == nil ? nil : 0; neutral.highlights = v.highlights == nil ? nil : 0
        neutral.shadows = v.shadows == nil ? nil : 0; neutral.vignette = v.vignette == nil ? nil : 0
        neutral.grain = v.grain == nil ? nil : 0; neutral.tint = v.tint == nil ? nil : 0
        neutral.filterIntensity = v.filterIntensity == nil ? nil : 1; neutral.stabilization = v.stabilization == nil ? nil : 0
        neutral.rollingShutterCorrection = v.rollingShutterCorrection == nil ? nil : false
        neutral.smoothSlowMotion = v.smoothSlowMotion == nil ? nil : false
        neutral.sharpening = v.sharpening == nil ? nil : 0; neutral.denoise = v.denoise == nil ? nil : 0; neutral.blur = v.blur == nil ? nil : 0
        return v == neutral
    }

    func starts(for item: TimelineItem, candidate: Candidate, asset: MediaAsset, in timeline: Timeline, fps: Double) -> [Double] {
        // Dialogue/subtitles, action completion and telemetry stay aligned.
        // Unknown temporal evidence permits inspection at the current edit,
        // but does not authorize moving the selected source range.
        guard let evidence = candidate.insights?.editorialEvidence, evidence.confidence >= 0.55,
              candidate.insights?.speech == nil, candidate.momentBoundary == nil,
              !evidence.hasProgression, item.telemetryOverlay == nil,
              !timeline.effectiveTelemetryItems.contains(where: { $0.linkedAssetID == asset.id || $0.targetClipID == item.id }),
              !timeline.effectiveTitleItems.contains(where: { [.subtitle, .automaticSubtitles, .wordLevelCaptions].contains($0.kind) }) else { return [item.sourceStart] }
        let lower = max(candidate.sourceStart, evidence.usableRange.start)
        let upper = min(candidate.sourceStart + candidate.sourceDuration, evidence.usableRange.end, asset.metadata.duration ?? .greatestFiniteMagnitude)
        var starts = [item.sourceStart]
        for offset in [-0.4, -0.2, 0.2, 0.4] {
            let value = ((item.sourceStart + offset) * fps).rounded() / fps
            guard value >= lower, value + item.sourceDuration <= upper else { continue }
            let repeats = timeline.items.contains { other in
                other.id != item.id && other.overlay == nil && other.assetID == item.assetID
                    && min(value + item.sourceDuration, other.sourceStart + other.sourceDuration) - max(value, other.sourceStart) > 0.001
            }
            if !repeats { starts.append(value) }
        }
        return starts
    }

    private func times(starts: [Double], duration: Double, outgoing: Bool, fps: Double) -> [Double] {
        Array(Set(starts.flatMap { windowTimes(start: $0, duration: duration, outgoing: outgoing, fps: fps) })).sorted()
    }
    private func windowTimes(start: Double, duration: Double, outgoing: Bool, fps: Double) -> [Double] {
        let step = max(1, (fps * 0.1).rounded()) / fps
        let edge = outgoing ? start + duration - 1 / fps : start
        return (0..<4).map { edge + Double(outgoing ? $0 - 3 : $0) * step }
    }
    private func window(_ frames: [NaturalTransitionFrame], start: Double, duration: Double, outgoing: Bool, fps: Double) -> [NaturalTransitionFrame] {
        windowTimes(start: start, duration: duration, outgoing: outgoing, fps: fps).compactMap { t in frames.first { abs($0.time - t) < 0.001 } }
    }
    private func signature(_ left: TimelineItem, _ right: TimelineItem, assets: [MediaAsset], timeline: Timeline) -> String {
        EditorialIdentity.uuid(Self.editSignature(left, right, timeline: timeline) + assets.map(\.contentHash).joined()).uuidString
    }
    private static func editSignature(_ left: TimelineItem, _ right: TimelineItem, timeline: Timeline) -> String {
        let clips = [left, right].map { item -> TimelineItem in
            var copy = item
            copy.incomingEditDecision = nil; copy.explanation = []
            return copy
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(clips)) ?? Data()
        let transitions = timeline.effectiveTransitionItems.filter { $0.incomingClipID == right.id }
        let transitionData = (try? encoder.encode(transitions)) ?? Data()
        let aspect = Int((Double(timeline.width) / Double(max(1, timeline.height)) * 10_000).rounded())
        return EditorialIdentity.uuid(Self.version + "aspect-\(aspect)@\(timeline.frameRate)" + data.base64EncodedString() + transitionData.base64EncodedString()).uuidString
    }

    /// Only measured source coverage may explain an empty-looking rendered
    /// frame. Never exempts decoder failure, other parts of the shot, stale
    /// source ranges or an arbitrary dark frame elsewhere in the film.
    static func expectsCoveredSource(at time: Double, timeline: Timeline, darkOnly: Bool = false) -> Bool {
        let items = timeline.items.filter { $0.overlay == nil }.sorted { $0.timelineStart < $1.timelineStart }
        for index in items.indices.dropFirst() {
            let left = items[index - 1], right = items[index]
            guard abs(time - right.timelineStart) <= 0.31,
                  !timeline.effectiveEffects.contains(where: { $0.enabled && time >= $0.startTime && time < $0.endTime }),
                  !timeline.items.contains(where: { $0.overlay != nil && time >= $0.timelineStart && time < $0.timelineStart + $0.timelineDuration }),
                  let evidence = right.incomingEditDecision?.naturalTransition,
                  evidence.kind == .occlusion, evidence.sampledFrameCount >= 8,
                  evidence.editSignature == editSignature(left, right, timeline: timeline) else { continue }
            let times = (darkOnly ? evidence.darkFrameTimes : evidence.coveredFrameTimes) ?? []
            if times.contains(where: { abs(time - $0) <= 0.5 / max(1, timeline.frameRate) + 0.001 }) { return true }
            if zip(times, times.dropFirst()).contains(where: { $1 - $0 <= 0.11 && time >= $0 && time <= $1 }) { return true }
        }
        return false
    }
}
