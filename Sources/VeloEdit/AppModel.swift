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
    case settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Главная"
        case .media: return "Медиатека"
        case .director: return "Умный режиссёр"
        case .timeline: return "Монтаж"
        case .export: return "Экспорт"
        case .settings: return "Настройки"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"
        case .media: return "photo.on.rectangle.angled"
        case .director: return "wand.and.stars"
        case .timeline: return "timeline.selection"
        case .export: return "square.and.arrow.up"
        case .settings: return "gearshape"
        }
    }
}

enum WorkspaceSettingsTab: String, CaseIterable {
    case general = "Основные"
    case storage = "Хранилище"
    case keyboardShortcuts = "Горячие клавиши"
}

enum DirectorMessageRole: Sendable {
    case user
    case assistant
}

struct DirectorMessage: Identifiable, Sendable {
    let id: UUID
    let role: DirectorMessageRole
    var text: String
    var response: DirectorResponseRecord? = nil
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
            text: "Расскажите, каким должен быть фильм, или ответьте на вопросы."
        )]
    }
}

enum ActivityPresentation {
    case standard
    case editorAI
    case silentEditor
}

@MainActor
final class TimelinePlaybackClock: ObservableObject {
    @Published fileprivate(set) var time: Double = 0
}

private extension DirectorMessage {
    init(projectMessage: ProjectDirectorMessage) {
        self.init(
            id: projectMessage.id,
            role: projectMessage.role == .user ? .user : .assistant,
            text: projectMessage.text,
            createdAt: projectMessage.createdAt
        )
        response = projectMessage.response
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
        response = directorMessage.response
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
    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private struct DirectorBriefFieldChanges: OptionSet {
        let rawValue: Int

        static let duration = DirectorBriefFieldChanges(rawValue: 1 << 0)
        static let mood = DirectorBriefFieldChanges(rawValue: 1 << 1)
        static let music = DirectorBriefFieldChanges(rawValue: 1 << 2)
        static let sourceAudio = DirectorBriefFieldChanges(rawValue: 1 << 3)
        static let titles = DirectorBriefFieldChanges(rawValue: 1 << 4)
    }

    private struct TimelineAIAnchor: Equatable {
        struct Item: Equatable {
            let id: UUID
            let timelineStart: Double
            let timelineDuration: Double
        }

        let timelineID: UUID
        let primaryItems: [Item]

        init(_ timeline: Timeline) {
            timelineID = timeline.id
            primaryItems = timeline.items
                .filter { $0.overlay == nil && $0.kind != .title }
                .map { Item(id: $0.id, timelineStart: $0.timelineStart, timelineDuration: $0.timelineDuration) }
        }
    }

    private struct PendingTimelineAIEdit {
        let instruction: String
        let replyID: UUID
        let range: ClosedRange<Double>?
        let timelineAnchor: TimelineAIAnchor?
        let selectedItemID: UUID?
        let selectedItemIsTitle: Bool
        let selectedCandidateID: UUID?
        let playheadTime: Double
        let preset: FilmPreset
        let targetDuration: Double?
        let preferredMusicTrackID: UUID?
        let directorBrief: DirectorBrief
        let briefChanges: DirectorBriefFieldChanges
        var retryCount: Int = 0
        var trace: PerformanceTrace? = nil
        var proposal: DirectorEditProposal? = nil
    }

    private static let recentProjectsKey = "recentProjectPaths.v1"
    let intro: FirstLaunchCoordinator
    private static let projectLibraryKey = "projectLibraryPaths.v1"
    private let defaults: UserDefaults
    private static let freeToUseLicenseAcceptedKey = "freeToUseLicenseAccepted.v1"
    private static let defaultDirectorBrief = "Сделай связный фильм из лучших моментов. Начни спокойно, затем добавь динамики и закончи красивым финалом."
    /// A 16:9 preview becomes 1920x1080 (1080x1920 in portrait). The matching
    /// render-quality policy also bounds custom aspect ratios without changing
    /// their editable or exported resolution.
    nonisolated static let interactivePreviewQuality: RenderQuality = .preview1080p
    nonisolated static let interactivePreviewLongEdge = 1_920
    @Published var project: ProjectManifest? {
        didSet {
            cachedPlaybackMap = nil
            cachedTimelineAssets = nil
            rebuildDirectorMomentIndex()
        }
    }
    private var cachedTimelineAssets: [UUID: MediaAsset]?
    private var directorContextRevision: UInt64 = 0
    private var directorMomentIndexTask: Task<DirectorMomentIndex?, Never>?
    private var directorAdviceReplyID: UUID?
    private struct AdviceContinuation {
        let prompt: String
        let context: DirectorContext
        let range: ClosedRange<Double>?
        let projectID: UUID?
        let revision: UInt64
    }
    private var directorAdviceContinuation: AdviceContinuation?
    private var directorMemoryPressure: DispatchSourceMemoryPressure?

    private func rebuildDirectorMomentIndex() {
        directorContextRevision &+= 1
        directorAdviceContinuation = nil
        directorMomentIndexTask?.cancel()
        let snapshot = project
        let revision = directorContextRevision
        directorMomentIndexTask = Task.detached(priority: .utility) {
            guard !Task.isCancelled, let snapshot else { return nil }
            return DirectorMomentIndex(project: snapshot, revision: revision)
        }
        if directorMemoryPressure == nil {
            let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            pressure.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.directorMomentIndexTask?.cancel()
                    self?.directorMomentIndexTask = nil
                    self?.directorAdviceContinuation = nil
                }
            }
            pressure.resume()
            directorMemoryPressure = pressure
        }
    }


    func timelineMediaAsset(_ id: UUID) -> MediaAsset? {
        if cachedTimelineAssets == nil {
            cachedTimelineAssets = Dictionary((project?.assets ?? []).map { ($0.id, $0) },
                                               uniquingKeysWith: { first, _ in first })
        }
        return cachedTimelineAssets?[id]
    }
    @Published var showsMissingMedia = false
    @Published var storageProjects: [ProjectStorageUsage] = []
    @Published var storageModels: [InstalledAIModel] = []
    @Published var storageModelsMessage = ""
    @Published var storageIsLoading = false
    @Published var storageIsCleaning = false
    private var storageTask: Task<Void, Never>?
    private var manualProjectAfterCreation = false
    private var needsCacheRefreshAfterCleanup = false
    var missingMediaAssets: [MediaAsset] { project?.assets.filter(\.missing) ?? [] }
    var hasActiveWork: Bool { isWorking || isDirectorResponding || openingProjectURL != nil }
    @Published var projectURL: URL?
    @Published private(set) var videoExportDirectory: URL?
    @Published private(set) var openingProjectURL: URL?
    @Published private(set) var openingProjectName: String?
    @Published private(set) var openingPresentation: ProjectLibrary.OpeningPresentation?
    @Published private(set) var openingSelectedAssetID: UUID?
    @Published private(set) var openingSelectedMusicTrackID: UUID?
    private var openingPresentationTask: Task<Void, Never>?
    private var preparedProjectPresentations: [URL: ProjectLibrary.OpeningPresentation] = [:]
    private var presentationLoads: [URL: Task<ProjectLibrary.OpeningPresentation?, Never>] = [:]

    var mediaLibraryAssets: [MediaAsset] {
        if openingProjectURL != nil { return openingPresentation?.preview.assets ?? [] }
        let order = Dictionary((project?.sourceMap?.entries ?? []).map { ($0.assetID, $0.order) },
                               uniquingKeysWith: { first, _ in first })
        return ProjectOpeningPreview.sortedMediaAssets(project?.assets ?? [], order: order)
    }
    var mediaLibraryMusicTracks: [LocalMusicTrack] {
        openingProjectURL == nil ? musicTracks : (openingPresentation?.music ?? [])
    }
    var mediaLibraryThumbnailURLs: [UUID: URL] {
        openingProjectURL == nil ? thumbnailURLs : (openingPresentation?.thumbnails ?? [:])
    }
    var mediaLibrarySelectedAssetID: UUID? {
        openingProjectURL == nil ? selectedAssetID : openingSelectedAssetID
    }
    var mediaLibrarySelectedMusicTrackID: UUID? {
        openingProjectURL == nil ? selectedMusicTrackID : openingSelectedMusicTrackID
    }
    @Published private(set) var isPresentingNewProject = false
    @Published private(set) var isCreatingProject = false
    @Published var newProjectDraft = NewProjectDraft(directoryURL:
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser)
    @Published private(set) var newProjectError: String?
    private var sectionBeforeProjectCreation: WorkspaceSection?
    var hasProjectWorkspace: Bool { project != nil || openingProjectURL != nil }
    @Published var selectedAssetID: UUID?
    @Published var selectedMusicTrackID: UUID?
    @Published var selectedTimelineItemID: UUID?
    @Published var selectedTimelineAudioClipID: UUID?
    @Published var selectedTelemetryItemID: UUID?
    @Published var selectedEffectTimelineItemID: UUID?
    @Published private(set) var titleEditStatus: String?
    @Published var selectedTitleTimelineItemID: UUID?
    @Published var selectedTransitionTimelineItemID: UUID?
    @Published private(set) var selectedTimelineItemIDs: Set<UUID> = []
    @Published private(set) var selectedTimelineAudioClipIDs: Set<UUID> = []
    @Published private(set) var selectedTelemetryItemIDs: Set<UUID> = []
    @Published private(set) var selectedEffectTimelineItemIDs: Set<UUID> = []
    @Published private(set) var selectedTitleTimelineItemIDs: Set<UUID> = []
    @Published private(set) var selectedTransitionTimelineItemIDs: Set<UUID> = []
    @Published var selectedSoundtrack = false
    let playbackClock = TimelinePlaybackClock()
    private(set) var timelinePlayheadTime: Double {
        get { playbackClock.time }
        set { if playbackClock.time != newValue { playbackClock.time = newValue } }
    }
    @Published var settingsTab: WorkspaceSettingsTab = .general
    @Published var section: WorkspaceSection = .home {
        didSet {
            // Some inspector and playback actions navigate directly. Do not
            // leave an invisible creation form blocking the next New action.
            if section != .home, isPresentingNewProject, !isCreatingProject {
                isPresentingNewProject = false
                sectionBeforeProjectCreation = nil
                newProjectError = nil
            }
        }
    }
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
    @Published var speechPackageStatus = "Проверяю речевой пакет"
    @Published var speechPackageInstalled = false
    @Published var speechPackageProgress: Double = 0
    @Published var preset: FilmPreset = .adventure { didSet { scheduleWorkspaceAutosave() } }
    @Published var targetMinutes = 2.0 { didSet { scheduleWorkspaceAutosave() } }
    @Published var directorBrief: DirectorBrief = .legacyDefault { didSet { scheduleWorkspaceAutosave() } }
    @Published private(set) var directorMusicTrackID: UUID? { didSet { scheduleWorkspaceAutosave() } }
    @Published var status = "Создайте или откройте проект"
    @Published var progress = 0.0
    @Published var activityTitle = ""
    @Published var activityCompleted = 0
    @Published var activityTotal = 0
    @Published var activityProgressLabel = ""
    @Published var activityFileName = ""
    @Published var activityTimeRemaining = ""
    @Published private(set) var activityUnmeasuredStartedAt: Date?
    @Published private(set) var activityStageProgress: Double?
    @Published private(set) var recoverableFilmBuild: FilmBuildRecovery?
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
    @Published var thumbnailURLs: [UUID: URL] = [:]
    @Published var timelineThumbnailURLs: [UUID: URL] = [:]
    @Published var timelineFilmstripURLs: [UUID: URL] = [:]
    @Published private(set) var musicTracks: [LocalMusicTrack] = []
    @Published private(set) var musicLibraryStatus = MusicLibraryStatus()
    @Published var errorMessage: String? {
        didSet {
            guard let errorMessage, errorMessage != oldValue else { return }
            AppNotifications.shared.send(title: "Ошибка VeloEdit", body: errorMessage)
        }
    }
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isImporting = false
    @Published private(set) var hasPendingFilmChanges = false { didSet { scheduleWorkspaceAutosave() } }
    @Published private(set) var recentProjectURLs: [URL] = []
    @Published private(set) var usageStatistics = AppUsageStatistics()
    private var knownProjectURLs: [URL] = []
    private var usageStatisticsTask: Task<Void, Never>?
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var updateStatusText = "Проверка запускается вручную"
    @Published private(set) var availableUpdateURL: URL?
    @Published private(set) var availableUpdateVersion: String?
    @Published var editorialComparison: EditorialComparisonSession?
    @Published var showEditorialStyle = false
    private var editorialPreparationTask: Task<Void, Never>?
    @Published private(set) var canUndoTimelineEdit = false
    @Published private(set) var canRedoTimelineEdit = false
    var pipeline: VeloEditPipeline?
    private var activePlayback: TimelinePlayback?
    private var playbackTimeObserver: Any?
    private var playbackItemStatusObservation: NSKeyValueObservation?
    private var filmVerificationTask: Task<Void, Never>?
    @Published private(set) var filmVerificationMessage = ""
    private var editTrace: PerformanceTrace?
    private var previewEditTrace: PerformanceTrace?
    private var previewEditRevision: UInt64?
    private var previewEditStarted: Double?
    private var previewStateLatency: Double?
    private var previewPosterTask: Task<Void, Never>?
    private var previewPosterRequestID: UUID?
    private var previewPosterPlaybackID: ObjectIdentifier?
    private var previewPosterPlaybackTime: Double?
    private var previewPlayerFrameReady = false
    /// While a rebuilt composition is seeking back to the edited frame, keep
    /// the timeline playhead pinned there instead of briefly accepting the new
    /// AVPlayerItem's initial zero time.
    private var pendingPlaybackSeekTimelineTime: Double?
    private var activeTask: Task<Void, Never>?
    private var pendingTimelineAIEdits: [PendingTimelineAIEdit] = []
    private var activeTimelineAIEdit: PendingTimelineAIEdit?
    private var needsTimelineAIRetryAfterManualEdit = false
    private var activityDismissTask: Task<Void, Never>?
    private var activityETATask: Task<Void, Never>?
    private var activityFilmBuildStage: FilmBuildProgress.Stage?
    private var activityEstimatedCompletionUptime: TimeInterval?
    private var activityProgressEstimate = ActivityTimeEstimate()
    private var activityProgressStage: String?
    private var filmBuildTimeEstimate: FilmBuildTimeEstimate?
    private static let filmTimingCalibrationKey = "filmTimingCalibration.v1"
    private var projectRestoreTask: Task<Void, Never>?
    private var projectOpenTask: Task<Void, Never>?
    private var sectionBeforeProjectOpen: WorkspaceSection?
    private let loadProject: @Sendable (URL) async throws -> ProjectStore
    private var directorTask: Task<Void, Never>?
    private var directorGeneration: UInt64 = 0
    private var queuedDirectorMessages: [String] = []
    private var hasQueuedFilmRequest = false
    @Published private(set) var newMaterialCount = 0 { didSet { scheduleWorkspaceAutosave() } }
    @Published private(set) var importWarnings: [String] = []
    @Published private(set) var activityStartedUptime: TimeInterval?
    private var workspaceAutosaveTask: Task<Void, Never>?
    private var timelineCommitTask: Task<Void, Never>?
    private var timelinePersistenceFailed = false
    private var hasUnpersistedTimelineEdits = false
    private var externalResourceWaitTask: Task<Void, Never>?
    private var previewRebuildTask: Task<Void, Never>?
    private var previewSeekRevision: UInt64 = 0
    private var cachedPlaybackMap: TimelineTiming.PlaybackMap?
    private var playbackMap: TimelineTiming.PlaybackMap? {
        if let cachedPlaybackMap { return cachedPlaybackMap }
        guard let timeline else { return nil }
        let map = TimelineTiming.PlaybackMap(timeline: timeline)
        cachedPlaybackMap = map
        return map
    }
    private lazy var previewSeeker = TimelinePreviewSeeker { [weak self] request, finished in
        guard let self, let player = self.previewPlayer, let item = player.currentItem else {
            finished()
            return
        }
        let revision = self.previewSeekRevision
        let target = CMTime(seconds: request.time, preferredTimescale: 600)
        let tolerance = request.exact ? CMTime.zero
            : CMTime(seconds: 1 / max(15, request.frameRate), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] completed in
            Task { @MainActor in
                if let self, completed, self.previewPlayer === player,
                   player.currentItem === item, self.previewSeekRevision == revision {
                    self.showReadyPreviewPlayerFrame()
                }
                finished()
            }
        }
    }
    private var timelineEditRevision: UInt64 = 0
    private var operationGeneration: UInt64 = 0
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
    private let directorAgent: LocalDirectorAgent
    private let personalTasteStore: LocalPersonalTasteStore

    var timeline: Timeline? { project?.timelines.last }
    /// Long AI editor work is optimistic background work, not a reason to
    /// freeze direct manipulation. Import/export and destructive jobs remain
    /// exclusive, while timeline gestures stay available during editor AI.
    var isTimelineInteractionBlocked: Bool {
        isWorking && activityPresentation != .editorAI
    }
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
        musicTracks.first { $0.id == directorMusicTrackID }
    }
    var directorMusicSelectionTitle: String {
        if let directorMusicTrack { return "Трек: \(directorMusicTrack.title)" }
        switch directorBrief.musicPolicy {
        case .matchVideo: return "Музыка: автоподбор"
        case .soft: return "Музыка: мягкая"
        case .none: return "Музыка: выключена"
        case .specificTrack: return "Музыка: трек недоступен"
        }
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
        guard let timeline else { return 30 }
        return ExportSettingsPolicy.maximumSourceFrameRate(timeline: timeline, assets: project?.assets ?? [])
    }
    var exportFrameRateOptions: [Double] {
        let standard = [24.0, 25.0, 30.0, 50.0, 60.0, 120.0, 240.0]
        let fractional = [24_000.0 / 1001, 30_000.0 / 1001, 60_000.0 / 1001]
        let maximum = timeline.map {
            min(240, max($0.frameRate, ExportSettingsPolicy.maximumSourceFrameRate(timeline: $0, assets: project?.assets ?? [])))
        } ?? 30
        return Array(Set(standard.filter { $0 <= maximum + 0.001 } + fractional.filter { $0 <= maximum + 0.001 } + [maximum, maximumSourceFrameRate])).sorted()
            .reduce(into: [Double]()) { values, value in
                if values.last.map({ abs($0 - value) > 0.001 }) ?? true { values.append(value) }
            }
    }
    func exportSettingsSummary(quality: RenderQuality, frameRate: Double? = nil) -> String {
        guard let timeline else { return "Сначала создайте монтаж" }
        let resolved = ExportSettingsPolicy.timeline(timeline, assets: project?.assets ?? [], quality: quality, frameRate: frameRate)
        return ExportVideoSettings(timeline: resolved, quality: quality).summary
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
    var canDownloadAIModel: Bool { true }
    func isAIModelInstalled(for mode: AIPowerMode) -> Bool {
        return aiModelAvailability[mode] ?? (mode == aiPowerMode && aiVisionModelInstalled)
    }
    func canDownloadAIModel(for mode: AIPowerMode) -> Bool {
        return true
    }
    var aiAnalysisRuntimeStatus: String {
        guard let result = project?.analyses.last else { return "Runtime будет проверен при первом анализе" }
        let speech = result.deepMediaDiagnostics?.stages.first { $0.stage == .asr }
        let speechStatus = speech?.ran == true ? "Речь распознана локально"
            : speech?.reason.contains("недоступен") == true ? "Распознавание речи недоступно" : nil
        return [result.aiRuntimeLabel, result.aiExecution?.summary, result.aiExecution?.modelQuantization, speechStatus]
            .compactMap { $0 }.joined(separator: " · ")
    }
    var aiAnalysisDetail: String {
        let samples = project?.analyses.compactMap(\.sampledFrameCount).reduce(0, +) ?? 0
        let deep = project?.analyses.compactMap(\.deepAnalyzedCandidateCount).reduce(0, +) ?? 0
        let decoded = project?.analyses.compactMap(\.metrics?.decodedFrameCount).reduce(0, +) ?? 0
        let cacheHits = project?.analyses.compactMap(\.metrics?.frameCacheHitCount).reduce(0, +) ?? 0
        let vlmCalls = project?.analyses.compactMap(\.metrics?.vlmCallCount).reduce(0, +) ?? 0
        let vlmReused = project?.analyses.compactMap(\.metrics?.vlmCacheHitCount).reduce(0, +) ?? 0
        let telemetry = project?.analyses.compactMap(\.telemetry?.timedSamples?.count).reduce(0, +) ?? 0
        if samples == 0 { return "Proxy → адаптивная выборка → лучшие моменты → глубокий анализ" }
        let telemetryStatus = telemetry > 0 ? " · синхронизировано точек телеметрии: \(telemetry)" : ""
        return "Кадров: \(samples) · декодировано: \(decoded) · из кэша: \(cacheHits) · VLM-попыток: \(vlmCalls), из кэша: \(vlmReused) · глубоко проверено: \(deep)\(telemetryStatus)"
    }
    var aiThermalStatus: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Температура нормальная"
        case .fair: return "Нагрузка умеренная"
        case .serious: return "Обработка идёт меньшими порциями для охлаждения"
        case .critical: return "Паузы для охлаждения · объём анализа сохранён"
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
                $0.schemaVersion == project.analysisSchemaVersion &&
                $0.deepMediaVersion == DeepAnalysisCache.version &&
                analysis($0, satisfies: aiProfile)
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
    var timelinePersistenceStatus: String {
        if timelinePersistenceFailed { return "Не сохранено — повторите сохранение" }
        if hasUnpersistedTimelineEdits { return "Изменение применено · сохраняется" }
        if !filmVerificationMessage.isEmpty { return filmVerificationMessage }
        guard let timeline else { return "" }
        if let report = timeline.filmDeliveryReport, report.isCurrent(for: timeline) {
            return report.status == .verified ? "Сохранено · проверено" : "Сохранено · есть замечания проверки"
        }
        return "Сохранено · проверка требуется"
    }

    private func scheduleFilmVerification() {
        filmVerificationTask?.cancel()
        guard let pipeline, let current = timeline,
              project?.storyPlans.contains(where: { $0.id == current.storyPlanID }) == true else { return }
        let revision = timelineEditRevision
        let signature = EditorialRenderSignature.signature(current)
        filmVerificationMessage = "Сохранено · проверяется"
        filmVerificationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                guard let self, self.pipeline === pipeline, self.timelineEditRevision == revision,
                      self.timeline.map(EditorialRenderSignature.signature) == signature else { return }
                if self.isWorking || self.isDirectorResponding {
                    self.filmVerificationMessage = "Сохранено · проверка ожидает завершения операции"
                    return
                }
                let activity = WorkActivity(reason: "Проверка фильма VeloEdit")
                defer { withExtendedLifetime(activity) {} }
                let checked = try await pipeline.verifyCurrentFilm()
                try Task.checkCancellation()
                guard self.pipeline === pipeline, self.timelineEditRevision == revision,
                      self.timeline.map(EditorialRenderSignature.signature) == signature else { return }
                await self.refresh()
                self.filmVerificationMessage = checked.filmDeliveryReport?.status == .verified
                    ? "Сохранено · проверено" : "Сохранено · есть замечания проверки"
                self.editTrace?.event("edit.verification.finished", fields: ["status": self.filmVerificationMessage])
            } catch is CancellationError { }
            catch {
                guard let self, self.pipeline === pipeline, self.timelineEditRevision == revision else { return }
                self.filmVerificationMessage = "Сохранено · проверка не завершена"
            }
        }
    }

    var filmReadinessStatus: String {
        if isCreatingFilm { return status }
        if hasUnpersistedTimelineEdits || !filmVerificationMessage.isEmpty { return timelinePersistenceStatus }
        if hasPendingFilmChanges {
            return timeline == nil
                ? "Замысел изменён — нужно создать фильм"
                : "Есть неприменённые правки — текущий просмотр показывает предыдущую версию"
        }
        if let timeline, let report = timeline.filmDeliveryReport, report.isCurrent(for: timeline) {
            return report.completionMessage
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
                $0.deepMediaVersion == DeepAnalysisCache.version &&
                analysis($0, satisfies: aiProfile)
            }
        }
    }

    private func analysis(_ result: AnalysisResult, satisfies profile: AIAnalysisProfile) -> Bool {
        result.satisfies(profile)
            && result.directorCandidates.contains { !$0.excluded && $0.sourceDuration > 0.05 }
            && ((result.completedDepth ?? .quick) > profile.targetDepth || result.analysisProfileKey == profile.cacheKey)
    }

    init(defaults: UserDefaults = .standard, startBackgroundServices: Bool = true,
         personalTasteStore: LocalPersonalTasteStore = LocalPersonalTasteStore(),
         directorAgent: LocalDirectorAgent? = nil,
         loadProject: @escaping @Sendable (URL) async throws -> ProjectStore = { url in
             try await Task.detached(priority: .userInitiated) { try ProjectStore(open: url) }.value
         }) {
        self.defaults = defaults
        self.intro = FirstLaunchCoordinator(defaults: defaults)
        self.directorAgent = directorAgent ?? LocalDirectorAgent()
        self.personalTasteStore = personalTasteStore
        self.loadProject = loadProject
        let paths = defaults.stringArray(forKey: Self.recentProjectsKey) ?? []
        let recentURLs = ProjectLibrary.uniqueURLs(paths.map { URL(fileURLWithPath: $0) })
        recentProjectURLs = Array(recentURLs.prefix(12))
        let libraryPaths = defaults.stringArray(forKey: Self.projectLibraryKey) ?? []
        knownProjectURLs = ProjectLibrary.uniqueURLs(libraryPaths.map { URL(fileURLWithPath: $0) } + recentURLs)
        defaults.set(knownProjectURLs.map(\.path), forKey: Self.projectLibraryKey)
        guard startBackgroundServices else { return }
        refreshUsageStatistics()
        Task(priority: .utility) { await refreshDirectorRuntimeStatus() }
        Task(priority: .utility) { await refreshLocalVisionModelStatus(startService: false) }
    }

    func createProject() {
        intro.accept(.projectCommand)
        guard !storageIsCleaning else { return }
        // Let the welcome button finish its gesture before replacing its view.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.openingProjectURL == nil, !self.isCreatingProject,
                  !self.isPresentingNewProject else { return }
            let directory = self.defaults.url(forKey: "newProjectDirectory.v1")
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            self.newProjectDraft = NewProjectDraft(directoryURL: directory)
            self.newProjectError = nil
            self.sectionBeforeProjectCreation = self.section
            self.previewPlayer?.pause()
            self.section = .home
            self.isPresentingNewProject = true
        }
    }

    func beginManualOnboarding() {
        if pipeline != nil { startManualEditing() }
        else { manualProjectAfterCreation = true; createProject() }
    }

    func cancelProjectCreation() {
        guard isPresentingNewProject, !isCreatingProject else { return }
        isPresentingNewProject = false
        manualProjectAfterCreation = false
        newProjectError = nil
        if let previous = sectionBeforeProjectCreation { section = previous }
        sectionBeforeProjectCreation = nil
    }

    func chooseNewProjectDirectory() {
        guard isPresentingNewProject, !isCreatingProject else { return }
        let panel = NSOpenPanel()
        panel.title = "Папка для нового проекта"
        panel.prompt = "Выбрать папку"
        panel.directoryURL = newProjectDraft.directoryURL
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newProjectDraft.directoryURL = url
        newProjectError = nil
    }

    func confirmProjectCreation() async {
        guard isPresentingNewProject, !isCreatingProject, openingProjectURL == nil else { return }
        let draft = newProjectDraft
        if let message = draft.validationMessage { newProjectError = message; return }
        newProjectError = nil
        isCreatingProject = true
        defer { isCreatingProject = false }
        guard await flushAutosave() else { return }
        do {
            let store = try await Task.detached(priority: .userInitiated) { try draft.makeStore() }.value
            resetProjectUI()
            pipeline = VeloEditPipeline(store: store, personalTasteStore: personalTasteStore)
            projectURL = draft.packageURL
            rememberProject(draft.packageURL)
            defaults.set(draft.directoryURL, forKey: "newProjectDirectory.v1")
            await refresh()
            isPresentingNewProject = false
            sectionBeforeProjectCreation = nil
            section = .media
            status = "Проект создан — перетащите фотографии, видео или музыку"
            if manualProjectAfterCreation {
                manualProjectAfterCreation = false
                startManualEditing()
            }
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileWriteFileExistsError {
                newProjectError = "Проект с таким названием уже существует. Измените название или папку."
            } else {
                newProjectError = "Не удалось создать проект: \(error.localizedDescription)"
            }
        }
    }

    static func makeProjectOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Открыть проект VeloEdit"
        panel.allowedContentTypes = [UTType(exportedAs: "app.veloedit.project", conformingTo: .package)]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        return panel
    }

    private var projectOpenPanel: NSOpenPanel?

    func openProject() {
        intro.accept(.projectCommand)
        guard !storageIsCleaning else { return }
        guard !isCreatingProject, projectOpenPanel == nil else { return }
        let panel = Self.makeProjectOpenPanel()
        projectOpenPanel = panel
        // Return from SwiftUI's button/menu action before presenting AppKit's
        // panel. A nested runModal loop can dispatch project changes while the
        // originating gesture and its view are still on the stack.
        DispatchQueue.main.async { [weak self] in
            let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                self?.projectOpenPanel = nil
                guard response == .OK, let url = panel.url else { return }
                self?.openProject(at: url)
            }
            if let window = NSApplication.shared.mainWindow {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }
    }

    func openRecentProject(_ url: URL, name: String? = nil) {
        openProject(at: url, name: name)
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
        let currentName = ProjectSummary.load(from: url)?.name
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
                let store = try await Task.detached(priority: .userInitiated) {
                    try ProjectStore(open: url)
                }.value
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
        // Finish the card's menu action before removing its backing entry.
        DispatchQueue.main.async { [weak self] in
            self?.performRecentProjectDeletion(url)
        }
    }

    private func recentProjectFileIsMissing(_ url: URL) -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return false
        } catch {
            let error = error as NSError
            // Access failures must not be mistaken for an already deleted file.
            return error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
        }
    }

    private func finishRecentProjectDeletion(_ url: URL, wasMissing: Bool) {
        forgetRecentProject(url)
        if projectURL?.standardizedFileURL == url.standardizedFileURL {
            resetProjectUI()
            pipeline = nil
            section = .home
        }
        status = wasMissing ? "Проект удалён из списка" : "Проект перемещён в Корзину"
    }

    private func performRecentProjectDeletion(_ url: URL) {
        guard !hasActiveWork, !storageIsCleaning else { return }
        if recentProjectFileIsMissing(url) { forgetStoredProject(url); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Переместить проект в Корзину?"
        alert.informativeText = "Пакет «\(url.deletingPathExtension().lastPathComponent)» будет перемещён целиком: монтаж, анализ, история, кэш и вложенные материалы. Внешние исходники и экспорт за пределами пакета сохранятся. Проект можно восстановить из Корзины; место освободится после её очистки в Finder."
        alert.addButton(withTitle: "Переместить в Корзину")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { if let result = await trashStoredProjects([url]) { status = result } }
    }

    private func openProject(at url: URL, destination: WorkspaceSection = .media, name: String? = nil) {
        intro.accept(.projectCommand)
        guard !storageIsCleaning else { return }
        // A recent-project card lives inside a ForEach backed by
        // `recentProjectURLs`. Opening it also moves that URL to the front of
        // the list. If we publish those changes while SwiftUI is still
        // dispatching the card's ButtonGesture, the pressed button can be
        // destroyed underneath the gesture (and SwiftUI crashes in
        // MainActor.assumeIsolated). Start the state transition on the next
        // main-run-loop turn, after the click has fully completed.
        DispatchQueue.main.async { [weak self] in
            self?.performProjectOpen(at: url, destination: destination, name: name)
        }
    }

    private func performProjectOpen(at url: URL, destination: WorkspaceSection, name: String?) {
        guard !isCreatingProject, !storageIsCleaning else { return }
        cancelProjectCreation()
        guard openingProjectURL?.standardizedFileURL != url.standardizedFileURL else {
            section = destination
            return
        }
        projectOpenTask?.cancel()
        if openingProjectURL == nil { sectionBeforeProjectOpen = section }
        openingProjectURL = url
        openingProjectName = name ?? url.deletingPathExtension().lastPathComponent
        openingPresentationTask?.cancel()
        openingSelectedAssetID = nil
        openingSelectedMusicTrackID = nil
        openingPresentation = preparedProjectPresentations[url.standardizedFileURL]
        openingPresentationTask = Task { [weak self] in
            guard let self else { return }
            let presentation = await prepareProjectPresentation(at: url)
            guard !Task.isCancelled, openingProjectURL == url else { return }
            openingPresentation = presentation
            if name == nil, let presentation { openingProjectName = presentation.preview.name }
        }
        // Present the destination on the next click-safe run-loop turn. Keep
        // the previous store intact until saving and loading both succeed.
        section = destination
        previewPlayer?.pause()
        // A deliberate reopen is the recovery action suggested by stale/CAS
        // errors. Do not keep presenting an error that belonged to the
        // previous store after a fresh manifest has been loaded successfully.
        errorMessage = nil
        projectOpenTask = Task { [weak self] in
            guard let self else { return }
            let saved = await flushAutosave()
            guard !Task.isCancelled else { return }
            guard saved else { finishProjectOpen(restoringSection: true); return }
            do {
                try Task.checkCancellation()
                // A 30–80 MB manifest must never be decoded on MainActor.
                let store = try await loadProject(url)
                let loadedProject = await store.manifest
                let recovery = await store.recoverableFilmBuild()
                try Task.checkCancellation()
                let presentation = openingPresentation
                let pendingAssetID = openingSelectedAssetID
                let pendingMusicID = openingSelectedMusicTrackID
                resetProjectUI()
                let openedPipeline = VeloEditPipeline(store: store, personalTasteStore: personalTasteStore)
                pipeline = openedPipeline
                project = loadedProject
                projectURL = url
                // Keep the same artwork and selection across hydration, so the
                // first screen doesn't blink or jump back to an empty grid.
                thumbnailURLs = presentation?.thumbnails ?? [:]
                musicTracks = presentation?.music ?? []
                selectedAssetID = loadedProject.assets.first { $0.id == pendingAssetID }?.id
                selectedMusicTrackID = musicTracks.first { $0.id == pendingMusicID }?.id
                rememberProject(url)
                let preferences = loadedProject.preferences
                aiPowerMode = preferences.effectiveAIPowerMode
                advancedAISettings = preferences.effectiveAdvancedAISettings
                errorMessage = nil
                status = "Проект открыт"
                recoverableFilmBuild = recovery
                finishProjectOpen(restoringSection: false)
                prepareOpenedProject()

                // Cached artwork appears independently; missing frames are
                // regenerated later by prepareOpenedProject().
                Task(priority: .utility) { [weak self] in
                    async let thumbnails = openedPipeline.thumbnailURLs()
                    async let timelineFilmstrips = openedPipeline.cachedTimelineFilmstripURLs()
                    let values = await (thumbnails, timelineFilmstrips)
                    guard let self, self.pipeline === openedPipeline else { return }
                    self.thumbnailURLs = values.0
                    self.timelineFilmstripURLs = values.1
                    self.timelineThumbnailURLs = values.1
                }
            } catch {
                guard !Task.isCancelled else { return }
                finishProjectOpen(restoringSection: true)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finishProjectOpen(restoringSection: Bool) {
        if restoringSection, let previousSection = sectionBeforeProjectOpen {
            section = previousSection
        }
        sectionBeforeProjectOpen = nil
        projectOpenTask = nil
        openingProjectURL = nil
        openingProjectName = nil
        openingPresentationTask?.cancel()
        openingPresentationTask = nil
        openingPresentation = nil
        openingSelectedAssetID = nil
        openingSelectedMusicTrackID = nil
    }

    /// Cards warm only display metadata, never stores, recovery or playback.
    /// A click joins an in-flight read rather than decoding the same file twice.
    @discardableResult
    func prepareProjectPresentation(at url: URL) async -> ProjectLibrary.OpeningPresentation? {
        let key = url.standardizedFileURL
        if let pending = presentationLoads[key] { return await pending.value }
        let pending = Task.detached(priority: .userInitiated) {
            ProjectLibrary.OpeningPresentation.load(from: key)
        }
        presentationLoads[key] = pending
        let presentation = await pending.value
        presentationLoads[key] = nil
        preparedProjectPresentations[key] = presentation
        let retained = Set(recentProjectURLs.map(\.standardizedFileURL) + [key])
        preparedProjectPresentations = preparedProjectPresentations.filter { retained.contains($0.key) }
        return presentation
    }

    private func rememberProject(_ url: URL) {
        let normalized = url.standardizedFileURL
        knownProjectURLs = ProjectLibrary.uniqueURLs(knownProjectURLs + [normalized])
        defaults.set(knownProjectURLs.map(\.path), forKey: Self.projectLibraryKey)
        var updated = recentProjectURLs.filter { $0.standardizedFileURL.path != normalized.path }
        updated.insert(normalized, at: 0)
        recentProjectURLs = Array(updated.prefix(12))
        persistRecentProjects()
    }

    private func persistRecentProjects() {
        defaults.set(recentProjectURLs.map(\.path), forKey: Self.recentProjectsKey)
        refreshUsageStatistics()
    }

    func refreshUsageStatistics() {
        usageStatisticsTask?.cancel()
        let urls = knownProjectURLs
        let directories = [defaults.url(forKey: "newProjectDirectory.v1")].compactMap { $0 }
        usageStatisticsTask = Task.detached(priority: .utility) { [weak self] in
            guard let snapshot = try? ProjectLibrary.scan(urls: urls, directories: directories),
                  !Task.isCancelled else { return }
            await self?.applyUsageStatistics(snapshot)
        }
    }

    private func applyUsageStatistics(_ snapshot: ProjectLibrary.Snapshot) {
        guard !Task.isCancelled else { return }
        knownProjectURLs = ProjectLibrary.uniqueURLs(knownProjectURLs + snapshot.urls)
        defaults.set(knownProjectURLs.map(\.path), forKey: Self.projectLibraryKey)
        usageStatistics = snapshot.statistics
        if snapshot.refreshedSummaries {
            // Republish so recent-project cards pick up migrated summaries.
            recentProjectURLs = recentProjectURLs
        }
    }

    func chooseMedia() {
        guard !storageIsCleaning else { return }
        guard pipeline != nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Импорт медиа и телеметрии"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        // Let import inspect every explicitly selected file and explain unsupported formats.
        panel.allowsOtherFileTypes = true
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
                ? "Новые треки скачать не удалось. Доступная локальная музыка сохранена; поиск можно повторить."
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
        if defaults.bool(forKey: Self.freeToUseLicenseAcceptedKey) { return true }
        let alert = NSAlert()
        alert.messageText = "Необязательные онлайн-источники"
        alert.informativeText = "VeloEdit сохранит источник, лицензию и атрибуцию каждого скачанного трека. У Free To Use бесплатная лицензия предназначена для user-generated content и требует атрибуции; для коммерческих роликов может потребоваться отдельная лицензия. Openverse используется только для треков с проверяемой Creative Commons лицензией."
        alert.addButton(withTitle: "Проверить источники")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        defaults.set(true, forKey: Self.freeToUseLicenseAcceptedKey)
        return true
    }

    func refreshMusicLibrary() async {
        do {
            musicTracks = if let pipeline { try await pipeline.musicTracks() } else { [] }
            musicLibraryStatus = if let pipeline { await pipeline.musicLibraryStatus() } else { MusicLibraryStatus() }
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
        importWarnings = []
        run("Импортирую материалы") {
            defer { self.isImporting = false }
            let previousAssetIDs = Set(self.project?.assets.map(\.id) ?? [])
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
            if self.timeline != nil, Set(self.project?.assets.map(\.id) ?? []) != previousAssetIDs {
                self.newMaterialCount += Set(self.project?.assets.map(\.id) ?? []).subtracting(previousAssetIDs).count
            }
            self.importWarnings = thumbnailErrors
            self.status = self.project?.lastImportReport?.summary
                ?? (errors.isEmpty ? "Фото, видео и музыка готовы" : "Не удалось добавить файлов: \(errors.count)")
            if !thumbnailErrors.isEmpty { self.status += " · Ошибок миниатюр: \(thumbnailErrors.count)" }
        }
    }

    func retryFailedImports() {
        guard let report = project?.lastImportReport else { return }
        importMedia(report.failures.map(\.url))
    }

    func saveImportReport() {
        guard let report = project?.lastImportReport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Результат импорта.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.text.write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
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
            let incomplete = self.project?.assets.filter { asset in
                self.project?.analyses.contains { $0.assetID == asset.id && self.analysis($0, satisfies: self.aiProfile) } != true
            }.count ?? total
            let message = incomplete > 0
                ? "Частичный анализ сохранён. Требуют повторного анализа: \(incomplete) из \(total)."
                : count == 0
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

    func refreshSpeechPackageStatus() async {
        do {
            let manifest = try SpeechPackageManifest.bundled()
            if let package = await SpeechAssetStore.shared.installedURL(manifest: manifest) {
                try await SpeechAssetStore.shared.verify(package, manifest: manifest)
                speechPackageInstalled = true
            } else { speechPackageInstalled = false }
            speechPackageStatus = speechPackageInstalled ? "Локальная речь готова · работает без интернета" : "Речь и субтитры · \(ByteCountFormatter.string(fromByteCount: manifest.totalBytes, countStyle: .file)) (\(manifest.totalBytes) байт)"
        } catch { speechPackageInstalled = false; speechPackageStatus = error.localizedDescription }
    }

    func installSpeechPackage(fromDisk: Bool = false) {
        var local: URL?
        if fromDisk {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.message = "Выберите папку речевого пакета с package.json"
            guard panel.runModal() == .OK else { return }; local = panel.url
        }
        let source = local
        run("Устанавливаю локальную речь") {
            let manifest = try SpeechPackageManifest.bundled()
            _ = try await SpeechAssetStore.shared.install(manifest: manifest, from: source) { completed, total in
                await MainActor.run {
                    self.speechPackageProgress = Double(completed) / Double(max(1, total))
                    self.speechPackageStatus = "\(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) из \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
                }
            }
            await self.refreshSpeechPackageStatus()
        }
    }

    func exportSubtitles(_ format: SubtitleFileFormat) {
        guard timeline != nil, !isWorking, exportPanel == nil else { return }
        let projectID = project?.id
        let panel = Self.makeExportSavePanel(title: "Сохранить субтитры", directory: videoExportDirectoryURL,
                                             suggestedName: "Субтитры." + format.rawValue,
                                             contentType: UTType(filenameExtension: format.rawValue) ?? .plainText)
        presentExportPanel(panel) { [weak self] url in
            guard let self, self.project?.id == projectID, let timeline = self.timeline, !self.isWorking else { return }
            do {
                try Data(SubtitleFileExporter.render(timeline: timeline, format: format).utf8).write(to: url, options: .atomic)
                self.status = "Субтитры сохранены: \(url.lastPathComponent)"
            } catch { self.errorMessage = error.localizedDescription }
        }
    }

    func selectPreset(_ value: FilmPreset) {
        guard preset != value else { return }
        if value == .vlog {
            directorBrief.previousStandardPreset = preset
            if directorBrief.subtitlePolicy == nil { directorBrief.subtitlePolicy = directorBrief.titlePolicy == .none ? .off : .automatic }
        }
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

    func refreshLocalVisionModelStatus(startService: Bool = true) async {
        let profile = aiProfile
        aiVisionModelStatus = "Проверяю \(profile.ollamaModelID)…"
        let availability = await LocalAIModelManager.shared.availability(
            model: profile.ollamaModelID,
            startService: startService
        )
        guard profile.ollamaModelID == aiProfile.ollamaModelID else { return }
        aiVisionModelInstalled = availability.installed
        aiModelAvailability[aiPowerMode] = availability.installed
        aiVisionModelStatus = availability.message
    }

    private func prepareAutonomousAI() async throws {
        let profile = aiProfile
        let manager = LocalAIModelManager.shared
        let availability = await manager.availability(model: profile.ollamaModelID)
        if !availability.installed, !UserDefaults.standard.bool(forKey: "VeloEdit.ModelDownloadConsent.\(profile.ollamaModelID)") {
            let alert = NSAlert()
            alert.messageText = "Подготовить локальный анализ"
            alert.informativeText = "Для анализа материалов нужно один раз загрузить модель (\(profile.estimatedDownloadSize)). Материалы обрабатываются на этом Mac."
            alert.addButton(withTitle: "Загрузить и создать фильм")
            alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
            manager.authorizeDownload(model: profile.ollamaModelID)
        }
    }

    func downloadSelectedAIModel() {
        downloadAIModel(for: aiPowerMode)
    }

    func refreshAIModelAvailability() async {
        var availabilityByMode: [AIPowerMode: Bool] = [:]
        for mode in AIPowerMode.allCases {
            let profile = AIAnalysisProfile.resolve(mode: mode, advanced: advancedAISettings, thermalState: .nominal)
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
        LocalAIModelManager.shared.authorizeDownload(model: modelID)
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

    func setDurationMode(_ mode: FilmDurationMode) {
        guard directorBrief.durationMode != mode else { return }
        directorBrief.durationMode = mode
        markFilmNeedsRebuild("Требование к длительности изменено")
    }

    func setTargetMinutes(_ value: Double) {
        let normalized = min(60, AutomaticFilmDurationPolicy.normalizedRequest(value * 60) / 60)
        let duration = normalized * 60
        let changed = abs(targetMinutes - normalized) > 0.001 ||
            abs(directorBrief.requestedDuration - duration) > 0.001
        guard changed else { return }
        targetMinutes = normalized
        directorBrief.requestedDuration = duration
        if directorBrief.durationMode != .approximate { directorBrief.durationMode = .exact }
        markFilmNeedsRebuild("Длительность изменена — примените правки к фильму")
    }

    func setDirectorCanvasFormat(_ format: DirectorCanvasFormat) {
        guard directorBrief.canvasFormat != format || directorBrief.usesAutomaticCanvasFormat else { return }
        directorBrief.canvasFormat = format
        directorBrief.canvasFormatIsAutomatic = false
        markFilmNeedsRebuild("Формат кадра изменён — примените правки к фильму")
    }

    func setDirectorCanvasFormatAutomatic() {
        var updated = directorBrief
        updated.canvasFormatIsAutomatic = true
        if let format = automaticDirectorCanvasFormat() {
            updated.canvasFormat = format
        }
        guard updated != directorBrief else { return }
        directorBrief = updated
        markFilmNeedsRebuild("Формат кадра будет взят из исходного видео")
    }

    /// Source-driven format remains a first-class questionnaire choice. Once
    /// the user explicitly picks 16:9 or 9:16, film creation must not silently
    /// replace that delivery intent with the source dimensions.
    private func applyAutomaticDirectorCanvasFormat() {
        guard directorBrief.usesAutomaticCanvasFormat,
              let format = automaticDirectorCanvasFormat() else { return }
        directorBrief.canvasFormat = format
    }

    private func automaticDirectorCanvasFormat() -> DirectorCanvasFormat? {
        let assets = project?.assets ?? []
        let source = assets.first(where: { $0.kind == .video && $0.displayDimensions != nil })
            ?? assets.first(where: { $0.displayDimensions != nil })
        guard let dimensions = source?.displayDimensions else { return nil }
        let width = max(64, dimensions.width - dimensions.width % 2)
        let height = max(64, dimensions.height - dimensions.height % 2)
        return DirectorCanvasFormat(
            width: width,
            height: height,
            label: "Авто · \(width):\(height)"
        )
    }

    var usefulDirectorTelemetry: [TelemetryWidgetKind] {
        guard let project else { return [] }
        let usable = Set(project.assets.filter { !$0.excluded && !$0.missing }.map(\.id))
        let summaries = project.analyses.filter { usable.contains($0.assetID) }.compactMap(\.telemetry)
            + project.effectiveTelemetrySources.filter { $0.linkedAssetID.map(usable.contains) == true }.map(\.summary)
        var seen = Set<TelemetryWidgetKind>()
        return summaries.flatMap { AutomaticTelemetryPolicy.usefulKinds(in: $0) }.filter { seen.insert($0).inserted }
    }

    func selectStandardDirectorMood(_ mood: DirectorNarrativeMood) {
        if preset == .vlog { selectPreset(directorBrief.previousStandardPreset ?? .adventure) }
        setDirectorNarrativeMood(mood)
    }

    func setDirectorSubtitlePolicy(_ policy: DirectorSubtitlePolicy) {
        directorBrief.subtitlePolicy = policy
        markFilmNeedsRebuild("Субтитры изменены — примените правки к фильму")
    }

    func setDirectorSubtitleStyle(_ style: SpeechCaptionStyle?) {
        guard directorBrief.subtitleStyle != style else { return }
        directorBrief.subtitleStyle = style
        markFilmNeedsRebuild("Оформление субтитров изменено — примените правки к фильму")
    }

    func setDirectorNarrativeMood(_ mood: DirectorNarrativeMood) {
        guard directorBrief.mood != mood else { return }
        directorBrief.mood = mood
        markFilmNeedsRebuild("Настроение фильма изменено — примените правки к фильму")
    }

    func setDirectorMusicPolicy(_ policy: DirectorMusicPolicy) {
        var updated = directorBrief
        updated.musicPolicy = policy
        if policy == .specificTrack {
            updated.musicTrackID = directorMusicTrackID
            if updated.musicTrackID == nil { updated.musicPolicy = .matchVideo }
        } else {
            updated.musicTrackID = nil
        }
        let nextTrackID = updated.musicPolicy == .specificTrack ? updated.musicTrackID : nil
        guard updated != directorBrief || nextTrackID != directorMusicTrackID else { return }
        directorBrief = updated
        directorMusicTrackID = nextTrackID
        markFilmNeedsRebuild("Настройка музыки изменена — примените правки к фильму")
    }

    func setDirectorSourceAudioPolicy(_ policy: DirectorSourceAudioPolicy) {
        guard directorBrief.sourceAudioPolicy != policy else { return }
        directorBrief.sourceAudioPolicy = policy
        markFilmNeedsRebuild("Звук исходников изменён — примените правки к фильму")
    }

    func setDirectorTitlePolicy(_ policy: DirectorTitlePolicy) {
        if policy == .none { directorBrief.subtitlePolicy = .off }
        guard directorBrief.titlePolicy != policy else { return }
        directorBrief.titlePolicy = policy
        markFilmNeedsRebuild("Количество титров изменено — примените правки к фильму")
    }

    func setDirectorEffectsPolicy(_ policy: DirectorEffectsPolicy) {
        guard directorBrief.effectsPolicy != policy else { return }
        directorBrief.effectsPolicy = policy
        markFilmNeedsRebuild("Количество эффектов изменено — примените правки к фильму")
    }

    func selectDirectorMusicTrack(_ trackID: UUID?) {
        let validatedID = trackID.flatMap { id in
            userMusicTracks.contains(where: { $0.id == id }) ? id : nil
        }
        var updated = directorBrief
        if let validatedID {
            updated.musicPolicy = .specificTrack
            updated.musicTrackID = validatedID
        } else {
            updated.musicPolicy = .matchVideo
            updated.musicTrackID = nil
        }
        guard directorMusicTrackID != validatedID || directorBrief != updated else { return }
        directorMusicTrackID = validatedID
        directorBrief = updated
        if timeline != nil {
            let message = validatedID == nil
                ? "Включён автоподбор музыки — примените правки к фильму"
                : "Выбран свой трек — примените правки к фильму"
            markFilmNeedsRebuild(message)
        }
    }

    var canSendDirectorMessage: Bool {
        !directorInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func sendDirectorMessage() {
        let sourceText = directorInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }
        if DirectorRequestIntentInterpreter().mode(for: sourceText) == .advisory {
            directorInput = ""
            submitDirectorAdvice(sourceText)
            return
        }
        if isDirectorResponding {
            queuedDirectorMessages.append(sourceText)
            directorInput = ""
            directorStatus = "Сообщение принято · отправлю следом"
            return
        }
        if selectedTitleTimelineItem != nil, TitleEditInterpreter.targetsSelectedTitle(sourceText) {
            directorInput = ""
            directorMessages.append(DirectorMessage(role: .user, text: sourceText))
            _ = editSelectedTitleWithAI(sourceText)
            appendDirectorNote(titleEditStatus ?? "Правка титра не применена.")
            return
        }
        let speechCommand = sourceText.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        if ["без субтитров", "убери субтитры", "добавь субтитры", "включи субтитры", "оставь субтитры без звука", "убери только названия частей"].contains(speechCommand) {
            directorInput = ""
            directorMessages.append(DirectorMessage(role: .user, text: sourceText))
            directorBrief = directorBrief.applyingSubtitleCommand(speechCommand)
            if let pipeline, timeline != nil {
                run("Обновляю надписи") {
                    _ = try await pipeline.applySpeechCaptionSettings(self.directorBrief)
                    await self.refresh(); await self.rebuildPlaybackIfPossible(show: false)
                    self.appendDirectorNote("Настройка надписей применена к текущему монтажу.")
                }
            } else { appendDirectorNote("Настройка надписей сохранена для фильма.") }
            return
        }
        let requestMode = DirectorRequestIntentInterpreter().mode(for: sourceText)
        if requestMode == .edit, timeline != nil {
            // Both composers edit an existing movie through the same captured
            // selection, queue, transaction, preview and Undo path.
            directorInput = ""
            submitTimelineAIEdit(sourceText)
            return
        }
        let requestedMusic = requestMode == .edit
            ? MusicPromptInterpreter().interpret(prompt: sourceText, preset: preset)
            : nil
        if requestedMusic != nil, !confirmFreeToUseLicenseIfNeeded() { return }
        guard let exchange = beginDirectorExchange(mode: requestMode) else { return }
        let submittedSelection = selectedTimelineItemID
        let submittedPlayhead = timelinePlayheadTime
        let exactCommands = EditorCommandParser().parseComplete(exchange.text, hasSelection: submittedSelection != nil)
        isDirectorResponding = true
        directorStatus = requestMode == .advisory
            ? "Анализирую материал для совета — Timeline останется без изменений"
            : requestedMusic == nil ? "Умный режиссёр изучает замысел" : "Ищу подходящую музыку"
        directorGeneration &+= 1
        let responseGeneration = directorGeneration
        directorTask = Task {
            let activity = WorkActivity(reason: "Ответ и монтаж VeloEdit")
            defer { withExtendedLifetime(activity) {} }
            let naturalLanguageBaseline = self.timeline
            var naturalExecution: NaturalLanguageEditResult?
            var naturalLanguageApplied = false
            if requestMode == .edit, exactCommands != nil, let pipeline, self.timeline != nil, !self.isWorking {
                do {
                    self.directorStatus = "Применяю минимальную правку к Timeline"
                    let execution = try await pipeline.applyNaturalLanguageEdit(
                        exchange.text,
                        selectedItemID: submittedSelection,
                        playheadTime: submittedPlayhead,
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
            guard !Task.isCancelled, self.directorGeneration == responseGeneration else { return }
            var reply = await directorAgent.respond(
                to: exchange.text,
                context: directorContext(selection: (submittedSelection, submittedPlayhead)),
                mode: requestMode,
                onPartialReply: { [weak self] text in
                    guard let self, self.directorGeneration == responseGeneration else { return }
                    self.directorStatus = "\(text) · план ещё формируется"
                }
            )
            guard !Task.isCancelled, self.directorGeneration == responseGeneration else { return }
            if reply.planningFailed {
                self.consumePendingDirectorInstruction(exchange.text)
                self.finishDirectorExchange(replyID: exchange.replyID, sourceText: exchange.text, reply: reply, mode: .advisory)
                self.isDirectorResponding = false
                self.directorTask = nil
                return
            }
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
                            text: "Подобрал «\(track.title)» — \(track.author) и сохранил трек в локальную библиотеку. При создании фильма добавлю его в монтаж." + ((await pipeline.musicSearchNotice()).map { "\n" + $0 } ?? ""),
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
                            text: "Готово: выбрал «\(title)», сохранил локально и добавил в монтаж." + ((await pipeline.musicSearchNotice()).map { "\n" + $0 } ?? ""),
                            runtimeLabel: reply.runtimeLabel,
                            normalizedBrief: reply.normalizedBrief,
                            commands: reply.commands
                        )
                        self.consumePendingDirectorInstruction(exchange.text)
                    }
                } catch {
                    reply = DirectorAIReply(
                        text: "Не удалось получить музыку: \(error.localizedDescription)",
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
                            targetDuration: self.directorBrief.explicitRequestedDuration,
                            directorBrief: self.directorBrief,
                            ignoredFeedbackConstraints: Self.ignoredStoryConstraints(
                                for: exchange.text,
                                commandCategories: Set(execution.plan.commands.map(\.semanticCategory))
                            )
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
                                selectedItemID: submittedSelection,
                                selectedCandidateID: naturalLanguageBaseline?.items
                                    .first(where: { $0.id == submittedSelection })?.candidateID,
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
                    ? (self.timeline?.filmDeliveryReport?.completionMessage ?? "Монтаж обновлён и сохранён")
                    : (naturalExecution?.userSummary ?? "Готово: правка применена к Timeline.")
                reply = DirectorAIReply(
                    text: summary,
                    runtimeLabel: reply.runtimeLabel,
                    normalizedBrief: reply.normalizedBrief,
                    commands: reply.commands
                )
            }
            guard !Task.isCancelled, self.directorGeneration == responseGeneration else { return }
            finishDirectorExchange(
                replyID: exchange.replyID,
                sourceText: exchange.text,
                reply: reply,
                mode: requestMode,
                wasExecuted: naturalLanguageApplied
            )
            isDirectorResponding = false
            directorTask = nil
            if !self.queuedDirectorMessages.isEmpty {
                let draft = self.directorInput
                self.directorInput = self.queuedDirectorMessages.removeFirst()
                self.sendDirectorMessage()
                self.directorInput = draft
                return
            }
            // Editing requests are actions, not drafts. A fast in-place edit
            // is preferred, but if there is no Timeline yet or the request
            // needs the full director pipeline, continue automatically instead
            // of waiting for a separate Create/Rebuild button.
            if requestMode == .edit,
               self.hasPendingFilmChanges,
               self.project?.assets.isEmpty == false {
                if self.isWorking { self.hasQueuedFilmRequest = true }
                else { self.createFilm() }
            }
            self.startNextQueuedTimelineAIEdit()
        }
    }

    func refreshDirectorRuntimeStatus() async {
        directorRuntimeStatus = "Проверяю локальную нейросеть…"
        directorRuntimeStatus = await directorAgent.runtimeStatus()
    }

    func createFilm(forceFullRemake: Bool = false) {
        guard let pipeline, !isWorking, !isDirectorResponding else { return }
        let isRebuildingFilm = timeline != nil
        let timelineToAvoid = forceFullRemake ? timeline : nil
        let selectedDirectorTrack = directorMusicTrack
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
                    try Task.checkCancellation()
                    self.finishDirectorExchange(replyID: pendingExchange.replyID, sourceText: pendingExchange.text, reply: reply)
                    self.isDirectorResponding = false
                } else if !isRebuildingFilm {
                    self.appendDirectorNote("Начинаю монтаж по текущему описанию. Сначала проверю анализ исходников, затем соберу историю и сразу подготовлю просмотр.")
                } else if forceFullRemake {
                    self.appendDirectorNote("Начинаю заново: сохраню готовый анализ исходников, но построю новую историю и выберу другую режиссёрскую трактовку.")
                }
                try Task.checkCancellation()
                if self.timeline != nil {
                    // Film regeneration must start from the latest visible
                    // title/clip settings, including a pending autosave.
                    try await self.commitTimelineForExport(using: pipeline)
                }
                self.progress = 0.10

                if self.preset != .vlog { try await self.prepareAutonomousAI() }
                try Task.checkCancellation()
                self.applyAutomaticDirectorCanvasFormat()
                let revision = self.directorRevision
                let pendingInstructionCount = self.pendingDirectorInstructions.count
                let pendingInstructions = self.pendingDirectorInstructions
                let pendingCommandGroups = self.pendingDirectorCommandGroups
                let shouldReviseExistingFilm = !forceFullRemake && self.timeline != nil && self.hasPendingFilmChanges
                let prompt = self.prompt
                let preset = self.preset
                let directorBrief = self.directorBrief
                let targetDuration = directorBrief.explicitRequestedDuration
                let previousTimeline = self.timeline
                let selectedCandidateID = previousTimeline?.items.first(where: { $0.id == self.selectedTimelineItemID })?.candidateID
                let editorCommands = Self.resolvedEditorCommands(
                    instructions: pendingInstructions,
                    commandGroups: pendingCommandGroups,
                    fallbackPrompt: prompt,
                    preset: preset
                )

                self.progress = 0.60
                self.activityTitle = "Умный режиссёр собирает историю"
                self.status = "Готовлю материалы и выбираю лучшие моменты"
                self.beginUnmeasuredActivity(at: 0.60, step: .preparing)
                let filmBuildGeneration = self.operationGeneration
                let buildProgress: FilmBuildProgressHandler = { [weak self] update in
                    await self?.setFilmBuildProgress(update, generation: filmBuildGeneration)
                }
                let baseTimeline: Timeline
                let canEditExistingTimelineInPlace = shouldReviseExistingFilm &&
                    !pendingInstructions.contains(where: DirectorRequestContract.requiresStoryRebuild) &&
                    previousTimeline != nil &&
                    previousTimeline?.width == directorBrief.canvasFormat.width &&
                    previousTimeline?.height == directorBrief.canvasFormat.height &&
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
                        preferredMusicTrackID: selectedDirectorTrack?.id,
                        directorBrief: directorBrief,
                        progress: buildProgress
                    )
                } else {
                    baseTimeline = try await pipeline.createFilm(
                        prompt: prompt,
                        preset: preset,
                        targetDuration: targetDuration,
                        preferredMusicTrackID: selectedDirectorTrack?.id,
                        directorBrief: directorBrief,
                        avoidingTimeline: timelineToAvoid,
                        progress: buildProgress
                    )
                }
                self.activityTitle = "Исполняю команды видеоредактора"
                self.status = "Применяю скорость, кадр, звук, титры, переходы и эффекты из запроса"
                self.beginUnmeasuredActivity(at: 0.78, step: .commands)
                let commandReport: EditorCommandReport
                if canEditExistingTimelineInPlace {
                    commandReport = try await pipeline.applyEditorCommands(editorCommands,
                        selectedItemID: nil, selectedCandidateID: selectedCandidateID, createCheckpoint: true)
                } else {
                    commandReport = EditorCommandReport(recognizedCount: editorCommands.count)
                }
                await self.refresh()
                let timeline = self.timeline ?? baseTimeline
                self.activityTitle = "Готовлю просмотр фильма"
                self.status = "Соединяю \(timeline.items.count) фрагментов в одну композицию"
                self.beginUnmeasuredActivity(at: 0.84, step: .playback)
                let playback = try await pipeline.makePlayback { [weak self] item in
                    Task { @MainActor in
                        guard let self, self.isWorking, self.isCreatingFilm,
                              self.operationGeneration == filmBuildGeneration else { return }
                        self.setProgress(item, base: 0.84, span: 0.15, phase: "Просмотр")
                    }
                }
                try Task.checkCancellation()
                self.setPlayback(playback, show: true, autoplay: false)
                self.progress = 1
                self.status = "\(timeline.filmDeliveryReport?.completionMessage ?? "Фильм сохранён"): \(timeline.items.count) фрагментов, \(Self.durationText(AutomaticFilmDurationPolicy.renderedDuration(of: timeline)))"
                self.completeFilmBuild(
                    revision: revision,
                    consumedInstructionCount: pendingInstructionCount,
                    previousTimeline: previousTimeline,
                    timeline: timeline,
                    commandReport: commandReport,
                    usesCompactConfirmation: isRebuildingFilm
                )
            } catch {
                self.finishUnmeasuredActivity()
                if self.directorTask == nil { self.isDirectorResponding = false }
                if let pendingExchange {
                    self.directorMessages.removeAll { $0.id == pendingExchange.replyID && $0.text.isEmpty }
                }
                if error is CancellationError {
                    self.directorStatus = "Создание фильма отменено · можно повторить"
                    self.appendDirectorNote("Остановил создание фильма. Ваше описание сохранено — можно изменить его и запустить монтаж снова.")
                } else {
                    self.directorStatus = "Создание фильма не завершено · можно повторить"
                    self.appendDirectorNote("Задание пока не завершено. Данные проекта и параметры сборки сохранены.")
                }
                throw error
            }
        }
    }

    func remakeFilmFromScratch() {
        guard timeline != nil, !isWorking, !isDirectorResponding else { return }
        createFilm(forceFullRemake: true)
    }

    private func waitForExternalResources() {
        guard externalResourceWaitTask == nil, let pipeline else { return }
        externalResourceWaitTask = Task { [weak self] in
            defer { self?.externalResourceWaitTask = nil }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.pipeline === pipeline else { return }
                guard await pipeline.store.manifest.autonomousJob?.state == .waitingForExternalResource else { return }
                guard await pipeline.externalDependenciesAvailable() else { continue }
                guard (try? await pipeline.store.activateAfterExternalWait()) == true else { return }
                self.project = await pipeline.store.manifest
                self.recoverableFilmBuild = await pipeline.store.recoverableFilmBuild()
                guard !self.isWorking else { continue }
                if self.project?.autonomousJob?.kind == .film {
                    self.resumeInterruptedFilmBuild()
                } else {
                    self.run("Сохраняю видео") {
                        if let report = try await pipeline.resumeExport() {
                            await self.refresh()
                            self.status = "Видео сохранено: \(report.outputURL.lastPathComponent)"
                        }
                    }
                }
                return
            }
        }
    }

    func resumeInterruptedFilmBuild() {
        guard let pipeline, !isWorking, recoverableFilmBuild != nil else { return }
        projectRestoreTask?.cancel()
        projectRestoreTask = nil
        isCreatingFilm = true
        run("Продолжаю сохранённую сборку") {
            defer { self.isCreatingFilm = false }
            self.beginUnmeasuredActivity(at: 0, step: .finishing)
            let generation = self.operationGeneration
            let callback: FilmBuildProgressHandler = { [weak self] update in
                await self?.setFilmBuildProgress(update, generation: generation)
            }
            let previous = self.timeline
            let result = try await pipeline.resumeFilmBuild(progress: callback)
            await self.refresh()
            self.activityTitle = "Готовлю просмотр фильма"
            self.beginUnmeasuredActivity(at: 0.84, step: .playback)
            let playback = try await pipeline.makePlayback { [weak self] item in
                Task { @MainActor in
                    guard let self, self.isWorking, self.isCreatingFilm,
                          self.operationGeneration == generation else { return }
                    self.setProgress(item, base: 0.84, span: 0.15, phase: "Просмотр")
                }
            }
            self.setPlayback(playback, show: true, autoplay: false)
            self.completeFilmBuild(revision: self.directorRevision, consumedInstructionCount: self.pendingDirectorInstructions.count, previousTimeline: previous, timeline: result)
            self.status = "\(result.filmDeliveryReport?.completionMessage ?? "Фильм сохранён"): \(result.items.count) фрагментов, \(Self.durationText(AutomaticFilmDurationPolicy.renderedDuration(of: result)))"
        }
    }

    func regenerate() {
        let requestedFeedback = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isWorking, !requestedFeedback.isEmpty else { return }
        submitTimelineAIEdit(requestedFeedback)
    }

    /// Accept an edit from the timeline composer even while another pipeline
    /// operation is finishing. Pipeline mutations remain serialized; busy-time
    /// submissions are queued instead of being rejected by a disabled button.
    func submitTimelineAIEdit(_ instruction: String, range: ClosedRange<Double>? = nil, proposal: DirectorEditProposal? = nil) {
        let clean = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if DirectorRequestIntentInterpreter().mode(for: clean) == .advisory {
            feedback = ""
            submitDirectorAdvice(clean, range: range)
            return
        }
        let trace = PerformanceTrace(name: "edit.command", projectID: project?.id, revision: String(timelineEditRevision))
        trace.event("edit.submitted", fields: ["selectedID": selectedTimelineItemID?.uuidString ?? ""])
        trace.event("edit.accepted")

        if range == nil, !isWorking, !isDirectorResponding,
           selectedTitleTimelineItem != nil, TitleEditInterpreter.targetsSelectedTitle(clean) {
            let replyID = beginTimelineDirectorExchange(clean, range: nil)
            if editSelectedTitleWithAI(clean) { feedback = "" }
            status = titleEditStatus ?? status
            updateTimelineDirectorExchange(replyID, status: status)
            return
        }

        let parsedCommands = EditorCommandParser().parse(clean, preset: preset)
        let requestsDownloadableMusic = range == nil && parsedCommands.contains { command in
            if case .setMusic(let directive?) = command { return directive.trackID == nil }
            return false
        }
        guard !requestsDownloadableMusic || confirmFreeToUseLicenseIfNeeded() else { return }

        // A whole-film duration belongs to the director brief. A command such
        // as “сделай этот клип 5 секунд” is deliberately kept clip-local.
        let hasClipDurationCommand = parsedCommands.contains { command in
            if case .setDuration = command { return true }
            if case .insertBackground = command { return true }
            if case .insertSource = command { return true }
            return false
        }
        let requestedFilmDuration: Double? = if range == nil,
                                               !hasClipDurationCommand,
                                               AutonomousDurationOptimizer.requestContainsExplicitDuration(clean) {
            min(3_600, AutomaticFilmDurationPolicy.normalizedRequest(PromptInterpreter().interpret(prompt: clean, preset: preset).targetDuration))
        } else {
            nil
        }
        var requestedDirectorBrief = directorBrief.applyingSubtitleCommand(clean)
        var requestedPreferredMusicTrackID = directorMusicTrack?.id
        var briefChanges: DirectorBriefFieldChanges = []
        if range == nil {
            for command in parsedCommands {
                switch command {
                case .setMusic(nil):
                    briefChanges.insert(.music)
                    requestedDirectorBrief.musicPolicy = .none
                    requestedDirectorBrief.musicTrackID = nil
                    requestedPreferredMusicTrackID = nil
                case .setMusic(let directive?):
                    briefChanges.insert(.music)
                    requestedDirectorBrief.musicPolicy = .matchVideo
                    requestedDirectorBrief.musicTrackID = nil
                    requestedPreferredMusicTrackID = directive.trackID
                case .setOriginalAudioVolume(let volume):
                    briefChanges.insert(.sourceAudio)
                    requestedDirectorBrief.sourceAudioPolicy = volume < 0.01 ? .mute : volume < 0.75 ? .duck : .preserve
                case .removeTitles:
                    briefChanges.insert(.titles)
                    requestedDirectorBrief.titlePolicy = .none
                case .addTitle:
                    briefChanges.insert(.titles)
                    if requestedDirectorBrief.titlePolicy == .none { requestedDirectorBrief.titlePolicy = .minimal }
                case .insertBackground(let insertion) where insertion.title != nil:
                    briefChanges.insert(.titles)
                    if requestedDirectorBrief.titlePolicy == .none { requestedDirectorBrief.titlePolicy = .minimal }
                default:
                    break
                }
            }

            if let requestedMood = Self.narrativeMood(requestedBy: clean) {
                briefChanges.insert(.mood)
                requestedDirectorBrief.mood = requestedMood
            }
            if let requestedFilmDuration {
                // The setup slider deliberately starts at 30 seconds, but a
                // Montage comment may request any engine-supported duration
                // down to five seconds.
                briefChanges.insert(.duration)
                requestedDirectorBrief.requestedDuration = requestedFilmDuration
                requestedDirectorBrief.durationMode = FilmDurationRequirement.parse(prompt: clean).mode
            }
        }

        feedback = ""
        let selectedItem = timeline?.items.first { $0.id == (proposal?.item.id ?? selectedTimelineItemID) }
        let edit = PendingTimelineAIEdit(
            instruction: clean,
            replyID: beginTimelineDirectorExchange(clean, range: range),
            range: range,
            timelineAnchor: timeline.map(TimelineAIAnchor.init),
            selectedItemID: proposal?.item.id ?? selectedTitleTimelineItem?.id ?? selectedItem?.id,
            selectedItemIsTitle: proposal == nil && selectedTitleTimelineItem != nil,
            selectedCandidateID: selectedItem?.candidateID,
            playheadTime: timelinePlayheadTime,
            preset: preset,
            targetDuration: requestedFilmDuration ?? requestedDirectorBrief.explicitRequestedDuration,
            preferredMusicTrackID: requestedPreferredMusicTrackID,
            directorBrief: requestedDirectorBrief,
            briefChanges: briefChanges,
            trace: trace,
            proposal: proposal
        )
        pendingTimelineAIEdits.append(edit)
        queuedTimelineAIEditCount = pendingTimelineAIEdits.count
        guard !isWorking, !isDirectorResponding else {
            status = "Правка монтажа поставлена в очередь"
            return
        }
        // A new submission can arrive during the completion callback's delay.
        // It must not overtake commands that were accepted while we were busy.
        startNextQueuedTimelineAIEdit()
    }

    func renderPreview() {
        guard timeline != nil else { return }
        if previewPlayer != nil {
            showMovie()
            return
        }
        guard let pipeline else { return }
        run("Готовлю предварительный просмотр") {
            let playback = try await pipeline.makePlayback(interactiveQuality: Self.interactivePreviewQuality) { [weak self] item in
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
        guard !isWorking, exportPanel == nil else { return }
        guard let pipeline, timeline?.effectiveTelemetryItems.isEmpty == false else {
            errorMessage = "Добавьте хотя бы один слой телеметрии на Timeline."
            return
        }
        let panel = Self.makeExportSavePanel(title: "Сохранить прозрачную телеметрию", directory: videoExportDirectoryURL,
                                             suggestedName: "Телеметрия VeloEdit ProRes 4444.mov", contentType: .quickTimeMovie)
        presentExportPanel(panel) { [weak self] url in
            guard let self, self.pipeline === pipeline, !self.isWorking else { return }
            self.run("Экспортирую прозрачную телеметрию", completionNotification: "Экспорт завершён") {
                try await self.commitTimelineForExport(using: pipeline)
                _ = try await pipeline.renderTelemetryOverlay(to: url) { [weak self] item in
                    Task { @MainActor in self?.setProgress(item) }
                }
                self.status = "Прозрачный overlay ProRes 4444 сохранён"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    func exportWithSettings(quality: RenderQuality, frameRate: Double? = nil) {
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

    var completedVideoExports: [RenderJob] {
        (project?.renderJobs ?? []).filter { $0.status == .completed && $0.artifactHash != nil }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    func openExportedVideo(_ job: RenderJob) { NSWorkspace.shared.open(job.outputURL) }
    func revealExportedVideo(_ job: RenderJob) { NSWorkspace.shared.activateFileViewerSelecting([job.outputURL]) }

    func saveVideo() {
        saveVideoAs()
    }

    func copyExportNextToProject(_ job: RenderJob) {
        guard let pipeline, !isWorking else { return }
        run("Копирую готовое видео рядом с проектом") {
            let url = try await pipeline.copyExportNextToProject(jobID: job.id)
            await self.refresh()
            self.status = "Видео сохранено рядом с проектом: \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    var videoExportDirectoryURL: URL? {
        videoExportDirectory ?? projectURL?.deletingLastPathComponent()
    }

    private var exportPanel: NSSavePanel?

    func chooseVideoExportDirectory() {
        guard pipeline != nil, !isWorking, exportPanel == nil else { return }
        let package = projectURL
        let panel = NSOpenPanel()
        panel.title = "Куда сохранить видео"
        panel.prompt = "Выбрать папку"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = videoExportDirectoryURL
        presentExportPanel(panel) { [weak self] url in
            guard let self, self.projectURL == package else { return }
            self.videoExportDirectory = url
        }
    }

    func saveVideoAs() { exportVideo(quality: .maximum, suggestedName: "Фильм VeloEdit.mp4", frameRate: timeline?.frameRate) }

    static func makeVideoSavePanel(directory: URL?, suggestedName: String) -> NSSavePanel {
        let panel = makeExportSavePanel(title: "Сохранить видео", directory: directory,
                                        suggestedName: suggestedName, contentType: .mpeg4Movie)
        panel.message = "Видео будет сохранено отдельным MP4-файлом."
        return panel
    }

    private static func makeExportSavePanel(title: String, directory: URL?, suggestedName: String,
                                            contentType: UTType) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = title
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [contentType]
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName
        return panel
    }

    private func presentExportPanel(_ panel: NSSavePanel, selection: @escaping (URL) -> Void) {
        exportPanel = panel
        DispatchQueue.main.async { [weak self] in
            let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                self?.exportPanel = nil
                guard response == .OK, let url = panel.url else { return }
                selection(url)
            }
            if let window = NSApplication.shared.mainWindow {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }
    }

    private func exportVideo(quality: RenderQuality, suggestedName: String, frameRate: Double? = nil) {
        guard let pipeline, timeline != nil, !isWorking, exportPanel == nil else { return }
        let panel = Self.makeVideoSavePanel(directory: videoExportDirectoryURL, suggestedName: suggestedName)
        presentExportPanel(panel) { [weak self] url in
            guard let self, self.pipeline === pipeline, !self.isWorking else { return }
            self.videoExportDirectory = url.deletingLastPathComponent()
            self.run("Сохраняю видео", completionNotification: "Видео сохранено") {
                try await self.commitTimelineForExport(using: pipeline)
                let report = try await pipeline.render(to: url, quality: quality, frameRate: frameRate, replaceExisting: true) { [weak self] item in
                    Task { @MainActor in self?.setProgress(item) }
                }
                await self.refresh()
                self.status = "Видео сохранено: \(report.videoInfo?.summary ?? report.outputURL.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([report.outputURL])
            }
        }
    }

    func exportFCPXML(mode: FCPXMLExportMode = .edit) {
        guard let pipeline, !isWorking, exportPanel == nil else { return }
        let panel = Self.makeExportSavePanel(title: "Сохранить монтаж для Final Cut Pro", directory: videoExportDirectoryURL,
                                             suggestedName: mode == .edit ? "Монтаж VeloEdit.fcpxml" : "Подборка VeloEdit.fcpxml",
                                             contentType: UTType(filenameExtension: "fcpxml") ?? .xml)
        presentExportPanel(panel) { [weak self] url in
            guard let self, self.pipeline === pipeline, !self.isWorking else { return }
            self.run("Экспортирую проект для Final Cut Pro", completionNotification: "Экспорт завершён") {
                try await self.commitTimelineForExport(using: pipeline)
                try await pipeline.exportFCPXML(to: url, mode: mode)
                self.status = "Проект для Final Cut Pro сохранён: \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func commitTimelineForExport(using pipeline: VeloEditPipeline) async throws {
        await timelineCommitTask?.value
        try Task.checkCancellation()
        guard self.pipeline === pipeline, let timeline else { throw CancellationError() }
        // Export must include the last visible edit even when autosave was
        // still debouncing or failed. A save error stops export here.
        let revision = timelineEditRevision
        let committed = try await pipeline.commitLatestTimeline(timeline, clientRevision: revision)
        if committed, self.pipeline === pipeline, timelineEditRevision == revision {
            hasUnpersistedTimelineEdits = false
            timelinePersistenceFailed = false
        }
    }

    func exportDiagnostics() {
        let pipeline = pipeline
        let panel = NSSavePanel()
        panel.title = "Экспорт диагностики"
        panel.nameFieldStringValue = "Диагностика VeloEdit.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                var report = Self.applicationDiagnostics()
                if let pipeline {
                    report += "\n\n" + (await pipeline.diagnostics())
                } else {
                    report += "\nПроект: не открыт"
                }
                try report.write(to: url, atomically: true, encoding: .utf8)
                status = "Диагностика сохранена"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func exportPersonalTasteProfile() {
        let panel = NSSavePanel()
        panel.title = "Экспорт профиля предпочтений"
        panel.nameFieldStringValue = "Профиль VeloEdit.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await personalTasteStore.export(to: url)
                status = "Профиль предпочтений экспортирован"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func importPersonalTasteProfile() {
        let panel = NSOpenPanel()
        panel.title = "Импорт профиля предпочтений"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Заменить профиль предпочтений?"
        alert.informativeText = "VeloEdit начнёт использовать предпочтения из выбранного файла. Текущий профиль можно заранее экспортировать."
        alert.addButton(withTitle: "Импортировать")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            do {
                if let pipeline {
                    try await pipeline.importPersonalTasteProfile(from: url)
                    await refresh()
                } else {
                    try await personalTasteStore.importProfile(from: url)
                }
                status = "Профиль предпочтений импортирован"
            } catch {
                errorMessage = "Не удалось импортировать профиль: \(error.localizedDescription)"
            }
        }
    }

    func resetPersonalTasteProfile() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Сбросить профиль предпочтений?"
        alert.informativeText = "Локально выученные предпочтения и история сигналов этого проекта будут удалены. Перед сбросом профиль можно экспортировать."
        alert.addButton(withTitle: "Сбросить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                if let pipeline {
                    try await pipeline.resetPersonalTasteProfile()
                    await refresh()
                } else {
                    try await personalTasteStore.reset()
                }
                status = "Профиль предпочтений сброшен"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var currentAppBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    func checkForUpdates() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        updateStatusText = "Проверяю последнюю версию…"
        availableUpdateURL = nil
        availableUpdateVersion = nil

        Task {
            defer { isCheckingForUpdates = false }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/007danlin/VeloEdit/releases/latest")!)
                request.timeoutInterval = 15
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("VeloEdit/\(currentAppVersion)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if http.statusCode == 404 {
                    updateStatusText = "Опубликованных обновлений пока нет"
                    return
                }
                guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }

                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let latest = Self.normalizedVersion(release.tagName)
                if Self.isVersion(latest, newerThan: currentAppVersion) {
                    availableUpdateURL = release.htmlURL
                    availableUpdateVersion = latest
                    updateStatusText = "Доступна версия \(latest)"
                } else if Self.isVersion(currentAppVersion, newerThan: latest) {
                    updateStatusText = "Установлена более новая тестовая сборка"
                } else {
                    updateStatusText = "У вас последняя версия"
                }
            } catch {
                updateStatusText = "Не удалось проверить обновления"
            }
        }
    }

    func openAvailableUpdate() {
        guard let availableUpdateURL else {
            checkForUpdates()
            return
        }
        NSWorkspace.shared.open(availableUpdateURL)
    }

    private static func normalizedVersion(_ version: String) -> String {
        var result = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.first == "v" || result.first == "V" { result.removeFirst() }
        return result
    }

    private static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        normalizedVersion(lhs).compare(normalizedVersion(rhs), options: [.numeric, .caseInsensitive]) == .orderedDescending
    }

    private static func applicationDiagnostics() -> String {
        let process = ProcessInfo.processInfo
        let memoryGB = Double(process.physicalMemory) / 1_073_741_824
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "неизвестна"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "неизвестна"
        return """
        VeloEdit — диагностика приложения
        Создано: \(ISO8601DateFormatter().string(from: Date()))
        Версия: \(version) (\(build))
        macOS: \(process.operatingSystemVersionString)
        Память: \(String(format: "%.1f", memoryGB)) ГБ
        Процессоров: \(process.processorCount)
        """
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

    func collectProjectCopy() {
        guard pipeline != nil, let projectURL, !isWorking else { return }
        let panel = NSSavePanel()
        panel.title = "Собрать копию проекта с исходниками"
        panel.nameFieldStringValue = "\(project?.name ?? "Проект") — копия.veloedit"
        panel.directoryURL = projectURL.deletingLastPathComponent()
        panel.allowedContentTypes = [UTType(filenameExtension: "veloedit") ?? .package]
        panel.canCreateDirectories = true
        presentExportPanel(panel) { [weak self] destination in
            guard let self, self.projectURL == projectURL, !self.isWorking else { return }
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                self.errorMessage = "В этом месте уже есть проект. Выберите другое имя для копии."
                return
            }
            self.run("Собираю копию проекта") {
                _ = try await self.collectProjectCopy(to: destination)
                self.status = "Копия проекта собрана и проверена"
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
    }

    func collectProjectCopy(to destination: URL) async throws -> URL {
        guard let pipeline else { throw ProjectStoreError.invalidProjectPackage(destination) }
        // The chat debounce may still be pending when the user collects a
        // portable copy. Include the latest messages, drafts and timeline edits.
        guard await flushAutosave(), self.pipeline === pipeline else {
            throw ProjectStoreError.persistenceFailure(stage: "подготовка копии", path: destination.path,
                underlying: errorMessage ?? "Проект изменился во время сохранения")
        }
        try Task.checkCancellation()
        return try await pipeline.collectProjectCopy(to: destination) { [weak self] update in
            Task { @MainActor in self?.setProgress(update) }
        }
    }

    func locateMissingMedia(_ assetID: UUID? = nil) {
        guard let pipeline, !hasActiveWork, !storageIsCleaning else { return }
        let panel = NSOpenPanel()
        panel.title = assetID == nil ? "Папка с перемещёнными исходниками" : "Найти исходный файл"
        panel.prompt = "Восстановить связь"
        panel.canChooseDirectories = assetID == nil
        panel.canChooseFiles = assetID != nil
        panel.allowsMultipleSelection = false
        if let assetID, let asset = project?.assets.first(where: { $0.id == assetID }) {
            panel.message = "Выберите оригинал «\(asset.displayName)» или его точную копию."
        } else {
            panel.message = "VeloEdit проверит совпадение файлов и сохранит все монтажные правки."
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("Восстанавливаю исходники") {
            let count: Int
            if let assetID { try await pipeline.relinkMedia(assetID: assetID, to: url); count = 1 }
            else { count = try await pipeline.relinkMedia(in: url) }
            await self.refresh()
            self.status = "Восстановлено файлов: \(count). Не найдено: \(self.missingMediaAssets.count)."
            if self.missingMediaAssets.isEmpty { self.showsMissingMedia = false }
            if count == 0 { self.errorMessage = "В выбранной папке не найдено однозначных совпадений. Выберите файл отдельно или проверьте, что это точные копии исходников." }
            if self.timeline != nil, self.missingMediaAssets.isEmpty {
                let playback = try await pipeline.makePlayback(interactiveQuality: Self.interactivePreviewQuality)
                self.setPlayback(playback, show: false, autoplay: false)
            }
        }
    }

    func refreshStorageUsage() {
        storageTask?.cancel()
        storageIsLoading = true
        let urls = ProjectLibrary.uniqueURLs(knownProjectURLs + recentProjectURLs + [projectURL].compactMap { $0 })
        storageTask = Task { [weak self] in
            let inventory = Task.detached(priority: .utility) { () -> [ProjectStorageUsage] in
                var result: [ProjectStorageUsage] = []
                for url in urls {
                    guard !Task.isCancelled else { break }
                    result.append(StorageMaintenance.usage(of: url))
                }
                return result
            }
            let projects = await withTaskCancellationHandler(operation: { await inventory.value }, onCancel: { inventory.cancel() })
            guard !Task.isCancelled, let self else { return }
            self.storageProjects = projects
            do {
                let models = try await LocalAIModelManager.shared.installedModelList()
                guard !Task.isCancelled else { return }
                self.storageModels = models
                self.storageModelsMessage = models.isEmpty ? "Загруженных моделей нет" : "Модели могут использоваться другими приложениями через Ollama. Общие файлы занимают место только один раз."
            } catch {
                guard !Task.isCancelled else { return }
                self.storageModels = []
                self.storageModelsMessage = "Локальный сервис недоступен. Список моделей появится после подготовки ИИ."
            }
            self.storageIsLoading = false
        }
    }

    func isCurrentProject(_ url: URL) -> Bool {
        projectURL.map { StorageMaintenance.sameProject($0, url) } ?? false
    }

    private func suspendProjectCacheReaders() async -> Bool {
        guard await flushAutosave() else { return false }
        projectRestoreTask?.cancel()
        previewRebuildTask?.cancel()
        filmVerificationTask?.cancel()
        externalResourceWaitTask?.cancel()
        await projectRestoreTask?.value
        await previewRebuildTask?.value
        await filmVerificationTask?.value
        projectRestoreTask = nil
        previewRebuildTask = nil
        filmVerificationTask = nil
        clearTimelinePlayback()
        return true
    }

    func clearSelectedProjectCaches(_ selection: [URL: Set<ProjectCacheCategory>]) async -> String? {
        guard !hasActiveWork, !storageIsCleaning, downloadingAIPowerMode == nil else { return nil }
        storageIsCleaning = true
        isWorking = true
        activityTitle = "Очищаю хранилище"
        defer { storageIsCleaning = false; isWorking = false; refreshStorageUsage() }
        if selection.keys.contains(where: isCurrentProject) {
            guard await suspendProjectCacheReaders() else { return nil }
        }
        let others = knownProjectURLs
        var freed: Int64 = 0
        var failures: [String] = []
        for (url, categories) in selection.sorted(by: { $0.key.path < $1.key.path }) {
            for category in ProjectCacheCategory.allCases where categories.contains(category) {
                do {
                    freed += try await Task.detached(priority: .utility) {
                        try StorageMaintenance.clear(category, package: url, protectingProjects: others)
                    }.value
                } catch { failures.append("\(url.deletingPathExtension().lastPathComponent), \(category.title): \(error.localizedDescription)") }
            }
            if isCurrentProject(url) {
                thumbnailURLs = [:]; timelineFilmstripURLs = [:]; timelineThumbnailURLs = [:]
                needsCacheRefreshAfterCleanup = true
            }
        }
        if !failures.isEmpty { errorMessage = "Часть кэша не удалось удалить. Уже освобождено \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)).\n" + failures.joined(separator: "\n") }
        let message = "Освобождено \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)). Кэш создастся по мере необходимости."
        status = message
        return message
    }

    func trashStoredProjects(_ urls: [URL]) async -> String? {
        guard !hasActiveWork, !storageIsCleaning, downloadingAIPowerMode == nil, !urls.isEmpty else { return nil }
        storageIsCleaning = true
        isWorking = true
        activityTitle = "Перемещаю проекты в Корзину"
        defer { storageIsCleaning = false; isWorking = false; refreshStorageUsage() }
        if urls.contains(where: isCurrentProject) {
            guard await suspendProjectCacheReaders() else { return nil }
        }
        let others = knownProjectURLs
        do {
            let dependents = try await Task.detached(priority: .utility) { try StorageMaintenance.projectsDepending(on: urls, among: others) }.value
            guard dependents.isEmpty else {
                errorMessage = "В этих пакетах есть материалы других проектов: " + dependents.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: ", ") + ". Сначала соберите автономные копии этих проектов или перенесите их исходники."
                return nil
            }
        } catch { errorMessage = "Не удалось проверить связи проектов. Удаление не начато: \(error.localizedDescription)"; return nil }
        var moved = 0
        for url in urls {
            do {
                try await Task.detached(priority: .utility) { try StorageMaintenance.moveProjectToTrash(url) }.value
                if isCurrentProject(url) {
                    pipeline = nil
                    resetProjectUI()
                    isWorking = true
                    section = .settings
                }
                forgetStoredProject(url)
                moved += 1
            } catch { errorMessage = "Перемещено в Корзину: \(moved). Не удалось удалить «\(url.lastPathComponent)»: \(error.localizedDescription)"; break }
        }
        guard moved > 0 else { return nil }
        return "В Корзину перемещено проектов: \(moved). Место освободится после её очистки в Finder."
    }

    func forgetStoredProject(_ url: URL) {
        knownProjectURLs.removeAll { $0.resolvingSymlinksInPath().standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path }
        recentProjectURLs.removeAll { $0.resolvingSymlinksInPath().standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path }
        preparedProjectPresentations[url.standardizedFileURL] = nil
        defaults.set(knownProjectURLs.map(\.path), forKey: Self.projectLibraryKey)
        persistRecentProjects()
        refreshStorageUsage()
    }

    func removeStoredModel(_ name: String) async -> Bool {
        guard !hasActiveWork, !storageIsCleaning, downloadingAIPowerMode == nil else { return false }
        storageIsCleaning = true
        isWorking = true
        activityTitle = "Удаляю AI-модель"
        defer { storageIsCleaning = false; isWorking = false; refreshStorageUsage() }
        do {
            try await LocalAIModelManager.shared.removeModel(name)
            await refreshAIModelAvailability()
            status = "Модель удалена. Её можно загрузить снова при выборе режима ИИ."
            return true
        } catch { errorMessage = "Не удалось удалить модель: \(error.localizedDescription)"; return false }
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
        if openingProjectURL != nil {
            openingSelectedMusicTrackID = nil
            openingSelectedAssetID = id
            return
        }
        selectedMusicTrackID = nil
        selectedAssetID = id
    }

    func selectMusicTrackForInspector(_ id: UUID) {
        if openingProjectURL != nil {
            openingSelectedAssetID = nil
            openingSelectedMusicTrackID = id
            return
        }
        selectedAssetID = nil
        selectedMusicTrackID = id
    }

    func closeMediaInspector() {
        openingSelectedAssetID = nil
        openingSelectedMusicTrackID = nil
        guard openingProjectURL == nil else { return }
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
        guard let pipeline, project?.assets.contains(where: { $0.id == id }) == true, !isWorking else { return }
        run("Удаляю материал из проекта") {
            try await pipeline.removeAsset(id: id)
            self.selectedAssetID = nil
            self.selectedTimelineItemID = nil
            await self.refresh()
            await self.rebuildPlaybackIfPossible(show: false)
            self.updateTimelineHistoryAvailability()
            self.status = "Материал удалён из проекта. Доступна отмена."
        }
    }

    func createProxy(_ id: UUID) {
        guard let pipeline else { return }
        run("Создаю облегчённую копию") {
            let url = try await pipeline.ensureProxy(for: id)
            await self.rebuildPlaybackIfPossible(show: false)
            self.status = "Облегчённая копия готова: \(url.lastPathComponent)"
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
        guard let asset = project?.assets.first(where: { $0.id == assetID }) else { return }
        let itemID = UUID()
        let sourceDuration = asset.kind == .video ? max(0.25, asset.metadata.duration ?? 5) : 4
        let item = TimelineItem(
            id: itemID,
            assetID: asset.id,
            kind: asset.kind == .video ? .video : .photo,
            sourceDuration: sourceDuration,
            timelineStart: 0,
            timelineDuration: sourceDuration,
            explanation: ["Добавлено вручную из медиатеки"]
        )
        editTimelineOptimistically(
            "Материал добавлен в фильм",
            didApply: { self.selectTimelineItem(itemID) }
        ) {
            TimelineMutationEngine.insertPrimaryItem(in: &$0, item: item, atPrimaryIndex: index)
        }
    }

    func insertAssetAsOverlay(_ assetID: UUID, at time: Double) {
        guard let asset = project?.assets.first(where: { $0.id == assetID }) else { return }
        let itemID = UUID()
        let sourceDuration = asset.kind == .video ? max(0.25, asset.metadata.duration ?? 5) : 4
        let item = TimelineItem(
            id: itemID,
            assetID: asset.id,
            kind: asset.kind == .video ? .video : .photo,
            sourceDuration: sourceDuration,
            timelineStart: time,
            timelineDuration: sourceDuration,
            overlay: OverlaySettings(style: .cutaway),
            explanation: ["Добавлено как связанный клип"]
        )
        editTimelineOptimistically(
            "Видео добавлено поверх основного",
            didApply: { self.selectTimelineItem(itemID) }
        ) {
            TimelineMutationEngine.insertConnectedItem(in: &$0, item: item, atTimelineStart: time)
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
        insertMusicClip(trackID, at: time, duration: nil)
    }

    private func insertMusicClip(_ trackID: UUID, at time: Double?, duration requestedDuration: Double?, sourceStart: Double = 0, speed: Double = 1) {
        guard let timeline, let track = musicTracks.first(where: { $0.id == trackID }) else { return }
        let start = min(max(0, time ?? timelinePlayheadTime), max(0, timeline.duration - 0.05))
        let sourceStart = min(max(0, sourceStart), max(0, track.duration - 0.05))
        let duration = min(max(0.05, requestedDuration ?? timeline.duration),
                           max(0.05, min((track.duration - sourceStart) / speed, timeline.duration - start)))
        let clip = TimelineAudioClip(
            trackID: track.id,
            title: track.title,
            role: .music,
            sourceStart: sourceStart,
            sourceDuration: duration * speed,
            timelineStart: start,
            timelineDuration: duration,
            speed: speed,
            adjustments: AudioAdjustments(volume: timeline.music?.volume ?? 0.22)
        )
        editTimelineOptimistically(
            "Аудиоклип добавлен",
            didApply: { self.selectTimelineAudioClip(clip.id) }
        ) { updated in
            guard TimelineMutationEngine.insertAudioClip(in: &updated, clip: clip) else { return false }
            updated.music = nil
            updated.adaptiveSoundtrack = nil
            return true
        }
    }

    func selectTimelineItem(_ id: UUID?, modifiers: NSEvent.ModifierFlags = []) {
        isTimelineInspectorPresented = false
        updateTimelineSelection(id.map(TimelineSelectionKey.item), modifiers: modifiers)
    }

    func selectTimelineAudioClip(_ id: UUID?, modifiers: NSEvent.ModifierFlags = []) {
        isTimelineInspectorPresented = false
        updateTimelineSelection(id.map(TimelineSelectionKey.audio), modifiers: modifiers)
    }

    func selectTelemetryItem(_ id: UUID?, modifiers: NSEvent.ModifierFlags = []) {
        isTimelineInspectorPresented = false
        updateTimelineSelection(id.map(TimelineSelectionKey.telemetry), modifiers: modifiers)
    }

    func selectEffectTimelineItem(_ id: UUID?, modifiers: NSEvent.ModifierFlags = []) {
        isTimelineInspectorPresented = false
        updateTimelineSelection(id.map(TimelineSelectionKey.effect), modifiers: modifiers)
    }

    func selectEffectTimelineItems(
        _ ids: [UUID],
        primaryID: UUID,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        isTimelineInspectorPresented = false
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
        titleEditStatus = nil
        if let item = selectedTitleTimelineItem { revealTitleForEditing(item) }
    }

    func selectTransitionTimelineItem(_ id: UUID?, modifiers: NSEvent.ModifierFlags = []) {
        isTimelineInspectorPresented = false
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
        let targetClip = targetClipID.flatMap { id in timeline?.items.first(where: { $0.id == id }) }
            ?? time.flatMap { telemetryClip(at: $0) }
            ?? telemetryTargetClip
        guard let targetClip, targetClip.kind == .video else {
            errorMessage = "Выберите видеофрагмент с телеметрией."
            return
        }
        guard let assetID = targetClip.assetID else { return }
        let source = TelemetrySourceSelector().bestSource(
                for: kind,
                linkedAssetID: assetID,
                sources: project?.effectiveTelemetrySources ?? []
            )
        guard let summary = source?.summary ?? project?.analyses.first(where: { $0.assetID == assetID })?.telemetry,
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
        let item = TimelineTelemetryItem(
            targetClipID: targetClip.id,
            sourceID: source?.id,
            linkedAssetID: assetID,
            sourceStart: targetClip.sourceStart,
            timelineStart: targetClip.timelineStart,
            timelineDuration: targetClip.timelineDuration,
            syncOffset: source?.synchronization.offsetSeconds ?? 0,
            settings: settings,
            explanation: ["Телеметрия фрагмента \(targetClip.id.uuidString)"]
        )
        editTimelineOptimistically(
            "Добавлен \(kind.localizedTitle) · \(presentation.localizedTitle)",
            didApply: { self.selectTelemetryItem(item.id) }
        ) {
            TimelineMutationEngine.insertTelemetry(in: &$0, item: item)
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
        guard var copy = selectedTelemetryItem, let timeline else { return }
        copy.id = UUID()
        copy.timelineStart = min(max(0, timeline.duration - copy.timelineDuration), copy.timelineStart + 0.25)
        copy.explanation.append("Копия слоя телеметрии")
        editTimelineOptimistically("Дублирую слой телеметрии", didApply: { self.selectTelemetryItem(copy.id) }) {
            TimelineMutationEngine.insertTelemetry(in: &$0, item: copy)
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
        guard let timeline else { return }
        let target = requestedTime == nil ? selectedTimelineItem : nil
        let start = min(max(0, requestedTime ?? target?.timelineStart ?? timelinePlayheadTime), max(0, timeline.duration - 0.05))
        let duration = min(target?.timelineDuration ?? 2, max(0.25, timeline.duration - start))
        let preset = EffectPresetRegistry.preset(for: type)
        let effect = EffectTimelineItem(
            effectType: type,
            startTime: start,
            duration: duration,
            parameters: preset.defaultParameters,
            targetClipID: target?.id,
            stackOrder: EffectStackEngine.stack(in: timeline, for: target?.id).count,
            explanation: [
                "Пользователь добавил отдельный эффект \(type.localizedTitle)",
                "Renderer: native Core Image; объект остаётся редактируемым на Timeline"
            ]
        )
        editTimelineOptimistically(
            "Эффект добавлен на Timeline",
            didApply: {
                self.selectEffectTimelineItem(effect.id)
                self.revealAddedEffect(start: effect.startTime, duration: effect.duration)
            }
        ) {
            TimelineMutationEngine.insertEffect(in: &$0, effect: effect)
        }
    }

    func applyEffectStackPreset(_ presetID: String, at requestedTime: Double? = nil) {
        guard let preset = EffectStackPresetRegistry.preset(id: presetID), let timeline else { return }
        let target = requestedTime == nil ? selectedTimelineItem : nil
        let start = min(max(0, requestedTime ?? target?.timelineStart ?? timelinePlayheadTime), max(0, timeline.duration - 0.05))
        let duration = min(target?.timelineDuration ?? 3, max(0.05, timeline.duration - start))
        var createdIDs: [UUID] = []
        editTimelineOptimistically("Применяю пресет \(preset.name)", didApply: {
            self.revealAddedEffect(start: start, duration: duration)
        }) {
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

    private func revealAddedEffect(start: Double, duration: Double) {
        guard !(previewPlayer.map(Self.isActivelyPlaying) ?? false) else { return }
        // Sample inside the animation, where zooms/fades/flashes have become
        // visible, including when the drop was away from the old playhead.
        seekTimeline(to: start + duration * 0.35)
    }

    func addTimelineTransition(_ style: TransitionStyle, at requestedTime: Double? = nil) {
        guard let timeline else { return }
        let primary = timeline.items.filter { $0.overlay == nil }.sorted { $0.timelineStart < $1.timelineStart }
        guard primary.count > 1 else { return }
        let incomingIndex: Int? = {
            if requestedTime == nil, let selected = selectedTimelineItem,
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
            editTimelineOptimistically("Возвращаю прямую склейку") {
                TimelineMutationEngine.replaceTransition(in: &$0, incomingClipID: incoming.id, with: nil)
            }
            return
        }
        let preset = TransitionPresetRegistry.preset(for: style)
        let transition = TimelineTransitionItem(
            style: style,
            outgoingClipID: outgoing.id,
            incomingClipID: incoming.id,
            startTime: incoming.timelineStart,
            duration: preset.defaultDuration,
            intensity: preset.defaultIntensity,
            parameters: preset.defaultParameters,
            direction: preset.defaultDirection,
            easing: preset.defaultEasing,
            explanation: [
                "Пользователь добавил \(style.localizedTitle)",
                "Переход — обычный объект Timeline; Preview и Export используют общий renderer"
            ]
        )
        editTimelineOptimistically(
            "Переход добавлен на Timeline",
            didApply: { self.selectTransitionTimelineItem(transition.id) }
        ) {
            TimelineMutationEngine.replaceTransition(in: &$0, incomingClipID: incoming.id, with: transition)
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
        guard var copy = selectedEffectTimelineItem, let timeline else { return }
        copy.id = UUID()
        copy.effectStackPresetID = nil
        copy.effectStackPresetInstanceID = nil
        copy.startTime = min(max(0, timeline.duration - copy.duration), copy.startTime + 0.25)
        editTimelineOptimistically("Дублирую эффект", didApply: { self.selectEffectTimelineItem(copy.id) }) {
            TimelineMutationEngine.insertEffect(in: &$0, effect: copy)
        }
    }

    func copySelectedEffectTimelineItem() {
        guard let item = selectedEffectTimelineItem else { return }
        copiedEffectTimelineItem = item
        status = "Эффект скопирован"
    }

    func pasteEffectTimelineItem(at time: Double? = nil) {
        guard var copy = copiedEffectTimelineItem, let timeline else { return }
        copy.id = UUID()
        copy.startTime = min(max(0, time ?? timelinePlayheadTime), max(0, timeline.duration - 0.05))
        copy.targetClipID = copy.targetClipID.flatMap { id in timeline.items.contains(where: { $0.id == id }) ? id : nil }
        copy.effectStackPresetID = nil
        copy.effectStackPresetInstanceID = nil
        copy.stackOrder = EffectStackEngine.stack(in: timeline, for: copy.targetClipID).count
        copy.explanation.append("Скопировано и вставлено пользователем")
        editTimelineOptimistically("Эффект вставлен", didApply: { self.selectEffectTimelineItem(copy.id) }) {
            TimelineMutationEngine.insertEffect(in: &$0, effect: copy)
        }
    }

    var canPasteEffectTimelineItem: Bool { copiedEffectTimelineItem != nil }

    func addModernTitle(_ text: String, kind: TitleTimelineKind, at time: Double? = nil) {
        let templateID = TitleTemplateRegistry.defaultTemplate(for: kind)?.id
        addModernTitle(text, templateID: templateID, fallbackKind: kind, at: time)
    }

    func addModernTitle(_ text: String, templateID: String?, fallbackKind: TitleTimelineKind = .title, at time: Double? = nil) {
        guard let timeline else { return }
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
        let title = TitleTimelineItem(
            kind: kind,
            templateID: template?.id,
            text: text,
            additionalText: template?.preview.secondaryText,
            callToAction: template?.preview.callToAction,
            startTime: start,
            duration: duration,
            style: template?.defaultStyle ?? TitleStyle(),
            words: words,
            activeWordHighlighting: kind == .wordLevelCaptions,
            explanation: ["Пользователь добавил \(kind.localizedTitle)"]
        )
        editTimelineOptimistically(
            "Титр добавлен на Timeline",
            didApply: { self.selectTitleTimelineItem(title.id) }
        ) {
            TimelineMutationEngine.insertTitle(in: &$0, title: title)
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
                $0.activeWordHighlighting = template.kind == .wordLevelCaptions
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

    @discardableResult
    func editSelectedTitleWithAI(_ instruction: String) -> Bool {
        guard let item = selectedTitleTimelineItem else { return false }
        guard !isTimelineInteractionBlocked else {
            titleEditStatus = "Дождитесь завершения текущей операции и повторите правку."
            return false
        }
        guard let result = TitleEditInterpreter.applying(instruction, to: item) else {
            titleEditStatus = "Не удалось применить запрос. Например: «текст: Поехали», «сделай красным», «крупнее», «номер главы 7» или «шаблон Cinematic»."
            return false
        }
        guard result.item != item else {
            titleEditStatus = "У титра уже заданы эти настройки."
            revealTitleForEditing(item)
            return true
        }
        editTimelineOptimistically("Обновляю титр") {
            TimelineMutationEngine.updateTitle(in: &$0, id: item.id) { title in
                title = result.item
                title.explanation.append("Правка титра по запросу: \(instruction)")
            }
        }
        titleEditStatus = "Изменено: \(result.changes.joined(separator: ", "))."
        return true
    }

    func refreshChapterTitles() {
        guard let pipeline, !isTimelineInteractionBlocked else { return }
        run("Обновляю названия частей") {
            await self.timelineCommitTask?.value
            let renamed = try await pipeline.refreshChapterTitles()
            await self.refresh()
            let playback = try await pipeline.makePlayback(interactiveQuality: Self.interactivePreviewQuality)
            self.setPlayback(playback, show: false)
            let limited = (renamed.chapterTitleDecisions ?? []).filter { $0.source == .fallback || $0.source == .retained }.count
            self.status = limited == 0 ? "Названия частей обновлены" : "Названия обновлены · для \(limited) частей недостаточно подтверждений"
        }
    }

    func setSelectedModernTitleChapterNumber(_ number: Int) {
        guard let item = selectedTitleTimelineItem else { return }
        editTimelineOptimistically("Меняю номер главы") {
            TimelineMutationEngine.updateTitle(in: &$0, id: item.id) { $0.setChapterNumber(number) }
        }
    }

    private func revealTitleForEditing(_ item: TitleTimelineItem) {
        guard previewPlayer.map(Self.isActivelyPlaying) != true else { return }
        let template = TitleTemplateRegistry.template(for: item)
        let motion = template?.animationFitted(to: item.duration)
        let stagger = Double(template?.layout.elements.map(\.staggerIndex).max() ?? 0)
        let entrance = item.animation.entrance == .none ? 0 :
            (motion?.animationIn.duration ?? 0.35) + stagger * (motion?.animationIn.stagger ?? 0)
        let exit = item.animation.exit == .none ? 0 :
            (motion?.animationOut.duration ?? 0.35) + stagger * (motion?.animationOut.stagger ?? 0)
        let local = timelinePlayheadTime - item.startTime
        let frame = 1 / max(1, timeline?.frameRate ?? 30)
        if local < entrance + frame || local >= item.duration - exit - frame {
            let settled = min(item.duration - frame, max(entrance + frame, item.duration * 0.5))
            seekTimeline(to: item.startTime + max(0, settled))
        }
    }

    func setSelectedTransitionDuration(_ duration: Double) {
        guard let item = selectedTransitionTimelineItem else { return }
        editTimelineOptimistically("Меняю длительность перехода") {
            TimelineMutationEngine.updateTransition(in: &$0, id: item.id) { $0.duration = duration }
        }
    }

    func setSelectedTransitionStyle(_ style: TransitionStyle) {
        guard let item = selectedTransitionTimelineItem else { return }
        if style == .cut {
            editTimelineOptimistically("Возвращаю прямую склейку") {
                TimelineMutationEngine.replaceTransition(in: &$0, incomingClipID: item.incomingClipID, with: nil)
            }
            return
        }
        editTimelineOptimistically("Меняю тип перехода") {
            TimelineMutationEngine.updateTransition(in: &$0, id: item.id) {
                let preset = TransitionPresetRegistry.preset(for: style)
                $0.style = style
                $0.intensity = preset.defaultIntensity
                $0.parameters = preset.defaultParameters
                $0.direction = preset.defaultDirection
                $0.easing = preset.defaultEasing
            }
        }
    }

    func setSelectedTransitionEnabled(_ enabled: Bool) {
        guard let item = selectedTransitionTimelineItem else { return }
        editTimelineOptimistically(enabled ? "Включаю переход" : "Выключаю переход") {
            TimelineMutationEngine.updateTransition(in: &$0, id: item.id) { $0.enabled = enabled }
        }
    }

    func setSelectedTransitionIntensity(_ intensity: Double) {
        guard let item = selectedTransitionTimelineItem else { return }
        editTimelineOptimistically("Меняю интенсивность перехода") {
            TimelineMutationEngine.updateTransition(in: &$0, id: item.id) { $0.intensity = intensity }
        }
    }

    func setSelectedTransitionParameter(_ name: String, value: Double) {
        guard let item = selectedTransitionTimelineItem else { return }
        var parameters = item.effectiveParameters.filter { $0.name != name }
        parameters.append(EffectParameter(name: name, value: value))
        editTimelineOptimistically("Меняю параметр перехода") {
            TimelineMutationEngine.updateTransition(in: &$0, id: item.id) { $0.parameters = parameters }
        }
    }

    func setSelectedTransitionDirection(_ direction: TransitionDirection) {
        guard let item = selectedTransitionTimelineItem else { return }
        editTimelineOptimistically("Меняю направление перехода") {
            TimelineMutationEngine.updateTransition(in: &$0, id: item.id) { $0.direction = direction }
        }
    }

    func setSelectedTransitionEasing(_ easing: KeyframeEasing) {
        guard let item = selectedTransitionTimelineItem else { return }
        editTimelineOptimistically("Меняю easing перехода") {
            TimelineMutationEngine.updateTransition(in: &$0, id: item.id) { $0.easing = easing }
        }
    }

    func deleteSelectedTimelineObject() {
        deleteTimelineSelection()
    }

    func selectSoundtrack() {
        guard timeline?.music != nil else { return }
        isTimelineInspectorPresented = false
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
        guard let timeline, let clipboard = timelineClipboard, !clipboard.isEmpty else { return }
        let position = min(max(0, requestedTime ?? timelinePlayheadTime), timeline.duration)
        let result = inserting(clipboard, into: timeline, at: position)
        editTimelineOptimistically("Элементы вставлены", didApply: {
            self.applyTimelineSelection(result.selection, active: result.active)
        }) {
            $0 = result.timeline
            return true
        }
    }

    func duplicateTimelineSelection() {
        guard let timeline, let clipboard = makeTimelineClipboard(), !clipboard.isEmpty else { return }
        let selectedEndTimes = clipboard.items.map { $0.timelineStart + $0.timelineDuration } +
            clipboard.audioClips.map(\.timelineEnd) + clipboard.telemetryItems.map(\.timelineEnd) +
            clipboard.effects.map(\.endTime) + clipboard.titles.map(\.endTime) +
            clipboard.transitions.map { $0.startTime + $0.duration }
        let position = min(max(0, selectedEndTimes.max() ?? timelinePlayheadTime), timeline.duration)
        let result = inserting(clipboard, into: timeline, at: position)
        editTimelineOptimistically("Элементы продублированы", didApply: {
            self.applyTimelineSelection(result.selection, active: result.active)
        }) {
            $0 = result.timeline
            return true
        }
    }

    func deleteTimelineSelection(status initialStatus: String = "Удаляю выбранные элементы") {
        guard var updated = timeline, hasTimelineSelection else { return }
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
        updated.telemetryItems = updated.effectiveTelemetryItems.filter {
            !telemetryIDs.contains($0.id) && $0.targetClipID.map(removedClipIDs.contains) != true
        }
        updated.effects = updated.effectiveEffects.filter {
            !effectIDs.contains($0.id) && $0.targetClipID.map(removedClipIDs.contains) != true
        }
        for title in updated.effectiveTitleItems where titleIDs.contains(title.id) { SpeechSubtitleBuilder.suppress(title, in: &updated) }
        updated.titleItems = updated.effectiveTitleItems.filter {
            !titleIDs.contains($0.id) && $0.targetClipID.map(removedClipIDs.contains) != true
        }
        updated.transitionItems = updated.effectiveTransitionItems.filter {
            !transitionIDs.contains($0.id) && !removedClipIDs.contains($0.outgoingClipID) && !removedClipIDs.contains($0.incomingClipID)
        }
        if selection.contains(.soundtrack) { updated.music = nil }
        editTimelineOptimistically(initialStatus, didApply: { self.clearTimelineSelection() }) {
            $0 = updated
            return true
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
        guard let music = timeline?.music, let trackID = music.trackID else { return }
        insertMusicClip(trackID, at: time, duration: nil, sourceStart: music.sourceStart ?? 0, speed: music.effectiveSpeed)
    }

    func trimSoundtrack(toTimelineStart start: Double, duration: Double) {
        guard let music = timeline?.music, let trackID = music.trackID else { return }
        insertMusicClip(trackID, at: start, duration: duration,
                        sourceStart: (music.sourceStart ?? 0) + max(0, start) * music.effectiveSpeed, speed: music.effectiveSpeed)
    }

    func seekTimeline(to requestedTime: Double) {
        guard requestedTime.isFinite, let timeline, let map = playbackMap else { return }
        let time = min(max(0, TimelineTiming.quantized(requestedTime, frameRate: timeline.frameRate)), map.duration)
        timelinePlayheadTime = time
        guard previewPlayer?.currentItem != nil else { return }
        let mapped = map.playbackTime(forTimelineTime: time)
        let playbackTime = Self.playablePreviewTime(mapped, duration: activePlayback?.duration ?? map.duration,
                                                   frameRate: timeline.frameRate)
        // An old decoder result must not move the user's pointer backwards.
        pendingPlaybackSeekTimelineTime = nil
        previewSeekRevision &+= 1
        previewPosterTask?.cancel()
        previewPosterTask = nil
        previewPosterRequestID = nil
        if let playback = activePlayback {
            hidePreviewPosterIfStale(for: playback, playbackTime: playbackTime, frameRate: timeline.frameRate)
        }
        previewSeeker.submit(time: playbackTime, frameRate: timeline.frameRate)
    }

    var shouldHandleTimelineUndo: Bool {
        !intro.blocksEditorInput && !isPresentingNewProject && openingProjectURL == nil && timeline != nil && editorialComparison == nil && !showEditorialStyle && !isTextEntryFocused
    }

    var shouldHandleTimelineShortcuts: Bool {
        !intro.blocksEditorInput && !isPresentingNewProject && openingProjectURL == nil && section == .timeline && !isTextEntryFocused
    }

    func handleTimelineKeyDown(_ event: NSEvent) -> Bool {
        guard shouldHandleTimelineShortcuts else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // Boundary navigation belongs to the editor, even without menu items.
        if modifiers == .command {
            switch event.keyCode {
            case 123: seekTimeline(to: 0); return true
            case 124: seekTimeline(to: timeline?.duration ?? 0); return true
            default: break
            }
        }
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
            // Let the view close previews or cancel work before clearing selection.
            return false
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
        guard let responder = NSApp?.keyWindow?.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }
        return responder.nextResponder is NSTextView || responder.nextResponder is NSTextField
    }

    /// Montage comments share the director and keep their captured selection.
    private func applyTimelineAIComment(_ edit: PendingTimelineAIEdit) {
        let clean = edit.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pipeline, !clean.isEmpty, !isWorking else { return }

        let previousTimeline = timeline
        let preservedTimelineTime = edit.playheadTime
        let shouldResumePlayback = previewPlayer.map(Self.isActivelyPlaying) ?? false
        let normalizedInstruction = clean.lowercased().replacingOccurrences(of: "ё", with: "е")
        let explicitlyUsesSelection = [
            "выбранн", "выделенн", "этот клип", "этого клипа", "этом клипе",
            "этот фрагмент", "этого фрагмента", "этом фрагменте",
            "этот момент", "этого момента", "у него", "на нем", "сделай его"
        ].contains(where: normalizedInstruction.contains)
            || (edit.selectedItemIsTitle
                && EditorCommandParser().parse(clean, preset: edit.preset).contains { $0.semanticCategory.hasPrefix("title-") })
        let selectedItemID: UUID? = {
            guard explicitlyUsesSelection else { return nil }
            if let id = edit.selectedItemID,
               (previousTimeline?.items.contains(where: { $0.id == id }) == true
                || previousTimeline?.effectiveTitleItems.contains(where: { $0.id == id }) == true) {
                return id
            }
            return nil
        }()
        guard !explicitlyUsesSelection || selectedItemID != nil else {
            feedback = clean
            status = "Выбранный при отправке клип удалён — выберите адресат правки заново"
            updateTimelineDirectorExchange(edit.replyID, status: status)
            activeTimelineAIEdit = nil
            Task { @MainActor [weak self] in self?.startNextQueuedTimelineAIEdit() }
            return
        }

        progress = 0
        isCreatingFilm = true
        run("ИИ применяет комментарий к монтажу", presentation: .editorAI) {
            defer { self.isCreatingFilm = false }
            self.activityTitle = "Понимаю монтажную правку"
            self.status = "Локальный ИИ переводит пожелание в безопасный план действий"
            var context = EditorCommandParser().parseComplete(clean, hasSelection: selectedItemID != nil) != nil
                ? DirectorContext(assetCount: 0, videoCount: 0, photoCount: 0, analyzedCount: 0, candidateCount: 0,
                    currentTimelineItemCount: previousTimeline?.items.count ?? 0, targetDuration: edit.targetDuration ?? 0,
                    preset: edit.preset, currentOperation: "Точная правка", selectedItemSummary: selectedItemID?.uuidString)
                : self.directorContext(selection: (selectedItemID, edit.playheadTime))
            if !explicitlyUsesSelection {
                context.selectedItemSummary = nil
                context.neighboringItemSummaries = []
            }
            let reply = await self.directorAgent.respond(
                to: clean,
                context: context,
                mode: .edit,
                recordInHistory: false,
                onPartialReply: { [weak self] text in self?.status = "\(text) · ожидаю полный план" }
            )
            try Task.checkCancellation()
            self.editTrace?.event("edit.plan.ready")
            guard !reply.planningFailed else {
                self.status = reply.text
                self.setDirectorResponseRecord(edit.replyID, receipt: .init(failure: reply.text))
                return
            }
            guard !self.needsTimelineAIRetryAfterManualEdit else { return }
            self.directorRuntimeStatus = reply.runtimeLabel
            self.progress = 0.16
            let deterministicCommands = EditorCommandParser().parse(clean, preset: edit.preset)
            let deterministicCategories = Set(deterministicCommands.map(\.semanticCategory))
            let requestsWholeFilmDuration = AutonomousDurationOptimizer.requestContainsExplicitDuration(clean)
                && !deterministicCommands.contains(where: { $0.semanticCategory == "duration" })
            let supplementalCommands = EditorCommand.supplemental(reply.commands.filter {
                !(requestsWholeFilmDuration && $0.semanticCategory == "duration")
            }, to: deterministicCommands)

            let planningPlan: NaturalLanguageEditingPlan? = if let currentProject = self.project,
                                                               let currentTimeline = previousTimeline {
                NaturalLanguageDirector().plan(
                    input: NaturalLanguageDirectorInput(
                        userRequest: clean,
                        currentProject: currentProject,
                        timeline: currentTimeline,
                        selectedItemID: selectedItemID,
                        playheadTime: edit.playheadTime
                    ),
                    supplementalCommands: supplementalCommands
                )
            } else {
                nil
            }

            var finalExecution: NaturalLanguageEditResult?
            var didRebuild = false
            var refinementFailure: String?
            var previewReady = false

            if planningPlan?.requiresBackgroundRefinement == true {
                self.progress = 0.36
                self.activityTitle = "Уточняю режиссёрское решение"
                self.status = "Пересобираю историю без повторного анализа исходников"
                let normalized = reply.normalizedBrief?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let feedback = if let normalized,
                                  !normalized.isEmpty,
                                  normalized.localizedCaseInsensitiveCompare(clean) != .orderedSame {
                    "Режиссёрская интерпретация: \(normalized)\nТочный запрос пользователя: \(clean)"
                } else {
                    clean
                }
                _ = try await pipeline.regenerate(
                    feedback: feedback,
                    preset: edit.preset,
                    targetDuration: edit.targetDuration,
                    preferredMusicTrackID: edit.preferredMusicTrackID,
                    directorBrief: edit.directorBrief,
                    ignoredFeedbackConstraints: Self.ignoredStoryConstraints(
                        for: clean,
                        commandCategories: deterministicCategories
                    )
                )
                didRebuild = true
                guard !self.needsTimelineAIRetryAfterManualEdit else { return }
                await self.refresh()
                let refinedSelectedItemID = explicitlyUsesSelection
                    ? (edit.selectedItemIsTitle ? edit.selectedItemID : edit.selectedCandidateID.flatMap { candidateID in
                        self.timeline?.items.first(where: { $0.candidateID == candidateID })?.id
                    })
                    : nil
                self.progress = 0.76
                self.activityTitle = "Применяю точные монтажные команды"
                self.status = "Сохраняю фильтры, звук, титры, переходы и эффекты из комментария"
                if Task.isCancelled {
                    refinementFailure = "дополнительное уточнение отменено после основной пересборки"
                } else {
                    do {
                        finalExecution = try await pipeline.applyNaturalLanguageEdit(
                            clean,
                            selectedItemID: refinedSelectedItemID,
                            playheadTime: edit.playheadTime,
                            supplementalCommands: supplementalCommands,
                            createCheckpoint: false,
                            recordHistory: true
                        )
                    } catch {
                        refinementFailure = error.localizedDescription
                    }
                }
            } else {
                self.activityTitle = "Применяю правку"
                self.status = "Обновляю только затронутые слои Timeline"
                finalExecution = try await pipeline.applyNaturalLanguageEdit(
                    clean,
                    selectedItemID: selectedItemID,
                    playheadTime: edit.playheadTime,
                    supplementalCommands: supplementalCommands,
                    createCheckpoint: true,
                    recordHistory: true
                )
            }

            guard !self.needsTimelineAIRetryAfterManualEdit else { return }
            await self.refresh()
            // The pipeline checks cancellation before its atomic store commit.
            // Once it returns, always reconcile AppModel with the durable state
            // instead of reporting a cancellation against an already-saved edit.
            self.directorBrief = edit.directorBrief
            self.targetMinutes = edit.directorBrief.requestedDuration / 60
            self.directorMusicTrackID = edit.directorBrief.musicPolicy == .specificTrack
                ? edit.directorBrief.musicTrackID
                : nil
            let changed = previousTimeline != self.timeline
            if changed {
                PerformanceTrace.current?.event("comment.applied-and-saved")
                self.editTrace?.event("edit.saved")
                self.recordTimelineChange(from: previousTimeline)
                if let previousTimeline, let current = self.timeline {
                    _ = try? await pipeline.recordPreferenceSignals(
                        before: previousTimeline,
                        after: current,
                        source: didRebuild ? .regenerate : .acceptedEdit
                    )
                }
                self.progress = 0.84
                self.activityTitle = "Обновляю просмотр"
                self.status = "Собираю Preview из изменённого Timeline"
                let previewUpdated = await self.rebuildPlaybackIfPossible(
                    show: false,
                    restoringTimelineTime: preservedTimelineTime,
                    resumePlayback: shouldResumePlayback
                )
                self.showViewer = true
                previewReady = previewUpdated
                if !previewUpdated {
                    refinementFailure = "правка сохранена, но просмотр не обновлён: \(self.errorMessage ?? "повторите подготовку просмотра")"
                }
                self.editTrace?.event(previewUpdated ? "director.preview-ready" : "director.preview-failed")
                PerformanceTrace.current?.event(previewUpdated ? "comment.preview-available" : "comment.preview-failed")
            }

            if (changed || didRebuild),
               !self.prompt.localizedCaseInsensitiveContains(clean) {
                self.prompt += "\n\(clean)"
            }
            self.progress = 1
            let applied = (finalExecution?.commandReport.applied ?? [])
                + (finalExecution?.toolReport.applied.map(\.reason) ?? [])
            let omitted = (finalExecution?.commandReport.ignored ?? []) + (finalExecution?.toolReport.rejected ?? [])
                + (finalExecution?.safetyViolations ?? []) + (finalExecution?.plan.rejectedReasons ?? [])
            let receipt = DirectorExecutionReceipt(requested: finalExecution?.plan.commands ?? reply.commands,
                applied: applied, omitted: omitted, saved: changed || didRebuild, previewReady: previewReady,
                cancelled: Task.isCancelled, failure: refinementFailure)
            self.status = DirectorResponseComposer.execution(receipt)
            self.setDirectorResponseRecord(edit.replyID, receipt: receipt)
            if changed { self.scheduleFilmVerification() }
        }
    }

    private func applyMagicBrush(_ edit: PendingTimelineAIEdit) {
        guard let range = edit.range else { return }
        let clean = edit.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pipeline, !clean.isEmpty, !isWorking else { return }
        let previousTimeline = timeline
        let preservedTimelineTime = edit.playheadTime
        let shouldResumePlayback = previewPlayer.map(Self.isActivelyPlaying) ?? false
        run("Волшебная кисть изменяет выбранный диапазон", presentation: .editorAI) {
            var context = self.directorContext(selection: (edit.selectedItemID, edit.playheadTime))
            context.selectedItemSummary = "Только выделенный диапазон \(Self.clockText(range.lowerBound))–\(Self.clockText(range.upperBound)); остальные части фильма менять нельзя"
            context.playheadTime = range.lowerBound
            let reply = await self.directorAgent.respond(
                to: clean, context: context, mode: .edit,
                recordInHistory: false, allowsFootageReplacement: true
            )
            self.directorRuntimeStatus = reply.runtimeLabel
            try Task.checkCancellation()
            guard !reply.planningFailed else {
                self.status = reply.text
                self.setDirectorResponseRecord(edit.replyID, receipt: .init(failure: reply.text))
                return
            }
            guard !self.needsTimelineAIRetryAfterManualEdit else { return }
            let report = try await pipeline.applyEditorCommands(clean, timelineRange: range, preset: edit.preset, supplementalCommands: reply.commands, modelRequestsReplacement: reply.replacesSelectedFootage)
            guard report.hasChanges else {
                let receipt = DirectorExecutionReceipt(omitted: report.ignored)
                self.status = DirectorResponseComposer.execution(receipt)
                self.setDirectorResponseRecord(edit.replyID, receipt: receipt)
                return
            }
            guard !self.needsTimelineAIRetryAfterManualEdit else { return }
            await self.refresh()
            self.recordTimelineChange(from: previousTimeline)
            if let previousTimeline, let current = self.timeline {
                _ = try? await pipeline.recordPreferenceSignals(before: previousTimeline, after: current)
            }
            let previewUpdated = await self.rebuildPlaybackIfPossible(
                show: false,
                restoringTimelineTime: preservedTimelineTime,
                resumePlayback: shouldResumePlayback
            )
            self.showViewer = true
            let receipt = DirectorExecutionReceipt(requested: reply.commands, applied: report.applied, omitted: report.ignored,
                saved: true, previewReady: previewUpdated, cancelled: Task.isCancelled)
            self.status = DirectorResponseComposer.execution(receipt) + " Только в выделенном диапазоне."
            self.setDirectorResponseRecord(edit.replyID, receipt: receipt)
            self.scheduleFilmVerification()
        }
    }

    func undoTimelineEdit() {
        if !isTimelineInteractionBlocked, let pipeline,
           let removed = project?.removedMedia?.last, removed.afterTimelines == project?.timelines {
            run("Возвращаю материал") {
                try await pipeline.restoreRemovedMedia(id: removed.id)
                await self.refresh()
                self.updateTimelineHistoryAvailability()
                await self.rebuildPlaybackIfPossible(show: false)
                self.status = "Материал и его монтаж восстановлены"
            }
            return
        }
        guard !isTimelineInteractionBlocked, pipeline != nil, let current = timeline, let target = undoTimelineHistory.popLast() else { return }
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
        guard !isTimelineInteractionBlocked, pipeline != nil, let current = timeline, let target = redoTimelineHistory.popLast() else { return }
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

    func trimTimelineItem(id: UUID, sourceStart: Double, timelineDuration: Double, timelineStart: Double? = nil) {
        selectTimelineItem(id)
        editTimelineOptimistically("Меняю границы фрагмента") {
            TimelineMutationEngine.updateItem(in: &$0, id: id) {
                let factor = $0.speedRamp?.outputDuration(sourceDuration: 1) ?? (1 / $0.speed)
                if let timelineStart, $0.overlay != nil {
                    let offset = ($0.overlay?.effectiveStartOffset ?? 0) + timelineStart - $0.timelineStart
                    $0.overlay?.startOffset = offset
                    $0.timelineStart = timelineStart
                }
                $0.sourceStart = sourceStart
                $0.timelineDuration = timelineDuration
                $0.sourceDuration = timelineDuration / max(0.01, factor)
            }
        }
    }

    func toggleSelectedTimelineLock() {
        guard let item = selectedTimelineItem else { return }
        editTimelineOptimistically(item.locked ? "Снимаю блокировку" : "Закрепляю фрагмент") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) { $0.locked.toggle() }
        }
    }

    func setSelectedTransition(_ transition: String?) {
        guard let item = selectedTimelineItem else { return }
        editTimelineOptimistically("Обновляю переход") {
            TimelineMutationEngine.setTransition(in: &$0, incomingClipID: item.id, style: transition.flatMap(TransitionStyle.init(rawValue:)))
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
        guard let item = selectedTimelineItem, !item.isFreezeFrame else { return }
        let ramp: SpeedRamp?
        switch mode {
        case "ease-in": ramp = .easeIn
        case "ease-out": ramp = .easeOut
        case "action": ramp = .action
        default: ramp = nil
        }
        editTimelineOptimistically(ramp == nil ? "Убираю рамп скорости" : "Настраиваю рамп скорости") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) {
                $0.speed = 1
                $0.speedRamp = ramp
                $0.timelineDuration = max(0.25, ramp?.outputDuration(sourceDuration: $0.sourceDuration) ?? $0.sourceDuration)
                var video = $0.effectiveVideoAdjustments
                video.smoothSlowMotion = false
                $0.videoAdjustments = video.isNeutral ? nil : video
            }
        }
    }

    func setSelectedCrop(_ crop: CropStyle) {
        guard let item = selectedTimelineItem else { return }
        var value = item.effectiveVideoAdjustments
        value.crop = crop
        editTimelineOptimistically("Меняю кадрирование") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) {
                $0.videoAdjustments = value.isNeutral ? nil : value
            }
        }
    }

    func setSelectedCropMode(_ mode: String) {
        guard let item = selectedTimelineItem else { return }
        var video = item.effectiveVideoAdjustments
        video.crop = mode == "fit" ? .fit : .fill
        // A manual framing choice must override the director's stored
        // subject-aware zoom; otherwise “Уместить” still looked cropped.
        video.subjectReframe = nil
        let effect: String? = mode == "ken-burns"
            ? ClipEffect.kenBurns.rawValue
            : (item.effect == ClipEffect.kenBurns.rawValue ? nil : item.effect)
        editTimelineOptimistically("Меняю стиль кадрирования") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) {
                $0.effect = effect
                $0.videoAdjustments = video.isNeutral ? nil : video
            }
        }
    }

    func setSelectedFilter(_ filter: VideoFilter) {
        guard let item = selectedTimelineItem else { return }
        var value = item.effectiveVideoAdjustments
        value.filter = filter
        editTimelineOptimistically("Применяю видеофильтр") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) {
                $0.videoAdjustments = value.isNeutral ? nil : value
            }
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
        guard let item = selectedTimelineItem else { return }
        var value = item.effectiveVideoAdjustments
        value.rotationQuarterTurns = ((value.rotationQuarterTurns + quarterTurns) % 4 + 4) % 4
        editTimelineOptimistically("Поворачиваю фрагмент") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) {
                $0.videoAdjustments = value.isNeutral ? nil : value
            }
        }
    }

    func setSelectedOverlay(_ style: OverlayStyle?) {
        guard let item = selectedTimelineItem else { return }
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
        editTimelineOptimistically(style == nil ? "Убираю наложение" : "Создаю второй видеослой") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) {
                $0.overlay = overlay
            }
        }
    }

    func autoEnhanceSelected() {
        guard let item = selectedTimelineItem, item.kind != .title else { return }
        editTimelineOptimistically("Автоматически улучшаю цвет") {
            let result = EditorCommandExecutor().apply([.autoEnhance(.selected)], to: $0, selectedItemID: item.id)
            $0 = result.timeline
            return result.report.hasChanges
        }
    }

    func insertFreezeFrameForSelected(duration: Double = 2) {
        guard let item = selectedTimelineItem, item.kind == .video else { return }
        editTimelineOptimistically("Добавляю стоп-кадр") {
            let result = EditorCommandExecutor().apply(
                [.insertFreezeFrame(duration, .selected)],
                to: $0,
                selectedItemID: item.id
            )
            $0 = result.timeline
            return result.report.hasChanges
        }
    }

    func toggleSelectedReverse() {
        guard let item = selectedTimelineItem, item.kind == .video else { return }
        editTimelineOptimistically(item.isReversed ? "Возвращаю обычное воспроизведение" : "Включаю реверс") {
            let result = EditorCommandExecutor().apply(
                [.setReverse(!item.isReversed, .selected)],
                to: $0,
                selectedItemID: item.id
            )
            $0 = result.timeline
            return result.report.hasChanges
        }
    }

    func insertInstantReplayForSelected() {
        guard let item = selectedTimelineItem, item.kind == .video else { return }
        editTimelineOptimistically("Добавляю замедленный повтор") {
            let result = EditorCommandExecutor().apply(
                [.insertInstantReplay(0.5, .selected)],
                to: $0,
                selectedItemID: item.id
            )
            $0 = result.timeline
            return result.report.hasChanges
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
        guard let item = selectedTimelineItem else { return }
        var video = item.effectiveVideoAdjustments
        video.crop = .fill
        video.rotationQuarterTurns = 0
        video.subjectReframe = nil
        editTimelineOptimistically("Сбрасываю кадрирование") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) {
                $0.effect = item.effect == ClipEffect.kenBurns.rawValue ? nil : item.effect
                $0.videoAdjustments = video.isNeutral ? nil : video
            }
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
        guard let item = selectedTimelineItem else { return }
        var video = item.effectiveVideoAdjustments
        video.smoothSlowMotion = false
        var audio = item.effectiveAudioAdjustments
        audio.preservePitch = true
        editTimelineOptimistically("Сбрасываю скорость") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) {
                $0.speed = 1
                $0.speedRamp = nil
                $0.timelineDuration = $0.sourceDuration
                $0.reversePlayback = nil
                $0.videoAdjustments = video.isNeutral ? nil : video
                $0.audioAdjustments = audio.isNeutral ? nil : audio
            }
        }
    }

    func resetSelectedFilters() {
        guard let item = selectedTimelineItem else { return }
        var video = item.effectiveVideoAdjustments
        video.filter = .none
        video.filterIntensity = 1
        var audio = item.effectiveAudioAdjustments
        audio.effect = AudioEffect.none
        editTimelineOptimistically("Сбрасываю фильтры") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) {
                $0.videoAdjustments = video.isNeutral ? nil : video
                $0.audioAdjustments = audio.isNeutral ? nil : audio
            }
        }
    }

    func resetAllSelectedViewerAdjustments() {
        guard let item = selectedTimelineItem else { return }
        editTimelineOptimistically("Сбрасываю все настройки фрагмента") {
            TimelineMutationEngine.updateItem(in: &$0, id: item.id) {
                $0.speed = 1
                $0.speedRamp = nil
                $0.timelineDuration = $0.sourceDuration
                $0.effect = nil
                $0.videoAdjustments = nil
                $0.audioAdjustments = nil
                $0.reversePlayback = nil
            }
        }
    }

    func setSelectedTelemetryEnabled(_ enabled: Bool) {
        guard let item = selectedTimelineItem else { return }
        editTimelineOptimistically(enabled ? "Добавляю телеметрию" : "Убираю телеметрию") {
            let result = EditorCommandExecutor().apply(
                [.setTelemetryOverlay(enabled ? TelemetryOverlaySettings() : nil, .selected)],
                to: $0,
                selectedItemID: item.id
            )
            $0 = result.timeline
            return result.report.hasChanges
        }
    }

    func duplicateSelectedTimelineItem() {
        duplicateTimelineSelection()
    }

    func splitSelectedTimelineItem() {
        guard canSplitTimelineSelectionAtPlayhead else { return }
        var createdID: UUID?
        let splitTime = timelinePlayheadTime
        if let item = selectedTimelineItem {
            editTimelineOptimistically("Фрагмент разделён", didApply: {
                if let createdID { self.selectTimelineItem(createdID) }
            }) {
                createdID = TimelineMutationEngine.splitItem(in: &$0, id: item.id, atTimelineTime: splitTime)
                return createdID != nil
            }
        } else if let clip = selectedTimelineAudioClip {
            editTimelineOptimistically("Аудио разделено", didApply: {
                if let createdID { self.selectTimelineAudioClip(createdID) }
            }) {
                createdID = TimelineMutationEngine.splitAudioClip(in: &$0, id: clip.id, atTimelineTime: splitTime)
                return createdID != nil
            }
        }
    }

    func detachSelectedAudio() {
        guard let item = selectedTimelineItem else { return }
        let assets = project?.assets ?? []
        var createdID: UUID?
        editTimelineOptimistically("Аудио отделено", didApply: {
            if let createdID { self.selectTimelineAudioClip(createdID) }
        }) {
            createdID = TimelineMutationEngine.detachAudio(in: &$0, from: item.id, assets: assets)
            return createdID != nil
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
                $0.sourceDuration = duration * $0.effectiveSpeed
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

    func setSelectedTimelineAudioSpeed(_ speed: Double) {
        guard let clip = selectedTimelineAudioClip else { return }
        let clamped = min(max(0.1, speed), 20)
        editTimelineOptimistically("Меняю скорость аудиоклипа") {
            TimelineMutationEngine.updateAudioClip(in: &$0, id: clip.id) {
                $0.speed = clamped
                $0.timelineDuration = max(0.05, $0.sourceDuration / clamped)
            }
        }
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
        guard let source = copiedTimelineItemSettings,
              let target = timeline?.items.first(where: { $0.id == id }) else { return }
        editTimelineOptimistically("Настройки фрагмента вставлены", didApply: { self.selectTimelineItem(id) }) { timeline in
            let changed = TimelineMutationEngine.updateItem(in: &timeline, id: id) {
                if target.kind == .video {
                    $0.speed = source.speed
                    $0.speedRamp = nil
                    $0.timelineDuration = max(0.05, $0.sourceDuration / source.speed)
                    $0.audioAdjustments = source.audioAdjustments
                }
                $0.effect = source.effect
                $0.videoAdjustments = source.videoAdjustments
                if target.kind == .title { $0.titleStyle = source.titleStyle }
            }
            let transitionChanged = TimelineMutationEngine.setTransition(
                in: &timeline, incomingClipID: id, style: source.transition.flatMap(TransitionStyle.init(rawValue:)))
            return changed || transitionChanged
        }
    }

    var canPasteTimelineSettings: Bool { copiedTimelineItemSettings != nil }

    func addTitle(_ text: String, atEnd: Bool) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        editTimelineOptimistically("Добавляю титр") {
            let result = EditorCommandExecutor().apply([.addTitle(clean, atEnd ? .end : .beginning)], to: $0)
            $0 = result.timeline
            return result.report.hasChanges
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
            if style == nil {
                self.directorBrief.musicPolicy = .none
                self.directorBrief.musicTrackID = nil
                self.directorMusicTrackID = nil
            } else {
                let resolvedTrackID = await pipeline.snapshot().timelines.last?.music?.trackID
                self.directorBrief.musicPolicy = resolvedTrackID == nil ? .matchVideo : .specificTrack
                self.directorBrief.musicTrackID = resolvedTrackID
                self.directorMusicTrackID = resolvedTrackID
            }
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
        let resolvedTrackID = directive?.trackID
        editTimeline(directive == nil ? "Убираю музыку" : "Выбираю локальный трек") {
            try await pipeline.updateMusic(directive)
            self.directorBrief.musicPolicy = resolvedTrackID == nil ? .none : .specificTrack
            self.directorBrief.musicTrackID = resolvedTrackID
            self.directorMusicTrackID = resolvedTrackID
        }
    }

    func setMusicVolume(_ volume: Double) {
        editTimelineOptimistically("Настраиваю громкость музыки") { timeline in
            guard timeline.music != nil else { return false }
            timeline.setSoundtrackVolume(volume)
            return true
        }
    }

    func setMusicSpeed(_ speed: Double) {
        editTimelineOptimistically("Меняю скорость музыки") { timeline in
            guard timeline.music != nil else { return false }
            timeline.setSoundtrackSpeed(speed)
            return true
        }
    }

    func setOriginalAudioEnabled(_ enabled: Bool) {
        editTimelineOptimistically(
            enabled ? "Включаю звук исходников" : "Убираю звук исходников",
            didApply: {
                self.directorBrief.sourceAudioPolicy = enabled ? .preserve : .mute
            }
        ) { timeline in
            let value = enabled ? 1.0 : 0.0
            guard abs(timeline.effectiveOriginalAudioVolume - value) > 0.0001 else { return false }
            timeline.originalAudioVolume = value
            return true
        }
    }

    func deleteSelectedTimelineItem() {
        deleteTimelineSelection()
    }

    func cancelOperation() { guard !storageIsCleaning else { return }; cancelOperation(preservingProgress: false) }

    private func cancelOperation(preservingProgress: Bool) {
        for edit in pendingTimelineAIEdits {
            updateTimelineDirectorExchange(edit.replyID, status: "Правка отменена до выполнения")
        }
        pendingTimelineAIEdits.removeAll()
        queuedTimelineAIEditCount = 0
        if !queuedDirectorMessages.isEmpty {
            directorInput = (queuedDirectorMessages + [directorInput]).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        queuedDirectorMessages.removeAll()
        hasQueuedFilmRequest = false
        directorGeneration &+= 1
        directorTask?.cancel()
        directorTask = nil
        isDirectorResponding = false
        if !isWorking { isAnalyzing = false }
        directorMessages.removeAll { $0.role == .assistant && $0.text.isEmpty }
        directorStatus = isCreatingFilm
            ? "Создание фильма отменено · можно повторить"
            : "Операция отменена · можно отправить новое сообщение"
        externalResourceWaitTask?.cancel()
        externalResourceWaitTask = nil
        activeTask?.cancel()
        status = "Операция отменена"
        if let pipeline {
            Task {
                if !preservingProgress { try? await pipeline.store.cancelAutonomousJob() }
                await pipeline.cancelAllAnalysis()
            }
        }
    }

    func waitForCurrentWork() async {
        while hasActiveWork && !Task.isCancelled {
            await activeTask?.value
            await directorTask?.value
            await projectOpenTask?.value
            if hasActiveWork { try? await Task.sleep(for: .milliseconds(100)) }
        }
    }

    func stopForApplicationTermination(preserveProgress: Bool = true) async -> Bool {
        let jobBeforeExit = await pipeline?.store.manifest.autonomousJob
        let shouldResume = jobBeforeExit?.state.resumesAutomatically == true && jobBeforeExit?.explicitCancellation != true
        let work = activeTask
        let reply = directorTask
        previewSeeker.reset()
        previewPosterTask?.cancel()
        cancelOperation(preservingProgress: preserveProgress)
        projectOpenTask?.cancel()
        projectRestoreTask?.cancel()
        filmVerificationTask?.cancel()
        previewRebuildTask?.cancel()
        if let pipeline { await pipeline.cancelAllAnalysis() }
        await work?.value
        await reply?.value
        await projectOpenTask?.value
        if let pipeline {
            do {
                if preserveProgress && shouldResume { try await pipeline.store.prepareAutonomousJobForRestart() }
                else if !preserveProgress { try await pipeline.store.cancelAutonomousJob() }
            }
            catch { errorMessage = "Не удалось сохранить задание для продолжения: \(error.localizedDescription)"; return false }
        }
        return true
    }

    func useNewMaterialsInFilm() {
        guard newMaterialCount > 0, !isWorking, !isDirectorResponding else { return }
        newMaterialCount = 0
        markFilmNeedsRebuild("Добавляю новые материалы в фильм", instruction: "Используй вновь добавленные материалы в фильме")
        createFilm()
    }

    func dismissNewMaterials() { newMaterialCount = 0 }

    func startManualEditing() {
        guard let pipeline, !isWorking else { return }
        section = .timeline
        guard timeline == nil else { return }
        run("Открываю ручной монтаж", presentation: .silentEditor) {
            try await pipeline.createManualTimeline()
            await self.refresh()
            self.section = .timeline
            self.status = "Добавляйте материалы на монтажную линию"
        }
    }

    func refresh() async {
        guard let pipeline else { project = nil; return }
        let refreshRevision = timelineEditRevision
        let preserveVisibleTimeline = hasUnpersistedTimelineEdits || needsTimelineAIRetryAfterManualEdit
        try? await pipeline.migrateLegacyBuiltInBackgroundAssets()
        let previousMode = aiPowerMode
        let previousAdvancedSettings = advancedAISettings
        try? await pipeline.refreshMediaAvailability()
        var refreshed = await pipeline.snapshot()
        guard self.pipeline === pipeline else { return }
        if preserveVisibleTimeline || hasUnpersistedTimelineEdits || needsTimelineAIRetryAfterManualEdit || timelineEditRevision != refreshRevision,
           let visible = timeline, let index = refreshed.timelines.firstIndex(where: { $0.id == visible.id }) {
            refreshed.timelines[index] = visible
        }
        project = refreshed
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
        timelineFilmstripURLs = await pipeline.timelineFilmstripURLs()
        timelineThumbnailURLs = timelineFilmstripURLs
        await refreshMusicLibrary()
        refreshUsageStatistics()
    }

    @discardableResult
    func flushAutosave() async -> Bool {
        workspaceAutosaveTask?.cancel()
        workspaceAutosaveTask = nil
        while let pendingTimelineCommit = timelineCommitTask {
            timelineCommitTask = nil
            await pendingTimelineCommit.value
        }
        previewRebuildTask?.cancel()
        previewRebuildTask = nil
        if timelinePersistenceFailed, let pipeline, let timeline {
            do {
                _ = try await pipeline.commitLatestTimeline(timeline, clientRevision: timelineEditRevision)
                timelinePersistenceFailed = false
                hasUnpersistedTimelineEdits = false
            } catch { errorMessage = "Не удалось сохранить последнюю правку: \(error.localizedDescription)"; return false }
        }
        guard await persistWorkspaceState() else { return false }
        if let pipeline {
            do {
                let location = try await pipeline.store.verifyDurableState()
                if location == .localRecovery { status = "Правки сохранены в локальной аварийной копии" }
            } catch { errorMessage = "Не удалось подтвердить сохранение. Выберите доступное место для копии проекта."; return false }
        }
        return true
        // Every store mutation is already durable. A second save re-encodes
        // the entire archive and invalidates in-flight work for no change.
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
        intro.accept(.projectCommand)
        guard !isCreatingProject, !storageIsCleaning else { return }
        guard hasProjectWorkspace || destination == .home || destination == .settings else { return }
        cancelProjectCreation()
        if destination != .timeline { showViewer = false }
        if destination == .settings { isTimelineInspectorPresented = false }
        section = destination
        if [.media, .timeline].contains(destination), needsCacheRefreshAfterCleanup, let pipeline, !hasActiveWork {
            needsCacheRefreshAfterCleanup = false
            projectRestoreTask = Task { [weak self] in
                _ = await pipeline.generateThumbnails()
                guard !Task.isCancelled, let self, self.pipeline === pipeline else { return }
                self.thumbnailURLs = await pipeline.thumbnailURLs()
                self.timelineFilmstripURLs = await pipeline.timelineFilmstripURLs()
                self.timelineThumbnailURLs = self.timelineFilmstripURLs
            }
        }
        if destination == .timeline && previewPlayer == nil && timeline != nil && !hasActiveWork {
            previewRebuildTask?.cancel()
            previewRebuildTask = Task { [weak self] in _ = await self?.rebuildPlaybackIfPossible(show: false) }
        }
    }

    func toggleTimelineInspector() {
        isTimelineInspectorPresented.toggle()
    }

    func openTimelineInspector() {
        isTimelineInspectorPresented = selectedTitleTimelineItem != nil || selectedTimelineItem?.kind == .title
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
        directorAdviceContinuation = nil
        showsMissingMedia = false
        needsCacheRefreshAfterCleanup = false
        externalResourceWaitTask?.cancel()
        externalResourceWaitTask = nil
        recoverableFilmBuild = nil
        operationGeneration &+= 1
        activeTask?.cancel()
        activeTask = nil
        isWorking = false
        pendingTimelineAIEdits.removeAll()
        queuedTimelineAIEditCount = 0
        projectRestoreTask?.cancel()
        projectRestoreTask = nil
        workspaceAutosaveTask?.cancel()
        workspaceAutosaveTask = nil
        timelineCommitTask?.cancel()
        timelineCommitTask = nil
        hasUnpersistedTimelineEdits = false
        timelinePersistenceFailed = false
        previewRebuildTask?.cancel()
        previewRebuildTask = nil
        timelineEditRevision &+= 1
        isRestoringWorkspaceState = true
        defer { isRestoringWorkspaceState = false }
        directorTask?.cancel()
        directorTask = nil
        filmVerificationTask?.cancel()
        filmVerificationTask = nil
        filmVerificationMessage = ""
        isDirectorResponding = false
        isCreatingFilm = false
        hasPendingFilmChanges = false
        directorRevision = 0
        directorGeneration &+= 1
        queuedDirectorMessages.removeAll()
        newMaterialCount = 0
        importWarnings = []
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
        feedback = ""
        preset = .adventure
        targetMinutes = DirectorBrief.legacyDefault.requestedDuration / 60
        directorBrief = .legacyDefault
        if let playbackTimeObserver, let previewPlayer {
            previewPlayer.removeTimeObserver(playbackTimeObserver)
        }
        playbackTimeObserver = nil
        previewSeeker.reset()
        pendingPlaybackSeekTimelineTime = nil
        playbackItemStatusObservation?.invalidate()
        playbackItemStatusObservation = nil
        previewPosterTask?.cancel()
        previewPosterTask = nil
        previewPosterRequestID = nil
        previewPlayer?.pause()
        project = nil
        projectURL = nil
        videoExportDirectory = nil
        activePlayback = nil
        previewPlayer = nil
        previewURL = nil
        previewPosterImage = nil
        isPreviewPosterVisible = false
        previewPosterPlaybackID = nil
        previewPosterPlaybackTime = nil
        showViewer = false
        thumbnailURLs = [:]
        timelineThumbnailURLs = [:]
        timelineFilmstripURLs = [:]
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
        clearActivityETA()
        isActivityPanelVisible = false
        isActivityComplete = false
    }

    private static func restoredDirectorBrief(
        workspaceState: ProjectWorkspaceState?,
        storyPlan: StoryPlan?,
        timeline: Timeline?
    ) -> DirectorBrief {
        if let brief = workspaceState?.directorBrief { return brief }
        if let brief = storyPlan?.directorBrief { return brief }

        var brief = DirectorBrief.legacyDefault
        let inferredDuration = workspaceState.map { $0.targetMinutes * 60 }
            ?? storyPlan?.constraints.targetDuration
            ?? timeline?.duration
            ?? brief.requestedDuration
        brief.requestedDuration = min(3_600, AutomaticFilmDurationPolicy.normalizedRequest(inferredDuration))

        if let timeline {
            brief.canvasFormat = timeline.height > timeline.width ? .portrait9x16 : .landscape16x9
            if let savedTrackID = workspaceState?.directorMusicTrackID {
                brief.musicPolicy = .specificTrack
                brief.musicTrackID = savedTrackID
            } else {
                brief.musicPolicy = timeline.music == nil ? .none : .matchVideo
                brief.musicTrackID = nil
            }

            let sourceVolume = timeline.effectiveOriginalAudioVolume
            if sourceVolume < 0.01 {
                brief.sourceAudioPolicy = .mute
            } else if sourceVolume < 0.75 {
                brief.sourceAudioPolicy = .duck
            } else {
                brief.sourceAudioPolicy = .preserve
            }

            let hasTitles = timeline.items.contains { $0.kind == .title } ||
                !timeline.effectiveTitleItems.isEmpty
            brief.titlePolicy = hasTitles ? .minimal : .none
        } else if let savedTrackID = workspaceState?.directorMusicTrackID {
            brief.musicPolicy = .specificTrack
            brief.musicTrackID = savedTrackID
        }

        if let pacing = storyPlan?.constraints.pacing {
            if pacing < 0.42 { brief.mood = .calm }
            else if pacing > 0.70 { brief.mood = .dynamic }
            else { brief.mood = .cinematic }
        }
        return brief
    }

    private func prepareOpenedProject() {
        guard let pipeline, project != nil else { return }
        isRestoringWorkspaceState = true
        if let saved = project?.workspaceState {
            newMaterialCount = max(0, saved.pendingNewMaterialCount ?? 0)
            prompt = saved.prompt
            directorInput = saved.directorDraft
            directorMessages = saved.directorMessages.map { messages in
                messages.map { saved in
                    var message = DirectorMessage(projectMessage: saved)
                    if message.role == .assistant,
                       message.text.hasPrefix("Не удалось закончить монтаж:") || message.text.hasPrefix("Монтаж не сохранён:") {
                        if let root = self.projectURL {
                            let logs = root.appendingPathComponent("Logs")
                            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                            try? Data(message.text.utf8).write(to: logs.appendingPathComponent("legacy-\(message.id).txt"), options: .atomic)
                        }
                        message.text = "Предыдущая сборка была прервана. Описание фильма сохранено."
                    }
                    return message
                }
            } ?? DirectorMessage.initial
            feedback = saved.feedbackDraft
            preset = saved.preset
            directorBrief = Self.restoredDirectorBrief(
                workspaceState: saved,
                storyPlan: project?.storyPlans.last,
                timeline: timeline
            )
            targetMinutes = directorBrief.requestedDuration / 60
            directorMusicTrackID = directorBrief.musicPolicy == .specificTrack
                ? directorBrief.musicTrackID
                : nil
            pendingDirectorInstructions = saved.pendingDirectorInstructions
            pendingDirectorCommandGroups = Array(repeating: [], count: saved.pendingDirectorInstructions.count)
            hasPendingFilmChanges = saved.hasPendingFilmChanges
            directorRevision = saved.pendingDirectorInstructions.count
        } else if let plan = project?.storyPlans.last {
            prompt = plan.prompt
            directorInput = ""
            preset = plan.preset
            directorBrief = Self.restoredDirectorBrief(
                workspaceState: nil,
                storyPlan: plan,
                timeline: timeline
            )
            targetMinutes = directorBrief.requestedDuration / 60
            directorMusicTrackID = directorBrief.musicPolicy == .specificTrack
                ? directorBrief.musicTrackID
                : nil
            hasPendingFilmChanges = false
            pendingDirectorInstructions = []
            pendingDirectorCommandGroups = []
        } else if let timeline {
            directorBrief = Self.restoredDirectorBrief(
                workspaceState: nil,
                storyPlan: nil,
                timeline: timeline
            )
            targetMinutes = directorBrief.requestedDuration / 60
            directorMusicTrackID = directorBrief.musicPolicy == .specificTrack
                ? directorBrief.musicTrackID
                : nil
        }
        directorAgent.restoreConversation(directorMessages)
        undoTimelineHistory = (project?.timelineCheckpoints ?? [])
            .suffix(40)
            .map(\.timeline)
            .filter { $0 != timeline }
        redoTimelineHistory = []
        updateTimelineHistoryAvailability()
        isRestoringWorkspaceState = false
        let job = project?.autonomousJob
        if job?.state == .waitingForExternalResource {
            status = job?.externalResource ?? "Ожидаю материалы"
            waitForExternalResources()
            return
        }
        if recoverableFilmBuild != nil,
           job?.explicitCancellation != true,
           job?.state.resumesAutomatically ?? (project?.intentLedger?.entries.last?.status != .cancelled) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pipeline === pipeline else { return }
                self.resumeInterruptedFilmBuild()
            }
            return
        }
        if job?.kind == .export, job?.state.resumesAutomatically == true, job?.explicitCancellation != true {
            run("Сохраняю видео") {
                if let report = try await pipeline.resumeExport() {
                    await self.refresh()
                    self.status = "Видео сохранено: \(report.outputURL.lastPathComponent)"
                }
            }
            return
        }
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
                try await pipeline.refreshMediaAvailability()
                guard !Task.isCancelled, self.pipeline === pipeline else { return }
                await self.refresh()
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

                if shouldPreparePlayback {
                    let restoreRevision = self.timelineEditRevision
                    let playback = try await pipeline.makePlayback(interactiveQuality: Self.interactivePreviewQuality)
                    guard !Task.isCancelled, self.pipeline === pipeline else { return }
                    if self.timelineEditRevision == restoreRevision {
                        self.setPlayback(playback, show: false, autoplay: false)
                    }
                    restoreWarning = restoreWarning ?? playback.warnings.first
                }

                // Media generation is useful but not part of opening a project.
                // Run it only after the editor and preview are already usable.
                _ = await pipeline.generateThumbnails()
                async let thumbnails = pipeline.thumbnailURLs()
                async let timelineFilmstrips = pipeline.timelineFilmstripURLs()
                let cachedImages = await (thumbnails, timelineFilmstrips)
                guard !Task.isCancelled, self.pipeline === pipeline else { return }
                self.thumbnailURLs = cachedImages.0
                self.timelineFilmstripURLs = cachedImages.1
                self.timelineThumbnailURLs = cachedImages.1
                await self.refreshMusicLibrary()

                if let restoreWarning {
                    self.status = restoreWarning
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
        previewSeeker.reset()
        pendingPlaybackSeekTimelineTime = nil
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
        previewPlayerFrameReady = false
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
                guard let self, self.previewPlayer === player, player.currentItem === playerItem,
                      let map = self.playbackMap else { return }
                if self.previewSeeker.isSeeking { return }
                if self.isPreviewPosterVisible, player.timeControlStatus == .playing {
                    self.isPreviewPosterVisible = false
                }
                if let pendingTime = self.pendingPlaybackSeekTimelineTime {
                    self.timelinePlayheadTime = min(map.duration, pendingTime)
                    return
                }
                // A paused decoder can report an older/tolerant frame after
                // the latest seek completed. The editor owns the paused clock.
                guard Self.isActivelyPlaying(player) else { return }
                self.timelinePlayheadTime = min(
                    map.duration,
                    map.timelineTime(forPlaybackTime: value.seconds)
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
                TimelineTiming.playbackTime(forTimelineTime: restoredTimelineTime, timeline: timeline),
                duration: playback.duration,
                frameRate: timeline.frameRate
            )
        } else {
            requestedPlaybackTime = min(
                max(0, playback.duration - 0.001),
                1 / max(15, frameRate)
            )
        }

        // Keep a fallback frame while the replacement item loads. Once a seek
        // succeeds, AVPlayer owns both paused and playing presentation: swapping
        // to an NSImage after scrubbing can change HDR tone mapping/brightness.
        preparePreviewPoster(
            for: playback,
            playerItem: playerItem,
            at: requestedPlaybackTime
        )

        let installedSeekRevision = previewSeekRevision
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

                guard self.previewSeekRevision == installedSeekRevision, !self.previewSeeker.isSeeking else { return }
                let shouldPlay = autoplay || Self.isActivelyPlaying(player)
                let target = CMTime(seconds: requestedPlaybackTime, preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak playerItem] finished in
                    Task { @MainActor [weak self, weak playerItem] in
                        guard let self,
                              let playerItem,
                              self.previewPlayer === player,
                              player.currentItem === playerItem,
                              self.previewSeekRevision == installedSeekRevision,
                              !self.previewSeeker.isSeeking else { return }
                        if let restoredTimelineTime {
                            self.pendingPlaybackSeekTimelineTime = nil
                            self.timelinePlayheadTime = restoredTimelineTime
                        }
                        if finished { self.showReadyPreviewPlayerFrame() }
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
        let requestID = UUID()
        previewPosterRequestID = requestID
        let safeTime = min(max(0, playbackTime), max(0, playback.duration - 0.001))
        let videoComposition = playerItem.videoComposition

        previewPosterTask = Task.detached(priority: .userInitiated) { [weak self, weak playerItem] in
            // Collapse rapid timeline scrubbing into the final requested frame.
            try? await Task.sleep(nanoseconds: 35_000_000)
            guard !Task.isCancelled else { return }

            let generator = AVAssetImageGenerator(asset: playback.composition)
            generator.appliesPreferredTrackTransform = true
            let previewLongEdge = CGFloat(AppModel.interactivePreviewLongEdge)
            generator.maximumSize = CGSize(width: previewLongEdge, height: previewLongEdge)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.videoComposition = videoComposition

            // Black is a valid edited frame (opacity, fades, black backgrounds).
            // Substituting a brighter neighbor hides precisely those edits and
            // can move a short effect outside the paused preview altogether.
            let generatedFrame = try? await withTaskCancellationHandler {
                try await generator.image(at: CMTime(seconds: safeTime, preferredTimescale: 600))
            } onCancel: {
                generator.cancelAllCGImageGeneration()
            }
            let generatedImage = generatedFrame?.image
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self, weak playerItem] in
                guard let self,
                      let playerItem,
                      self.previewPosterRequestID == requestID,
                      self.activePlayback === playback,
                      self.previewPlayer?.currentItem === playerItem else { return }
                guard let generatedImage else {
                    if !self.previewPosterMatches(
                        playback,
                        playbackTime: safeTime,
                        frameRate: self.timeline?.frameRate ?? 30
                    ) {
                        self.isPreviewPosterVisible = false
                    }
                    return
                }
                self.previewPosterImage = NSImage(cgImage: generatedImage, size: .zero)
                self.previewPosterPlaybackID = ObjectIdentifier(playback)
                self.previewPosterPlaybackTime = safeTime
                self.isPreviewPosterVisible = !self.previewPlayerFrameReady && self.previewPlayer?.timeControlStatus != .playing
                if self.isPreviewPosterVisible { self.recordPreviewFramePublished() }
            }
        }
    }

    private func showReadyPreviewPlayerFrame() {
        previewPlayerFrameReady = true
        if isPreviewPosterVisible { isPreviewPosterVisible = false }
        recordPreviewFramePublished()
    }

    private func recordPreviewFramePublished() {
        guard previewEditRevision == timelineEditRevision, let started = previewEditStarted else { return }
        let latency = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        previewEditTrace?.event("edit.preview.pixels-published", values: ["milliseconds": latency])
        let sample = InteractionLatencySample(name: "paused composition frame",
            stateUpdateMilliseconds: previewStateLatency ?? 0, visualFeedbackMilliseconds: latency)
        Task { await interactionLatencyRecorder.record(sample) }
        previewEditStarted = nil
    }

    private func hidePreviewPosterIfStale(
        for playback: TimelinePlayback,
        playbackTime: Double,
        frameRate: Double
    ) {
        guard isPreviewPosterVisible, !previewPosterMatches(
            playback,
            playbackTime: playbackTime,
            frameRate: frameRate
        ) else { return }
        isPreviewPosterVisible = false
    }

    private func previewPosterMatches(
        _ playback: TimelinePlayback,
        playbackTime: Double,
        frameRate: Double
    ) -> Bool {
        guard previewPosterImage != nil,
              previewPosterPlaybackID == ObjectIdentifier(playback),
              let previewPosterPlaybackTime else { return false }
        let tolerance = max(1.0 / max(15, frameRate), 1.0 / 120.0)
        return abs(previewPosterPlaybackTime - playbackTime) <= tolerance
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
        checkpointReason: String? = nil,
        preferenceSource: PreferenceSignalSource = .manualEdit,
        didApply: (() -> Void)? = nil,
        mutation: (inout Timeline) -> Bool
    ) {
        let interactionStarted = ProcessInfo.processInfo.systemUptime
        guard !isTimelineInteractionBlocked, let pipeline, var manifest = project,
              let timelineIndex = manifest.timelines.indices.last else { return }
        let previous = manifest.timelines[timelineIndex]
        var next = previous
        guard mutation(&next), next != previous else { return }
        next = TimelineFrameRatePolicy.applying(to: next, assets: manifest.assets)

        manifest.timelines[timelineIndex] = next
        project = manifest
        hasUnpersistedTimelineEdits = true
        timelinePlayheadTime = min(max(0, timelinePlayheadTime), next.duration)
        if isWorking, activityPresentation == .editorAI {
            // The in-flight AI result was planned against an older snapshot.
            // Let it finish, keep this manual edit authoritative, then rebase
            // the AI request once onto the newest timeline.
            needsTimelineAIRetryAfterManualEdit = true
        }
        didApply?()
        if let title = selectedTitleTimelineItem,
           previous.effectiveTitleItems.first(where: { $0.id == title.id }) != title {
            revealTitleForEditing(title)
        }
        let stateLatency = (ProcessInfo.processInfo.systemUptime - interactionStarted) * 1_000
        let interactionTrace = PerformanceTrace(name: "edit.manual", projectID: manifest.id, revision: String(timelineEditRevision + 1))
        interactionTrace.event("edit.state.applied", values: ["milliseconds": stateLatency])
        previewEditTrace = interactionTrace
        previewEditStarted = interactionStarted
        previewStateLatency = stateLatency
        filmVerificationTask?.cancel()
        filmVerificationMessage = ""
        if recordHistory { recordTimelineChange(from: previous) }
        status = initialStatus
        hasPendingFilmChanges = true

        timelineEditRevision &+= 1
        let revision = timelineEditRevision
        previewEditRevision = revision
        let shouldResumePlayback = previewPlayer.map(Self.isActivelyPlaying) ?? false

        timelineCommitTask?.cancel()
        timelineCommitTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
                try Task.checkCancellation()
                let committed = try await pipeline.commitLatestTimeline(next, clientRevision: revision, checkpointReason: checkpointReason)
                guard committed, !Task.isCancelled else { return }
                _ = try? await pipeline.recordPreferenceSignals(before: previous, after: next, source: preferenceSource)
                guard let self, self.pipeline === pipeline, self.timelineEditRevision == revision else { return }
                self.timelinePersistenceFailed = false
                self.hasUnpersistedTimelineEdits = false
                interactionTrace.event("edit.saved")
                self.status = await pipeline.store.persistenceLocation == .localRecovery ? "Правка сохранена в локальной аварийной копии" : "Правка сохранена · проверяется"
                self.scheduleFilmVerification()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.pipeline === pipeline, self.timelineEditRevision == revision else { return }
                self.timelinePersistenceFailed = true
                self.errorMessage = "Изменение видно в редакторе, но не сохранено: \(error.localizedDescription)"
            }
        }

        previewRebuildTask?.cancel()
        if next.items.isEmpty {
            clearTimelinePlayback()
            previewRebuildTask = nil
            return
        }
        let invalidation = TimelineInvalidationPlanner.plan(from: previous, to: next)
        let previewDebounceNanoseconds: UInt64 = invalidation.requiresCompositionRebuild ? 35_000_000 : 16_000_000
        previewRebuildTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: previewDebounceNanoseconds)
                try Task.checkCancellation()
                let playback = try await pipeline.makePlayback(timeline: next, projectSnapshot: manifest, interactiveQuality: Self.interactivePreviewQuality)
                try Task.checkCancellation()
                guard let self, self.pipeline === pipeline, self.timelineEditRevision == revision else { return }
                self.setPlayback(
                    playback,
                    show: false,
                    autoplay: shouldResumePlayback,
                    restoringTimelineTime: self.timelinePlayheadTime
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
        canUndoTimelineEdit = !undoTimelineHistory.isEmpty || (project?.removedMedia?.last.map { $0.afterTimelines == project?.timelines } ?? false)
        canRedoTimelineEdit = !redoTimelineHistory.isEmpty
    }

    private func clearTimelinePlayback() {
        if let playbackTimeObserver, let previewPlayer {
            previewPlayer.removeTimeObserver(playbackTimeObserver)
        }
        playbackTimeObserver = nil
        previewSeeker.reset()
        pendingPlaybackSeekTimelineTime = nil
        playbackItemStatusObservation?.invalidate()
        playbackItemStatusObservation = nil
        previewPosterTask?.cancel()
        previewPosterTask = nil
        previewPosterRequestID = nil
        previewPlayer?.pause()
        previewPlayer = nil
        activePlayback = nil
        previewPosterImage = nil
        isPreviewPosterVisible = false
        previewPosterPlaybackID = nil
        previewPosterPlaybackTime = nil
        showViewer = false
    }

    @discardableResult
    private func rebuildPlaybackIfPossible(
        show: Bool,
        restoringTimelineTime requestedTimelineTime: Double? = nil,
        resumePlayback requestedResumePlayback: Bool? = nil
    ) async -> Bool {
        guard let pipeline, timeline?.items.contains(where: { $0.kind != .title }) == true else {
            clearTimelinePlayback()
            return timeline?.items.isEmpty == true
        }
        let rebuildRevision = timelineEditRevision
        let visibleTimeline = timeline
        let visibleProject = project
        let timelineTime = requestedTimelineTime ?? timelinePlayheadTime
        let resumePlayback = requestedResumePlayback
            ?? previewPlayer.map(Self.isActivelyPlaying)
            ?? false
        // Freeze the old frame while the new composition is assembled. This
        // prevents the old cut from running ahead and then visibly jumping
        // backwards when the edited frame is restored.
        previewPlayer?.pause()
        do {
            let playback = try await pipeline.makePlayback(timeline: visibleTimeline, projectSnapshot: visibleProject, interactiveQuality: Self.interactivePreviewQuality)
            guard self.pipeline === pipeline, timelineEditRevision == rebuildRevision else { return false }
            setPlayback(
                playback,
                show: show,
                autoplay: show || resumePlayback,
                restoringTimelineTime: timelineTime
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
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
                directorBrief.requestedDuration = interpreted.targetDuration
                directorBrief.durationMode = FilmDurationRequirement.parse(prompt: text).mode
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
        directorAgent.restoreConversation(directorMessages)
        if mode == .advisory {
            directorRuntimeStatus = reply.runtimeLabel
            directorStatus = "Совет готов · исходник и Timeline не изменены"
            scheduleWorkspaceAutosave()
            return
        }
        let pendingIndex = pendingDirectorInstructions.lastIndex(of: sourceText)
        // A model paraphrase is displayed in the reply, never appended as a
        // later user instruction: that would override the original brief.
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

    private func revisionFeedback(instructions: [String], preset: FilmPreset, targetDuration: Double?) -> String {
        var parts = instructions
        parts.append("Выбранный стиль: \(preset.localizedTitle).")
        if let targetDuration { parts.append("Целевая длительность: \(Self.durationText(targetDuration)).") }
        return parts.joined(separator: "\n")
    }

    private static func resolvedEditorCommands(
        instructions: [String],
        commandGroups: [[EditorCommand]],
        fallbackPrompt: String,
        preset: FilmPreset
    ) -> [EditorCommand] {
        guard !instructions.isEmpty else {
            // TimelineComposer has already resolved the soundtrack and any
            // explicitly requested telemetry accent from the full brief.
            // Applying those commands a second time could switch music back
            // to an old track or cover every clip with a duplicate full HUD.
            return EditorCommandParser().parse(fallbackPrompt, preset: preset).filter {
                $0.semanticCategory != "music" && $0.semanticCategory != "telemetry"
            }
        }
        let resolved = instructions.indices.flatMap { index in
            let deterministic = EditorCommandParser().parse(instructions[index], preset: preset)
            guard commandGroups.indices.contains(index), !commandGroups[index].isEmpty else {
                return deterministic
            }
            let structured = commandGroups[index]
            let deterministicCategories = Set(deterministic.map(\.semanticCategory))
            return DirectorRequestContract.authorizedCommands(deterministic + structured.filter {
                !deterministicCategories.contains($0.semanticCategory)
            }, prompt: instructions[index], preset: preset)
        }
        var seen = Set<EditorCommand>()
        return resolved.filter { seen.insert($0).inserted }
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
            pendingDirectorInstructions = project?.intentLedger?.unfulfilledInstructions ?? []
            pendingDirectorCommandGroups = Array(repeating: [], count: pendingDirectorInstructions.count)
            hasPendingFilmChanges = !pendingDirectorInstructions.isEmpty
        } else {
            let consumed = min(consumedInstructionCount, pendingDirectorInstructions.count)
            if consumed > 0 {
                pendingDirectorInstructions.removeFirst(consumed)
                pendingDirectorCommandGroups.removeFirst(min(consumed, pendingDirectorCommandGroups.count))
            }
            hasPendingFilmChanges = true
        }

        if !pendingDirectorInstructions.isEmpty {
            appendDirectorNote("Остались невыполненные инструкции: \(pendingDirectorInstructions.joined(separator: "; "))")
        }
        if let report = timeline.filmDeliveryReport, report.isCurrent(for: timeline), !report.warnings.isEmpty {
            appendDirectorNote(report.completionMessage + ".")
        }
        if usesCompactConfirmation {
            appendDirectorNote("Фильм пересобран")
        } else {
            appendDirectorNote(Self.filmRevisionSummary(previous: previousTimeline, current: timeline))
            if let commandReport {
                appendDirectorNote(commandReport.chatSummary)
            }
        }
        let frameTolerance = 1 / max(1, timeline.frameRate)
        if directorBrief.explicitRequestedDuration != nil, timeline.duration + frameTolerance < directorBrief.requestedDuration {
            appendDirectorNote(
                "Запрошено \(Self.durationText(directorBrief.requestedDuration)), "
                    + "режиссёр отобрал \(Self.durationText(timeline.duration)). "
                    + "Требование к длительности не выполнено. Сохранена короткая версия; это не означает, что в исходниках больше нет подходящего материала."
            )
        }
        directorStatus = hasPendingFilmChanges
            ? "Фильм сохранён; есть неприменённые правки"
            : timeline.filmDeliveryReport?.completionMessage ?? "Фильм сохранён и доступен для просмотра"
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

    @discardableResult
    private func persistWorkspaceState() async -> Bool {
        guard !isRestoringWorkspaceState, let pipeline, project != nil else { return true }
        var state = ProjectWorkspaceState(
            prompt: prompt,
            preset: preset,
            targetMinutes: targetMinutes,
            directorMusicTrackID: directorMusicTrackID,
            directorBrief: directorBrief,
            directorDraft: directorInput,
            feedbackDraft: feedback,
            pendingDirectorInstructions: pendingDirectorInstructions,
            hasPendingFilmChanges: hasPendingFilmChanges,
            directorMessages: directorMessages
                .filter { !$0.text.isEmpty }
                .map { ProjectDirectorMessage(directorMessage: $0) }
        )
        state.pendingNewMaterialCount = newMaterialCount > 0 ? newMaterialCount : nil
        do {
            try await pipeline.updateWorkspaceState(state)
            return true
        } catch {
            errorMessage = "Не удалось автоматически сохранить проект: \(error.localizedDescription)"
            return false
        }
    }

    private static func filmRevisionSummary(previous: Timeline?, current: Timeline) -> String {
        guard let previous else {
            let result = current.filmDeliveryReport.map { $0.isCurrent(for: current) ? $0.completionMessage : "Фильм сохранён" } ?? "Фильм сохранён"
            return "\(result). Собрал \(current.items.count) фрагментов на \(durationText(AutomaticFilmDurationPolicy.renderedDuration(of: current))). Timeline и просмотр обновлены."
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

    private func beginTimelineDirectorExchange(_ text: String, range: ClosedRange<Double>?) -> UUID {
        directorMessages.append(DirectorMessage(role: .user, text: text))
        let source = range.map { "Волшебная кисть · \(Self.clockText($0.lowerBound))–\(Self.clockText($0.upperBound))" } ?? "Монтаж"
        let replyID = UUID()
        directorMessages.append(DirectorMessage(id: replyID, role: .assistant, text: "\(source)\nПравка принята в очередь"))
        return replyID
    }

    private func updateTimelineDirectorExchange(_ replyID: UUID, status: String) {
        guard let index = directorMessages.firstIndex(where: { $0.id == replyID }) else { return }
        directorMessages[index].text = status
        directorStatus = status
        activeTimelineAIEdit?.trace?.event("director.full-displayed", fields: ["state": directorMessages[index].response?.state.rawValue ?? "status"])
        directorAgent.restoreConversation(directorMessages)
    }

    /// All three composers route discussion here before touching a brief, queue
    /// or editing transaction. Every await consumes one send-to-display budget.
    private func submitDirectorAdvice(_ text: String, range: ClosedRange<Double>? = nil) {
        // A question does not cancel an already authorized film-building task.
        // Timeline editing owns a separate ordered operation; this guard is
        // for the initial director task before a movie exists.
        if isDirectorResponding, directorAdviceReplyID == nil, directorTask != nil {
            directorMessages.append(DirectorMessage(role: .user, text: text))
            var reply = DirectorMessage(role: .assistant,
                text: "Режиссёр ещё обрабатывает предыдущую задачу. Для оценки готового момента пока недостаточно данных.")
            reply.response = .init(state: .proposed, projectID: project?.id, revision: directorContextRevision,
                advisory: true, fallback: true)
            directorMessages.append(reply)
            scheduleWorkspaceAutosave()
            return
        }
        if ["да, сделай", "да сделай", "давай так", "сделай так", "примени совет"].contains(text.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            if let proposal = directorMessages.last(where: { $0.role == .assistant })?.response?.proposal,
               let project, proposal.isApplicable(to: project, selectedID: selectedTimelineItemID), range == nil {
                submitTimelineAIEdit("Установи длительность выбранного клипа \(String(format: "%.6f", proposal.duration)) секунд", proposal: proposal)
                return
            }
        }
        let submittedAt = ProcessInfo.processInfo.systemUptime
        let followsPrevious = ["продолжи ожидание", "подожди", "подробнее", "объясни подробнее"].contains(
            text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
        let continuation = followsPrevious ? directorAdviceContinuation.flatMap {
            $0.projectID == project?.id && $0.revision == directorContextRevision ? $0 : nil
        } : nil
        let requestPrompt = continuation.map { $0.prompt + "\nПользователь просит: " + text } ?? text
        let capturedRange = followsPrevious ? continuation?.range : range
        if !followsPrevious { directorAdviceContinuation = nil }
        let projectID = project?.id
        let revision = directorContextRevision
        let selection = selectedTimelineItemID
        let playhead = timelinePlayheadTime
        let snapshot = project
        let indexTask = directorMomentIndexTask
        let capturedPreset = preset
        let capturedDuration = targetMinutes * 60
        let trace = PerformanceTrace(name: "director.advice", projectID: projectID, revision: String(revision))
        trace.event("director.submitted")
        if let previous = directorAdviceReplyID,
           let i = directorMessages.firstIndex(where: { $0.id == previous }), directorMessages[i].text.isEmpty {
            directorMessages[i].text = "Ожидание отменено новым вопросом."
            directorMessages[i].response = .init(state: .cancelled, projectID: projectID, advisory: true)
        }
        directorTask?.cancel()
        directorGeneration &+= 1
        let generation = directorGeneration
        let replyID = UUID()
        directorAdviceReplyID = replyID
        directorMessages.append(DirectorMessage(role: .user, text: text))
        directorMessages.append(DirectorMessage(id: replyID, role: .assistant, text: ""))
        directorStatus = "Обдумываю момент · совет"
        isDirectorResponding = true
        trace.event("director.ui-accepted")
        let knownReply: String? = {
            if followsPrevious, continuation == nil {
                return "Нет актуального вопроса для продолжения. Повторите вопрос о нужном фрагменте."
            }
            if let reason = DirectorResponseComposer.recordedDurationReason(prompt: text,
                reasons: snapshot?.timelines.last?.directorRun?.decisionReasons ?? []) { return reason }
            let query = text.lowercased()
            if ["какая громкость", "громкость музыки?", "какой уровень музыки"].contains(where: query.contains) {
                guard let music = snapshot?.timelines.last?.music else { return "В этом монтаже музыка не выбрана." }
                return "Громкость музыки — \(String(format: "%g", music.volume * 100))%."
            }
            if ["готово", "сделано", "ты закончил"].contains(query.trimmingCharacters(in: .punctuationCharacters)) {
                if isWorking { return "Операция ещё выполняется." }
                if let response = directorMessages.dropLast(2).reversed().compactMap(\.response).first(where: { !$0.advisory }) {
                    if response.saved { return response.previewReady ? "Правка сохранена, просмотр готов." : "Правка сохранена. Просмотр пока не обновлён." }
                    return "Подтверждённой сохранённой правки пока нет."
                }
                return "В истории нет подтверждения выполненной правки."
            }
            if ["да, сделай", "да сделай", "давай так", "сделай так", "примени совет"].contains(where: query.contains) {
                return "Уточните, какую правку применить и к какому клипу: в последнем совете нет однозначного исполняемого предложения."
            }
            if query.contains("проанализируй") {
                return "Отдельный анализ этого диапазона пока недоступен. Анализ исходников можно запустить в медиатеке."
            }
            return nil
        }()
        directorTask = Task {
            await PerformanceTrace.$current.withValue(trace) {
                var moment = continuation?.context.moment
                let fallback = DirectorAIReply(text: "Не успел подготовить оценку за отведённое время. Можно попросить продолжить ожидание.", runtimeLabel: "Ограниченный ответ", normalizedBrief: nil, isFallback: true)
                let detailed = ["подробнее", "подробно", "подробный", "продолжи ожидание", "подожди"].contains(where: text.lowercased().contains)
                let reply: DirectorAIReply
                if let knownReply {
                    reply = DirectorAIReply(text: knownReply, runtimeLabel: "Данные проекта", normalizedBrief: nil)
                } else {
                    reply = await DirectorReplyDeadline.run(seconds: detailed ? 30 : 6, fallback: fallback) {
                        let index = await indexTask?.value
                        guard !Task.isCancelled else { return fallback }
                        moment = continuation?.context.moment ?? index?.resolve(prompt: text, selectedID: selection, playhead: playhead, range: capturedRange)
                        trace.event("director.context-ready", values: ["cacheBytes": Double(index?.estimatedBytes ?? 0)])
                        let context = continuation?.context ?? DirectorContext(assetCount: snapshot?.assets.count ?? 0, videoCount: 0, photoCount: 0,
                            analyzedCount: 0, candidateCount: 0, currentTimelineItemCount: snapshot?.timelines.last?.items.count ?? 0,
                            currentMusicTrackTitle: snapshot?.timelines.last?.music?.trackTitle,
                            targetDuration: capturedDuration, preset: capturedPreset, currentOperation: "Совет",
                            selectedItemSummary: moment?.targetID, playheadTime: playhead, moment: moment,
                            musicVolume: snapshot?.timelines.last?.music?.volume)
                        if self.directorGeneration == generation, self.project?.id == projectID,
                           self.directorContextRevision == revision {
                            self.directorAdviceContinuation = AdviceContinuation(prompt: continuation?.prompt ?? text,
                                context: context, range: capturedRange, projectID: projectID, revision: revision)
                        }
                        return await self.directorAgent.respond(to: requestPrompt, context: context, mode: .advisory,
                            recordInHistory: false, submittedAt: submittedAt)
                    }
                }
                guard !Task.isCancelled, self.directorGeneration == generation, self.project?.id == projectID,
                      let i = self.directorMessages.firstIndex(where: { $0.id == replyID }) else {
                    trace.finish(status: "cancelled")
                    if self.directorGeneration == generation {
                        self.isDirectorResponding = false; self.directorTask = nil
                    }
                    return
                }
                self.directorMessages[i].text = reply.text
                self.directorMessages[i].response = .init(state: .proposed, projectID: projectID, revision: revision,
                    itemIDs: moment?.objects.map(\.itemID) ?? [], advisory: true, fallback: reply.isFallback,
                    details: (moment?.limitations ?? []) + (moment?.objects.flatMap(\.limitations) ?? []))
                self.directorMessages[i].response?.range = capturedRange ?? (moment?.objects.count == 1 ? moment?.objects.first?.filmRange : nil)
                if capturedRange == nil, let snapshot, let objects = moment?.objects, objects.count == 1, let object = objects.first,
                   (reply.judgment?.stance == .keep || reply.isFallback),
                   reply.text.contains("слово целиком"),
                   let proposal = DirectorEditProposal.completingCutWord(project: snapshot, targetID: object.itemID) {
                    self.directorMessages[i].response?.proposal = proposal
                }
                self.directorAgent.restoreConversation(self.directorMessages)
                self.directorRuntimeStatus = reply.runtimeLabel
                self.directorStatus = reply.isFallback ? "Совет · ограниченные данные" : "Совет"
                trace.event("director.first-displayed", fields: ["result": reply.isFallback ? "fallback" : "answer"])
                trace.event("director.full-displayed")
                trace.finish(status: reply.isFallback ? "fallback" : "success")
                self.isDirectorResponding = false
                self.directorTask = nil
                self.directorAdviceReplyID = nil
                self.scheduleWorkspaceAutosave()
                if !self.queuedDirectorMessages.isEmpty {
                    let draft = self.directorInput
                    self.directorInput = self.queuedDirectorMessages.removeFirst()
                    self.sendDirectorMessage()
                    self.directorInput = draft
                } else { self.startNextQueuedTimelineAIEdit() }
            }
        }
    }

    private func setDirectorResponseRecord(_ id: UUID, receipt: DirectorExecutionReceipt) {
        guard let i = directorMessages.firstIndex(where: { $0.id == id }) else { return }
        directorMessages[i].response = .init(state: receipt.state, projectID: project?.id, revision: directorContextRevision,
            itemIDs: activeTimelineAIEdit?.selectedItemID.map { [$0] } ?? [], saved: receipt.saved,
            previewReady: receipt.previewReady, details: receipt.applied + receipt.omitted + (receipt.failure.map { [$0] } ?? []))
        directorMessages[i].response?.range = activeTimelineAIEdit?.range
    }

    private func directorContext(selection: (id: UUID?, playhead: Double)? = nil) -> DirectorContext {
        let assets = project?.assets ?? []
        let analyses = project?.analyses ?? []
        let currentAnalyses = analyses.filter { analysis in
            assets.contains { asset in
                analysis.assetID == asset.id &&
                analysis.analyzedContentHash == asset.contentHash &&
                analysis.schemaVersion == project?.analysisSchemaVersion &&
                analysis.deepMediaVersion == DeepAnalysisCache.version
            }
        }
        let currentTimeline = timeline
        let selectedID = selection.map { $0.id } ?? selectedTimelineItemID
        let selectedIndex = selectedID.flatMap { id in currentTimeline?.items.firstIndex(where: { $0.id == id }) }
        let selectedSummary = selectedIndex.flatMap { index -> String? in
            guard let item = currentTimeline?.items[index] else { return nil }
            return "\(item.storyRole?.localizedTitle ?? item.kind.rawValue), \(Self.durationText(item.timelineDuration)), источник \(item.assetID?.uuidString.prefix(8) ?? "нет")"
        } ?? currentTimeline?.effectiveTitleItems.first(where: { $0.id == selectedID }).map { "Титр «\($0.text)», \(Self.clockText($0.startTime))" }
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
            playheadTime: currentTimeline == nil ? nil : (selection?.playhead ?? timelinePlayheadTime),
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
        guard isWorking else { return }
        activityUnmeasuredStartedAt = nil
        activityFilmBuildStage = nil
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
        let stage = "\(base)|\(span)|\(phase ?? "")"
        if let previousStage = activityProgressStage, previousStage != stage {
            clearActivityETA(preservingFilmEstimate: true)
        }
        activityProgressStage = stage
        let measured = activityProgressEstimate.observe(
            stage: stage, fraction: localProgress, now: ProcessInfo.processInfo.systemUptime
        )
        if filmBuildTimeEstimate != nil {
            filmBuildTimeEstimate?.observe(
                step: showsAnalysisFileProgress ? .analysis : .playback,
                fraction: localProgress, total: item.total,
                secondsRemaining: item.estimatedSecondsRemaining,
                now: ProcessInfo.processInfo.systemUptime
            )
            refreshFilmBuildETA()
        } else if localProgress >= 1 {
            clearActivityETA()
        } else if let eta = item.estimatedSecondsRemaining {
            if eta.isFinite, eta > 0 {
                setActivityETA(eta)
            } else {
                clearActivityETA()
                activityTimeRemaining = ActivityTimeEstimate.label(secondsRemaining: 0)
            }
        } else if !showsAnalysisFileProgress, let measured {
            setActivityETA(measured)
        }
        let detail = progressLabel.isEmpty ? item.currentName : "\(item.currentName) · \(progressLabel)"
        status = phase.map { "\($0): \(detail)" } ?? detail
    }

    private func setActivityETA(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else {
            clearActivityETA()
            return
        }
        activityEstimatedCompletionUptime = ProcessInfo.processInfo.systemUptime + seconds
        activityTimeRemaining = ActivityTimeEstimate.label(secondsRemaining: seconds, wholeFilm: filmBuildTimeEstimate != nil)
        guard activityETATask == nil else { return }
        activityETATask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                guard self.isWorking, let completion = self.activityEstimatedCompletionUptime else {
                    self.activityETATask = nil
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                let remaining = self.filmBuildTimeEstimate?.remaining(now: now) ?? (completion - now)
                self.activityTimeRemaining = self.filmBuildTimeEstimate?.hasMeasuredPace == false
                    ? "Уточняю время…"
                    : ActivityTimeEstimate.label(secondsRemaining: remaining, wholeFilm: self.filmBuildTimeEstimate != nil)
            }
        }
    }

    private func refreshFilmBuildETA() {
        guard let seconds = filmBuildTimeEstimate?.remaining(now: ProcessInfo.processInfo.systemUptime) else { return }
        setActivityETA(seconds)
        if filmBuildTimeEstimate?.hasMeasuredPace == false { activityTimeRemaining = "Уточняю время…" }
    }

    private func clearActivityETA(preservingFilmEstimate: Bool = false) {
        activityETATask?.cancel()
        activityETATask = nil
        activityEstimatedCompletionUptime = nil
        activityTimeRemaining = isWorking ? "Уточняю время…" : ""
        activityUnmeasuredStartedAt = nil
        activityFilmBuildStage = nil
        activityStageProgress = nil
        if !preservingFilmEstimate { filmBuildTimeEstimate = nil }
    }

    private func beginUnmeasuredActivity(at completedProgress: Double, step: FilmBuildTimeEstimate.Step) {
        clearActivityETA(preservingFilmEstimate: true)
        activityProgressEstimate = ActivityTimeEstimate()
        activityProgressStage = nil
        activityUnmeasuredStartedAt = Date()
        activityProgressLabel = ""
        progress = max(progress, completedProgress)
        filmBuildTimeEstimate?.begin(step, now: ProcessInfo.processInfo.systemUptime)
        refreshFilmBuildETA()
    }

    private func setFilmBuildProgress(_ update: FilmBuildProgress, generation: UInt64) {
        guard isWorking, isCreatingFilm, operationGeneration == generation,
              activityUnmeasuredStartedAt != nil else { return }
        if activityFilmBuildStage != update.stage {
            activityUnmeasuredStartedAt = Date()
            activityFilmBuildStage = update.stage
        }
        activityTitle = update.stage.title
        activityProgressLabel = update.countLabel
        activityStageProgress = update.fraction
        status = update.detail ?? update.stage.title
        filmBuildTimeEstimate?.observe(update, now: ProcessInfo.processInfo.systemUptime)
        refreshFilmBuildETA()
    }

    private func finishUnmeasuredActivity(at finalProgress: Double? = nil) {
        if let finalProgress { progress = max(progress, finalProgress) }
        clearActivityETA()
    }

    private func run(
        _ initialStatus: String,
        presentation: ActivityPresentation = .standard,
        completionNotification: String? = nil,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !isWorking else { return }
        filmVerificationTask?.cancel()
        if !filmVerificationMessage.isEmpty { filmVerificationMessage = "Сохранено · проверка ожидает завершения операции" }
        activityDismissTask?.cancel()
        activityDismissTask = nil
        clearActivityETA()
        isWorking = true
        activityStartedUptime = ProcessInfo.processInfo.systemUptime
        activityPresentation = presentation
        isActivityPanelVisible = presentation != .silentEditor
        isActivityComplete = false
        activityTitle = initialStatus
        activityCompleted = 0
        activityTotal = 0
        activityProgressLabel = ""
        activityFileName = ""
        activityTimeRemaining = ""
        activityProgressEstimate = ActivityTimeEstimate()
        activityProgressStage = nil
        status = initialStatus
        progress = 0
        if isCreatingFilm, presentation == .standard {
            let assets = project?.assets.filter { !$0.excluded && !$0.missing } ?? []
            filmBuildTimeEstimate = FilmBuildTimeEstimate(
                sourceSeconds: assets.reduce(0) { $0 + ($1.metadata.duration ?? 0) },
                assetCount: assets.count, filmSeconds: directorBrief.requestedDuration,
                needsAnalysis: !isAnalysisCurrent, includesMusic: directorBrief.musicPolicy != .none,
                calibration: UserDefaults.standard.dictionary(forKey: Self.filmTimingCalibrationKey) as? [String: Double] ?? [:],
                now: ProcessInfo.processInfo.systemUptime
            )
            refreshFilmBuildETA()
        }
        operationGeneration &+= 1
        let runGeneration = operationGeneration
        let notificationTitle = completionNotification ?? (isCreatingFilm ? "Видео готово" : nil)
        let buildObserver: FilmBuildProgressHandler = { [weak self] update in
            await self?.setFilmBuildProgress(update, generation: runGeneration)
        }
        activeTask = Task {
            let activity = WorkActivity(reason: initialStatus)
            defer { withExtendedLifetime(activity) {} }
            var completedSuccessfully = false
            var retryAfterConflict = false
            do {
                await timelineCommitTask?.value
                if timelinePersistenceFailed, let pipeline {
                    try await commitTimelineForExport(using: pipeline)
                }
                try Task.checkCancellation()
                try await PerformanceTrace.measure(name: initialStatus, projectID: self.project?.id) {
                    try await FilmBuildReporting.$handler.withValue(isCreatingFilm ? buildObserver : nil) {
                        try await operation()
                    }
                }
                // Some AVFoundation and filesystem operations complete even
                // after their surrounding Task has been cancelled. Never
                // publish such a late completion as a successful operation.
                try Task.checkCancellation()
                completedSuccessfully = true
            } catch is CancellationError {
                if operationGeneration == runGeneration {
                    if let id = activeTimelineAIEdit?.replyID,
                       let response = directorMessages.first(where: { $0.id == id })?.response, response.saved {
                        status = "Правка сохранена. Ожидание отменено после сохранения." + (response.previewReady ? "" : " Просмотр пока не обновлён.")
                    } else { status = "Операция отменена до сохранения" }
                }
            } catch let projectError as ProjectStoreError {
                if case .staleRevision = projectError,
                   presentation == .editorAI,
                   var edit = activeTimelineAIEdit,
                   edit.retryCount < 3 {
                    edit.retryCount += 1
                    pendingTimelineAIEdits.insert(edit, at: 0)
                    queuedTimelineAIEditCount = pendingTimelineAIEdits.count
                    status = "Timeline изменился — ИИ спокойно повторит правку в фоне"
                    retryAfterConflict = true
                } else if operationGeneration == runGeneration {
                    errorMessage = projectError.localizedDescription
                    status = "Ошибка"
                }
            } catch {
                if operationGeneration == runGeneration {
                    errorMessage = notificationTitle == "Видео готово"
                        ? "Нужны доступные исходники и место для сохранения. Проект сохранён — можно продолжить сборку."
                        : String(error.localizedDescription.prefix(350))
                    status = "Требуется внимание"
                }
            }
            guard operationGeneration == runGeneration else { return }
            let savedDirectorEdit = activeTimelineAIEdit.flatMap { edit in directorMessages.first(where: { $0.id == edit.replyID })?.response?.saved } ?? false
            if completedSuccessfully, let notificationTitle, presentation != .editorAI || savedDirectorEdit {
                AppNotifications.shared.send(title: notificationTitle, body: status)
            }
            if let pipeline { recoverableFilmBuild = await pipeline.store.recoverableFilmBuild() }
            guard operationGeneration == runGeneration else { return }
            if presentation == .editorAI, needsTimelineAIRetryAfterManualEdit, let pipeline {
                do { try await commitTimelineForExport(using: pipeline) }
                catch {
                    timelinePersistenceFailed = true
                    errorMessage = "Не удалось сохранить ручную правку: \(error.localizedDescription)"
                }
            }
            if presentation == .editorAI,
               needsTimelineAIRetryAfterManualEdit,
               let edit = activeTimelineAIEdit,
               !retryAfterConflict {
                pendingTimelineAIEdits.insert(edit, at: 0)
                queuedTimelineAIEditCount = pendingTimelineAIEdits.count
                status = "Ручная правка сохранена — ИИ применит свою поверх неё"
            }
            if presentation == .editorAI {
                if let edit = activeTimelineAIEdit, !retryAfterConflict, !needsTimelineAIRetryAfterManualEdit {
                    let failure = completedSuccessfully ? "" : errorMessage.map { ": \($0)" } ?? ""
                    if directorMessages.first(where: { $0.id == edit.replyID })?.response == nil {
                        setDirectorResponseRecord(edit.replyID, receipt: .init(cancelled: Task.isCancelled,
                            failure: completedSuccessfully ? nil : errorMessage ?? status))
                    }
                    updateTimelineDirectorExchange(edit.replyID, status: status + failure)
                    _ = await persistWorkspaceState()
                }
                activeTimelineAIEdit = nil
                needsTimelineAIRetryAfterManualEdit = false
            }
            isWorking = false
            activityStartedUptime = nil
            activeTask = nil
            if let pipeline, await pipeline.store.manifest.autonomousJob?.state == .waitingForExternalResource {
                project = await pipeline.store.manifest
                errorMessage = nil
                status = project?.autonomousJob?.externalResource ?? "Ожидаю материалы"
                waitForExternalResources()
            }
            if completedSuccessfully, let calibration = filmBuildTimeEstimate?.finish(now: ProcessInfo.processInfo.systemUptime) {
                UserDefaults.standard.set(calibration, forKey: Self.filmTimingCalibrationKey)
            }
            clearActivityETA()
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
                try? await Task.sleep(for: .milliseconds(retryAfterConflict ? 350 : 120))
                guard let self else { return }
                if self.hasQueuedFilmRequest, !self.isWorking, !self.isDirectorResponding {
                    self.hasQueuedFilmRequest = false
                    self.createFilm()
                }
                self.startNextQueuedTimelineAIEdit()
                if !self.isWorking, self.pendingTimelineAIEdits.isEmpty,
                   self.filmVerificationMessage.contains("ожидает") { self.scheduleFilmVerification() }
            }
        }
    }

    private func startTimelineAIEdit(_ pendingEdit: PendingTimelineAIEdit) {
        let edit = rebasedTimelineAIEdit(pendingEdit)
        if let proposal = edit.proposal,
           project.map({ !proposal.isApplicable(to: $0, selectedID: edit.selectedItemID) }) ?? true {
            updateTimelineDirectorExchange(edit.replyID, status: "Момент изменился после совета — сначала нужно оценить его заново.")
            Task { @MainActor [weak self] in self?.startNextQueuedTimelineAIEdit() }
            return
        }
        activeTimelineAIEdit = edit
        editTrace = edit.trace
        edit.trace?.event("edit.dequeued")
        if edit.range != nil {
            guard let timeline,
                  edit.timelineAnchor == TimelineAIAnchor(timeline) else {
                activeTimelineAIEdit = nil
                feedback = edit.instruction
                status = "Timeline изменился — выделите диапазон кистью заново"
                updateTimelineDirectorExchange(edit.replyID, status: status)
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.startNextQueuedTimelineAIEdit()
                }
                return
            }
            applyMagicBrush(edit)
        } else {
            applyTimelineAIComment(edit)
        }
    }

    private func rebasedTimelineAIEdit(_ edit: PendingTimelineAIEdit) -> PendingTimelineAIEdit {
        var brief = directorBrief
        if edit.briefChanges.contains(.duration) {
            brief.requestedDuration = edit.directorBrief.requestedDuration
        }
        if edit.briefChanges.contains(.mood) {
            brief.mood = edit.directorBrief.mood
        }
        if edit.briefChanges.contains(.music) {
            brief.musicPolicy = edit.directorBrief.musicPolicy
            brief.musicTrackID = edit.directorBrief.musicTrackID
        }
        if edit.briefChanges.contains(.sourceAudio) {
            brief.sourceAudioPolicy = edit.directorBrief.sourceAudioPolicy
        }
        if edit.briefChanges.contains(.titles) {
            brief.titlePolicy = edit.directorBrief.titlePolicy
        }
        return PendingTimelineAIEdit(
            instruction: edit.instruction,
            replyID: edit.replyID,
            range: edit.range,
            timelineAnchor: edit.timelineAnchor,
            selectedItemID: edit.selectedItemID,
            selectedItemIsTitle: edit.selectedItemIsTitle,
            selectedCandidateID: edit.selectedCandidateID,
            playheadTime: edit.playheadTime,
            preset: edit.preset,
            targetDuration: brief.explicitRequestedDuration,
            preferredMusicTrackID: edit.briefChanges.contains(.music)
                ? edit.preferredMusicTrackID
                : directorMusicTrack?.id,
            directorBrief: brief,
            briefChanges: edit.briefChanges,
            retryCount: edit.retryCount,
            trace: edit.trace,
            proposal: edit.proposal
        )
    }

    private static func narrativeMood(requestedBy instruction: String) -> DirectorNarrativeMood? {
        let text = instruction.lowercased().replacingOccurrences(of: "ё", with: "е")
        func moodEvent(
            fragments: [String],
            affirmed: DirectorNarrativeMood,
            negated: DirectorNarrativeMood?
        ) -> (DirectorNarrativeMood, String.Index)? {
            fragments.compactMap { fragment -> (DirectorNarrativeMood, String.Index)? in
                guard let range = text.range(of: fragment, options: .backwards) else { return nil }
                let prefixStart = text.index(range.lowerBound, offsetBy: -min(48, text.distance(from: text.startIndex, to: range.lowerBound)))
                let prefix = String(text[prefixStart..<range.lowerBound])
                let isNegated = prefix.range(
                    of: #"(?:\bне\b|\bбез\b|никак\w*|избег\w*)[^,;.!?\n]{0,44}$"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
                if isNegated, let negated { return (negated, range.lowerBound) }
                return isNegated ? nil : (affirmed, range.lowerBound)
            }.max { $0.1 < $1.1 }
        }

        return [
            moodEvent(fragments: ["динамич", "энергич", "быстрый темп", "dynamic", "energetic"], affirmed: .dynamic, negated: .calm),
            moodEvent(fragments: ["спокой", "размеренн", "медленный темп", "calm", "slower"], affirmed: .calm, negated: .dynamic),
            moodEvent(fragments: ["кинематограф", "атмосферн", "cinematic", "atmospheric"], affirmed: .cinematic, negated: nil)
        ].compactMap { $0 }.max { $0.1 < $1.1 }?.0
    }

    private static func ignoredStoryConstraints(
        for instruction: String,
        commandCategories: Set<String>
    ) -> StoryConstraintLocks {
        var ignored: StoryConstraintLocks = []
        if commandCategories.contains("duration") {
            ignored.insert(.targetDuration)
        }
        if commandCategories.contains("transition") {
            ignored.insert(.transitionFrequency)
        }
        if commandCategories.contains("speed") {
            let text = instruction.lowercased().replacingOccurrences(of: "ё", with: "е")
            let vaguePacing = [
                "сделай быстрее", "чуть быстрее", "плотнее экшен", "экшен плотнее",
                "кадры подышат", "пусть кадры подышат", "не так быстро",
                "монтаж динамичнее", "сделай динамичнее"
            ].contains(where: text.contains)
            if !vaguePacing { ignored.insert(.pacing) }
        }
        return ignored
    }

    private func startNextQueuedTimelineAIEdit() {
        guard !isWorking, !isDirectorResponding, !pendingTimelineAIEdits.isEmpty else { return }
        let edit = pendingTimelineAIEdits.removeFirst()
        queuedTimelineAIEditCount = pendingTimelineAIEdits.count
        startTimelineAIEdit(edit)
    }
}


extension AppModel {
    func closeEditorialComparison() {
        editorialComparison?.close()
        editorialComparison = nil
    }

    func listenToMusicAlternatives() {
        guard let before = timeline, before.music != nil, let pipeline, let snapshot = project else { return }
        previewPlayer?.pause()
        let focus = before.items.first { $0.storyRole == .climax || $0.storyRole == .reaction }?.timelineStart ?? min(before.duration * 0.35, max(0, before.duration - 16))
        let session = EditorialComparisonSession(before: before, title: "Послушать варианты", detail: "Текущая музыка и до трёх альтернатив с тем же видео. При переключении позиция сохраняется.", focusTime: focus)
        editorialComparison?.close(); editorialComparison = session
        session.task = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let playback = try await pipeline.makePlayback(timeline: before, projectSnapshot: snapshot, interactiveLongEdge: 960)
                try Task.checkCancellation()
                await session.append(title: "Сейчас · " + (before.music?.trackTitle ?? "Музыка"), timeline: before, playback: playback)
                let alternatives = try await pipeline.musicAlternatives(for: before)
                for alternative in alternatives {
                    try Task.checkCancellation()
                    let playback = try await pipeline.makePlayback(timeline: alternative, projectSnapshot: snapshot, interactiveLongEdge: 960)
                    try Task.checkCancellation()
                    await session.append(title: alternative.music?.trackTitle ?? "Вариант", timeline: alternative, playback: playback)
                }
                session.message = alternatives.isEmpty ? "Других подходящих локальных треков нет. Добавьте музыку в библиотеку." : nil
            } catch is CancellationError { return }
            catch { session.message = error.localizedDescription }
            guard self.editorialComparison === session else { return }
            session.preparing = false
        }
    }

    func replaceMusicImmediately() {
        guard !isTimelineInteractionBlocked, let before = timeline, before.music != nil, let pipeline else { return }
        editorialPreparationTask?.cancel()
        status = "Подбираю другую музыку"
        editorialPreparationTask = Task { [weak self] in
            do {
                let alternatives = try await pipeline.musicAlternatives(for: before)
                try Task.checkCancellation()
                guard let self, self.pipeline === pipeline, self.timeline == before else { return }
                guard let after = alternatives.first else { self.errorMessage = "Других подходящих локальных треков нет. Добавьте музыку в библиотеку. Текущая версия сохранена."; return }
                self.editTimelineOptimistically("Другая музыка", checkpointReason: "Перед заменой музыки") { $0 = after; return true }
            } catch is CancellationError { }
            catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func compareOtherShot(_ itemID: UUID) {
        guard let timeline, let project else { return }
        let edits = LocalEditorialEditPlanner.alternatives(itemID: itemID, timeline: timeline, project: project)
        guard !edits.isEmpty else { errorMessage = "В допустимом интервале нет подходящих альтернатив. Монтаж сохранён."; return }
        prepareEditorialEdits(edits)
    }

    func compareShotDuration(_ itemID: UUID, longer: Bool) {
        guard let timeline, let project else { return }
        do { prepareEditorialEdits([try LocalEditorialEditPlanner.duration(itemID: itemID, longer: longer, timeline: timeline, project: project)]) }
        catch { errorMessage = error.localizedDescription }
    }

    private func prepareEditorialEdits(_ edits: [LocalEditorialEdit]) {
        guard let first = edits.first, let pipeline, let snapshot = project else { return }
        previewPlayer?.pause()
        let session = EditorialComparisonSession(before: first.before, title: first.title, detail: first.detail, focusTime: first.start)
        editorialComparison?.close(); editorialComparison = session
        session.task = Task { [weak session] in
            guard let session else { return }
            do {
                let playback = try await pipeline.makePlayback(timeline: first.before, projectSnapshot: snapshot, interactiveLongEdge: 960)
                try Task.checkCancellation()
                await session.append(title: "До", timeline: first.before, playback: playback)
                for (index, edit) in edits.enumerated() {
                    let playback = try await pipeline.makePlayback(timeline: edit.after, projectSnapshot: snapshot, interactiveLongEdge: 960)
                    try Task.checkCancellation()
                    await session.append(title: edits.count == 1 ? "После" : "Вариант \(index + 1)", timeline: edit.after, playback: playback)
                }
            } catch is CancellationError { return }
            catch { session.message = error.localizedDescription }
            session.preparing = false
        }
    }

    func applyEditorialComparison() {
        guard let session = editorialComparison, !session.preparing,
              session.selectedIndex > 0, session.options.indices.contains(session.selectedIndex) else { return }
        guard timeline == session.before else {
            session.message = "Монтаж изменился после открытия сравнения. Закройте его и подготовьте варианты заново."
            return
        }
        let after = session.options[session.selectedIndex].timeline
        let title = session.title
        closeEditorialComparison()
        editTimelineOptimistically(title, checkpointReason: "Перед правкой: " + title) { $0 = after; return true }
    }

    func rememberEditorialStyle(_ aspects: Set<EditorialPreferenceAspect>) async {
        guard let timeline, let project else { return }
        let track = musicTracks.first { $0.id == timeline.music?.trackID }
        let durations = timeline.items.filter { $0.overlay == nil && $0.kind != .title }.map(\.timelineDuration)
        let average = durations.reduce(0, +) / Double(max(1, durations.count))
        let titleDurations = timeline.effectiveTitleItems.map(\.duration)
        var signals: [ExplicitEditorialPreference] = []
        for aspect in aspects {
            if aspect == .music && track == nil { continue }
            if aspect == .titles && titleDurations.isEmpty { continue }
            let value = aspect == .pacing ? min(1, max(0, (8 - average) / 8)) : aspect == .titles ? titleDurations.reduce(0, +) / Double(titleDurations.count) : 1
            signals.append(.init(aspect: aspect, scope: .mood, projectID: project.id, timeline: timeline, track: track, value: value))
        }
        do { try await ExplicitEditorialPreferenceStore.shared.record(signals); status = "Предпочтения сохранены" }
        catch { errorMessage = error.localizedDescription }
    }

    func rememberMusicDislike(excludeTrack: Bool) {
        guard let timeline, let project, let track = musicTracks.first(where: { $0.id == timeline.music?.trackID }) else { return }
        let signal = ExplicitEditorialPreference(aspect: .music, scope: excludeTrack ? .track : .mood,
            projectID: project.id, timeline: timeline, track: track, value: -1, excluded: excludeTrack)
        Task {
            do { try await ExplicitEditorialPreferenceStore.shared.record([signal]); status = "Предпочтение сохранено. Отменить его можно в «Запомнить этот стиль»." }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
