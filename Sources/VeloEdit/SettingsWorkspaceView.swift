import SwiftUI
import AppKit
import VeloEditCore

struct SettingsWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Настройки").font(.largeTitle.bold())
                Spacer()
                Text("Версия \(model.currentAppVersion)").foregroundStyle(.secondary)
            }.padding([.horizontal, .top], 24).padding(.bottom, 16)
            Picker("Раздел настроек", selection: $model.settingsTab) {
                ForEach(WorkspaceSettingsTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 530).padding(.horizontal, 24).padding(.bottom, 18)
            Divider()
            switch model.settingsTab {
            case .storage: StorageSettingsView()
            case .keyboardShortcuts: KeyboardShortcutsSettingsView()
            case .general: GeneralSettingsView()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private func storageSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private struct StorageReview: Identifiable {
    enum Operation {
        case cache([URL: Set<ProjectCacheCategory>])
        case projects(trash: [URL], forget: [URL])
        case model(String)
        case forget(URL)
    }
    let id = UUID()
    let operation: Operation
    let title: String
    let details: [String]
    let removed: String
    let kept: String
    let action: String
}

private struct StorageSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var setup: DirectorModelSetup
    @State private var mode = "Кэш"
    @State private var search = ""
    @State private var largestFirst = true
    @State private var cacheSelection: [URL: Set<ProjectCacheCategory>] = [:]
    @State private var projectSelection = Set<URL>()
    @State private var review: StorageReview?
    @State private var result: String?

    private var projects: [ProjectStorageUsage] {
        model.storageProjects.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.url.path.localizedCaseInsensitiveContains(search) }
            .sorted { largestFirst ? $0.totalBytes > $1.totalBytes : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var selectedBytes: Int64 {
        model.storageProjects.reduce(0) { sum, item in
            if mode == "Проекты" { return sum + (projectSelection.contains(item.url) ? item.totalBytes : 0) }
            return sum + (cacheSelection[item.url] ?? []).reduce(0) { $0 + (item.cacheBytes[$1] ?? 0) }
        }
    }
    private var selectedCount: Int {
        mode == "Проекты" ? projectSelection.count : cacheSelection.values.filter { !$0.isEmpty }.count
    }
    private var busy: Bool {
        model.hasActiveWork || model.storageIsCleaning || model.downloadingAIPowerMode != nil || setup.phase == .downloading || setup.phase == .verifying
    }
    private var selectedProjectsArePending: Bool {
        mode == "Проекты" && model.storageProjects.contains { projectSelection.contains($0.url) && !$0.availabilityIsKnown }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    overview
                    if let result {
                        Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            .textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    projectControls
                    if model.storageIsLoading && model.storageProjects.isEmpty {
                        ProgressView("Считаем размер проектов…").padding(30).frame(maxWidth: .infinity)
                    } else if projects.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "Нет известных проектов" : "Ничего не найдено", systemImage: "folder", description: Text("Здесь появляются проекты, которые вы создавали или открывали в VeloEdit."))
                    }
                    ForEach(projects) { project in projectRow(project) }
                    modelList
                    Text("Размеры относятся к файлам внутри пакетов .veloedit. Внешние исходники не включены. Доступное место может отличаться из-за общих файлов, сжатия и снимков диска.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(24)
            }
            Divider()
            HStack(spacing: 12) {
                if model.storageIsCleaning { ProgressView().controlSize(.small); Text("Выполняем операцию…") }
                else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedCount == 0 ? "Выберите, что удалить" : "Выбрано проектов: \(selectedCount) · \(storageSize(selectedBytes))").font(.callout.weight(.semibold))
                        Text(mode == "Кэш" ? "Исходники, монтаж, анализ и экспорт сохранятся." : "Доступные проекты — в Корзину, недоступные — убрать из списка.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Снять выбор") { cacheSelection = [:]; projectSelection = [] }.disabled(selectedCount == 0)
                    Button(mode == "Кэш" ? "Очистить…" : "Удалить выбранные…", action: reviewSelection)
                        .buttonStyle(.borderedProminent).fixedSize().disabled(busy || selectedCount == 0 || selectedProjectsArePending)
                }
            }.padding(16).background(.bar)
        }
        .onAppear(perform: model.refreshStorageUsage)
        .onChange(of: model.storageProjects.map(\.url)) { _, urls in
            let remaining = Set(urls)
            projectSelection.formIntersection(remaining)
            cacheSelection = cacheSelection.filter { remaining.contains($0.key) }
        }
        .sheet(item: $review) { item in
            StorageConfirmationView(review: item) {
                review = nil
                Task { await perform(item.operation) }
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Хранилище", systemImage: "internaldrive").font(.title2.bold())
                Spacer()
                if model.storageIsLoading { ProgressView().controlSize(.small) }
                Button("Обновить", systemImage: "arrow.clockwise", action: model.refreshStorageUsage).disabled(model.storageIsLoading || model.storageIsCleaning)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 30) { statistics }
                VStack(alignment: .leading, spacing: 14) { statistics }
            }
            Text("Можно очистить отдельные категории, весь доступный кэш или удалить выбранные проекты. Сначала вы увидите состав удаления.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.storageIsLoading {
                Text("Размеры обновляются в фоне. Можно продолжать выбирать проекты; итоговый размер ещё уточняется.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.hasActiveWork || setup.phase == .downloading || setup.phase == .verifying {
                Label("Очистка станет доступна после завершения текущей работы и загрузок.", systemImage: "clock").font(.caption).foregroundStyle(.orange)
            }
        }.padding(18).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var statistics: some View {
        statistic("Проекты на диске", bytes: model.storageProjects.reduce(0) { $0 + $1.totalBytes })
        statistic("Можно очистить", bytes: model.storageProjects.reduce(0) { $0 + $1.reclaimableBytes })
        if let free = model.storageAvailableCapacity {
            statistic("Свободно на системном диске", bytes: free)
        }
    }
    private func statistic(_ title: String, bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(storageSize(bytes)).font(.title2.bold().monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var projectControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Проекты").font(.title3.bold())
                Spacer()
                Picker("Действие", selection: $mode) { Text("Кэш").tag("Кэш"); Text("Проекты целиком").tag("Проекты") }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240).disabled(model.storageIsCleaning)
            }
            HStack {
                TextField("Поиск по названию или пути", text: $search).textFieldStyle(.roundedBorder)
                Menu("Сортировка", systemImage: "arrow.up.arrow.down") {
                    Button("Сначала большие") { largestFirst = true }
                    Button("По названию") { largestFirst = false }
                }
                Button("Выбрать показанные") {
                    for project in projects {
                        if mode == "Проекты" { projectSelection.insert(project.url) }
                        else if !project.unavailable { cacheSelection[project.url] = Set(ProjectCacheCategory.allCases.filter { (project.cacheBytes[$0] ?? 0) > 0 }) }
                    }
                }
            }
        }
    }

    private func projectRow(_ project: ProjectStorageUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                if mode == "Проекты" {
                    Toggle("Выбрать \(project.name)", isOn: Binding(get: { projectSelection.contains(project.url) }, set: { selected in
                        if selected { projectSelection.insert(project.url) } else { projectSelection.remove(project.url) }
                    })).labelsHidden().toggleStyle(.checkbox)
                }
                Image(systemName: project.unavailable ? "externaldrive.badge.exclamationmark" : "film.stack").foregroundStyle(project.unavailable ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(project.name).font(.headline).textSelection(.enabled)
                        if model.projectURL?.standardizedFileURL == project.url.standardizedFileURL { Text("Открыт").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(project.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                Text(project.isCalculating ? "Считаем…" : project.unavailable ? "Недоступен" : storageSize(project.totalBytes)).font(.callout.monospacedDigit())
                Menu {
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }.disabled(project.unavailable)
                    if project.unavailable {
                        Button("Убрать из списка…") {
                            review = StorageReview(operation: .forget(project.url), title: "Убрать проект из списка?", details: [project.name, project.url.path], removed: "Только запись в библиотеке и недавних проектах VeloEdit.", kept: "Файлы на диске не изменятся. Проект можно открыть снова через меню «Файл».", action: "Убрать из списка")
                        }
                    } else {
                        Button("Переместить в Корзину…", role: .destructive) { reviewProjects([project]) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().disabled(busy || !project.availabilityIsKnown)
            }
            if project.unavailable {
                Text("Подключите диск и обновите список, чтобы удалить файлы. В режиме «Проекты целиком» можно выделить этот проект и убрать запись вместе с другими. Недоступные данные не учитываются в размере.").font(.caption).foregroundStyle(.secondary)
            } else if mode == "Кэш" {
                Divider()
                ForEach(ProjectCacheCategory.allCases) { category in
                    HStack(alignment: .top) {
                        Toggle(isOn: Binding(get: { cacheSelection[project.url]?.contains(category) == true }, set: { selected in
                            if selected { cacheSelection[project.url, default: []].insert(category) }
                            else { cacheSelection[project.url]?.remove(category) }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title)
                                Text(description(category)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox).disabled((project.cacheBytes[category] ?? 0) == 0)
                        Spacer()
                        Text(storageSize(project.cacheBytes[category] ?? 0)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Text("Сохранятся: исходники, музыка, телеметрия, монтаж, результаты анализа, история правок и готовые видео. Используемые как исходники файлы кэша защищены.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Весь пакет: монтаж, анализ, история, кэш и вложенные файлы. Вложенные материалы: \(storageSize(project.embeddedMediaBytes)). Внешние исходники и видео за пределами пакета сохранятся.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
    private func description(_ category: ProjectCacheCategory) -> String {
        switch category {
        case .proxies: return "Облегчённые копии видео. Просмотр может стать медленнее до их повторного создания."
        case .previews: return "Временные видео и кадры. Следующий просмотр или анализ может занять больше времени."
        case .thumbnails: return "Изображения в медиатеке и на шкале. Создадутся заново при открытии."
        case .analysis: return "Промежуточные вычисления. Готовый анализ в проекте сохраняется; повторные AI-задачи могут занять дольше."
        }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Локальные AI-модели", systemImage: "cpu").font(.title3.bold())
                if model.storageModelsIsLoading { ProgressView().controlSize(.small) }
            }
            Text(model.storageModelsMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(model.storageModels, id: \.name) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.callout.weight(.medium)).textSelection(.enabled)
                        Text(item.name == LocalDirectorAgent.ollamaModel ? "ИИ-режиссёр" : "Модель Ollama").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(item.size.map(storageSize) ?? "Размер неизвестен").foregroundStyle(.secondary)
                    Button("Удалить…", role: .destructive) {
                        review = StorageReview(operation: .model(item.name), title: "Удалить модель?", details: [item.name, "Размер модели: \(item.size.map(storageSize) ?? "неизвестен")"], removed: "Выбранная модель из Ollama. Общие слои, нужные другим моделям, останутся, поэтому освободиться может меньше места. Это повлияет и на другие приложения, использующие эту модель.", kept: "Проекты, исходники, готовые фильмы и результаты анализа сохранятся. Для новых AI-задач эту модель потребуется скачать заново.", action: "Удалить модель")
                    }.disabled(busy || model.storageModelsIsLoading)
                }.padding(.vertical, 5)
            }
            if !setup.isInstalled {
                Button("Подготовить ИИ-режиссёра", action: setup.retry).disabled(busy)
            }
            Text("Модели удаляются через Ollama. Встроенные компоненты приложения и модели распознавания речи не входят в этот список.").font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func reviewSelection() {
        let selected = model.storageProjects.filter { mode == "Проекты" ? projectSelection.contains($0.url) : !(cacheSelection[$0.url] ?? []).isEmpty }
        if mode == "Проекты" { reviewProjects(selected); return }
        let selection = cacheSelection.filter { !$0.value.isEmpty }
        review = StorageReview(operation: .cache(selection), title: "Очистить выбранный кэш?", details: selected.map { item in
            "\(item.name) — \(ProjectCacheCategory.allCases.filter { selection[item.url]?.contains($0) == true }.map(\.title).joined(separator: ", "))"
        } + ["Будет освобождено примерно \(storageSize(selectedBytes))."], removed: "Только выбранные временные файлы. Кэш удаляется без Корзины и создаётся заново по мере необходимости.", kept: "Исходники, музыка, телеметрия, монтаж, анализ, история правок и экспорт. Файлы, на которые ссылается проект, не удаляются. Первый просмотр после очистки может быть медленнее.", action: "Очистить кэш")
    }
    private func reviewProjects(_ selected: [ProjectStorageUsage]) {
        let available = selected.filter { !$0.unavailable }
        let unavailable = selected.filter(\.unavailable)
        var removed: [String] = []
        if !available.isEmpty {
            let size = available.contains(where: \.isCalculating) ? "ещё подсчитывается" : storageSize(available.reduce(0) { $0 + $1.totalBytes })
            removed.append("В Корзину: \(available.count) пакетов целиком, включая монтаж, историю, анализ, кэш и вложенные файлы. Размер пакетов: \(size).")
        }
        if !unavailable.isEmpty {
            removed.append("Из списка: \(unavailable.count) записей недоступных проектов. Их файлы на дисках не изменятся; после подключения диска проекты можно открыть снова.")
        }
        review = StorageReview(operation: .projects(trash: available.map(\.url), forget: unavailable.map(\.url)),
            title: available.isEmpty ? "Убрать выбранные проекты из списка?" : "Удалить выбранные проекты?",
            details: selected.map { "\($0.name) · \($0.unavailable ? "убрать из списка" : "в Корзину · " + ($0.isCalculating ? "размер подсчитывается" : storageSize($0.totalBytes)))\n\($0.url.path)" },
            removed: removed.joined(separator: "\n\n") + " Открытый выбранный проект будет закрыт.",
            kept: "Внешние исходники и экспорт, другие проекты и AI-модели сохранятся. Пакеты можно восстановить из Корзины через Finder. Место освободится после очистки Корзины. Перед перемещением проверяются ссылки из других известных проектов.",
            action: available.isEmpty ? "Убрать из списка" : "Удалить выбранные")
    }
    private func perform(_ operation: StorageReview.Operation) async {
        guard !busy else { return }
        result = nil
        switch operation {
        case .cache(let selection):
            for (url, categories) in selection { cacheSelection[url]?.subtract(categories) }
            result = await model.clearSelectedProjectCaches(selection)
        case .projects(let urls, let unavailable):
            projectSelection.subtract(urls + unavailable)
            result = await model.trashStoredProjects(urls, forgetting: unavailable)
        case .model(let name):
            if await model.removeStoredModel(name) {
                if name == LocalDirectorAgent.ollamaModel { setup.modelWasRemoved() }
                result = "Модель \(name) удалена."
            }
        case .forget(let url):
            projectSelection.remove(url)
            model.forgetStoredProject(url); result = "Запись убрана из списка. Файлы не изменены."
        }
    }
}

private struct StorageConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    let review: StorageReview
    let confirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(review.title, systemImage: "externaldrive.badge.minus").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(review.details.enumerated()), id: \.offset) { _, detail in Text(detail).textSelection(.enabled) }
                    Divider()
                    Text("Что удалится").font(.headline)
                    Text(review.removed)
                    Text("Что сохранится").font(.headline)
                    Text(review.kept).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction); Button(review.action, role: .destructive, action: confirm).buttonStyle(.borderedProminent).tint(.red) }
        }.padding(24).frame(width: 580, height: 510)
    }
}

private struct KeyboardShortcutsSettingsView: View {
    private let groups: [(String, [(String, String)])] = [
        ("Проекты и разделы", [("Новый проект", "⌘ N"), ("Открыть проект", "⌘ O"), ("Импортировать материалы", "⌘ I"), ("Настройки", "⌘ ,"), ("Показать / скрыть боковую панель", "⌘ 0"), ("Перейти к разделу", "⌘ 1 … 6")]),
        ("Монтаж · когда активна монтажная шкала", [("Воспроизведение / пауза", "Пробел"), ("На кадр назад / вперёд", "← / →"), ("На секунду назад / вперёд", "⇧ ← / ⇧ →"), ("К началу / концу", "⌘ ← / ⌘ →"), ("Копировать / вырезать / вставить", "⌘ C / ⌘ X / ⌘ V"), ("Дублировать", "⌘ D"), ("Выделить всё", "⌘ A"), ("Удалить выделенное", "⌫"), ("Отменить / повторить правку", "⌘ Z / ⇧ ⌘ Z")]),
        ("Фильм", [("Создать фильм", "⌘ ↩"), ("Открыть просмотр", "⇧ ⌘ P"), ("Открыть экспорт", "⌘ E"), ("Сохранить видео · в разделе экспорта", "⇧ ⌘ S"), ("Развернуть проигрыватель · в монтаже", "F"), ("Остановить операцию / закрыть просмотр", "Esc")])
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Сочетания работают в соответствующем разделе. При вводе текста используются обычные команды редактирования.").foregroundStyle(.secondary)
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(group.0).font(.headline)
                        ForEach(group.1, id: \.0) { item in
                            HStack { Text(item.0); Spacer(); Text(item.1).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                        }
                    }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(24)
        }
    }
}

struct MissingMediaView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Найти исходники", systemImage: "externaldrive.badge.exclamationmark").font(.title2.bold())
            Text("Монтаж и результаты анализа сохранены. Подключите прежний диск или выберите оригиналы в новом расположении. Файлы проверяются по содержимому, чтобы не подменить кадры.").foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.missingMediaAssets) { asset in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(asset.displayName).font(.headline)
                                Text(asset.originalURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Указать файл…") { model.locateMissingMedia(asset.id) }.disabled(model.hasActiveWork)
                        }
                        Divider()
                    }
                }
            }
            HStack {
                Button("Найти в папке…") { model.locateMissingMedia() }.disabled(model.hasActiveWork)
                Button("Проверить снова") { Task { await model.refresh(); if model.missingMediaAssets.isEmpty { dismiss() } } }.disabled(model.hasActiveWork)
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 680, height: 460)
    }
}
