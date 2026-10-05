import Foundation
import CryptoKit

public struct EventDiscoveryResult: Sendable {
    public var events: [Event]
    public var diagnostics: EventRunDiagnostics
    public var sourceMap: SourceMap

    public init(events: [Event], diagnostics: EventRunDiagnostics, sourceMap: SourceMap = .empty) {
        self.events = events
        self.diagnostics = diagnostics
        self.sourceMap = sourceMap
    }
}

public enum EventDeviceIdentity {
    public static func key(for asset: MediaAsset) -> String {
        let make = asset.metadata.cameraMake?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = asset.metadata.cameraModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = [make, model].compactMap { value in value?.isEmpty == false ? value : nil }.joined(separator: " ")
        if !known.isEmpty { return known.lowercased() }
        let name = asset.displayName.lowercased()
        if name.contains("gopro") || name.hasPrefix("gopr") || name.hasPrefix("gh") || name.hasPrefix("gx")
            || name.range(of: #"^gp\d{6}"#, options: .regularExpression) != nil { return "gopro" }
        if name.contains("dji") { return "dji" }
        if name.contains("iphone") || name.hasPrefix("img_") { return "iphone" }
        return "unknown:\(asset.originalURL.pathExtension.lowercased())"
    }
}

/// Offline, deterministic archive-level reasoning. It fuses temporal, spatial,
/// visual, semantic, subject, activity, audio and device evidence before Story
/// Engine sees any individual highlight.
public struct EventIntelligenceEngine: Sendable {
    public var maximumMultiDayGap: TimeInterval
    public var mergeThreshold: Double

    public init(maximumMultiDayGap: TimeInterval = 4 * 86_400, mergeThreshold: Double = 0.58) {
        self.maximumMultiDayGap = max(6 * 3_600, maximumMultiDayGap)
        self.mergeThreshold = mergeThreshold.clamped01
    }

    public func discover(assets: [MediaAsset], analyses: [AnalysisResult], sourceMap providedSourceMap: SourceMap? = nil) -> EventDiscoveryResult {
        let assets = assets.map { asset in
            var copy = asset
            copy.metadata = MediaCaptureClock.metadata(for: asset)
            return copy
        }
        let analysesByAsset = Dictionary(uniqueKeysWithValues: analyses.map { ($0.assetID, $0) })
        let sourceMap = providedSourceMap ?? SourceTimelineAnalyzer().analyze(assets: assets, analyses: analyses)
        let sourceOrder = Dictionary(uniqueKeysWithValues: sourceMap.entries.map { ($0.assetID, $0.order) })
        var observations = assets
            .filter { !$0.excluded && !$0.missing }
            .map { Observation(asset: $0, analysis: analysesByAsset[$0.id], sourceOrder: sourceOrder[$0.id]) }
        guard !observations.isEmpty else {
            return EventDiscoveryResult(
                events: [],
                diagnostics: EventRunDiagnostics(
                    eventsDetected: 0,
                    eventConfidence: [:],
                    eventTitles: [],
                    eventDateRanges: [],
                    eventOrder: [],
                    sceneCount: 0,
                    crossDeviceMatches: 0,
                    sourceMap: sourceMap
                ),
                sourceMap: sourceMap
            )
        }

        let offsets = estimateDeviceTimeOffsets(observations)
        for index in observations.indices {
            let offset = offsets[observations[index].device, default: 0]
            observations[index].normalizedDate = observations[index].rawDate?.addingTimeInterval(-offset)
        }
        observations.sort(by: chronologicalObservationOrder)

        // Candidate features depend only on the candidate, not on the pair.
        // Building this index for every pair repeats the same text analysis
        // thousands of times for a moderately sized archive.
        let sceneIndex = SemanticSceneIndex(candidates: observations.flatMap { $0.candidates.prefix(6) })

        var union = UnionFind(count: observations.count)
        var acceptedLinks: [PairLink] = []
        var splitBoundaries = 0
        for first in observations.indices {
            var second = first + 1
            while second < observations.count {
                if let left = observations[first].normalizedDate,
                   let right = observations[second].normalizedDate,
                   right.timeIntervalSince(left) > maximumMultiDayGap {
                    break
                }
                let metrics = pairMetrics(observations[first], observations[second], sceneIndex: sceneIndex)
                if shouldMerge(metrics, first: observations[first], second: observations[second]) {
                    union.join(first, second)
                    acceptedLinks.append(PairLink(first: first, second: second, metrics: metrics))
                } else if second == first + 1,
                          sameLocalDay(observations[first].normalizedDate, observations[second].normalizedDate),
                          metrics.temporal > 0.08 {
                    splitBoundaries += 1
                }
                second += 1
            }
        }

        var roots: [Int: Int] = [:]
        for index in observations.indices { roots[index] = union.root(index) }
        // Similar content later in the archive is a new visit. Union-find
        // similarity must not pull it back through an intervening activity.
        var grouped: [[Int]] = []
        for index in observations.indices {
            if let previous = grouped.last?.last,
               roots[previous] == roots[index] {
                grouped[grouped.count - 1].append(index)
            } else { grouped.append([index]) }
        }
        var events = grouped.map { indices in
            makeEvent(indices.sorted(), observations: observations, links: acceptedLinks, offsets: offsets, sourceMap: sourceMap)
        }
        let sourceRank = Dictionary(uniqueKeysWithValues: sourceMap.entries.map { ($0.assetID, $0.order) })
        events.sort {
            let lhsRank = $0.assetIDs.compactMap { sourceRank[$0] }.min() ?? Int.max
            let rhsRank = $1.assetIDs.compactMap { sourceRank[$0] }.min() ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhs = $0.startDate ?? .distantFuture
            let rhs = $1.startDate ?? .distantFuture
            if lhs != rhs { return lhs < rhs }
            return $0.title < $1.title
        }

        let reasons = Dictionary(uniqueKeysWithValues: events.map { event in
            (event.id.uuidString, (event.evidence ?? []).map(\.explanation))
        })
        let diagnostics = EventRunDiagnostics(
            eventsDetected: events.count,
            eventsMerged: max(0, observations.count - events.count),
            eventsSplit: splitBoundaries,
            eventConfidence: Dictionary(uniqueKeysWithValues: events.map { ($0.id.uuidString, $0.effectiveConfidence) }),
            eventTitles: events.map(\.title),
            eventDateRanges: events.map { EventDateRangeSummary(eventID: $0.id, title: $0.title, startDate: $0.startDate, endDate: $0.endDate) },
            eventOrder: events.map(\.id),
            sceneCount: events.reduce(0) { $0 + $1.effectiveScenes.count },
            crossDeviceMatches: events.reduce(0) { $0 + $1.effectiveCrossDeviceMatchCount },
            deviceTimeOffsets: offsets,
            clusteringReasons: reasons,
            sourceMap: sourceMap
        )
        return EventDiscoveryResult(events: events, diagnostics: diagnostics, sourceMap: sourceMap)
    }

