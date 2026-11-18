import Foundation
import VeloEditCore

/// Interpret localized pacing and musical endings together. The compact schema
/// lets the local model specify both layers without generating a clip-by-clip plan.
enum SectionPacingPlan {
    static func canInterpret(_ prompt: String, context: DirectorContext) -> Bool {
        guard context.currentTimelineItemCount > 0, context.selectedItemSummary == nil else { return false }
        let text = prompt.lowercased().replacingOccurrences(of: "ё", with: "е")
        return ["начал", "вступлен", "старт", "раскачк", "финал", "конц", "конец", "концов"].contains(where: text.contains)
            && ["темп", "энерг", "бодр", "плотн", "живее", "динами", "музык", "саундтрек", "мелоди"].contains(where: text.contains)
            && text.range(of: #"\d+:\d+|\b(?:кроме|если|выбран\w*|выделен\w*)\b"#, options: .regularExpression) == nil
    }

    static func request(_ prompt: String, model: String) throws -> URLRequest {
        let words = prompt.lowercased()
        let mentionsMusic = ["музык", "саундтрек", "трек", "мелоди", "песн"].contains(where: words.contains)
        let fade: [String: Any] = mentionsMusic
            ? ["type": "number", "minimum": 0, "maximum": 30]
            : ["type": "number", "enum": [0]]
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["coverage", "tighten", "musicFadeSeconds"],
            "properties": [
                "coverage": ["type": "string", "enum": ["complete", "other"]],
                "tighten": ["type": "string", "enum": ["first", "last", "none"]],
                "musicFadeSeconds": fade
            ]
        ]
        let instruction = """
            Прочитай всё пожелание монтажёра. Сократить первый или последний план, чтобы оживить темп этого участка — tighten first или last. Если не просили уплотнить монтаж, tighten none. Плавно погасить существующую музыку к концу фильма — musicFadeSeconds, число секунд из запроса или 4, если длительность не указана. Если про затухание не просили, верни 0. Заполни оба поля независимо. coverage complete только если эти действия выполняют ВСЁ пожелание. Для дополнительных правок, конкретной скорости или длины плана, другого адресата, условий, отрицаний, смены трека, постоянной громкости или совета верни other.
            """
        let body: [String: Any] = [
            "model": model, "think": false, "stream": true, "format": schema,
            "messages": [["role": "system", "content": instruction], ["role": "user", "content": prompt]],
            "options": ["temperature": 0, "num_predict": 160]
        ]
        var request = URLRequest(url: LocalAIRuntimeConfiguration.baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func commands(from content: String) throws -> [EditorCommand]? {
        struct Plan: Decodable {
            enum Section: String, Decodable { case first, last, none }
            var coverage: String
            var tighten: Section
            var musicFadeSeconds: Double
        }
        let plan = try JSONDecoder().decode(Plan.self, from: Data(content.utf8))
        guard plan.coverage == "complete", (0...30).contains(plan.musicFadeSeconds) else { return nil }
        var result: [EditorCommand] = []
        if plan.tighten != .none { result.append(.tightenCut(plan.tighten == .first ? .first : .last)) }
        if plan.musicFadeSeconds > 0 { result.append(.setMusicEndingFade(plan.musicFadeSeconds)) }
        return result.isEmpty ? nil : result
    }
}
