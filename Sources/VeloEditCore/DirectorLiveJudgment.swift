import Foundation

public enum DirectorJudgmentStance: String, Codable, Sendable {
    case keep, trim, compare, reorder, clarify, insufficientEvidence
}

public struct DirectorJudgment: Codable, Sendable {
    public var reply: String
    public var stance: DirectorJudgmentStance
    public var targetID: String
    public var evidenceIDs: [String]

    public init(reply: String, stance: DirectorJudgmentStance, targetID: String, evidenceIDs: [String]) {
        self.reply = reply; self.stance = stance; self.targetID = targetID; self.evidenceIDs = evidenceIDs
    }

    /// Structural and conservative lexical checks, not a claim of complete
    /// semantic verification. Human groundedness evaluation remains necessary.
    public func validated(in moment: DirectorMomentContext?, detailed: Bool = false, allowsProposedTitle: Bool = false) -> Bool {
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              detailed || reply.split(whereSeparator: \.isWhitespace).count <= 45,
              reply.count <= (detailed ? 4_000 : 450), targetID == (moment?.targetID ?? "") else { return false }
        let lowered = reply.lowercased()
        let executionClaims = ["готово", "применил", "поставил", "сохранил", "обрезал", "удалил", "изменил", "обновил", "переставил", "сделал", "заменил",
            "сохранено", "сохраняется", "обрезано", "удалено", "изменено", "применено", "поставлено", "добавлено", "переставлено", "заменено"]
        let factualText = lowered.replacingOccurrences(of: #"(?:я\s+)?бы\s+(?:применил|поставил|сохранил|обрезал|удалил|изменил|обновил|переставил|сделал|заменил)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?:применил|поставил|сохранил|обрезал|удалил|изменил|обновил|переставил|сделал|заменил)\s+бы"#, with: "", options: .regularExpression)
        if executionClaims.contains(where: factualText.contains) { return false }
        guard let moment else { return stance == .insufficientEvidence && evidenceIDs.isEmpty }
        let facts = moment.facts
        let cited = evidenceIDs.compactMap { id in facts.first { $0.id == id } }
        guard Set(evidenceIDs).count == evidenceIDs.count, cited.count == evidenceIDs.count else { return false }
        for fact in cited {
            guard let object = (moment.objects + moment.neighbors).first(where: { $0.itemID == fact.itemID }),
                  fact.assetID == object.assetID, fact.candidateID == object.candidateID,
                  fact.contentHash == object.contentHash, fact.analysisVersion == object.analysisVersion,
                  fact.analysisVersion != "missing" else { return false }
            if fact.kind == .scene {
                guard fact.sourceRange == object.analysisRange, fact.sourceRange.overlaps(object.sourceRange) else { return false }
            } else {
                guard fact.sourceRange.lowerBound >= object.sourceRange.lowerBound,
                      fact.sourceRange.upperBound <= object.sourceRange.upperBound else { return false }
            }
        }
        if stance == .compare {
            guard moment.objects.count >= 2, moment.objects.allSatisfy({ object in cited.contains { $0.itemID == object.itemID } }) else { return false }
        }
        if [.clarify, .insufficientEvidence].contains(stance), cited.isEmpty {
            guard ["недостат", "нет данных", "не хватает", "не могу", "укажите", "уточни", "нет актуаль", "не разобран", "не анализир", "без анализ", "мало данных"].contains(where: lowered.contains) else { return false }
        }
        if ![.clarify, .insufficientEvidence].contains(stance) {
            guard cited.contains(where: { fact in moment.objects.contains { $0.itemID == fact.itemID } }) else { return false }
        }
        let evidenceText = cited.map(\.text).joined(separator: " ").lowercased()
        // Numeric cut locations may not be synthesized from scene descriptions.
        // Source clock values are deliberately not allowed as film trim commands.
        let numbers = Self.matches(#"\d+(?:[.,]\d+)?"#, in: reply)
        if !numbers.allSatisfy({ evidenceText.contains($0) }) { return false }
        for quote in Self.matches(#"[«“\"]([^»”\"]+)[»”\"]"#, in: reply, group: 1) {
            if !allowsProposedTitle && !evidenceText.contains(quote.lowercased()) { return false }
        }
        if ["обрыва", "обрезан", "последнее слово", "конец фразы"].contains(where: lowered.contains), !cited.contains(where: { $0.kind == .cutSpeech }) { return false }
        if ["смех", "сме", "аплодис", "крик"].contains(where: lowered.contains), !cited.contains(where: { $0.kind == .audio }) { return false }
        if ["скуч", "груст", "счастлив", "зритель"].contains(where: lowered.contains) { return false }
        if stance == .trim && !cited.contains(where: { [.temporalSample, .speech, .cutSpeech, .silence].contains($0.kind) }), !numbers.isEmpty { return false }
        return true
    }

    private static func matches(_ pattern: String, in text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: group), in: text).map { String(text[$0]) }
        }
    }
}