    private func estimateDeviceTimeOffsets(_ observations: [Observation]) -> [String: Double] {
        // Similar scenery/GPS or a single nearby timestamp cannot distinguish
        // clock skew from two different moments at the same place. Preserve
        // camera clocks until calibrated synchronization evidence is available.
        [:]
    }

    private func shouldMerge(_ metrics: PairMetrics, first: Observation, second: Observation) -> Bool {
        if metrics.hardSplit { return false }
        let gap = dateGap(first.normalizedDate, second.normalizedDate)
        if metrics.activityCompatibility == .incompatible && !metrics.decisiveSameTakeEvidence {
            // Different activities may be consecutive chapters of one outing.
            // Keep that macro event only when archive evidence independently
            // confirms continuity; a shared semanticEventID is never enough.
            let sameDeviceContinuity = first.device == second.device
                && gap <= 15 * 60
                && metrics.temporal >= 0.82
            let sourceContinuity = (metrics.filename ?? 0) >= 0.78 && gap <= 12 * 3_600
            let spatialContinuity = metrics.temporal >= 0.78 && (metrics.gps ?? 0) >= 0.68
            guard sameDeviceContinuity || sourceContinuity || spatialContinuity else { return false }
        }
        if (metrics.filename ?? 0) >= 0.95, first.device == second.device, gap <= 12 * 3_600 {
            return true
        }
        if first.filenameIdentity.recordingGroup != nil,
           first.filenameIdentity.recordingGroup == second.filenameIdentity.recordingGroup,
           first.asset.kind != second.asset.kind,
           (metrics.filename ?? 0) >= 0.88,
           gap <= 12 * 3_600 {
            return true
        }
        if (metrics.filename ?? 0) >= 0.85,
           first.filenameIdentity.family == second.filenameIdentity.family,
           ["iphone", "phone"].contains(first.filenameIdentity.family ?? ""),
           first.asset.kind != second.asset.kind,
           gap <= 12 * 3_600 {
            return true
        }
        if min(first.dateConfidence, second.dateConfidence) < 0.35, metrics.gps == nil {
            // Files imported together frequently share broad words such as
            // "action" or "people". With no trustworthy capture clock or GPS,
            // require a precise P2 semantic-event match plus an independent
            // visual/subject/audio confirmation.
            let preciseSemanticMatch = metrics.corroboratedSemanticEventID
            let corroboration = max(metrics.visual ?? 0, metrics.people ?? 0, metrics.audio ?? 0)
            guard preciseSemanticMatch && corroboration >= 0.62 else { return false }
        }
        let support = [metrics.gps, metrics.visual, metrics.semantic, metrics.activity, metrics.people, metrics.audio, metrics.filename]
            .compactMap { $0 }
            .max() ?? 0
        if support == 0 {
            // Only immediate camera chunks may merge on time alone. A same-day
            // timestamp never becomes sufficient evidence for a broad event;
            // import/modification dates are too weak even for that exception.
            return gap <= 90 && first.device == second.device
                && min(first.dateConfidence, second.dateConfidence) >= 0.55
        }
        if gap <= 15 * 60, first.device != second.device,
           max(metrics.gps ?? 0, metrics.semantic ?? 0, metrics.visual ?? 0) >= 0.38 {
            return metrics.score >= mergeThreshold - 0.08
        }
        if gap > 18 * 3_600 {
            return metrics.score >= mergeThreshold + 0.05
                && (metrics.gps ?? 0) >= 0.68
                && max(metrics.semantic ?? 0, metrics.activity ?? 0, metrics.people ?? 0) >= 0.50
        }
        return metrics.score >= mergeThreshold && metrics.temporal >= 0.16
    }

    private func pairMetrics(_ first: Observation, _ second: Observation, sceneIndex: SemanticSceneIndex) -> PairMetrics {
        let gap = dateGap(first.normalizedDate, second.normalizedDate)
        let rawTemporal = temporalSimilarity(gap: gap, datesAvailable: first.normalizedDate != nil && second.normalizedDate != nil)
        let temporal = rawTemporal * (0.35 + min(first.dateConfidence, second.dateConfidence) * 0.65)
        let gps = gpsSimilarity(first.coordinate, second.coordinate)
        let visual = visualSimilarity(first, second, index: sceneIndex)
        let filename = filenameSimilarity(first.filenameIdentity, second.filenameIdentity)
        let activityCompatibility = first.activityEvidence.compatibility(with: second.activityEvidence)
        let activity: Double? = switch activityCompatibility {
        case .compatible: 1
        case .incompatible: 0
        case .insufficientEvidence: nil
        }
        var semantic = optionalJaccard(first.semanticTokens, second.semanticTokens)
        let sharedSemanticEventID = !first.semanticEventIDs.isDisjoint(with: second.semanticEventIDs)
        // A persisted ID is a hint, never proof by itself. It can strengthen a
        // compatible pair only after current GPS, visual, filename or canonical
        // activity evidence corroborates it; conflicting activities veto it.
        let legacyIDCorroboration = max(gps ?? 0, visual ?? 0, filename ?? 0, activity ?? 0)
        let corroboratedSemanticEventID = sharedSemanticEventID
            && activityCompatibility != .incompatible
            && !first.activityEvidence.isAmbiguous
            && !second.activityEvidence.isAmbiguous
            && legacyIDCorroboration >= 0.62
        if corroboratedSemanticEventID {
            semantic = max(semantic ?? 0, 1)
        }
        let people = optionalJaccard(first.peopleTokens, second.peopleTokens)
        let audio = optionalJaccard(first.audioTokens, second.audioTokens)
        let sameRecordingIdentity = first.filenameIdentity.recordingGroup != nil
            && first.filenameIdentity.recordingGroup == second.filenameIdentity.recordingGroup
            && (filename ?? 0) >= 0.95
        let exactSameMoment = (visual ?? 0) >= 0.995
            && gap <= 90
            && max(gps ?? 0, semantic ?? 0, people ?? 0, audio ?? 0) >= 0.72
        let decisiveSameTakeEvidence = sameRecordingIdentity || exactSameMoment
        let deviceTimeline = first.device != second.device && gap <= 15 * 60 ? 1.0 : gap <= 4 * 60 ? 0.62 : 0.20
        let values: [(Double?, Double)] = [
            (temporal, 0.25), (gps, 0.18), (visual, 0.12), (semantic, 0.15),
            (activity, 0.08), (people, 0.06), (audio, 0.04), (deviceTimeline, 0.05),
            (filename, 0.07)
        ]
        let available = values.compactMap { value, weight in value.map { ($0, weight) } }
        let weight = available.reduce(0) { $0 + $1.1 }
        var score = available.reduce(0) { $0 + $1.0 * $1.1 } / max(0.000_001, weight)
        if first.device != second.device, gap <= 10 * 60,
           max(gps ?? 0, semantic ?? 0, visual ?? 0) >= 0.55 {
            score += 0.08
        }
        let distance = coordinateDistance(first.coordinate, second.coordinate)
        let hardSplit = gap > maximumMultiDayGap
            || (gap > 36 * 3_600 && !((gps ?? 0) >= 0.68 && max(semantic ?? 0, activity ?? 0) >= 0.50))
            || (gap > 5 * 3_600 && (distance ?? 0) > 25_000 && max(semantic ?? 0, activity ?? 0, people ?? 0) < 0.35)
            || (gap > 8 * 86_400)
        return PairMetrics(
            score: score.clamped01,
            temporal: temporal,
            gps: gps,
            visual: visual,
            semantic: semantic,
            activity: activity,
            people: people,
            audio: audio,
            filename: filename,
            deviceTimeline: deviceTimeline,
            gap: gap,
            hardSplit: hardSplit,
            activityCompatibility: activityCompatibility,
            decisiveSameTakeEvidence: decisiveSameTakeEvidence,
            corroboratedSemanticEventID: corroboratedSemanticEventID
        )
    }

