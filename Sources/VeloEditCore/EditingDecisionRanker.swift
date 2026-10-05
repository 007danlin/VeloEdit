import Foundation

public struct EditingDecisionSelection: Codable, Hashable, Sendable {
    public var modelID: String
    public var legacyStrategy: String
    public var selectedStrategy: String
    public var labelProvenance: String
    public var legacyTimelineID: UUID? = nil
    public var selectedTimelineID: UUID? = nil
    /// Present only when finite model scores actually participated in selection.
    public var evaluatedCandidateCount: Int? = nil
    public var legacyUtility: Double? = nil
    public var selectedUtility: Double? = nil
}

/// Small, inspectable pairwise model. It estimates technical preference, not
/// artistic merit or scene understanding. All AI modes use these same features.
public struct EditingDecisionFeatures: Codable, Hashable, Sendable {
    // v2 counts only evidenced actions; v1 treated generic activity peaks as
    // actions. Never silently apply weights fitted to those different labels.
    public static let schemaVersion = 2
    public static let names = ["chronologyErrors", "repeatedSourceShare", "incompleteActionShare", "incompleteSpeechShare",
        "invalidRangeShare", "shortShotShare", "longShotShare", "durationVariation", "sourceCoverage", "meanSourceQuality", "speechEvidenceShare"]
    public var values: [Double]

    func safetyMeasurements(in timeline: Timeline) -> [Double] {
        let items = timeline.items.filter { $0.overlay == nil && $0.kind != .title }
        let count = Double(max(1, items.count))
        let duration = max(0.05, items.reduce(0) { $0 + $1.sourceDuration })
        // Compare absolute defects, so adding more shots cannot dilute a
        // chronology/speech/action error into a supposedly safer proportion.
        return [values[0]*count, values[1]*duration, values[2]*count, values[3]*count, values[4]*count]
    }

    public static func extract(timeline: Timeline, assets: [MediaAsset], analyses: [AnalysisResult]) -> Self {
        let items = timeline.items.filter { $0.overlay == nil && $0.kind != .title }.sorted { $0.timelineStart < $1.timelineStart }
        let candidates = Dictionary(analyses.flatMap(\.directorCandidates).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byAsset = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let count = Double(max(1, items.count)), duration = max(0.05, items.reduce(0) { $0 + $1.sourceDuration })
        var ranges: [UUID: [EditorialSourceRange]] = [:]
        var repeated = 0.0, actionCuts = 0.0, speechCuts = 0.0, invalid = 0.0, speechKnown = 0.0, quality = 0.0
        let tolerance = 1 / max(1, timeline.frameRate) + 0.001
        for item in items {
            let start = item.sourceStart, end = start + item.sourceDuration
            if let id = item.assetID, let asset = byAsset[id] {
                if item.kind == .video {
                    if start < 0 || end > (asset.metadata.duration ?? end) + tolerance { invalid += 1 }
                    let prior = ranges[id, default: []]
                    repeated += prior.reduce(0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) }
                    var merged: [EditorialSourceRange] = []
                    for range in (prior + [.init(start: start, end: end)]).sorted(by: { $0.start < $1.start }) {
                        if let last = merged.last, range.start <= last.end {
                            merged[merged.count - 1] = .init(start: last.start, end: max(last.end, range.end))
                        } else { merged.append(range) }
                    }
                    ranges[id] = merged
                }
            } else { invalid += 1 }
            if let id = item.candidateID, let candidate = candidates[id] {
                quality += candidate.scores.quality
                if let boundary = candidate.momentBoundary, boundary.confirmedActionConfidence >= 0.65,
                   start > boundary.anticipationStart + tolerance || end < boundary.completionEnd - tolerance { actionCuts += 1 }
                if let speech = candidate.insights?.speech, speech.confidence >= 0.65 {
                    speechKnown += 1
                    if timeline.effectiveOriginalAudioVolume > 0 && !item.effectiveAudioAdjustments.muted,
                       start > speech.phraseStart + tolerance || end < speech.phraseEnd - tolerance { speechCuts += 1 }
                }
            }
        }
        let lengths = items.map(\.timelineDuration), mean = lengths.reduce(0, +) / count
        let variance = lengths.reduce(0) { $0 + pow($1 - mean, 2) } / count
        let sourceCount = max(1, assets.filter { !$0.excluded && !$0.missing }.count)
        let chronology = EditorialChronologyReport.inspect(timeline: timeline, assets: assets)
        return Self(values: [Double(chronology.confirmedErrorCount) / count, min(1, repeated / duration), actionCuts/count,
            speechCuts/count, invalid/count, Double(lengths.filter { $0 < 1 }.count)/count,
            Double(lengths.filter { $0 > 12 }.count)/count, min(2, sqrt(variance)/max(0.05, mean))/2,
            Double(Set(items.compactMap(\.assetID)).count)/Double(sourceCount), quality/count, speechKnown/count])
    }
}

