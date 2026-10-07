import Foundation

/// A small, closed grammar for everyday edits. Every word must be consumed;
/// fuzzy scene descriptions, exclusions and unknown tails stay with the director.
/// This is also used by the regular planner, so routing cannot change the edit.
enum ExactEditorCommandParser {
    struct Result {
        var commands: [EditorCommand]
        var target: EditorCommandTarget?
    }

    static func cleanRequest(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip politeness only at the edges. Never rewrite quoted title text.
        for _ in 0..<4 {
            text = text.replacingOccurrences(of: #"^(?:(?:ну\s+)?(?:и\s+)?(?:еще|ещё|также|теперь|а еще|а ещё)|пожалуйста|можешь|можно)\b[,\s]*"#,
                with: "", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: #"[,\s]+пожалуйста[.!?]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseClause(_ input: String, hasSelection: Bool, inheritedTarget: EditorCommandTarget? = nil) -> Result? {
        var text = cleanRequest(input).lowercased().replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
        // A question about an effect is not an instruction to add it.
        guard !text.isEmpty else { return nil }
        func match(_ pattern: String, in value: String? = nil) -> [String]? {
            let source = value ?? text
            guard let regex = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$"),
                  let result = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return nil }
            return (1..<result.numberOfRanges).map { Range(result.range(at: $0), in: source).map { String(source[$0]) } ?? "" }
        }
        func number(_ string: String) -> Double? { Double(string.replacingOccurrences(of: ",", with: ".")) }
        let decimal = #"(\d+(?:[.,]\d+)?)"#
        let setting = #"(?:(?:сделай|поставь|установи|установить|выставь)\s+)?"#
        let add = #"(?:(?:хочу|нужно)\s+)?(?:добавь|добавить|наложи|наложить|поставь|поставить|примени|применить|включи|включить|хочу|нужен|нужна|нужно|сделай)\s+"#
        let remove = #"(?:убери|убрать|удали|удалить|отключи|отключить|выключи|выключить)\s+"#

        // Global soundtrack operations are handled before media target parsing.
        if let values = match(setting + #"(?:громкость музыки\s+(?:на\s+)?|музыку\s+на\s+)"# + decimal + #"\s*%"#),
           let value = number(values[0]), (0...100).contains(value) {
            return Result(commands: [.setMusicVolume(value / 100)], target: nil)
        }
        if match(#"(?:приглуши музыку|сделай музыку тише|музыку потише|убавь музыку)"#) != nil {
            return Result(commands: [.setMusicVolume(0.25)], target: nil)
        }
        if match(remove + #"музыку|без музыки"#) != nil { return Result(commands: [.setMusic(nil)], target: nil) }
        if match(#"(?:приглуши музыку|музыку тише) под (?:речь|голос)"#) != nil {
            return Result(commands: [.setAudioDucking(true)], target: nil)
        }
        if match(remove + #"(?:все титры|титры)|без титров"#) != nil { return Result(commands: [.removeTitles], target: nil) }
        if match(#"(?:приглуши|приглушить) (?:звук исходников|исходный звук)"#) != nil {
            return Result(commands: [.setOriginalAudioVolume(DirectorSourceAudioPolicy.duck.volume)], target: nil)
        }
        if match(remove + #"(?:звук исходников|исходный звук)"#) != nil {
            return Result(commands: [.setOriginalAudioVolume(0)], target: nil)
        }
        if match(#"(?:верни|включи) (?:звук исходников|исходный звук)"#) != nil {
            return Result(commands: [.setOriginalAudioVolume(1)], target: nil)
        }

        // Recognize one explicit media scope. Multiple targets, ranges and
        // exclusions are intentionally not collapsed to the first mentioned clip.
        let noun = #"(?:клип(?:а|е|у|ом)?|фрагмент(?:а|е|у|ом)?|момент(?:а|е|у|ом)?|план(?:а|е|у|ом)?|видео|ролик(?:а|е|у|ом)?)"#
        let ordinal = #"(?:перв(?:ый|ое|ого|ом|ому)|втор(?:ой|ое|ого|ом|ому)|трет(?:ий|ье|ьего|ьем|ьему)|четверт(?:ый|ое|ого|ом|ому)|пят(?:ый|ое|ого|ом|ому)|шест(?:ой|ое|ого|ом|ому)|седьм(?:ой|ое|ого|ом|ому)|восьм(?:ой|ое|ого|ом|ому)|девят(?:ый|ое|ого|ом|ому)|десят(?:ый|ое|ого|ом|ому)|последн(?:ий|ее|его|ем|ему))"#
        let selected = #"(?:(?:выбранн|выделенн)(?:ый|ое|ого|ом|ому)|эт(?:от|о|ого|ом|ому))"#
        let scopePattern = #"(?<![\p{L}\d])(?:(?:в|во|на|у|для|ко?|из|с|со)\s+)?(?:"#
            + "(?:" + ordinal + "|" + selected + #"|\d+\s*[-–]?\s*(?:й|ый|ой|ий|м|ом|му|го|е))\s+"# + noun
            + "|" + noun + #"\s*(?:номер\s*|№\s*)?\d+"#
            + #"|(?:все|всех|всем|каждый|каждом)\s+(?:клипы?|клипов|клипах|клипам|фрагменты?|фрагментов|фрагментах|фрагментам|видео|ролики|роликах)"#
            + #"|весь фильм|всего фильма|всем фильме|нем|него|здесь)(?![\p{L}\d])"#
        guard let scopeRegex = try? NSRegularExpression(pattern: scopePattern) else { return nil }
        // Quoted effect names (e.g. “Дрейф камеры”) must stay intact.
        let quotes = (try? NSRegularExpression(pattern: #"[«“\"][^»”\"]*[»”\"]"#))?
            .matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range) ?? []
        let scopes = scopeRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter { candidate in
            !quotes.contains { NSIntersectionRange($0, candidate.range).length > 0 }
        }
        guard scopes.count <= 1 else { return nil }
        var explicitTarget: EditorCommandTarget?
        if let scope = scopes.first, let range = Range(scope.range, in: text) {
            let phrase = String(text[range])
            if phrase.hasSuffix(" нем") || phrase.hasSuffix(" него") {
                // «Во втором клипе … у него …» refers to that clip; an
                // explicit «выбранный» in the next clause still means selection.
                explicitTarget = inheritedTarget ?? .selected
            } else if phrase.range(of: #"\b(?:выбранн|выделенн|эт)"#, options: .regularExpression) != nil || phrase == "здесь" {
                explicitTarget = .selected
            } else if phrase.contains("перв") { explicitTarget = .first }
            else if phrase.contains("последн") { explicitTarget = .last }
            else if phrase.contains("все") || phrase.contains("весь") || phrase.contains("всю") || phrase.contains("кажд") { explicitTarget = .all }
            else {
                let ordinals = ["втор", "трет", "четверт", "пят", "шест", "седьм", "восьм", "девят", "десят"]
                if let offset = ordinals.firstIndex(where: phrase.contains) { explicitTarget = .number(offset + 2) }
                else if let range = phrase.range(of: #"\d+"#, options: .regularExpression), let index = Int(phrase[range]), index > 0 {
                    explicitTarget = .number(index)
                } else { return nil }
            }
            text.replaceSubrange(range, with: " ")
            text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        let target = explicitTarget ?? inheritedTarget ?? .all
        guard target != .selected || hasSelection else { return nil }
        func result(_ command: EditorCommand) -> Result { Result(commands: [command], target: explicitTarget) }

        if let values = match(add + #"(?:эффект\s+)?(.+)"#), let effect = libraryEffect(named: values[0]) {
            return result(.addLibraryEffect(effect, target))
        }
        if match(remove + #"(?:все )?эффекты?|без эффектов"#) != nil { return result(.setEffect(nil, target)) }
        let motion: [(String, ClipEffect)] = [
            (#"(?:плавный )?наезд(?: камеры)?"#, .pushIn), (#"(?:плавный )?отъезд(?: камеры)?"#, .pullOut),
            (#"(?:плавное )?приближение|zoom[ -]in"#, .zoomIn), (#"(?:плавное )?отдаление|zoom[ -]out"#, .zoomOut),
            (#"панорама влево"#, .panLeft), (#"панорама вправо"#, .panRight)
        ]
        for (pattern, effect) in motion where match(add + "(?:" + pattern + ")") != nil {
            return result(.setEffect(effect, target))
        }
        if let values = match(#"(?:ускорь|ускорить|замедли|замедлить)\s+в\s+"# + decimal + #"\s*раз(?:а)?"#),
           let factor = number(values[0]), (1...8).contains(factor) {
            return result(.setSpeed(text.hasPrefix("замедл") ? 1 / factor : factor, target))
        }
        if let values = match(setting + #"скорость\s+"# + decimal + #"\s*[xх]?"#),
           let speed = number(values[0]), (0.125...8).contains(speed) { return result(.setSpeed(speed, target)) }
        if match(#"(?:верни|сделай) (?:обычную|нормальную) скорость"#) != nil { return result(.setSpeed(1, target)) }
        if match(remove + #"(?:замедление|слоумо|слоу-мо|slow motion)"#) != nil { return result(.removeSlowMotion(target)) }
        if let values = match(setting + #"длительность\s+"# + decimal + #"\s*(?:секунд[уы]?|сек\.?|с)"#),
           explicitTarget != nil, let seconds = number(values[0]), (0.25...3600).contains(seconds) {
            return result(.setDuration(seconds, target))
        }
        if match(remove + #"звук"#) != nil { return result(target == .all ? .setOriginalAudioVolume(0) : .setClipMuted(true, target)) }
        if match(#"(?:верни|включи|включить) звук"#) != nil { return result(target == .all ? .setOriginalAudioVolume(1) : .setClipMuted(false, target)) }
        if let values = match(setting + #"громкость(?: звука)?\s+(?:на\s+)?"# + decimal + #"\s*%"#),
           let value = number(values[0]), (0...200).contains(value) { return result(.setClipVolume(value / 100, target)) }
        if match(#"(?:отдели|отделить) звук"#) != nil { return result(.detachAudio(target)) }
        if match(#"(?:стабилизируй|стабилизировать)(?: видео)?|убери тряску"#) != nil { return result(.setStabilization(0.58, target)) }
        if match(remove + #"стабилизацию"#) != nil { return result(.setStabilization(0, target)) }
        if match(#"(?:поверни|повернуть) вправо(?: на 90(?: градусов)?)?"#) != nil { return result(.rotate(1, target)) }
        if match(#"(?:поверни|повернуть) влево(?: на 90(?: градусов)?)?"#) != nil { return result(.rotate(-1, target)) }
        if match(#"(?:отрази|отразить)(?: зеркально)?|сделай зеркально"#) != nil { return result(.setEffect(.mirror, target)) }
        if match(#"заполни кадр|обрежь по краям"#) != nil { return result(.setCrop(.fill, target)) }
        if match(#"покажи целиком|вмести в кадр"#) != nil { return result(.setCrop(.fit, target)) }
        if match(remove + #"фильтр|сбрось цвет|верни цвет"#) != nil { return result(.setFilter(.none, target)) }
        if match(#"сделай (?:черно-белым|черно-белое|монохромным)"#) != nil { return result(.setFilter(.monochrome, target)) }
        let filters: [(String, VideoFilter)] = [("черно-белый", .monochrome), ("монохром", .monochrome), ("нуар", .noir), ("сепия", .sepia), ("теплый", .warm), ("холодный", .cool), ("яркий", .vivid), ("драматичный", .dramatic)]
        for (name, filter) in filters where match(add + "(?:фильтр " + name + "|" + name + " фильтр)") != nil {
            return result(.setFilter(filter, target))
        }
        // Destructive operations require an explicit clip, never an empty scope.
        if explicitTarget != nil {
            if match(#"(?:удали|удалить|убери|убрать)"#) != nil { return result(.delete(target)) }
            if match(#"дублируй|дублировать|скопируй"#) != nil { return result(.duplicate(target)) }
            if match(#"разрежь|раздели"#) != nil { return result(.split(target)) }
            if match(#"(?:перемести|поставь) в начало"#) != nil { return result(.move(target, .beginning)) }
            if match(#"(?:перемести|поставь) в конец"#) != nil { return result(.move(target, .end)) }
        }
        return nil
    }

    static func libraryEffect(named input: String) -> TimelineEffectType? {
        let name = input.lowercased().replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: CharacterSet(charactersIn: " «»\"“”"))
        let aliases: [String: TimelineEffectType] = [
            "камеры": .videoCamera, "камера": .videoCamera, "видеокамеры": .videoCamera,
            "video camera": .videoCamera, "camera": .videoCamera, "rec": .videoCamera,
            "видоискатель": .videoCamera, "видоискателя": .videoCamera,
            "глитч": .glitch, "зум": .zoom, "дрожание камеры": .shake,
            "ручной камеры": .handheld, "дрейфа камеры": .cameraDrift,
            "рыбьего глаза": .fisheye, "пленочного зерна": .filmGrain
        ]
        return aliases[name] ?? TimelineEffectType.allCases.first {
            name == $0.rawValue || name == $0.localizedTitle.lowercased().replacingOccurrences(of: "ё", with: "е")
        }
    }
}