    private func makeEvent(_ indices: [Int], observations: [Observation], links: [PairLink], offsets: [String: Double], sourceMap: SourceMap) -> Event {
        let members = indices.map { observations[$0] }
        let memberSet = Set(indices)
        let internalLinks = links.filter { memberSet.contains($0.first) && memberSet.contains($0.second) }
        let allTags = members.reduce(into: Set<String>()) { $0.formUnion($1.semanticTokens) }
        let dates = members.compactMap(\.normalizedDate)
        let coordinates = members.compactMap(\.coordinate)
        let location = eventLocation(coordinates: coordinates, members: members)
        let titleDecision = EventTitleGenerator().title(tags: allTags, observations: members, location: location)
        let eventID = stableUUID(
            namespace: "event",
            components: members.map { $0.asset.id.uuidString }.sorted()
        )
        let scenes = makeScenes(members: members, eventID: eventID, sourceMap: sourceMap)
        let quality = eventQuality(members: members, scenes: scenes, internalLinks: internalLinks)
        let dateConfidence = members.map(\.dateConfidence).reduce(0, +) / Double(max(1, members.count))
        let linkConfidence = internalLinks.isEmpty
            ? (members.count == 1 ? 0.54 : 0.35)
            : internalLinks.map(\.metrics.score).reduce(0, +) / Double(internalLinks.count)
        let confidence = (linkConfidence * 0.62 + dateConfidence * 0.18 + quality.semanticCoherence * 0.12 + quality.temporalCoherence * 0.08).clamped01
        let evidence = aggregateEvidence(internalLinks: internalLinks, members: members, location: location)
        let crossDevice = internalLinks.filter { observations[$0.first].device != observations[$0.second].device }.count
        let memberDevices = Set(members.map(\.device))
        let memberOffsets = offsets.filter { memberDevices.contains($0.key) }
        return Event(
            id: eventID,
            title: titleDecision.title,
            startDate: dates.min(),
            endDate: members.compactMap { member in
                member.normalizedDate.map { $0.addingTimeInterval(member.asset.metadata.duration ?? 0) }
            }.max() ?? dates.max(),
            assetIDs: members.sorted(by: chronologicalObservationOrder).map(\.asset.id),
            tags: allTags,
            location: location,
            confidence: confidence,
            titleConfidence: titleDecision.confidence,
            evidence: evidence,
            scenes: scenes,
            quality: quality,
            deviceTimeOffsets: memberOffsets,
            crossDeviceMatchCount: crossDevice
        )
    }

    private func makeScenes(members: [Observation], eventID: UUID, sourceMap: SourceMap) -> [EventScene] {
        let memberIDs = Set(members.map(\.asset.id))
        let activityGroups = sourceMap.activityGroups
            .filter { !$0.assetIDs.allSatisfy { !memberIDs.contains($0) } }
            .sorted { $0.order < $1.order }
        if !activityGroups.isEmpty {
            return makeActivityGroupScenes(groups: activityGroups, members: members, eventID: eventID)
        }
        struct Unit {
            var assetID: UUID
            var candidateID: UUID?
            var date: Date?
            var tags: Set<String>
            var action: Double
            var quality: Double
            var device: String
        }
        var units: [Unit] = []
        for member in members {
            if member.candidates.isEmpty {
                units.append(Unit(assetID: member.asset.id, candidateID: nil, date: member.normalizedDate, tags: member.semanticTokens, action: 0.25, quality: 0.45, device: member.device))
            } else {
                for candidate in member.candidates {
                    units.append(Unit(
                        assetID: member.asset.id,
                        candidateID: candidate.id,
                        date: member.normalizedDate?.addingTimeInterval(candidate.sourceStart),
                        tags: member.semanticTokens.union(candidate.tags.map { $0.lowercased() }),
                        action: candidate.insights?.dynamics ?? candidate.scores.action,
                        quality: candidate.scores.quality,
                        device: member.device
                    ))
                }
            }
        }
        units.sort {
            if let lhs = $0.date, let rhs = $1.date, lhs != rhs { return lhs < rhs }
            return ($0.candidateID?.uuidString ?? $0.assetID.uuidString) < ($1.candidateID?.uuidString ?? $1.assetID.uuidString)
        }
        var groups: [[Unit]] = []
        for unit in units {
            guard let last = groups.last?.last else { groups.append([unit]); continue }
            let gap = dateGap(last.date, unit.date)
            let semantic = jaccard(last.tags, unit.tags)
            let sameScene = (gap <= 3 * 60 && (semantic >= 0.18 || last.device != unit.device))
                || (last.assetID == unit.assetID && gap <= 45 && semantic >= 0.12)
            if sameScene { groups[groups.count - 1].append(unit) }
            else { groups.append([unit]) }
        }
        guard !groups.isEmpty else { return [] }
        let energy = groups.map { group in group.reduce(0) { $0 + $1.action * 0.72 + $1.quality * 0.28 } / Double(group.count) }
        let peakIndex = energy.indices.max(by: { energy[$0] < energy[$1] }) ?? 0
        return groups.enumerated().map { index, group in
            let tags = group.reduce(into: Set<String>()) { $0.formUnion($1.tags) }
            let phase: EventScenePhase
            if groups.count == 1 { phase = .peak }
            else if index == peakIndex { phase = .peak }
            else if index == 0 { phase = .setup }
            else if index < peakIndex { phase = index + 1 == peakIndex ? .preparation : .action }
            else if index == peakIndex + 1 { phase = .reaction }
            else if index == groups.count - 1 { phase = .conclusion }
            else { phase = .reaction }
            let title = EventTitleGenerator().sceneTitle(tags: tags, phase: phase)
            let sceneComponents = group.compactMap { $0.candidateID?.uuidString }
                + group.map { $0.assetID.uuidString }
                + [phase.rawValue]
            return EventScene(
                id: stableUUID(namespace: "event-scene:\(eventID.uuidString)", components: sceneComponents.sorted()),
                title: title,
                startDate: group.compactMap(\.date).min(),
                endDate: group.compactMap(\.date).max(),
                assetIDs: Array(Set(group.map(\.assetID))).sorted { $0.uuidString < $1.uuidString },
                candidateIDs: group.compactMap(\.candidateID),
                tags: tags,
                phase: phase,
                confidence: (0.48 + min(0.34, Double(group.count) * 0.06) + min(0.18, energy[index] * 0.18)).clamped01
            )
        }
    }

