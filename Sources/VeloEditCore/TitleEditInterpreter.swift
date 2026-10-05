import Foundation

/// Shared title commands for the director, timeline composer and inspector.
/// An unrecognized request never substitutes an arbitrary template.
public enum TitleEditInterpreter {
    public struct Result: Sendable {
        public var item: TitleTimelineItem
        public var changes: [String]
    }

    public static func targetsSelectedTitle(_ instruction: String) -> Bool {
        let text = normalized(instruction.replacingOccurrences(of: #"[«“\"][^»”\"]+[»”\"]"#, with: "", options: .regularExpression))
        guard DirectorRequestIntentInterpreter().mode(for: instruction) == .edit else { return false }
        // Keep wider montage requests on their existing execution path.
        guard !["фильм", "монтаж", "музык", "звук", "клип", "ролик", "видео", "переход", "эффект", "все титры", "всех титр"]
            .contains(where: text.contains) else { return false }
        return ["титр", "глав", "надпис", "подзаголов", "шрифт", "текст"].contains(where: text.contains)
            || applying(instruction, to: TitleTimelineItem(kind: .title, text: "", startTime: 0, duration: 3)) != nil
    }

    public static func applying(_ instruction: String, to original: TitleTimelineItem) -> Result? {
        var item = original
        var changes: [String] = []
        let quotedPattern = #"[«“\"]([^»”\"]+)[»”\"]"#
        // Text supplied in quotes is content, not a style instruction.
        let text = normalized(instruction.replacingOccurrences(of: quotedPattern, with: "", options: .regularExpression))
        func contains(_ values: [String]) -> Bool { values.contains(where: text.contains) }
        func capture(_ pattern: String, in source: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let aliases: [(String, [String])] = [
            ("title.cinematic.v1", ["кинемат", "кинош"]),
            ("title.dynamic.v1", ["динами", "экшен", "энергич"]),
            ("title.modern.v1", ["современн"]),
            ("title.elegant.v1", ["элегант", "нежн", "изящ"]),
            ("title.bold.v1", ["жирн", "контрастн"]),
            ("title.travel.v1", ["путешеств"]),
            ("title.location.v1", ["локац"]),
            ("title.end-card.v1", ["финальн", "конечн"]),
            ("title.minimal-clean.v1", ["минимал", "простым", "чистым"])
        ]
        let isCaption = original.speechAnchor != nil || [.subtitle, .automaticSubtitles, .wordLevelCaptions].contains(original.kind)
        let named = TitleTemplateRegistry.all.first { template in
            guard template.category != .captions || isCaption || text.contains(template.id) else { return false }
            let escaped = NSRegularExpression.escapedPattern(for: template.name.lowercased())
            return text.range(of: "\\b" + escaped + "\\b", options: .regularExpression) != nil || text.contains(template.id)
        }
        let captionAliases = [("cinematic", ["кинош", "кинемат"]), ("vlog", ["влог"]),
                              ("travel", ["путешеств"]), ("social", ["соцсет"])]
        let captionTemplate = isCaption ? captionAliases.first(where: { contains($0.1) })
            .flatMap { TitleTemplateRegistry.template(id: "caption.\($0.0).v1") } : nil
        let template = named ?? captionTemplate ?? aliases.first(where: { contains($0.1) }).flatMap { TitleTemplateRegistry.template(id: $0.0) }
        if let template {
            if template.id != item.effectiveTemplateID {
                item.templateID = template.id
                item.kind = template.kind
                item.style = template.defaultStyle
                item.activeWordHighlighting = template.kind == .wordLevelCaptions
            }
            changes.append("шаблон \(template.name)")
        }

        if let quoted = capture(#"(?:на|→)\s*[«“\"]([^»”\"]+)[»”\"]"#, in: instruction) ?? capture(quotedPattern, in: instruction) {
            if contains(["подзаголов", "второй строк", "нижней строк"]) {
                item.additionalText = quoted
                changes.append("подзаголовок")
            } else if contains(["кнопк", "cta", "призыв"]) {
                item.callToAction = quoted
                changes.append("финальная подпись")
            } else if contains(["текст", "напиши", "замени", "назови", "назван", "переимен", "титр"]) {
                item.text = quoted
                changes.append("текст")
            }
        } else if let value = capture(#"(?:текст|напиши|название)\s*[:=]\s*(.+)$"#, in: instruction) {
            item.text = value
            changes.append("текст")
        }

        if let value = capture(#"(?:номер\s+главы|глав[аыуе]|chapter)\s*(?:номер|на|теперь|будет|сделай|поставь|:|=|№)?\s*(\d{1,3})\b"#, in: text), let number = Int(value) {
            item.setChapterNumber(number)
            changes.append("номер главы \(item.formattedChapterNumber)")
        }
        if contains(["убери подзаголов", "без подзаголов", "удали подзаголов"]) {
            item.additionalText = nil
            changes.append("без подзаголовка")
        }
        if contains(["убери кнопку", "без кнопки", "убери cta", "без cta"]) {
            item.callToAction = nil
            changes.append("без финальной подписи")
        }
        let colors: [(String, [String])] = [
            ("#FF453A", ["красн"]), ("#FFD60A", ["желт", "золот"]),
            ("#30D158", ["зелен"]), ("#64D2FF", ["сини", "синий", "синего", "голуб"]),
            ("#A78BFA", ["фиолет"]), ("#FF9F0A", ["оранж"]), ("#FF85C0", ["розов"]),
            ("#AEB4BF", ["серым", "серый", "серого"]), ("#111111", ["черн"]), ("#FFFFFF", ["бел"])
        ]
        if let color = colors.first(where: { contains($0.1) }) {
            item.style.textColorHex = color.0
            changes.append("цвет текста")
        }
        if let size = capture(#"(?:размер(?:\s+шрифта)?|шрифт)\s*(?:на|:|=)?\s*(\d{2,3})\b"#, in: text).flatMap(Double.init) {
            item.style.fontSize = min(260, max(12, size))
            changes.append("размер текста")
        } else if contains(["крупн", "больше", "увеличь"]) {
            item.style.fontSize = min(260, item.style.fontSize * 1.2)
            changes.append("текст крупнее")
        } else if contains(["мельче", "мелк", "меньше", "уменьши"]) {
            item.style.fontSize = max(12, item.style.fontSize * 0.8)
            changes.append("текст мельче")
        }
        if contains(["выше", "подними"]) {
            item.style.yPosition = max(0.15, item.style.effectiveYPosition - 0.08)
            changes.append("положение выше")
        } else if contains(["ниже", "опусти"]) {
            item.style.yPosition = min(0.85, item.style.effectiveYPosition + 0.08)
            changes.append("положение ниже")
        }
        if contains(["без анимац", "убери анимац"]) {
            item.animation.entrance = .none
            item.animation.exit = .none
            changes.append("без анимации")
        }
        if let value = capture(#"(?:длительност[ьи]|длится|на)\s*(\d+(?:[.,]\d+)?)\s*(?:сек|с\b)"#, in: text),
           let duration = Double(value.replacingOccurrences(of: ",", with: ".")) {
            item.duration = min(30, max(0.25, duration))
            changes.append("длительность")
        }
        guard !changes.isEmpty else { return nil }
        return Result(item: item, changes: changes)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }
}