public enum DirectorExecutionState: String, Codable, Sendable {
    case proposed, running, applied, partial, failed, cancelled, noChange
}

/// Stored beside the final text; optional on legacy workspace messages.
public struct DirectorResponseRecord: Codable, Hashable, Sendable {
    public var state: DirectorExecutionState
    public var projectID: UUID?
    public var revision: UInt64?
    public var itemIDs: [UUID]
    public var saved: Bool
    public var previewReady: Bool
    public var advisory: Bool
    public var fallback: Bool
    public var details: [String]
    public var proposal: DirectorEditProposal? = nil
    public var range: ClosedRange<Double>? = nil

    public init(state: DirectorExecutionState, projectID: UUID? = nil, revision: UInt64? = nil, itemIDs: [UUID] = [], saved: Bool = false, previewReady: Bool = false, advisory: Bool = false, fallback: Bool = false, details: [String] = []) {
        self.state = state; self.projectID = projectID; self.revision = revision; self.itemIDs = itemIDs
        self.saved = saved; self.previewReady = previewReady; self.advisory = advisory; self.fallback = fallback; self.details = details
    }
}

public struct DirectorExecutionReceipt: Sendable {
    public var requested: [EditorCommand]
    public var applied: [String]
    public var omitted: [String]
    public var saved: Bool
    public var previewReady: Bool
    public var cancelled: Bool
    public var failure: String?

    public init(requested: [EditorCommand] = [], applied: [String] = [], omitted: [String] = [], saved: Bool = false, previewReady: Bool = false, cancelled: Bool = false, failure: String? = nil) {
        self.requested = requested; self.applied = applied; self.omitted = omitted; self.saved = saved
        self.previewReady = previewReady; self.cancelled = cancelled; self.failure = failure
    }
    public var state: DirectorExecutionState {
        if saved { return !omitted.isEmpty || failure != nil ? .partial : .applied }
        if cancelled { return .cancelled }
        if failure != nil { return .failed }
        return .noChange
    }
}

public enum DirectorResponseComposer {
    /// A saved film-level rationale is attributable history, not fresh visual
    /// evidence. Do not use it to explain an individual clip or later edit.
    public static func recordedDurationReason(prompt: String, reasons: [String]) -> String? {
        let text = prompt.lowercased()
        guard ["почему", "объясни", "поясни"].contains(where: text.contains),
              ["фильм", "ролик", "хронометраж"].contains(where: text.contains),
              ["длин", "длинн", "корот", "длит", "хронометраж"].contains(where: text.contains),
              !["клип", "кадр", "фрагмент"].contains(where: text.contains), !reasons.isEmpty else { return nil }
        let words = reasons.prefix(2).joined(separator: ". ").split(whereSeparator: \.isWhitespace)
        let excerpt = words.prefix(36).joined(separator: " ")
        return "В сохранённом обосновании сборки: \(excerpt)\(words.count > 36 ? "…" : "")"
    }

    public static func asksForPastEditReason(_ prompt: String) -> Bool {
        let text = prompt.lowercased()
        return ["почему", "зачем"].contains(where: text.contains)
            && ["убрал", "удалил", "обрезал", "добавил", "поставил", "заменил", "сократил", "установил", "здесь эффект"].contains(where: text.contains)
    }

