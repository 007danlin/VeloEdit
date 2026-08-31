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
                let metrics = pairMetrics(observations[first], observations[second])
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
        let grouped = Dictionary(grouping: observations.indices, by: { roots[$0] ?? $0 })
        var events = grouped.values.map { indices in
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
        let counts = Dictionary(grouping: observations, by: \.device).mapValues(\.count)
        guard let reference = counts.sorted(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }).first?.key else { return [:] }
        var samples: [String: [Double]] = [:]
        let referenceValues = observations.filter { $0.device == reference && $0.rawDate != nil && $0.dateConfidence >= 0.55 }
        for other in observations where other.device != reference && other.dateConfidence >= 0.55 {
            guard let otherDate = other.rawDate else { continue }
            let matches = referenceValues.compactMap { candidate -> (Double, Double)? in
                guard let referenceDate = candidate.rawDate else { return nil }
                let delta = otherDate.timeIntervalSince(referenceDate)
                guard abs(delta) <= 10 * 60 else { return nil }
                let semantic = jaccard(candidate.semanticTokens, other.semanticTokens)
                let spatial = gpsSimilarity(candidate.coordinate, other.coordinate) ?? 0
                let visual = visualSimilarity(candidate, other) ?? 0
                let confidence = max(semantic, spatial, visual)
                guard confidence >= 0.48 else { return nil }
                return (delta, confidence)
            }.sorted { abs($0.0) < abs($1.0) }
            if let best = matches.first, abs(best.0) >= 0.25 {
                samples[other.device, default: []].append(best.0)
            }
        }
        var result = [reference: 0.0]
        for (device, values) in samples where !values.isEmpty {
            let sorted = values.sorted()
            let median = sorted[sorted.count / 2]
            result[device] = min(300, max(-300, median))
        }
        return result
    }

    private func shouldMerge(_ metrics: PairMetrics, first: Observation, second: Observation) -> Bool {
        if metrics.hardSplit { return false }
        let gap = dateGap(first.normalizedDate, second.normalizedDate)
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
            let preciseSemanticMatch = !first.semanticEventIDs.isDisjoint(with: second.semanticEventIDs)
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

    private func pairMetrics(_ first: Observation, _ second: Observation) -> PairMetrics {
        let gap = dateGap(first.normalizedDate, second.normalizedDate)
        let rawTemporal = temporalSimilarity(gap: gap, datesAvailable: first.normalizedDate != nil && second.normalizedDate != nil)
        let temporal = rawTemporal * (0.35 + min(first.dateConfidence, second.dateConfidence) * 0.65)
        let gps = gpsSimilarity(first.coordinate, second.coordinate)
        let visual = visualSimilarity(first, second)
        var semantic = optionalJaccard(first.semanticTokens, second.semanticTokens)
        if !first.semanticEventIDs.isDisjoint(with: second.semanticEventIDs) {
            semantic = max(semantic ?? 0, 1)
        }
        let activity = optionalJaccard(first.activityTokens, second.activityTokens)
        let people = optionalJaccard(first.peopleTokens, second.peopleTokens)
        let audio = optionalJaccard(first.audioTokens, second.audioTokens)
        let filename = filenameSimilarity(first.filenameIdentity, second.filenameIdentity)
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
            hardSplit: hardSplit
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
        let memberIDs = Set(members.map(\.asset.id))
        let membersByID = Dictionary(uniqueKeysWithValues: members.map { ($0.asset.id, $0) })
        let energies = groups.map { group -> Double in
            let candidates = group.assetIDs.compactMap { membersByID[$0] }.flatMap(\.candidates)
            guard !candidates.isEmpty else { return 0.35 }
            return candidates.reduce(0) {
                $0 + ($1.insights?.dynamics ?? $1.scores.action) * 0.72 + $1.scores.quality * 0.28
            } / Double(candidates.count)
        }
        let peakIndex = energies.indices.max(by: { energies[$0] < energies[$1] }) ?? 0
        return groups.enumerated().map { index, group in
            let groupMembers = group.assetIDs.compactMap { membersByID[$0] }
            let candidates = groupMembers.flatMap(\.candidates).sorted {
                let lhsAsset = group.assetIDs.firstIndex(of: $0.assetID) ?? Int.max
                let rhsAsset = group.assetIDs.firstIndex(of: $1.assetID) ?? Int.max
                if lhsAsset != rhsAsset { return lhsAsset < rhsAsset }
                return $0.sourceStart < $1.sourceStart
            }
            let tags = groupMembers.reduce(into: Set<String>()) { $0.formUnion($1.semanticTokens) }
            let phase: EventScenePhase
            if groups.count == 1 { phase = .peak }
            else if index == peakIndex { phase = .peak }
            else if index == 0 { phase = .setup }
            else if index < peakIndex { phase = index + 1 == peakIndex ? .preparation : .action }
            else if index == peakIndex + 1 { phase = .reaction }
            else if index == groups.count - 1 { phase = .conclusion }
            else { phase = .reaction }
            let dates = groupMembers.compactMap(\.normalizedDate)
            return EventScene(
                id: stableUUID(namespace: "event-scene:\(eventID.uuidString)", components: [group.id.uuidString]),
                title: group.title,
                startDate: dates.min(),
                endDate: groupMembers.compactMap { member in
                    member.normalizedDate.map { $0.addingTimeInterval(member.asset.metadata.duration ?? 0) }
                }.max() ?? dates.max(),
                assetIDs: group.assetIDs.filter(memberIDs.contains),
                candidateIDs: candidates.map(\.id),
                tags: tags,
                phase: phase,
                confidence: group.confidence
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

    private func visualSimilarity(_ first: Observation, _ second: Observation) -> Double? {
        guard !first.candidates.isEmpty, !second.candidates.isEmpty else { return nil }
        let index = SemanticSceneIndex(candidates: first.candidates + second.candidates)
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
        personalAdjustments: [String: Double] = [:]
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
    var activityTokens: Set<String>
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
            self.dateConfidence = asset.metadata.dateConfidence ?? 0.12
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
        let activities = ["action", "sport", "cycling", "bike", "bicycle", "cyclist", "fishing", "rafting", "kayak", "hiking", "running", "swimming", "driving", "travel", "boat", "ski", "snowboard", "сплав", "рыбалка", "велосипед", "поход", "плавание", "дорога"]
        self.activityTokens = Set(semantic.filter { token in activities.contains(where: token.contains) })
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

    mutating func join(_ first: Int, _ second: Int) {
        let lhs = root(first)
        let rhs = root(second)
        guard lhs != rhs else { return }
        if ranks[lhs] < ranks[rhs] { parents[lhs] = rhs }
        else if ranks[lhs] > ranks[rhs] { parents[rhs] = lhs }
        else { parents[rhs] = lhs; ranks[lhs] += 1 }
    }
}