    private func makeActivityGroupScenes(groups: [SourceActivityGroup], members: [Observation], eventID: UUID) -> [EventScene] {
        struct CandidateUnit {
            var candidate: Candidate
            var assetRank: Int
            var tags: Set<String>
            var summaries: [String]
            var activity: ActivityEvidence
        }
        struct ActivityRun {
            var family: ActivityFamily
            var unitIndices: [Int]
        }
        struct SceneSlice {
            var stableComponents: [String]
            var title: String
            var assetIDs: [UUID]
            var candidates: [Candidate]
            var tags: Set<String>
            var startDate: Date?
            var endDate: Date?
            var confidence: Double
            var energy: Double
        }

        let memberIDs = Set(members.map(\.asset.id))
        let membersByID = Dictionary(uniqueKeysWithValues: members.map { ($0.asset.id, $0) })

        func semanticEvidence(for candidate: Candidate) -> (Set<String>, [String], ActivityEvidence) {
            var tags = Set(candidate.tags.map { $0.lowercased() })
            let summaries = candidate.insights?.sceneSummary.map { [$0] } ?? []
            for summary in summaries {
                let words = summary.lowercased()
                    .split { !$0.isLetter && !$0.isNumber }
                    .map(String.init)
                tags.formUnion(words)
                if words.count >= 2 {
                    for index in 0..<(words.count - 1) {
                        tags.insert("\(words[index]) \(words[index + 1])")
                    }
                }
            }
            return (tags, summaries, ActivityCompatibilityContract.evidence(in: tags))
        }

        func meanEnergy(_ candidates: [Candidate]) -> Double {
            guard !candidates.isEmpty else { return 0.35 }
            return candidates.reduce(0) {
                $0 + ($1.insights?.dynamics ?? $1.scores.action) * 0.72 + $1.scores.quality * 0.28
            } / Double(candidates.count)
        }

        func dateRange(for candidates: [Candidate]) -> (Date?, Date?) {
            let starts = candidates.compactMap { candidate in
                membersByID[candidate.assetID]?.normalizedDate?.addingTimeInterval(candidate.sourceStart)
            }
            let ends = candidates.compactMap { candidate in
                membersByID[candidate.assetID]?.normalizedDate?
                    .addingTimeInterval(candidate.sourceStart + candidate.sourceDuration)
            }
            return (starts.min(), ends.max())
        }

        func unsplitSlice(for group: SourceActivityGroup, groupMembers: [Observation], candidates: [Candidate]) -> SceneSlice {
            var tags = groupMembers.reduce(into: Set<String>()) { $0.formUnion($1.semanticTokens) }
            if group.title == "Багги", group.evidence.contains(where: { $0.kind == "activity" && $0.score >= 0.84 }) {
                tags.insert("buggy")
            }
            let dates = groupMembers.compactMap(\.normalizedDate)
            return SceneSlice(
                stableComponents: [group.id.uuidString],
                title: group.title,
                assetIDs: group.assetIDs.filter(memberIDs.contains),
                candidates: candidates,
                tags: tags,
                startDate: dates.min(),
                endDate: groupMembers.compactMap { member in
                    member.normalizedDate.map { $0.addingTimeInterval(member.asset.metadata.duration ?? 0) }
                }.max() ?? dates.max(),
                confidence: group.confidence,
                energy: meanEnergy(candidates)
            )
        }

        func supported(_ run: ActivityRun, units: [CandidateUnit]) -> Bool {
            let evidence = run.unitIndices.map { units[$0].activity }
            let duration = run.unitIndices.reduce(0) { $0 + units[$1].candidate.sourceDuration }
            let confidence = evidence.reduce(0) { $0 + $1.confidence } / Double(max(1, evidence.count))
            let markers = evidence.reduce(into: Set<String>()) { $0.formUnion($1.matchedMarkers) }
            // Two independently detected moments are enough only when their
            // shared family is confidently specific. A single moment needs a
            // longer range and at least two corroborating activity markers.
            return (run.unitIndices.count >= 2 && duration >= 4 && confidence >= 0.62)
                || (duration >= 6 && confidence >= 0.82 && markers.count >= 2)
        }

        func splitSlices(
            for group: SourceActivityGroup,
            groupMembers: [Observation],
            candidates: [Candidate]
        ) -> [SceneSlice]? {
            guard candidates.count >= 2 else { return nil }
            let assetRank = Dictionary(uniqueKeysWithValues: group.assetIDs.enumerated().map { ($0.element, $0.offset) })
            let units = candidates.map { candidate -> CandidateUnit in
                let semantic = semanticEvidence(for: candidate)
                return CandidateUnit(
                    candidate: candidate,
                    assetRank: assetRank[candidate.assetID] ?? Int.max,
                    tags: semantic.0,
                    summaries: semantic.1,
                    activity: semantic.2
                )
            }.sorted {
                if $0.assetRank != $1.assetRank { return $0.assetRank < $1.assetRank }
                if $0.candidate.sourceStart != $1.candidate.sourceStart {
                    return $0.candidate.sourceStart < $1.candidate.sourceStart
                }
                return $0.candidate.id.uuidString < $1.candidate.id.uuidString
            }

            var runs: [ActivityRun] = []
            for (index, unit) in units.enumerated() {
                guard let family = unit.activity.family, unit.activity.confidence >= 0.58 else { continue }
                if runs.last?.family == family {
                    runs[runs.count - 1].unitIndices.append(index)
                } else {
                    runs.append(ActivityRun(family: family, unitIndices: [index]))
                }
            }
            let supportedRuns = runs.filter { supported($0, units: units) }
            guard supportedRuns.count >= 2 else { return nil }

            // Ignore isolated classifier flicker between two supported runs of
            // the same activity. It must not manufacture a new chapter or a
            // transition boundary by itself.
            var anchors: [ActivityRun] = []
            for run in supportedRuns {
                if anchors.last?.family == run.family {
                    anchors[anchors.count - 1].unitIndices.append(contentsOf: run.unitIndices)
                } else {
                    anchors.append(run)
                }
            }
            guard anchors.count >= 2 else { return nil }

            var labels: [SmartTitleDecision] = []
            for anchor in anchors {
                let anchorUnits = anchor.unitIndices.map { units[$0] }
                let tags = anchorUnits.reduce(into: Set<String>()) { $0.formUnion($1.tags) }
                let summaries = anchorUnits.flatMap(\.summaries)
                guard let label = SmartTitleEngine().contentConfirmedActivityTitle(tags: tags, summaries: summaries) else {
                    return nil
                }
                labels.append(label)
            }

            return anchors.indices.map { anchorIndex in
                let lower = anchorIndex == 0 ? 0 : anchors[anchorIndex].unitIndices.min() ?? 0
                let upper = anchorIndex + 1 < anchors.count
                    ? (anchors[anchorIndex + 1].unitIndices.min() ?? units.count)
                    : units.count
                let sliceUnits = Array(units[lower..<max(lower + 1, upper)])
                let sliceCandidates = sliceUnits.map(\.candidate)
                let sliceAssetSet = Set(sliceCandidates.map(\.assetID))
                let sliceTags = sliceUnits.reduce(into: Set<String>()) { $0.formUnion($1.tags) }
                let evidence = anchors[anchorIndex].unitIndices.map { units[$0].activity.confidence }
                let evidenceConfidence = evidence.reduce(0, +) / Double(max(1, evidence.count))
                let range = dateRange(for: sliceCandidates)
                return SceneSlice(
                    stableComponents: [group.id.uuidString, "candidate-activity-run", anchors[anchorIndex].family.rawValue]
                        + sliceCandidates.map { $0.id.uuidString },
                    title: labels[anchorIndex].primaryText,
                    assetIDs: group.assetIDs.filter(sliceAssetSet.contains),
                    candidates: sliceCandidates,
                    tags: sliceTags,
                    startDate: range.0,
                    endDate: range.1,
                    confidence: (group.confidence * 0.46 + evidenceConfidence * 0.34 + labels[anchorIndex].confidence * 0.20).clamped01,
                    energy: meanEnergy(sliceCandidates)
                )
            }
        }

        var slices: [SceneSlice] = []
        for group in groups {
            let groupMembers = group.assetIDs.compactMap { membersByID[$0] }
            let candidates = groupMembers.flatMap(\.candidates).sorted {
                let lhsAsset = group.assetIDs.firstIndex(of: $0.assetID) ?? Int.max
                let rhsAsset = group.assetIDs.firstIndex(of: $1.assetID) ?? Int.max
                if lhsAsset != rhsAsset { return lhsAsset < rhsAsset }
                return $0.sourceStart < $1.sourceStart
            }
            if let split = splitSlices(for: group, groupMembers: groupMembers, candidates: candidates) {
                slices.append(contentsOf: split)
            } else {
                slices.append(unsplitSlice(for: group, groupMembers: groupMembers, candidates: candidates))
            }
        }

        let peakIndex = slices.indices.max(by: { slices[$0].energy < slices[$1].energy }) ?? 0
        return slices.enumerated().map { index, slice in
            let phase: EventScenePhase
            if slices.count == 1 { phase = .peak }
            else if index == peakIndex { phase = .peak }
            else if index == 0 { phase = .setup }
            else if index < peakIndex { phase = index + 1 == peakIndex ? .preparation : .action }
            else if index == peakIndex + 1 { phase = .reaction }
            else if index == slices.count - 1 { phase = .conclusion }
            else { phase = .reaction }
            return EventScene(
                id: stableUUID(namespace: "event-scene:\(eventID.uuidString)", components: slice.stableComponents),
                title: slice.title,
                startDate: slice.startDate,
                endDate: slice.endDate,
                assetIDs: slice.assetIDs,
                candidateIDs: slice.candidates.map(\.id),
                tags: slice.tags,
                phase: phase,
                confidence: slice.confidence
            )
        }
    }

