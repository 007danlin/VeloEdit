import Foundation

extension TitleTemplateRegistry {
    public static var openingTemplates: [TitleTemplateDefinition] {
        all.filter { $0.supportsFilmOpening }
    }

    static func expandedTemplates(_ originals: [TitleTemplateDefinition]) -> [TitleTemplateDefinition] {
        var compact = originals.first { $0.id == "title.minimal-clean.v1" }!
        compact.layoutOrigin = compact.defaultStyle
        compact.styleOverride = EditorialPresentationPolicy.compactChapterStyle
        compact.id = "title.chapter-compact.v1"
        compact.name = "Глава компактная"
        compact.category = .chapterTitles
        compact.kind = .chapter
        compact.preview = .init(primaryText: "Дорога домой")
        compact.duration = 5
        compact.defaultAnimation = .init(entrance: .none, exit: .none, duration: 0)
        compact.layout.elements.removeAll { $0.content == .secondaryText }
        // The chapter style moves the group left and down relative to the
        // opening layout. Keep its landscape text inside the safe margin,
        // including the first glyph's overhang and readability outline.
        // Portrait retains its separately authored placement.
        for index in compact.layout.elements.indices {
            compact.layout.elements[index].frame.x += 0.03
            if compact.layout.elements[index].id == "primary" {
                compact.layout.elements[index].portraitFrame = .init(x: 0.20, y: 0.32, width: 0.74, height: 0.22)
            } else if compact.layout.elements[index].id == "hairline" {
                compact.layout.elements[index].portraitFrame = .init(x: 0.28, y: 0.58, width: 0.44, height: 0.004)
            }
        }

        let type = TitleTemplateTypography(fontFamily: "Georgia", fontSize: 100,
            fontWeight: 0.4, textColorHex: "#FFF9F0", tracking: 2, lineSpacing: 1.12, alignment: .center)
        let sub = TitleTemplateTypography(fontFamily: "Avenir Next", fontSize: 32,
            fontWeight: 0.55, textColorHex: "#FFF9F0", tracking: 2, lineSpacing: 1.1, alignment: .center)
        let clean = TitleTemplateDefinition(id: "title.cinematic-clean.v1", name: "Кино без рамки",
            category: .cinematicTitles, kind: .cinematicTitle,
            preview: .init(primaryText: "За городом", secondaryText: "Один день в дороге"), duration: 5.2,
            typography: type,
            layout: .init(elements: [
                .init(id: "primary", kind: .text, content: .primaryText, frame: .init(x: 0.08, y: 0.33, width: 0.84, height: 0.26),
                      fillColorHex: "#FFF9F0", typography: type),
                .init(id: "secondary", kind: .text, content: .secondaryText, frame: .init(x: 0.14, y: 0.63, width: 0.72, height: 0.12),
                      fillColorHex: "#FFF9F0", typography: sub)
            ]),
            animation: .init(animationIn: .init(duration: 0.75), animationOut: .init(duration: 0.6)),
            textConstraints: .init(maxCharacters: 80, maxLines: 2, maxWidth: 0.84, maxHeight: 0.28, minFontScale: 0.4))
        return originals + [clean, compact]
    }
}

public extension TitleTemplateDefinition {
    var supportsFilmOpening: Bool {
        ["title.minimal-clean.v1", "title.cinematic-clean.v1", "title.cinematic.v1", "title.elegant.v1",
         "title.dynamic.v1", "title.modern.v1", "title.bold.v1", "title.travel.v1"].contains(id)
    }

    func matchesSearch(_ query: String) -> Bool {
        let aliases: [String: String] = [
            "title.minimal-clean.v1": "минималистичный чистый спокойный",
            "title.cinematic-clean.v1": "cinematic clean кино без рамки",
            "title.chapter-compact.v1": "compact chapter глава компактная",
            "title.cinematic.v1": "кино кинематографичный",
            "title.elegant.v1": "элегантный семейный",
            "title.dynamic.v1": "динамический спорт",
            "title.modern.v1": "современный", "title.bold.v1": "жирный яркий",
            "title.travel.v1": "путешествие маршрут", "title.chapter.v1": "глава часть",
            "title.location.v1": "место локация", "title.date.v1": "дата время",
            "title.lower-third.v1": "нижняя треть имя", "title.end-card.v1": "финал конец"
        ]
        return query.isEmpty || (name + " " + id + " " + (aliases[id] ?? ""))
            .localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
