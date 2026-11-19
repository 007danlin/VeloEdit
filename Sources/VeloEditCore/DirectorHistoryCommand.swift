import Foundation

/// History changes must consume the entire instruction. A question about Undo,
/// a quoted title or an instruction to remove a particular effect is a different request.
public enum DirectorHistoryCommand: Sendable {
    case undo, redo

    public init?(_ prompt: String) {
        var text = prompt.lowercased().replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"^(?:(?:нет|стоп|я передумал[аи]?|передумал[аи]?|все-таки|давай|ладно)[, —]+)+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".! "))
        if text.range(of: #"^(?:undo|(?:отмени|откати)(?: (?:это|последн(?:юю|ее) (?:правку|изменение|действие)))?|верни как было|шаг назад)$"#, options: .regularExpression) != nil {
            self = .undo
        } else if text.range(of: #"^(?:redo|повтори (?:последнюю правку|отмененную правку|отмененное действие)|верни (?:отмененную правку|отмененное изменение)|шаг вперед)$"#, options: .regularExpression) != nil {
            self = .redo
        } else { return nil }
    }
}