    private func eventQuality(members: [Observation], scenes: [EventScene], internalLinks: [PairLink]) -> EventQuality {
        let candidates = members.flatMap(\.candidates)
        func mean(_ values: [Double], fallback: Double = 0.45) -> Double {
            values.isEmpty ? fallback : values.reduce(0, +) / Double(values.count)
        }
        let visual = mean(candidates.map { $0.scores.quality * 0.55 + ($0.insights?.visualAppeal ?? $0.scores.interest) * 0.45 })
        let semantic = internalLinks.isEmpty ? (members.count == 1 ? 0.62 : 0.40) : mean(internalLinks.compactMap(\.metrics.semantic))
        let temporal = internalLinks.isEmpty ? (members.count == 1 ? 0.72 : 0.42) : mean(internalLinks.map(\.metrics.temporal))
        let usableSeconds = candidates.filter { $0.scores.quality >= 0.38 && $0.scores.interest >= 0.35 }.reduce(0) { $0 + min(8, $1.sourceDuration) }
        let usable = min(1, usableSeconds / 45)
        let emotional = mean(candidates.map { candidate in
            let named = candidate.insights?.emotion?.isEmpty == false ? 1.0 : 0.18
            let people = candidate.tags.contains("people") ? 0.75 : 0
            let audio = candidate.insights?.audioEvents?.filter { [.laughter, .applause, .scream].contains($0.kind) }.map(\.confidence).max() ?? 0
            return max(named, people, audio)
        }, fallback: 0.25)
        let action = mean(candidates.map { $0.insights?.dynamics ?? $0.scores.action })
        let uniqueness = mean(candidates.map(\.scores.uniqueness))
        let story = mean(candidates.map { $0.insights?.storyValue ?? $0.scores.interest })
        let devices = Set(members.map(\.device)).count
        let tags = Set(members.flatMap(\.semanticTokens)).count
        let diversity = (min(1, Double(scenes.count) / 6) * 0.45 + min(1, Double(devices) / 3) * 0.28 + min(1, Double(tags) / 16) * 0.27).clamped01
        let total = visual * 0.14 + semantic * 0.12 + temporal * 0.10 + usable * 0.14
            + emotional * 0.10 + action * 0.10 + uniqueness * 0.09 + story * 0.13 + diversity * 0.08
        return EventQuality(
            total: total,
            visualQuality: visual,
            semanticCoherence: semantic,
            temporalCoherence: temporal,
            usableMaterial: usable,
            emotionalValue: emotional,
            action: action,
            uniqueness: uniqueness,
            storyPotential: story,
            diversity: diversity
        )
    }

