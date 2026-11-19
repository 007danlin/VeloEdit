import Foundation
import VeloEditCore

/// Resolve the look independently from the area the user asked to edit.
enum DirectorAppearancePlan {
    static func target(for prompt: String, brush: Bool) -> EditorCommandTarget? {
        guard canInterpret(prompt) else { return nil }
        if brush { return .selected }
        let wholeFilm = #"\b(?:весь (?:ролик|фильм)|вс[её] видео|по всему (?:ролику|фильму)|на (?:всех (?:клипах|планах)|все (?:клипы|планы))|от начала до конца)\b"#
        guard prompt.range(of: wholeFilm, options: [.regularExpression, .caseInsensitive]) != nil,
              !EditorCommandParser.refersToCurrentLocation(prompt) else { return nil }
        return .all
    }

    static func canInterpret(_ prompt: String) -> Bool {
        let text = prompt.lowercased().replacingOccurrences(of: "ё", with: "е")
        let appearance = #"\b(?:эффект|фильтр|цвет|картинк|выгляд|пленк|(?:видео)?кассет|оттенк|тон|пиксел|будто|словно|похож)"#
        guard text.range(of: appearance, options: .regularExpression) != nil else { return false }
        let restriction = #"\d|[;!?]\s*\S|\b(?:и|но|если|кроме|только на|не|сначала|потом|вместо|перв\w*|втор\w*|последн\w*|половин\w*|лиц[оеау]|номер\w*|объект\w*|фон\w*|переход\w*|звук\w*|музык\w*|титр\w*|убери|удали|отмени|сбрось|верни)\b"#
        guard text.range(of: restriction, options: .regularExpression) == nil else { return false }
        return EditorCommandParser().parse(prompt).isEmpty
    }

    private static func choices(for target: EditorCommandTarget) -> [String: EditorCommand] {
        var choices: [String: EditorCommand] = [:]
        for filter in VideoFilter.allCases where filter != .none {
            choices[filter.localizedTitle] = .setFilter(filter, target)
        }
        for effect in TimelineEffectType.allCases { choices[effect.localizedTitle] = .addLibraryEffect(effect, target) }
        return choices
    }

    static func request(_ prompt: String, model: String) throws -> URLRequest {
        // Describe the visible result of opaque or easily confused preset names.
        // The model returns the displayed name directly, in the user's language.
        let descriptions: [TimelineEffectType: String] = [
            .fisheye: "сверхширокий угол, выпуклый центр, края изгибаются",
            .barrelDistortion: "прямые линии выгибаются наружу, как на бочке",
            .lensDistortion: "геометрическое искажение оптикой",
            .videoCamera: "рамка записи, видоискатель и индикатор REC",
            .vhsDistortion: "аналоговая видеокассета, помехи старой магнитной ленты",
            .scanlines: "видны горизонтальные строки телеэкрана",
            .pixelate: "изображение из крупных квадратных пикселей, мозаика",
            .halftone: "печатный растр из точек", .posterize: "мало градаций цвета",
            .filmGrain: "фактура зернистой киноплёнки", .filmBurn: "засветка горящей плёнки",
            .rgbSplit: "цветные контуры расходятся", .glitch: "цифровые сбои, изображение распадается",
            .letterbox: "чёрные полосы сверху и снизу", .vignette: "затемнение краёв",
            .handheld: "покачивание при съёмке с рук", .backgroundBlur: "фон вне фокуса",
            .vintage: "выцветшее ретроизображение", .softFocus: "мягкие контуры по всему кадру"
        ]
        let names = VideoFilter.allCases.filter { $0 != .none }.map(\.localizedTitle) + TimelineEffectType.allCases.map { effect in
            descriptions[effect].map { "\(effect.localizedTitle) — \($0)" } ?? effect.localizedTitle
        }
        let system = """
            Ты подбираешь оформление видео. Выбери одно название из каталога по тому, как должна выглядеть картинка. Учитывай физический смысл описания. Если для всей просьбы одного эффекта на всю картинку недостаточно, есть отдельные действия, условия, маска, разные адресаты или вопрос — ответь other.
            Каталог: \(names.joined(separator: "; ")).
            """
        let schema: [String: Any] = ["type": "object", "required": ["look"], "additionalProperties": false,
            "properties": ["look": ["type": "string", "enum": ["other"] + choices(for: .selected).keys.sorted()]]]
        let body: [String: Any] = ["model": model, "stream": true, "think": false, "format": schema,
            "options": ["temperature": 0, "num_predict": 40],
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]]
        var request = URLRequest(url: LocalAIRuntimeConfiguration.baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func command(from content: String, target: EditorCommandTarget) throws -> EditorCommand? {
        struct Plan: Decodable { let look: String }
        return choices(for: target)[try JSONDecoder().decode(Plan.self, from: Data(content.utf8)).look]
    }
}
