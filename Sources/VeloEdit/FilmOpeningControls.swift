import SwiftUI
import VeloEditCore

struct FilmOpeningControls: View {
    @EnvironmentObject var model: AppModel
    @State private var settings = FilmOpeningSettings()

    var body: some View {
        DisclosureGroup("Название фильма в начале") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Режим", selection: $settings.policy) {
                    ForEach(FilmOpeningPolicy.allCases) { Text($0.localizedTitle).tag($0) }
                }
                if settings.policy != .off {
                    TextField("Название по содержанию фильма", text: $settings.title, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    TextField("Подзаголовок — необязательно", text: $settings.subtitle, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    if settings.policy == .selected {
                        Picker("Оформление", selection: Binding(get: { settings.templateID ?? "title.cinematic-clean.v1" }, set: { settings.templateID = $0 })) {
                            ForEach(TitleTemplateRegistry.openingTemplates) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                HStack {
                    Button("Применить") {
                        if settings.policy == .selected && settings.templateID == nil { settings.templateID = "title.cinematic-clean.v1" }
                        model.applyFilmOpeningSettings(settings)
                    }.disabled(model.isTimelineInteractionBlocked)
                    if model.timeline?.effectiveTitleItems.contains(where: { $0.semanticRole == .filmOpening }) == true {
                        Button("Посмотреть начало") { model.previewFilmOpening() }
                    }
                }
                if let opening = model.timeline?.effectiveTitleItems.first(where: { $0.semanticRole == .filmOpening }) {
                    Text("\(opening.text) · \(TitleTemplateRegistry.template(for: opening)?.name ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let warning = model.timeline?.openingTitleDecision?.warning {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }.padding(.top, 6)
        }
        .onAppear { sync() }
        .onChange(of: model.timeline?.openingTitles) { _, _ in sync() }
    }

    private func sync() {
        settings = model.timeline?.openingTitles ?? model.directorBrief.openingTitles
            ?? FilmOpeningSettings(policy: model.timeline == nil ? .automatic : .off)
    }
}