    private func aggregateEvidence(internalLinks: [PairLink], members: [Observation], location: EventLocation?) -> [EventClusteringEvidence] {
        var values: [(String, Double, String)] = []
        if !internalLinks.isEmpty {
            func add(_ kind: String, _ scores: [Double], _ explanation: String) {
                guard !scores.isEmpty else { return }
                values.append((kind, scores.reduce(0, +) / Double(scores.count), explanation))
            }
            add("time", internalLinks.map(\.metrics.temporal), "Близкая или последовательно связанная временная шкала")
            add("gps", internalLinks.compactMap(\.metrics.gps), "Совпадающая GPS-зона или маршрут")
            add("visual", internalLinks.compactMap(\.metrics.visual), "Визуально согласованные сцены")
            add("semantic", internalLinks.compactMap(\.metrics.semantic), "Совпадающий смысл и контекст материала")
            add("activity", internalLinks.compactMap(\.metrics.activity), "Одна активность продолжается между файлами")
            add("people", internalLinks.compactMap(\.metrics.people), "Совпадают люди или главные объекты")
            add("audio", internalLinks.compactMap(\.metrics.audio), "Совпадает аудиоконтекст")
            add("filename", internalLinks.compactMap(\.metrics.filename), "Имена файлов указывают на главы одной записи или соседнюю camera sequence")
        }
        let devices = Set(members.map(\.device))
        if devices.count > 1 {
            values.append(("cross-device", min(1, Double(devices.count) / 3), "Пересекаются камеры: \(devices.sorted().joined(separator: ", "))"))
        }
        if location?.confidence ?? 0 > 0.5 {
            values.append(("location", location?.confidence ?? 0, "Медиана координат подтверждает общее место"))
        }
        return values.sorted { $0.1 > $1.1 }.prefix(7).map { EventClusteringEvidence(kind: $0.0, score: $0.1, explanation: $0.2) }
    }

    private func eventLocation(coordinates: [TelemetryCoordinate], members: [Observation]) -> EventLocation? {
        let semanticLocations = members.flatMap { member in member.analysis?.scenes?.compactMap(\.location) ?? [] }
        let commonLabel = Dictionary(grouping: semanticLocations.filter { !$0.isEmpty }, by: { $0.lowercased() })
            .max(by: { $0.value.count < $1.value.count })?.value.first
        guard !coordinates.isEmpty || commonLabel != nil else { return nil }
        let latitude = coordinates.isEmpty ? nil : coordinates.map(\.latitude).sorted()[coordinates.count / 2]
        let longitude = coordinates.isEmpty ? nil : coordinates.map(\.longitude).sorted()[coordinates.count / 2]
        let confidence = coordinates.isEmpty ? 0.42 : min(0.96, 0.58 + Double(coordinates.count) * 0.07)
        return EventLocation(latitude: latitude, longitude: longitude, semanticLabel: commonLabel, confidence: confidence)
    }

    private func visualSimilarity(_ first: Observation, _ second: Observation, index: SemanticSceneIndex) -> Double? {
        guard !first.candidates.isEmpty, !second.candidates.isEmpty else { return nil }
        return first.candidates.prefix(6).flatMap { lhs in
            second.candidates.prefix(6).map { index.similarity(between: lhs, and: $0) }
        }.max()
    }

    private func temporalSimilarity(gap: TimeInterval, datesAvailable: Bool) -> Double {
        guard datesAvailable else { return 0.34 }
        switch gap {
        case ...90: return 1
        case ...(15 * 60): return 0.92
        case ...(60 * 60): return 0.78
        case ...(3 * 3_600): return 0.60
        case ...(8 * 3_600): return 0.42
        case ...(20 * 3_600): return 0.24
        case ...(48 * 3_600): return 0.16
        default: return 0.07
        }
    }

    private func gpsSimilarity(_ first: TelemetryCoordinate?, _ second: TelemetryCoordinate?) -> Double? {
        guard let distance = coordinateDistance(first, second) else { return nil }
        switch distance {
        case ...120: return 1
        case ...750: return 0.88
        case ...3_000: return 0.68
        case ...12_000: return 0.38
        case ...30_000: return 0.12
        default: return 0
        }
    }

    private func coordinateDistance(_ first: TelemetryCoordinate?, _ second: TelemetryCoordinate?) -> Double? {
        guard let first, let second else { return nil }
        let radius = 6_371_000.0
        let lat1 = first.latitude * .pi / 180
        let lat2 = second.latitude * .pi / 180
        let deltaLat = (second.latitude - first.latitude) * .pi / 180
        let deltaLon = (second.longitude - first.longitude) * .pi / 180
        let value = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return radius * 2 * atan2(sqrt(value), sqrt(max(0, 1 - value)))
    }

    private func optionalJaccard(_ first: Set<String>, _ second: Set<String>) -> Double? {
        guard !first.isEmpty, !second.isEmpty else { return nil }
        return jaccard(first, second)
    }

    private func filenameSimilarity(_ first: FilenameIdentity, _ second: FilenameIdentity) -> Double? {
        if let lhs = first.recordingGroup, lhs == second.recordingGroup {
            return min(first.recordingGroupStrength, second.recordingGroupStrength)
        }
        guard let lhsFamily = first.family, lhsFamily == second.family,
              let lhsSequence = first.sequence, let rhsSequence = second.sequence else { return nil }
        let delta = abs(lhsSequence - rhsSequence)
        if delta == 1 { return 0.90 }
        if delta <= 4 { return 0.78 }
        if delta <= 8 { return 0.52 }
        if delta <= 16 { return 0.24 }
        return nil
    }

    private func jaccard(_ first: Set<String>, _ second: Set<String>) -> Double {
        let union = first.union(second)
        guard !union.isEmpty else { return 0 }
        return Double(first.intersection(second).count) / Double(union.count)
    }

    private func dateGap(_ first: Date?, _ second: Date?) -> TimeInterval {
        guard let first, let second else { return 12 * 3_600 }
        return abs(second.timeIntervalSince(first))
    }

    private func sameLocalDay(_ first: Date?, _ second: Date?) -> Bool {
        guard let first, let second else { return false }
        return Calendar.current.isDate(first, inSameDayAs: second)
    }

    private func chronologicalObservationOrder(_ first: Observation, _ second: Observation) -> Bool {
        if first.sourceOrder != second.sourceOrder { return first.sourceOrder < second.sourceOrder }
        let lhs = first.normalizedDate ?? .distantFuture
        let rhs = second.normalizedDate ?? .distantFuture
        if lhs != rhs { return lhs < rhs }
        return first.asset.id.uuidString < second.asset.id.uuidString
    }

