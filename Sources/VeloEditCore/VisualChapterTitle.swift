import Foundation
import NaturalLanguage

public struct ChapterTitleFrame: Codable, Hashable, Sendable {
    public var itemID: UUID
    public var assetID: UUID
    public var sourceStart: Double
    public var sourceDuration: Double
    public var sourceSeconds: Double
    public var timelineSeconds: Double
    public var imageHash: String
}

public struct VisualChapterTitleReceipt: Codable, Hashable, Sendable {
    static let role = "chapter-title-vision-v3"
    public var requestRole: String
    public var modelIdentity: String
    public var frames: [ChapterTitleFrame]
    public var answer: String
    public var responseCacheHit: Bool

    func matches(part: FilmPart, timeline: Timeline) -> Bool {
        let membership = Set(part.itemIDs)
        let shots = timeline.items.filter { membership.contains($0.id) }.sorted { $0.timelineStart < $1.timelineStart }
        let sampled = LocalChapterTitleModel.framePositions(shots)
        guard !sampled.isEmpty, frames.count == sampled.count else { return false }
        return zip(frames, sampled).allSatisfy { frame, position in
            let item = position.item
            return frame.itemID == item.id && frame.assetID == item.assetID && !frame.imageHash.isEmpty
                && frame.sourceStart == item.sourceStart && frame.sourceDuration == item.sourceDuration
                && abs(frame.timelineSeconds - position.seconds) < 0.001
        }
    }
}

extension LocalChapterTitleModel {
    static func sampledShots(_ items: [TimelineItem], limit: Int = 12) -> [TimelineItem] {
        guard items.count > limit, limit >= 3 else { return items }
        var chosen: Set<Int> = [0, items.count / 2, items.count - 1]
        let changes = (1..<items.count).filter { items[$0].eventID != items[$0 - 1].eventID }
        for index in changes where chosen.count < limit { chosen.insert(index) }
        // Bisect the largest remaining gap to keep the whole edit represented.
        while chosen.count < limit {
            let ordered = chosen.sorted()
            guard let gap = zip(ordered, ordered.dropFirst()).max(by: { $0.1 - $0.0 < $1.1 - $1.0 }) else { break }
            chosen.insert((gap.0 + gap.1) / 2)
        }
        return chosen.sorted().map { items[$0] }
    }

    /// A single moving shot needs temporal context to distinguish the scene
    /// from an ambiguous foreground detail in a single still.
    static func framePositions(_ items: [TimelineItem]) -> [(item: TimelineItem, seconds: Double)] {
        if items.count == 1, let only = items.first, only.kind == .video,
           min(only.sourceDuration, only.timelineDuration) >= 1.5 {
            return [0.2, 0.5, 0.8].map { (only, only.timelineStart + only.timelineDuration * $0) }
        }
        return sampledShots(items).map { ($0, $0.timelineStart + $0.timelineDuration / 2) }
    }

    private struct VisualReply: Decodable {
        let observation: String
        let title: String
    }

