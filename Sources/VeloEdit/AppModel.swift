import Foundation
import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import VeloEditCore

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case home
    case media
    case director
    case timeline
    case export

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Главная"
        case .media: return "Медиатека"
        case .director: return "Умный режиссёр"
        case .timeline: return "Монтаж"
        case .export: return "Экспорт"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"
        case .media: return "photo.on.rectangle.angled"
        case .director: return "wand.and.stars"
        case .timeline: return "timeline.selection"
        case .export: return "square.and.arrow.up"
        }
    }
}

enum DirectorMessageRole: Sendable {
    case user
    case assistant
}

struct DirectorMessage: Identifiable, Sendable {
    let id: UUID
    let role: DirectorMessageRole
    var text: String
    let createdAt: Date

    init(id: UUID = UUID(), role: DirectorMessageRole, text: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }

    static var initial: [DirectorMessage] {
        [DirectorMessage(
            role: .assistant,
            text: "Расскажите, каким должен быть фильм. Я отвечу, перескажу замысел и сохраню пожелания, пока VeloEdit импортирует или анализирует исходники."
        )]
    }
}

enum ActivityPresentation {
    case standard
    case editorAI
    case silentEditor
}

private extension DirectorMessage {
    init(projectMessage: ProjectDirectorMessage) {
        self.init(
            id: projectMessage.id,
            role: projectMessage.role == .user ? .user : .assistant,
            text: projectMessage.text,
            createdAt: projectMessage.createdAt
        )
    }
}

private extension ProjectDirectorMessage {
    init(directorMessage: DirectorMessage) {
        self.init(
            id: directorMessage.id,
            role: directorMessage.role == .user ? .user : .assistant,
            text: directorMessage.text,
            createdAt: directorMessage.createdAt
        )
    }
}

private enum TimelineSelectionKey: Hashable {
    case item(UUID)
    case audio(UUID)
    case telemetry(UUID)
    case effect(UUID)
    case title(UUID)
    case transition(UUID)
    case soundtrack
}

private struct TimelineClipboard {
    var items: [TimelineItem]
    var audioClips: [TimelineAudioClip]
    var telemetryItems: [TimelineTelemetryItem]
    var effects: [EffectTimelineItem]
    var titles: [TitleTimelineItem]
    var transitions: [TimelineTransitionItem]
    var soundtrack: MusicDirective?

    var isEmpty: Bool {
        items.isEmpty && audioClips.isEmpty && telemetryItems.isEmpty && effects.isEmpty &&
        titles.isEmpty && transitions.isEmpty && soundtrack == nil
    }

    var referenceTime: Double {
        let starts = items.map(\.timelineStart) + audioClips.map(\.timelineStart) +
            telemetryItems.map(\.timelineStart) + effects.map(\.startTime) +
            titles.map(\.startTime) + transitions.map(\.startTime)
        return starts.min() ?? 0
    }
}

@MainActor
final class AppModel: ObservableObject {
    private struct PendingTimelineAIEdit {
        let instruction: String
        let range: ClosedRange<Double>?
    }

    private static let recentProjectsKey = "recentProjectPaths.v1"
    private static let freeToUseLicenseAcceptedKey = "freeToUseLicenseAccepted.v1"
    private static let defaultDirectorBrief = "Сделай связный фильм из лучших моментов. Начни спокойно, затем добавь динамики и закончи красивым финалом."
    @Published var project: ProjectManifest?
    @Published var projectURL: URL?
    @Published var selectedAssetID: UUID?
    @Published var selectedMusicTrackID: UUID?
    @Published var selectedTimelineItemID: UUID?
    @Published var selectedTimelineAudioClipID: UUID?
    @Published var selectedTelemetryItemID: UUID?
    @Published var selectedEffectTimelineItemID: UUID?
    @Published var selectedTitleTimelineItemID: UUID?
    @Published var selectedTransitionTimelineItemID: UUID?
    @Published private(set) var selectedTimelineItemIDs: Set<UUID> = []
    @Published private(set) var selectedTimelineAudioClipIDs: Set<UUID> = []
    @Published private(set) var selectedTelemetryItemIDs: Set<UUID> = []
    @Published private(set) var selectedEffectTimelineItemIDs: Set<UUID> = []
    @Published private(set) var selectedTitleTimelineItemIDs: Set<UUID> = []
    @Published private(set) var selectedTransitionTimelineItemIDs: Set<UUID> = []
    @Published var selectedSoundtrack = false
    @Published private(set) var timelinePlayheadTime: Double = 0
    @Published var section: WorkspaceSection = .home
    @Published var prompt = AppModel.defaultDirectorBrief { didSet { scheduleWorkspaceAutosave() } }
    @Published var directorInput = "" { didSet { scheduleWorkspaceAutosave() } }
    @Published var directorMessages = DirectorMessage.initial { didSet { scheduleWorkspaceAutosave() } }
    @Published var directorStatus = "Готов выслушать ваш замысел"
    @Published var directorRuntimeStatus = LocalDirectorAgent.currentRuntimeLabel()
    @Published var aiPowerMode: AIPowerMode = .fast
    @Published var advancedAISettings = AdvancedAISettings()
    @Published var aiVisionModelStatus = "Проверяю локальную vision-модель…"
    @Published var aiVisionModelInstalled = false
    @Published var isDownloadingAIModel = false
    @Published var aiModelDownloadProgress = 0.0
    @Published private(set) var aiModelAvailability: [AIPowerMode: Bool] = [:]
    @Published private(set) var downloadingAIPowerMode: AIPowerMode?
    @Published var isDirectorResponding = false
    @Published var isCreatingFilm = false
    @Published var feedback = "" { didSet { scheduleWorkspaceAutosave() } }
    @Published var preset: FilmPreset = .adventure { didSet { scheduleWorkspaceAutosave() } }
    @Published var targetMinutes = 2.0 { didSet { scheduleWorkspaceAutosave() } }
    @Published private(set) var directorMusicTrackID: UUID? { didSet { scheduleWorkspaceAutosave() } }
    @Published var status = "Создайте или откройте проект"
    @Published var progress = 0.0
    @Published var activityTitle = ""
    @Published var activityCompleted = 0
    @Published var activityTotal = 0
    @Published var activityProgressLabel = ""
    @Published var activityFileName = ""
    @Published var activityTimeRemaining = ""
    @Published var isWorking = false
    @Published private(set) var queuedTimelineAIEditCount = 0
    @Published private(set) var activityPresentation: ActivityPresentation = .standard
    @Published private(set) var isActivityPanelVisible = false
    @Published private(set) var isActivityComplete = false
    @Published var isDropTarget = false
    @Published var previewURL: URL?
    @Published var previewPlayer: AVPlayer?
    @Published private(set) var previewPosterImage: NSImage?
    @Published private(set) var isPreviewPosterVisible = false
    @Published var showViewer = false
    @Published var isTimelineInspectorPresented = false
    @Published var isShowingManualExportSettings = false
    @Published var thumbnailURLs: [UUID: URL] = [:]
    @Published var timelineThumbnailURLs: [UUID: URL] = [:]
    @Published private(set) var musicTracks: [LocalMusicTrack] = []
    @Published private(set) var musicLibraryStatus = MusicLibraryStatus()
    @Published var errorMessage: String?
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isImporting = false
    @Published private(set) var hasPendingFilmChanges = false { didSet { scheduleWorkspaceAutosave() } }
    @Published private(set) var recentProjectURLs: [URL] = []
    @Published private(set) var canUndoTimelineEdit = false
    @Published private(set) var canRedoTimelineEdit = false
    var pipeline: VeloEditPipeline?
    private var activePlayback: TimelinePlayback?
    private var playbackTimeObserver: Any?
    private var playbackItemStatusObservation: NSKeyValueObservation?
    private var previewPosterTask: Task<Void, Never>?
    /// While a rebuilt composition is seeking back to the edited frame, keep
    /// the timeline playhead pinned there instead of briefly accepting the new
    /// AVPlayerItem's initial zero time.
    private var pendingPlaybackSeekTimelineTime: Double?
    private var activeTask: Task<Void, Never>?
    private var pendingTimelineAIEdits: [PendingTimelineAIEdit] = []
    private var activityDismissTask: Task<Void, Never>?
    private var projectRestoreTask: Task<Void, Never>?
    private var directorTask: Task<Void, Never>?
    private var workspaceAutosaveTask: Task<Void, Never>?
    private var timelineCommitTask: Task<Void, Never>?
    private var previewRebuildTask: Task<Void, Never>?
    private var timelineEditRevision: UInt64 = 0
    private let interactionLatencyRecorder = InteractionLatencyRecorder()
    private var isRestoringWorkspaceState = false
    private var directorRevision = 0
    private var pendingDirectorInstructions: [String] = []
    private var undoTimelineHistory: [Timeline] = []
    private var redoTimelineHistory: [Timeline] = []
    private var pendingDirectorCommandGroups: [[EditorCommand]] = []
    private var copiedTimelineItemSettings: TimelineItem?
    private var copiedTelemetrySettings: TelemetryOverlaySettings?
    private var copiedEffectTimelineItem: EffectTimelineItem?
    private var copiedEffectKeyframe: EffectKeyframe?
    private var timelineClipboard: TimelineClipboard?
    private var timelineSelectionAnchor: TimelineSelectionKey?
    private let directorAgent = LocalDirectorAgent()

    var timeline: Timeline? { project?.timelines.last }
    var selectedAsset: MediaAsset? { project?.assets.first { $0.id == selectedAssetID } }
    var selectedMusicTrack: LocalMusicTrack? { musicTracks.first { $0.id == selectedMusicTrackID } }
    var userMusicTracks: [LocalMusicTrack] {
        musicTracks.filter { $0.sourceProvider == .user }
    }
    var bundledMusicTracks: [LocalMusicTrack] {
        musicTracks.filter { $0.sourceProvider == .bundled }
    }
    var cachedOnlineMusicTracks: [LocalMusicTrack] {
        musicTracks.filter { $0.sourceProvider.isOnline }
    }
    var directorMusicTrack: LocalMusicTrack? {
        userMusicTracks.first { $0.id == directorMusicTrackID }
    }
    var directorMusicSelectionTitle: String {
        directorMusicTrack.map { "Мой трек: \($0.title)" } ?? "Музыка: автоподбор"
    }
    var selectedTimelineItem: TimelineItem? { timeline?.items.first { $0.id == selectedTimelineItemID } }
    var selectedTimelineAudioClip: TimelineAudioClip? {
        timeline?.effectiveAudioClips.first { $0.id == selectedTimelineAudioClipID }
    }
    var selectedTelemetryItem: TimelineTelemetryItem? { timeline?.effectiveTelemetryItems.first { $0.id == selectedTelemetryItemID } }
    var telemetryTargetClip: TimelineItem? {
        if let selectedTimelineItem,
           selectedTimelineItem.kind == .video,
           selectedTimelineItem.assetID != nil {
            return selectedTimelineItem
        }
        return telemetryClip(at: timelinePlayheadTime)
    }
    var canInsertTelemetryPreset: Bool {
        !telemetryTargetSources.flatMap(\.summary.availableWidgetKinds).isEmpty
    }
    var telemetryTargetSources: [TelemetrySource] {
        guard let assetID = telemetryTargetClip?.assetID else { return [] }
        return project?.effectiveTelemetrySources.filter { $0.linkedAssetID == assetID } ?? []
    }
    var telemetryTargetSummary: TelemetrySummary? {
        guard let assetID = telemetryTargetClip?.assetID else { return nil }
        return TelemetrySourceSelector().bestGeneralSource(linkedAssetID: assetID, sources: telemetryTargetSources)?.summary
            ?? project?.analyses.first(where: { $0.assetID == assetID })?.telemetry
    }
    func availableTelemetryPresentations(for kind: TelemetryWidgetKind) -> [TelemetryWidgetPresentation] {
        let summaries = telemetryTargetSources.map(\.summary) + [telemetryTargetSummary].compactMap { $0 }
        return kind.supportedPresentations.filter { presentation in
            summaries.contains { $0.supports(kind, presentation: presentation) }
        }
    }
    func canInsertTelemetryPreset(kind: TelemetryWidgetKind, presentation: TelemetryWidgetPresentation) -> Bool {
        telemetryTargetSources.contains { $0.summary.supports(kind, presentation: presentation) }
            || telemetryTargetSummary?.supports(kind, presentation: presentation) == true
    }
    var selectedEffectTimelineItem: EffectTimelineItem? { timeline?.effectiveEffects.first { $0.id == selectedEffectTimelineItemID } }
    var selectedTitleTimelineItem: TitleTimelineItem? { timeline?.effectiveTitleItems.first { $0.id == selectedTitleTimelineItemID } }
    var selectedTransitionTimelineItem: TimelineTransitionItem? { timeline?.effectiveTransitionItems.first { $0.id == selectedTransitionTimelineItemID } }
    private var currentTimelineSelection: Set<TimelineSelectionKey> {
        var selection = Set(selectedTimelineItemIDs.map(TimelineSelectionKey.item))
        selection.formUnion(selectedTimelineAudioClipIDs.map(TimelineSelectionKey.audio))
        selection.formUnion(selectedTelemetryItemIDs.map(TimelineSelectionKey.telemetry))
        selection.formUnion(selectedEffectTimelineItemIDs.map(TimelineSelectionKey.effect))
        selection.formUnion(selectedTitleTimelineItemIDs.map(TimelineSelectionKey.title))
        selection.formUnion(selectedTransitionTimelineItemIDs.map(TimelineSelectionKey.transition))
        if let selectedTimelineItemID { selection.insert(.item(selectedTimelineItemID)) }
        if let selectedTimelineAudioClipID { selection.insert(.audio(selectedTimelineAudioClipID)) }
        if let selectedTelemetryItemID { selection.insert(.telemetry(selectedTelemetryItemID)) }
        if let selectedEffectTimelineItemID { selection.insert(.effect(selectedEffectTimelineItemID)) }
        if let selectedTitleTimelineItemID { selection.insert(.title(selectedTitleTimelineItemID)) }
        if let selectedTransitionTimelineItemID { selection.insert(.transition(selectedTransitionTimelineItemID)) }
        if selectedSoundtrack { selection.insert(.soundtrack) }
        return selection
    }
    var hasTimelineSelection: Bool {
        !currentTimelineSelection.isEmpty
    }
    var canPasteTimelineElements: Bool { timelineClipboard?.isEmpty == false }