public struct EditingDecisionRanker: Codable, Sendable {
    public var schemaVersion: Int
    public var modelID: String
    public var featureNames: [String]
    public var weights: [Double]
    public var trainingDataSHA256: String
    public var labelProvenance: String
    public var validatedForDefault: Bool

    public var isValid: Bool {
        schemaVersion == EditingDecisionFeatures.schemaVersion && featureNames == EditingDecisionFeatures.names && weights.count == featureNames.count
            && weights.allSatisfy(\.isFinite) && !modelID.isEmpty && !trainingDataSHA256.isEmpty
    }
    public func utility(_ features: EditingDecisionFeatures) -> Double? {
        guard isValid, features.values.count == weights.count, features.values.allSatisfy(\.isFinite) else { return nil }
        let score = zip(weights, features.values).reduce(0) { $0 + $1.0 * $1.1 }
        return score.isFinite ? score : nil
    }
    /// Shared by all AI modes. The saved technical model is enabled by product
    /// policy; its historical training/validation metadata remains unchanged.
    public static let enabledPreferenceKey = "VeloEditEditingDecisionRankerEnabled"

    public static func configured() -> Self? {
        load(environment: ProcessInfo.processInfo.environment,
             enabled: UserDefaults.standard.object(forKey: enabledPreferenceKey) as? Bool ?? true)
    }

    /// A bad explicit override falls back to the legacy selector, never silently
    /// to another model. No process-wide cache: disabling applies to the next edit.
    static func load(environment: [String: String], enabled: Bool = true,
                     bundledData: Data = BundledEditingDecisionModel.data) -> Self? {
        guard enabled else { return nil }
        let override = environment["VELOEDIT_EDIT_RANKER"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, ["off", "false", "0", "disabled"].contains(override.lowercased()) { return nil }
        do {
            let data: Data
            if let override, !override.isEmpty {
                data = try Data(contentsOf: URL(fileURLWithPath: override))
            } else {
                data = bundledData
            }
            let model = try JSONDecoder().decode(Self.self, from: data)
            guard model.isValid else {
                FileHandle.standardError.write(Data("Editing model incompatible; using legacy selector.\n".utf8))
                return nil
            }
            return model
        } catch {
            FileHandle.standardError.write(Data("Editing model unavailable; using legacy selector: \(error.localizedDescription)\n".utf8))
            return nil
        }
    }
}

public struct EditingDecisionExample: Codable, Sendable {
    public var strategy: String
    public var features: EditingDecisionFeatures
    public var timeline: Timeline
    public var legacyScore: Double
    public var criticalCount: Int
    public var highCount: Int
}

struct EditingDecisionTrace: Codable {
    var schemaVersion = EditingDecisionFeatures.schemaVersion
    var featureNames = EditingDecisionFeatures.names
    var legacyWinner: String
    var selectedWinner: String
    var modelID: String?
    var examples: [EditingDecisionExample]
    var legacyTimelineID: UUID? = nil
    var selectedTimelineID: UUID? = nil
    var modelParticipated: Bool? = nil
    var evaluatedCandidateCount: Int? = nil
    var legacyUtility: Double? = nil
    var selectedUtility: Double? = nil

    func saveIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["VELOEDIT_VARIANT_TRACE_DIRECTORY"], !path.isEmpty else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder.veloEdit.encode(self).write(to: root.appendingPathComponent("variants-\(UUID().uuidString).json"), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Variant trace unavailable: \(error.localizedDescription)\n".utf8))
        }
    }
}