    public static func execution(_ receipt: DirectorExecutionReceipt) -> String {
        guard receipt.saved else {
            if receipt.cancelled { return "Правка отменена до сохранения." }
            if let failure = receipt.failure { return "Правку не удалось сохранить: \(failure)" }
            return receipt.omitted.isEmpty ? "Изменений не потребовалось." : "Не выполнено: \(receipt.omitted.joined(separator: "; "))."
        }
        var result: String
        if receipt.requested.count == 1, receipt.omitted.isEmpty, case .setMusicVolume(let volume) = receipt.requested[0] {
            result = "Поставил музыку на \(number(volume * 100))%."
        } else if receipt.requested.count == 1, receipt.omitted.isEmpty, case .setOriginalAudioVolume(let volume) = receipt.requested[0] {
            result = "Поставил звук исходников на \(number(volume * 100))%."
        } else if receipt.applied.isEmpty { result = "Монтаж сохранён." }
        else if receipt.applied.count <= 2 { result = "Сохранено: \(receipt.applied.joined(separator: "; "))." }
        else { result = "Сохранил \(receipt.applied.count) правки." }
        if !receipt.omitted.isEmpty { result += " Не выполнено: \(receipt.omitted.joined(separator: "; "))." }
        if let failure = receipt.failure { result += " \(failure)" }
        if !receipt.previewReady { result += " Просмотр пока не обновлён." }
        if receipt.cancelled { result += " Ожидание отменено после сохранения; правка остаётся в проекте." }
        return result
    }

    public static func limitedAdvice(prompt: String, moment: DirectorMomentContext?, delayed: Bool = false) -> String {
        let text = prompt.lowercased()
        if asksForPastEditReason(prompt) {
            return "В доступной истории нет подтверждённой причины этой правки. Можно заново оценить текущую склейку."
        }
        if ["мне нравится", "мне как раз нравится", "оставим", "не сокращай", "не надо"].contains(where: text.contains) {
            return "Учту это в следующих советах об этом моменте."
        }
        guard let moment, !moment.objects.isEmpty else { return "Укажите клип или таймкод — тогда смогу оценить конкретный момент." }
        if moment.scope == "comparison", moment.objects.count < 2 { return "Укажите два клипа для сравнения — по текущему выделению второй дубль не определён." }
        if let cut = moment.objects.flatMap(\.facts).first(where: { $0.kind == .cutSpeech }) {
            return "\(cut.text) Я бы сохранил слово целиком; границу стоит проверить на слух."
        }
        if delayed { return "Модель не успела ответить. По готовым данным уверенной оценки пока нет; можно попросить продолжить ожидание." }
        if moment.objects.allSatisfy({ $0.facts.isEmpty }) {
            return "Для этого фрагмента нет актуальных содержательных наблюдений — пока не могу оценить его монтаж. Анализ можно запустить в медиатеке."
        }
        return "Готовые наблюдения покрывают лишь часть этого момента. Пока оставил бы монтаж как есть: данных для уверенной правки недостаточно."
    }
    private static func number(_ value: Double) -> String { String(format: "%g", value) }
}

/// A narrow, evidence-derived continuation. It is never extracted from prose.
public struct DirectorEditProposal: Codable, Hashable, Sendable {
    public var projectID: UUID
    public var item: TimelineItem
    public var contentHash: String
    public var analysisDate: Date
    public var duration: Double

    public static func completingCutWord(project: ProjectManifest, targetID: UUID) -> DirectorEditProposal? {
        guard let item = project.timelines.last?.items.first(where: { $0.id == targetID }),
              !item.isReversed, !item.isFreezeFrame, item.speedRamp == nil, item.overlay == nil,
              let asset = project.assets.first(where: { $0.id == item.assetID }),
              let analysis = project.analyses.first(where: { $0.assetID == asset.id }),
              analysis.analyzedContentHash == asset.contentHash, analysis.schemaVersion == project.analysisSchemaVersion,
              analysis.deepMediaVersion == DeepAnalysisCache.version,
              let speech = analysis.candidates.first(where: { $0.id == item.candidateID })?.insights?.speech,
              speech.confidence >= 0.65,
              let word = speech.words?.first(where: { $0.confidence >= 0.65 && $0.startTime < item.sourceStart + item.sourceDuration - 0.04 && $0.endTime > item.sourceStart + item.sourceDuration }),
              word.endTime <= (asset.metadata.duration ?? 0), word.startTime >= item.sourceStart,
              !item.locked else { return nil }
        return DirectorEditProposal(projectID: project.id, item: item, contentHash: asset.contentHash,
            analysisDate: analysis.analyzedAt, duration: (word.endTime - item.sourceStart) / item.speed)
    }

    public func isApplicable(to project: ProjectManifest, selectedID: UUID?) -> Bool {
        project.id == projectID && (selectedID == nil || selectedID == item.id)
            && project.timelines.last?.items.first(where: { $0.id == item.id }) == item
            && project.assets.first(where: { $0.id == item.assetID })?.contentHash == contentHash
            && project.analyses.first(where: { $0.assetID == item.assetID })?.analyzedAt == analysisDate
            && Self.completingCutWord(project: project, targetID: item.id) == self
    }
}