    private func stableUUID(namespace: String, components: [String]) -> UUID {
        let payload = ([namespace] + components).joined(separator: "\u{1F}")
        var bytes = Array(SHA256.hash(data: Data(payload.utf8)).prefix(16))
        // RFC 4122 variant with a version-5-shaped deterministic identifier.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public struct EventDurationAllocator: Sendable {
    public init() {}

    public func allocate(
        events: [Event],
        totalDuration: Double,
        strategy: String,
        personalAdjustments: [String: Double] = [:],
        requiresExactTotal: Bool = false
    ) -> [UUID: Double] {
        guard !events.isEmpty else { return [:] }
        let target = max(5, totalDuration)
        let longEventPreference = personalAdjustments["eventDuration", default: 0]
        let minimum = min(8, max(2.2, target / Double(max(2, events.count * 5))))
        let strategyLower = strategy.lowercased()
        let weights = events.map { event -> Double in
            let quality = event.quality ?? EventQuality(total: 0.45, visualQuality: 0.45, semanticCoherence: 0.45, temporalCoherence: 0.45, usableMaterial: 0.35, emotionalValue: 0.35, action: 0.35, uniqueness: 0.45, storyPotential: 0.45, diversity: 0.35)
            var value = 0.18 + quality.total * 0.55 + quality.storyPotential * 0.17 + quality.usableMaterial * 0.10
            if strategyLower.contains("action") || strategyLower.contains("telemetry") { value += quality.action * 0.26 }
            if strategyLower.contains("emotional") || strategyLower.contains("people") { value += quality.emotionalValue * 0.24 }
            if strategyLower.contains("technical") { value += quality.visualQuality * 0.18 }
            value *= 1 + longEventPreference * quality.total * 0.22
            return max(0.05, value)
        }
        let sum = weights.reduce(0, +)
        if requiresExactTotal {
            // Quality still controls each event's share, but it must not turn
            // a user-selected runtime into a shorter creative suggestion.
            // TimelineComposer performs a second, source-capacity-aware pass
            // when one event cannot consume its complete share.
            let base = min(minimum, target / Double(events.count))
            let remaining = max(0, target - base * Double(events.count))
            return Dictionary(uniqueKeysWithValues: zip(events, weights).map { event, weight in
                (event.id, base + remaining * weight / max(0.000_001, sum))
            })
        }
        func maximumDuration(for event: Event) -> Double {
            // When the archive is one continuous event, its activity/scene
            // groups are the story structure. Do not discard most of the
            // already content-bounded target as if another event needed room.
            if events.count == 1, event.effectiveScenes.count > 1 { return target }
            let quality = event.quality
            if (quality?.total ?? 0.45) < 0.34 {
                return max(3, minimum)
            }
            let materialCeiling = minimum + (quality?.usableMaterial ?? 0.35) * max(10, target * 0.52)
            return max(minimum, min(target * 0.62, materialCeiling))
        }
        var values: [UUID: Double] = [:]
        for (event, weight) in zip(events, weights) {
            var duration = max(minimum, target * weight / max(0.000_001, sum))
            if (event.quality?.total ?? 0.45) < 0.34 { duration = min(duration, max(3, minimum)) }
            values[event.id] = min(maximumDuration(for: event), duration)
        }
        for _ in 0..<3 {
            let used = values.values.reduce(0, +)
            let remaining = target - used
            guard remaining > 0.2 else { break }
            let expandable = events.filter { event in
                values[event.id, default: 0] + 0.1 < maximumDuration(for: event)
            }
            guard !expandable.isEmpty else { break }
            let perEvent = remaining / Double(expandable.count)
            for event in expandable {
                values[event.id, default: 0] = min(
                    maximumDuration(for: event),
                    values[event.id, default: 0] + perEvent
                )
            }
        }
        return values
    }
}

public struct EventTitleGenerator: Sendable {
    public init() {}

    fileprivate func title(tags: Set<String>, observations: [Observation], location: EventLocation? = nil) -> (title: String, confidence: Double) {
        let decision = SmartTitleEngine().decide(SmartTitleContext(
            purpose: .activity,
            tags: tags,
            summaries: observations.compactMap { $0.analysis?.scenes?.compactMap(\.semanticDescription).joined(separator: " ") },
            locationName: location?.semanticLabel,
            locationConfidence: location?.confidence ?? 0,
            captureDate: observations.compactMap(\.normalizedDate).min(),
            dateAddsContext: false
        ))
        if let decision { return (decision.primaryText, decision.confidence) }
        if let date = observations.compactMap(\.normalizedDate).min() {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "d MMMM yyyy"
            return ("Съёмка — \(formatter.string(from: date))", 0.46)
        }
        return ("Съёмка", 0.24)
    }

