import Foundation
import VeloEditCore

/// A whole-film request can describe what the viewer should see without naming
/// an editor tool. Ask the model for the styles in order, once per sequence.
enum FilmWideVisualPlan {
    static func canInterpret(_ prompt: String, context: DirectorContext) -> Bool {
        guard context.currentTimelineItemCount > 0, context.selectedItemSummary == nil else { return false }
        let text = prompt.lowercased().replacingOccurrences(of: "ё", with: "е")
        let visual = ["камер", "кадр", "план", "стык", "скле", "переход", "эффект", "движени"]
        let global = #"\b(?:все|всех|всем|всему|весь|везде|кажд\w*|целиком)\b|от начала до конца"#
        guard visual.contains(where: text.contains), text.range(of: global, options: .regularExpression) != nil,
              text.range(of: #"\b(?:кроме|только|если|выбран\w*|выделен\w*|перв\w*|последн\w*)\b|\d+:\d+"#, options: .regularExpression) == nil
        else { return false }
        // Existing addressed commands (including named library effects) follow
        // the full planner. A visual-only plan cannot silently replace them.
        return EditorCommandParser().parse(prompt, preset: context.preset).isEmpty
    }

    static func request(_ prompt: String, model: String) throws -> URLRequest {
        func sequence(_ names: [String]) -> [String: Any] {
            ["type": "array", "items": ["type": "string", "enum": names], "maxItems": names.count]
        }
        let text = prompt.lowercased().replacingOccurrences(of: "ё", with: "е")
        let mentionsMotion = ["камер", "движени", "панорам", "наезд", "отъезд", "прибли", "вбок"].contains(where: text.contains)
        let mentionsCuts = ["склей", "стык", "перетек", "переход", "смена кадр", "между"].contains(where: text.contains)
        var properties: [String: Any] = ["coverage": ["type": "string", "enum": ["whole-film", "other"]]]
        if mentionsMotion || !mentionsCuts {
            properties["motion"] = sequence(ClipEffect.allCases.map(\.rawValue))
        }
        if mentionsCuts || !mentionsMotion {
            properties["cuts"] = sequence(TransitionStyle.allCases.filter { $0 != .cut }.map(\.rawValue))
        }
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": properties.keys.sorted(), "properties": properties
        ]
        let system = """
            Переведи просьбу монтажёра в последовательность приёмов. Если ВСЮ просьбу можно выполнить движением камеры на всех планах и/или переходами на всех склейках, coverage = whole-film. Иначе coverage = other. Если для любого действия нет поля в схеме, верни other. Частичный диапазон, разные адресаты, исключения, снятие эффекта, дополнительные действия или вопрос требуют other.
            motion — движения внутри кадров: плавно ближе = push-in, отъезд = pull-out, вбок = pan-left или pan-right. cuts — способы соединить соседние кадры: один перетекает в другой = cross-dissolve. Оставь незапрошенный массив пустым. Для одинакового приёма верни одно значение. При чередовании перечисли приёмы одного цикла в нужном порядке, движок сам повторит цикл до конца фильма.
            """
        let body: [String: Any] = [
            "model": model, "think": false, "stream": true, "format": schema,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
            "options": ["temperature": 0, "num_predict": 280]
        ]
        var request = URLRequest(url: LocalAIRuntimeConfiguration.baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func commands(from content: String) throws -> [EditorCommand]? {
        struct Plan: Decodable {
            let coverage: String
            let motion: [ClipEffect]?
            let cuts: [TransitionStyle]?
        }
        let plan = try JSONDecoder().decode(Plan.self, from: Data(content.utf8))
        let motion = plan.motion ?? []
        let cuts = plan.cuts ?? []
        guard plan.coverage == "whole-film", !cuts.contains(.cut) else { return nil }
        var commands: [EditorCommand] = []
        if let first = motion.first {
            commands.append(motion.count == 1 ? .setEffect(first, .all) : .setEffectPattern(motion, .all))
        }
        if let first = cuts.first {
            commands.append(cuts.count == 1 ? .setTransition(first, .all) : .setTransitionPattern(cuts, .all))
        }
        return commands.isEmpty ? nil : commands
    }
}