    func isTimelineItemSelected(_ id: UUID) -> Bool { currentTimelineSelection.contains(.item(id)) }
    func isTimelineAudioClipSelected(_ id: UUID) -> Bool { currentTimelineSelection.contains(.audio(id)) }
    func isTelemetryItemSelected(_ id: UUID) -> Bool { currentTimelineSelection.contains(.telemetry(id)) }
    func isEffectTimelineItemSelected(_ id: UUID) -> Bool { currentTimelineSelection.contains(.effect(id)) }
    func isTitleTimelineItemSelected(_ id: UUID) -> Bool { currentTimelineSelection.contains(.title(id)) }
    func isTransitionTimelineItemSelected(_ id: UUID) -> Bool { currentTimelineSelection.contains(.transition(id)) }
    var shouldShowActivityPanel: Bool {
        isActivityPanelVisible
    }
    var canSplitTimelineSelectionAtPlayhead: Bool {
        if let item = selectedTimelineItem {
            return item.kind != .title && timelinePlayheadTime > item.timelineStart && timelinePlayheadTime < item.timelineStart + item.timelineDuration
        }
        if let clip = selectedTimelineAudioClip {
            return timelinePlayheadTime > clip.timelineStart && timelinePlayheadTime < clip.timelineEnd
        }
        return false
    }
    var automaticallyShowPreview: Bool { UserDefaults.standard.object(forKey: "automaticallyShowPreview") as? Bool ?? true }
    var mediaReady: Bool { project?.assets.isEmpty == false }
    var analysisReady: Bool { isAnalysisCurrent }
    var montageReady: Bool { timeline?.items.isEmpty == false && !hasPendingFilmChanges }
    /// Availability and freshness are deliberately separate. Pending director
    /// notes make the current preview stale, but they must not make it
    /// unplayable: the user can keep watching the last assembled cut without
    /// rebuilding it first.
    var hasPlayablePreview: Bool { previewPlayer != nil }
    var playbackReady: Bool { hasPlayablePreview && !hasPendingFilmChanges }
    var maximumSourceFrameRate: Double {
        project?.assets.compactMap(\.metadata.frameRate).filter { $0.isFinite && $0 > 0 }.max()
            ?? timeline?.frameRate
            ?? 30
    }
    var exportFrameRateOptions: [Double] {
        let maximum = maximumSourceFrameRate
        let standard = [24.0, 25.0, 30.0, 50.0, 60.0, 120.0, 240.0].filter { $0 <= maximum + 0.01 }
        return Array(Set(standard + [maximum])).sorted()
    }
    var directorUsesNeuralModel: Bool {
        directorRuntimeStatus.contains("нейросеть") &&
        !directorRuntimeStatus.contains("не нейросеть") &&
        !directorRuntimeStatus.contains("Проверяю")
    }
    var aiProfile: AIAnalysisProfile {
        AIAnalysisProfile.resolve(mode: aiPowerMode, advanced: advancedAISettings, thermalState: .nominal)
    }
    var aiProfileSummary: String { aiProfile.summary }
    var canDownloadAIModel: Bool { aiProfile.runtime != .mlx }
    func isAIModelInstalled(for mode: AIPowerMode) -> Bool {
        return aiModelAvailability[mode] ?? (mode == aiPowerMode && aiVisionModelInstalled)
    }
    func canDownloadAIModel(for mode: AIPowerMode) -> Bool {
        return AIAnalysisProfile.resolve(mode: mode, advanced: advancedAISettings, thermalState: .nominal).runtime != .mlx
    }
    var aiAnalysisRuntimeStatus: String {
        project?.analyses.compactMap(\.aiRuntimeLabel).last ?? "Runtime будет проверен при первом анализе"
    }
    var aiAnalysisDetail: String {
        let samples = project?.analyses.compactMap(\.sampledFrameCount).reduce(0, +) ?? 0
        let deep = project?.analyses.compactMap(\.deepAnalyzedCandidateCount).reduce(0, +) ?? 0
        let decoded = project?.analyses.compactMap(\.metrics?.decodedFrameCount).reduce(0, +) ?? 0
        let cacheHits = project?.analyses.compactMap(\.metrics?.frameCacheHitCount).reduce(0, +) ?? 0
        let vlmCalls = project?.analyses.compactMap(\.metrics?.vlmCallCount).reduce(0, +) ?? 0
        let telemetry = project?.analyses.compactMap(\.telemetry?.timedSamples?.count).reduce(0, +) ?? 0
        if samples == 0 { return "Proxy → адаптивная выборка → лучшие моменты → глубокий анализ" }
        let telemetryStatus = telemetry > 0 ? " · синхронизировано точек телеметрии: \(telemetry)" : ""
        return "Кадров: \(samples) · декодировано: \(decoded) · из кэша: \(cacheHits) · VLM-пакетов: \(vlmCalls) · глубоко проверено: \(deep)\(telemetryStatus)"
    }
    var aiThermalStatus: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Температура нормальная"
        case .fair: return "Нагрузка умеренная"
        case .serious: return "Глубина анализа автоматически снижена"
        case .critical: return "Тяжёлый AI временно ограничен для охлаждения"
        @unknown default: return "Автоматическое управление нагрузкой"
        }
    }
    var filmReadiness: Double {
        if isCreatingFilm { return min(1, max(0, progress)) }
        if isImporting { return min(0.15, max(0, progress) * 0.15) }
        if isAnalyzing { return min(0.65, 0.15 + max(0, progress) * 0.5) }
        guard let project, !project.assets.isEmpty else { return 0 }
        let currentAnalysisCount = project.assets.filter { asset in
            project.analyses.contains {
                $0.assetID == asset.id && $0.analyzedContentHash == asset.contentHash &&
                $0.schemaVersion == project.analysisSchemaVersion && analysis($0, satisfies: aiProfile)
            }
        }.count
        return FilmReadinessCalculator.value(
            assetCount: project.assets.count,
            analyzedCount: currentAnalysisCount,
            hasMontage: timeline?.items.isEmpty == false,
            hasPlayback: previewPlayer != nil,
            hasPendingChanges: hasPendingFilmChanges
        )
    }
    var filmReadinessStatus: String {
        if isCreatingFilm { return status }
        if hasPendingFilmChanges {
            return timeline == nil
                ? "Замысел изменён — нужно создать фильм"
                : "Есть неприменённые правки — текущий просмотр показывает предыдущую версию"
        }
        return directorStatus
    }
    var filmActionTitle: String {
        if timeline == nil { return "Создать фильм" }
        return hasPendingFilmChanges ? "Применить правки" : "Пересобрать фильм"
    }
    var isAnalysisCurrent: Bool {
        guard let project, !project.assets.isEmpty else { return false }
        return project.assets.allSatisfy { asset in
            project.analyses.contains {
                $0.assetID == asset.id &&
                $0.analyzedContentHash == asset.contentHash &&
                $0.schemaVersion == project.analysisSchemaVersion &&
                analysis($0, satisfies: aiProfile)
            }
        }
    }

    private func analysis(_ result: AnalysisResult, satisfies profile: AIAnalysisProfile) -> Bool {
        result.satisfies(profile) && ((result.completedDepth ?? .quick) > profile.targetDepth || result.analysisProfileKey == profile.cacheKey)
    }

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.recentProjectsKey) ?? []
        recentProjectURLs = paths.map { URL(fileURLWithPath: $0) }
        Task { await refreshDirectorRuntimeStatus() }
        Task { await refreshLocalVisionModelStatus() }
    }

    func createProject() {
        let panel = NSSavePanel()
        panel.title = "Новый проект VeloEdit"
        panel.nameFieldStringValue = "Мой фильм"
        panel.allowedContentTypes = [UTType(filenameExtension: "veloedit") ?? .package]
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != ProjectStore.packageExtension { url.appendPathExtension(ProjectStore.packageExtension) }
        let destinationURL = url
        Task {
            await flushAutosave()
            do {
                var packageURL = destinationURL
                let store = try ProjectStore(createAt: packageURL, name: packageURL.deletingPathExtension().lastPathComponent)
                var resourceValues = URLResourceValues()
                resourceValues.hasHiddenExtension = true
                try? packageURL.setResourceValues(resourceValues)
                resetProjectUI()
                pipeline = VeloEditPipeline(store: store)
                projectURL = packageURL
                rememberProject(packageURL)
                section = .media
                await refresh()
                status = "Проект создан — перетащите фотографии, видео или музыку"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.title = "Открыть проект VeloEdit"
        panel.allowedContentTypes = [UTType(filenameExtension: "veloedit") ?? .package]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    func openRecentProject(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            forgetRecentProject(url)
            errorMessage = "Проект больше не найден: \(url.path)"
            return
        }
        openProject(at: url)
    }

    func openRecentProjectExport(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            forgetRecentProject(url)
            errorMessage = "Проект больше не найден: \(url.path)"
            return
        }
        openProject(at: url, destination: .export)
    }

    func forgetRecentProject(_ url: URL) {
        let path = url.standardizedFileURL.path
        recentProjectURLs.removeAll { $0.standardizedFileURL.path == path }
        persistRecentProjects()
    }

    func renameRecentProject(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            forgetRecentProject(url)
            errorMessage = "Проект больше не найден: \(url.path)"
            return
        }
        let manifestURL = url.appendingPathComponent("project.json")
        let currentName = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder.veloEdit.decode(ProjectManifest.self, from: $0) }
            .map(\.name)
            ?? url.deletingPathExtension().lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Переименовать проект"
        alert.informativeText = "Введите новое название проекта. Имя пакета на диске не изменится."
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        let field = NSTextField(string: currentName)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            do {
                let store = try ProjectStore(open: url)
                try await store.update { $0.name = name }
                if projectURL?.standardizedFileURL == url.standardizedFileURL {
                    await refresh()
                }
                rememberProject(url)
                status = "Проект переименован"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteRecentProject(_ url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Удалить проект?"
        alert.informativeText = "Проект «\(url.deletingPathExtension().lastPathComponent)» будет перемещён в Корзину."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                self.forgetRecentProject(url)
                if self.projectURL?.standardizedFileURL == url.standardizedFileURL {
                    self.resetProjectUI()
                    self.pipeline = nil
                    self.section = .home
                }
                self.status = "Проект перемещён в Корзину"
            }
        }
    }

    private func openProject(at url: URL, destination: WorkspaceSection = .media) {
        // A recent-project card lives inside a ForEach backed by
        // `recentProjectURLs`. Opening it also moves that URL to the front of
        // the list. If we publish those changes while SwiftUI is still
        // dispatching the card's ButtonGesture, the pressed button can be
        // destroyed underneath the gesture (and SwiftUI crashes in
        // MainActor.assumeIsolated). Start the state transition on the next
        // main-run-loop turn, after the click has fully completed.
        DispatchQueue.main.async { [weak self] in
            self?.performProjectOpen(at: url, destination: destination)
        }
    }

    private func performProjectOpen(at url: URL, destination: WorkspaceSection) {
        Task {
            await flushAutosave()
            do {
                let store = try ProjectStore(open: url)
                resetProjectUI()
                pipeline = VeloEditPipeline(store: store)
                projectURL = url
                rememberProject(url)
                section = .media
                await refresh()
                await refreshLocalVisionModelStatus()
                prepareOpenedProject()
                section = destination
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func rememberProject(_ url: URL) {
        let normalized = url.standardizedFileURL
        var updated = recentProjectURLs.filter { $0.standardizedFileURL.path != normalized.path }
        updated.insert(normalized, at: 0)
        recentProjectURLs = Array(updated.prefix(12))
        persistRecentProjects()
    }

    private func persistRecentProjects() {
        UserDefaults.standard.set(recentProjectURLs.map(\.path), forKey: Self.recentProjectsKey)
    }

    func chooseMedia() {
        guard pipeline != nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Импорт медиа и телеметрии"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        let cameraContainers = MediaImporter.videoExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = Array(Set([.image, .movie, .audio] + cameraContainers + TelemetryEngine.sidecarExtensions.compactMap { UTType(filenameExtension: $0) }))
        guard panel.runModal() == .OK else { return }
        importMedia(panel.urls)
    }

    func openFreeToUseMusic() {
        NSWorkspace.shared.open(FreeToUseMusicProvider.musicHomeURL)
        status = "Открыт официальный каталог Free To Use Music"
    }

    func prepareFreeToUseMusicLibrary() {
        prepareOnlineMusicLibrary()
    }

    func prepareOnlineMusicLibrary() {
        guard let pipeline, !isWorking, confirmFreeToUseLicenseIfNeeded() else { return }
        run("Проверяю онлайн-источники музыки") {
            let downloaded = await pipeline.prepareOnlineMusicLibrary()
            await self.refreshMusicLibrary()
            self.status = downloaded.isEmpty
                ? "Offline-библиотека готова; новые онлайн-треки не требуются"
                : "Онлайн-кэш обновлён — добавлено треков: \(downloaded.count)"
        }
    }

    func chooseMusicFolder() {
        guard let pipeline, !isWorking else { return }
        let panel = NSOpenPanel()
        panel.title = "Добавить папку My Music"
        panel.prompt = "Добавить папку"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        run("Индексирую My Music") {
            let tracks = try await pipeline.importMusicFolder(folder)
            await self.refreshMusicLibrary()
            self.status = "My Music готова · локальных треков: \(tracks.filter { $0.sourceProvider == .user }.count)"
        }
    }

    func copyMusicAttribution() {
        guard let trackID = timeline?.music?.trackID,
              let track = musicTracks.first(where: { $0.id == trackID }) else { return }
        let text = track.license.attributionText ?? [
            "\(track.title) — \(track.author)",
            "Источник: \(track.sourcePageURL.absoluteString)",
            "Лицензия: \(track.license.name)",
            "Атрибуция не требуется"
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = track.license.requiresAttribution == true
            ? "Атрибуция трека скопирована"
            : "Сведения о лицензии скопированы"
    }

    private func confirmFreeToUseLicenseIfNeeded() -> Bool {
        if UserDefaults.standard.bool(forKey: Self.freeToUseLicenseAcceptedKey) { return true }
        let alert = NSAlert()
        alert.messageText = "Необязательные онлайн-источники"
        alert.informativeText = "VeloEdit сохранит источник, лицензию и атрибуцию каждого скачанного трека. У Free To Use бесплатная лицензия предназначена для user-generated content и требует атрибуции; для коммерческих роликов может потребоваться отдельная лицензия. Openverse используется только для треков с проверяемой Creative Commons лицензией."
        alert.addButton(withTitle: "Проверить источники")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: Self.freeToUseLicenseAcceptedKey)
        return true
    }

    func refreshMusicLibrary() async {
        do {
            musicTracks = if let pipeline { try await pipeline.musicTracks() } else { [] }
            musicLibraryStatus = if let pipeline { await pipeline.musicLibraryStatus() } else { MusicLibraryStatus() }
            if let directorMusicTrackID,
               !userMusicTracks.contains(where: { $0.id == directorMusicTrackID }) {
                self.directorMusicTrackID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard pipeline != nil else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else { url = item as? URL }
                if let url { lock.lock(); urls.append(url); lock.unlock() }
            }
        }
        group.notify(queue: .main) { [weak self] in self?.importMedia(urls) }
        return true
    }

    func importMedia(_ urls: [URL]) {
        guard let pipeline, !isWorking else { return }
        section = .media
        isImporting = true
        run("Импортирую материалы") {
            defer { self.isImporting = false }
            let errors = try await pipeline.importMedia(urls) { [weak self] item in
                Task { @MainActor in self?.setProgress(item, base: 0, span: 0.70, phase: "Импорт") }
            }
            await self.refresh()
            self.activityTitle = "Создаю изображения предварительного просмотра исходников"
            self.progress = 0.70
            let thumbnailErrors = await pipeline.generateThumbnails { [weak self] item in
                Task { @MainActor in self?.setProgress(item, base: 0.70, span: 0.30, phase: "Предпросмотр") }
            }
            self.thumbnailURLs = await pipeline.thumbnailURLs()
            if self.timeline != nil {
                self.markFilmNeedsRebuild("Добавлены новые материалы — фильм нужно обновить", instruction: "Учти вновь добавленные материалы")
            }
            let skipped = errors.count + thumbnailErrors.count
            self.status = skipped == 0 ? "Фото, видео и музыка готовы" : "Материалы добавлены, предупреждений: \(skipped)"
        }
    }

    func analyze() {
        guard let pipeline, !isWorking else { return }
        isAnalyzing = true
        run("Анализирую материалы") {
            defer { self.isAnalyzing = false }
            let count = try await pipeline.analyzeMissing(preferredAssetID: self.selectedAssetID) { [weak self] item in
                Task { @MainActor in self?.setProgress(item, showsAnalysisFileProgress: true) }
            }
            await self.refresh()
            let total = self.project?.assets.count ?? 0
            let message = count == 0
                ? "Анализ уже готов — все материалы актуальны (\(total))."
                : "Анализ завершён — обработано новых материалов: \(count) из \(total)."
            self.status = message
            if count > 0, self.timeline != nil {
                self.markFilmNeedsRebuild("Анализ исходников обновлён — фильм нужно пересобрать")
            }
        }
    }

    func refreshEmbeddedTelemetryIfNeeded() async {
        guard let pipeline else { return }
        do {
            let count = try await pipeline.refreshEmbeddedTelemetryIfNeeded()
            guard count > 0 else { return }
            await refresh()
            status = "Найдена телеметрия камер: \(count)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectPreset(_ value: FilmPreset) {
        guard preset != value else { return }
        preset = value
        markFilmNeedsRebuild("Стиль изменён — примените правки к фильму")
    }

    func setAIPowerMode(_ value: AIPowerMode) {
        guard aiPowerMode != value else { return }
        aiPowerMode = value
        persistAISettings()
        if timeline != nil { markFilmNeedsRebuild("Мощность AI изменена — фильм нужно обновить") }
        Task { await refreshLocalVisionModelStatus() }
    }

    func setAdvancedAISettings(_ value: AdvancedAISettings) {
        guard advancedAISettings != value else { return }
        advancedAISettings = value
        aiModelAvailability = [:]
        persistAISettings()
        status = "Расширенные настройки AI сохранены. Анализ будет обновлён при следующем запуске."
        if timeline != nil { markFilmNeedsRebuild("Модель AI изменена — фильм нужно обновить") }
        Task { await refreshAIModelAvailability() }
    }

    func refreshLocalVisionModelStatus() async {
        let profile = aiProfile
        guard profile.runtime != .mlx else {
            aiVisionModelInstalled = false
            aiVisionModelStatus = "MLX adapter ещё не включён в эту release-сборку; доступен Apple Vision fallback"
            return
        }
        aiVisionModelStatus = "Проверяю \(profile.ollamaModelID)…"
        let availability = await LocalAIModelManager.shared.availability(model: profile.ollamaModelID)
        guard profile.ollamaModelID == aiProfile.ollamaModelID else { return }
        aiVisionModelInstalled = availability.installed
        aiModelAvailability[aiPowerMode] = availability.installed
        aiVisionModelStatus = availability.message
    }

    func downloadSelectedAIModel() {
        downloadAIModel(for: aiPowerMode)
    }

    func refreshAIModelAvailability() async {
        var availabilityByMode: [AIPowerMode: Bool] = [:]
        for mode in AIPowerMode.allCases {
            let profile = AIAnalysisProfile.resolve(mode: mode, advanced: advancedAISettings, thermalState: .nominal)
            guard profile.runtime != .mlx else {
                availabilityByMode[mode] = false
                continue
            }
            let availability = await LocalAIModelManager.shared.availability(model: profile.ollamaModelID)
            availabilityByMode[mode] = availability.installed
            if mode == aiPowerMode {
                aiVisionModelInstalled = availability.installed
                aiVisionModelStatus = availability.message
            }
        }
        aiModelAvailability = availabilityByMode
    }

    func downloadAIModel(for mode: AIPowerMode) {
        guard canDownloadAIModel(for: mode), downloadingAIPowerMode == nil else { return }
        let profile = AIAnalysisProfile.resolve(mode: mode, advanced: advancedAISettings, thermalState: .nominal)
        let modelID = profile.ollamaModelID
        downloadingAIPowerMode = mode
        isDownloadingAIModel = true
        aiModelDownloadProgress = 0
        if mode == aiPowerMode { aiVisionModelStatus = "Подготавливаю загрузку…" }
        Task {
            do {
                try await LocalAIModelManager.shared.pull(model: modelID) { [weak self] update in
                    Task { @MainActor in
                        self?.aiModelDownloadProgress = update.fraction
                        if self?.aiPowerMode == mode {
                            self?.aiVisionModelStatus = "Загружаю · \(Int(update.fraction * 100))%"
                        }
                    }
                }
                aiModelAvailability[mode] = true
                if mode == aiPowerMode { aiVisionModelInstalled = true }
                aiModelDownloadProgress = 1
                if mode == aiPowerMode { aiVisionModelStatus = "Модель загружена и готова" }
            } catch {
                errorMessage = error.localizedDescription
                if mode == aiPowerMode { aiVisionModelStatus = error.localizedDescription }
            }
            isDownloadingAIModel = false
            downloadingAIPowerMode = nil
            await refreshAIModelAvailability()
        }
    }

    private func persistAISettings() {
        guard let pipeline else { return }
        let mode = aiPowerMode
        let advanced = advancedAISettings
        Task {
            do {
                try await pipeline.updateAISettings(mode: mode, advanced: advanced)
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setTargetMinutes(_ value: Double) {
        let normalized = min(60, max(0.5, value))
        guard abs(targetMinutes - normalized) > 0.001 else { return }
        targetMinutes = normalized
        markFilmNeedsRebuild("Длительность изменена — примените правки к фильму")
    }

    func selectDirectorMusicTrack(_ trackID: UUID?) {
        let validatedID = trackID.flatMap { id in
            userMusicTracks.contains(where: { $0.id == id }) ? id : nil
        }
        guard directorMusicTrackID != validatedID else { return }
        directorMusicTrackID = validatedID
        if timeline != nil {
            let message = validatedID == nil
                ? "Включён автоподбор музыки — примените правки к фильму"
                : "Выбран свой трек — примените правки к фильму"
            markFilmNeedsRebuild(message)
        }
    }

    func sendDirectorMessage() {
        guard !isDirectorResponding else { return }
        let sourceText = directorInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }
        let requestMode = DirectorRequestIntentInterpreter().mode(for: sourceText)
        let requestedMusic = requestMode == .edit
            ? MusicPromptInterpreter().interpret(prompt: sourceText, preset: preset)
            : nil
        if requestedMusic != nil, !confirmFreeToUseLicenseIfNeeded() { return }
        guard let exchange = beginDirectorExchange(mode: requestMode) else { return }
        isDirectorResponding = true
        directorStatus = requestMode == .advisory
            ? "Анализирую материал для совета — Timeline останется без изменений"
            : requestedMusic == nil ? "Умный режиссёр изучает замысел" : "Подбираю музыку в Free To Use"
        directorTask = Task {
            if requestMode == .advisory,
               let pipeline,
               !self.isWorking,
               !self.isAnalysisCurrent,
               self.project?.assets.isEmpty == false {
                self.isAnalyzing = true
                self.directorStatus = "Сначала анализирую ролик, не меняя исходник и Timeline"
                _ = try? await pipeline.analyzeMissing(preferredAssetID: self.selectedAssetID)
                await self.refresh()
                self.isAnalyzing = false
            }
            let naturalLanguageBaseline = self.timeline
            var naturalExecution: NaturalLanguageEditResult?
            var naturalLanguageApplied = false
            if requestMode == .edit, let pipeline, self.timeline != nil {
                do {
                    self.directorStatus = "Применяю минимальную правку к Timeline"
                    let execution = try await pipeline.applyNaturalLanguageEdit(
                        exchange.text,
                        selectedItemID: self.selectedTimelineItemID,
                        playheadTime: self.timelinePlayheadTime,
                        createCheckpoint: true,
                        recordHistory: true
                    )
                    naturalExecution = execution
                    naturalLanguageApplied = execution.committed
                    if execution.committed {
                        await self.refresh()
                        await self.rebuildPlaybackIfPossible(show: false)
                        self.directorStatus = execution.plan.requiresBackgroundRefinement
                            ? "Предварительный результат готов · уточняю монтаж в фоне"
                            : "Правка сразу отражена в Timeline и Preview"
                    }
                } catch {
                    // Keep the request in the existing pending queue. The user
                    // still gets a local-model reply and can retry safely.
                    self.directorStatus = "Быстрая правка не применена · сохраняю запрос"
                }
            }
            var reply = await directorAgent.respond(
                to: exchange.text,
                context: directorContext(),
                mode: requestMode
            )
            guard !Task.isCancelled else { return }
            if requestMode == .advisory {
                reply = DirectorAIReply(
                    text: reply.text,
                    runtimeLabel: reply.runtimeLabel,
                    normalizedBrief: nil,
                    commands: []
                )
            }
            let parsedCommands = EditorCommandParser().parse(exchange.text, preset: self.preset)
            let isMusicOnlyRequest = !parsedCommands.isEmpty && parsedCommands.allSatisfy {
                $0.semanticCategory == "music" || $0.semanticCategory == "music-volume"
            }
            if let requestedMusic, let pipeline, isMusicOnlyRequest, !naturalLanguageApplied {
                do {
                    if self.timeline == nil {
                        let track = try await pipeline.prepareMusicTrack(for: requestedMusic)
                        await self.refreshMusicLibrary()
                        reply = DirectorAIReply(
                            text: "Подобрал «\(track.title)» — \(track.author) и сохранил трек в локальную библиотеку. При создании фильма добавлю его в монтаж.",
                            runtimeLabel: reply.runtimeLabel,
                            normalizedBrief: reply.normalizedBrief,
                            commands: reply.commands
                        )
                    } else {
                        let previousTimeline = self.timeline
                        try await pipeline.updateMusic(requestedMusic)
                        await self.refresh()
                        await self.refreshMusicLibrary()
                        self.recordTimelineChange(from: previousTimeline)
                        if let previousTimeline, let current = self.timeline {
                            _ = try? await pipeline.recordPreferenceSignals(before: previousTimeline, after: current, source: .music)
                        }
                        await self.rebuildPlaybackIfPossible(show: false)
                        let title = self.timeline?.music?.trackTitle ?? "подходящий трек"
                        reply = DirectorAIReply(
                            text: "Готово: выбрал «\(title)», сохранил локально и добавил в монтаж.",
                            runtimeLabel: reply.runtimeLabel,
                            normalizedBrief: reply.normalizedBrief,
                            commands: reply.commands
                        )
                        self.consumePendingDirectorInstruction(exchange.text)
                    }
                } catch {
                    reply = DirectorAIReply(
                        text: "Не удалось скачать музыку из Free To Use: \(error.localizedDescription)",
                        runtimeLabel: reply.runtimeLabel,
                        normalizedBrief: reply.normalizedBrief,
                        commands: reply.commands
                    )
                }
            }
            if requestMode == .edit, let pipeline, let execution = naturalExecution {
                do {
                    if execution.plan.requiresBackgroundRefinement {
                        self.directorStatus = "Предварительный результат виден · выполняю глубокое уточнение"
                        let selectedCandidateID = naturalLanguageBaseline?.items
                            .first(where: { $0.id == self.selectedTimelineItemID })?.candidateID
                        _ = try await pipeline.regenerate(
                            feedback: reply.normalizedBrief?.isEmpty == false ? reply.normalizedBrief! : exchange.text,
                            selectedCandidateID: selectedCandidateID,
                            preset: self.preset,
                            targetDuration: self.targetMinutes * 60
                        )
                        let refined = try await pipeline.applyNaturalLanguageEdit(
                            exchange.text,
                            selectedItemID: nil,
                            playheadTime: self.timelinePlayheadTime,
                            supplementalCommands: reply.commands,
                            createCheckpoint: false,
                            recordHistory: true
                        )
                        naturalExecution = refined
                        naturalLanguageApplied = true
                        await self.refresh()
                        await self.rebuildPlaybackIfPossible(show: false)
                    } else {
                        let consumed = Self.naturalLanguageConsumedCategories(execution.plan)
                        let extra = reply.commands.filter { !consumed.contains($0.semanticCategory) }
                        if !extra.isEmpty {
                            _ = try await pipeline.applyEditorCommands(
                                extra,
                                selectedItemID: self.selectedTimelineItemID,
                                selectedCandidateID: naturalLanguageBaseline?.items
                                    .first(where: { $0.id == self.selectedTimelineItemID })?.candidateID,
                                createCheckpoint: false
                            )
                            await self.refresh()
                            await self.rebuildPlaybackIfPossible(show: false)
                            naturalLanguageApplied = true
                        }
                    }
                } catch {
                    self.errorMessage = "Предварительная правка сохранена, но фоновое уточнение не завершено: \(error.localizedDescription)"
                }
            }
            if naturalLanguageApplied {
                self.recordTimelineChange(from: naturalLanguageBaseline)
                if let naturalLanguageBaseline, let current = self.timeline {
                    _ = try? await pipeline?.recordPreferenceSignals(
                        before: naturalLanguageBaseline,
                        after: current,
                        source: .acceptedEdit
                    )
                }
                self.consumePendingDirectorInstruction(exchange.text)
                let summary = naturalExecution?.plan.requiresBackgroundRefinement == true
                    ? "Готово: применил запрос и автоматически уточнил монтаж через полный режиссёрский pipeline."
                    : (naturalExecution?.userSummary ?? "Готово: правка применена к Timeline.")
                reply = DirectorAIReply(
                    text: summary,
                    runtimeLabel: reply.runtimeLabel,
                    normalizedBrief: reply.normalizedBrief,
                    commands: reply.commands
                )
            }
            finishDirectorExchange(
                replyID: exchange.replyID,
                sourceText: exchange.text,
                reply: reply,
                mode: requestMode,
                wasExecuted: naturalLanguageApplied
            )
            isDirectorResponding = false
            directorTask = nil
            // Editing requests are actions, not drafts. A fast in-place edit
            // is preferred, but if there is no Timeline yet or the request
            // needs the full director pipeline, continue automatically instead
            // of waiting for a separate Create/Rebuild button.
            if requestMode == .edit,
               self.hasPendingFilmChanges,
               self.project?.assets.isEmpty == false {
                self.createFilm()
            }
        }
    }

    func refreshDirectorRuntimeStatus() async {
        directorRuntimeStatus = "Проверяю локальную нейросеть…"
        directorRuntimeStatus = await directorAgent.runtimeStatus()
    }

    func createFilm() {
        guard let pipeline, !isWorking, !isDirectorResponding else { return }
        let isRebuildingFilm = timeline != nil
        let selectedDirectorTrack = directorMusicTrack
        let musicRequest = ([prompt] + pendingDirectorInstructions).joined(separator: "\n")
        if selectedDirectorTrack == nil,
           MusicPromptInterpreter().interpret(
            prompt: musicRequest,
            preset: preset,
            automaticDefault: true
        ) != nil,
           !confirmFreeToUseLicenseIfNeeded() { return }
        let pendingExchange = beginDirectorExchange()
        progress = 0
        isCreatingFilm = true
        run("Запускаю создание фильма") {
            defer { self.isCreatingFilm = false }
            do {
                self.activityTitle = "Умный режиссёр изучает задачу"
                self.status = "Фиксирую замысел и параметры фильма"
                self.progress = 0.03
                if let pendingExchange {
                    self.isDirectorResponding = true
                    self.directorStatus = "Умный режиссёр готовит ответ перед монтажом"
                    let reply = await self.directorAgent.respond(to: pendingExchange.text, context: self.directorContext())
                    self.finishDirectorExchange(replyID: pendingExchange.replyID, sourceText: pendingExchange.text, reply: reply)
                    self.isDirectorResponding = false
                } else if !isRebuildingFilm {
                    self.appendDirectorNote("Начинаю монтаж по текущему описанию. Сначала проверю анализ исходников, затем соберу историю и сразу подготовлю просмотр.")
                }
                try Task.checkCancellation()
                self.progress = 0.10

                let revision = self.directorRevision
                let pendingInstructionCount = self.pendingDirectorInstructions.count
                let pendingInstructions = self.pendingDirectorInstructions
                let pendingCommandGroups = self.pendingDirectorCommandGroups
                let shouldReviseExistingFilm = self.timeline != nil && self.hasPendingFilmChanges
                let prompt = self.prompt
                let preset = self.preset
                let targetDuration = self.targetMinutes * 60
                let previousTimeline = self.timeline
                let selectedCandidateID = previousTimeline?.items.first(where: { $0.id == self.selectedTimelineItemID })?.candidateID
                let editorCommands = Self.resolvedEditorCommands(
                    instructions: pendingInstructions,
                    commandGroups: pendingCommandGroups,
                    fallbackPrompt: prompt,
                    preset: preset
                )

                self.activityTitle = "Анализирую исходники"
                let analyzed: Int
                if self.isAnalysisCurrent {
                    analyzed = 0
                    self.status = "Использую единожды сохранённый анализ исходников"
                } else {
                    self.status = "Ищу выразительные и технически удачные моменты"
                    analyzed = try await pipeline.analyzeMissing(preferredAssetID: self.selectedAssetID) { [weak self] item in
                        Task {
                            @MainActor in self?.setProgress(
                                item,
                                base: 0.10,
                                span: 0.50,
                                phase: "Анализ",
                                showsAnalysisFileProgress: true
                            )
                        }
                    }
                }
                self.progress = 0.60
                self.activityTitle = "Умный режиссёр собирает историю"
                self.status = analyzed == 0 ? "Использую готовый анализ и расставляю лучшие моменты" : "Анализ готов, выбираю лучшие моменты"
                self.progress = 0.66
                let baseTimeline: Timeline
                let canEditExistingTimelineInPlace = shouldReviseExistingFilm &&
                    previousTimeline != nil &&
                    !pendingInstructions.isEmpty &&
                    !editorCommands.isEmpty
                if canEditExistingTimelineInPlace, let previousTimeline {
                    // A filter, title, music or clip-setting request must not
                    // ask StoryEngine to choose and trim the entire film again.
                    baseTimeline = previousTimeline
                } else if shouldReviseExistingFilm {
                    let feedback = self.revisionFeedback(
                        instructions: pendingInstructions,
                        preset: preset,
                        targetDuration: targetDuration
                    )
                    baseTimeline = try await pipeline.regenerate(
                        feedback: feedback,
                        preset: preset,
                        targetDuration: targetDuration,
                        preferredMusicTrackID: selectedDirectorTrack?.id
                    )
                } else {
                    baseTimeline = try await pipeline.createFilm(
                        prompt: prompt,
                        preset: preset,
                        targetDuration: targetDuration,
                        preferredMusicTrackID: selectedDirectorTrack?.id
                    )
                }
                self.progress = 0.73
                self.activityTitle = "Исполняю команды видеоредактора"
                self.status = "Применяю скорость, кадр, звук, титры, переходы и эффекты из запроса"
                let commandReport = try await pipeline.applyEditorCommands(
                    editorCommands,
                    selectedItemID: nil,
                    selectedCandidateID: selectedCandidateID,
                    createCheckpoint: true
                )
                if let selectedDirectorTrack {
                    self.status = "Добавляю выбранный трек «\(selectedDirectorTrack.title)»"
                    try await pipeline.updateMusic(MusicDirective(
                        style: selectedDirectorTrack.suggestedStyle,
                        bpm: selectedDirectorTrack.bpm,
                        volume: self.timeline?.music?.volume ?? 0.22,
                        trackID: selectedDirectorTrack.id,
                        trackTitle: selectedDirectorTrack.title
                    ))
                }
                await self.refresh()
                let timeline = self.timeline ?? baseTimeline
                self.progress = 0.78
                self.activityTitle = "Готовлю просмотр фильма"
                self.status = "Соединяю \(timeline.items.count) фрагментов в одну композицию"
                let playback = try await pipeline.makePlayback { [weak self] item in
                    Task { @MainActor in self?.setProgress(item, base: 0.78, span: 0.21, phase: "Просмотр") }
                }
                self.setPlayback(playback, show: false, autoplay: false)
                self.progress = 1
                self.status = "Фильм готов: \(timeline.items.count) фрагментов, \(Self.durationText(timeline.duration))"
                self.completeFilmBuild(
                    revision: revision,
                    consumedInstructionCount: pendingInstructionCount,
                    previousTimeline: previousTimeline,
                    timeline: timeline,
                    commandReport: commandReport,
                    usesCompactConfirmation: isRebuildingFilm
                )
            } catch {
                self.isDirectorResponding = false
                if error is CancellationError {
                    self.appendDirectorNote("Остановил создание фильма. Ваше описание сохранено — можно изменить его и запустить монтаж снова.")
                } else {
                    self.appendDirectorNote("Не удалось закончить монтаж: \(error.localizedDescription). Бриф сохранён, можно повторить попытку.")
                }
                throw error
            }
        }
    }

    func regenerate() {
        let requestedFeedback = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pipeline, !isWorking, !requestedFeedback.isEmpty else { return }
        markFilmNeedsRebuild("Правка принята — пересобираю фильм", instruction: requestedFeedback)
        let revision = directorRevision
        let pendingInstructionCount = pendingDirectorInstructions.count
        let previousTimeline = timeline
        progress = 0
        isCreatingFilm = true
        run("Пересобираю без повторного анализа", presentation: .editorAI) {
            defer { self.isCreatingFilm = false }
            let selectedCandidate = previousTimeline?.items.first(where: { $0.id == self.selectedTimelineItemID })?.candidateID
            let commandPrompt = self.selectedTimelineItemID == nil
                ? requestedFeedback
                : "выбранный фрагмент, \(requestedFeedback)"
            let editorCommands = EditorCommandParser().parse(commandPrompt, preset: self.preset)
            self.progress = 0.12
            let baseTimeline: Timeline
            if !editorCommands.isEmpty, let previousTimeline {
                self.status = "Сохраняю текущий монтаж и применяю локальные параметры"
                baseTimeline = previousTimeline
            } else {
                self.status = "Применяю правку к режиссёрскому плану"
                baseTimeline = try await pipeline.regenerate(
                    feedback: requestedFeedback,
                    selectedCandidateID: selectedCandidate,
                    preset: self.preset,
                    targetDuration: self.targetMinutes * 60
                )
            }
            self.progress = 0.62
            self.status = "Исполняю команды видеоредактора из правки"
            let commandReport = try await pipeline.applyEditorCommands(
                editorCommands,
                selectedItemID: self.selectedTimelineItemID,
                selectedCandidateID: selectedCandidate,
                createCheckpoint: true
            )
            await self.refresh()
            let timeline = self.timeline ?? baseTimeline
            self.progress = 0.72
            self.activityTitle = "Обновляю просмотр"
            self.status = "Соединяю обновлённый монтаж"
            let playback = try await pipeline.makePlayback { [weak self] item in
                Task { @MainActor in self?.setProgress(item, base: 0.72, span: 0.27, phase: "Просмотр") }
            }
            self.setPlayback(playback)
            self.recordTimelineChange(from: previousTimeline)
            if let previousTimeline, let current = self.timeline {
                _ = try? await pipeline.recordPreferenceSignals(before: previousTimeline, after: current, source: .regenerate)
            }
            self.feedback = ""
            if !self.prompt.localizedCaseInsensitiveContains(requestedFeedback) {
                self.prompt += "\n\(requestedFeedback)"
            }
            self.progress = 1
            self.status = "Фильм обновлён: \(timeline.items.count) фрагментов"
            self.completeFilmBuild(
                revision: revision,
                consumedInstructionCount: pendingInstructionCount,
                previousTimeline: previousTimeline,
                timeline: timeline,
                commandReport: commandReport
            )
        }
    }

    /// Accept an edit from the timeline composer even while another pipeline
    /// operation is finishing. Pipeline mutations remain serialized; busy-time
    /// submissions are queued instead of being rejected by a disabled button.
    func submitTimelineAIEdit(_ instruction: String, range: ClosedRange<Double>? = nil) {
        let clean = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        feedback = ""
        let edit = PendingTimelineAIEdit(instruction: clean, range: range)
        guard !isWorking else {
            pendingTimelineAIEdits.append(edit)
            queuedTimelineAIEditCount = pendingTimelineAIEdits.count
            status = "Правка монтажа поставлена в очередь"
            return
        }
        startTimelineAIEdit(edit)
    }

    func renderPreview() {
        guard timeline != nil else { return }
        if previewPlayer != nil {
            showMovie()
            return
        }
        guard let pipeline else { return }
        run("Готовлю предварительный просмотр") {
            let playback = try await pipeline.makePlayback { [weak self] item in
                Task { @MainActor in self?.setProgress(item) }
            }
            self.setPlayback(playback, show: false)
            self.showMovie()
            self.status = playback.warnings.first ?? "Предварительный просмотр готов"
        }
    }

    func exportMaximum() { exportVideo(quality: .maximum, suggestedName: "Фильм VeloEdit максимального качества.mp4") }
    func export1080p() { exportVideo(quality: .final1080p, suggestedName: "Фильм VeloEdit высокой чёткости.mp4") }

    func exportTelemetryOverlay() {
        guard let pipeline, timeline?.effectiveTelemetryItems.isEmpty == false else {
            errorMessage = "Добавьте хотя бы один слой телеметрии на Timeline."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Телеметрия VeloEdit ProRes 4444.mov"
        panel.allowedContentTypes = [.quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("Экспортирую прозрачную телеметрию") {
            _ = try await pipeline.renderTelemetryOverlay(to: url) { [weak self] item in
                Task { @MainActor in self?.setProgress(item) }
            }
            self.status = "Прозрачный overlay ProRes 4444 сохранён"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func exportWithSettings(quality: RenderQuality, frameRate: Double = 30) {
        let suggestedName: String
        switch quality {
        case .preview720p:
            suggestedName = "Фильм VeloEdit 720p.mp4"
        case .preview1080p, .final1080p:
            suggestedName = "Фильм VeloEdit 1080p.mp4"
        case .final4K:
            suggestedName = "Фильм VeloEdit 4K.mp4"
        case .maximum:
            suggestedName = "Фильм VeloEdit максимального качества.mp4"
        }
        exportVideo(quality: quality, suggestedName: suggestedName, frameRate: frameRate)
    }

    func presentManualExportSettings() {
        openSection(.export)
        isShowingManualExportSettings = true
    }

    private func exportVideo(quality: RenderQuality, suggestedName: String, frameRate: Double? = nil) {
        guard let pipeline, confirmSelectedMusicExport() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("Экспортирую видео") {
            let report = try await pipeline.render(to: url, quality: quality, frameRate: frameRate) { [weak self] item in
                Task { @MainActor in self?.setProgress(item) }
            }
            if let warning = report.warnings.first {
                self.status = "Экспорт готов без саундтрека. \(warning)"
            } else {
                self.status = report.skippedItemIDs.isEmpty ? "Экспорт готов" : "Экспорт готов; неподдерживаемых элементов: \(report.skippedItemIDs.count)"
            }
        }
    }

    func exportFCPXML(mode: FCPXMLExportMode = .edit) {
        guard let pipeline, confirmSelectedMusicExport() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = mode == .edit ? "Монтаж VeloEdit.fcpxml" : "Подборка VeloEdit.fcpxml"
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml") ?? .xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("Экспортирую проект для Final Cut Pro") {
            try await pipeline.exportFCPXML(to: url, mode: mode)
            self.status = "Проект для Final Cut Pro сохранён: \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func exportDiagnostics() {
        guard let pipeline else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Диагностика VeloEdit.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try (await pipeline.diagnostics()).write(to: url, atomically: true, encoding: .utf8); status = "Диагностика сохранена" }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func exportPersonalTasteProfile() {
        guard let pipeline else { return }
        let panel = NSSavePanel()
        panel.title = "Экспорт Personal Taste"
        panel.nameFieldStringValue = "VeloEdit Personal Taste.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await pipeline.exportPersonalTasteProfile(to: url)
                status = "Personal Taste экспортирован"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func resetPersonalTasteProfile() {
        guard let pipeline else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Сбросить Personal Taste?"
        alert.informativeText = "Локально выученные предпочтения и история сигналов этого проекта будут удалены. Перед сбросом профиль можно экспортировать."
        alert.addButton(withTitle: "Сбросить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await pipeline.resetPersonalTasteProfile()
                await refresh()
                status = "Personal Taste сброшен"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func confirmSelectedMusicExport() -> Bool {
        guard let music = timeline?.music else { return true }
        guard let trackID = music.trackID,
              let track = musicTracks.first(where: { $0.id == trackID }),
              FileManager.default.fileExists(atPath: track.localFileURL.path) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Саундтрек недоступен"
            alert.informativeText = "Локального музыкального файла нет. Видео можно экспортировать без музыки; звук исходников сохранится."
            alert.addButton(withTitle: "Экспортировать без музыки")
            alert.addButton(withTitle: "Отмена")
            return alert.runModal() == .alertFirstButtonReturn
        }
        return true
    }

    func renameProject(to proposedName: String) {
        guard let pipeline else { return }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        run("Сохраняю название") {
            try await pipeline.renameProject(to: name)
            await self.refresh()
            self.status = "Проект переименован"
        }
    }

    func revealProject() {
        guard let projectURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([projectURL])
        status = "Проект показан в Finder"
    }

    func revealAsset(_ id: UUID) {
        guard let asset = project?.assets.first(where: { $0.id == id }) else { return }
        guard FileManager.default.fileExists(atPath: asset.originalURL.path) else {
            errorMessage = "Исходный файл не найден: \(asset.originalURL.path)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([asset.originalURL])
        status = "Исходник показан в Finder"
    }

    func selectAssetForMediaInspector(_ id: UUID) {
        selectedMusicTrackID = nil
        selectedAssetID = id
    }

    func selectMusicTrackForInspector(_ id: UUID) {
        selectedAssetID = nil
        selectedMusicTrackID = id
    }

    func closeMediaInspector() {
        selectedAssetID = nil
        selectedMusicTrackID = nil
    }

    func toggleFavorite(_ id: UUID) {
        guard let pipeline, let asset = project?.assets.first(where: { $0.id == id }) else { return }
        run(asset.favorite ? "Убираю из избранного" : "Добавляю в избранное") {
            try await pipeline.updateAsset(id: id, favorite: !asset.favorite)
            await self.refresh()
            self.status = asset.favorite ? "Убрано из избранного" : "Добавлено в избранное"
            if self.timeline != nil {
                self.markFilmNeedsRebuild("Выбор избранного изменён — фильм нужно обновить")
            }
        }
    }

    func toggleExcluded(_ id: UUID) {
        guard let pipeline, let asset = project?.assets.first(where: { $0.id == id }) else { return }
        run(asset.excluded ? "Возвращаю в подбор" : "Исключаю из подбора") {
            try await pipeline.updateAsset(id: id, excluded: !asset.excluded)
            await self.refresh()
            self.status = asset.excluded ? "Материал снова участвует в подборе" : "Материал исключён из будущих монтажей"
            if self.timeline != nil {
                self.markFilmNeedsRebuild("Состав материалов изменён — фильм нужно обновить")
            }
        }
    }

    func removeAsset(_ id: UUID) {
        guard let pipeline, let asset = project?.assets.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Удалить «\(asset.displayName)» из проекта?"
        alert.informativeText = "Оригинальный файл останется на диске. Материал и его фрагменты исчезнут только из VeloEdit."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Удалить из проекта")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run("Удаляю материал из проекта") {
            try await pipeline.removeAsset(id: id)
            self.selectedAssetID = nil
            self.selectedTimelineItemID = nil
            await self.refresh()
            await self.rebuildPlaybackIfPossible(show: false)
            self.status = "Материал удалён из проекта; оригинал не изменён"
        }
    }

    func createProxy(_ id: UUID) {
        guard let pipeline else { return }
        run("Создаю облегчённую копию") {
            let url = try await pipeline.ensureProxy(for: id)
            self.status = "Облегчённая копия готова: \(url.lastPathComponent)"
        }
    }

    func verifyMediaIntegrity() {
        guard let pipeline, project?.assets.isEmpty == false else { return }
        run("Проверяю целостность материалов") {
            let count = try await pipeline.verifyFullHashes { [weak self] item in
                Task { @MainActor in self?.setProgress(item) }
            }
            await self.refresh()
            self.status = count == 0 ? "Все материалы уже проверены" : "Проверка завершена: \(count) файлов"
        }
    }

    func moveSelectedTimelineItem(_ offset: Int) {
        guard let id = selectedTimelineItemID,
              let oldIndex = timeline?.items.firstIndex(where: { $0.id == id }) else { return }
        editTimelineOptimistically("Перемещаю фрагмент") {
            TimelineMutationEngine.moveItem(in: &$0, id: id, toIndex: oldIndex + offset)
        }
    }

    func moveTimelineItem(_ id: UUID, toIndex index: Int) {
        editTimelineOptimistically("Перемещаю фрагмент") {
            TimelineMutationEngine.moveItem(in: &$0, id: id, toIndex: index)
        }
    }

    func movePrimaryTimelineItem(_ id: UUID, toPrimaryIndex index: Int) {
        editTimelineOptimistically("Перемещаю фрагмент") {
            TimelineMutationEngine.movePrimaryItem(in: &$0, id: id, toPrimaryIndex: index)
        }
    }

    func moveConnectedTimelineItem(_ id: UUID, toTimelineStart time: Double) {
        editTimelineOptimistically("Перемещаю связанный фрагмент") {
            TimelineMutationEngine.moveConnectedItem(in: &$0, id: id, toTimelineStart: time)
        }
    }

    func insertAssetIntoTimeline(_ assetID: UUID, at index: Int? = nil) {
        guard let pipeline else { return }
        editTimeline("Добавляю материал в фильм") {
            let itemID = try await pipeline.insertAssetIntoTimeline(assetID: assetID, at: index)
            self.selectTimelineItem(itemID)
        }
    }

    func insertAssetAsOverlay(_ assetID: UUID, at time: Double) {
        guard let pipeline else { return }
        editTimeline("Добавляю видео поверх основного") {
            let itemID = try await pipeline.insertAssetAsOverlay(assetID: assetID, atTime: time)
            self.selectTimelineItem(itemID)
        }
    }

    func insertBackgroundIntoTimeline(_ preset: BackgroundPreset, at index: Int? = nil) {
        guard let pipeline else { return }
        editTimeline("Добавляю фон в фильм") {
            let itemID = try await pipeline.insertBackgroundIntoTimeline(preset, at: index)
            self.selectTimelineItem(itemID)
        }
    }

    func insertMusicClip(_ trackID: UUID, at time: Double? = nil) {
        guard let pipeline else { return }
        editTimeline("Добавляю аудиоклип") {
            if let id = try await pipeline.insertMusicClip(trackID: trackID, atTimelineStart: time ?? self.timelinePlayheadTime) {
                self.selectTimelineAudioClip(id)
            }
        }
    }

    func selectTimelineItem(_ id: UUID?, modifiers: NSEvent.ModifierFlags = []) {
        updateTimelineSelection(id.map(TimelineSelectionKey.item), modifiers: modifiers)
    }

    func selectTimelineAudioClip(_ id: UUID?, modifiers: NSEvent.ModifierFlags = []) {
        updateTimelineSelection(id.map(TimelineSelectionKey.audio), modifiers: modifiers)
    }

    func selectTelemetryItem(_ id: UUID?, modifiers: NSEvent.ModifierFlags = []) {
        updateTimelineSelection(id.map(TimelineSelectionKey.telemetry), modifiers: modifiers)
    }

    func selectEffectTimelineItem(_ id: UUID?, modifiers: NSEvent.ModifierFlags = []) {
        updateTimelineSelection(id.map(TimelineSelectionKey.effect), modifiers: modifiers)
    }

    func selectEffectTimelineItems(
        _ ids: [UUID],
        primaryID: UUID,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        let validIDs = Set(ids.filter { id in
            timeline?.effectiveEffects.contains(where: { $0.id == id }) == true
        })
        guard validIDs.contains(primaryID) else { return }
        guard validIDs.count > 1 else {
            selectEffectTimelineItem(primaryID, modifiers: modifiers)
            return
        }

        let primary = TimelineSelectionKey.effect(primaryID)
        let group = Set(validIDs.map(TimelineSelectionKey.effect))
        let flags = modifiers.intersection([.command, .shift])
        if flags.contains(.shift) {
            updateTimelineSelection(primary, modifiers: flags)
            var selection = currentTimelineSelection
            if selection.contains(primary) { selection.formUnion(group) }
            applyTimelineSelection(selection, active: primary)
        } else if flags.contains(.command) {
            var selection = currentTimelineSelection
            if group.isSubset(of: selection) { selection.subtract(group) }
            else { selection.formUnion(group) }
            timelineSelectionAnchor = primary
            applyTimelineSelection(selection, active: selection.contains(primary) ? primary : selection.first)
        } else {
            timelineSelectionAnchor = primary
            applyTimelineSelection(group, active: primary)
        }
    }

    func selectTitleTimelineItem(_ id: UUID?, modifiers: NSEvent.ModifierFlags = []) {
        updateTimelineSelection(id.map(TimelineSelectionKey.title), modifiers: modifiers)
    }

    func selectTransitionTimelineItem(_ id: UUID?, modifiers: NSEvent.ModifierFlags = []) {
        updateTimelineSelection(id.map(TimelineSelectionKey.transition), modifiers: modifiers)
    }

    func insertTelemetryPreset(
        kind: TelemetryWidgetKind,
        presentation: TelemetryWidgetPresentation,
        style: TelemetryWidgetStyle,
        targetClipID: UUID? = nil,
        at time: Double? = nil,
        normalizedPosition: CGPoint? = nil
    ) {
        guard let pipeline else { return }
        let targetClip = targetClipID.flatMap { id in timeline?.items.first(where: { $0.id == id }) }
            ?? time.flatMap { telemetryClip(at: $0) }
            ?? telemetryTargetClip
        guard let targetClip, targetClip.kind == .video else {
            errorMessage = "Выберите видеофрагмент с телеметрией."
            return
        }
        guard let assetID = targetClip.assetID,
              let summary = TelemetrySourceSelector().bestSource(
                for: kind,
                linkedAssetID: assetID,
                sources: project?.effectiveTelemetrySources ?? []
              )?.summary ?? project?.analyses.first(where: { $0.assetID == assetID })?.telemetry,
              summary.supports(kind, presentation: presentation) else {
            errorMessage = "В этом видео нет данных для «\(kind.localizedTitle)»."
            return
        }
        var layout = TelemetryWidgetLayout.presetLayout(kind: kind, presentation: presentation)
        if let point = normalizedPosition {
            layout.x = min(max(0, point.x - layout.width / 2), 1 - layout.width)
            layout.y = min(max(0, point.y - layout.height / 2), 1 - layout.height)
        }
        let settings = TelemetryOverlaySettings(
            metrics: kind.metric.map { [$0] } ?? [],
            style: style,
            widgets: [layout]
        )
        editTimeline("Добавляю \(kind.localizedTitle) · \(presentation.localizedTitle)") {
            if let id = try await pipeline.addTelemetryItem(attachedTo: targetClip.id, settings: settings) {
                self.selectTelemetryItem(id)
            } else {
                self.errorMessage = "У фрагмента «\(targetClip.title ?? "Видео")» нет телеметрии."
            }
        }
    }

    private func telemetryClip(at timelineTime: Double) -> TimelineItem? {
        let active = timeline?.items.filter {
            $0.kind == .video && $0.assetID != nil &&
            timelineTime >= $0.timelineStart && timelineTime < $0.timelineStart + $0.timelineDuration
        } ?? []
        return active.last(where: { $0.overlay != nil }) ?? active.first(where: { $0.overlay == nil }) ?? active.last
    }

    func moveTelemetryItem(_ id: UUID, toTimelineStart time: Double) {
        editTimelineOptimistically("Перемещаю слой телеметрии") {
            TimelineMutationEngine.updateTelemetry(in: &$0, id: id) { $0.timelineStart = time }
        }
    }

    func trimTelemetryItem(_ id: UUID, timelineStart: Double, duration: Double, sourceStart: Double) {
        editTimelineOptimistically("Меняю границы телеметрии") { timeline in
            TimelineMutationEngine.updateTelemetry(in: &timeline, id: id) {
                $0.sourceStart = sourceStart
                $0.timelineStart = timelineStart
                $0.timelineDuration = duration
            }
        }
    }

    func setSelectedTelemetryDuration(_ duration: Double) {
        guard let item = selectedTelemetryItem else { return }
        editTimelineOptimistically("Меняю длительность телеметрии") {
            TimelineMutationEngine.updateTelemetry(in: &$0, id: item.id) { $0.timelineDuration = duration }
        }
    }

    func setSelectedTelemetryOffset(_ offset: Double) {
        guard let item = selectedTelemetryItem else { return }
        editTimelineOptimistically("Синхронизирую телеметрию") {
            TimelineMutationEngine.updateTelemetry(in: &$0, id: item.id) { $0.syncOffset = offset }
        }
    }

    func attachTelemetrySourceToSelectedClip(_ sourceID: UUID) {
        guard let pipeline,
              let assetID = telemetryTargetClip?.assetID,
              let asset = project?.assets.first(where: { $0.id == assetID }),
              var source = project?.effectiveTelemetrySources.first(where: { $0.id == sourceID }) else {
            errorMessage = "Выберите видеофрагмент для привязки телеметрии."
            return
        }
        source.linkedAssetID = assetID
        let synchronization = TelemetryEngine().synchronize(source: source, with: asset)
        run("Привязываю источник телеметрии") {
            try await pipeline.updateTelemetrySource(
                id: sourceID,
                linkedAssetID: assetID,
                updateLinkedAsset: true,
                synchronization: synchronization
            )
            await self.refresh()
            await self.rebuildPlaybackIfPossible(show: false)
            self.status = "Телеметрия привязана и синхронизирована с видео"
        }
    }

    func automaticallySynchronizeTelemetrySource(_ sourceID: UUID) {
        guard let pipeline,
              let source = project?.effectiveTelemetrySources.first(where: { $0.id == sourceID }),
              let assetID = source.linkedAssetID ?? telemetryTargetClip?.assetID,
              let asset = project?.assets.first(where: { $0.id == assetID }) else {
            errorMessage = "Сначала привяжите источник к видеофрагменту."
            return
        }
        let synchronization = TelemetryEngine().synchronize(source: source, with: asset)
        run("Автоматически синхронизирую телеметрию") {
            try await pipeline.updateTelemetrySource(
                id: sourceID,
                linkedAssetID: assetID,
                updateLinkedAsset: true,
                synchronization: synchronization
            )
            await self.refresh()
            await self.rebuildPlaybackIfPossible(show: false)
            self.status = "Синхронизация: \(synchronization.method.localizedTitle), точность \(Int(synchronization.confidence * 100))%"
        }
    }

    func setTelemetrySourceOffset(_ sourceID: UUID, offset: Double) {
        guard let pipeline,
              let source = project?.effectiveTelemetrySources.first(where: { $0.id == sourceID }) else { return }
        let synchronization = TelemetrySynchronization(
            offsetSeconds: offset,
            method: .manualOffset,
            confidence: 1,
            frameRate: source.synchronization.frameRate
        )
        run("Меняю смещение источника") {
            try await pipeline.updateTelemetrySource(id: sourceID, synchronization: synchronization)
            await self.refresh()
            await self.rebuildPlaybackIfPossible(show: false)
            self.status = "Ручное смещение телеметрии: \(String(format: "%+.3f", offset)) с"
        }
    }

    func applyCSVTelemetryMapping(_ sourceID: UUID, mapping: [String: TelemetryCSVField]) {
        guard let pipeline else { return }
        run("Сопоставляю столбцы CSV") {
            try await pipeline.applyCSVTelemetryMapping(id: sourceID, mapping: mapping)
            await self.refresh()
            await self.rebuildPlaybackIfPossible(show: false)
            self.status = "Столбцы CSV сопоставлены; исходные custom fields сохранены"
        }
    }

    func setSelectedTelemetryStyle(_ style: TelemetryWidgetStyle) {
        updateSelectedTelemetrySettings("Меняю стиль телеметрии") { $0.style = style }
    }

    func setSelectedTelemetryOpacity(_ opacity: Double) {
        updateSelectedTelemetrySettings("Меняю прозрачность телеметрии") { $0.opacity = min(max(0, opacity), 1) }
    }

    func setSelectedTelemetryWidget(_ kind: TelemetryWidgetKind) {
        updateSelectedTelemetrySettings("Меняю виджет телеметрии") { settings in
            let previous = settings.resolvedWidgets.first
            var layout = TelemetryWidgetLayout.presetLayout(kind: kind, presentation: kind.defaultPresentation)
            if let previous {
                layout.x = previous.x
                layout.y = previous.y
                layout.width = previous.width
                layout.height = previous.height
                layout.opacity = previous.opacity
            }
            settings.widgets = [layout]
            if let metric = kind.metric { settings.metrics = [metric] }
        }
    }

    func setSelectedTelemetryPresentation(_ presentation: TelemetryWidgetPresentation) {
        updateSelectedTelemetrySettings("Меняю вариант виджета") { settings in
            var widgets = settings.widgets ?? settings.resolvedWidgets
            guard !widgets.isEmpty else { return }
            widgets[0].presentation = presentation
            settings.widgets = widgets
        }
    }

    func changeSelectedTelemetryLayout(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        updateSelectedTelemetrySettings("Размещаю виджет телеметрии") { settings in
            var widgets = settings.widgets ?? settings.resolvedWidgets
            guard !widgets.isEmpty else { return }
            widgets[0].x = min(max(0, widgets[0].x + x), 1)
            widgets[0].y = min(max(0, widgets[0].y + y), 1)
            widgets[0].width = min(max(0.08, widgets[0].width + width), 1)
            widgets[0].height = min(max(0.06, widgets[0].height + height), 1)
            settings.widgets = widgets
        }
    }

    func setSelectedTelemetryLayoutFrame(x: Double, y: Double, width: Double, height: Double) {
        updateSelectedTelemetrySettings("Размещаю виджет на кадре") { settings in
            var widgets = settings.widgets ?? settings.resolvedWidgets
            guard !widgets.isEmpty else { return }
            widgets[0].width = min(max(0.08, width), 1)
            widgets[0].height = min(max(0.06, height), 1)
            widgets[0].x = min(max(0, x), 1 - widgets[0].width)
            widgets[0].y = min(max(0, y), 1 - widgets[0].height)
            settings.widgets = widgets
        }
    }

    func duplicateSelectedTelemetryItem() {
        guard let pipeline, let item = selectedTelemetryItem else { return }
        editTimeline("Дублирую слой телеметрии") {
            if let id = try await pipeline.duplicateTelemetryItem(id: item.id) { self.selectTelemetryItem(id) }
        }
    }

    func copySelectedTelemetrySettings() {
        guard let item = selectedTelemetryItem else { return }
        copiedTelemetrySettings = item.settings
        status = "Настройки телеметрии скопированы"
    }

    func pasteSelectedTelemetrySettings() {
        guard let settings = copiedTelemetrySettings else { return }
        updateSelectedTelemetrySettings("Вставляю настройки телеметрии") { $0 = settings }
    }

    var canPasteTelemetrySettings: Bool { copiedTelemetrySettings != nil }

    private func updateSelectedTelemetrySettings(_ status: String, mutation: @escaping (inout TelemetryOverlaySettings) -> Void) {
        guard let item = selectedTelemetryItem else { return }
        editTimelineOptimistically(status) {
            TimelineMutationEngine.updateTelemetry(in: &$0, id: item.id) { mutation(&$0.settings) }
        }
    }

    // MARK: Independent effects, titles and transitions

    func addTimelineEffect(_ type: TimelineEffectType, at requestedTime: Double? = nil) {
        guard let pipeline, let timeline else { return }
        let target = requestedTime == nil ? selectedTimelineItem : nil
        let start = min(max(0, requestedTime ?? target?.timelineStart ?? timelinePlayheadTime), max(0, timeline.duration - 0.05))
        let duration = min(target?.timelineDuration ?? 2, max(0.25, timeline.duration - start))
        editTimeline("Добавляю эффект на Timeline") {
            let preset = EffectPresetRegistry.preset(for: type)
            if let id = try await pipeline.addEffectTimelineItem(
                type: type,
                startTime: start,
                duration: duration,
                targetClipID: target?.id,
                parameters: preset.defaultParameters,
                explanation: [
                    "Пользователь добавил отдельный эффект \(type.localizedTitle)",
                    "Renderer: native Core Image; объект остаётся редактируемым на Timeline"
                ]
            ) {
                self.selectEffectTimelineItem(id)
            }
        }
    }

    func applyEffectStackPreset(_ presetID: String, at requestedTime: Double? = nil) {
        guard let preset = EffectStackPresetRegistry.preset(id: presetID), let timeline else { return }
        let target = selectedTimelineItem
        let start = min(max(0, requestedTime ?? target?.timelineStart ?? timelinePlayheadTime), max(0, timeline.duration - 0.05))
        let duration = min(target?.timelineDuration ?? 3, max(0.05, timeline.duration - start))
        var createdIDs: [UUID] = []
        editTimelineOptimistically("Применяю пресет \(preset.name)") {
            createdIDs = EffectStackPresetRegistry.apply(
                preset,
                to: &$0,
                targetClipID: target?.id,
                startTime: start,
                duration: duration,
                explanation: "Пользователь применил пресет \(preset.name)"
            )
            return !createdIDs.isEmpty
        }
        if let id = createdIDs.first {
            selectEffectTimelineItems(createdIDs, primaryID: id)
        }
    }

    func addTimelineTransition(_ style: TransitionStyle, at requestedTime: Double? = nil) {
        guard let pipeline, let timeline else { return }
        let primary = timeline.items.filter { $0.overlay == nil }.sorted { $0.timelineStart < $1.timelineStart }
        guard primary.count > 1 else { return }
        let incomingIndex: Int? = {
            if let selected = selectedTimelineItem,
               let index = primary.firstIndex(where: { $0.id == selected.id }), index > 0 { return index }
            let targetTime = requestedTime ?? timelinePlayheadTime
            return primary.indices.dropFirst().min { lhs, rhs in
                abs(primary[lhs].timelineStart - targetTime) < abs(primary[rhs].timelineStart - targetTime)
            }
        }()
        guard let incomingIndex else { return }
        let incoming = primary[incomingIndex]
        let outgoing = primary[incomingIndex - 1]
        if style == .cut {
            editTimeline("Возвращаю прямую склейку") {
                if let existing = timeline.effectiveTransitionItems.first(where: { $0.incomingClipID == incoming.id }) {
                    try await pipeline.deleteTransitionTimelineItem(id: existing.id)
                } else {
                    try await pipeline.updateTimelineItem(id: incoming.id, transition: nil, updateTransition: true)
                }
            }
            return
        }
        let preset = TransitionPresetRegistry.preset(for: style)
        editTimeline("Добавляю переход на Timeline") {
            if let id = try await pipeline.addTransitionTimelineItem(
                style: style,
                outgoingClipID: outgoing.id,
                incomingClipID: incoming.id,
                duration: preset.defaultDuration,
                explanation: [
                    "Пользователь добавил \(style.localizedTitle)",
                    "Переход — обычный объект Timeline; Preview и Export используют общий renderer"
                ]
            ) {
                self.selectTransitionTimelineItem(id)
            }
        }
    }

    func moveEffectTimelineItem(_ id: UUID, to time: Double) {
        editTimelineOptimistically("Перемещаю эффект") {
            TimelineMutationEngine.updateEffect(in: &$0, id: id) { $0.startTime = time }
        }
    }

    func moveEffectTimelineItems(_ ids: [UUID], primaryID: UUID, to time: Double) {
        guard let primary = timeline?.effectiveEffects.first(where: { $0.id == primaryID }) else { return }
        let effectIDs = Set(ids)
        let delta = time - primary.startTime
        editTimelineOptimistically("Перемещаю пресет эффектов") { timeline in
            var changed = false
            for id in effectIDs {
                guard let item = timeline.effectiveEffects.first(where: { $0.id == id }) else { continue }
                changed = TimelineMutationEngine.updateEffect(in: &timeline, id: id) {
                    $0.startTime = item.startTime + delta
                } || changed
            }
            return changed
        }
    }

    func trimEffectTimelineItem(_ id: UUID, startTime: Double, duration: Double) {
        editTimelineOptimistically("Меняю границы эффекта") { timeline in
            TimelineMutationEngine.updateEffect(in: &timeline, id: id) {
                $0.startTime = startTime
                $0.duration = duration
            }
        }
    }

    func trimEffectTimelineItems(_ ids: [UUID], startTime: Double, duration: Double) {
        let effectIDs = Set(ids)
        editTimelineOptimistically("Меняю границы пресета эффектов") { timeline in
            var changed = false
            for id in effectIDs {
                changed = TimelineMutationEngine.updateEffect(in: &timeline, id: id) {
                    $0.startTime = startTime
                    $0.duration = duration
                } || changed
            }
            return changed
        }
    }

    func setSelectedEffectDuration(_ duration: Double) {
        guard let item = selectedEffectTimelineItem else { return }
        editTimelineOptimistically("Меняю длительность эффекта") {
            TimelineMutationEngine.updateEffect(in: &$0, id: item.id) { $0.duration = duration }
        }
    }

    func setSelectedEffectIntensity(_ intensity: Double) {
        guard let item = selectedEffectTimelineItem else { return }
        editTimelineOptimistically("Меняю интенсивность эффекта") {
            TimelineMutationEngine.updateEffect(in: &$0, id: item.id) { $0.intensity = intensity }
        }
    }

    func setSelectedEffectParameter(_ name: String, value: Double) {
        guard let item = selectedEffectTimelineItem else { return }
        guard let descriptor = EffectPresetRegistry.preset(for: item.effectType).parameter(named: name), descriptor.key != "intensity" else { return }
        var parameters = item.parameters.filter { $0.name != name }
        parameters.append(descriptor.parameter(value: value))
        editTimelineOptimistically("Меняю параметр эффекта") {
            TimelineMutationEngine.updateEffect(in: &$0, id: item.id) { $0.parameters = parameters }
        }
    }

    func setSelectedEffectEnabled(_ enabled: Bool) {
        guard let item = selectedEffectTimelineItem else { return }
        editTimelineOptimistically(enabled ? "Включаю эффект" : "Выключаю эффект") {
            TimelineMutationEngine.updateEffect(in: &$0, id: item.id) { $0.enabled = enabled }
        }
    }

    func setEffectTimelineItemsEnabled(_ ids: [UUID], enabled: Bool) {
        let effectIDs = Set(ids)
        editTimelineOptimistically(enabled ? "Включаю пресет эффектов" : "Выключаю пресет эффектов") { timeline in
            var changed = false
            for id in effectIDs {
                changed = TimelineMutationEngine.updateEffect(in: &timeline, id: id) {
                    $0.enabled = enabled
                } || changed
            }
            return changed
        }
    }

    func addSelectedEffectKeyframe(parameter: String = "intensity", easing: KeyframeEasing = .easeInOut) {
        guard let item = selectedEffectTimelineItem else { return }
        guard let descriptor = EffectPresetRegistry.preset(for: item.effectType).parameter(named: parameter), descriptor.supportsKeyframes else { return }
        let local = min(max(0, timelinePlayheadTime - item.startTime), item.duration)
        let value = parameter == "intensity" ? item.intensity : (item.parameters.first(where: { $0.name == parameter })?.effectiveNumericValue ?? descriptor.defaultValue)
        var keyframes = item.keyframes.filter { !($0.parameter == parameter && abs($0.time - local) < 0.001) }
        keyframes.append(EffectKeyframe(
            parameter: parameter,
            time: local,
            value: value,
            easing: easing,
            typedValue: EffectParameterValue.scalar(value, as: descriptor.valueType)
        ))
        editTimelineOptimistically("Добавляю keyframe") {
            TimelineMutationEngine.updateEffect(in: &$0, id: item.id) { $0.keyframes = keyframes }
        }
    }

    func removeSelectedEffectKeyframe(_ keyframeID: UUID) {
        guard let item = selectedEffectTimelineItem else { return }
        let keyframes = item.keyframes.filter { $0.id != keyframeID }
        editTimelineOptimistically("Удаляю keyframe") {
            TimelineMutationEngine.updateEffect(in: &$0, id: item.id) { $0.keyframes = keyframes }
        }
    }

    func setSelectedEffectKeyframeEasing(_ keyframeID: UUID, easing: KeyframeEasing) {
        guard let item = selectedEffectTimelineItem else { return }
        var keyframes = item.keyframes
        guard let index = keyframes.firstIndex(where: { $0.id == keyframeID }) else { return }
        keyframes[index].easing = easing
        editTimelineOptimistically("Меняю easing keyframe") {
            TimelineMutationEngine.updateEffect(in: &$0, id: item.id) { $0.keyframes = keyframes }
        }
    }

    func setSelectedEffectKeyframe(_ keyframeID: UUID, time: Double? = nil, value: Double? = nil) {
        guard let item = selectedEffectTimelineItem else { return }
        var keyframes = item.keyframes
        guard let index = keyframes.firstIndex(where: { $0.id == keyframeID }),
              let descriptor = EffectPresetRegistry.preset(for: item.effectType).parameter(named: keyframes[index].parameter) else { return }
        if let time { keyframes[index].time = min(max(0, time), item.duration) }
        if let value {
            let clamped = min(max(descriptor.range.lowerBound, value), descriptor.range.upperBound)
            keyframes[index].value = clamped
            keyframes[index].typedValue = EffectParameterValue.scalar(clamped, as: descriptor.valueType)
        }
        editTimelineOptimistically("Редактирую keyframe") {
            TimelineMutationEngine.updateEffect(in: &$0, id: item.id) { $0.keyframes = keyframes }
        }
    }

    func copySelectedEffectKeyframe(_ keyframeID: UUID) {
        guard let keyframe = selectedEffectTimelineItem?.keyframes.first(where: { $0.id == keyframeID }) else { return }
        copiedEffectKeyframe = keyframe
        status = "Keyframe скопирован"
    }

    func pasteSelectedEffectKeyframe() {
        guard let item = selectedEffectTimelineItem, var keyframe = copiedEffectKeyframe else { return }
        guard let descriptor = EffectPresetRegistry.preset(for: item.effectType).parameter(named: keyframe.parameter), descriptor.supportsKeyframes else { return }
        keyframe.id = UUID()
        keyframe.time = min(max(0, timelinePlayheadTime - item.startTime), item.duration)
        var keyframes = item.keyframes.filter { !($0.parameter == keyframe.parameter && abs($0.time - keyframe.time) < 0.001) }
        keyframes.append(keyframe)
        editTimelineOptimistically("Вставляю keyframe") {
            TimelineMutationEngine.updateEffect(in: &$0, id: item.id) { $0.keyframes = keyframes }
        }
    }

    var canPasteEffectKeyframe: Bool { copiedEffectKeyframe != nil }

    func moveSelectedEffectInStack(_ offset: Int) {
        guard let timeline, let item = selectedEffectTimelineItem else { return }
        let stack = EffectStackEngine.stack(in: timeline, for: item.targetClipID)
        guard let index = stack.firstIndex(where: { $0.id == item.id }) else { return }
        editTimelineOptimistically("Меняю порядок эффектов") {
            TimelineMutationEngine.reorderEffect(in: &$0, id: item.id, toIndex: index + offset)
        }
    }

    func duplicateSelectedEffectTimelineItem() {
        guard let pipeline, let item = selectedEffectTimelineItem else { return }
        editTimeline("Дублирую эффект") {
            if let id = try await pipeline.duplicateEffectTimelineItem(id: item.id) { self.selectEffectTimelineItem(id) }
        }
    }

    func copySelectedEffectTimelineItem() {
        guard let item = selectedEffectTimelineItem else { return }
        copiedEffectTimelineItem = item
        status = "Эффект скопирован"
    }

    func pasteEffectTimelineItem(at time: Double? = nil) {
        guard let pipeline, let source = copiedEffectTimelineItem, let timeline else { return }
        let start = min(max(0, time ?? timelinePlayheadTime), max(0, timeline.duration - 0.05))
        let target = source.targetClipID.flatMap { id in timeline.items.contains(where: { $0.id == id }) ? id : nil }
        editTimeline("Вставляю эффект") {
            guard let id = try await pipeline.addEffectTimelineItem(
                type: source.effectType,
                startTime: start,
                duration: source.duration,
                targetClipID: target,
                intensity: source.intensity,
                explanation: source.explanation + ["Скопировано и вставлено пользователем"]
            ) else { return }
            try await pipeline.updateEffectTimelineItem(
                id: id,
                enabled: source.enabled,
                parameters: source.parameters,
                keyframes: source.keyframes
            )
            self.selectEffectTimelineItem(id)
        }
    }

    var canPasteEffectTimelineItem: Bool { copiedEffectTimelineItem != nil }

    func addModernTitle(_ text: String, kind: TitleTimelineKind, at time: Double? = nil) {
        let templateID = TitleTemplateRegistry.defaultTemplate(for: kind)?.id
        addModernTitle(text, templateID: templateID, fallbackKind: kind, at: time)
    }

    func addModernTitle(_ text: String, templateID: String?, fallbackKind: TitleTimelineKind = .title, at time: Double? = nil) {
        guard let pipeline, let timeline else { return }
        let template = TitleTemplateRegistry.template(id: templateID)
        let kind = template?.kind ?? fallbackKind
        let start = min(max(0, time ?? timelinePlayheadTime), max(0, timeline.duration - 0.05))
        let preferredDuration = template?.duration ?? (kind == .titleCard || kind == .endCard ? 4.5 : 3.2)
        let duration = min(preferredDuration, max(0.25, timeline.duration - start))
        let words: [CaptionWord]
        if kind.category == .captions {
            let values = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let step = duration / Double(max(1, values.count))
            words = values.enumerated().map { index, word in
                CaptionWord(word: word, start: Double(index) * step, end: Double(index + 1) * step)
            }
        } else {
            words = []
        }
        editTimeline("Добавляю редактируемый титр") {
            if let id = try await pipeline.addTitleTimelineItem(
                kind: kind,
                templateID: template?.id,
                text: text,
                additionalText: template?.preview.secondaryText,
                callToAction: template?.preview.callToAction,
                startTime: start,
                duration: duration,
                words: words,
                explanation: ["Пользователь добавил (kind.localizedTitle)"]
            ) {
                self.selectTitleTimelineItem(id)
            }
        }
    }

    func moveTitleTimelineItem(_ id: UUID, to time: Double) {
        editTimelineOptimistically("Перемещаю титр") {
            TimelineMutationEngine.updateTitle(in: &$0, id: id) { $0.startTime = time }
        }
    }

    func trimTitleTimelineItem(_ id: UUID, startTime: Double, duration: Double) {
        editTimelineOptimistically("Меняю границы титра") { timeline in
            TimelineMutationEngine.updateTitle(in: &timeline, id: id) {
                $0.startTime = startTime
                $0.duration = duration
            }
        }
    }

    func setSelectedModernTitleText(_ text: String) {
        guard let item = selectedTitleTimelineItem else { return }
        editTimelineOptimistically("Меняю текст титра") {
            TimelineMutationEngine.updateTitle(in: &$0, id: item.id) { $0.text = text }
        }
    }

    func setSelectedModernTitleAdditionalText(_ text: String) {
        guard let item = selectedTitleTimelineItem else { return }
        editTimelineOptimistically("Меняю подзаголовок карточки") {
            TimelineMutationEngine.updateTitle(in: &$0, id: item.id) { $0.additionalText = text }
        }
    }

    func setSelectedModernTitleCallToAction(_ text: String) {
        guard let item = selectedTitleTimelineItem else { return }
        editTimelineOptimistically("Меняю кнопку карточки") {
            TimelineMutationEngine.updateTitle(in: &$0, id: item.id) { $0.callToAction = text }
        }
    }

    func setSelectedModernTitleCardDetails(additionalText: String, callToAction: String) {
        guard let item = selectedTitleTimelineItem else { return }
        editTimelineOptimistically("Меняю содержимое карточки") {
            TimelineMutationEngine.updateTitle(in: &$0, id: item.id) {
                $0.additionalText = additionalText
                $0.callToAction = callToAction
            }
        }
    }

    func setSelectedModernTitleDuration(_ duration: Double) {
        guard let item = selectedTitleTimelineItem else { return }
        editTimelineOptimistically("Меняю длительность титра") {
            TimelineMutationEngine.updateTitle(in: &$0, id: item.id) { $0.duration = duration }
        }
    }

    func setSelectedModernTitleStyle(_ style: TitleStyle) {
        guard let item = selectedTitleTimelineItem else { return }
        editTimelineOptimistically("Обновляю оформление титра") {
            TimelineMutationEngine.updateTitle(in: &$0, id: item.id) { $0.style = style }
        }
    }

    func setSelectedModernTitleTemplate(_ templateID: String) {
        guard let item = selectedTitleTimelineItem,
              let template = TitleTemplateRegistry.template(id: templateID) else { return }
        editTimelineOptimistically("Меняю шаблон титра") {
            TimelineMutationEngine.updateTitle(in: &$0, id: item.id) {
                $0.templateID = template.id
                $0.kind = template.kind
                $0.style = template.defaultStyle
                if $0.additionalText?.isEmpty != false { $0.additionalText = template.preview.secondaryText }
                if $0.callToAction?.isEmpty != false { $0.callToAction = template.preview.callToAction }
                $0.explanation.append("Пользователь выбрал Title Template \(template.name)")
            }
        }
    }

    func setSelectedModernTitleAnimation(_ animation: TitleAnimation) {
        guard let item = selectedTitleTimelineItem else { return }
        editTimelineOptimistically("Обновляю анимацию титра") {
            TimelineMutationEngine.updateTitle(in: &$0, id: item.id) { $0.animation = animation }
        }
    }

    func editSelectedTitleWithAI(_ instruction: String) {
        guard selectedTitleTimelineItem != nil else { return }
        let text = instruction.lowercased()
        let templateID: String
        if text.contains("кинемат") { templateID = "title.cinematic.v1" }
        else if text.contains("динами") || text.contains("спорт") || text.contains("экшен") { templateID = "title.dynamic.v1" }
        else if text.contains("элегант") || text.contains("нежн") { templateID = "title.elegant.v1" }
        else if text.contains("жирн") || text.contains("ярк") { templateID = "title.bold.v1" }
        else if text.contains("путеш") || text.contains("travel") { templateID = "title.travel.v1" }
        else if text.contains("мест") || text.contains("локац") { templateID = "title.location.v1" }
        else if text.contains("глав") || text.contains("chapter") { templateID = "title.chapter.v1" }
        else { templateID = "title.minimal-clean.v1" }
        setSelectedModernTitleTemplate(templateID)
    }

    func setSelectedTransitionDuration(_ duration: Double) {
        guard let pipeline, let item = selectedTransitionTimelineItem else { return }
        editTimeline("Меняю длительность перехода") { try await pipeline.updateTransitionTimelineItem(id: item.id, duration: duration) }
    }

    func setSelectedTransitionStyle(_ style: TransitionStyle) {
        guard let pipeline, let item = selectedTransitionTimelineItem else { return }
        if style == .cut {
            editTimeline("Возвращаю прямую склейку") { try await pipeline.deleteTransitionTimelineItem(id: item.id) }
            return
        }
        editTimeline("Меняю тип перехода") { try await pipeline.updateTransitionTimelineItem(id: item.id, style: style) }
    }

    func setSelectedTransitionEnabled(_ enabled: Bool) {
        guard let pipeline, let item = selectedTransitionTimelineItem else { return }
        editTimeline(enabled ? "Включаю переход" : "Выключаю переход") {
            try await pipeline.updateTransitionTimelineItem(id: item.id, enabled: enabled)
        }
    }

    func setSelectedTransitionIntensity(_ intensity: Double) {
        guard let pipeline, let item = selectedTransitionTimelineItem else { return }
        editTimeline("Меняю интенсивность перехода") {
            try await pipeline.updateTransitionTimelineItem(id: item.id, intensity: intensity)
        }
    }

    func setSelectedTransitionParameter(_ name: String, value: Double) {
        guard let pipeline, let item = selectedTransitionTimelineItem else { return }
        var parameters = item.effectiveParameters.filter { $0.name != name }
        parameters.append(EffectParameter(name: name, value: value))
        editTimeline("Меняю параметр перехода") {
            try await pipeline.updateTransitionTimelineItem(id: item.id, parameters: parameters)
        }
    }

    func setSelectedTransitionDirection(_ direction: TransitionDirection) {
        guard let pipeline, let item = selectedTransitionTimelineItem else { return }
        editTimeline("Меняю направление перехода") {
            try await pipeline.updateTransitionTimelineItem(id: item.id, direction: direction)
        }
    }

    func setSelectedTransitionEasing(_ easing: KeyframeEasing) {
        guard let pipeline, let item = selectedTransitionTimelineItem else { return }
        editTimeline("Меняю easing перехода") {
            try await pipeline.updateTransitionTimelineItem(id: item.id, easing: easing)
        }
    }

    func deleteSelectedTimelineObject() {
        deleteTimelineSelection()
    }

    func selectSoundtrack() {
        guard timeline?.music != nil else { return }
        updateTimelineSelection(.soundtrack, modifiers: NSEvent.modifierFlags)
    }

    func clearTimelineSelection() {
        selectedTimelineItemIDs.removeAll()
        selectedTimelineAudioClipIDs.removeAll()
        selectedTelemetryItemIDs.removeAll()
        selectedEffectTimelineItemIDs.removeAll()
        selectedTitleTimelineItemIDs.removeAll()
        selectedTransitionTimelineItemIDs.removeAll()
        selectedTimelineItemID = nil
        selectedTimelineAudioClipID = nil
        selectedTelemetryItemID = nil
        selectedEffectTimelineItemID = nil
        selectedTitleTimelineItemID = nil
        selectedTransitionTimelineItemID = nil
        selectedSoundtrack = false
        timelineSelectionAnchor = nil
    }

    func selectAllTimelineElements() {
        guard let timeline else { return }
        selectedTimelineItemIDs = Set(timeline.items.map(\.id))
        selectedTimelineAudioClipIDs = Set(timeline.effectiveAudioClips.map(\.id))
        selectedTelemetryItemIDs = Set(timeline.effectiveTelemetryItems.map(\.id))
        selectedEffectTimelineItemIDs = Set(timeline.effectiveEffects.map(\.id))
        selectedTitleTimelineItemIDs = Set(timeline.effectiveTitleItems.map(\.id))
        selectedTransitionTimelineItemIDs = Set(timeline.effectiveTransitionItems.map(\.id))
        selectedSoundtrack = timeline.music != nil
        selectedTimelineItemID = timeline.items.first?.id
        selectedTimelineAudioClipID = nil
        selectedTelemetryItemID = nil
        selectedEffectTimelineItemID = nil
        selectedTitleTimelineItemID = nil
        selectedTransitionTimelineItemID = nil
        timelineSelectionAnchor = orderedTimelineSelectionKeys().first
    }

    private func updateTimelineSelection(_ key: TimelineSelectionKey?, modifiers: NSEvent.ModifierFlags) {
        guard let key else { clearTimelineSelection(); return }
        let flags = modifiers.intersection([.command, .shift])
        var selection = currentTimelineSelection
        if flags.contains(.shift), let anchor = timelineSelectionAnchor {
            let ordered = orderedTimelineSelectionKeys().filter { selectionKind($0) == selectionKind(key) }
            if let start = ordered.firstIndex(of: anchor), let end = ordered.firstIndex(of: key) {
                if !flags.contains(.command) { selection.removeAll() }
                selection.formUnion(ordered[min(start, end)...max(start, end)])
            } else {
                selection = [key]
            }
        } else if flags.contains(.command) {
            if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
            timelineSelectionAnchor = key
        } else {
            selection = [key]
            timelineSelectionAnchor = key
        }
        applyTimelineSelection(selection, active: selection.contains(key) ? key : selection.first)
    }

    private func applyTimelineSelection(_ selection: Set<TimelineSelectionKey>, active: TimelineSelectionKey?) {
        selectedTimelineItemIDs = Set(selection.compactMap { if case .item(let id) = $0 { id } else { nil } })
        selectedTimelineAudioClipIDs = Set(selection.compactMap { if case .audio(let id) = $0 { id } else { nil } })
        selectedTelemetryItemIDs = Set(selection.compactMap { if case .telemetry(let id) = $0 { id } else { nil } })
        selectedEffectTimelineItemIDs = Set(selection.compactMap { if case .effect(let id) = $0 { id } else { nil } })
        selectedTitleTimelineItemIDs = Set(selection.compactMap { if case .title(let id) = $0 { id } else { nil } })
        selectedTransitionTimelineItemIDs = Set(selection.compactMap { if case .transition(let id) = $0 { id } else { nil } })
        selectedTimelineItemID = active.flatMap { if case .item(let id) = $0 { id } else { nil } }
        selectedTimelineAudioClipID = active.flatMap { if case .audio(let id) = $0 { id } else { nil } }
        selectedTelemetryItemID = active.flatMap { if case .telemetry(let id) = $0 { id } else { nil } }
        selectedEffectTimelineItemID = active.flatMap { if case .effect(let id) = $0 { id } else { nil } }
        selectedTitleTimelineItemID = active.flatMap { if case .title(let id) = $0 { id } else { nil } }
        selectedTransitionTimelineItemID = active.flatMap { if case .transition(let id) = $0 { id } else { nil } }
        selectedSoundtrack = selection.contains(.soundtrack)
    }

    private func orderedTimelineSelectionKeys() -> [TimelineSelectionKey] {
        guard let timeline else { return [] }
        var values: [(Double, Int, TimelineSelectionKey)] = []
        values += timeline.items.map { ($0.timelineStart, 0, .item($0.id)) }
        values += timeline.effectiveTitleItems.map { ($0.startTime, 1, .title($0.id)) }
        values += timeline.effectiveEffects.map { ($0.startTime, 2, .effect($0.id)) }
        values += timeline.effectiveTelemetryItems.map { ($0.timelineStart, 3, .telemetry($0.id)) }
        values += timeline.effectiveAudioClips.map { ($0.timelineStart, 4, .audio($0.id)) }
        values += timeline.effectiveTransitionItems.map { ($0.startTime, 5, .transition($0.id)) }
        if timeline.music != nil { values.append((0, 6, .soundtrack)) }
        return values.sorted { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }.map(\.2)
    }

    private func selectionKind(_ key: TimelineSelectionKey) -> Int {
        switch key {
        case .item: return 0
        case .title: return 1
        case .effect: return 2
        case .telemetry: return 3
        case .audio: return 4
        case .transition: return 5
        case .soundtrack: return 6
        }
    }

    func copyTimelineSelection() {
        guard let clipboard = makeTimelineClipboard(), !clipboard.isEmpty else { return }
        timelineClipboard = clipboard
        status = "Скопировано элементов: \(currentTimelineSelection.count)"
    }

    func cutTimelineSelection() {
        guard let clipboard = makeTimelineClipboard(), !clipboard.isEmpty else { return }
        timelineClipboard = clipboard
        deleteTimelineSelection(status: "Вырезаю выбранные элементы")
    }

    func pasteTimelineSelection(at requestedTime: Double? = nil) {
        guard let pipeline, let timeline, let clipboard = timelineClipboard, !clipboard.isEmpty else { return }
        let position = min(max(0, requestedTime ?? timelinePlayheadTime), timeline.duration)
        let result = inserting(clipboard, into: timeline, at: position)
        editTimeline("Вставляю элементы в позицию playhead") {
            try await pipeline.replaceLatestTimeline(with: result.timeline)
            self.applyTimelineSelection(result.selection, active: result.active)
        }
    }

    func duplicateTimelineSelection() {
        guard let pipeline, let timeline, let clipboard = makeTimelineClipboard(), !clipboard.isEmpty else { return }
        let selectedEndTimes = clipboard.items.map { $0.timelineStart + $0.timelineDuration } +
            clipboard.audioClips.map(\.timelineEnd) + clipboard.telemetryItems.map(\.timelineEnd) +
            clipboard.effects.map(\.endTime) + clipboard.titles.map(\.endTime) +
            clipboard.transitions.map { $0.startTime + $0.duration }
        let position = min(max(0, selectedEndTimes.max() ?? timelinePlayheadTime), timeline.duration)
        let result = inserting(clipboard, into: timeline, at: position)
        editTimeline("Дублирую выбранные элементы") {
            try await pipeline.replaceLatestTimeline(with: result.timeline)
            self.applyTimelineSelection(result.selection, active: result.active)
        }
    }

    func deleteTimelineSelection(status initialStatus: String = "Удаляю выбранные элементы") {
        guard let pipeline, var updated = timeline, hasTimelineSelection else { return }
        let selection = currentTimelineSelection
        let removedClipIDs = Set(selection.compactMap { if case .item(let id) = $0 { id } else { nil } })
        let audioIDs = Set(selection.compactMap { if case .audio(let id) = $0 { id } else { nil } })
        let telemetryIDs = Set(selection.compactMap { if case .telemetry(let id) = $0 { id } else { nil } })
        let effectIDs = Set(selection.compactMap { if case .effect(let id) = $0 { id } else { nil } })
        let titleIDs = Set(selection.compactMap { if case .title(let id) = $0 { id } else { nil } })
        let transitionIDs = Set(selection.compactMap { if case .transition(let id) = $0 { id } else { nil } })
        let transitionIncomingClipIDs = Set(updated.effectiveTransitionItems.filter { transitionIDs.contains($0.id) }.map(\.incomingClipID))
        updated.items.removeAll { removedClipIDs.contains($0.id) }
        for index in updated.items.indices where transitionIncomingClipIDs.contains(updated.items[index].id) {
            updated.items[index].transition = nil
            updated.items[index].incomingEditDecision = EditorialBoundaryDecision(
                choice: .cut,
                motivation: "Переход удалён пользователем; восстановлена чистая склейка",
                confidence: 1
            )
        }
        updated.items = TimelineTiming.retimed(updated.items)
        updated.audioClips = updated.effectiveAudioClips.filter {
            !audioIDs.contains($0.id) && $0.attachedToItemID.map(removedClipIDs.contains) != true
        }
        updated.telemetryItems = updated.effectiveTelemetryItems.filter { !telemetryIDs.contains($0.id) }
        updated.effects = updated.effectiveEffects.filter {
            !effectIDs.contains($0.id) && $0.targetClipID.map(removedClipIDs.contains) != true
        }
        updated.titleItems = updated.effectiveTitleItems.filter {
            !titleIDs.contains($0.id) && $0.targetClipID.map(removedClipIDs.contains) != true
        }
        updated.transitionItems = updated.effectiveTransitionItems.filter {
            !transitionIDs.contains($0.id) && !removedClipIDs.contains($0.outgoingClipID) && !removedClipIDs.contains($0.incomingClipID)
        }
        if selection.contains(.soundtrack) { updated.music = nil }
        editTimeline(initialStatus) {
            try await pipeline.replaceLatestTimeline(with: updated)
            self.clearTimelineSelection()
        }
    }

    private func makeTimelineClipboard() -> TimelineClipboard? {
        guard let timeline else { return nil }
        let selection = currentTimelineSelection
        return TimelineClipboard(
            items: timeline.items.filter { selection.contains(.item($0.id)) },
            audioClips: timeline.effectiveAudioClips.filter { selection.contains(.audio($0.id)) },
            telemetryItems: timeline.effectiveTelemetryItems.filter { selection.contains(.telemetry($0.id)) },
            effects: timeline.effectiveEffects.filter { selection.contains(.effect($0.id)) },
            titles: timeline.effectiveTitleItems.filter { selection.contains(.title($0.id)) },
            transitions: timeline.effectiveTransitionItems.filter { selection.contains(.transition($0.id)) },
            soundtrack: selection.contains(.soundtrack) ? timeline.music : nil
        )
    }

    private func inserting(
        _ clipboard: TimelineClipboard,
        into source: Timeline,
        at requestedTime: Double
    ) -> (timeline: Timeline, selection: Set<TimelineSelectionKey>, active: TimelineSelectionKey?) {
        var result = source
        let insertionTime = TimelineTiming.quantized(min(max(0, requestedTime), source.duration), frameRate: source.frameRate)
        let referenceTime = clipboard.referenceTime
        var idMap: [UUID: UUID] = [:]
        var insertedSelection: Set<TimelineSelectionKey> = []
        let copiedPrimaries = clipboard.items.filter { $0.overlay == nil }
        let insertedDuration = copiedPrimaries.reduce(0) { $0 + $1.timelineDuration }

        if insertedDuration > 0 {
            result.audioClips = result.effectiveAudioClips.map { item in
                var item = item
                if item.timelineStart >= insertionTime { item.timelineStart += insertedDuration }
                return item
            }
            result.telemetryItems = result.effectiveTelemetryItems.map { item in
                var item = item
                if item.timelineStart >= insertionTime { item.timelineStart += insertedDuration }
                return item
            }
            result.effects = result.effectiveEffects.map { item in
                var item = item
                if item.startTime >= insertionTime { item.startTime += insertedDuration }
                return item
            }
            result.titleItems = result.effectiveTitleItems.map { item in
                var item = item
                if item.startTime >= insertionTime { item.startTime += insertedDuration }
                return item
            }
            result.transitionItems = result.effectiveTransitionItems.map { item in
                var item = item
                if item.startTime >= insertionTime { item.startTime += insertedDuration }
                return item
            }
        }

        let primaryCopies: [TimelineItem] = copiedPrimaries.map { original in
            var copy = original
            copy.id = UUID()
            copy.timelineStart = 0
            copy.explanation.append("Копия на Timeline")
            idMap[original.id] = copy.id
            insertedSelection.insert(.item(copy.id))
            return copy
        }

        if !primaryCopies.isEmpty {
            let primaryIndices = result.items.indices.filter { result.items[$0].overlay == nil }
            if let splitIndex = primaryIndices.first(where: {
                let item = result.items[$0]
                return insertionTime > item.timelineStart + 0.000_1 && insertionTime < item.timelineStart + item.timelineDuration - 0.000_1
            }) {
                let original = result.items[splitIndex]
                let leftDuration = insertionTime - original.timelineStart
                let rightDuration = original.timelineDuration - leftDuration
                let leftSourceDuration = original.sourceDuration * (leftDuration / max(0.000_1, original.timelineDuration))
                var left = original
                left.timelineDuration = leftDuration
                left.sourceDuration = leftSourceDuration
                var right = original
                right.id = UUID()
                right.sourceStart = original.sourceStart + leftSourceDuration
                right.sourceDuration = max(0, original.sourceDuration - leftSourceDuration)
                right.timelineDuration = rightDuration
                right.transition = nil
                result.items[splitIndex] = left
                result.items.insert(contentsOf: primaryCopies + [right], at: splitIndex + 1)
                for index in result.items.indices where result.items[index].overlay?.baseItemID == original.id && result.items[index].timelineStart >= insertionTime {
                    let connectedStart = result.items[index].timelineStart
                    result.items[index].overlay?.baseItemID = right.id
                    result.items[index].overlay?.startOffset = max(0, connectedStart - insertionTime)
                }
                result.audioClips = result.effectiveAudioClips.map { item in
                    var item = item
                    if item.attachedToItemID == original.id && item.timelineStart >= insertionTime + insertedDuration {
                        item.attachedToItemID = right.id
                    }
                    return item
                }
                result.effects = result.effectiveEffects.map { item in
                    var item = item
                    if item.targetClipID == original.id && item.startTime >= insertionTime + insertedDuration {
                        item.targetClipID = right.id
                    }
                    return item
                }
                result.titleItems = result.effectiveTitleItems.map { item in
                    var item = item
                    if item.targetClipID == original.id && item.startTime >= insertionTime + insertedDuration {
                        item.targetClipID = right.id
                    }
                    return item
                }
                result.transitionItems = result.effectiveTransitionItems.map { transition in
                    var transition = transition
                    if transition.outgoingClipID == original.id && transition.incomingClipID != original.id {
                        transition.outgoingClipID = right.id
                    }
                    return transition
                }
            } else {
                let insertionIndex = primaryIndices.first(where: { result.items[$0].timelineStart >= insertionTime - 0.000_1 }) ?? result.items.endIndex
                result.items.insert(contentsOf: primaryCopies, at: insertionIndex)
            }
        }

        for original in clipboard.items where original.overlay != nil {
            var copy = original
            copy.id = UUID()
            copy.timelineStart = max(0, insertionTime + original.timelineStart - referenceTime)
            if let baseID = copy.overlay?.baseItemID, let mapped = idMap[baseID] {
                copy.overlay?.baseItemID = mapped
            } else {
                copy.overlay?.baseItemID = nil
            }
            copy.explanation.append("Копия на Timeline")
            idMap[original.id] = copy.id
            result.items.append(copy)
            insertedSelection.insert(.item(copy.id))
        }
        result.items = TimelineTiming.retimed(result.items)

        for original in clipboard.audioClips {
            var copy = original
            copy.id = UUID()
            copy.timelineStart = max(0, insertionTime + original.timelineStart - referenceTime)
            copy.attachedToItemID = copy.attachedToItemID.flatMap { idMap[$0] }
            result.audioClips = result.effectiveAudioClips + [copy]
            insertedSelection.insert(.audio(copy.id))
        }
        for original in clipboard.telemetryItems {
            var copy = original
            copy.id = UUID()
            copy.timelineStart = max(0, insertionTime + original.timelineStart - referenceTime)
            copy.explanation.append("Копия на Timeline")
            result.telemetryItems = result.effectiveTelemetryItems + [copy]
            insertedSelection.insert(.telemetry(copy.id))
        }
        var copiedEffectPresetInstanceIDs: [UUID: UUID] = [:]
        for original in clipboard.effects {
            var copy = original
            copy.id = UUID()
            copy.startTime = max(0, insertionTime + original.startTime - referenceTime)
            copy.targetClipID = copy.targetClipID.flatMap { idMap[$0] ?? $0 }
            if let sourceInstanceID = original.effectStackPresetInstanceID {
                if let copiedInstanceID = copiedEffectPresetInstanceIDs[sourceInstanceID] {
                    copy.effectStackPresetInstanceID = copiedInstanceID
                } else {
                    let copiedInstanceID = UUID()
                    copiedEffectPresetInstanceIDs[sourceInstanceID] = copiedInstanceID
                    copy.effectStackPresetInstanceID = copiedInstanceID
                }
            }
            copy.explanation.append("Копия на Timeline")
            result.effects = result.effectiveEffects + [copy]
            insertedSelection.insert(.effect(copy.id))
        }
        for original in clipboard.titles {
            var copy = original
            copy.id = UUID()
            copy.startTime = max(0, insertionTime + original.startTime - referenceTime)
            copy.targetClipID = copy.targetClipID.flatMap { idMap[$0] ?? $0 }
            copy.words = copy.words.map { word in var word = word; word.id = UUID(); return word }
            copy.explanation.append("Копия на Timeline")
            result.titleItems = result.effectiveTitleItems + [copy]
            insertedSelection.insert(.title(copy.id))
        }
        for original in clipboard.transitions {
            var copy = original
            copy.id = UUID()
            copy.startTime = max(0, insertionTime + original.startTime - referenceTime)
            copy.outgoingClipID = idMap[original.outgoingClipID] ?? original.outgoingClipID
            copy.incomingClipID = idMap[original.incomingClipID] ?? original.incomingClipID
            copy.explanation.append("Копия на Timeline")
            result.transitionItems = result.effectiveTransitionItems + [copy]
            insertedSelection.insert(.transition(copy.id))
        }
        if let soundtrack = clipboard.soundtrack {
            result.music = soundtrack
            insertedSelection.insert(.soundtrack)
        }
        return (result, insertedSelection, insertedSelection.first)
    }

    func moveSoundtrack(toTimelineStart time: Double) {
        guard let pipeline, let trackID = timeline?.music?.trackID else { return }
        editTimeline("Перемещаю музыку") {
            if let id = try await pipeline.insertMusicClip(trackID: trackID, atTimelineStart: time) {
                self.selectTimelineAudioClip(id)
            }
        }
    }

    func trimSoundtrack(toTimelineStart start: Double, duration: Double) {
        guard let pipeline, let trackID = timeline?.music?.trackID else { return }
        editTimeline("Меняю границы музыки") {
            if let id = try await pipeline.insertMusicClip(trackID: trackID, atTimelineStart: start) {
                try await pipeline.updateAudioClip(id: id, timelineDuration: duration)
                self.selectTimelineAudioClip(id)
            }
        }
    }

    func seekTimeline(to requestedTime: Double) {
        guard let timeline else { return }
        let time = min(max(0, TimelineTiming.quantized(requestedTime, frameRate: timeline.frameRate)), timeline.duration)
        timelinePlayheadTime = time
        let mapped = TimelineTiming.playbackTime(forTimelineTime: time, items: timeline.items)
        let playbackDuration = activePlayback?.duration ?? timeline.duration
        let playbackTime = Self.playablePreviewTime(mapped, duration: playbackDuration, frameRate: timeline.frameRate)
        let target = CMTime(seconds: playbackTime, preferredTimescale: 600)
        if let playback = activePlayback,
           let player = previewPlayer,
           let playerItem = player.currentItem,
           !Self.isActivelyPlaying(player) {
            preparePreviewPoster(for: playback, playerItem: playerItem, at: playbackTime)
        }
        previewPlayer?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    var shouldHandleTimelineShortcuts: Bool {
        section == .timeline && !isTextEntryFocused
    }

    func handleTimelineKeyDown(_ event: NSEvent) -> Bool {
        guard shouldHandleTimelineShortcuts else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers.contains(.command) {
            let character = event.charactersIgnoringModifiers?.lowercased()
            switch character {
            case "c": copyTimelineSelection()
            case "x": cutTimelineSelection()
            case "v": pasteTimelineSelection()
            case "d": duplicateTimelineSelection()
            case "a": selectAllTimelineElements()
            case "z" where modifiers.contains(.shift): redoTimelineEdit()
            case "z": undoTimelineEdit()
            default: return false
            }
            return true
        }
        guard !modifiers.contains(.option), !modifiers.contains(.control) else { return false }
        switch event.keyCode {
        case 51, 117:
            deleteTimelineSelection()
        case 53:
            clearTimelineSelection()
        case 49:
            toggleTimelinePlayback()
        case 123:
            moveTimelinePlayhead(direction: -1, largeStep: modifiers.contains(.shift))
        case 124:
            moveTimelinePlayhead(direction: 1, largeStep: modifiers.contains(.shift))
        case 115:
            seekTimeline(to: 0)
        case 119:
            seekTimeline(to: timeline?.duration ?? 0)
        default:
            return false
        }
        return true
    }

    func toggleTimelinePlayback() {
        guard let player = previewPlayer else { return }
        if Self.isActivelyPlaying(player) {
            player.pause()
        } else {
            if let timeline, timelinePlayheadTime >= timeline.duration - 1 / max(1, timeline.frameRate) {
                timelinePlayheadTime = 0
                pendingPlaybackSeekTimelineTime = 0
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
                    Task { @MainActor in
                        guard let self, let player, self.previewPlayer === player else { return }
                        self.pendingPlaybackSeekTimelineTime = nil
                        if finished { player.playImmediately(atRate: 1) }
                    }
                }
                return
            }
            player.playImmediately(atRate: 1)
        }
    }

    func moveTimelinePlayhead(direction: Int, largeStep: Bool) {
        guard let timeline, direction != 0 else { return }
        let frame = 1 / max(1, timeline.frameRate)
        let step = largeStep ? max(1, frame * 10) : frame
        seekTimeline(to: timelinePlayheadTime + Double(direction.signum()) * step)
    }

    private var isTextEntryFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }
        return responder.nextResponder is NSTextView || responder.nextResponder is NSTextField
    }

    /// The magic brush is intentionally a local operation. The pipeline slices
    /// boundary clips before applying commands, then rebuilds the Player without
    /// moving away from the frame where the user invoked the change.
    func applyMagicBrush(_ instruction: String, to range: ClosedRange<Double>) {
        let clean = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pipeline, !clean.isEmpty, !isWorking else { return }
        let previousTimeline = timeline
        let preservedTimelineTime = timelinePlayheadTime
        let shouldResumePlayback = previewPlayer.map(Self.isActivelyPlaying) ?? false
        run("Волшебная кисть изменяет выбранный диапазон", presentation: .editorAI) {
            var context = self.directorContext()
            context.selectedItemSummary = "локальный диапазон \(Self.clockText(range.lowerBound))–\(Self.clockText(range.upperBound))"
            context.playheadTime = range.lowerBound
            let reply = await self.directorAgent.respond(
                to: "Измени только выбранный диапазон Timeline: \(clean)",
                context: context
            )
            let deterministic = EditorCommandParser().parse("выбранный фрагмент, \(clean)", preset: self.preset)
            let structuredCategories = Set(reply.commands.map(\.semanticCategory))
            let commands = deterministic.filter { !structuredCategories.contains($0.semanticCategory) } + reply.commands
            let report = try await pipeline.applyEditorCommands(commands, timelineRange: range)
            await self.refresh()
            self.recordTimelineChange(from: previousTimeline)
            if let previousTimeline, let current = self.timeline {
                _ = try? await pipeline.recordPreferenceSignals(before: previousTimeline, after: current)
            }
            await self.rebuildPlaybackIfPossible(
                show: false,
                restoringTimelineTime: preservedTimelineTime,
                resumePlayback: shouldResumePlayback
            )
            self.showViewer = true
            self.status = report.hasChanges
                ? "Готово — изменён только диапазон \(Self.clockText(range.lowerBound))–\(Self.clockText(range.upperBound))"
                : (report.ignored.first ?? "Не удалось распознать локальную правку")
        }
    }

    func undoTimelineEdit() {
        guard !isWorking, pipeline != nil, let current = timeline, let target = undoTimelineHistory.popLast() else { return }
        redoTimelineHistory.append(current)
        updateTimelineHistoryAvailability()
        editTimelineOptimistically(
            "Последняя правка отменена",
            recordHistory: false,
            preferenceSource: .undo
        ) {
            $0 = target
            return true
        }
    }

    func redoTimelineEdit() {
        guard !isWorking, pipeline != nil, let current = timeline, let target = redoTimelineHistory.popLast() else { return }
        undoTimelineHistory.append(current)
        updateTimelineHistoryAvailability()
        editTimelineOptimistically(
            "Правка повторена",
            recordHistory: false,
            preferenceSource: .restoration
        ) {
            $0 = target
            return true
        }
    }

    func changeSelectedTimelineDuration(by delta: Double) {
        guard let item = selectedTimelineItem else { return }
        let duration = max(0.25, item.timelineDuration + delta)
        editTimelineOptimistically("Меняю длительность") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) {
                let factor = $0.speedRamp?.outputDuration(sourceDuration: 1) ?? (1 / $0.speed)
                $0.timelineDuration = duration
                $0.sourceDuration = duration / max(0.01, factor)
            }
        }
    }

    func changeSelectedSourceStart(by delta: Double) {
        guard let item = selectedTimelineItem, item.kind == .video else { return }
        let sourceEnd = item.sourceStart + item.sourceDuration
        let minimumSourceDuration = 0.25 * item.speed
        let start = min(max(0, item.sourceStart + delta), sourceEnd - minimumSourceDuration)
        let duration = (sourceEnd - start) / item.speed
        editTimelineOptimistically("Меняю начало фрагмента") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) {
                $0.sourceStart = start
                $0.timelineDuration = duration
                $0.sourceDuration = max(0.05, sourceEnd - start)
            }
        }
    }

    func changeSelectedSourceEnd(by delta: Double) {
        guard let item = selectedTimelineItem, item.kind == .video else { return }
        let currentEnd = item.sourceStart + item.sourceDuration
        let assetDuration = item.assetID.flatMap { assetID in
            project?.assets.first(where: { $0.id == assetID })?.metadata.duration
        } ?? currentEnd
        let minimumEnd = item.sourceStart + 0.25 * item.speed
        let end = min(max(minimumEnd, currentEnd + delta), assetDuration)
        let duration = (end - item.sourceStart) / item.speed
        editTimelineOptimistically("Меняю конец фрагмента") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) {
                $0.timelineDuration = duration
                $0.sourceDuration = max(0.05, end - item.sourceStart)
            }
        }
    }

    func trimTimelineItem(id: UUID, sourceStart: Double, timelineDuration: Double) {
        selectTimelineItem(id)
        editTimelineOptimistically("Меняю границы фрагмента") {
            TimelineMutationEngine.updateItem(in: &$0, id: id) {
                let factor = $0.speedRamp?.outputDuration(sourceDuration: 1) ?? (1 / $0.speed)
                $0.sourceStart = sourceStart
                $0.timelineDuration = timelineDuration
                $0.sourceDuration = timelineDuration / max(0.01, factor)
            }
        }
    }

    func toggleSelectedTimelineLock() {
        guard let pipeline, let item = selectedTimelineItem else { return }
        editTimeline(item.locked ? "Снимаю блокировку" : "Закрепляю фрагмент") {
            try await pipeline.updateTimelineItem(id: item.id, locked: !item.locked)
        }
    }

    func setSelectedTransition(_ transition: String?) {
        guard let pipeline, let item = selectedTimelineItem else { return }
        editTimeline("Обновляю переход") {
            try await pipeline.updateTimelineItem(id: item.id, transition: transition, updateTransition: true)
        }
    }

    func setSelectedEffect(_ effect: String?) {
        guard let item = selectedTimelineItem else { return }
        editTimelineOptimistically("Обновляю эффект") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) { $0.effect = effect }
        }
    }

    func setSelectedSpeed(_ speed: Double) {
        guard let item = selectedTimelineItem else { return }
        let speed = min(20, max(0.1, speed))
        var video = item.effectiveVideoAdjustments
        if speed >= 0.999 { video.smoothSlowMotion = false }
        editTimelineOptimistically("Меняю скорость фрагмента") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) {
                $0.speed = speed
                $0.speedRamp = nil
                $0.timelineDuration = max(0.05, $0.sourceDuration / speed)
                $0.videoAdjustments = video.isNeutral ? nil : video
            }
        }
    }

    func setSelectedSpeedRamp(_ mode: String) {
        guard let pipeline, let item = selectedTimelineItem else { return }
        let ramp: SpeedRamp?
        switch mode {
        case "ease-in": ramp = .easeIn
        case "ease-out": ramp = .easeOut
        case "action": ramp = .action
        default: ramp = nil
        }
        editTimeline(ramp == nil ? "Убираю рамп скорости" : "Настраиваю рамп скорости") {
            _ = try await pipeline.applyEditorCommands([.setSpeedRamp(ramp, .selected)], selectedItemID: item.id)
            if item.effectiveVideoAdjustments.smoothSlowMotion == true {
                var video = item.effectiveVideoAdjustments
                video.smoothSlowMotion = false
                try await pipeline.updateTimelineItem(id: item.id, videoAdjustments: video, updateVideoAdjustments: true)
            }
        }
    }

    func setSelectedCrop(_ crop: CropStyle) {
        guard let pipeline, let item = selectedTimelineItem else { return }
        var value = item.effectiveVideoAdjustments
        value.crop = crop
        editTimeline("Меняю кадрирование") {
            try await pipeline.updateTimelineItem(id: item.id, videoAdjustments: value, updateVideoAdjustments: true)
        }
    }

    func setSelectedCropMode(_ mode: String) {
        guard let pipeline, let item = selectedTimelineItem else { return }
        var video = item.effectiveVideoAdjustments
        video.crop = mode == "fit" ? .fit : .fill
        // A manual framing choice must override the director's stored
        // subject-aware zoom; otherwise “Уместить” still looked cropped.
        video.subjectReframe = nil
        let effect: String? = mode == "ken-burns"
            ? ClipEffect.kenBurns.rawValue
            : (item.effect == ClipEffect.kenBurns.rawValue ? nil : item.effect)
        editTimeline("Меняю стиль кадрирования") {
            try await pipeline.updateTimelineItem(
                id: item.id,
                effect: effect,
                updateEffect: true,
                videoAdjustments: video,
                updateVideoAdjustments: true
            )
        }
    }

    func setSelectedFilter(_ filter: VideoFilter) {
        guard let pipeline, let item = selectedTimelineItem else { return }
        var value = item.effectiveVideoAdjustments
        value.filter = filter
        editTimeline("Применяю видеофильтр") {
            try await pipeline.updateTimelineItem(id: item.id, videoAdjustments: value, updateVideoAdjustments: true)
        }
    }

    func setSelectedFilterIntensity(_ intensity: Double) {
        updateSelectedVideoAdjustments("Меняю интенсивность фильтра") { $0.filterIntensity = min(max(0, intensity), 1) }
    }

    func setSelectedBrightness(_ value: Double) {
        updateSelectedVideoAdjustments("Меняю яркость") { $0.brightness = min(max(-1, value), 1) }
    }

    func setSelectedContrast(_ value: Double) {
        updateSelectedVideoAdjustments("Меняю контраст") { $0.contrast = min(max(0.25, value), 4) }
    }

    func setSelectedSaturation(_ value: Double) {
        updateSelectedVideoAdjustments("Меняю насыщенность") { $0.saturation = min(max(0, value), 2) }
    }

    func setSelectedWarmth(_ value: Double) {
        updateSelectedVideoAdjustments("Меняю температуру") { $0.warmth = min(max(-1, value), 1) }
    }

    func setSelectedTint(_ value: Double) {
        updateSelectedVideoAdjustments("Меняю оттенок") { $0.tint = min(max(-1, value), 1) }
    }

    func setSelectedStabilization(_ value: Double) {
        updateSelectedVideoAdjustments("Стабилизирую изображение") { $0.stabilization = min(max(0, value), 1) }
    }

    func setSelectedRollingShutterCorrection(_ enabled: Bool) {
        updateSelectedVideoAdjustments("Исправляю rolling shutter") { $0.rollingShutterCorrection = enabled }
    }

    func setSelectedSmoothSlowMotion(_ enabled: Bool) {
        updateSelectedVideoAdjustments("Настраиваю плавное замедление") { $0.smoothSlowMotion = enabled }
    }

    func rotateSelected(_ quarterTurns: Int) {
        guard let pipeline, let item = selectedTimelineItem else { return }
        var value = item.effectiveVideoAdjustments
        value.rotationQuarterTurns = ((value.rotationQuarterTurns + quarterTurns) % 4 + 4) % 4
        editTimeline("Поворачиваю фрагмент") {
            try await pipeline.updateTimelineItem(id: item.id, videoAdjustments: value, updateVideoAdjustments: true)
        }
    }

    func setSelectedOverlay(_ style: OverlayStyle?) {
        guard let pipeline, let item = selectedTimelineItem else { return }
        let baseID: UUID?
        if let selectedIndex = timeline?.items.firstIndex(where: { $0.id == item.id }) {
            baseID = timeline?.items[..<selectedIndex].last(where: { $0.overlay == nil && $0.kind != .title })?.id
                ?? timeline?.items.first(where: { $0.id != item.id && $0.overlay == nil && $0.kind != .title })?.id
        } else {
            baseID = nil
        }
        guard style == nil || baseID != nil else {
            errorMessage = "Для наложения нужен ещё один основной видеофрагмент"
            return
        }
        let overlay = style.map { OverlaySettings(style: $0, baseItemID: baseID) }
        editTimeline(style == nil ? "Убираю наложение" : "Создаю второй видеослой") {
            try await pipeline.updateTimelineItem(id: item.id, overlay: overlay, updateOverlay: true)
        }
    }

    func autoEnhanceSelected() {
        guard let pipeline, let item = selectedTimelineItem, item.kind != .title else { return }
        editTimeline("Автоматически улучшаю цвет") {
            _ = try await pipeline.applyEditorCommands([.autoEnhance(.selected)], selectedItemID: item.id)
        }
    }

    func insertFreezeFrameForSelected(duration: Double = 2) {
        guard let pipeline, let item = selectedTimelineItem, item.kind == .video else { return }
        editTimeline("Добавляю стоп-кадр") {
            _ = try await pipeline.applyEditorCommands(
                [.insertFreezeFrame(duration, .selected)],
                selectedItemID: item.id
            )
        }
    }

    func toggleSelectedReverse() {
        guard let pipeline, let item = selectedTimelineItem, item.kind == .video else { return }
        editTimeline(item.isReversed ? "Возвращаю обычное воспроизведение" : "Включаю реверс") {
            _ = try await pipeline.applyEditorCommands(
                [.setReverse(!item.isReversed, .selected)],
                selectedItemID: item.id
            )
        }
    }

    func insertInstantReplayForSelected() {
        guard let pipeline, let item = selectedTimelineItem, item.kind == .video else { return }
        editTimeline("Добавляю замедленный повтор") {
            _ = try await pipeline.applyEditorCommands(
                [.insertInstantReplay(0.5, .selected)],
                selectedItemID: item.id
            )
        }
    }

    func changeSelectedBrightness(by delta: Double) {
        updateSelectedVideoAdjustments("Меняю яркость") { $0.brightness = min(max(-1, $0.brightness + delta), 1) }
    }

    func changeSelectedContrast(by delta: Double) {
        updateSelectedVideoAdjustments("Меняю контраст") { $0.contrast = min(max(0.25, $0.contrast + delta), 4) }
    }

    func changeSelectedSaturation(by delta: Double) {
        updateSelectedVideoAdjustments("Меняю насыщенность") { $0.saturation = min(max(0, $0.saturation + delta), 2) }
    }

    func changeSelectedWarmth(by delta: Double) {
        updateSelectedVideoAdjustments("Меняю температуру цвета") { $0.warmth = min(max(-1, $0.warmth + delta), 1) }
    }

    func changeSelectedOpacity(by delta: Double) {
        updateSelectedVideoAdjustments("Меняю непрозрачность") { $0.opacity = min(max(0, $0.opacity + delta), 1) }
    }

    func changeSelectedExposure(by delta: Double) {
        updateSelectedVideoAdjustments("Меняю экспозицию") { $0.exposure = min(max(-4, ($0.exposure ?? 0) + delta), 4) }
    }

    func changeSelectedHighlights(by delta: Double) {
        updateSelectedVideoAdjustments("Меняю света") { $0.highlights = min(max(-1, ($0.highlights ?? 0) + delta), 1) }
    }

    func changeSelectedShadows(by delta: Double) {
        updateSelectedVideoAdjustments("Меняю тени") { $0.shadows = min(max(-1, ($0.shadows ?? 0) + delta), 1) }
    }

    func changeSelectedVignette(by delta: Double) {
        updateSelectedVideoAdjustments("Меняю виньетку") { $0.vignette = min(max(0, ($0.vignette ?? 0) + delta), 1) }
    }

    func changeSelectedGrain(by delta: Double) {
        updateSelectedVideoAdjustments("Меняю зерно") { $0.grain = min(max(0, ($0.grain ?? 0) + delta), 1) }
    }

    func setSelectedClipMuted(_ muted: Bool) {
        updateSelectedAudioAdjustments(muted ? "Отключаю звук фрагмента" : "Включаю звук фрагмента") { $0.muted = muted }
    }

    func setSelectedClipVolume(_ volume: Double) {
        updateSelectedAudioAdjustments("Меняю громкость фрагмента") { $0.volume = min(max(0, volume), 2) }
    }

    func changeSelectedAudioFadeIn(by delta: Double) {
        updateSelectedAudioAdjustments("Меняю нарастание звука") { $0.fadeIn = min(max(0, $0.fadeIn + delta), 10) }
    }

    func changeSelectedAudioFadeOut(by delta: Double) {
        updateSelectedAudioAdjustments("Меняю затухание звука") { $0.fadeOut = min(max(0, $0.fadeOut + delta), 10) }
    }

    func setSelectedNoiseReduction(_ value: Double) {
        updateSelectedAudioAdjustments("Очищаю звук") { $0.noiseReduction = min(max(0, value), 1) }
    }

    func setSelectedEQ(_ preset: AudioEQPreset) {
        updateSelectedAudioAdjustments("Настраиваю эквалайзер") { $0.eqPreset = preset }
    }

    func setSelectedAudioNormalize(_ enabled: Bool) {
        updateSelectedAudioAdjustments(enabled ? "Автоматически выравниваю громкость" : "Убираю автовыравнивание громкости") { $0.normalize = enabled }
    }

    func setSelectedDuckOthers(_ enabled: Bool) {
        updateSelectedAudioAdjustments(enabled ? "Снижаю громкость фоновых клипов" : "Возвращаю громкость фоновых клипов") { $0.duckOthers = enabled }
    }

    func setSelectedDuckingAmount(_ value: Double) {
        updateSelectedAudioAdjustments("Меняю приглушение фоновых клипов") { $0.duckingAmount = min(max(0, value), 1) }
    }

    func setSelectedPreservePitch(_ enabled: Bool) {
        updateSelectedAudioAdjustments(enabled ? "Сохраняю высоту тона" : "Связываю высоту тона со скоростью") { $0.preservePitch = enabled }
    }

    func setSelectedAudioEffect(_ effect: AudioEffect) {
        updateSelectedAudioAdjustments("Применяю аудиоэффект") { $0.effect = effect }
    }

    func resetSelectedColorBalance() {
        updateSelectedVideoAdjustments("Сбрасываю цветовой баланс") {
            $0.brightness = 0; $0.warmth = 0; $0.tint = 0
        }
    }

    func resetSelectedColorCorrection() {
        updateSelectedVideoAdjustments("Сбрасываю цветокоррекцию") {
            $0.exposure = 0; $0.contrast = 1; $0.saturation = 1
            $0.highlights = 0; $0.shadows = 0
        }
    }

    func resetSelectedCropAndRotation() {
        guard let pipeline, let item = selectedTimelineItem else { return }
        var video = item.effectiveVideoAdjustments
        video.crop = .fill
        video.rotationQuarterTurns = 0
        video.subjectReframe = nil
        editTimeline("Сбрасываю кадрирование") {
            try await pipeline.updateTimelineItem(
                id: item.id,
                effect: item.effect == ClipEffect.kenBurns.rawValue ? nil : item.effect,
                updateEffect: true,
                videoAdjustments: video,
                updateVideoAdjustments: true
            )
        }
    }

    func resetSelectedStabilization() {
        updateSelectedVideoAdjustments("Сбрасываю стабилизацию") {
            $0.stabilization = 0; $0.rollingShutterCorrection = false
        }
    }

    func resetSelectedVolume() {
        updateSelectedAudioAdjustments("Сбрасываю громкость") {
            $0.volume = 1; $0.muted = false; $0.normalize = false
            $0.duckOthers = false; $0.duckingAmount = 0.5
        }
    }

    func resetSelectedNoiseProcessing() {
        updateSelectedAudioAdjustments("Сбрасываю обработку шума") {
            $0.noiseReduction = 0; $0.eqPreset = .flat
        }
    }

    func resetSelectedSpeed() {
        guard let pipeline, let item = selectedTimelineItem else { return }
        var video = item.effectiveVideoAdjustments
        video.smoothSlowMotion = false
        var audio = item.effectiveAudioAdjustments
        audio.preservePitch = true
        editTimeline("Сбрасываю скорость") {
            try await pipeline.updateTimelineItem(
                id: item.id,
                speed: 1,
                videoAdjustments: video,
                updateVideoAdjustments: true,
                audioAdjustments: audio,
                updateAudioAdjustments: true,
                reversePlayback: false
            )
        }
    }

    func resetSelectedFilters() {
        guard let pipeline, let item = selectedTimelineItem else { return }
        var video = item.effectiveVideoAdjustments
        video.filter = .none
        video.filterIntensity = 1
        var audio = item.effectiveAudioAdjustments
        audio.effect = AudioEffect.none
        editTimeline("Сбрасываю фильтры") {
            try await pipeline.updateTimelineItem(
                id: item.id,
                videoAdjustments: video,
                updateVideoAdjustments: true,
                audioAdjustments: audio,
                updateAudioAdjustments: true
            )
        }
    }

    func resetAllSelectedViewerAdjustments() {
        guard let pipeline, let item = selectedTimelineItem else { return }
        editTimeline("Сбрасываю все настройки фрагмента") {
            try await pipeline.updateTimelineItem(
                id: item.id,
                speed: 1,
                effect: nil,
                updateEffect: true,
                videoAdjustments: VideoAdjustments(),
                updateVideoAdjustments: true,
                audioAdjustments: AudioAdjustments(),
                updateAudioAdjustments: true,
                reversePlayback: false
            )
        }
    }

    func setSelectedTelemetryEnabled(_ enabled: Bool) {
        guard let pipeline, let item = selectedTimelineItem else { return }
        editTimeline(enabled ? "Добавляю телеметрию" : "Убираю телеметрию") {
            _ = try await pipeline.applyEditorCommands(
                [.setTelemetryOverlay(enabled ? TelemetryOverlaySettings() : nil, .selected)],
                selectedItemID: item.id
            )
        }
    }

    func duplicateSelectedTimelineItem() {
        guard let pipeline, let item = selectedTimelineItem else { return }
        editTimeline("Дублирую фрагмент") {
            _ = try await pipeline.applyEditorCommands([.duplicate(.selected)], selectedItemID: item.id)
        }
    }

    func splitSelectedTimelineItem() {
        guard let pipeline, canSplitTimelineSelectionAtPlayhead else { return }
        if let item = selectedTimelineItem {
            editTimeline("Разделяю фрагмент в позиции указателя") {
                if let rightID = try await pipeline.splitTimelineItem(id: item.id, atTimelineTime: self.timelinePlayheadTime) {
                    self.selectTimelineItem(rightID)
                }
            }
        } else if let clip = selectedTimelineAudioClip {
            editTimeline("Разделяю аудио в позиции указателя") {
                if let rightID = try await pipeline.splitAudioClip(id: clip.id, atTimelineTime: self.timelinePlayheadTime) {
                    self.selectTimelineAudioClip(rightID)
                }
            }
        }
    }

    func detachSelectedAudio() {
        guard let pipeline, let item = selectedTimelineItem else { return }
        editTimeline("Отделяю аудио от видео") {
            if let id = try await pipeline.detachAudio(from: item.id) {
                self.selectTimelineAudioClip(id)
            }
        }
    }

    func moveTimelineAudioClip(_ id: UUID, toTimelineStart time: Double) {
        editTimelineOptimistically("Перемещаю аудиоклип") {
            TimelineMutationEngine.updateAudioClip(in: &$0, id: id) { $0.timelineStart = time }
        }
    }

    func trimTimelineAudioClip(_ id: UUID, timelineStart: Double? = nil, sourceStart: Double, duration: Double) {
        editTimelineOptimistically("Меняю границы аудиоклипа") { timeline in
            TimelineMutationEngine.updateAudioClip(in: &timeline, id: id) {
                if let timelineStart { $0.timelineStart = timelineStart }
                $0.sourceStart = sourceStart
                $0.timelineDuration = duration
                $0.sourceDuration = duration
            }
        }
    }

    func changeSelectedTimelineAudioDuration(by delta: Double) {
        guard let clip = selectedTimelineAudioClip else { return }
        let duration = min(clip.sourceDuration, max(0.05, clip.timelineDuration + delta))
        editTimelineOptimistically("Меняю границы аудиоклипа") {
            TimelineMutationEngine.updateAudioClip(in: &$0, id: clip.id) {
                $0.timelineDuration = duration
                $0.sourceDuration = duration
            }
        }
    }

    func setSelectedTimelineAudioVolume(_ volume: Double) {
        updateSelectedTimelineAudioAdjustments("Меняю громкость аудиоклипа") { $0.volume = min(max(0, volume), 2) }
    }

    func setSelectedTimelineAudioFades(in fadeIn: Double, out fadeOut: Double) {
        updateSelectedTimelineAudioAdjustments("Настраиваю fade аудиоклипа") {
            $0.fadeIn = min(max(0, fadeIn), 30)
            $0.fadeOut = min(max(0, fadeOut), 30)
        }
    }

    func setSelectedTimelineAudioNoiseReduction(_ amount: Double) {
        updateSelectedTimelineAudioAdjustments("Очищаю аудиоклип") { $0.noiseReduction = min(max(0, amount), 1) }
    }

    func setSelectedTimelineAudioEQ(_ preset: AudioEQPreset) {
        updateSelectedTimelineAudioAdjustments("Настраиваю EQ аудиоклипа") { $0.eqPreset = preset }
    }

    func setSelectedTimelineAudioNormalize(_ enabled: Bool) {
        updateSelectedTimelineAudioAdjustments(enabled ? "Выравниваю громкость аудиоклипа" : "Убираю автовыравнивание") { $0.normalize = enabled }
    }

    func setSelectedTimelineAudioDuckOthers(_ enabled: Bool) {
        updateSelectedTimelineAudioAdjustments(enabled ? "Включаю ducking" : "Выключаю ducking") { $0.duckOthers = enabled }
    }

    func setSelectedTimelineAudioEffect(_ effect: AudioEffect) {
        updateSelectedTimelineAudioAdjustments("Применяю аудиоэффект") { $0.effect = effect }
    }

    private func updateSelectedTimelineAudioAdjustments(
        _ status: String,
        mutation: @escaping (inout AudioAdjustments) -> Void
    ) {
        guard let clip = selectedTimelineAudioClip else { return }
        editTimelineOptimistically(status) {
            TimelineMutationEngine.updateAudioClip(in: &$0, id: clip.id) { mutation(&$0.adjustments) }
        }
    }

    func copySelectedTimelineSettings() {
        guard let item = selectedTimelineItem else { return }
        copiedTimelineItemSettings = item
        status = "Настройки фрагмента скопированы"
    }

    func pasteTimelineSettings(to id: UUID) {
        guard let pipeline, let source = copiedTimelineItemSettings,
              let target = timeline?.items.first(where: { $0.id == id }) else { return }
        selectTimelineItem(id)
        editTimeline("Вставляю настройки фрагмента") {
            try await pipeline.updateTimelineItem(
                id: target.id,
                speed: target.kind == .video ? source.speed : nil,
                transition: source.transition,
                updateTransition: true,
                effect: source.effect,
                updateEffect: true,
                videoAdjustments: source.videoAdjustments,
                updateVideoAdjustments: true,
                audioAdjustments: target.kind == .video ? source.audioAdjustments : nil,
                updateAudioAdjustments: target.kind == .video,
                titleStyle: target.kind == .title ? source.titleStyle : nil,
                updateTitleStyle: target.kind == .title
            )
        }
    }

    var canPasteTimelineSettings: Bool { copiedTimelineItemSettings != nil }

    func addTitle(_ text: String, atEnd: Bool) {
        guard let pipeline else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        editTimeline("Добавляю титр") {
            _ = try await pipeline.applyEditorCommands([.addTitle(clean, atEnd ? .end : .beginning)])
        }
    }

    func setSelectedTitleText(_ text: String) {
        guard let item = selectedTimelineItem, item.kind == .title else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != item.title else { return }
        editTimelineOptimistically("Обновляю текст титра") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) { $0.title = clean }
        }
    }

    func setSelectedTitleFontSize(_ size: Double) {
        updateSelectedTitleStyle("Меняю размер титра") { $0.fontSize = min(max(18, size), 220) }
    }

    func setSelectedTitleAlignment(_ alignment: TitleAlignment) {
        updateSelectedTitleStyle("Выравниваю титр") { $0.alignment = alignment }
    }

    func setSelectedTitleTextColor(_ hex: String) {
        updateSelectedTitleStyle("Меняю цвет титра") { $0.textColorHex = hex }
    }

    func setSelectedTitleBackgroundColor(_ hex: String) {
        updateSelectedTitleStyle("Меняю фон титра") { $0.backgroundColorHex = hex }
    }

    private func updateSelectedTitleStyle(_ status: String, mutation: @escaping (inout TitleStyle) -> Void) {
        guard let item = selectedTimelineItem, item.kind == .title else { return }
        editTimelineOptimistically(status) { timeline in
            TimelineMutationEngine.updateItem(in: &timeline, id: item.id) { edited in
                var style = edited.effectiveTitleStyle
                mutation(&style)
                edited.titleStyle = style
            }
        }
    }

    private func updateSelectedVideoAdjustments(_ status: String, mutation: @escaping (inout VideoAdjustments) -> Void) {
        guard let item = selectedTimelineItem else { return }
        editTimelineOptimistically(status) { timeline in
            TimelineMutationEngine.updateItem(in: &timeline, id: item.id) { edited in
                var value = edited.effectiveVideoAdjustments
                mutation(&value)
                edited.videoAdjustments = value
            }
        }
    }

    private func updateSelectedAudioAdjustments(_ status: String, mutation: @escaping (inout AudioAdjustments) -> Void) {
        guard let item = selectedTimelineItem else { return }
        editTimelineOptimistically(status) { timeline in
            TimelineMutationEngine.updateItem(in: &timeline, id: item.id) { edited in
                var value = edited.effectiveAudioAdjustments
                mutation(&value)
                edited.audioAdjustments = value
            }
        }
    }

    func setMusicStyle(_ style: MusicStyle?) {
        guard let pipeline else { return }
        let existingVolume = timeline?.music?.volume ?? 0.22
        let directive = style.map { MusicDirective(style: $0, bpm: Self.defaultBPM(for: $0), volume: existingVolume) }
        editTimeline(style == nil ? "Убираю музыку" : "Добавляю музыку") {
            try await pipeline.updateMusic(directive)
        }
    }

    func setMusicTrack(_ trackID: UUID?) {
        guard let pipeline else { return }
        let currentVolume = timeline?.music?.volume ?? 0.22
        let directive = trackID.flatMap { id in
            musicTracks.first(where: { $0.id == id }).map {
                MusicDirective(style: $0.suggestedStyle, bpm: $0.bpm, volume: currentVolume, trackID: $0.id, trackTitle: $0.title)
            }
        }
        editTimeline(directive == nil ? "Убираю музыку" : "Выбираю локальный трек") {
            try await pipeline.updateMusic(directive)
        }
    }

    func setMusicVolume(_ volume: Double) {
        editTimelineOptimistically("Настраиваю громкость музыки") { timeline in
            guard timeline.music != nil else { return false }
            timeline.music?.volume = min(max(0, volume), 1)
            return true
        }
    }

    func setOriginalAudioEnabled(_ enabled: Bool) {
        editTimelineOptimistically(enabled ? "Включаю звук исходников" : "Убираю звук исходников") { timeline in
            let value = enabled ? 1.0 : 0.0
            guard abs(timeline.effectiveOriginalAudioVolume - value) > 0.0001 else { return false }
            timeline.originalAudioVolume = value
            return true
        }
    }

    func deleteSelectedTimelineItem() {
        deleteTimelineSelection()
    }

    func cancelOperation() {
        activeTask?.cancel()
        if let pipeline { Task { await pipeline.cancelAllAnalysis() } }
        status = "Отменяю операцию"
    }

    func refresh() async {
        guard let pipeline else { project = nil; return }
        try? await pipeline.migrateLegacyBuiltInBackgroundAssets()
        let previousMode = aiPowerMode
        let previousAdvancedSettings = advancedAISettings
        project = await pipeline.snapshot()
        if selectedTimelineItemID.flatMap({ id in timeline?.items.contains(where: { $0.id == id }) }) != true {
            selectedTimelineItemID = nil
        }
        if selectedTimelineAudioClipID.flatMap({ id in timeline?.effectiveAudioClips.contains(where: { $0.id == id }) }) != true {
            selectedTimelineAudioClipID = nil
        }
        if selectedTelemetryItemID.flatMap({ id in timeline?.effectiveTelemetryItems.contains(where: { $0.id == id }) }) != true {
            selectedTelemetryItemID = nil
        }
        if selectedEffectTimelineItemID.flatMap({ id in timeline?.effectiveEffects.contains(where: { $0.id == id }) }) != true {
            selectedEffectTimelineItemID = nil
        }
        if selectedTitleTimelineItemID.flatMap({ id in timeline?.effectiveTitleItems.contains(where: { $0.id == id }) }) != true {
            selectedTitleTimelineItemID = nil
        }
        if selectedTransitionTimelineItemID.flatMap({ id in timeline?.effectiveTransitionItems.contains(where: { $0.id == id }) }) != true {
            selectedTransitionTimelineItemID = nil
        }
        selectedTimelineItemIDs.formIntersection(Set(timeline?.items.map(\.id) ?? []))
        selectedTimelineAudioClipIDs.formIntersection(Set(timeline?.effectiveAudioClips.map(\.id) ?? []))
        selectedTelemetryItemIDs.formIntersection(Set(timeline?.effectiveTelemetryItems.map(\.id) ?? []))
        selectedEffectTimelineItemIDs.formIntersection(Set(timeline?.effectiveEffects.map(\.id) ?? []))
        selectedTitleTimelineItemIDs.formIntersection(Set(timeline?.effectiveTitleItems.map(\.id) ?? []))
        selectedTransitionTimelineItemIDs.formIntersection(Set(timeline?.effectiveTransitionItems.map(\.id) ?? []))
        if timeline?.music == nil { selectedSoundtrack = false }
        if let preferences = project?.preferences {
            aiPowerMode = preferences.effectiveAIPowerMode
            advancedAISettings = preferences.effectiveAdvancedAISettings
        }
        if previousMode != aiPowerMode || previousAdvancedSettings != advancedAISettings {
            Task { await refreshLocalVisionModelStatus() }
        }
        thumbnailURLs = await pipeline.thumbnailURLs()
        timelineThumbnailURLs = await pipeline.timelineThumbnailURLs()
        await refreshMusicLibrary()
    }

    func flushAutosave() async {
        workspaceAutosaveTask?.cancel()
        workspaceAutosaveTask = nil
        let pendingTimelineCommit = timelineCommitTask
        timelineCommitTask = nil
        await pendingTimelineCommit?.value
        previewRebuildTask?.cancel()
        previewRebuildTask = nil
        await persistWorkspaceState()
        if let pipeline {
            try? await pipeline.save()
        }
        UserDefaults.standard.synchronize()
    }

    func showDirector() {
        showViewer = false
        section = .director
        Task { await refreshDirectorRuntimeStatus() }
    }

    func showMovie() {
        guard previewPlayer != nil else { return }
        showViewer = true
        section = .timeline
    }

    func openSection(_ destination: WorkspaceSection) {
        guard project != nil || destination == .home else { return }
        if destination != .timeline { showViewer = false }
        section = destination
    }

    func toggleTimelineInspector() {
        isTimelineInspectorPresented.toggle()
    }

    func openTimelineInspector() {
        isTimelineInspectorPresented = true
    }

    func closeTimelineInspector() {
        isTimelineInspectorPresented = false
    }

    func handleEscape() {
        if isWorking {
            cancelOperation()
        } else if showViewer {
            previewPlayer?.pause()
            showViewer = false
        } else if section == .timeline && hasTimelineSelection {
            clearTimelineSelection()
        } else if section == .timeline && isTimelineInspectorPresented {
            isTimelineInspectorPresented = false
        } else if selectedAssetID != nil {
            selectedAssetID = nil
        } else {
            selectedMusicTrackID = nil
        }
    }

    private func resetProjectUI() {
        projectRestoreTask?.cancel()
        projectRestoreTask = nil
        workspaceAutosaveTask?.cancel()
        workspaceAutosaveTask = nil
        timelineCommitTask?.cancel()
        timelineCommitTask = nil
        previewRebuildTask?.cancel()
        previewRebuildTask = nil
        timelineEditRevision &+= 1
        isRestoringWorkspaceState = true
        defer { isRestoringWorkspaceState = false }
        directorTask?.cancel()
        directorTask = nil
        isDirectorResponding = false
        isCreatingFilm = false
        hasPendingFilmChanges = false
        directorRevision = 0
        pendingDirectorInstructions = []
        pendingDirectorCommandGroups = []
        directorAgent.reset()
        directorRuntimeStatus = LocalDirectorAgent.currentRuntimeLabel()
        aiPowerMode = .fast
        advancedAISettings = AdvancedAISettings()
        aiVisionModelStatus = "Проверяю локальную vision-модель…"
        aiVisionModelInstalled = false
        isDownloadingAIModel = false
        aiModelDownloadProgress = 0
        aiModelAvailability = [:]
        downloadingAIPowerMode = nil
        Task { await refreshDirectorRuntimeStatus() }
        directorMessages = DirectorMessage.initial
        directorStatus = "Готов выслушать ваш замысел"
        prompt = Self.defaultDirectorBrief
        directorInput = ""
        if let playbackTimeObserver, let previewPlayer {
            previewPlayer.removeTimeObserver(playbackTimeObserver)
        }
        playbackTimeObserver = nil
        playbackItemStatusObservation?.invalidate()
        playbackItemStatusObservation = nil
        previewPosterTask?.cancel()
        previewPosterTask = nil
        previewPlayer?.pause()
        project = nil
        projectURL = nil
        activePlayback = nil
        previewPlayer = nil
        previewURL = nil
        previewPosterImage = nil
        isPreviewPosterVisible = false
        showViewer = false
        isShowingManualExportSettings = false
        thumbnailURLs = [:]
        timelineThumbnailURLs = [:]
        musicTracks = []
        musicLibraryStatus = MusicLibraryStatus()
        directorMusicTrackID = nil
        selectedAssetID = nil
        selectedMusicTrackID = nil
        selectedTimelineItemID = nil
        selectedTimelineAudioClipID = nil
        selectedTelemetryItemID = nil
        selectedEffectTimelineItemID = nil
        selectedTitleTimelineItemID = nil
        selectedTransitionTimelineItemID = nil
        selectedTimelineItemIDs = []
        selectedTimelineAudioClipIDs = []
        selectedTelemetryItemIDs = []
        selectedEffectTimelineItemIDs = []
        selectedTitleTimelineItemIDs = []
        selectedTransitionTimelineItemIDs = []
        selectedSoundtrack = false
        isTimelineInspectorPresented = false
        timelinePlayheadTime = 0
        copiedTimelineItemSettings = nil
        copiedEffectTimelineItem = nil
        copiedEffectKeyframe = nil
        timelineClipboard = nil
        timelineSelectionAnchor = nil
        undoTimelineHistory = []
        redoTimelineHistory = []
        updateTimelineHistoryAvailability()
        isAnalyzing = false
        isImporting = false
        activityDismissTask?.cancel()
        activityDismissTask = nil
        isActivityPanelVisible = false
        isActivityComplete = false
    }

    private func prepareOpenedProject() {
        guard let pipeline, project != nil else { return }
        isRestoringWorkspaceState = true
        if let saved = project?.workspaceState {
            prompt = saved.prompt
            directorInput = saved.directorDraft
            directorMessages = saved.directorMessages.map { messages in
                messages.map { DirectorMessage(projectMessage: $0) }
            } ?? DirectorMessage.initial
            feedback = saved.feedbackDraft
            preset = saved.preset
            targetMinutes = saved.targetMinutes
            directorMusicTrackID = saved.directorMusicTrackID
            pendingDirectorInstructions = saved.pendingDirectorInstructions
            pendingDirectorCommandGroups = Array(repeating: [], count: saved.pendingDirectorInstructions.count)
            hasPendingFilmChanges = saved.hasPendingFilmChanges
            directorRevision = saved.pendingDirectorInstructions.count
        } else if let plan = project?.storyPlans.last {
            prompt = plan.prompt
            directorInput = ""
            preset = plan.preset
            targetMinutes = plan.constraints.targetDuration / 60
            directorMusicTrackID = nil
            hasPendingFilmChanges = false
            pendingDirectorInstructions = []
            pendingDirectorCommandGroups = []
        }
        directorAgent.restoreConversation(directorMessages)
        undoTimelineHistory = (project?.timelineCheckpoints ?? [])
            .suffix(40)
            .map(\.timeline)
            .filter { $0 != timeline }
        redoTimelineHistory = []
        updateTimelineHistoryAvailability()
        isRestoringWorkspaceState = false
        guard project?.assets.isEmpty == false else { return }

        let shouldResolveMusic = timeline?.music != nil
        let shouldPreparePlayback = timeline != nil
        projectRestoreTask?.cancel()
        projectRestoreTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.pipeline === pipeline {
                    self.projectRestoreTask = nil
                }
            }

            do {
                var restoreWarning: String?
                if shouldResolveMusic {
                    do {
                        if try await pipeline.resolvePendingMusic() != nil {
                            let refreshedProject = await pipeline.snapshot()
                            let refreshedTracks = try? await pipeline.musicTracks()
                            guard !Task.isCancelled, self.pipeline === pipeline else { return }
                            self.project = refreshedProject
                            if let refreshedTracks { self.musicTracks = refreshedTracks }
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        restoreWarning = error.localizedDescription
                    }
                }

                _ = await pipeline.generateThumbnails()
                let thumbnails = await pipeline.thumbnailURLs()
                guard !Task.isCancelled, self.pipeline === pipeline else { return }
                self.thumbnailURLs = thumbnails

                if shouldPreparePlayback {
                    let playback = try await pipeline.makePlayback()
                    guard !Task.isCancelled, self.pipeline === pipeline else { return }
                    self.setPlayback(playback, show: false, autoplay: false)
                    restoreWarning = restoreWarning ?? playback.warnings.first
                }

                if let restoreWarning {
                    self.errorMessage = restoreWarning
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.pipeline === pipeline else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func setPlayback(
        _ playback: TimelinePlayback,
        show: Bool = true,
        autoplay: Bool = true,
        restoringTimelineTime requestedTimelineTime: Double? = nil
    ) {
        let previousPlayback = activePlayback
        let previousItem = previewPlayer?.currentItem
        if let playbackTimeObserver, let previewPlayer {
            previewPlayer.removeTimeObserver(playbackTimeObserver)
        }
        playbackTimeObserver = nil
        playbackItemStatusObservation?.invalidate()
        playbackItemStatusObservation = nil
        previewPosterTask?.cancel()
        previewPosterTask = nil
        // Keep the last verified frame visible until the replacement produces
        // its own frame. Clearing it here caused a black flash on every edit.
        isPreviewPosterVisible = previewPosterImage != nil
        previewPlayer?.pause()
        previewURL = nil
        activePlayback = playback
        let playerItem = AVPlayerItem(asset: playback.composition)
        if let videoComposition = playback.videoComposition {
            if videoComposition.animationTool == nil {
                playerItem.videoComposition = videoComposition
            } else if let liveComposition = videoComposition.mutableCopy() as? AVMutableVideoComposition {
                // AVVideoCompositionCoreAnimationTool is reliable for export,
                // but attaching it to AVPlayer during workspace restoration
                // corrupts the next SwiftUI main-executor check on the affected
                // macOS 26 runtime. Keep transforms/transitions in a live copy
                // and omit only the title overlay from interactive playback.
                liveComposition.animationTool = nil
                playerItem.videoComposition = liveComposition
            }
        }
        playerItem.audioMix = playback.audioMix
        // Keep the AVPlayer identity stable across timeline edits. SwiftUI can
        // continue displaying the same player surface while only its item is
        // replaced, which avoids a black/zero-frame flash in the viewer.
        let player = previewPlayer ?? AVPlayer()
        player.replaceCurrentItem(with: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        previewPlayer = player
        if let requestedTimelineTime, let timeline {
            let timelineTime = min(max(0, requestedTimelineTime), timeline.duration)
            pendingPlaybackSeekTimelineTime = timelineTime
            timelinePlayheadTime = timelineTime
        } else {
            pendingPlaybackSeekTimelineTime = nil
            timelinePlayheadTime = 0
        }
        playbackTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / max(15, timeline?.frameRate ?? 30), preferredTimescale: 600),
            queue: .main
        ) { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, let timeline = self.timeline else { return }
                if self.isPreviewPosterVisible, player.timeControlStatus == .playing {
                    self.isPreviewPosterVisible = false
                }
                if let pendingTime = self.pendingPlaybackSeekTimelineTime {
                    self.timelinePlayheadTime = min(timeline.duration, pendingTime)
                    return
                }
                self.timelinePlayheadTime = min(
                    timeline.duration,
                    TimelineTiming.timelineTime(forPlaybackTime: value.seconds, items: timeline.items)
                )
            }
        }
        let frameRate = timeline?.frameRate ?? 30
        let restoredTimelineTime = requestedTimelineTime.flatMap { requested in
            timeline.map { min(max(0, requested), $0.duration) }
        }
        let requestedPlaybackTime: Double
        if let restoredTimelineTime, let timeline {
            requestedPlaybackTime = Self.playablePreviewTime(
                TimelineTiming.playbackTime(forTimelineTime: restoredTimelineTime, items: timeline.items),
                duration: playback.duration,
                frameRate: timeline.frameRate
            )
        } else {
            requestedPlaybackTime = min(
                max(0, playback.duration - 0.001),
                1 / max(15, frameRate)
            )
        }

        // Generate a real composition frame independently of AVPlayer. It is
        // displayed while the player item is loading or paused, so the viewer
        // never falls back to an unexplained black rectangle.
        preparePreviewPoster(
            for: playback,
            playerItem: playerItem,
            at: requestedPlaybackTime
        )

        playbackItemStatusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self, weak playerItem] item, _ in
            guard item.status != .unknown else { return }
            Task { @MainActor [weak self, weak playerItem] in
                guard let self,
                      let playerItem,
                      self.activePlayback === playback,
                      self.previewPlayer === player,
                      player.currentItem === playerItem else { return }
                self.playbackItemStatusObservation?.invalidate()
                self.playbackItemStatusObservation = nil

                if item.status == .failed {
                    self.errorMessage = item.error?.localizedDescription ?? "Не удалось подготовить видео для просмотра."
                    if let previousItem, let previousPlayback {
                        player.replaceCurrentItem(with: previousItem)
                        self.activePlayback = previousPlayback
                        self.isPreviewPosterVisible = self.previewPosterImage != nil
                    }
                    return
                }
                guard item.status == .readyToPlay else { return }

                let shouldPlay = autoplay || Self.isActivelyPlaying(player)
                let target = CMTime(seconds: requestedPlaybackTime, preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak playerItem] finished in
                    Task { @MainActor [weak self, weak playerItem] in
                        guard let self,
                              let playerItem,
                              self.previewPlayer === player,
                              player.currentItem === playerItem else { return }
                        if let restoredTimelineTime {
                            self.pendingPlaybackSeekTimelineTime = nil
                            self.timelinePlayheadTime = restoredTimelineTime
                        }
                        if finished, shouldPlay { player.play() }
                    }
                }
            }
        }
        if show {
            showViewer = automaticallyShowPreview
            section = .timeline
        }
    }

    private func preparePreviewPoster(
        for playback: TimelinePlayback,
        playerItem: AVPlayerItem,
        at playbackTime: Double
    ) {
        previewPosterTask?.cancel()
        let safeTime = min(max(0, playbackTime), max(0, playback.duration - 0.001))
        let videoComposition = playerItem.videoComposition

        previewPosterTask = Task.detached(priority: .userInitiated) { [weak self, weak playerItem] in
            // Collapse rapid timeline scrubbing into the final requested frame.
            try? await Task.sleep(nanoseconds: 35_000_000)
            guard !Task.isCancelled else { return }

            let generator = AVAssetImageGenerator(asset: playback.composition)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1_280, height: 1_280)
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
            generator.videoComposition = videoComposition

            let requested = CMTime(seconds: safeTime, preferredTimescale: 600)
            var image = (try? generator.copyCGImage(at: requested, actualTime: nil))
                ?? (try? generator.copyCGImage(at: .zero, actualTime: nil))
            var rejectedBlackFrame = image.map { FrameQualityInspector.assess(image: $0).isBlack } ?? false
            if rejectedBlackFrame {
                let nearbyTimes = [
                    min(max(0, playback.duration - 0.001), safeTime + 0.12),
                    max(0, safeTime - 0.12),
                    min(max(0, playback.duration - 0.001), max(0.04, playback.duration * 0.1)),
                ]
                for nearbyTime in nearbyTimes where !Task.isCancelled {
                    guard let nearby = try? generator.copyCGImage(
                        at: CMTime(seconds: nearbyTime, preferredTimescale: 600),
                        actualTime: nil
                    ) else { continue }
                    if !FrameQualityInspector.assess(image: nearby).isBlack {
                        image = nearby
                        rejectedBlackFrame = false
                        break
                    }
                }
            }
            guard !Task.isCancelled, let image else { return }
            let shouldRejectBlackFrame = rejectedBlackFrame

            await MainActor.run { [weak self, weak playerItem] in
                guard let self,
                      let playerItem,
                      self.activePlayback === playback,
                      self.previewPlayer?.currentItem === playerItem else { return }
                if shouldRejectBlackFrame, self.previewPosterImage != nil {
                    self.status = "Просмотр: чёрный кадр декодера отклонён, сохранён предыдущий кадр"
                    self.isPreviewPosterVisible = true
                    return
                }
                self.previewPosterImage = NSImage(cgImage: image, size: .zero)
                self.isPreviewPosterVisible = self.previewPlayer?.timeControlStatus != .playing
            }
        }
    }

    private func editTimeline(_ initialStatus: String, mutation: @escaping @MainActor () async throws -> Void) {
        let previousTimeline = timeline
        let preservedTimelineTime = timelinePlayheadTime
        let shouldResumePlayback = previewPlayer.map(Self.isActivelyPlaying) ?? false
        run(initialStatus, presentation: .silentEditor) {
            try await mutation()
            await self.refresh()
            self.recordTimelineChange(from: previousTimeline)
            if let pipeline = self.pipeline, let previousTimeline, let current = self.timeline {
                _ = try? await pipeline.recordPreferenceSignals(before: previousTimeline, after: current)
            }
            await self.rebuildPlaybackIfPossible(
                show: false,
                restoringTimelineTime: preservedTimelineTime,
                resumePlayback: shouldResumePlayback
            )
            self.status = "Монтаж обновлён"
        }
    }

    /// Applies high-frequency editor changes in the current event turn. Disk
    /// persistence and composition rebuilding are coalesced, cancellable work;
    /// stale tasks cannot replace a newer edit or preview.
    private func editTimelineOptimistically(
        _ initialStatus: String,
        recordHistory: Bool = true,
        preferenceSource: PreferenceSignalSource = .manualEdit,
        mutation: (inout Timeline) -> Bool
    ) {
        let interactionStarted = ProcessInfo.processInfo.systemUptime
        guard !isWorking, let pipeline, var manifest = project,
              let timelineIndex = manifest.timelines.indices.last else { return }
        let previous = manifest.timelines[timelineIndex]
        var next = previous
        guard mutation(&next), next != previous else { return }

        manifest.timelines[timelineIndex] = next
        project = manifest
        let stateLatency = (ProcessInfo.processInfo.systemUptime - interactionStarted) * 1_000
        Task {
            await interactionLatencyRecorder.record(InteractionLatencySample(
                name: initialStatus,
                stateUpdateMilliseconds: stateLatency,
                visualFeedbackMilliseconds: stateLatency
            ))
        }
        if recordHistory { recordTimelineChange(from: previous) }
        status = initialStatus
        hasPendingFilmChanges = true

        timelineEditRevision &+= 1
        let revision = timelineEditRevision
        let preservedTimelineTime = timelinePlayheadTime
        let shouldResumePlayback = previewPlayer.map(Self.isActivelyPlaying) ?? false

        timelineCommitTask?.cancel()
        timelineCommitTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
                try Task.checkCancellation()
                let committed = try await pipeline.commitLatestTimeline(next, clientRevision: revision)
                guard committed, !Task.isCancelled else { return }
                _ = try? await pipeline.recordPreferenceSignals(before: previous, after: next, source: preferenceSource)
                guard let self, self.pipeline === pipeline, self.timelineEditRevision == revision else { return }
                self.status = "Монтаж обновлён"
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.pipeline === pipeline, self.timelineEditRevision == revision else { return }
                self.errorMessage = "Изменение видно в редакторе, но не сохранено: \(error.localizedDescription)"
            }
        }

        previewRebuildTask?.cancel()
        let invalidation = TimelineInvalidationPlanner.plan(from: previous, to: next)
        let previewDebounceNanoseconds: UInt64 = invalidation.requiresCompositionRebuild ? 35_000_000 : 16_000_000
        previewRebuildTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: previewDebounceNanoseconds)
                try Task.checkCancellation()
                let playback = try await pipeline.makePlayback(timeline: next, interactiveLongEdge: 1_280)
                try Task.checkCancellation()
                guard let self, self.pipeline === pipeline, self.timelineEditRevision == revision else { return }
                self.setPlayback(
                    playback,
                    show: false,
                    autoplay: shouldResumePlayback,
                    restoringTimelineTime: preservedTimelineTime
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.pipeline === pipeline, self.timelineEditRevision == revision else { return }
                self.errorMessage = "Не удалось обновить интерактивный просмотр: \(error.localizedDescription)"
            }
        }
    }

    private func recordTimelineChange(from previous: Timeline?) {
        guard let previous, let current = timeline, previous != current else { return }
        undoTimelineHistory.append(previous)
        if undoTimelineHistory.count > 40 {
            undoTimelineHistory.removeFirst(undoTimelineHistory.count - 40)
        }
        redoTimelineHistory.removeAll()
        updateTimelineHistoryAvailability()
    }

    private func updateTimelineHistoryAvailability() {
        canUndoTimelineEdit = !undoTimelineHistory.isEmpty
        canRedoTimelineEdit = !redoTimelineHistory.isEmpty
    }

    private func rebuildPlaybackIfPossible(
        show: Bool,
        restoringTimelineTime requestedTimelineTime: Double? = nil,
        resumePlayback requestedResumePlayback: Bool? = nil
    ) async {
        guard let pipeline, timeline?.items.contains(where: { $0.kind != .title }) == true else {
            if let playbackTimeObserver, let previewPlayer {
                previewPlayer.removeTimeObserver(playbackTimeObserver)
            }
            playbackTimeObserver = nil
            playbackItemStatusObservation?.invalidate()
            playbackItemStatusObservation = nil
            previewPosterTask?.cancel()
            previewPosterTask = nil
            previewPlayer?.pause()
            previewPlayer = nil
            activePlayback = nil
            previewPosterImage = nil
            isPreviewPosterVisible = false
            showViewer = false
            return
        }
        let timelineTime = requestedTimelineTime ?? timelinePlayheadTime
        let resumePlayback = requestedResumePlayback
            ?? previewPlayer.map(Self.isActivelyPlaying)
            ?? false
        // Freeze the old frame while the new composition is assembled. This
        // prevents the old cut from running ahead and then visibly jumping
        // backwards when the edited frame is restored.
        previewPlayer?.pause()
        do {
            let playback = try await pipeline.makePlayback()
            setPlayback(
                playback,
                show: show,
                autoplay: show || resumePlayback,
                restoringTimelineTime: timelineTime
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func isActivelyPlaying(_ player: AVPlayer) -> Bool {
        player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    private static func durationText(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return minutes == 0 ? "\(remainingSeconds) секунд" : "\(minutes) минут \(remainingSeconds) секунд"
    }

    private static func playablePreviewTime(_ requestedTime: Double, duration: Double, frameRate: Double) -> Double {
        let safeDuration = max(0, duration)
        let frameDuration = 1 / max(1, frameRate)
        return min(max(0, requestedTime), max(0, safeDuration - frameDuration))
    }

    private static func clockText(_ seconds: Double) -> String {
        let safe = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", safe / 60, safe % 60)
    }

    private static func defaultBPM(for style: MusicStyle) -> Double {
        switch style {
        case .energetic: return 132
        case .cinematic: return 82
        case .calm: return 68
        case .joyful: return 112
        case .electronic: return 124
        case .acoustic: return 94
        }
    }

    private func beginDirectorExchange(mode: DirectorRequestMode = .edit) -> (text: String, replyID: UUID)? {
        let text = directorInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        directorInput = ""
        if mode == .edit {
            let interpreted = PromptInterpreter().interpret(prompt: text, preset: preset)
            let presetDefault = PromptInterpreter.defaults(for: preset)
            if abs(interpreted.targetDuration - presetDefault.targetDuration) > 0.001 {
                targetMinutes = interpreted.targetDuration / 60
            }
            if prompt == Self.defaultDirectorBrief { prompt = text }
            else { prompt += "\n\(text)" }
            markFilmNeedsRebuild("Пожелание сохранено — его нужно применить к фильму", instruction: text)
        } else {
            scheduleWorkspaceAutosave()
        }
        directorMessages.append(DirectorMessage(role: .user, text: text))
        let replyID = UUID()
        directorMessages.append(DirectorMessage(id: replyID, role: .assistant, text: ""))
        return (text, replyID)
    }

    private func finishDirectorExchange(
        replyID: UUID,
        sourceText: String,
        reply: DirectorAIReply,
        mode: DirectorRequestMode = .edit,
        wasExecuted: Bool = false
    ) {
        guard let index = directorMessages.firstIndex(where: { $0.id == replyID }) else { return }
        directorMessages[index].text = reply.text
        if mode == .advisory {
            directorRuntimeStatus = reply.runtimeLabel
            directorStatus = "Совет готов · исходник и Timeline не изменены"
            scheduleWorkspaceAutosave()
            return
        }
        let pendingIndex = pendingDirectorInstructions.lastIndex(of: sourceText)
        if let normalizedBrief = reply.normalizedBrief, !normalizedBrief.isEmpty,
           !prompt.localizedCaseInsensitiveContains(normalizedBrief) {
            prompt += "\nРежиссёрская интерпретация: \(normalizedBrief)"
            let originalCommands = EditorCommandParser().parse(sourceText, preset: preset)
            let normalizedCommands = EditorCommandParser().parse(normalizedBrief, preset: preset)
            // The model's canonical wording is useful even when it maps to the
            // same number of commands: it commonly fixes the target or turns a
            // vague visual request into the exact transition/effect vocabulary.
            if !normalizedCommands.isEmpty,
               normalizedCommands.count >= originalCommands.count,
               let pendingIndex {
                pendingDirectorInstructions[pendingIndex] = normalizedBrief
            }
        }
        if !reply.commands.isEmpty,
           let pendingIndex,
           pendingDirectorCommandGroups.indices.contains(pendingIndex) {
            pendingDirectorCommandGroups[pendingIndex] = reply.commands
        }
        directorRuntimeStatus = reply.runtimeLabel
        directorStatus = wasExecuted
            ? "Правка применена · Timeline и Preview обновлены"
            : timeline == nil
                ? "Ответ готов · начинаю собирать фильм"
                : "Ответ готов · применяю правки к фильму"
    }

    private static func naturalLanguageConsumedCategories(_ plan: NaturalLanguageEditingPlan) -> Set<String> {
        var result = Set(plan.commands.map(\.semanticCategory))
        for intent in plan.intents {
            switch intent.operation {
            case .extendMoment: result.insert("duration")
            case .removeMoment: result.insert("delete")
            case .restoreMoment: result.insert("duplicate")
            case .reorder: result.insert("move")
            case .subtitles, .translation: result.insert("add-title")
            case .format, .reframe: result.insert("crop")
            case .audio: result.formUnion(["clip-volume", "clip-muted"])
            default: break
            }
        }
        return result
    }

    private func markFilmNeedsRebuild(_ message: String, instruction: String? = nil) {
        guard project != nil else { return }
        directorRevision += 1
        if let instruction, !instruction.isEmpty {
            pendingDirectorInstructions.append(instruction)
            pendingDirectorCommandGroups.append([])
        }
        hasPendingFilmChanges = true
        directorStatus = message
        scheduleWorkspaceAutosave()
    }

    private func revisionFeedback(instructions: [String], preset: FilmPreset, targetDuration: Double) -> String {
        var parts = instructions
        parts.append("Выбранный стиль: \(preset.localizedTitle).")
        parts.append("Целевая длительность: \(Self.durationText(targetDuration)).")
        return parts.joined(separator: "\n")
    }

    private static func resolvedEditorCommands(
        instructions: [String],
        commandGroups: [[EditorCommand]],
        fallbackPrompt: String,
        preset: FilmPreset
    ) -> [EditorCommand] {
        guard !instructions.isEmpty else {
            // TimelineComposer has already resolved the soundtrack from the
            // full brief. Applying the same setMusic command a second time
            // interpreted it as “replace” and could switch back to an old track.
            return EditorCommandParser().parse(fallbackPrompt, preset: preset).filter {
                $0.semanticCategory != "music"
            }
        }
        return instructions.indices.flatMap { index in
            let deterministic = EditorCommandParser().parse(instructions[index], preset: preset)
            guard commandGroups.indices.contains(index), !commandGroups[index].isEmpty else {
                return deterministic
            }
            let structured = commandGroups[index]
            let structuredCategories = Set(structured.map(\.semanticCategory))
            return deterministic.filter { !structuredCategories.contains($0.semanticCategory) } + structured
        }
    }

    private func consumePendingDirectorInstruction(_ instruction: String) {
        guard let index = pendingDirectorInstructions.lastIndex(of: instruction) else { return }
        pendingDirectorInstructions.remove(at: index)
        if pendingDirectorCommandGroups.indices.contains(index) {
            pendingDirectorCommandGroups.remove(at: index)
        }
        hasPendingFilmChanges = !pendingDirectorInstructions.isEmpty
        scheduleWorkspaceAutosave()
    }

    private func completeFilmBuild(
        revision: Int,
        consumedInstructionCount: Int,
        previousTimeline: Timeline?,
        timeline: Timeline,
        commandReport: EditorCommandReport? = nil,
        usesCompactConfirmation: Bool = false
    ) {
        if directorRevision == revision {
            pendingDirectorInstructions = []
            pendingDirectorCommandGroups = []
            hasPendingFilmChanges = false
        } else {
            let consumed = min(consumedInstructionCount, pendingDirectorInstructions.count)
            if consumed > 0 {
                pendingDirectorInstructions.removeFirst(consumed)
                pendingDirectorCommandGroups.removeFirst(min(consumed, pendingDirectorCommandGroups.count))
            }
            hasPendingFilmChanges = true
        }

        if usesCompactConfirmation {
            appendDirectorNote("Фильм пересобран")
        } else {
            appendDirectorNote(Self.filmRevisionSummary(previous: previousTimeline, current: timeline))
            if let commandReport {
                appendDirectorNote(commandReport.chatSummary)
            }
        }
        directorStatus = hasPendingFilmChanges
            ? "Текущая сборка готова, но есть ещё неприменённые правки"
            : "Правки применены · timeline и просмотр обновлены"
        scheduleWorkspaceAutosave()
    }

    private func scheduleWorkspaceAutosave() {
        guard !isRestoringWorkspaceState, pipeline != nil, project != nil else { return }
        workspaceAutosaveTask?.cancel()
        workspaceAutosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.persistWorkspaceState()
        }
    }

    private func persistWorkspaceState() async {
        guard !isRestoringWorkspaceState, let pipeline, project != nil else { return }
        let state = ProjectWorkspaceState(
            prompt: prompt,
            preset: preset,
            targetMinutes: targetMinutes,
            directorMusicTrackID: directorMusicTrackID,
            directorDraft: directorInput,
            feedbackDraft: feedback,
            pendingDirectorInstructions: pendingDirectorInstructions,
            hasPendingFilmChanges: hasPendingFilmChanges,
            directorMessages: directorMessages
                .filter { !$0.text.isEmpty }
                .map { ProjectDirectorMessage(directorMessage: $0) }
        )
        do {
            try await pipeline.updateWorkspaceState(state)
        } catch {
            errorMessage = "Не удалось автоматически сохранить проект: \(error.localizedDescription)"
        }
    }

    private static func filmRevisionSummary(previous: Timeline?, current: Timeline) -> String {
        guard let previous else {
            return "Готово. Собрал \(current.items.count) фрагментов на \(durationText(current.duration)). Timeline и просмотр обновлены."
        }
        let pairedChanges = zip(previous.items, current.items).filter { old, new in
            old.candidateID != new.candidateID ||
            old.kind != new.kind ||
            abs(old.sourceStart - new.sourceStart) > 0.01 ||
            abs(old.timelineDuration - new.timelineDuration) > 0.01 ||
            old.transition != new.transition ||
            old.effect != new.effect
        }.count
        let changed = pairedChanges + abs(previous.items.count - current.items.count)
        var audioChanges: [String] = []
        if abs(previous.effectiveOriginalAudioVolume - current.effectiveOriginalAudioVolume) > 0.001 {
            audioChanges.append(current.effectiveOriginalAudioVolume < 0.001 ? "звук исходников отключён" : "звук исходников включён")
        }
        if previous.music?.style != current.music?.style {
            audioChanges.append(current.music.map { "саундтрек: \($0.style.localizedTitle.lowercased())" } ?? "саундтрек убран")
        }
        let audioSummary = audioChanges.isEmpty ? "" : " Аудио: \(audioChanges.joined(separator: ", "))."
        return "Правки применены: было \(previous.items.count) фрагментов на \(durationText(previous.duration)), стало \(current.items.count) на \(durationText(current.duration)); изменено \(changed).\(audioSummary) Timeline и просмотр уже обновлены."
    }

    private func appendDirectorNote(_ text: String) {
        directorMessages.append(DirectorMessage(role: .assistant, text: text))
    }

    private func directorContext() -> DirectorContext {
        let assets = project?.assets ?? []
        let analyses = project?.analyses ?? []
        let currentAnalyses = analyses.filter { analysis in
            assets.contains { asset in
                analysis.assetID == asset.id &&
                analysis.analyzedContentHash == asset.contentHash &&
                analysis.schemaVersion == project?.analysisSchemaVersion
            }
        }
        let currentTimeline = timeline
        let selectedIndex = selectedTimelineItemID.flatMap { id in currentTimeline?.items.firstIndex(where: { $0.id == id }) }
        let selectedSummary = selectedIndex.flatMap { index -> String? in
            guard let item = currentTimeline?.items[index] else { return nil }
            return "\(item.storyRole?.localizedTitle ?? item.kind.rawValue), \(Self.durationText(item.timelineDuration)), источник \(item.assetID?.uuidString.prefix(8) ?? "нет")"
        }
        let neighbors: [String] = selectedIndex.map { index in
            guard let items = currentTimeline?.items else { return [] }
            return [index - 1, index + 1].compactMap { neighbor in
                guard items.indices.contains(neighbor) else { return nil }
                let item = items[neighbor]
                return "\(item.storyRole?.localizedTitle ?? item.kind.rawValue) · \(Self.durationText(item.timelineDuration))"
            }
        } ?? []
        var hintCounts: [String: Int] = [:]
        for analysis in currentAnalyses {
            for tag in analysis.sceneTags where !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hintCounts[tag, default: 0] += 1
            }
        }
        let eventHints = (project?.events ?? []).map(\.title).filter { !$0.isEmpty }
        let semanticHints = hintCounts.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(8).map(\.key)
        var seenHints = Set<String>()
        let contentHints = (eventHints + semanticHints).filter { seenHints.insert($0.lowercased()).inserted }.prefix(10)

        var audioCounts: [AudioEventKind: Int] = [:]
        for event in currentAnalyses.flatMap({ $0.audioAnalysis?.events ?? [] }) where event.confidence >= 0.45 {
            audioCounts[event.kind, default: 0] += 1
        }
        let audioHints = audioCounts.sorted {
            $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value
        }.prefix(6).map { "\(Self.audioEventTitle($0.key)): \($0.value) эпиз." }
        return DirectorContext(
            assetCount: assets.count,
            videoCount: assets.filter { $0.kind == .video }.count,
            photoCount: assets.filter { $0.kind == .photo }.count,
            analyzedCount: currentAnalyses.count,
            candidateCount: currentAnalyses.reduce(0) { $0 + $1.candidates.count },
            currentTimelineItemCount: timeline?.items.count ?? 0,
            localMusicTrackCount: musicTracks.count,
            currentMusicTrackTitle: timeline?.music?.trackTitle,
            targetDuration: targetMinutes * 60,
            preset: preset,
            currentOperation: isWorking ? status : "ожидание команды",
            storyRoles: currentTimeline?.items.filter { $0.overlay == nil }.compactMap { $0.storyRole?.localizedTitle } ?? [],
            selectedItemSummary: selectedSummary,
            playheadTime: currentTimeline == nil ? nil : timelinePlayheadTime,
            neighboringItemSummaries: neighbors,
            lastDirectorReviewScore: currentTimeline?.directorRun?.finalReview.score,
            autonomousStyleLabel: currentTimeline?.directorRun?.autonomousDecision?.projectStyle.internalLabel,
            autonomousDurationConfidence: currentTimeline?.directorRun?.autonomousDecision?.duration.confidence,
            autonomousDecisionReasons: Array(currentTimeline?.directorRun?.decisionReasons.prefix(8) ?? []),
            contentHints: Array(contentHints),
            audioHints: audioHints
        )
    }

    private static func audioEventTitle(_ kind: AudioEventKind) -> String {
        switch kind {
        case .speech: return "речь"
        case .laughter: return "смех"
        case .applause: return "аплодисменты"
        case .scream: return "крик"
        case .impact: return "удар"
        case .splash: return "вода"
        case .engine: return "двигатель"
        case .wind: return "ветер/шум"
        case .crowd: return "толпа"
        case .nature: return "природа"
        case .ambient: return "окружение"
        case .music: return "музыка"
        case .silence: return "тишина"
        }
    }

    private func setProgress(
        _ item: ImportProgress,
        base: Double = 0,
        span: Double = 1,
        phase: String? = nil,
        showsAnalysisFileProgress: Bool = false
    ) {
        let localProgress = item.total == 0 ? 0 : Double(item.completed) / Double(item.total)
        progress = min(1, max(0, base + localProgress * span))
        activityCompleted = item.completed
        activityTotal = item.total
        let progressLabel: String
        if showsAnalysisFileProgress, let fileIndex = item.currentFileIndex, let fileCount = item.fileCount {
            var components = ["Видео \(fileIndex) из \(fileCount)"]
            if let sceneIndex = item.currentSceneIndex, let sceneCount = item.sceneCount, sceneCount > 0 {
                components.append("сцена \(sceneIndex) из \(sceneCount)")
            }
            if let eta = item.estimatedSecondsRemaining, eta.isFinite, eta > 0 {
                components.append("осталось примерно \(Self.etaText(eta))")
            }
            if item.thermalThrottled { components.append("снижена нагрузка") }
            progressLabel = components.joined(separator: " · ")
        } else if showsAnalysisFileProgress, item.total > 0 {
            let totalFiles = max(1, item.total / 100)
            let isCompletedFile = item.currentName.hasPrefix("Анализ готов ·")
            let fileNumber: Int
            let filePercent: Int
            if item.completed >= item.total {
                fileNumber = totalFiles
                filePercent = 100
            } else if isCompletedFile {
                fileNumber = max(1, min(totalFiles, item.completed / 100))
                filePercent = 100
            } else {
                fileNumber = max(1, min(totalFiles, item.completed / 100 + 1))
                filePercent = max(0, min(100, item.completed % 100))
            }
            progressLabel = "Файл \(fileNumber) из \(totalFiles), \(filePercent)%."
        } else if item.total > 0 {
            progressLabel = "\(item.completed) из \(item.total)"
        } else {
            progressLabel = ""
        }
        activityProgressLabel = progressLabel
        activityFileName = showsAnalysisFileProgress ? (item.currentFileName ?? "") : ""
        if showsAnalysisFileProgress,
           let eta = item.estimatedSecondsRemaining,
           eta.isFinite,
           eta > 0 {
            activityTimeRemaining = Self.etaText(eta)
        } else {
            activityTimeRemaining = ""
        }
        let detail = progressLabel.isEmpty ? item.currentName : "\(item.currentName) · \(progressLabel)"
        status = phase.map { "\($0): \(detail)" } ?? detail
    }

    private static func etaText(_ seconds: TimeInterval) -> String {
        let rounded = max(1, Int(seconds.rounded()))
        if rounded < 60 { return "\(rounded) с" }
        let minutes = rounded / 60
        let remainder = rounded % 60
        if minutes < 10, remainder > 0 { return "\(minutes) мин \(remainder) с" }
        return "\(minutes) мин"
    }

    private func run(
        _ initialStatus: String,
        presentation: ActivityPresentation = .standard,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !isWorking else { return }
        activityDismissTask?.cancel()
        activityDismissTask = nil
        isWorking = true
        activityPresentation = presentation
        isActivityPanelVisible = presentation != .silentEditor
        isActivityComplete = false
        activityTitle = initialStatus
        activityCompleted = 0
        activityTotal = 0
        activityProgressLabel = ""
        activityFileName = ""
        activityTimeRemaining = ""
        status = initialStatus
        progress = 0
        activeTask = Task {
            var completedSuccessfully = false
            do {
                try await operation()
                completedSuccessfully = true
            } catch is CancellationError {
                status = "Операция отменена"
            } catch {
                errorMessage = error.localizedDescription
                status = "Ошибка"
            }
            isWorking = false
            activeTask = nil
            if presentation == .silentEditor {
                isActivityPanelVisible = false
            } else {
                isActivityComplete = completedSuccessfully
                if completedSuccessfully { progress = 1 }
                activityDismissTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(completedSuccessfully ? 3.2 : 1.5))
                    guard !Task.isCancelled else { return }
                    self?.isActivityPanelVisible = false
                    self?.isActivityComplete = false
                    self?.activityCompleted = 0
                    self?.activityTotal = 0
                    self?.activityProgressLabel = ""
                    self?.activityFileName = ""
                    self?.activityTimeRemaining = ""
                    self?.activityDismissTask = nil
                }
            }
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.startNextQueuedTimelineAIEdit()
            }
        }
    }

    private func startTimelineAIEdit(_ edit: PendingTimelineAIEdit) {
        if let range = edit.range {
            applyMagicBrush(edit.instruction, to: range)
        } else {
            feedback = edit.instruction
            regenerate()
        }
    }

    private func startNextQueuedTimelineAIEdit() {
        guard !isWorking, !pendingTimelineAIEdits.isEmpty else { return }
        let edit = pendingTimelineAIEdits.removeFirst()
        queuedTimelineAIEditCount = pendingTimelineAIEdits.count
        startTimelineAIEdit(edit)
    }
}
