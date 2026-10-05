import Foundation

public enum DirectorIntent: Codable, Hashable, Sendable {
    case createFilm
    case vlogSpeech
    case addTitles
    case sourceAudio(DirectorSourceAudioPolicy)
    case evaluateNewAssets([UUID])
    case requiredTags(Set<String>)
    case unverifiedInstruction(String)
}

public enum IntentSource: String, Codable, Hashable, Sendable { case prompt, pendingInstruction, importedAsset, recovery }
public enum IntentStatus: String, Codable, Hashable, Sendable { case pending, running, fulfilled, rejected, recoverableFailure, cancelled }
public struct IntentSatisfactionEvidence: Codable, Hashable, Sendable {
    public var timelineID: UUID?
    public var assetID: UUID?
    public var reason: String
    public var candidateIDs: [UUID]? = nil
    public var relatedCandidateIDs: [UUID]? = nil
}
public struct IntentLedgerEntry: Codable, Hashable, Sendable {
    public var id: UUID
    public var projectRevision: UInt64
    public var normalizedIntent: DirectorIntent
    public var source: IntentSource
    public var status: IntentStatus
    public var evidence: [IntentSatisfactionEvidence]
    public var failureReason: String?
    public var originalRequest: String? = nil
}
public struct IntentLedger: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public var entries: [IntentLedgerEntry]
    public init(entries: [IntentLedgerEntry] = []) { self.entries = entries }
    public var hasRecoverableGeneration: Bool {
        guard let latest = entries.last(where: { $0.normalizedIntent == .createFilm }) else { return false }
        return [.running, .pending, .recoverableFailure].contains(latest.status)
    }
    public var unfulfilledInstructions: [String] {
        guard let start = entries.lastIndex(where: { $0.normalizedIntent == .createFilm }) else { return [] }
        return entries[start...].compactMap { entry in
            guard entry.status == .rejected,
                  case .unverifiedInstruction(let text) = entry.normalizedIntent else { return nil }
            return text
        }
    }
}

public enum EditorialGenerationError: LocalizedError {
    case noPassingVariant([EditorialFinding])
    case unsatisfiedIntent(String)
    public var errorDescription: String? {
        switch self {
        case .noPassingVariant(let findings):
            var reasons: [String] = []
            for finding in findings.filter({ $0.severity >= 2 }).sorted(by: { $0.severity > $1.severity }) {
                let reason = Self.userFacingReason(for: finding.kind)
                if !reasons.contains(reason) { reasons.append(reason) }
            }
            if reasons.isEmpty { reasons = ["не удалось подтвердить качество готового фильма"] }
            return "Монтаж не сохранён: \(reasons.prefix(3).joined(separator: "; ")). Данные проекта сохранены."
        case .unsatisfiedIntent(let reason): return "Запрос не выполнен: \(reason). Данные проекта сохранены."
        }
    }

    private static func userFacingReason(for kind: EditorialFindingKind) -> String {
        switch kind {
        case .blankRenderedFrame: return "не удалось прочитать отдельные кадры видео"
        case .renderedEvidenceUnavailable, .blockingEvidenceUnknown: return "проверка готового фильма не завершена"
        case .unreadableTitle: return "не удалось сделать все титры читаемыми"
        case .chapterCoverageMismatch: return "названия частей не соответствуют выбранным сценам"
        case .hardDuplicate, .shotFamilyRunTooLong, .dominantSetup: return "в подборке остались повторяющиеся планы"
        case .unsafeReframe, .cropJump, .foregroundOcclusion, .dominantForegroundObject: return "в отдельных планах обрезан или закрыт главный объект"
        case .durationUnderflow, .durationPadding: return "не удалось собрать допустимую длительность из пригодных фрагментов"
        case .audioPolicyViolation, .audioLoudnessViolation, .audioPeakViolation: return "звуковой микс не прошёл проверку"
        case .musicNarrativeMismatch: return "подобранная музыка не соответствует фильму"
        case .previewExportMismatch: return "результат экспорта расходится с предпросмотром"
        case .missingPrimaryVideo: return "в подборке нет пригодного видео или фотографий"
        case .pendingIntentUnsatisfied, .staleGenerationResult: return "не удалось применить все запрошенные изменения"
        default: return "не удалось собрать связную последовательность сцен"
        }
    }
}