    public func sceneTitle(tags: Set<String>, phase: EventScenePhase) -> String {
        if let decision = SmartTitleEngine().decide(SmartTitleContext(purpose: .shortLabel, tags: tags)) {
            return decision.primaryText
        }
        switch phase {
        case .setup: return "Знакомство с местом"
        case .preparation: return "Подготовка"
        case .action: return "В движении"
        case .peak: return "Пик маршрута"
        case .reaction: return "Реакция"
        case .conclusion: return "Дорога домой"
        }
    }
}

fileprivate struct Observation: Sendable {
    var asset: MediaAsset
    var analysis: AnalysisResult?
    var rawDate: Date?
    var normalizedDate: Date?
    var dateConfidence: Double
    var coordinate: TelemetryCoordinate?
    var device: String
    var semanticTokens: Set<String>
    var semanticEventIDs: Set<String>
    var activityEvidence: ActivityEvidence
    var peopleTokens: Set<String>
    var audioTokens: Set<String>
    var filenameIdentity: FilenameIdentity
    var candidates: [Candidate]
    var sourceOrder: Int

    init(asset: MediaAsset, analysis: AnalysisResult?, sourceOrder: Int? = nil) {
        self.asset = asset
        self.analysis = analysis
        let filenameIdentity = FilenameIdentity(fileName: asset.displayName)
        self.filenameIdentity = filenameIdentity
        self.sourceOrder = sourceOrder ?? Int.max
        // Import time is the last-resort timeline anchor. Its low confidence
        // prevents it from merging unrelated files merely imported together.
        let effectiveDate = asset.metadata.effectiveCaptureDate ?? filenameIdentity.captureDate ?? asset.importedAt
        self.rawDate = effectiveDate
        self.normalizedDate = effectiveDate
        if asset.metadata.effectiveCaptureDate != nil {
            self.dateConfidence = asset.metadata.dateConfidence
                ?? (asset.metadata.dateSource == .embeddedMetadata ? 0.98 : asset.metadata.creationDate != nil ? 0.66 : 0.30)
        } else if filenameIdentity.captureDate != nil {
            self.dateConfidence = 0.58
        } else {
            self.dateConfidence = 0.12
        }
        self.coordinate = Self.coordinate(asset: asset, analysis: analysis)
        self.device = EventDeviceIdentity.key(for: asset)
        self.candidates = analysis?.directorCandidates ?? []
        self.semanticEventIDs = Set(self.candidates.compactMap { candidate in
            candidate.insights?.semanticEventID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
        var semantic = Set((analysis?.sceneTags ?? []).map { $0.lowercased() })
        for scene in analysis?.scenes ?? [] {
            semantic.formUnion(scene.people.map { $0.lowercased() })
            semantic.formUnion(scene.objects.map { $0.lowercased() })
            semantic.formUnion(scene.highlights.map { $0.lowercased() })
            semantic.formUnion(scene.recommendedUses.map { $0.lowercased() })
            if let location = scene.location { semantic.insert(location.lowercased()) }
            if let description = scene.semanticDescription { semantic.formUnion(Self.words(description)) }
        }
        for candidate in candidates {
            semantic.formUnion(candidate.tags.map { $0.lowercased() })
            if let summary = candidate.insights?.sceneSummary { semantic.formUnion(Self.words(summary)) }
        }
        semantic.formUnion(Self.words(asset.displayName))
        self.semanticTokens = semantic.filter { $0.count >= 3 }
        self.activityEvidence = ActivityCompatibilityContract.evidence(in: self.semanticTokens)
        var people = Set((analysis?.scenes ?? []).flatMap(\.people).map { $0.lowercased() })
        if semantic.contains("people") || semantic.contains("person") { people.insert("people") }
        for candidate in candidates {
            for track in candidate.insights?.subjectTracking?.tracks ?? [] where [.person, .face, .cyclist].contains(track.kind) {
                people.insert(track.label.lowercased())
            }
        }
        self.peopleTokens = people
        let events = (analysis?.audioAnalysis?.events ?? []) + candidates.flatMap { $0.insights?.audioEvents ?? [] }
        self.audioTokens = Set(events.filter { $0.confidence >= 0.42 }.map { $0.kind.rawValue })
    }

    private static func coordinate(asset: MediaAsset, analysis: AnalysisResult?) -> TelemetryCoordinate? {
        if let latitude = asset.metadata.latitude, let longitude = asset.metadata.longitude {
            return TelemetryCoordinate(latitude: latitude, longitude: longitude)
        }
        return analysis?.telemetry?.route?.first ?? analysis?.telemetry?.timedSamples?.compactMap(\.coordinate).first
    }

    private static func words(_ value: String) -> Set<String> {
        Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
    }
}

private struct PairMetrics: Sendable {
    var score: Double
    var temporal: Double
    var gps: Double?
    var visual: Double?
    var semantic: Double?
    var activity: Double?
    var people: Double?
    var audio: Double?
    var filename: Double?
    var deviceTimeline: Double
    var gap: TimeInterval
    var hardSplit: Bool
    var activityCompatibility: ActivityCompatibility
    var decisiveSameTakeEvidence: Bool
    var corroboratedSemanticEventID: Bool
}

fileprivate struct FilenameIdentity: Sendable {
    var recordingGroup: String?
    var recordingGroupStrength: Double
    var family: String?
    var sequence: Int?
    var captureDate: Date?

    init(fileName: String) {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent.uppercased()
        self.recordingGroup = nil
        self.recordingGroupStrength = 0
        self.family = nil
        self.sequence = nil
        self.captureDate = nil
        if let match = SourceSequenceDetector().detect(fileName: fileName) {
            self.recordingGroup = match.recordingKey
            self.recordingGroupStrength = match.recordingKey == nil ? 0 : match.confidence
            self.family = match.seriesKey
            self.sequence = match.sequenceID
            self.captureDate = match.captureDate
            return
        }
        if let groups = Self.captures(#"^GOPR([0-9]{4})(?:[-_].*)?$"#, in: stem),
           let recording = groups.first {
            self.recordingGroup = "gopro:\(recording)"
            self.recordingGroupStrength = 1
            self.family = "gopro"
            self.sequence = 0
            return
        }
        if let groups = Self.captures(#"^G[HXP]([0-9]{2})([0-9]{4})(?:[-_].*)?$"#, in: stem),
           groups.count == 2 {
            self.recordingGroup = "gopro:\(groups[1])"
            self.recordingGroupStrength = 1
            self.family = "gopro"
            self.sequence = Int(groups[0])
            return
        }
        if let groups = Self.captures(#"^DJI[_-]([0-9]{4})(?:[_-]([0-9]{3}))?.*$"#, in: stem),
           let recording = groups.first {
            self.family = "dji"
            if groups.count > 1, !groups[1].isEmpty {
                self.recordingGroup = "dji:\(recording)"
                self.recordingGroupStrength = 1
                self.sequence = Int(groups[1])
            } else {
                self.sequence = Int(recording)
            }
            return
        }
        if let groups = Self.captures(#"^(?:VID|PRO)[_-]([0-9]{8})[_-]([0-9]{6}).*?([0-9]{2,3})$"#, in: stem),
           groups.count == 3 {
            self.recordingGroup = "insta360:\(groups[0]):\(groups[1])"
            self.recordingGroupStrength = 1
            self.family = "insta360"
            self.sequence = Int(groups[2])
            self.captureDate = Self.cameraDate(day: groups[0], time: groups[1])
            return
        }
        if let groups = Self.captures(#"^(?:IMG|VID|PXL)[_-]([0-9]{8})[_-]?([0-9]{6}).*$"#, in: stem),
           groups.count == 2 {
            self.recordingGroup = "phone:\(groups[0]):\(groups[1])"
            self.recordingGroupStrength = 0.90
            self.family = "phone"
            self.sequence = Int(groups[1])
            self.captureDate = Self.cameraDate(day: groups[0], time: groups[1])
            return
        }
        if let groups = Self.captures(#"^([0-9]{8})[_-]([0-9]{6}).*$"#, in: stem),
           groups.count == 2 {
            self.recordingGroup = "phone:\(groups[0]):\(groups[1])"
            self.recordingGroupStrength = 0.88
            self.family = "phone"
            self.sequence = Int(groups[1])
            self.captureDate = Self.cameraDate(day: groups[0], time: groups[1])
            return
        }
        if let groups = Self.captures(#"^IMG[_-]([0-9]{3,6}).*$"#, in: stem), let value = groups.first {
            self.recordingGroup = "iphone:\(value)"
            self.recordingGroupStrength = 0.88
            self.family = "iphone"
            self.sequence = Int(value)
            return
        }
    }

    private static func captures(_ pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }

    private static func cameraDate(day: String, time: String) -> Date? {
        guard day.count == 8, time.count == 6 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: day + time)
    }
}

private struct PairLink: Sendable {
    var first: Int
    var second: Int
    var metrics: PairMetrics
}

private struct UnionFind {
    private var parents: [Int]
    private var ranks: [Int]

    init(count: Int) {
        parents = Array(0..<count)
        ranks = Array(repeating: 0, count: count)
    }

    mutating func root(_ value: Int) -> Int {
        if parents[value] != value { parents[value] = root(parents[value]) }
        return parents[value]
    }

    @discardableResult
    mutating func join(_ first: Int, _ second: Int) -> Int {
        let lhs = root(first)
        let rhs = root(second)
        guard lhs != rhs else { return lhs }
        if ranks[lhs] < ranks[rhs] {
            parents[lhs] = rhs
            return rhs
        }
        if ranks[lhs] > ranks[rhs] {
            parents[rhs] = lhs
            return lhs
        }
        parents[rhs] = lhs
        ranks[lhs] += 1
        return lhs
    }
}
