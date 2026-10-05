import Foundation

public enum ChapterTitleSource: String, Codable, Sendable { case user, reference, model, fallback, retained }
public enum ChapterEvidenceOrigin: String, Codable, Sendable {
    case visualSummary, visualSequence, objectLabels, speech, metadata, user, modelInference
}

public struct ChapterTitleEvidence: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var assetID: UUID
    public var itemID: UUID
    public var sourceStart: Double
    public var sourceEnd: Double
    public var timelineStart: Double
    public var timelineEnd: Double
    public var origin: ChapterEvidenceOrigin
    public var observation: String
    public var selected: Bool
    public var frameTimes: [Double]
    public var actionSequence: Bool
}

public struct ChapterTitleClaim: Codable, Hashable, Sendable {
    public var text: String
    /// activity, setting, date, place, people, or other
    public var kind: String
    public var evidenceIDs: [String]
}

public struct ChapterTitleProposal: Codable, Hashable, Sendable {
    public var text: String
    public var claims: [ChapterTitleClaim]
}

public struct ChapterThemeProposal: Codable, Hashable, Sendable {
    public var theme: String
    public var setting: String
    public var secondaryActivities: [String]
    public var contradictions: [String]
    public var unknowns: [String]
    /// At most two choices: specific, then a broader supported alternative.
    public var titles: [ChapterTitleProposal]
}

public struct ChapterTitleVerification: Codable, Hashable, Sendable {
    public var accepted: Bool
    public var reasons: [String]
    public var unsupportedClaims: [String]
    public var evidenceIDs: [String]
    public var coversWholePart: Bool
}

public struct ChapterTitleCoverage: Codable, Hashable, Sendable {
    public var selectedSeconds: Double
    public var observedSeconds: Double
    public var sampledEvidenceCount: Int
    public var availableEvidenceCount: Int
    public var beginning: Bool
    public var middle: Bool
    public var end: Bool
}

public struct ChapterTitleDecision: Codable, Hashable, Sendable {
    public var partID: UUID
    public var text: String
    public var source: ChapterTitleSource
    public var inputSignature: String
    public var rulesVersion: Int
    public var modelID: String
    public var theme: ChapterThemeProposal?
    public var claims: [ChapterTitleClaim]
    public var evidence: [ChapterTitleEvidence]
    public var coverage: ChapterTitleCoverage
    public var verifications: [ChapterTitleVerification]
    public var fallbackReason: String?
    public var modelCalls: Int
    public var elapsedSeconds: Double
}

public struct ChapterTitleInput: Codable, Hashable, Sendable {
    public var partID: UUID
    public var ordinal: Int
    public var duration: Double
    public var language: String
    public var maxCharacters: Int
    public var evidence: [ChapterTitleEvidence]
    public var coverage: ChapterTitleCoverage
    public var limitations: [String]
}

/// Injectable two-stage interface. A verifier receives facts and the proposed
/// wording, not the generator's confidence or previous automatic titles.
public protocol ChapterTitleModel: Sendable {
    var identity: String { get }
    func generate(_ input: ChapterTitleInput) async throws -> ChapterThemeProposal
    func verify(_ proposal: ChapterTitleProposal, input: ChapterTitleInput) async throws -> ChapterTitleVerification
}

public struct SmartChapterTitleEngine: Sendable {
    public static let rulesVersion = 1
    public init() {}

