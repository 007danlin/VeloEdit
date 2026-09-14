import Foundation
import CryptoKit

public enum SourceSequencePattern: String, Codable, Hashable, Sendable {
    case goPro
    case dji
    case cinemaReel
    case cameraClip
    case numberedMedia
    case numericStem
    case timestamp
    case genericNumeric
}

/// Camera-independent interpretation of the ordering information encoded in a
/// filename. `sequenceID` is the recording/clip number; `subSequenceID` is a
/// chapter or part number when the camera exposes one.
public struct SourceSequenceMatch: Codable, Hashable, Sendable {
    public var pattern: SourceSequencePattern
    public var family: String
    public var seriesKey: String
    public var sequenceID: Int
    public var subSequenceID: Int?
    public var recordingKey: String?
    public var captureDate: Date?
    public var confidence: Double
    public var matchedComponent: String

    public init(
        pattern: SourceSequencePattern,
        family: String,
        seriesKey: String,
        sequenceID: Int,
        subSequenceID: Int? = nil,
        recordingKey: String? = nil,
        captureDate: Date? = nil,
        confidence: Double,
        matchedComponent: String
    ) {
        self.pattern = pattern
        self.family = family
        self.seriesKey = seriesKey
        self.sequenceID = max(0, sequenceID)
        self.subSequenceID = subSequenceID.map { max(0, $0) }
        self.recordingKey = recordingKey
        self.captureDate = captureDate
        self.confidence = confidence.clamped01
        self.matchedComponent = matchedComponent
    }

    public var displayValue: String {
        if let subSequenceID, subSequenceID > 0,
           !(pattern == .goPro && subSequenceID == 1) {
            return "\(sequenceID).\(subSequenceID)"
        }
        return String(sequenceID)
    }
}

/// Extensible filename adapter used only as evidence. It never assumes that
/// all inputs come from one vendor and it deliberately returns nil when a name
/// has no defensible numeric sequence.
public struct SourceSequenceDetector: Sendable {
    public init() {}

