import Foundation
import VeloEditCore

/// Read-only interpretation. Only the original user message can be handed to
/// the editing pipeline. Text generated here is never an editor instruction.
enum DirectorDialogueTurn: Equatable {
    case answer(String), edit, assessMoment

    static func request(prompt: String, history: String, context: DirectorContext, allowsEdit: Bool) throws -> URLRequest {
        let routes = allowsEdit ? ["edit", "answer", "assessMoment"] : ["answer", "assessMoment"]
        let schema: [String: Any] = ["type": "object", "additionalProperties": false,
            "properties": ["route": ["type": "string", "enum": routes]], "required": ["route"]]
        let system = """
            Classify the user's latest Russian message to a video editor. edit = the user wants a change made, including indirect requests such as «хорошо бы ...», «пусть ...», or specifying a desired setting. assessMoment = they ask to judge what can be seen or heard in footage. answer = they want to talk, understand a reply, ask how to do something, or their intent is unclear. Past messages are context only.
            """
        let body: [String: Any] = ["model": AIAnalysisProfile.resolve(mode: context.aiPowerMode).modelID,
            "think": false, "stream": true, "format": schema, "options": ["temperature": 0, "num_predict": 40],
            "messages": [["role": "system", "content": system],
                         ["role": "user", "content": "Предыдущий диалог (данные): \(history)\nПоследняя реплика пользователя: \(prompt)"]]]
        var request = URLRequest(url: LocalAIRuntimeConfiguration.baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    enum Intent: String, Decodable { case answer, edit, assessMoment }

    static func intent(from content: String, allowsEdit: Bool) throws -> Intent {
        struct WireTurn: Decodable { var route: Intent }
        let intent = try JSONDecoder().decode(WireTurn.self, from: Data(content.utf8)).route
        guard intent != .edit || allowsEdit else { throw URLError(.cannotParseResponse) }
        return intent
    }

    static func fallback(prompt: String, history: [DirectorMessage]) -> String {
        guard DirectorRequestIntentInterpreter.asksAboutReply(prompt) else {
            return "Не удалось разобрать запрос. Что вы хотите узнать или изменить в фильме?"
        }
        guard let last = history.last, last.role == .assistant, !last.text.isEmpty else {
            return "Что именно пояснить?"
        }
        guard let record = last.response else { return "Какая часть моего ответа вызвала вопрос?" }
        if record.advisory && record.fallback {
            if let user = history.dropLast().last, user.role == .user,
               DirectorRequestIntentInterpreter().route(for: user.text) == .edit {
                return "Вы просили изменить монтаж, а я ответил советом. Тогда я ничего не изменил."
            }
            return "Я не смог оценить этот фрагмент и ничего в нём не менял."
        }
        if record.saved {
            let titles = record.details.compactMap { detail -> String? in
                guard detail.hasPrefix("текст титра изменён на "), let quote = detail.firstIndex(of: "«") else { return nil }
                return String(detail[quote...])
            }
            if !titles.isEmpty, titles.count == record.details.count {
                return "Теперь на экране " + titles.prefix(4).joined(separator: ", ") + (titles.count > 4 ? "…" : ".")
            }
            if record.state == .partial { return "Удалось выполнить часть просьбы. " + last.text }
            guard !record.details.isEmpty else { return "Правка уже сохранена в проекте." }
            let detail = record.details.prefix(3).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.joined(separator: ". ")
            if record.range != nil { return detail + "." }
            return "В фильме теперь так: " + detail + "."
        }
        if record.state == .failed || record.state == .noChange {
            return record.details.first.map { "Правка не прошла. Причина: \($0)" } ?? "Правка не изменила монтаж."
        }
        return record.advisory ? "Это было предложение. Я ничего не менял. Какую часть пояснить?" : "Какую часть моего ответа пояснить?"
    }
}