    static func displayTitle(_ answer: String, maximum: Int) -> String? {
        let raw = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if raw.hasPrefix("{") {
            guard let reply = try? JSONDecoder().decode(VisualReply.self, from: Data(raw.utf8)),
                  !reply.observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            text = reply.title
        } else { text = raw }
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "«»\"“”"))
        let productionTerms = #"(?i)\b(кадр(?:ы|а|е|ом)?|заголовок|титр|съёмка)\b"#
        guard title.count <= maximum, !SmartTitleEngine.isPlaceholderTitle(title),
              title.range(of: productionTerms, options: .regularExpression) == nil,
              title.range(of: #"^[А-Яа-яЁё]+(?:[- ][А-Яа-яЁё]+){0,4}$"#, options: .regularExpression) != nil else { return nil }
        return title
    }

    static func conflictsWithEvent(_ title: String, event: String?) -> Bool {
        guard let event, let subject = ActivityCompatibilityContract.evidence(in: [title]).family,
              let eventSubject = ActivityCompatibilityContract.evidence(in: [event]).family else { return false }
        return subject != eventSubject
    }

    /// Check the model's proposed claim against its own visual note and the
    /// independent evidence already available for this exact cut.
    static func rejectionReason(for title: String, answer: String, event: String?, observations: [String]) -> String? {
        if conflictsWithEvent(title, event: event) {
            return "Действие в названии противоречит подтверждённой теме всей главы"
        }
        guard let reply = try? JSONDecoder().decode(VisualReply.self, from: Data(answer.utf8)) else { return nil }
        let evidence = observations.joined(separator: " ").lowercased()
        let name = title.lowercased()
        let people = #"(?i)\b(человек|люд|мужчин|женщин|реб[её]н|дети|девуш|парень|спортсмен|турист|водител|гонщик|велосипедист|рыбак|пешеход|путник|person|people|rider|cyclist)"#
        if name.range(of: people, options: .regularExpression) != nil,
           (reply.observation + " " + evidence).range(of: people, options: .regularExpression) == nil {
            return "Титр называет участника, которого нет в наблюдениях выбранных кадров"
        }
        let flight = #"(?i)\b(парени|парящ|пол[её]т|взл[её]т|прол[её]т|летящ)"#
        if name.range(of: flight, options: .regularExpression) != nil {
            let airborne = #"(?i)\b(парит|парят|парящ|летит|летят|летящ|летел|летал|лететь|пол[её]т|взлет|взлёт|дрон|беспилотник|аэросъ[её]м|с высоты|flying|aerial|soaring|hovering|airborne|drone|takeoff|in flight)"#
            if (reply.observation + " " + evidence).range(of: airborne, options: .regularExpression) == nil {
                return "Наблюдения выбранных кадров не подтверждают полёт"
            }
        }
        if let reason = unsupportedSpecificClaim(in: title, observation: reply.observation, evidence: evidence) { return reason }
        let kinship = #"(?i)\b(семейн|семь[яиюе]|родител|бабушк|дедушк|супруг|сестр|брат|внук)"#
        if name.range(of: kinship, options: .regularExpression) != nil,
           evidence.range(of: kinship, options: .regularExpression) == nil {
            return "Родственные отношения не подтверждены для выбранных кадров"
        }
        // A building's condition is visible, but its occupancy or history is
        // an inference. Require corroboration before making it a chapter title.
        if (name.contains("заброшен") || name.contains("забыты") || name.contains("забыто")),
           !evidence.contains("заброшен"), !evidence.contains("забыт"), !evidence.contains("abandon") {
            return "Статус места не подтверждён независимыми наблюдениями выбранных кадров"
        }
        if let event, let vehicle = specificVehicle(in: event),
           let other = specificVehicle(in: title), other != vehicle,
           evidence.range(of: other, options: .regularExpression) == nil {
            return "В названии указан другой транспорт без подтверждения в выбранных кадрах"
        }
        return nil
    }

    private static func unsupportedSpecificClaim(in title: String, observation: String, evidence: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass, .lemma])
        let prefix = "Это "
        let sentence = prefix + title
        tagger.string = sentence
        let range = sentence.index(sentence.startIndex, offsetBy: prefix.count)..<sentence.endIndex
        tagger.setLanguage(.russian, range: sentence.startIndex..<sentence.endIndex)
        let notes = (observation + " " + evidence).lowercased()
        var reason: String?
        var previous = ""
        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { kind, word in
            let (nameType, _) = tagger.tag(at: word.lowerBound, unit: .word, scheme: .nameType)
            let (lemma, _) = tagger.tag(at: word.lowerBound, unit: .word, scheme: .lemma)
            let base = (lemma?.rawValue ?? String(sentence[word])).lowercased()
            let form = sentence[word].lowercased()
            defer { previous = form }
            // With a genitive masculine noun, «с» denotes a source; the
            // instrumental would denote accompaniment. A stationary scene
            // supplies no evidence that something came from that source.
            if previous == "с", kind == .noun, form == base + "а",
               !notes.contains("с " + form),
               notes.range(of: #"(?i)\b(вернул|возвращ|спуска|сош[её]л|уехал|приехал|выезж)"#, options: .regularExpression) == nil {
                reason = "Титр указывает, откуда пришли или приехали, без такого наблюдения в кадрах"
                return false
            }
            let capitalizedNoun = kind == .noun && word.lowerBound != range.lowerBound && sentence[word].first?.isUppercase == true
            if nameType == .placeName || nameType == .personalName || nameType == .organizationName || capitalizedNoun {
                let stem = String(base.dropLast(base.count > 4 ? 1 : 0))
                if !evidence.contains(stem) { reason = "Имя в названии отсутствует в независимых наблюдениях выбранных кадров" }
            } else if kind == .adjective, base.hasSuffix("ский"), base.count >= 7 {
                // Russian place-derived adjectives are often tagged as ordinary
                // adjectives. Require their stem in the visual note or cut evidence.
                if !notes.contains(String(base.dropLast(4))) { reason = "Уточнение места отсутствует в наблюдениях выбранных кадров" }
            }
            return reason == nil
        }
        return reason
    }

    private static func specificVehicle(in text: String) -> String? {
        let kinds = ["багги|buggy|utv", "джип|внедорожник|jeep|suv", "грузовик|truck",
                     "мотоцикл|motorcycle", "катер|лодк|яхт|boat|yacht", "гольф|golf"]
        return kinds.map { #"(?i)\b(?:"# + $0 + ")" }
            .first { text.range(of: $0, options: .regularExpression) != nil }
    }

    func verifiedVisualTitleProfile() async throws -> FilmProcessProfile {
        let manager = LocalAIModelManager.shared
        let modelID = AIAnalysisProfile.sharedTitleModelID
        try await manager.ensureAuthorizedModelAvailable(model: modelID)
        guard let digest = await manager.installedModelDigest(model: modelID), identity == modelID + "@" + digest else {
            throw LocalAIInferenceFailure(model: modelID, reason: "Не удалось подтвердить digest модели титров")
        }
        if let expected = FilmProcessContext.current?.titleModelDigest, expected != digest {
            throw FilmProcessProfileError.changedWeights(modelID)
        }
        return FilmProcessProfile(analysis: .resolve(mode: .fast), modelDigest: digest)
    }

    func visualTitle(items: [TimelineItem], assets: [UUID: MediaAsset], limit: Int, correction: String? = nil) async throws -> VisualChapterTitleReceipt {
        let modelID = AIAnalysisProfile.sharedTitleModelID
        let titleProfile = try await verifiedVisualTitleProfile()
        let root = responseCacheURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("VeloEdit-ChapterFrames")
        let cache = FrameCache(rootURL: root.appendingPathComponent("Frames"))
        let sampler = AdaptiveFrameSampler()
        var frames: [ChapterTitleFrame] = []
        var images: [String] = []
        for (item, timelineSeconds) in Self.framePositions(items) {
            try Task.checkCancellation()
            guard let id = item.assetID, let asset = assets[id] else { throw ChapterTitleFailure.insufficientEvidence }
            let time = item.sourceTime(atTimelineTime: timelineSeconds)
            let sample: VisualFrameSample?
            if asset.kind == .photo {
                sample = try await sampler.samplePhoto(url: asset.originalURL, sourceHash: asset.contentHash, maximumSize: 640, frameCache: cache).samples.first
            } else {
                sample = try await sampler.selectedContentSamples(url: asset.originalURL, sourceHash: asset.contentHash, timestamps: [time], frameCache: cache, maximumSize: 640).first
            }
            guard let sample, !sample.jpegBase64.isEmpty else { throw ChapterTitleFailure.insufficientEvidence }
            let actual = sample.actualTimestamp ?? sample.timestamp
            guard asset.kind == .photo || (actual >= item.sourceStart && actual < item.sourceStart + item.sourceDuration) else {
                throw ChapterTitleFailure.insufficientEvidence
            }
            images.append(sample.jpegBase64)
            frames.append(.init(itemID: item.id, assetID: id, sourceStart: item.sourceStart, sourceDuration: item.sourceDuration,
                                sourceSeconds: actual, timelineSeconds: timelineSeconds,
                                imageHash: EditorialIdentity.hash(sample.jpegBase64)))
        }
        guard !images.isEmpty else { throw ChapterTitleFailure.insufficientEvidence }
        var prompt = "Эти фотографии идут в порядке монтажа одной главы домашнего фильма. В поле observation кратко опиши саму сцену: где мы и что происходит. В поле title придумай естественное русское название всей главы из одного–пяти слов. Выбери явное действие, место или настроение, общее для снимков. Если марка, вид транспорта или предмет узнаются неоднозначно, опиши обстановку. Избегай технических слов о кадрах и съёмке."
        if let correction {
            prompt += " Предыдущее название отклонено. " + correction + ". Посмотри на эти же фотографии ещё раз. Назови простыми словами только то, что непосредственно видно. Не добавляй метафору, занятие или историю места."
        }
        let format: [String: Any] = [
            "type": "object", "properties": [
                "observation": ["type": "string", "maxLength": 150],
                "title": ["type": "string", "pattern": "^[А-ЯЁа-яё]+(?:[- ][А-ЯЁа-яё]+){0,4}$", "maxLength": limit]
            ], "required": ["observation", "title"], "additionalProperties": false
        ]
        let role = VisualChapterTitleReceipt.role
        let key = EditorialIdentity.hash(([role, identity, prompt, String(limit)] + frames.map(\.imageHash)).joined(separator: "|"))
        let file = responseCacheURL?.appendingPathComponent(key + ".txt")
        if let file, let answer = try? String(contentsOf: file, encoding: .utf8) {
            return .init(requestRole: role, modelIdentity: identity, frames: frames, answer: answer, responseCacheHit: true)
        }
        let body: [String: Any] = ["model": modelID, "stream": true, "think": false, "format": format,
            "messages": [["role": "user", "content": prompt, "images": images]],
            "options": ["temperature": 0, "seed": 42, "num_ctx": 16384, "num_predict": 160]]
        var request = URLRequest(url: LocalAIRuntimeConfiguration.baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = titleProfile.analysis.vlmPrefillTimeout(imageCount: images.count)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        let (bytes, response) = try await FilmProcessContext.$current.withValue(titleProfile) {
            try await LocalAIInferenceClient.shared.response(for: request, progress: FilmBuildReporting.handler)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              result["model"] as? String == modelID, result["done"] as? Bool == true,
              result["done_reason"] as? String == "stop",
              let answer = (result["message"] as? [String: Any])?["content"] as? String else { throw ChapterTitleFailure.invalidResponse }
        try titleProfile.validate(model: modelID, digest: await LocalAIModelManager.shared.installedModelDigest(model: modelID))
        if let file {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try answer.write(to: file, atomically: true, encoding: .utf8)
        }
        return .init(requestRole: role, modelIdentity: identity, frames: frames, answer: answer, responseCacheHit: false)
    }
}