    public func detect(fileName: String) -> SourceSequenceMatch? {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent.uppercased()

        // GoPro recording number is the trailing four digits. The leading two
        // digits on chapter names are the part, not the archive chronology.
        if let groups = captures(#"^GOPR([0-9]{4})(?:[-_].*)?$"#, in: stem),
           let value = groups.first, let recording = Int(value) {
            return SourceSequenceMatch(
                pattern: .goPro, family: "gopro", seriesKey: "camera:gopro",
                sequenceID: recording, subSequenceID: 0,
                recordingKey: "gopro:\(recording)", confidence: 0.99,
                matchedComponent: value
            )
        }
        if let groups = captures(#"^G[HXP]([0-9]{2})([0-9]{4})(?:[-_].*)?$"#, in: stem),
           groups.count == 2, let chapter = Int(groups[0]), let recording = Int(groups[1]) {
            return SourceSequenceMatch(
                pattern: .goPro, family: "gopro", seriesKey: "camera:gopro",
                sequenceID: recording, subSequenceID: chapter,
                recordingKey: "gopro:\(recording)", confidence: 0.99,
                matchedComponent: groups[1]
            )
        }

        if let groups = captures(#"^DJI[_-]([0-9]{3,8})(?:[_-]([0-9]{1,4}))?.*$"#, in: stem),
           let value = groups.first, let sequence = Int(value) {
            let part = groups.count > 1 && !groups[1].isEmpty ? Int(groups[1]) : nil
            return SourceSequenceMatch(
                pattern: .dji, family: "dji", seriesKey: "camera:dji",
                sequenceID: sequence, subSequenceID: part,
                recordingKey: part == nil ? nil : "dji:\(sequence)", confidence: 0.97,
                matchedComponent: value
            )
        }

        // ARRI/Sony/Canon-style reel and clip identifiers, including
        // A001_C001_0101AB.MXF. The reel scopes the sequence to one camera roll.
        if let groups = captures(#"^([A-Z][0-9]{3})[_-]C([0-9]{3,6})(?:[_-]([0-9]{2,8})[A-Z]*)?.*$"#, in: stem),
           groups.count >= 2, let clip = Int(groups[1]) {
            return SourceSequenceMatch(
                pattern: .cinemaReel, family: "cinema", seriesKey: "reel:\(groups[0])",
                sequenceID: clip,
                subSequenceID: groups.count > 2 && !groups[2].isEmpty ? Int(groups[2]) : nil,
                confidence: 0.98, matchedComponent: groups[1]
            )
        }

        if let groups = captures(#"^C([0-9]{3,7})(?:[-_].*)?$"#, in: stem),
           let value = groups.first, let sequence = Int(value) {
            return SourceSequenceMatch(
                pattern: .cameraClip, family: "camera-clip", seriesKey: "camera:c",
                sequenceID: sequence, confidence: 0.94, matchedComponent: value
            )
        }

        if let groups = captures(#"^(?:IMG|VID|MVI|DSC|MOV|CLIP)[_-]([0-9]{8})[_-]?([0-9]{6})(?:[-_].*)?$"#, in: stem),
           groups.count == 2,
           let captureDate = cameraDate(day: groups[0], time: groups[1]),
           let sequence = secondsOfDay(groups[1]) {
            return SourceSequenceMatch(
                pattern: .timestamp, family: "timestamp-media", seriesKey: "date:\(groups[0])",
                sequenceID: sequence, captureDate: captureDate, confidence: 0.96,
                matchedComponent: groups[0] + groups[1]
            )
        }
        if let groups = captures(#"^([0-9]{8})[_-]([0-9]{6})(?:[-_].*)?$"#, in: stem),
           groups.count == 2,
           let captureDate = cameraDate(day: groups[0], time: groups[1]),
           let sequence = secondsOfDay(groups[1]) {
            return SourceSequenceMatch(
                pattern: .timestamp, family: "timestamp", seriesKey: "date:\(groups[0])",
                sequenceID: sequence, captureDate: captureDate, confidence: 0.94,
                matchedComponent: groups[0] + groups[1]
            )
        }

        if let groups = captures(#"^(IMG|VID|MVI|DSC|MOV|CLIP)[_-]([0-9]{3,8})(?:[-_].*)?$"#, in: stem),
           groups.count == 2, let sequence = Int(groups[1]) {
            let family = groups[0].lowercased()
            return SourceSequenceMatch(
                pattern: .numberedMedia, family: family, seriesKey: "camera:\(family)",
                sequenceID: sequence, recordingKey: "\(family):\(sequence)",
                confidence: 0.92, matchedComponent: groups[1]
            )
        }

        if let groups = captures(#"^([0-9]{3,10})$"#, in: stem),
           let value = groups.first, let sequence = Int(value) {
            return SourceSequenceMatch(
                pattern: .numericStem, family: "numeric", seriesKey: "camera:numeric",
                sequenceID: sequence, confidence: 0.90, matchedComponent: value
            )
        }

        // Conservative final adapter for unknown cameras. The surrounding
        // non-numeric skeleton prevents unrelated naming schemes from sharing
        // one sequence, and its lower confidence keeps it below real metadata.
        let ranges = digitRuns(in: stem).filter { $0.value.count >= 2 && $0.value.count <= 9 }
        guard let run = ranges.last, let sequence = Int(run.value) else { return nil }
        var skeleton = stem
        skeleton.replaceSubrange(run.range, with: "#")
        return SourceSequenceMatch(
            pattern: .genericNumeric, family: "generic", seriesKey: "generic:\(skeleton)",
            sequenceID: sequence, confidence: 0.56, matchedComponent: run.value
        )
    }

    private func captures(_ pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }

    private func digitRuns(in value: String) -> [(range: Range<String.Index>, value: String)] {
        var result: [(Range<String.Index>, String)] = []
        var start: String.Index?
        var index = value.startIndex
        while index < value.endIndex {
            if value[index].isNumber {
                if start == nil { start = index }
            } else if let runStart = start {
                result.append((runStart..<index, String(value[runStart..<index])))
                start = nil
            }
            index = value.index(after: index)
        }
        if let start { result.append((start..<value.endIndex, String(value[start..<value.endIndex]))) }
        return result
    }

    private func cameraDate(day: String, time: String) -> Date? {
        guard day.count == 8, time.count == 6 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: day + time)
    }

    private func secondsOfDay(_ value: String) -> Int? {
        guard value.count == 6,
              let hour = Int(value.prefix(2)),
              let minute = Int(value.dropFirst(2).prefix(2)),
              let second = Int(value.suffix(2)),
              hour < 24, minute < 60, second < 60 else { return nil }
        return hour * 3_600 + minute * 60 + second
    }
}

public struct SourceMapEvidence: Codable, Hashable, Sendable {
    public var kind: String
    public var score: Double
    public var explanation: String

    public init(kind: String, score: Double, explanation: String) {
        self.kind = kind
        self.score = score.clamped01
        self.explanation = explanation
    }
}

public struct SourceMapEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID { assetID }
    public var assetID: UUID
    public var displayName: String
    public var order: Int
    public var sequence: SourceSequenceMatch?
    public var captureDate: Date?
    public var chronologyConfidence: Double
    public var activityGroupID: UUID
    public var activityTitle: String
    public var activityConfidence: Double
    public var evidence: [SourceMapEvidence]

    public init(
        assetID: UUID,
        displayName: String,
        order: Int,
        sequence: SourceSequenceMatch?,
        captureDate: Date?,
        chronologyConfidence: Double,
        activityGroupID: UUID,
        activityTitle: String,
        activityConfidence: Double,
        evidence: [SourceMapEvidence]
    ) {
        self.assetID = assetID
        self.displayName = displayName
        self.order = max(0, order)
        self.sequence = sequence
        self.captureDate = captureDate
        self.chronologyConfidence = chronologyConfidence.clamped01
        self.activityGroupID = activityGroupID
        self.activityTitle = activityTitle
        self.activityConfidence = activityConfidence.clamped01
        self.evidence = evidence
    }
}

public struct SourceActivityGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var order: Int
    public var title: String
    public var assetIDs: [UUID]
    public var confidence: Double
    public var evidence: [SourceMapEvidence]

    public init(id: UUID, order: Int, title: String, assetIDs: [UUID], confidence: Double, evidence: [SourceMapEvidence]) {
        self.id = id
        self.order = max(0, order)
        self.title = title
        self.assetIDs = assetIDs
        self.confidence = confidence.clamped01
        self.evidence = evidence
    }
}

public struct SourceMap: Codable, Hashable, Sendable {
    public var entries: [SourceMapEntry]
    public var activityGroups: [SourceActivityGroup]
    public var generatedAt: Date

    public init(entries: [SourceMapEntry], activityGroups: [SourceActivityGroup], generatedAt: Date = Date()) {
        self.entries = entries.sorted { $0.order < $1.order }
        self.activityGroups = activityGroups.sorted { $0.order < $1.order }
        self.generatedAt = generatedAt
    }

    public static let empty = SourceMap(entries: [], activityGroups: [], generatedAt: Date(timeIntervalSince1970: 0))
    public var orderedAssetIDs: [UUID] { entries.sorted { $0.order < $1.order }.map(\.assetID) }
}

/// Archive-level pass run before Event Intelligence and Story Engine. It first
/// establishes one source order, then groups only adjacent sources using the
/// same visual, semantic, audio, GPS and telemetry evidence used downstream.
public struct SourceTimelineAnalyzer: Sendable {
    public var groupingThreshold: Double

    public init(groupingThreshold: Double = 0.60) {
        self.groupingThreshold = groupingThreshold.clamped01
    }

    public func analyze(assets: [MediaAsset], analyses: [AnalysisResult]) -> SourceMap {
        let assets = assets.map { asset in
            var copy = asset
            copy.metadata = MediaCaptureClock.metadata(for: asset)
            return copy
        }
        let analysesByAsset = Dictionary(uniqueKeysWithValues: analyses.map { ($0.assetID, $0) })
        var nodes = assets
            .filter { !$0.excluded && !$0.missing }
            .map { Node(asset: $0, analysis: analysesByAsset[$0.id]) }
        guard !nodes.isEmpty else { return .empty }

        let sequenceGroups = Dictionary(grouping: nodes.indices.compactMap { index in
            nodes[index].sequence.map { sequence in
                let day = nodes[index].captureDate.map { Calendar.current.startOfDay(for: $0).timeIntervalSince1970 }
                return (sequence.seriesKey + (day.map { "|\($0)" } ?? "|undated"), index)
            }
        }, by: { $0.0 })
        for (_, members) in sequenceGroups {
            let indices = members.map(\.1)
            guard indices.count >= 2 else { continue }
            let reliableEmbeddedDates = indices.filter { nodes[$0].dateReliability >= 0.90 }.count
            // Trust a complete set of high-confidence embedded capture clocks
            // even when filename numbers disagree. Sequence becomes dominant
            // only when at least one real timestamp is unavailable/unreliable.
            let useSequence = reliableEmbeddedDates == 0
            guard useSequence else { continue }
            let sequenceOrder = indices.sorted { sequenceLess(nodes[$0], nodes[$1]) }
            let anchor = indices.compactMap { nodes[$0].captureDate }.min()
                ?? indices.map { nodes[$0].asset.importedAt }.min()
                ?? .distantPast
            var cursor = anchor
            for index in sequenceOrder {
                nodes[index].syntheticDate = cursor
                nodes[index].usesSequenceOrder = true
                cursor = cursor.addingTimeInterval(max(1, nodes[index].asset.metadata.duration ?? 1) + 1)
            }
        }

        nodes.sort(by: chronologicalLess)
        let decisions = zip(nodes, nodes.dropFirst()).map { continuity(first: $0, second: $1) }
        var rawGroups: [[Node]] = []
        var groupDecisions: [[ContinuityDecision]] = []
        for (index, node) in nodes.enumerated() {
            guard index > 0 else {
                rawGroups.append([node])
                groupDecisions.append([])
                continue
            }
            let decision = decisions[index - 1]
            if decision.shouldGroup {
                rawGroups[rawGroups.count - 1].append(node)
                groupDecisions[groupDecisions.count - 1].append(decision)
            } else {
                rawGroups.append([node])
                groupDecisions.append([])
            }
        }

        var groups: [SourceActivityGroup] = []
        var groupByAsset: [UUID: SourceActivityGroup] = [:]
        for (index, members) in rawGroups.enumerated() {
            let decisions = groupDecisions[index]
            let tags = members.reduce(into: Set<String>()) { $0.formUnion($1.semanticTokens) }
            let titleDecision = activityTitle(tags: tags, memberCount: members.count)
            let confidence: Double
            if decisions.isEmpty {
                confidence = (0.52 + members[0].chronologyConfidence * 0.18 + titleDecision.confidence * 0.12).clamped01
            } else {
                confidence = (decisions.map(\.score).reduce(0, +) / Double(decisions.count) * 0.76 + titleDecision.confidence * 0.24).clamped01
            }
            var evidence = decisions.flatMap(\.evidence)
            evidence.append(SourceMapEvidence(kind: "activity", score: titleDecision.confidence, explanation: titleDecision.explanation))
            evidence = strongestEvidence(evidence)
            let assetIDs = members.map(\.asset.id)
            let id = stableUUID(namespace: "source-activity", components: assetIDs.map(\.uuidString))
            let group = SourceActivityGroup(id: id, order: index, title: titleDecision.title, assetIDs: assetIDs, confidence: confidence, evidence: evidence)
            groups.append(group)
            assetIDs.forEach { groupByAsset[$0] = group }
        }

        let entries = nodes.enumerated().compactMap { index, node -> SourceMapEntry? in
            guard let group = groupByAsset[node.asset.id] else { return nil }
            var evidence: [SourceMapEvidence] = []
            if let sequence = node.sequence {
                evidence.append(SourceMapEvidence(
                    kind: "sequence", score: sequence.confidence,
                    explanation: "Из имени извлечён sequence ID \(sequence.displayValue) (\(sequence.pattern.rawValue))"
                ))
            }
            if let source = node.asset.metadata.dateSource {
                evidence.append(SourceMapEvidence(
                    kind: "timestamp", score: node.dateReliability,
                    explanation: "Временная метка: \(localizedDateSource(source))"
                ))
            }
            if node.usesSequenceOrder {
                evidence.append(SourceMapEvidence(
                    kind: "ordering", score: node.sequence?.confidence ?? 0.5,
                    explanation: "Sequence ID восстановил порядок при отсутствующей или ненадёжной metadata"
                ))
            }
            return SourceMapEntry(
                assetID: node.asset.id,
                displayName: node.asset.displayName,
                order: index,
                sequence: node.sequence,
                captureDate: node.captureDate,
                chronologyConfidence: node.chronologyConfidence,
                activityGroupID: group.id,
                activityTitle: group.title,
                activityConfidence: group.confidence,
                evidence: strongestEvidence(evidence)
            )
        }
        return SourceMap(entries: entries, activityGroups: groups)
    }

    private func chronologicalLess(_ first: Node, _ second: Node) -> Bool {
        let lhs = first.syntheticDate ?? first.captureDate
        let rhs = second.syntheticDate ?? second.captureDate
        if let lhs, let rhs { if lhs != rhs { return lhs < rhs } }
        else if lhs != nil { return true }
        else if rhs != nil { return false }
        if let left = first.sequence, let right = second.sequence,
           left.seriesKey == right.seriesKey {
            return sequenceLess(first, second)
        }
        if first.asset.importedAt != second.asset.importedAt { return first.asset.importedAt < second.asset.importedAt }
        return first.asset.id.uuidString < second.asset.id.uuidString
    }

    private func sequenceLess(_ first: Node, _ second: Node) -> Bool {
        guard let lhs = first.sequence, let rhs = second.sequence else {
            return first.asset.id.uuidString < second.asset.id.uuidString
        }
        if lhs.sequenceID != rhs.sequenceID { return lhs.sequenceID < rhs.sequenceID }
        if (lhs.subSequenceID ?? 0) != (rhs.subSequenceID ?? 0) {
            return (lhs.subSequenceID ?? 0) < (rhs.subSequenceID ?? 0)
        }
        return first.asset.id.uuidString < second.asset.id.uuidString
    }

    private func sequenceInversionRatio(indices: [Int], nodes: [Node]) -> Double {
        let dated = indices.filter { nodes[$0].captureDate != nil }
            .sorted { (nodes[$0].captureDate ?? .distantFuture) < (nodes[$1].captureDate ?? .distantFuture) }
        guard dated.count >= 2 else { return 1 }
        var inversions = 0
        var comparisons = 0
        for first in dated.indices {
            for second in dated.indices where second > first {
                comparisons += 1
                if sequenceLess(nodes[dated[second]], nodes[dated[first]]) { inversions += 1 }
            }
        }
        return comparisons == 0 ? 0 : Double(inversions) / Double(comparisons)
    }

    private func continuity(first: Node, second: Node) -> ContinuityDecision {
        let sequence = sequenceContinuity(first.sequence, second.sequence)
        let temporal = temporalContinuity(first: first, second: second)
        let gps = gpsContinuity(first: first, second: second)
        let speed = scalarContinuity(first.endSpeed, second.startSpeed, scale: 12)
        let visual = boundaryVisualContinuity(first: first, second: second)
        let semantic = optionalJaccard(first.semanticTokens, second.semanticTokens)
        let activity = optionalJaccard(first.activityTokens, second.activityTokens)
        let audio = optionalJaccard(first.audioTokens, second.audioTokens)
        let weighted: [(Double?, Double)] = [
            (sequence?.score, 0.25), (temporal, 0.18), (gps, 0.15), (speed, 0.04),
            (visual, 0.16), (semantic, 0.13), (activity, 0.06), (audio, 0.03)
        ]
        let available = weighted.compactMap { value, weight in value.map { ($0, weight) } }
        let score = available.reduce(0) { $0 + $1.0 * $1.1 } / max(0.000_001, available.reduce(0) { $0 + $1.1 })
        let distance = coordinateDistance(first.endCoordinate, second.startCoordinate)
        let hardSplit = (distance ?? 0) > 30_000
            || temporalHardSplit(first: first, second: second)
            || strongActivityConflict(first.activityTokens, second.activityTokens)
        let contentSupport = max(visual ?? 0, semantic ?? 0, activity ?? 0, gps ?? 0, audio ?? 0)
        let shouldGroup: Bool
        if hardSplit {
            shouldGroup = false
        } else if first.sequence?.recordingKey != nil,
                  first.sequence?.recordingKey == second.sequence?.recordingKey {
            shouldGroup = true
        } else if let sequence {
            if sequence.primaryGap <= 4 {
                shouldGroup = score >= groupingThreshold - 0.08 && contentSupport >= 0.30
            } else if sequence.primaryGap <= 8 {
                shouldGroup = score >= groupingThreshold + 0.03
                    && max(activity ?? 0, semantic ?? 0, gps ?? 0) >= 0.62
                    && (visual ?? 0.55) >= 0.55
            } else {
                shouldGroup = false
            }
        } else {
            let closeCapture = (temporal ?? 0) >= 0.82
            shouldGroup = score >= groupingThreshold
                && closeCapture
                && (contentSupport >= 0.42 || (gps ?? 0) >= 0.82)
        }
        var evidence: [SourceMapEvidence] = []
        if let sequence {
            evidence.append(SourceMapEvidence(kind: "sequence", score: sequence.score, explanation: "Соседние sequence ID; расстояние \(sequence.primaryGap)"))
        }
        if let temporal { evidence.append(SourceMapEvidence(kind: "proximity", score: temporal, explanation: "Временная близость соседних файлов")) }
        if let gps { evidence.append(SourceMapEvidence(kind: "gps", score: gps, explanation: "Непрерывность GPS/маршрута")) }
        if let speed { evidence.append(SourceMapEvidence(kind: "telemetry", score: speed, explanation: "Согласованная скорость на границе файлов")) }
        if let visual { evidence.append(SourceMapEvidence(kind: "visual", score: visual, explanation: "Визуальная непрерывность конца и начала файлов")) }
        if let semantic { evidence.append(SourceMapEvidence(kind: "semantic", score: semantic, explanation: "Совпадает содержание исходников")) }
        if let activity { evidence.append(SourceMapEvidence(kind: "activity", score: activity, explanation: "Продолжается одна активность")) }
        if let audio { evidence.append(SourceMapEvidence(kind: "audio", score: audio, explanation: "Согласованный акустический контекст")) }
        return ContinuityDecision(score: score.clamped01, shouldGroup: shouldGroup, evidence: strongestEvidence(evidence))
    }

    private func sequenceContinuity(_ first: SourceSequenceMatch?, _ second: SourceSequenceMatch?) -> (score: Double, primaryGap: Int)? {
        guard let first, let second, first.seriesKey == second.seriesKey else { return nil }
        let detectorConfidence = min(first.confidence, second.confidence)
        if first.sequenceID == second.sequenceID {
            let partGap = abs((second.subSequenceID ?? 0) - (first.subSequenceID ?? 0))
            let raw: Double = partGap <= 1 ? 1 : partGap <= 3 ? 0.82 : 0.45
            return (raw * detectorConfidence, 0)
        }
        let gap = second.sequenceID - first.sequenceID
        guard gap > 0 else { return (0, abs(gap)) }
        switch gap {
        case 1: return (1 * detectorConfidence, gap)
        case 2...4: return (0.88 * detectorConfidence, gap)
        case 5...8: return (0.56 * detectorConfidence, gap)
        case 9...16: return (0.25 * detectorConfidence, gap)
        default: return (0.05 * detectorConfidence, gap)
        }
    }

    private func temporalContinuity(first: Node, second: Node) -> Double? {
        guard let left = first.captureDate, let right = second.captureDate else { return nil }
        let startGap = abs(right.timeIntervalSince(left))
        let endGap = abs(right.timeIntervalSince(left.addingTimeInterval(first.asset.metadata.duration ?? 0)))
        let gap = min(startGap, endGap)
        let raw: Double
        switch gap {
        case ...5: raw = 1
        case ...90: raw = 0.94
        case ...(5 * 60): raw = 0.76
        case ...(30 * 60): raw = 0.48
        case ...(3 * 3_600): raw = 0.24
        default: raw = 0.05
        }
        return raw * (0.38 + min(first.dateReliability, second.dateReliability) * 0.62)
    }

    private func temporalHardSplit(first: Node, second: Node) -> Bool {
        guard min(first.dateReliability, second.dateReliability) >= 0.65,
              let left = first.captureDate, let right = second.captureDate else { return false }
        let gap = right.timeIntervalSince(left.addingTimeInterval(first.asset.metadata.duration ?? 0))
        return gap > 45 * 60 || !Calendar.current.isDate(left, inSameDayAs: right)
    }

    private func gpsContinuity(first: Node, second: Node) -> Double? {
        guard let distance = coordinateDistance(first.endCoordinate, second.startCoordinate) else { return nil }
        switch distance {
        case ...80: return 1
        case ...500: return 0.90
        case ...2_500: return 0.68
        case ...12_000: return 0.30
        default: return 0
        }
    }

    private func boundaryVisualContinuity(first: Node, second: Node) -> Double? {
        guard let left = first.candidates.sorted(by: { $0.sourceStart < $1.sourceStart }).last,
              let right = second.candidates.sorted(by: { $0.sourceStart < $1.sourceStart }).first else { return nil }
        return SemanticSceneIndex(candidates: [left, right]).similarity(between: left, and: right)
    }

    private func scalarContinuity(_ first: Double?, _ second: Double?, scale: Double) -> Double? {
        guard let first, let second else { return nil }
        return max(0, 1 - abs(first - second) / max(0.001, scale))
    }

    private func optionalJaccard(_ first: Set<String>, _ second: Set<String>) -> Double? {
        guard !first.isEmpty, !second.isEmpty else { return nil }
        let union = first.union(second)
        return union.isEmpty ? nil : Double(first.intersection(second).count) / Double(union.count)
    }

    private func strongActivityConflict(_ first: Set<String>, _ second: Set<String>) -> Bool {
        guard !first.isEmpty, !second.isEmpty, first.isDisjoint(with: second) else { return false }
        let specific: Set<String> = ["cycling", "fishing", "rafting", "hiking", "running", "swimming", "skiing", "driving", "buggy"]
        return !first.intersection(specific).isEmpty && !second.intersection(specific).isEmpty
    }

    private func activityTitle(tags: Set<String>, memberCount: Int) -> (title: String, confidence: Double, explanation: String) {
        let text = tags.joined(separator: " ").lowercased()
        func has(_ values: [String]) -> Bool { values.contains(where: text.contains) }
        // Small off-road buggies are often mislabeled as `bicycle` or the very
        // broad `machine`. Fuse independent evidence across an adjacent
        // two-camera/two-file block instead of requiring three literal
        // `buggy` labels. A real cycling signal still wins over a stray car in
        // the background.
        let explicitBuggy = has(["buggy", "багги", "utv", "side-by-side", "side by side"])
        let offRoad = has(["dirt_road", "off-road", "offroad", "trail", "road"])
        // `vehicle` is intentionally not motor-specific: vision commonly tags
        // a bicycle as both `vehicle` and `machine`. Require evidence that
        // cannot be satisfied by an ordinary mountain-bike ride.
        let motorVehicle = has(["car", "automobile", "motor_vehicle", "motor vehicle", "off-road vehicle"])
        let mechanics = has(["machine", "wheel", "tire", "tyre"])
        let safetyGear = has(["helmet", "headgear"])
        let strongCycling = has(["cycling", "cyclist", "велосипедист"])
        if explicitBuggy || (
            memberCount >= 2 && offRoad && motorVehicle && mechanics && safetyGear && !strongCycling
        ) {
            let confidence = explicitBuggy ? 0.96 : 0.84
            return ("Багги", confidence, "Грунтовая дорога, автомобиль, колёса и защитная экипировка совместно подтверждают поездку на багги")
        }
        if let decision = SmartTitleEngine().decide(SmartTitleContext(purpose: .shortLabel, tags: tags)) {
            return (decision.primaryText, decision.confidence, decision.explanation.first ?? "Название следует распознанному содержанию")
        }
        return ("Съёмка", 0.28, "Недостаточно семантических данных: нейтральная внутренняя метка не используется как экранный титр")
    }

    private func localizedDateSource(_ source: MediaDateSource) -> String {
        switch source {
        case .embeddedMetadata: return "встроенная metadata"
        case .fileCreationDate: return "дата создания файла"
        case .fileModificationDate: return "дата изменения файла"
        case .importDate: return "время импорта (fallback)"
        }
    }

    private func strongestEvidence(_ values: [SourceMapEvidence]) -> [SourceMapEvidence] {
        var best: [String: SourceMapEvidence] = [:]
        for value in values where value.score > (best[value.kind]?.score ?? -1) { best[value.kind] = value }
        return best.values.sorted { $0.score > $1.score }.prefix(7).map { $0 }
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

    private func stableUUID(namespace: String, components: [String]) -> UUID {
        let payload = ([namespace] + components).joined(separator: "\u{1F}")
        var bytes = Array(SHA256.hash(data: Data(payload.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

private struct ContinuityDecision: Sendable {
    var score: Double
    var shouldGroup: Bool
    var evidence: [SourceMapEvidence]
}

private struct Node: Sendable {
    var asset: MediaAsset
    var analysis: AnalysisResult?
    var sequence: SourceSequenceMatch?
    var captureDate: Date?
    var dateReliability: Double
    var syntheticDate: Date?
    var usesSequenceOrder = false
    var semanticTokens: Set<String>
    var activityTokens: Set<String>
    var audioTokens: Set<String>
    var candidates: [Candidate]
    var startCoordinate: TelemetryCoordinate?
    var endCoordinate: TelemetryCoordinate?
    var startSpeed: Double?
    var endSpeed: Double?

    init(asset: MediaAsset, analysis: AnalysisResult?) {
        self.asset = asset
        self.analysis = analysis
        let sequence = SourceSequenceDetector().detect(fileName: asset.displayName)
        self.sequence = sequence
        self.captureDate = asset.metadata.effectiveCaptureDate ?? sequence?.captureDate
        switch asset.metadata.dateSource {
        case .embeddedMetadata: self.dateReliability = asset.metadata.dateConfidence ?? 0.98
        case .fileCreationDate: self.dateReliability = asset.metadata.dateConfidence ?? 0.68
        case .fileModificationDate: self.dateReliability = asset.metadata.dateConfidence ?? 0.32
        case .importDate: self.dateReliability = asset.metadata.dateConfidence ?? 0.12
        case nil: self.dateReliability = sequence?.captureDate == nil ? 0.10 : 0.72
        }
        self.syntheticDate = nil
        self.candidates = analysis?.directorCandidates ?? []

        var tokens = Set((analysis?.sceneTags ?? []).map(Self.normalize))
        for scene in analysis?.scenes ?? [] {
            tokens.formUnion(scene.people.map(Self.normalize))
            tokens.formUnion(scene.objects.map(Self.normalize))
            tokens.formUnion(scene.recommendedUses.map(Self.normalize))
            if let location = scene.location { tokens.insert(Self.normalize(location)) }
            if let summary = scene.semanticDescription { tokens.formUnion(Self.words(summary)) }
        }
        for candidate in self.candidates {
            tokens.formUnion(candidate.tags.map(Self.normalize))
            if let summary = candidate.insights?.sceneSummary { tokens.formUnion(Self.words(summary)) }
        }
        let noise: Set<String> = [
            "4k", "horizontal", "telemetry-event", "g-force", "intro", "outro", "b-roll",
            "adult", "object", "salient-object", "peak", "action"
        ]
        self.semanticTokens = tokens.filter { $0.count >= 3 && !noise.contains($0) && !$0.hasPrefix("gx0") }

        var activities = Set<String>()
        let activityAliases: [(String, [String])] = [
            ("buggy", ["buggy", "багги", "utv", "side-by-side"]),
            ("cycling", ["cycling", "cyclist", "bicycle", "bike", "велосип"]),
            ("fishing", ["fishing", "рыбал"]),
            ("rafting", ["rafting", "kayak", "каяк", "сплав"]),
            ("hiking", ["hiking", "поход"]),
            ("running", ["running", "бег"]),
            ("swimming", ["swimming", "плавание"]),
            ("skiing", ["ski", "snowboard", "лыж"]),
            ("driving", ["driving", "vehicle", "road", "дорога"])
        ]
        let joined = self.semanticTokens.joined(separator: " ")
        for (activity, aliases) in activityAliases where aliases.contains(where: joined.contains) { activities.insert(activity) }
        self.activityTokens = activities

        let audioEvents = (analysis?.audioAnalysis?.events ?? []) + self.candidates.flatMap { $0.insights?.audioEvents ?? [] }
        self.audioTokens = Set(audioEvents.filter { $0.confidence >= 0.42 }.map { $0.kind.rawValue })
        let samples = analysis?.telemetry?.timedSamples ?? []
        let coordinates = samples.compactMap(\.coordinate)
        let route = analysis?.telemetry?.route ?? []
        self.startCoordinate = coordinates.first ?? route.first ?? Self.assetCoordinate(asset)
        self.endCoordinate = coordinates.last ?? route.last ?? Self.assetCoordinate(asset)
        let speeds = samples.compactMap(\.speedMetersPerSecond)
        self.startSpeed = speeds.first ?? analysis?.telemetry?.speedSamplesMetersPerSecond?.first
        self.endSpeed = speeds.last ?? analysis?.telemetry?.speedSamplesMetersPerSecond?.last
    }

    var chronologyConfidence: Double {
        if dateReliability >= 0.90 && !usesSequenceOrder { return dateReliability.clamped01 }
        if usesSequenceOrder, let sequence { return (sequence.confidence * 0.82 + dateReliability * 0.18).clamped01 }
        if let sequence { return max(dateReliability, sequence.confidence * 0.72).clamped01 }
        return dateReliability.clamped01
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func words(_ value: String) -> Set<String> {
        Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
    }

    private static func assetCoordinate(_ asset: MediaAsset) -> TelemetryCoordinate? {
        guard let latitude = asset.metadata.latitude, let longitude = asset.metadata.longitude else { return nil }
        return TelemetryCoordinate(latitude: latitude, longitude: longitude)
    }
}
