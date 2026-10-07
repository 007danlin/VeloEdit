import Foundation

public enum DirectorFactKind: String, Codable, Sendable {
    case scene, temporalSample, speech, cutSpeech, silence, audio, timeline, decision
}

/// All clocks are explicit. Coverage is source time, never a film timecode.
public struct DirectorMomentFact: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var itemID: UUID
    public var assetID: UUID?
    public var candidateID: UUID?
    public var contentHash: String
    public var analysisVersion: String
    public var kind: DirectorFactKind
    public var sourceRange: ClosedRange<Double>
    public var text: String
    public var method: String
    public var confidence: Double?
    public var limitations: String
}

public struct DirectorMomentObject: Codable, Hashable, Sendable {
    public var itemID: UUID
    public var candidateID: UUID?
    public var assetID: UUID?
    public var contentHash: String
    public var analysisVersion: String
    public var filmRange: ClosedRange<Double>
    public var sourceRange: ClosedRange<Double>
    public var role: String?
    public var reversed: Bool
    public var analysisRange: ClosedRange<Double>? = nil
    public var facts: [DirectorMomentFact]
    public var limitations: [String]
}

public struct DirectorMomentContext: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var revision: UInt64
    public var scope: String
    public var objects: [DirectorMomentObject]
    public var neighbors: [DirectorMomentObject]
    public var limitations: [String]

    public var facts: [DirectorMomentFact] { objects.flatMap(\.facts) + neighbors.flatMap(\.facts) }
    public var targetID: String { objects.map { $0.itemID.uuidString }.joined(separator: ",") }
    /// Episode descriptions cannot answer questions requiring sound or timing.
    /// Check before generation rather than inferring events from scene labels.
    public func adviceEvidenceGap(for prompt: String) -> String? {
        let text = prompt.lowercased().replacingOccurrences(of: "ё", with: "е")
        if scope == "comparison", objects.count < 2 {
            return "Укажите два клипа для сравнения — по текущему выделению второй дубль не определён."
        }
        let local = objects.flatMap(\.facts)
        guard !local.isEmpty, !DirectorResponseComposer.asksForPastEditReason(prompt) else { return nil }
        if ["что слышно", "звук мешает", "музыка мешает", "речь не обрезана", "речь обрезана"].contains(where: text.contains),
           !local.contains(where: { [.audio, .speech, .cutSpeech, .silence].contains($0.kind) }) {
            return "В готовом анализе нет локальных данных о звуке. По описанию кадров не могу оценить, что здесь слышно и мешает ли это монтажу."
        }
        let needsTiming = ["затянуто", "медленно", "быстро", "пауз", "резко", "склейк", "переход", "закончить", "конец"]
        let preference = ["мне нравится", "мне как раз нравится", "не сокращай", "оставим"].contains(where: text.contains)
        if !preference, needsTiming.contains(where: text.contains),
           !local.contains(where: { [.speech, .cutSpeech, .silence].contains($0.kind) }),
           local.filter({ $0.kind == .temporalSample }).count < 2 {
            return "Есть лишь общее описание эпизода. По нему не видно, как меняется действие и где проходит удачная склейка — уверенно советовать обрезку пока рано."
        }
        return nil
    }
    public var modelData: String {
        // JSON escaping keeps filenames, descriptions and transcripts in data.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Immutable metadata index built off the UI thread once per project revision.
/// No frames, audio buffers, URLs, model weights or free-form reply cache.
public struct DirectorMomentIndex: Sendable {
    public static let byteLimit = 32 * 1_024 * 1_024
    public let projectID: UUID
    public let revision: UInt64
    public private(set) var estimatedBytes = 0
    private var objects: [UUID: DirectorMomentObject] = [:]
    private var ordered: [TimelineItem] = []
    private var position: [UUID: Int] = [:]
    private var names: [String: [UUID]] = [:]
    private var truncated = false

    public init(project: ProjectManifest, revision: UInt64, byteLimit: Int = Self.byteLimit) {
        projectID = project.id
        self.revision = revision
        let assets = Dictionary(project.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let analyses = Dictionary(project.analyses.map { ($0.assetID, $0) }, uniquingKeysWith: { a, b in a.analyzedAt > b.analyzedAt ? a : b })
        var candidates: [UUID: Candidate] = [:]
        for analysis in analyses.values {
            for candidate in analysis.candidates { candidates[candidate.id] = candidate }
        }
        let encoder = JSONEncoder()
        for item in (project.timelines.last?.items ?? []).filter({ $0.overlay == nil && $0.kind != .title }).sorted(by: { $0.timelineStart < $1.timelineStart }) {
            if Task.isCancelled { truncated = true; break }
            let asset = item.assetID.flatMap { assets[$0] }
            let analysis = item.assetID.flatMap { analyses[$0] }
            let current = asset != nil && analysis?.analyzedContentHash == asset?.contentHash
                && analysis?.schemaVersion == project.analysisSchemaVersion
                && analysis?.deepMediaVersion == DeepAnalysisCache.version
            let candidate = item.candidateID.flatMap { candidates[$0] }
            let object = Self.makeObject(item: item, asset: asset, analysis: current ? analysis : nil,
                                         candidate: current && candidate?.assetID == asset?.id ? candidate : nil)
            // Includes conservative overhead for dictionaries and retained Swift values.
            let cost = (try? encoder.encode(object).count).map { $0 * 3 + 2_048 } ?? 4_096
            guard estimatedBytes + cost <= min(Self.byteLimit, max(0, byteLimit)) else { truncated = true; break }
            estimatedBytes += cost
            position[item.id] = ordered.count
            // Retain timing only; evidence is stored once in compact objects.
            var timing = item
            timing.explanation = []; timing.videoAdjustments = nil; timing.audioAdjustments = nil
            timing.incomingEditDecision = nil; timing.telemetryOverlay = nil
            objects[item.id] = object
            ordered.append(timing)
            if let name = asset?.displayName, name.count <= 256 { names[name.lowercased(), default: []].append(item.id) }
        }
    }

    public func resolve(prompt: String, selectedID: UUID?, playhead: Double, range: ClosedRange<Double>? = nil) -> DirectorMomentContext {
        let text = prompt.lowercased().replacingOccurrences(of: "ё", with: "е")
        var scope = "moment"
        var issues: [String] = truncated ? ["Индекс ограничен бюджетом памяти; покрыта только часть фильма."] : []
        var ids: [UUID] = []
        let all = ["весь фильм", "всем фильме", "целом", "всего фильма"].contains(where: text.contains)
            || (text.contains("фильм") && (text.contains("назвать") || text.contains("название")))
        if all {
            scope = "film"
            let count = ordered.count
            ids = Array(Set([0, count / 2, max(0, count - 1)])).sorted().compactMap { ordered.indices.contains($0) ? ordered[$0].id : nil }
            issues.append("Оценка фильма по началу, середине и концу; остальные моменты не представлены.")
        } else {
            // Explicit IDs, unique filename, numbered objects and film timecodes
            // precede selection. A failed explicit reference never falls through.
            let explicitIDs = Self.matches(#"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"#, text).compactMap { UUID(uuidString: $0[0]) }
            let named = names.filter { text.contains($0.key) }.flatMap(\.value)
            let numbers = Self.matches(#"(?:клип|кадр|дубль|фрагмент)\s*(?:№\s*)?(\d+)"#, text)
                .compactMap { Int($0[0]) }
            let clocks = Self.matches(#"(?<!\d)(\d{1,2}):(\d{2})(?::(\d{2}))?(?!\d)"#, text)
            if !explicitIDs.isEmpty {
                ids = explicitIDs.filter { objects[$0] != nil }
                if ids.count != explicitIDs.count { ids = []; issues.append("Указанного клипа нет в доступном монтаже.") }
            }
            else if !named.isEmpty {
                ids = Array(Set(named))
                if ids.count > 1 { ids = []; issues.append("Этот исходник встречается несколько раз; укажите номер клипа или таймкод.") }
            } else if !numbers.isEmpty {
                ids = numbers.compactMap { ordered.indices.contains($0 - 1) ? ordered[$0 - 1].id : nil }
                if ids.count != numbers.count { ids = []; issues.append("Указанного клипа нет в доступном монтаже.") }
            } else if !clocks.isEmpty {
                ids = clocks.compactMap { values in
                    let a = Double(values[0]) ?? 0, b = Double(values[1]) ?? 0
                    let time = values.count > 2 && !values[2].isEmpty ? a * 3600 + b * 60 + (Double(values[2]) ?? 0) : a * 60 + b
                    return item(at: time)?.id
                }
                if ids.count != clocks.count { ids = []; issues.append("На указанном таймкоде нет клипа.") }
            } else if ["первые два", "первых двух"].contains(where: text.contains) { ids = Array(ordered.prefix(2).map(\.id)) }
            else if text.contains("начал") && !["этого", "выбранного", "здесь"].contains(where: text.contains) { ids = ordered.first.map { [$0.id] } ?? [] }
            else if (text.contains("конец") || text.contains("финал")) && !["этого", "выбранного", "здесь"].contains(where: text.contains) { ids = ordered.last.map { [$0.id] } ?? [] }
            else if let range {
                scope = "range"
                ids = ordered.filter { $0.timelineStart < range.upperBound && $0.timelineStart + $0.timelineDuration > range.lowerBound }.map(\.id)
            } else if let selectedID {
                ids = objects[selectedID] == nil ? [] : [selectedID]
                if ids.isEmpty { issues.append("Выбранный объект не является доступным видеоклипом.") }
            } else { ids = item(at: playhead).map { [$0.id] } ?? [] }
        }
        if text.contains("дубл") || text.contains("сравни") {
            scope = "comparison"
            if ids.count < 2 { issues.append("Для сравнения нужны два явно указанных клипа.") }
        }
        var seen = Set<UUID>()
        ids = ids.filter { seen.insert($0).inserted }
        if ids.count > 3 { issues.append("Показаны только первые три клипа указанной области."); ids = Array(ids.prefix(3)) }
        var selected = ids.compactMap { objects[$0] }
        if let range, scope == "range" {
            selected = selected.compactMap { object in
                guard let i = position[object.itemID] else { return nil }
                let item = ordered[i]
                let film = max(range.lowerBound, object.filmRange.lowerBound)...min(range.upperBound, object.filmRange.upperBound)
                let a = item.sourceTime(atTimelineTime: film.lowerBound), b = item.sourceTime(atTimelineTime: film.upperBound)
                var cropped = object
                cropped.filmRange = film; cropped.sourceRange = min(a, b)...max(a, b)
                cropped.facts = object.facts.filter { $0.sourceRange.lowerBound >= cropped.sourceRange.lowerBound && $0.sourceRange.upperBound <= cropped.sourceRange.upperBound && $0.kind != .cutSpeech }
                cropped.limitations.append("Факты за пределами выделенного диапазона исключены; границы речи для этого среза не проверены.")
                return cropped
            }
        }
        let neighbors: [DirectorMomentObject] = ids.count == 1 && scope == "moment" ? ids.first.flatMap { position[$0] }.map { index in
            [index - 1, index + 1].compactMap { i in ordered.indices.contains(i) ? objects[ordered[i].id] : nil }
        } ?? [] : []
        if selected.isEmpty { issues.append("Укажите клип или таймкод для оценки.") }
        return DirectorMomentContext(projectID: projectID, revision: revision, scope: scope, objects: selected, neighbors: neighbors, limitations: issues)
    }

    private func item(at time: Double) -> TimelineItem? {
        var low = 0, high = ordered.count
        while low < high {
            let mid = (low + high) / 2
            if ordered[mid].timelineStart <= time { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let item = ordered[low - 1]
        return time < item.timelineStart + item.timelineDuration ? item : nil
    }

    private static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }

    private static func makeObject(item: TimelineItem, asset: MediaAsset?, analysis: AnalysisResult?, candidate: Candidate?) -> DirectorMomentObject {
        let source = item.sourceStart...(item.isFreezeFrame ? item.sourceStart : item.sourceStart + item.sourceDuration)
        let version = analysis.map { "\($0.schemaVersion):\($0.deepMediaVersion ?? 0):\($0.analyzedAt.timeIntervalSince1970)" } ?? "missing"
        var facts: [DirectorMomentFact] = []
        func add(_ kind: DirectorFactKind, _ coverage: ClosedRange<Double>, _ text: String, _ method: String, _ confidence: Double? = nil, _ limitations: String = "") {
            guard facts.count < 6, text.count <= 500, coverage.overlaps(source) else { return }
            facts.append(DirectorMomentFact(id: "\(item.id.uuidString)-\(facts.count)", itemID: item.id, assetID: item.assetID,
                candidateID: item.candidateID, contentHash: asset?.contentHash ?? "", analysisVersion: version,
                kind: kind, sourceRange: coverage, text: text, method: method, confidence: confidence, limitations: limitations))
        }
        var limitations: [String] = []
        if analysis == nil { limitations.append("Нет актуального анализа этого исходника.") }
        if let speech = candidate?.insights?.speech, speech.confidence >= 0.65,
           speech.phraseStart <= source.upperBound, speech.phraseEnd >= source.lowerBound {
            let words = (speech.words ?? []).filter { $0.confidence >= 0.65 && $0.endTime > source.lowerBound && $0.startTime < source.upperBound }
            let cut = words.first { ($0.startTime < source.lowerBound && $0.endTime > source.lowerBound + 0.04) || ($0.startTime < source.upperBound - 0.04 && $0.endTime > source.upperBound) }
            if let cut, !item.isReversed, !item.isFreezeFrame {
                add(.cutSpeech, max(source.lowerBound, cut.startTime)...min(source.upperBound, cut.endTime),
                    "Граница клипа проходит внутри слова «\(cut.text)».", "ASR word boundaries", cut.confidence,
                    "Границы ASR приблизительны; это не проверка на слух.")
            }
            let contained = speech.phraseStart >= source.lowerBound && speech.phraseEnd <= source.upperBound
            if contained, !item.isReversed, !item.isFreezeFrame {
                add(.speech, speech.phraseStart...speech.phraseEnd, "Фраза: «\(speech.text)».", "ASR", speech.confidence, "Транскрипция может содержать ошибки.")
            } else { limitations.append("Фраза покрыта частично либо воспроизводится в обратном порядке; её целостность не подтверждена.") }
        }
        if let evidence = candidate?.insights?.editorialEvidence, evidence.analysisVersion == EditorialEvidenceCache.version {
            for sample in evidence.samples.filter({ source.contains($0.sourceTime) && $0.confidence >= 0.65 && !$0.actionState.isEmpty }).prefix(2) {
                add(.temporalSample, sample.sourceTime...sample.sourceTime, sample.actionState.sorted().joined(separator: ", "),
                    "sampled frame", sample.confidence, "Один кадр, не последовательность действий. Время в исходнике.")
            }
        }
        if let candidate, candidate.sourceStart < source.upperBound,
           candidate.sourceStart + candidate.sourceDuration > source.lowerBound,
           let summary = candidate.insights?.sceneSummary, !summary.isEmpty {
            add(.scene, candidate.sourceStart...(candidate.sourceStart + candidate.sourceDuration), summary,
                "candidate scene summary", nil, "Описание всего эпизода, не наблюдение в точке playhead. Выбранный клип может покрывать лишь часть; нельзя утверждать, что действие попало в этот срез, или определять секунду обрезки.")
        }
        let events = candidate?.insights?.audioEvents ?? analysis?.audioAnalysis?.events ?? []
        for event in events where event.confidence >= 0.65 && event.startTime >= source.lowerBound && event.endTime <= source.upperBound {
            let dsp = event.evidence.isEmpty || event.evidence.contains { $0.localizedCaseInsensitiveContains("DSP") }
            if dsp {
                if event.kind == .silence { add(.silence, event.startTime...event.endTime, "Низкий уровень сигнала.", "DSP", event.confidence, "Это не доказательство отсутствия речи или намеренной паузы.") }
            } else {
                add(.audio, event.startTime...event.endTime, "Аудиособытие: \(event.kind.rawValue)", event.evidence.joined(separator: "; "), event.confidence, "Результат распознавания звука.")
            }
        }
        if facts.isEmpty { limitations.append("Содержательных наблюдений внутри выбранных границ нет.") }
        return DirectorMomentObject(itemID: item.id, candidateID: item.candidateID, assetID: item.assetID,
            contentHash: asset?.contentHash ?? "", analysisVersion: version,
            filmRange: item.timelineStart...(item.timelineStart + item.timelineDuration), sourceRange: source,
            role: item.storyRole?.rawValue, reversed: item.isReversed,
            analysisRange: candidate.map { $0.sourceStart...($0.sourceStart + $0.sourceDuration) }, facts: facts, limitations: limitations)
    }
}