    public func applying(to source: Timeline, plan: StoryPlan, assets: [MediaAsset], analyses: [AnalysisResult],
                         mode: AIPowerMode, model: any ChapterTitleModel, force: Bool = false) async throws -> Timeline {
        guard !ExplicitDeliveryRequirements(plan: plan).forbidsTitles,
              EditorialPresentationPolicy.requiresChapterTitles(plan) || source.effectiveTitleItems.contains(where: { $0.kind == .chapter }) else { return source }
        var result = FilmPartPolicy.freezing(source, plan: plan)
        let parts = result.filmParts ?? []
        let byAsset = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byAnalysis = Dictionary(analyses.filter {
            guard let asset = byAsset[$0.assetID] else { return false }
            return $0.analyzedContentHash == asset.contentHash || $0.analyzedContentHash == asset.fullContentHash
        }.map { ($0.assetID, $0) }, uniquingKeysWith: { first, _ in first })
        var decisions: [ChapterTitleDecision] = []
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            let ids = Set(part.itemIDs)
            let items = result.items.filter { ids.contains($0.id) }.sorted { $0.timelineStart < $1.timelineStart }
            guard let first = items.first, let last = items.last else { continue }
            let end = last.timelineStart + last.timelineDuration
            let existing = source.effectiveTitleItems.first { $0.filmPartID == part.id && $0.kind == .chapter }
                ?? source.effectiveTitleItems.first { $0.kind == .chapter && abs($0.startTime - first.timelineStart) < 0.001 }
            let manual = existing.flatMap { !AutomatedTitlePolicy.isGenerated($0) ? $0 : nil }
            // Blanket references are used only when every selected source in
            // this part has the same approved label. Mixed sources stay unknown.
            let labels = items.map { item -> String? in
                guard let id = item.assetID else { return nil }
                return plan.approvedSourceChapterLabels?[id]?.text
                    ?? byAsset[id].flatMap { plan.chapterTitleReference?.labelsByContentHash[$0.contentHash]?.text }
            }
            let approved = labels.allSatisfy { $0 != nil } && Set(labels.compactMap { $0 }).count == 1 ? labels.first.flatMap { $0 } : nil
            let allEvidence = Self.collect(items: items, analyses: byAnalysis, frameRate: source.frameRate)
            let limit: Int
            switch mode { case .fast: limit = 18; case .balanced: limit = 30; case .quality: limit = 48; case .maximum: limit = 60 }
            let evidence = Self.sample(allEvidence, limit: limit)
            let duration = items.reduce(0) { $0 + $1.timelineDuration }
            let visual = allEvidence.filter { $0.selected && [.visualSummary, .visualSequence, .objectLabels].contains($0.origin) }
            let sampledVisual = evidence.filter { $0.selected && [.visualSummary, .visualSequence, .objectLabels].contains($0.origin) }
            let coverage = ChapterTitleCoverage(selectedSeconds: duration,
                observedSeconds: Self.coveredSeconds(sampledVisual), sampledEvidenceCount: evidence.count, availableEvidenceCount: allEvidence.count,
                beginning: visual.contains { $0.timelineStart < first.timelineStart + (end - first.timelineStart) / 3 },
                middle: visual.contains { $0.timelineEnd > first.timelineStart + (end - first.timelineStart) / 3 && $0.timelineStart < first.timelineStart + (end - first.timelineStart) * 2 / 3 },
                end: visual.contains { $0.timelineEnd > first.timelineStart + (end - first.timelineStart) * 2 / 3 })
            let maxCharacters = TitleTemplateRegistry.template(id: existing?.effectiveTemplateID ?? "title.minimal-clean.v1")?.textConstraints.maxCharacters ?? 48
            var input = ChapterTitleInput(partID: part.id, ordinal: index + 1, duration: duration, language: "ru", maxCharacters: min(64, maxCharacters), evidence: evidence,
                coverage: coverage, limitations: ["Descriptions are fallible saved model observations, not human annotation.",
                    "Whole-candidate descriptions crossing a selected cut are omitted: their source context cannot safely be assigned to this part.",
                    "No extra frame decoding; unknown coverage remains unknown."])
            if approved == nil && labels.contains(where: { $0 != nil }) { input.limitations.append("Conflicting or incomplete approved source labels; no blanket reference applied.") }
            struct Signature: Encodable {
                var version: Int; var model: String; var mode: String; var input: ChapterTitleInput
                var sources: [String]; var observations: [ChapterTitleEvidence]; var restrictions: [String]
            }
            // Relative timing means moving an intact part does not invalidate
            // its semantics, while trim, content, observation and model changes do.
            var relative = input
            relative.ordinal = 0
            relative.evidence = Self.relative(evidence, start: first.timelineStart)
            let sourceKeys = items.map { item -> String in
                let asset = item.assetID.flatMap { byAsset[$0] }
                let analysis = item.assetID.flatMap { byAnalysis[$0] }
                let relevant = analysis?.candidates.filter { $0.sourceStart < item.sourceStart + item.sourceDuration && $0.sourceStart + $0.sourceDuration > item.sourceStart } ?? []
                let observations = relevant.map { candidate in
                    let samples = (candidate.insights?.editorialEvidence?.samples ?? []).filter {
                        $0.sourceTime >= item.sourceStart && $0.sourceTime < item.sourceStart + item.sourceDuration
                    }.map { "\($0.sourceTime)|\($0.actionState.sorted())|\($0.confidence)" }.joined(separator: ";")
                    return "\(candidate.sourceStart)|\(candidate.sourceDuration)|\(candidate.insights?.sceneSummary ?? "")|\(candidate.tags.sorted())|\(candidate.insights?.speech?.text ?? "")|\(candidate.insights?.editorialEvidence?.analysisVersion ?? 0)|\(samples)"
                }.joined(separator: "\n")
                return "\(item.id)|\(asset?.fullContentHash ?? asset?.contentHash ?? item.assetID?.uuidString ?? "unknown")|\(item.sourceStart)|\(item.sourceDuration)|\(item.timelineDuration)|\(analysis?.schemaVersion ?? 0)|\(analysis?.analysisProfileKey ?? "unknown")|\(analysis?.analysisModelDigest ?? "unknown")|\(EditorialIdentity.hash(observations))"
            }
            let date = Self.trustedDate(items: items, assets: byAsset)
            let signature = try Self.signature(Signature(version: Self.rulesVersion, model: model.identity, mode: mode.rawValue, input: relative,
                sources: sourceKeys, observations: Self.relative(allEvidence, start: first.timelineStart),
                restrictions: [manual?.text ?? "", approved ?? "", date ?? "", plan.prompt]))
            if !force, var cached = source.chapterTitleDecisions?.first(where: { $0.partID == part.id && $0.inputSignature == signature }) {
                cached.evidence = evidence + cached.evidence.filter { $0.origin == .metadata }.map { old in
                    var value = old; value.timelineStart = first.timelineStart; value.timelineEnd = end; return value
                }
                cached.coverage = coverage
                // Cached generic numbering follows ordering, never invents days.
                if cached.source == .fallback, cached.text.hasPrefix("Часть ") { cached.text = "Часть \(index + 1)" }
                decisions.append(cached)
                continue
            }
            let started = ProcessInfo.processInfo.systemUptime
            var decision = ChapterTitleDecision(partID: part.id, text: manual?.text ?? approved ?? date ?? "Часть \(index + 1)",
                source: manual != nil ? .user : approved != nil ? .reference : .fallback,
                inputSignature: signature, rulesVersion: Self.rulesVersion, modelID: model.identity, theme: nil, claims: [],
                evidence: evidence, coverage: coverage, verifications: [], fallbackReason: nil, modelCalls: 0, elapsedSeconds: 0)
            if manual == nil && approved == nil {
                do {
                    guard !visual.isEmpty else { throw ChapterTitleFailure.insufficientEvidence }
                    decision.modelCalls += 1
                    let theme = try await model.generate(input)
                    try Task.checkCancellation()
                    decision.theme = theme
                    for proposal in theme.titles.prefix(2) {
                        var review = Self.validate(proposal, input: input)
                        if review.accepted {
                            decision.modelCalls += 1
                            let semantic = try await model.verify(proposal, input: input)
                            try Task.checkCancellation()
                            let known = Set(input.evidence.map(\.id))
                            review = semantic
                            if semantic.reasons.isEmpty || semantic.evidenceIDs.isEmpty || !Set(semantic.evidenceIDs).isSubset(of: known)
                                || !semantic.unsupportedClaims.isEmpty || !semantic.coversWholePart {
                                review.accepted = false
                                review.reasons.append("Verifier did not establish grounded coverage of the whole part")
                            }
                        }
                        decision.verifications.append(review)
                        if review.accepted {
                            decision.text = proposal.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            decision.source = .model
                            decision.claims = proposal.claims
                            break
                        }
                    }
                    if decision.source == .fallback { decision.fallbackReason = "No proposed title passed grounding and whole-part verification" }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    decision.fallbackReason = String(describing: error)
                    // A failed request may not destroy the user's current film.
                    // Keep provenance explicit: this is not a verified model result.
                    if let existing, !existing.text.isEmpty {
                        decision.text = existing.text
                        decision.source = .retained
                    }
                }
            }
            if decision.source == .fallback, let date, let assetID = first.assetID {
                let metadata = ChapterTitleEvidence(id: "capture-date", assetID: assetID, itemID: first.id,
                    sourceStart: first.sourceStart, sourceEnd: first.sourceStart + first.sourceDuration,
                    timelineStart: first.timelineStart, timelineEnd: end, origin: .metadata,
                    observation: "Embedded capture metadata with explicit time zone, same date across all selected sources: \(date)",
                    selected: true, frameTimes: [], actionSequence: false)
                decision.evidence.append(metadata)
                decision.claims = [.init(text: date, kind: "date", evidenceIDs: [metadata.id])]
            }
            if end - first.timelineStart < 1.25 { decision.fallbackReason = "Part shorter than the existing 1.25-second readability minimum" }
            decision.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
            decisions.append(decision)
        }
        try Task.checkCancellation()
        result.chapterTitleDecisions = decisions
        result = EditorialPresentationPolicy.ensuringChapterTitles(in: result, plan: plan, preserveExistingPresentation: true)
        // Readability and export receipts are tied to the exact rendered text.
        if result.effectiveTitleItems != source.effectiveTitleItems {
            result.editorialReview = nil
            result.filmDeliveryReport = nil
        }
        return result
    }

    static func validate(_ proposal: ChapterTitleProposal, input: ChapterTitleInput) -> ChapterTitleVerification {
        var reasons: [String] = []
        let text = proposal.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(whereSeparator: \.isWhitespace)
        if text.isEmpty || text.count > input.maxCharacters || words.count > 6 || text.contains("\n") || SmartTitleEngine.isPlaceholderTitle(text) {
            reasons.append("Title is empty, too long, or a structural placeholder")
        }
        if text.range(of: "[А-Яа-яЁё]", options: .regularExpression) == nil { reasons.append("Russian wording required") }
        if proposal.claims.isEmpty { reasons.append("No claim-level evidence") }
        let byID = Dictionary(input.evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for claim in proposal.claims {
            let refs = claim.evidenceIDs.compactMap { byID[$0] }
            if claim.text.isEmpty || refs.isEmpty || refs.count != claim.evidenceIDs.count { reasons.append("Unknown or missing evidence for \(claim.text)") }
            let selected = refs.filter { $0.selected && [.visualSummary, .visualSequence, .objectLabels, .metadata, .user].contains($0.origin) }
            if selected.isEmpty { reasons.append("Claim exists only outside the selected film: \(claim.text)") }
            if claim.kind == "activity" {
                let semantic = selected.filter { $0.origin == .visualSummary }
                if !selected.contains(where: \.actionSequence) && Set(semantic.map(\.itemID)).count < 2 {
                    reasons.append("An object or one observation does not establish an activity: \(claim.text)")
                }
            }
            if ["date", "place", "people"].contains(claim.kind), !selected.contains(where: { $0.origin == .metadata || $0.origin == .user }) {
                // Generic visible people are allowed; names/relationships are not.
                if claim.kind != "people" { reasons.append("Specific date/place lacks trusted metadata or user confirmation") }
            }
        }
        let ids = Array(Set(proposal.claims.flatMap(\.evidenceIDs))).sorted()
        let selected = ids.compactMap { byID[$0] }.filter { $0.selected && [.visualSummary, .visualSequence, .objectLabels].contains($0.origin) }
        let enough = Self.coveredSeconds(selected) >= min(input.duration * 0.5, input.coverage.observedSeconds * 0.65)
            && Self.coveredSeconds(selected) > 0
        if !enough { reasons.append("Cited observations do not cover the predominant part of available footage evidence") }
        if input.duration > 10 && !(input.coverage.beginning && input.coverage.middle && input.coverage.end) {
            reasons.append("Missing observations across the beginning, middle or end of the part")
        }
        return .init(accepted: reasons.isEmpty, reasons: reasons.isEmpty ? ["Claim references, temporal evidence and duration coverage checked"] : reasons,
                     unsupportedClaims: reasons, evidenceIDs: ids, coversWholePart: enough)
    }

    private static func collect(items: [TimelineItem], analyses: [UUID: AnalysisResult], frameRate: Double) -> [ChapterTitleEvidence] {
        var output: [ChapterTitleEvidence] = []
        for item in items {
            guard let asset = item.assetID, let analysis = analyses[asset] else { continue }
            let end = item.sourceStart + item.sourceDuration
            let candidates = analysis.candidates.filter { $0.sourceStart < end && $0.sourceStart + $0.sourceDuration > item.sourceStart }
            for candidate in candidates {
                let start = max(item.sourceStart, candidate.sourceStart), stop = min(end, candidate.sourceStart + candidate.sourceDuration)
                // Frame quantization is not a meaningful excluded event. Any
                // larger trim keeps the whole-candidate description context-only.
                let tolerance = 1 / max(24, frameRate) + 0.000_001
                let fullySelected = candidate.sourceStart >= item.sourceStart - tolerance && candidate.sourceStart + candidate.sourceDuration <= end + tolerance
                func add(_ origin: ChapterEvidenceOrigin, _ text: String, selected: Bool, times: [Double] = [], action: Bool = false) {
                    guard !text.isEmpty else { return }
                    let observedStart = times.min() ?? start, observedEnd = times.max() ?? stop
                    let timeA = timelineTime(sourceTime: observedStart, item: item), timeB = timelineTime(sourceTime: observedEnd, item: item)
                    output.append(.init(id: "e\(output.count)", assetID: asset, itemID: item.id,
                        sourceStart: selected ? observedStart : candidate.sourceStart,
                        sourceEnd: selected ? observedEnd : candidate.sourceStart + candidate.sourceDuration,
                        timelineStart: min(timeA, timeB), timelineEnd: max(timeA, timeB),
                        origin: origin, observation: String(text.prefix(1200)), selected: selected, frameTimes: times, actionSequence: action))
                }
                if fullySelected, let summary = candidate.insights?.sceneSummary { add(.visualSummary, summary, selected: true) }
                if let speech = candidate.insights?.speech, speech.phraseStart >= item.sourceStart, speech.phraseEnd <= end {
                    add(.speech, speech.text, selected: true)
                }
                // Labels have no frame-level timestamp; a trimmed candidate's
                // labels must not become observations of retained footage.
                if fullySelected { add(.objectLabels, candidate.tags.sorted().joined(separator: ", "), selected: true) }
                let samples = (candidate.insights?.editorialEvidence?.samples ?? []).filter { $0.sourceTime >= start && $0.sourceTime < stop && $0.confidence >= 0.65 }
                let actions = Set(samples.flatMap { $0.actionState }).sorted().filter { action in samples.filter { $0.actionState.contains(action) }.count >= 3 }
                for action in actions {
                    add(.visualSequence, "Repeated observed action: " + action, selected: true,
                        times: samples.filter { $0.actionState.contains(action) }.map(\.sourceTime), action: true)
                }
            }
        }
        return output
    }

    /// Invert the existing compositor time mapping, including ramps/reverse.
    private static func timelineTime(sourceTime: Double, item: TimelineItem) -> Double {
        if item.isFreezeFrame { return item.timelineStart }
        var lower = item.timelineStart, upper = item.timelineStart + item.timelineDuration
        for _ in 0..<32 {
            let mid = (lower + upper) / 2
            let before = item.sourceTime(atTimelineTime: mid) < sourceTime
            if before != (item.reversePlayback == true) { lower = mid } else { upper = mid }
        }
        return (lower + upper) / 2
    }

    private static func sample(_ evidence: [ChapterTitleEvidence], limit: Int) -> [ChapterTitleEvidence] {
        let selected = evidence.filter(\.selected)
        let context = evidence.filter { !$0.selected }
        func stratified(_ pool: [ChapterTitleEvidence], count: Int) -> [ChapterTitleEvidence] {
            guard count > 0 else { return [] }
            guard pool.count > count else { return pool }
            if count == 1 { return [pool[pool.count / 2]] }
            return (0..<count).map { pool[Int((Double($0) * Double(pool.count - 1) / Double(count - 1)).rounded())] }
        }
        // Unselected descriptions cannot overwhelm the retained film. Sample
        // both ends of each pool and reserve at most a quarter for context.
        let contextCount = min(context.count, limit / 4, max(0, limit - selected.count))
        return (stratified(selected, count: limit - contextCount) + stratified(context, count: contextCount))
            .sorted { $0.timelineStart == $1.timelineStart ? $0.id < $1.id : $0.timelineStart < $1.timelineStart }
    }

    static func coveredSeconds(_ evidence: [ChapterTitleEvidence]) -> Double {
        var end = -Double.infinity, seconds = 0.0
        for value in evidence.sorted(by: { $0.timelineStart < $1.timelineStart }) {
            seconds += max(0, value.timelineEnd - max(end, value.timelineStart))
            end = max(end, value.timelineEnd)
        }
        return seconds
    }

    private static func relative(_ evidence: [ChapterTitleEvidence], start: Double) -> [ChapterTitleEvidence] {
        evidence.map { original in var value = original; value.timelineStart -= start; value.timelineEnd -= start; return value }
    }

    private static func trustedDate(items: [TimelineItem], assets: [UUID: MediaAsset]) -> String? {
        let values = Set(items.compactMap(\.assetID))
        guard !values.isEmpty else { return nil }
        var dates = Set<String>()
        for id in values {
            guard let metadata = assets[id]?.metadata, metadata.dateSource == .embeddedMetadata,
                  let date = metadata.creationDate, let zone = metadata.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)),
                  (metadata.dateConfidence ?? 0) >= 0.8 else { return nil }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU")
            formatter.timeZone = zone; formatter.dateFormat = "d MMMM yyyy"
            dates.insert(formatter.string(from: date))
        }
        return dates.count == 1 ? dates.first : nil
    }

    private static func signature<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return EditorialIdentity.hash(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}

enum ChapterTitleFailure: Error { case insufficientEvidence, unavailableModel, invalidResponse }