public enum IntentLedgerEngine {
    public static func intents(prompt: String, brief: DirectorBrief?, pending: [String], newAssetIDs: [UUID]) -> [DirectorIntent] {
        let prompt = (pending.filter { !prompt.contains($0) } + [prompt]).joined(separator: "\n")
        var intents: [DirectorIntent] = [.createFilm]
        if let brief { intents.append(.sourceAudio(EditorialIntentEnforcer.updatedBrief(brief, prompt: prompt)?.sourceAudioPolicy ?? brief.sourceAudioPolicy)) }
        if brief == nil, let volume = OriginalAudioPromptInterpreter().volume(prompt: prompt) {
            intents.append(.sourceAudio(volume == 0 ? .mute : volume < 1 ? .duck : .preserve))
        }
        if EditorialIntentEnforcer.requestsAdditionalTitles(prompt)
            || (EditorialIntentEnforcer.titleRequest(prompt) != false && brief?.titlePolicy == .keyOnly) { intents.append(.addTitles) }
        for text in Array(Set(pending + [prompt])).flatMap({ $0.components(separatedBy: CharacterSet(charactersIn: ".!?;\n")) }) {
            let normalized = text.lowercased()
            let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if ["влог", "режим влог", "стиль: влог", "создай влог", "сделай влог"].contains(trimmed) {
                intents.append(.vlogSpeech); continue
            }
            // Questionnaire fields have independent delivery checks. Do not
            // reject the entire questionnaire, or skip a compound request just
            // because one of its clauses mentions titles.
            if brief != nil, ["формат:", "длительность:", "длительность —", "точная длительность:", "настроение:", "музыка:", "звук:", "титры:"].contains(where: trimmed.hasPrefix) { continue }
            if ["фильм", "создай фильм", "создать фильм", "сделай фильм", "create film", "create a film"].contains(normalized.trimmingCharacters(in: .whitespacesAndNewlines)) {
                // This request is already represented by the generation entry.
                continue
            }
            if FilmDurationRequirement.parse(prompt: text).mode != .automatic { continue }
            if !EditorCommandParser().parse(text, preset: .story).isEmpty { continue }
            if ["динамично", "красиво", "кинематографично", "киношно"].contains(trimmed) { continue }
            if EditorialIntentEnforcer.titleRequest(text) != nil {
                // Already resolved against the latest prompt above, including
                // a later request to remove titles.
                continue
            } else if OriginalAudioPromptInterpreter().volume(prompt: text) != nil {
                continue // Resolved once from the latest instruction above.
            } else if ["новые материал", "новые файл", "new asset"].contains(where: normalized.contains) {
                intents.append(.evaluateNewAssets(newAssetIDs))
            } else { intents.append(.unverifiedInstruction(text)) }
        }
        if !newAssetIDs.isEmpty { intents.append(.evaluateNewAssets(newAssetIDs)) }
        return Array(Set(intents)).sorted { String(describing: $0) < String(describing: $1) }
    }

    public static func validate(_ intent: DirectorIntent, timeline: Timeline, previous: Timeline?, analyses: [AnalysisResult], assets: [MediaAsset]) -> (IntentStatus, [IntentSatisfactionEvidence], String?) {
        let evidence = IntentSatisfactionEvidence(timelineID: timeline.id, reason: "Проверено состояние сохраняемого Timeline")
        switch intent {
        case .createFilm:
            let delivered = timeline.filmDeliveryReport?.isCurrent(for: timeline) == true
            return timeline.items.contains(where: { $0.overlay == nil && $0.kind != .title }) && (delivered || timeline.editorialReview?.hardGatePassed != false) ? (.fulfilled, [evidence], nil) : (.recoverableFailure, [], "Нет валидного Timeline")
        case .vlogSpeech:
            let expected = Set(assets.filter { !$0.excluded && !$0.missing && $0.kind == .video && $0.metadata.hasAudio }.map(\.id))
            let recognized = Set((timeline.speechRecords ?? []).map(\.assetID))
            let valid = timeline.speechRecords != nil && expected.isSubset(of: recognized)
                && timeline.items.allSatisfy { $0.overlay != nil || ($0.speed == 1 && !$0.isReversed) }
            return valid ? (.fulfilled, [evidence], nil) : (.recoverableFailure, [], "Влог требует речевого анализа всех исходников и сохранения скорости голоса")
        case .sourceAudio(let policy):
            let valid = policy != .mute || timeline.effectiveOriginalAudioVolume == 0 && timeline.effectiveAudioClips.isEmpty && timeline.items.filter { $0.kind == .video }.allSatisfy { $0.effectiveAudioAdjustments.muted }
            return valid ? (.fulfilled, [evidence], nil) : (.recoverableFailure, [], "Нарушен source audio policy")
        case .addTitles:
            return EditorialPresentationPolicy.hasReadableTitle(in: timeline)
                ? (.fulfilled, [evidence], nil) : (.recoverableFailure, [], "В ролике отсутствует читаемый титр")
        case .requiredTags(let tags):
            let selected = Set(timeline.items.compactMap(\.candidateID))
            let present = analyses.flatMap(\.directorCandidates).filter { selected.contains($0.id) }.reduce(into: Set<String>()) { $0.formUnion($1.tags) }
            return tags.isSubset(of: present) ? (.fulfilled, [evidence], nil) : (.recoverableFailure, [], "Не сохранено обязательное содержание")
        case .evaluateNewAssets(let ids):
            let decisions = EditorialSourceCoverage.decisions(timeline: timeline, context: EditorialAnalysisContext(analyses: analyses), assets: assets)
            let values = ids.map { id -> IntentSatisfactionEvidence in
                guard let decision = decisions.first(where: { $0.assetID == id }) else {
                    return .init(timelineID: timeline.id, assetID: id, reason: "analysisUnavailable: исходник не найден")
                }
                return .init(timelineID: timeline.id, assetID: id,
                    reason: decision.reason == .included ? "included" : "\(decision.reason.rawValue): \(decision.detail)",
                    candidateIDs: decision.candidateIDs, relatedCandidateIDs: decision.relatedCandidateIDs)
            }
            return (.fulfilled, values, nil)
        case .unverifiedInstruction(let text):
            return (.rejected, [], "Не подтверждена инструкция «\(text.trimmingCharacters(in: .whitespacesAndNewlines))». Фильм сохранён; это указание требует уточнения.")
        }
    }
}
