import SwiftUI
import VeloEditCore

struct ExportWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var preset: VideoPreset = .maximum
    @State private var customQuality: RenderQuality = .final4K
    @State private var customFrameRate: Double = 30
    @State private var showsTechnicalDetails = false
    @State private var showsExportHistory = false

    private enum VideoPreset: Hashable {
        case maximum, fullHD, custom
    }

    private var quality: RenderQuality {
        switch preset {
        case .maximum: return .maximum
        case .fullHD: return .final1080p
        case .custom: return customQuality
        }
    }

    private var frameRate: Double {
        switch preset {
        case .maximum: return model.maximumSourceFrameRate
        case .fullHD: return model.timeline?.frameRate ?? 30
        case .custom: return customFrameRate
        }
    }

    private var videoSettings: ExportVideoSettings? {
        guard let timeline = model.timeline else { return nil }
        let resolved = ExportSettingsPolicy.timeline(timeline, assets: model.project?.assets ?? [],
                                                    quality: quality, frameRate: frameRate)
        return ExportVideoSettings(timeline: resolved, quality: quality)
    }

    private var exportUnavailable: Bool { model.timeline == nil || model.isWorking }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                videoCard
                if !model.completedVideoExports.isEmpty { completedExports }
                otherFormats
            }
            .frame(maxWidth: 820)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { customFrameRate = model.maximumSourceFrameRate }
        .onChange(of: model.project?.id) { _, _ in
            preset = .maximum
            customQuality = .final4K
            customFrameRate = model.maximumSourceFrameRate
            showsExportHistory = false
        }
        .onChange(of: model.exportFrameRateOptions) { _, options in
            if !options.contains(customFrameRate) {
                customFrameRate = model.maximumSourceFrameRate
            }
        }
        .onChange(of: model.completedVideoExports.first?.id) { previous, current in
            if let current, current != previous { showsExportHistory = true }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Экспорт").font(.title.bold())
                Text("Сохраните фильм или продолжите работу в другом редакторе.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Собрать копию проекта", systemImage: "shippingbox", action: model.collectProjectCopy)
                Button("Показать проект в Finder", systemImage: "folder", action: model.revealProject)
                Divider()
                Button("Экспортировать диагностику…", systemImage: "doc.text", action: model.exportDiagnostics)
            } label: {
                Label("Проект", systemImage: "ellipsis.circle")
            }
            .fixedSize()
            .disabled(model.isWorking)
        }
    }

    private var videoCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Видео", systemImage: "film")
                    .font(.headline)
                Spacer()
                Button("Предпросмотр", systemImage: "play", action: model.renderPreview)
                    .help("Посмотреть монтаж без сохранения файла")
                    .disabled(exportUnavailable)
            }

            VStack(alignment: .leading, spacing: 16) {
                settingsRow("Качество") {
                    Picker("Качество видео", selection: $preset) {
                        Text("Максимальное").tag(VideoPreset.maximum)
                        Text("Full HD · 1080p").tag(VideoPreset.fullHD)
                        Text("Вручную").tag(VideoPreset.custom)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if preset == .custom {
                    settingsRow("Разрешение") {
                        Picker("Разрешение видео", selection: $customQuality) {
                            Text("720p — компактный файл").tag(RenderQuality.preview720p)
                            Text("1080p — Full HD").tag(RenderQuality.final1080p)
                            Text("2160p — 4K UHD").tag(RenderQuality.final4K)
                            Text("Максимум по исходникам").tag(RenderQuality.maximum)
                        }
                        .labelsHidden()
                    }
                    settingsRow("Частота кадров") {
                        Picker("Частота кадров", selection: $customFrameRate) {
                            ForEach(model.exportFrameRateOptions, id: \.self) { value in
                                Text("\(ExportVideoSettings.frameRateLabel(value)) кадров/с").tag(value)
                            }
                        }
                        .labelsHidden()
                    }
                }

                settingsRow("Сохранить в") {
                    HStack(spacing: 12) {
                        Text(model.videoExportDirectoryURL?.path ?? "Выберите папку для видео")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(model.videoExportDirectoryURL?.path ?? "Место сохранения видео")
                        Button("Обзор…", action: model.chooseVideoExportDirectory)
                            .accessibilityLabel("Выбрать папку для видео")
                    }
                }
            }
            .disabled(exportUnavailable)

            Divider()

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    if let settings = videoSettings {
                        HStack(spacing: 6) {
                            Text("MP4 · \(settings.width) × \(settings.height) · \(ExportVideoSettings.frameRateLabel(settings.frameRate)) кадров/с")
                                .font(.callout.monospacedDigit())
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Параметры видео", systemImage: "info.circle") {
                                showsTechnicalDetails.toggle()
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Кодек, битрейт и цветовой профиль")
                            .popover(isPresented: $showsTechnicalDetails) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Параметры видео").font(.headline)
                                    Text(settings.summary)
                                    Text("Пропорции монтажа сохраняются. Битрейт переменный и зависит от сложности кадров. MP4 сжимается с потерями; HDR преобразуется в SDR.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(18)
                                .frame(width: 340)
                            }
                        }
                        Text("Отдельный MP4. При сохранении можно выбрать имя файла и изменить папку.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Сначала создайте монтаж, чтобы сохранить видео.")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button("Сохранить видео", systemImage: "square.and.arrow.down", action: saveVideo)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .fixedSize()
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(exportUnavailable)
            }
        }
        .padding(22)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.06))
        }
    }

    private var otherFormats: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Другие форматы")
                .font(.headline)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                formatRow("Субтитры", subtitle: "Текст и таймкоды отдельным файлом", icon: "captions.bubble") {
                    Menu("Сохранить…") {
                        Button("SRT — универсальный формат") { model.exportSubtitles(.srt) }
                        Button("WebVTT — для веб-плееров") { model.exportSubtitles(.vtt) }
                    }
                    .accessibilityLabel("Сохранить субтитры")
                    .fixedSize()
                }
                Divider().padding(.leading, 54)
                formatRow("Прозрачная телеметрия", subtitle: "Виджеты без фона · MOV, ProRes 4444", icon: "circle.dotted.circle") {
                    Button("Сохранить…", action: model.exportTelemetryOverlay)
                        .accessibilityLabel("Сохранить прозрачную телеметрию")
                }
                Divider().padding(.leading, 54)
                formatRow("Final Cut Pro", subtitle: "Редактируемый монтаж · FCPXML", icon: "timeline.selection") {
                    Button("Сохранить…") { model.exportFCPXML(mode: .edit) }
                        .accessibilityLabel("Сохранить монтаж для Final Cut Pro")
                }
            }
            .disabled(exportUnavailable)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var completedExports: some View {
        DisclosureGroup(isExpanded: $showsExportHistory) {
            VStack(spacing: 0) {
                ForEach(model.completedVideoExports) { job in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.outputURL.lastPathComponent)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(job.outputURL.path)
                            Text(job.videoSummary ?? "Проверенное видео")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Версия монтажа: \(job.timelineID.uuidString.prefix(8))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        if let package = model.projectURL,
                           ProjectVideoFiles.isInsideProject(job.outputURL, package: package) {
                            Button("Сохранить рядом") { model.copyExportNextToProject(job) }
                                .help("Скопировать готовое видео из проекта без повторного экспорта")
                                .disabled(model.isWorking)
                        }
                        Button("Открыть", systemImage: "play") { model.openExportedVideo(job) }
                        Button("В Finder", systemImage: "folder") { model.revealExportedVideo(job) }
                    }
                    .padding(.vertical, 10)
                }
            }
        } label: {
            Label("Сохранённые видео · \(model.completedVideoExports.count)", systemImage: "checkmark.circle")
                .font(.callout.weight(.medium))
        }
    }

    private func settingsRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatRow<Action: View>(_ title: String, subtitle: String, icon: String,
                                         @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            action().fixedSize()
        }
        .padding(16)
    }

    private func saveVideo() {
        model.exportWithSettings(quality: quality, frameRate: frameRate)
    }
}
