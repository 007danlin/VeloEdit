import Foundation

public enum DirectorBriefFulfillmentError: LocalizedError, Sendable {
    case requestedMusicUnavailable(String)
    case unavailableMusicTrack(UUID)
    case automaticMusicUnavailable
    case specificMusicTrackNotSelected
    case missingGeneratedTimeline
    case noUsableSourceMaterial
    case noUsableMoments

    public var errorDescription: String? {
        switch self {
        case .requestedMusicUnavailable(let query):
            return "Запрошенная песня «\(query)» недоступна. Текущая версия сохранена; выберите доступный файл или другую песню."
        case .unavailableMusicTrack:
            return "Выбранный музыкальный трек недоступен. Верните файл трека или выберите другой — фильм не будет сохранён с подменой музыки."
        case .automaticMusicUnavailable:
            return "Не удалось получить подходящий музыкальный трек. Проверьте подключение или выберите свой трек — фильм не будет сохранён без обещанной музыки."
        case .specificMusicTrackNotSelected:
            return "В брифе указана конкретная музыка, но трек не выбран. Выберите трек или переключите способ подбора музыки."
        case .missingGeneratedTimeline:
            return "Не удалось проверить режиссёрский бриф: созданный фильм не найден."
        case .noUsableSourceMaterial:
            return "Не из чего собрать фильм: все исходники исключены, недоступны или не содержат читаемого изображения. Верните хотя бы один исходник в проект и повторите запрос."
        case .noUsableMoments:
            return "Не удалось найти ни одного пригодного видеофрагмента. Проверьте доступ к исходным файлам или повторно запустите анализ — режиссёрский запрос сохранён."
        }
    }
}

public actor VeloEditPipeline {
    public let store: ProjectStore
    private let renderedProber: any EditorialRenderedProbing
    private let speechRecognizer: (any LocalSpeechRecognizing)?
    private let importer: MediaImporter
    private let analyzer: (any VisionModelProtocol)?
    private let musicLibrary: LocalMusicLibrary
    private let musicSystem: MusicLibrary
    private let musicSelectionHistory: LocalMusicSelectionHistoryStore
    private let personalTasteStore: LocalPersonalTasteStore
    private var lastMusicResolutionError: String?
    private let analysisQueue = AnalysisBackgroundQueue()
    private var activeAnalysisTask: Task<AnalysisResult, Error>?
    private var activeAnalysisAssetID: UUID?
    private var latestClientTimelineRevision: UInt64 = 0
    private var activeFilmTask: Task<Timeline, Error>?
    private var activeFilmRequest: FilmBuildRequest?

    public init(
        store: ProjectStore,
        importer: MediaImporter = MediaImporter(),
        speechRecognizer: (any LocalSpeechRecognizing)? = nil,
        renderedProber: any EditorialRenderedProbing = LocalEditorialRenderedProber(),
        analyzer: (any VisionModelProtocol)? = nil,
        musicLibrary: LocalMusicLibrary? = nil,
        musicSystem: MusicLibrary? = nil,
        freeToUseProvider: FreeToUseMusicProvider? = nil,
        musicSelectionHistory: LocalMusicSelectionHistoryStore = .shared,
        personalTasteStore: LocalPersonalTasteStore = LocalPersonalTasteStore()
    ) {
        self.store = store
        self.importer = importer
        self.speechRecognizer = speechRecognizer
        self.renderedProber = renderedProber
        self.analyzer = analyzer
        let projectMusicLibrary = musicLibrary ?? LocalMusicLibrary(rootURL: store.musicLibraryURL)
        self.musicLibrary = projectMusicLibrary
        let bundledProvider = BundledMusicProvider(library: projectMusicLibrary)
        let localProvider = LocalMusicProvider(library: projectMusicLibrary)
        let onlineFreeToUseProvider = freeToUseProvider ?? FreeToUseMusicProvider(library: projectMusicLibrary)
        let openverseProvider = OpenverseMusicProvider(library: projectMusicLibrary)
        self.musicSystem = musicSystem ?? MusicLibrary(
            localLibrary: projectMusicLibrary,
            providers: [bundledProvider, localProvider, onlineFreeToUseProvider, openverseProvider, IncompetechMusicProvider(library: projectMusicLibrary), AudionautixMusicProvider(library: projectMusicLibrary), ScottBuckleyMusicProvider(library: projectMusicLibrary), InternetArchiveMusicProvider(library: projectMusicLibrary), WebMusicProvider(library: projectMusicLibrary)],
            reusableCache: musicLibrary == nil ? .shared : nil
        )
        self.musicSelectionHistory = musicSelectionHistory
        self.personalTasteStore = personalTasteStore
    }

    public func updateAISettings(mode: AIPowerMode, advanced: AdvancedAISettings) async throws {
        try await store.update { project in
            project.preferences.aiPowerMode = mode
            project.preferences.advancedAISettings = advanced
        }
    }

    /// Rename an existing film without invoking selection, chronology, music or
    /// montage assembly. The store revision rejects any late result after edits.
    @discardableResult
    public func refreshChapterTitles(force: Bool = false, model suppliedModel: (any ChapterTitleModel)? = nil) async throws -> Timeline {
        let snapshot = await store.snapshot()
        let project = snapshot.manifest
        guard let timeline = project.timelines.last,
              var plan = project.storyPlans.last(where: { $0.id == timeline.storyPlanID }) else {
            throw DirectorBriefFulfillmentError.missingGeneratedTimeline
        }
        if let reference = project.preferences.chapterTitleReference { plan = reference.applying(to: plan, assets: project.assets) }
        let model: any ChapterTitleModel
        if let suppliedModel { model = suppliedModel }
        else { model = await LocalChapterTitleModel.configured(preferences: project.preferences, previousModelIdentity: timeline.chapterTitleDecisions?.first?.modelID) }
        let renamed = try await SmartChapterTitleEngine().applying(to: timeline, plan: plan, assets: project.assets,
            analyses: project.analyses, mode: project.preferences.effectiveAIPowerMode, model: model, force: force)
        try Task.checkCancellation()
        try await store.update(ifRevision: snapshot.revision) { current in
            guard let index = current.timelines.firstIndex(where: { $0.id == timeline.id }) else { return }
            if renamed != timeline { Self.appendCheckpoint(timeline: timeline, reason: "Названия частей", to: &current) }
            current.timelines[index] = renamed
        }
        return renamed
    }

    public func applySpeechCaptionSettings(_ brief: DirectorBrief) async throws -> Timeline {
        let snapshot = await store.snapshot()
        var project = snapshot.manifest
        guard var timeline = project.timelines.last, let planIndex = project.storyPlans.firstIndex(where: { $0.id == timeline.storyPlanID }) else { throw DirectorBriefFulfillmentError.missingGeneratedTimeline }
        let preset = project.storyPlans[planIndex].preset
        let enabled = brief.subtitlesEnabled(preset: preset)
        var records = timeline.speechRecords ?? []
        if enabled {
            let ids = Set(timeline.items.compactMap(\.assetID))
            let speechCacheURL = await store.cacheURL
            let recognizer: any LocalSpeechRecognizing = speechRecognizer ?? WhisperKitSpeechRecognizer(cacheURL: speechCacheURL)
            for asset in project.assets where ids.contains(asset.id) && asset.metadata.hasAudio && !records.contains(where: { $0.assetID == asset.id }) {
                if let transcript = try await recognizer.transcribe(url: asset.originalURL, localeIdentifier: "ru") { records.append(SpeechSourceRecord(assetID: asset.id, transcript: transcript)) }
            }
        }
        timeline.speechRecords = records
        if brief.titlePolicy == .none { timeline.titleItems = timeline.effectiveTitleItems.filter { [.subtitle, .automaticSubtitles, .wordLevelCaptions].contains($0.kind) } }
        timeline = SpeechSubtitleBuilder.applying(to: timeline, records: records, enabled: enabled, allowMuted: brief.subtitlesWithoutAudio == true, style: brief.subtitleStyle)
        project.storyPlans[planIndex].directorBrief = brief
        try Task.checkCancellation()
        try await store.update(ifRevision: snapshot.revision) { current in
            if let old = current.timelines.last { Self.appendCheckpoint(timeline: old, reason: "Настройка субтитров", to: &current) }
            current.storyPlans[planIndex].directorBrief = brief
            if let i = current.timelines.firstIndex(where: { $0.id == timeline.id }) { current.timelines[i] = timeline }
        }
        return timeline
    }

    public func updateWorkspaceState(_ state: ProjectWorkspaceState) async throws {
        try await store.updateWorkspaceState(state)
    }

    /// Re-runs the deterministic production contract after editor commands and
    /// manual music assignment. This is intentionally public because AppModel
    /// applies those mutations after automatic variant selection.
    @discardableResult
    public func enforceDirectorBrief(_ brief: DirectorBrief) async throws -> Timeline {
        let snapshot = await store.snapshot()
        let current = snapshot.manifest
        guard var timeline = current.timelines.last,
              var plan = current.storyPlans.last(where: { $0.id == timeline.storyPlanID }) else {
            throw DirectorBriefFulfillmentError.missingGeneratedTimeline
        }
        plan.directorBrief = brief
        if plan.preset == .vlog {
            timeline.originalAudioVolume = brief.sourceAudioPolicy.volume
            timeline.audioDucking = AudioDuckingSettings(enabled: brief.sourceAudioPolicy != .mute)
            if brief.musicPolicy == .none { timeline.music = nil; timeline.adaptiveSoundtrack = nil }
            if brief.titlePolicy == .none { timeline.titleItems = timeline.effectiveTitleItems.filter { [.subtitle, .automaticSubtitles, .wordLevelCaptions].contains($0.kind) } }
            timeline = SpeechSubtitleBuilder.applying(to: timeline, records: timeline.speechRecords ?? [], enabled: brief.subtitlesEnabled(preset: .vlog), allowMuted: brief.subtitlesWithoutAudio == true, style: brief.subtitleStyle)
            try await store.update(ifRevision: snapshot.revision) { project in
                if let index = project.storyPlans.firstIndex(where: { $0.id == plan.id }) { project.storyPlans[index] = plan }
                if let index = project.timelines.firstIndex(where: { $0.id == timeline.id }) { project.timelines[index] = timeline }
            }
            return timeline
        }
        // A late format/title/audio change preserves the duration contract.
        plan.constraints.targetDuration = brief.explicitRequestedDuration
            ?? plan.constraints.targetDuration
        plan.constraints.pacing = brief.mood.pacing

        let tracks = try await musicSystem.tracks()
        if brief.musicPolicy == .specificTrack {
            guard let trackID = brief.musicTrackID else {
                throw DirectorBriefFulfillmentError.specificMusicTrackNotSelected
            }
            guard let track = tracks.first(where: {
                $0.id == trackID && FileManager.default.fileExists(atPath: $0.localFileURL.path)
            }) else {
                throw DirectorBriefFulfillmentError.unavailableMusicTrack(trackID)
            }
            timeline.music = MusicDirective(
                style: track.suggestedStyle,
                bpm: track.bpm,
                volume: timeline.music?.volume ?? 0.22,
                trackID: track.id,
                trackTitle: track.title
            )
            timeline.adaptiveSoundtrack = nil
        }

        timeline = try TimelineDeliveryContract().enforce(
            timeline: timeline,
            plan: plan,
            assets: current.assets,
            analyses: current.analyses
        )
        if brief.musicPolicy == .matchVideo || brief.musicPolicy == .soft {
            if brief.musicPolicy == .soft {
                // A late editor command may have attached an energetic track
                // ID. Clear that identity so the calm directive is resolved
                // again instead of preserving a musically incompatible file.
                timeline.music?.trackID = nil
                timeline.music?.trackTitle = nil
                timeline.music?.structure = nil
            }
            timeline = await Self.resolvingMusic(
                in: timeline,
                tracks: tracks,
                preserveDuration: true
            )
            guard let trackID = timeline.music?.trackID,
                  tracks.contains(where: {
                      $0.id == trackID && FileManager.default.fileExists(atPath: $0.localFileURL.path)
                  }) else {
                throw DirectorBriefFulfillmentError.automaticMusicUnavailable
            }
            // Music resolution may refresh BPM/structure, but it must not
            // relax the selected soft/content-aware policy.
            timeline = try TimelineDeliveryContract().enforce(
                timeline: timeline,
                plan: plan,
                assets: current.assets,
                analyses: current.analyses
            )
            timeline = await Self.applyingAdaptiveSoundtrack(
                to: timeline,
                plan: plan,
                tracks: tracks,
                analyses: current.analyses
            )
        }
        try await store.update(ifRevision: snapshot.revision) { project in
            if let planIndex = project.storyPlans.lastIndex(where: { $0.id == plan.id }) {
                project.storyPlans[planIndex] = plan
            }
            if let timelineIndex = project.timelines.lastIndex(where: { $0.id == timeline.id }) {
                project.timelines[timelineIndex] = timeline
            }
            Self.recordMusicCredit(from: timeline, tracks: tracks, in: &project)
        }
        return timeline
    }

    public func save() async throws {
        try await store.save()
    }

    /// Persists an already-normalized optimistic Timeline. Calls may arrive out
    /// of order after preview work; only the newest client revision is allowed
    /// to become project state.
    @discardableResult
    public func commitLatestTimeline(_ timeline: Timeline, clientRevision: UInt64, checkpointReason: String? = nil) async throws -> Bool {
        guard clientRevision >= latestClientTimelineRevision else { return false }
        latestClientTimelineRevision = clientRevision
        let tracks = (try? await musicSystem.tracks()) ?? []
        guard clientRevision >= latestClientTimelineRevision else { return false }
        try await store.update { project in
            guard let index = project.timelines.indices.last else { return }
            if let checkpointReason, project.timelines[index] != timeline {
                Self.appendCheckpoint(timeline: project.timelines[index], reason: checkpointReason, to: &project)
            }
            // The lock is edited instantly with the clip. Keep the source
            // candidate in sync so a later AI assembly respects that choice.
            let previousItems = Dictionary(uniqueKeysWithValues: project.timelines[index].items.map { ($0.id, $0) })
            for item in timeline.items where previousItems[item.id]?.locked != item.locked {
                guard let candidateID = item.candidateID else { continue }
                for analysisIndex in project.analyses.indices {
                    guard let candidateIndex = project.analyses[analysisIndex].candidates.firstIndex(where: { $0.id == candidateID }) else { continue }
                    project.analyses[analysisIndex].candidates[candidateIndex].locked = item.locked
                    if item.locked { project.analyses[analysisIndex].candidates[candidateIndex].excluded = false }
                }
            }
            project.timelines[index] = timeline
            Self.recordMusicCredit(from: timeline, tracks: tracks, in: &project)
        }
        return true
    }

    /// Rechecks the saved edit against an immutable revision. A late review may
    /// not replace a newer edit. Reuses completed stages, preserving MP4 proof.
    @discardableResult
    public func verifyCurrentFilm() async throws -> Timeline {
        let snapshot = await store.snapshot()
        let current = snapshot.manifest
        guard let original = current.timelines.last,
              let plan = current.storyPlans.first(where: { $0.id == original.storyPlanID }) else {
            throw NaturalLanguageDirectorError.timelineUnavailable
        }
        return try await PerformanceTrace.measure(name: "film.recheck", projectID: current.id, revision: String(snapshot.revision),
            fields: ["signature": EditorialRenderSignature.signature(original)]) {
            let tracks = try await musicSystem.tracks()
            let cache = CachePaths(root: await store.cacheURL).previewDerivedMediaDirectory
            var checked = await Self.editorialRenderReview(timeline: original, plan: plan, assets: current.assets,
                analyses: current.analyses, tracks: tracks, telemetry: Self.telemetryLookup(in: current), cacheURL: cache,
                prober: renderedProber, repairsRemaining: 0, events: current.events, normalizePresentation: false)
            try Task.checkCancellation()
            checked.filmDeliveryReport = AutomaticFilmDelivery.verifiedReport(for: checked, plan: plan,
                assets: current.assets, analyses: current.analyses)
            try await store.update(ifRevision: snapshot.revision) { project in
                guard let index = project.timelines.indices.last, project.timelines[index].id == original.id else {
                    throw ProjectStoreError.staleRevision(expected: snapshot.revision, actual: snapshot.revision + 1)
                }
                project.timelines[index] = checked
            }
            return checked
        }
    }

    public func snapshot() async -> ProjectManifest {
        try? await migrateLegacyTimelineAudioSettings()
        return await store.manifest
    }

    public func renameProject(to name: String) async throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        try await store.update { project in
            project.name = cleanName
        }
    }

    public func updateAsset(id: UUID, favorite: Bool? = nil, excluded: Bool? = nil) async throws {
        try await store.update { project in
            guard let index = project.assets.firstIndex(where: { $0.id == id }) else { return }
            if let favorite { project.assets[index].favorite = favorite }
            if let excluded {
                project.assets[index].excluded = excluded
                project.sourceMap = nil
            }
        }
    }

    public func removeAsset(id: UUID) async throws {
        try await store.update { project in
            guard let asset = project.assets.first(where: { $0.id == id }) else { return }
            var archived = RemovedMediaArchive(asset: asset, analyses: project.analyses.filter { $0.assetID == id },
                sourceMap: project.sourceMap, events: project.events, plans: project.storyPlans,
                timelines: project.timelines, telemetry: project.effectiveTelemetrySources.filter { $0.linkedAssetID == id })
            let candidateIDs = Set(project.analyses
                .filter { $0.assetID == id }
                .flatMap(\.candidates)
                .map(\.id))
            project.assets.removeAll { $0.id == id }
            project.analyses.removeAll { $0.assetID == id }
            project.sourceMap = nil
            for index in project.events.indices {
                project.events[index].assetIDs.removeAll { $0 == id }
            }
            project.events.removeAll { $0.assetIDs.isEmpty }
            for index in project.storyPlans.indices {
                for chapterIndex in project.storyPlans[index].chapters.indices {
                    project.storyPlans[index].chapters[chapterIndex].candidateIDs.removeAll { candidateIDs.contains($0) }
                }
                project.storyPlans[index].chapters.removeAll { $0.candidateIDs.isEmpty }
            }
            for index in project.timelines.indices {
                project.timelines[index].items.removeAll { $0.assetID == id }
                project.timelines[index].audioClips?.removeAll { $0.assetID == id }
                let removedSourceIDs = Set(project.effectiveTelemetrySources.filter { $0.linkedAssetID == id }.map(\.id))
                project.timelines[index].telemetryItems?.removeAll { $0.linkedAssetID == id || $0.sourceID.map(removedSourceIDs.contains) == true }
                project.timelines[index].items = Self.retimed(project.timelines[index].items)
                let availableIDs = Set(project.timelines[index].items.map(\.id))
                project.timelines[index].effects?.removeAll { effect in
                    effect.targetClipID.map { !availableIDs.contains($0) } ?? false
                }
                project.timelines[index].titleItems?.removeAll { title in
                    title.targetClipID.map { !availableIDs.contains($0) } ?? false
                }
                project.timelines[index].transitionItems?.removeAll {
                    !availableIDs.contains($0.outgoingClipID) || !availableIDs.contains($0.incomingClipID)
                }
            }
            project.telemetrySources?.removeAll { $0.linkedAssetID == id }
            archived.afterTimelines = project.timelines
            project.removedMedia = (project.removedMedia ?? []) + [archived]
        }
    }

    public func updateTimelineItem(
        id: UUID,
        sourceStart: Double? = nil,
        timelineDuration: Double? = nil,
        speed: Double? = nil,
        locked: Bool? = nil,
        transition: String? = nil,
        updateTransition: Bool = false,
        effect: String? = nil,
        updateEffect: Bool = false,
        videoAdjustments: VideoAdjustments? = nil,
        updateVideoAdjustments: Bool = false,
        audioAdjustments: AudioAdjustments? = nil,
        updateAudioAdjustments: Bool = false,
        reversePlayback: Bool? = nil,
        title: String? = nil,
        updateTitle: Bool = false,
        titleStyle: TitleStyle? = nil,
        updateTitleStyle: Bool = false,
        overlay: OverlaySettings? = nil,
        updateOverlay: Bool = false
    ) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last,
                  let itemIndex = project.timelines[timelineIndex].items.firstIndex(where: { $0.id == id }) else { return }
            let previousClips = Dictionary(uniqueKeysWithValues: project.timelines[timelineIndex].items.map { ($0.id, $0) })
            var item = project.timelines[timelineIndex].items[itemIndex]
            let assetDuration = item.kind == .video ? item.assetID.flatMap { assetID in
                project.assets.first(where: { $0.id == assetID })?.metadata.duration
            } : nil
            if let sourceStart {
                let durationFactor = item.speedRamp?.outputDuration(sourceDuration: 1) ?? (1 / item.speed)
                let minimumSourceDuration = 0.25 / max(0.01, durationFactor)
                let upperBound = max(0, (assetDuration ?? item.sourceStart + item.sourceDuration) - minimumSourceDuration)
                item.sourceStart = min(max(0, sourceStart), upperBound)
                if let assetDuration {
                    let availableSource = max(minimumSourceDuration, assetDuration - item.sourceStart)
                    item.sourceDuration = min(item.sourceDuration, availableSource)
                    item.timelineDuration = item.sourceDuration * durationFactor
                }
            }
            if let timelineDuration {
                let durationFactor = item.speedRamp?.outputDuration(sourceDuration: 1) ?? (1 / item.speed)
                let available = assetDuration.map { max(0.25, ($0 - item.sourceStart) * durationFactor) } ?? 60 * 60
                let duration = min(max(0.25, timelineDuration), available)
                item.timelineDuration = duration
                item.sourceDuration = duration / max(0.01, durationFactor)
            }
            if let speed {
                item.speed = min(max(0.1, speed), 20)
                item.speedRamp = nil
                item.timelineDuration = max(0.05, item.sourceDuration / item.speed)
            }
            if let locked {
                item.locked = locked
                if let candidateID = item.candidateID {
                    for analysisIndex in project.analyses.indices {
                        if let candidateIndex = project.analyses[analysisIndex].candidates.firstIndex(where: { $0.id == candidateID }) {
                            project.analyses[analysisIndex].candidates[candidateIndex].locked = locked
                            if locked { project.analyses[analysisIndex].candidates[candidateIndex].excluded = false }
                        }
                    }
                }
            }
            if updateTransition {
                item.transition = transition
                var transitions = project.timelines[timelineIndex].effectiveTransitionItems
                transitions.removeAll { $0.incomingClipID == item.id }
                if let raw = transition,
                   let style = TransitionStyle(rawValue: raw),
                   style != .cut,
                   let outgoing = project.timelines[timelineIndex].items[..<itemIndex].last(where: { $0.overlay == nil }) {
                    let preset = TransitionPresetRegistry.preset(for: style)
                    transitions.append(TimelineTransitionItem(
                        style: style,
                        outgoingClipID: outgoing.id,
                        incomingClipID: item.id,
                        startTime: item.timelineStart,
                        duration: preset.defaultDuration,
                        intensity: preset.defaultIntensity,
                        parameters: preset.defaultParameters,
                        explanation: ["Пользователь выбрал редактируемый переход VeloEdit"]
                    ))
                }
                project.timelines[timelineIndex].transitionItems = transitions
            }
            if updateEffect { item.effect = effect }
            if updateVideoAdjustments { item.videoAdjustments = videoAdjustments?.isNeutral == true ? nil : videoAdjustments }
            if updateAudioAdjustments { item.audioAdjustments = audioAdjustments?.isNeutral == true ? nil : audioAdjustments }
            if let reversePlayback { item.reversePlayback = reversePlayback ? true : nil }
            if updateTitle { item.title = title }
            if updateTitleStyle { item.titleStyle = titleStyle }
            if updateOverlay { item.overlay = overlay }
            project.timelines[timelineIndex].items[itemIndex] = item
            project.timelines[timelineIndex].items = Self.retimed(project.timelines[timelineIndex].items)
            Self.alignTelemetryItems(in: &project.timelines[timelineIndex], previousClips: previousClips)
        }
    }

    /// Adds a source from the media browser to the magnetic primary storyline.
    /// TimelineTiming closes every gap after insertion, so dropping a source can
    /// never leave an accidental hole in the movie.
    @discardableResult
    public func insertAssetIntoTimeline(assetID: UUID, at requestedIndex: Int? = nil) async throws -> UUID {
        let itemID = UUID()
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last,
                  let asset = project.assets.first(where: { $0.id == assetID }) else { return }
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
            let index = min(max(0, requestedIndex ?? project.timelines[timelineIndex].items.count), project.timelines[timelineIndex].items.count)
            project.timelines[timelineIndex].items.insert(item, at: index)
            project.timelines[timelineIndex].items = Self.retimed(project.timelines[timelineIndex].items)
        }
        return itemID
    }

    /// Materializes a built-in background inside the project and inserts it as
    /// a normal still-image clip in the magnetic primary storyline.
    @discardableResult
    public func insertBackgroundIntoTimeline(
        _ preset: BackgroundPreset,
        at requestedIndex: Int? = nil,
        duration: Double = 4
    ) async throws -> UUID {
        let current = await store.manifest
        guard let timeline = current.timelines.last else {
            throw FCPXMLExportError.invalidTimeline("Нет созданного фильма")
        }
        let width = max(16, timeline.width)
        let height = max(16, timeline.height)
        let contentHash = "\(preset.contentHashPrefix)\(width)x\(height)"
        let cache = CachePaths(root: await store.cacheURL)
        let imageURL = cache.background(preset, width: width, height: height)
        if !FileManager.default.fileExists(atPath: imageURL.path) {
            try FileManager.default.createDirectory(at: cache.backgroundsDirectory, withIntermediateDirectories: true)
            try BackgroundPresetRenderer.render(
                preset,
                width: width,
                height: height,
                sourceImageURL: preset.bundledImageURL(),
                to: imageURL
            )
        }
        let values = try imageURL.resourceValues(forKeys: [.fileSizeKey])
        let itemID = UUID()
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            let asset: MediaAsset
            if let existing = project.assets.first(where: { $0.contentHash == contentHash }) {
                asset = existing
            } else {
                asset = MediaAsset(
                    originalURL: imageURL,
                    displayName: preset.localizedTitle,
                    kind: .photo,
                    byteSize: Int64(values.fileSize ?? 0),
                    contentHash: contentHash,
                    metadata: MediaMetadata(width: width, height: height, codec: "png", dynamicRange: .sdr)
                )
                project.assets.append(asset)
            }
            let clipDuration = max(0.25, duration)
            let item = TimelineItem(
                id: itemID,
                assetID: asset.id,
                kind: .photo,
                sourceDuration: clipDuration,
                timelineStart: 0,
                timelineDuration: clipDuration,
                title: preset.localizedTitle,
                explanation: ["Добавлен фон «\(preset.localizedTitle)»"]
            )
            let index = min(max(0, requestedIndex ?? project.timelines[timelineIndex].items.count), project.timelines[timelineIndex].items.count)
            project.timelines[timelineIndex].items.insert(item, at: index)
            project.timelines[timelineIndex].items = Self.retimed(project.timelines[timelineIndex].items)
        }
        return itemID
    }

    /// Prepare resources without publishing any Timeline changes. The caller
    /// commits resources, clips and titles together under the snapshot revision.
    private func preparingDirectorBackgrounds(_ commands: [EditorCommand], in source: ProjectManifest, timeline: Timeline) async throws -> ProjectManifest {
        var project = source
        let cache = CachePaths(root: await store.cacheURL)
        for command in commands {
            guard case .insertBackground(let insertion) = command,
                  let preset = DirectorLibraryEdits.background(matching: insertion.background),
                  insertion.duration.isFinite, (0.25...120).contains(insertion.duration) else { continue }
            try Task.checkCancellation()
            let width = max(16, timeline.width), height = max(16, timeline.height)
            let hash = "\(preset.contentHashPrefix)\(width)x\(height)"
            let imageURL = cache.background(preset, width: width, height: height)
            if !FileManager.default.fileExists(atPath: imageURL.path) {
                try FileManager.default.createDirectory(at: cache.backgroundsDirectory, withIntermediateDirectories: true)
                try BackgroundPresetRenderer.render(preset, width: width, height: height,
                    sourceImageURL: preset.bundledImageURL(), to: imageURL)
            }
            if let index = project.assets.firstIndex(where: { $0.contentHash == hash }) {
                project.assets[index].originalURL = imageURL
                project.assets[index].missing = false
            } else {
                let values = try imageURL.resourceValues(forKeys: [.fileSizeKey])
                project.assets.append(MediaAsset(originalURL: imageURL, displayName: preset.localizedTitle,
                    kind: .photo, byteSize: Int64(values.fileSize ?? 0), contentHash: hash,
                    metadata: MediaMetadata(width: width, height: height, codec: "png", dynamicRange: .sdr)))
            }
        }
        return project
    }

    /// Upgrades background assets created by an earlier catalogue version in
    /// place. Timeline item IDs and asset references stay intact, but playback
    /// immediately uses the new shared browser/render artwork.
    public func migrateLegacyBuiltInBackgroundAssets() async throws {
        let current = await store.manifest
        let legacyAssets = current.assets.filter {
            BackgroundPreset.preset(for: $0) != nil && !$0.contentHash.hasPrefix("veloedit-background-v3-")
        }
        guard !legacyAssets.isEmpty else { return }
        let fallbackTimeline = current.timelines.last
        let cache = CachePaths(root: await store.cacheURL)
        try FileManager.default.createDirectory(at: cache.backgroundsDirectory, withIntermediateDirectories: true)
        var replacements: [UUID: MediaAsset] = [:]

        for legacy in legacyAssets {
            guard let preset = BackgroundPreset.preset(for: legacy) else { continue }
            let width = max(16, legacy.metadata.width ?? fallbackTimeline?.width ?? 1920)
            let height = max(16, legacy.metadata.height ?? fallbackTimeline?.height ?? 1080)
            let imageURL = cache.background(preset, width: width, height: height)
            if !FileManager.default.fileExists(atPath: imageURL.path) {
                try BackgroundPresetRenderer.render(
                    preset,
                    width: width,
                    height: height,
                    sourceImageURL: preset.bundledImageURL(),
                    to: imageURL
                )
            }
            let values = try imageURL.resourceValues(forKeys: [.fileSizeKey])
            var replacement = legacy
            replacement.originalURL = imageURL
            replacement.bookmarkData = nil
            replacement.byteSize = Int64(values.fileSize ?? 0)
            replacement.contentHash = "\(preset.contentHashPrefix)\(width)x\(height)"
            replacement.fullContentHash = nil
            replacement.metadata.width = width
            replacement.metadata.height = height
            replacement.metadata.codec = "png"
            replacement.metadata.dynamicRange = .sdr
            replacement.missing = false
            replacements[legacy.id] = replacement
        }

        guard !replacements.isEmpty else { return }
        try await store.update { project in
            for index in project.assets.indices {
                if let replacement = replacements[project.assets[index].id] {
                    project.assets[index] = replacement
                }
            }
        }
    }

    /// Adds media above the magnetic storyline without changing its duration.
    @discardableResult
    public func insertAssetAsOverlay(
        assetID: UUID,
        atTime requestedTime: Double,
        style: OverlayStyle = .cutaway
    ) async throws -> UUID {
        let itemID = UUID()
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last,
                  let asset = project.assets.first(where: { $0.id == assetID }) else { return }
            var timeline = project.timelines[timelineIndex]
            timeline.items = Self.retimed(timeline.items)
            let primaries = timeline.items.filter { $0.overlay == nil }
            guard !primaries.isEmpty else { return }
            let time = TimelineTiming.quantized(min(max(0, requestedTime), timeline.duration), frameRate: timeline.frameRate)
            guard let base = primaries.first(where: {
                time >= $0.timelineStart && time < $0.timelineStart + $0.timelineDuration
            }) ?? primaries.min(by: { abs($0.timelineStart - time) < abs($1.timelineStart - time) }) else { return }
            let sourceDuration = asset.kind == .video ? max(0.25, asset.metadata.duration ?? 5) : 4
            let available = max(0.25, timeline.duration - time)
            let duration = min(sourceDuration, available)
            let item = TimelineItem(
                id: itemID,
                assetID: asset.id,
                kind: asset.kind == .video ? .video : .photo,
                sourceDuration: duration,
                timelineStart: time,
                timelineDuration: duration,
                overlay: OverlaySettings(
                    style: style,
                    baseItemID: base.id,
                    startOffset: time - base.timelineStart
                ),
                explanation: ["Добавлено как связанный клип"]
            )
            timeline.items.append(item)
            timeline.items = Self.retimed(timeline.items)
            project.timelines[timelineIndex] = timeline
        }
        return itemID
    }

    /// Reorders only the primary storyline. Connected clips retain their base
    /// references and move with that base during magnetic retiming.
    public func movePrimaryTimelineItem(id: UUID, toPrimaryIndex requestedIndex: Int) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            var timeline = project.timelines[timelineIndex]
            var primaries = timeline.items.filter { $0.overlay == nil }
            let connected = timeline.items.filter { $0.overlay != nil }
            guard let oldIndex = primaries.firstIndex(where: { $0.id == id }) else { return }
            let item = primaries.remove(at: oldIndex)
            let newIndex = min(max(0, requestedIndex), primaries.count)
            primaries.insert(item, at: newIndex)
            timeline.items = Self.retimed(primaries + connected)
            project.timelines[timelineIndex] = timeline
        }
    }

    /// Moves a connected visual clip freely in time while preserving an iMovie-
    /// style connection to the nearest primary storyline clip.
    public func moveConnectedTimelineItem(id: UUID, toTimelineStart requestedStart: Double) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            var timeline = project.timelines[timelineIndex]
            timeline.items = Self.retimed(timeline.items)
            guard let index = timeline.items.firstIndex(where: { $0.id == id && $0.overlay != nil }) else { return }
            let primaries = timeline.items.filter { $0.overlay == nil }
            guard !primaries.isEmpty else { return }
            let maximum = max(0, timeline.duration - timeline.items[index].timelineDuration)
            let start = TimelineTiming.quantized(min(max(0, requestedStart), maximum), frameRate: timeline.frameRate)
            guard let base = primaries.first(where: {
                start >= $0.timelineStart && start < $0.timelineStart + $0.timelineDuration
            }) ?? primaries.min(by: { abs($0.timelineStart - start) < abs($1.timelineStart - start) }) else { return }
            timeline.items[index].timelineStart = start
            timeline.items[index].overlay?.baseItemID = base.id
            timeline.items[index].overlay?.startOffset = start - base.timelineStart
            timeline.items = Self.retimed(timeline.items)
            project.timelines[timelineIndex] = timeline
        }
    }

    /// Splits a visual clip at an exact timeline frame rather than at its
    /// midpoint. Returns the newly created right-hand clip when a split occurs.
    @discardableResult
    public func splitTimelineItem(id: UUID, atTimelineTime requestedTime: Double) async throws -> UUID? {
        var createdID: UUID?
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            createdID = TimelineMutationEngine.splitItem(in: &project.timelines[timelineIndex], id: id, atTimelineTime: requestedTime)
        }
        return createdID
    }

    /// Creates an independently movable audio region from a video's source
    /// audio and mutes the embedded copy to prevent double playback.
    @discardableResult
    public func detachAudio(from itemID: UUID) async throws -> UUID? {
        var createdID: UUID?
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            createdID = TimelineMutationEngine.detachAudio(in: &project.timelines[timelineIndex], from: itemID, assets: project.assets)
        }
        return createdID
    }

    @discardableResult
    public func insertMusicClip(trackID: UUID, atTimelineStart requestedStart: Double) async throws -> UUID? {
        let tracks = try await musicSystem.tracks()
        guard let track = tracks.first(where: { $0.id == trackID }) else { return nil }
        var createdID: UUID?
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            var timeline = project.timelines[timelineIndex]
            let start = TimelineTiming.quantized(min(max(0, requestedStart), max(0, timeline.duration - 0.05)), frameRate: timeline.frameRate)
            let duration = min(max(0.05, track.duration), max(0.05, timeline.duration - start))
            let id = UUID()
            var clips = timeline.effectiveAudioClips
            clips.append(TimelineAudioClip(
                id: id,
                trackID: track.id,
                title: track.title,
                role: .music,
                sourceDuration: duration,
                timelineStart: start,
                timelineDuration: duration,
                adjustments: AudioAdjustments(volume: timeline.music?.volume ?? 0.22)
            ))
            timeline.audioClips = clips
            timeline.music = nil
            project.timelines[timelineIndex] = timeline
            createdID = id
        }
        return createdID
    }

    public func updateAudioClip(
        id: UUID,
        timelineStart: Double? = nil,
        sourceStart: Double? = nil,
        timelineDuration: Double? = nil,
        adjustments: AudioAdjustments? = nil
    ) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            var timeline = project.timelines[timelineIndex]
            var clips = timeline.effectiveAudioClips
            guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
            if let timelineStart {
                let maximum = max(0, timeline.duration - clips[index].timelineDuration)
                clips[index].timelineStart = TimelineTiming.quantized(min(max(0, timelineStart), maximum), frameRate: timeline.frameRate)
                clips[index].attachedToItemID = nil
                clips[index].attachmentOffset = nil
            }
            if let sourceStart { clips[index].sourceStart = max(0, sourceStart) }
            if let timelineDuration {
                // The UI clamps extension to the real backing asset. Do not
                // clamp against the already-trimmed duration here: doing so
                // made it impossible to drag a shortened edge back out.
                let trimmedDuration = max(0.05, timelineDuration)
                // Audio edge dragging is a trim, not time stretching. Keeping
                // the old source duration made a shortened music clip speed up.
                clips[index].sourceDuration = trimmedDuration
                clips[index].timelineDuration = trimmedDuration
            }
            if let adjustments { clips[index].adjustments = adjustments }
            timeline.audioClips = clips
            project.timelines[timelineIndex] = timeline
        }
    }

    public func deleteAudioClip(id: UUID) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            var clips = project.timelines[timelineIndex].effectiveAudioClips
            clips.removeAll { $0.id == id }
            project.timelines[timelineIndex].audioClips = clips
        }
    }

    @discardableResult
    public func splitAudioClip(id: UUID, atTimelineTime requestedTime: Double) async throws -> UUID? {
        var createdID: UUID?
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            createdID = TimelineMutationEngine.splitAudioClip(in: &project.timelines[timelineIndex], id: id, atTimelineTime: requestedTime)
        }
        return createdID
    }

    /// Manual editing has no dependency on AI models or source analysis.
    public func createManualTimeline() async throws {
        try Task.checkCancellation()
        try await store.update { project in
            guard project.timelines.isEmpty else { return }
            let plan = StoryPlan(prompt: "Ручной монтаж", preset: .story,
                constraints: .init(targetDuration: 0), chapters: [])
            project.storyPlans.append(plan)
            var timeline = Timeline(storyPlanID: plan.id, items: [])
            timeline.automaticallySelectFrameRate = true
            project.timelines.append(timeline)
        }
    }

    /// Restores a complete edit snapshot. Used by the editor's Undo/Redo stack.
    public func replaceLatestTimeline(with timeline: Timeline) async throws {
        try await store.update { project in
            guard let index = project.timelines.indices.last else { return }
            var restored = timeline
            restored.items = Self.retimed(restored.items)
            project.timelines[index] = restored
        }
    }

    /// Applies deterministic editor commands only inside a brushed time range.
    /// Boundary clips are sliced first, which keeps the rest of the movie byte-for-
    /// byte equivalent at the Timeline model level.
    public static func requestsLocalShotReplacement(_ prompt: String) -> Bool {
        LocalShotReplacement.requestsReplacement(prompt)
    }

    @discardableResult
    public func applyEditorCommands(
        _ prompt: String,
        timelineRange: ClosedRange<Double>,
        preset: FilmPreset = .story,
        supplementalCommands: [EditorCommand] = [],
        modelRequestsReplacement: Bool = false
    ) async throws -> EditorCommandReport {
        let parsed = EditorCommandParser().parse("выбранный фрагмент, \(prompt)", preset: preset)
        let replacement = LocalShotReplacement.requestsReplacement(prompt)
            || (modelRequestsReplacement && LocalShotReplacement.allowsReplacement(prompt))
        // A replacement request must not be approximated by unrelated model
        // commands (the old brush changed EQ/fades and reported success).
        let commands = parsed + (replacement ? [] : EditorCommand.supplemental(supplementalCommands, to: parsed))
        return try await applyEditorCommands(commands, timelineRange: timelineRange, replacingShots: replacement)
    }

    /// Executes every supported editor action inside the brushed range.
    @discardableResult
    public func applyEditorCommands(
        _ commands: [EditorCommand],
        timelineRange: ClosedRange<Double>
    ) async throws -> EditorCommandReport {
        try await applyEditorCommands(commands, timelineRange: timelineRange, replacingShots: false)
    }

    private func applyEditorCommands(
        _ commands: [EditorCommand],
        timelineRange: ClosedRange<Double>,
        replacingShots: Bool
    ) async throws -> EditorCommandReport {
        let snapshot = await store.snapshot()
        guard let source = snapshot.manifest.timelines.last else {
            return EditorCommandReport(
                recognizedCount: commands.count,
                ignored: ["Для локальной AI-правки сначала нужен Timeline"]
            )
        }
        var resolvedCommands = commands
        var resolvedTracks: [LocalMusicTrack] = []
        for index in resolvedCommands.indices {
            guard case .setMusic(let requested?) = resolvedCommands[index] else { continue }
            let previous = source.effectiveAdaptiveSoundtrack?.segments.first(where: {
                $0.timelineStart <= timelineRange.lowerBound && $0.timelineEnd > timelineRange.lowerBound
            })?.directive.trackID ?? source.music?.trackID
            var directive = Self.musicDirective(requested, replacing: previous) ?? requested
            let tracks = try await tracksForResolving(directive)
            let exact = directive.trackID.flatMap { id in tracks.first { $0.id == id && $0.isPlayable } }
            guard let track = exact ?? LocalMusicSelector().select(for: directive, from: tracks,
                excluding: directive.preferDifferentTrack == true ? previous : nil) else {
                throw FreeToUseAPIError.providerFailure(lastMusicResolutionError ?? "Нет доступного аудиофайла для выделенного диапазона")
            }
            directive.trackID = track.id
            directive.trackTitle = track.title
            directive.bpm = track.bpm
            directive.preferDifferentTrack = nil
            resolvedCommands[index] = .setMusic(directive)
            resolvedTracks.append(contentsOf: tracks)
        }
        var baseline = source
        var replacementIDs: [UUID] = []
        if replacingShots {
            let slice = TimelineRangeSlicer.slice(source, for: timelineRange)
            baseline = try LocalShotReplacement.apply(to: slice.timeline, itemIDs: Set(slice.itemIDs), original: source, project: snapshot.manifest)
            replacementIDs = slice.itemIDs.filter { id in
                baseline.items.first { $0.id == id } != slice.timeline.items.first { $0.id == id }
            }
        }
        var result = Self.applyingLocalizedEditorCommands(
            resolvedCommands,
            to: baseline,
            timelineRange: timelineRange,
            assets: snapshot.manifest.assets
        )
        if replacingShots {
            result.report.recognizedCount += 1
            result.report.applied.insert("заменено фрагментов: \(replacementIDs.count); длительность сохранена", at: 0)
            result.report.affectedItemIDs = Array(Set(result.report.affectedItemIDs + replacementIDs)).sorted { $0.uuidString < $1.uuidString }
        }
        guard result.timeline != source else { return result.report }

        try Task.checkCancellation()
        try await store.update(ifRevision: snapshot.revision) { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            Self.appendCheckpoint(
                timeline: project.timelines[timelineIndex],
                reason: "Перед локальной правкой Волшебной кистью",
                to: &project
            )
            project.timelines[timelineIndex] = result.timeline
            Self.recordMusicCredit(from: result.timeline, tracks: resolvedTracks, in: &project)
        }
        return result.report
    }

    public func updateMusic(_ directive: MusicDirective?) async throws {
        let snapshot = await store.snapshot()
        let current = snapshot.manifest
        guard var timeline = current.timelines.last else { return }
        let previousTrackID = timeline.music?.trackID
        let requested = Self.musicDirective(directive, replacing: previousTrackID)
        var tracks = try await tracksForResolving(requested)
        timeline.music = requested
        timeline.adaptiveSoundtrack = nil
        if var resolved = requested {
            let exact = resolved.searchRequests?.first.flatMap { request in
                request.exactTrack ? tracks.first(where: { request.matches(title: $0.title, artist: $0.author) }) : nil
            }
            guard let track = exact ?? LocalMusicSelector().select(for: resolved, from: tracks,
                excluding: resolved.preferDifferentTrack == true ? previousTrackID : nil) ?? tracks.first else {
                throw FreeToUseAPIError.providerFailure(lastMusicResolutionError ?? "Нет доступного аудиофайла")
            }
            resolved.trackID = track.id
            resolved.trackTitle = track.title
            resolved.bpm = track.bpm
            resolved.preferDifferentTrack = nil
            timeline.music = resolved
            timeline = SoundtrackEditorialPolicy.applying(track: track,
                structure: await MusicStructureCache.shared.structure(for: track), to: timeline, analyses: current.analyses)
            if requested?.trackID == nil, var plan = current.storyPlans.first(where: { $0.id == timeline.storyPlanID }) {
                if plan.directorBrief != nil { plan.directorBrief?.musicPolicy = .matchVideo }
                try await acquireSectionMusic(timelines: [timeline], stories: [StoryPlanVariant(plan: plan, strategy: "music-update", seedScore: 0)], analyses: current.analyses)
                tracks = try await musicSystem.tracks()
                timeline = await Self.applyingAdaptiveSoundtrack(to: timeline, plan: plan, tracks: tracks, analyses: current.analyses)
            }
        }
        try Task.checkCancellation()
        try await store.update(ifRevision: snapshot.revision) { project in
            guard let index = project.timelines.firstIndex(where: { $0.id == timeline.id }) else { return }
            project.timelines[index] = timeline
            Self.recordMusicCredit(from: timeline, tracks: tracks, in: &project)
        }
    }

    public func musicSearchNotice() -> String? { lastMusicResolutionError }

    public func musicTracks() async throws -> [LocalMusicTrack] {
        try await musicSystem.tracks()
    }

    public func musicLibraryStatus() async -> MusicLibraryStatus {
        await musicSystem.status()
    }

    @discardableResult
    public func importMusicFolder(_ folderURL: URL) async throws -> [LocalMusicTrack] {
        let audioURLs = importer.expandAudio([folderURL])
        for audioURL in audioURLs {
            do {
                _ = try await musicLibrary.importUserTrack(audioURL)
            } catch MusicLibraryError.duplicateSource {
                continue
            }
        }
        return try await musicSystem.tracks()
    }

    /// Resolves a user's request even before a timeline exists. The official
    /// provider is contacted when the local Free To Use catalog is empty or
    /// when the user explicitly asks for another track.
    @discardableResult
    public func prepareMusicTrack(for directive: MusicDirective) async throws -> LocalMusicTrack {
        let tracks = try await tracksForResolving(directive)
        guard let track = LocalMusicSelector().select(for: directive, from: tracks) else {
            throw FreeToUseAPIError.providerFailure(
                lastMusicResolutionError ?? FreeToUseAPIError.noFreeTrack.localizedDescription
            )
        }
        return track
    }

    /// Resolves a persisted music intent left behind by an earlier offline or
    /// failed provider request. This lets an existing project heal itself on
    /// the next open instead of requiring the user to repeat the instruction.
    @discardableResult
    public func resolvePendingMusic() async throws -> LocalMusicTrack? {
        let current = await store.manifest
        guard let timeline = current.timelines.last, var directive = timeline.music else { return nil }
        let previousTrackID = directive.trackID
        if directive.preferDifferentTrack != true,
           let trackID = directive.trackID,
           let existing = try await musicSystem.tracks().first(where: { $0.id == trackID }),
           FileManager.default.fileExists(atPath: existing.localFileURL.path) {
            return existing
        }
        if directive.preferDifferentTrack != true,
           let trackID = directive.trackID,
           let legacy = try await LocalMusicLibrary.shared.tracks().first(where: { $0.id == trackID }),
           FileManager.default.fileExists(atPath: legacy.localFileURL.path) {
            return try await musicLibrary.importExistingTrack(legacy)
        }

        directive.trackID = nil
        directive.trackTitle = nil
        let tracks = try await tracksForResolving(directive)
        guard let track = LocalMusicSelector().select(
            for: directive,
            from: tracks,
            excluding: directive.preferDifferentTrack == true ? previousTrackID : nil
        ) else {
            throw FreeToUseAPIError.providerFailure(
                lastMusicResolutionError ?? "в локальной библиотеке нет доступного аудиофайла"
            )
        }
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            var resolved = directive
            resolved.trackID = track.id
            resolved.trackTitle = track.title
            resolved.bpm = track.bpm
            resolved.preferDifferentTrack = nil
            project.timelines[timelineIndex].music = resolved
            project.timelines[timelineIndex] = MusicBeatSynchronizer()
                .refreshingStructure(in: project.timelines[timelineIndex], for: track)
            Self.recordMusicCredit(from: project.timelines[timelineIndex], tracks: tracks, in: &project)
        }
        return track
    }

    @discardableResult
    public func prepareOnlineMusicLibrary() async -> [LocalMusicTrack] {
        await musicSystem.prepareOnlineCatalog()
    }

    @available(*, deprecated, renamed: "prepareOnlineMusicLibrary()")
    @discardableResult
    public func prepareFreeToUseMusicLibrary() async throws -> [LocalMusicTrack] {
        await prepareOnlineMusicLibrary()
    }

    public func removeMusicTrack(id: UUID) async throws {
        try await musicLibrary.remove(id: id)
        try await store.update { project in
            for index in project.timelines.indices {
                if project.timelines[index].music?.trackID == id {
                    project.timelines[index].music = nil
                    project.timelines[index].adaptiveSoundtrack = nil
                } else if project.timelines[index].adaptiveSoundtrack?.segments.contains(where: {
                    $0.directive.trackID == id
                }) == true {
                    // Keep the still-playable master track and fall back to a
                    // single soundtrack when any secondary region disappears.
                    project.timelines[index].adaptiveSoundtrack = nil
                }
            }
        }
    }

    public func updateOriginalAudioVolume(_ volume: Double) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            project.timelines[timelineIndex] = SourceAudioMixPolicy.applyingRequestedVolume(volume, to: project.timelines[timelineIndex])
        }
    }

    @discardableResult
    public func applyEditorCommands(
        _ prompt: String,
        selectedItemID: UUID? = nil,
        selectedCandidateID: UUID? = nil,
        preset: FilmPreset = .story,
        createCheckpoint: Bool = false
    ) async throws -> EditorCommandReport {
        let commands = EditorCommandParser().parse(prompt, preset: preset)
        return try await applyEditorCommands(
            commands,
            selectedItemID: selectedItemID,
            selectedCandidateID: selectedCandidateID,
            createCheckpoint: createCheckpoint
        )
    }

    @discardableResult
    public func applyEditorCommands(
        _ commands: [EditorCommand],
        selectedItemID: UUID? = nil,
        selectedCandidateID: UUID? = nil,
        createCheckpoint: Bool = false
    ) async throws -> EditorCommandReport {
        guard !commands.isEmpty else { return EditorCommandReport(recognizedCount: 0) }
        let snapshot = await store.snapshot()
        var current = snapshot.manifest
        guard let source = current.timelines.last else {
            return EditorCommandReport(
                recognizedCount: commands.count,
                ignored: ["Для применения монтажных команд сначала нужен Timeline"]
            )
        }
        current = try await preparingDirectorBackgrounds(commands, in: current, timeline: source)
        let previousTrackID = source.music?.trackID
        let parsedMusic = commands.reversed().compactMap { command -> MusicDirective? in
            if case .setMusic(let directive?) = command { return directive }
            return nil
        }.first
        let requestedMusic = Self.musicDirective(parsedMusic, replacing: previousTrackID)
        var tracks = try await tracksForResolving(requestedMusic)
        let result = EditorCommandExecutor().apply(
            commands,
            to: source,
            selectedItemID: selectedItemID,
            selectedCandidateID: selectedCandidateID,
            assets: current.assets, analyses: current.analyses
        )
        var timeline = Self.clampedToAvailableMedia(result.timeline, assets: current.assets)
        if var directive = timeline.music, directive.trackID == nil {
            if requestedMusic?.preferDifferentTrack == true {
                directive.preferDifferentTrack = true
            }
            if let track = LocalMusicSelector().select(
                for: directive,
                from: tracks,
                excluding: directive.preferDifferentTrack == true ? previousTrackID : nil
            ) {
                directive.trackID = track.id
                directive.trackTitle = track.title
                directive.bpm = track.bpm
                directive.preferDifferentTrack = nil
                timeline.music = directive
            }
        }
        if timeline.music?.preferDifferentTrack == true, previousTrackID != nil {
            timeline.music = source.music
        }
        if let trackID = timeline.music?.trackID,
           trackID != previousTrackID,
           let track = tracks.first(where: { $0.id == trackID }) {
            timeline = MusicBeatSynchronizer().refreshingStructure(in: timeline, for: track)
        }

        if requestedMusic != nil, timeline.music != nil, requestedMusic?.trackID == nil,
           var plan = current.storyPlans.first(where: { $0.id == timeline.storyPlanID }) {
            if plan.directorBrief != nil { plan.directorBrief?.musicPolicy = .matchVideo }
            try await acquireSectionMusic(timelines: [timeline], stories: [StoryPlanVariant(plan: plan, strategy: "music-update", seedScore: 0)], analyses: current.analyses)
            tracks = try await musicSystem.tracks()
            timeline = await Self.applyingAdaptiveSoundtrack(to: timeline, plan: plan, tracks: tracks, analyses: current.analyses)
        }
        var report = result.report
        let replacementFailed = requestedMusic?.preferDifferentTrack == true
            && previousTrackID != nil
            && timeline.music?.trackID == previousTrackID
        if requestedMusic != nil, timeline.music?.trackID == nil || replacementFailed {
            report.applied.removeAll { $0.hasPrefix("музыка «") }
            let reason = lastMusicResolutionError ?? "в локальной библиотеке нет доступного аудиофайла"
            let action = replacementFailed ? "не изменён" : "не добавлен"
            report.ignored.append("саундтрек \(action): \(reason)")
        }
        guard timeline != source else {
            report.applied = []
            if report.ignored.isEmpty {
                report.ignored.append("Запрошенные параметры уже установлены")
            }
            report.affectedItemIDs = []
            return report
        }

        try Task.checkCancellation()
        try await store.update(ifRevision: snapshot.revision) { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            if createCheckpoint {
                Self.appendCheckpoint(
                    timeline: project.timelines[timelineIndex],
                    reason: "Перед применением AI editing tools",
                    to: &project
                )
            }
            project.assets = current.assets
            project.timelines[timelineIndex] = timeline
            Self.recordMusicCredit(from: timeline, tracks: tracks, in: &project)
        }
        return report
    }

    /// P8 production entry point. Planning and execution happen against one
    /// immutable project snapshot; the resulting Timeline is committed once,
    /// so a natural-language request maps to one checkpoint/Undo operation.
    @discardableResult
    public func applyNaturalLanguageEdit(
        _ request: String,
        selectedItemID: UUID? = nil,
        playheadTime: Double? = nil,
        supplementalCommands: [EditorCommand] = [],
        createCheckpoint: Bool = true,
        recordHistory: Bool = true
    ) async throws -> NaturalLanguageEditResult {
        let snapshot = await store.snapshot()
        var current = snapshot.manifest
        guard let timeline = current.timelines.last else {
            throw NaturalLanguageDirectorError.timelineUnavailable
        }
        let projectStyle = current.storyPlans.last?.autonomousDecision?.projectStyle
            ?? AutonomousProjectStyleEngine().infer(
                assets: current.assets,
                analyses: current.analyses,
                fallbackPreset: current.storyPlans.last?.preset ?? .story,
                events: current.events
            )
        let deviceTaste = await personalTasteStore.profile()
        let taste = deviceTaste.totalSignalCount > 0
            ? deviceTaste
            : (current.personalTasteProfile ?? deviceTaste)
        var input = NaturalLanguageDirectorInput(
            userRequest: request,
            currentProject: current,
            timeline: timeline,
            tasteProfile: taste,
            styleProfile: projectStyle,
            eventGraph: DirectorEventGraph(events: current.events),
            selectedItemID: selectedItemID,
            playheadTime: playheadTime
        )
        let director = NaturalLanguageDirector()
        let plan = director.plan(input: input, supplementalCommands: supplementalCommands)
        current = try await preparingDirectorBackgrounds(plan.commands, in: current, timeline: timeline)
        input.currentProject = current
        input.assets = current.assets
        var result = director.execute(plan: plan, input: input, recordHistory: recordHistory)

        let requestedMusic = plan.commands.reversed().compactMap { command -> MusicDirective? in
            if case .setMusic(let directive?) = command { return directive }
            return nil
        }.first
        if result.committed, var directive = result.timeline.music,
           directive.trackID == nil, requestedMusic != nil {
            let previousTrackID = timeline.music?.trackID
            let tracks = try await tracksForResolving(directive)
            if let track = LocalMusicSelector().select(
                for: directive,
                from: tracks,
                excluding: directive.preferDifferentTrack == true ? previousTrackID : nil
            ) {
                directive.trackID = track.id
                directive.trackTitle = track.title
                directive.bpm = track.bpm
                directive.preferDifferentTrack = nil
                result.timeline.music = directive
                result.timeline = MusicBeatSynchronizer().refreshingStructure(in: result.timeline, for: track)
                result.invalidation = TimelineInvalidationPlanner.plan(from: timeline, to: result.timeline)
            } else {
                result.timeline.music = timeline.music
                let reason = lastMusicResolutionError ?? "доступный локальный трек не найден"
                result.commandReport.ignored.append("саундтрек не изменён: \(reason)")
                result.userSummary += " Саундтрек не изменён: \(reason)."
            }
        }

        guard result.committed else { return result }
        try Task.checkCancellation()
        try await store.update(ifRevision: snapshot.revision) { project in
            guard let index = project.timelines.indices.last else { return }
            if createCheckpoint {
                Self.appendCheckpoint(
                    timeline: project.timelines[index],
                    reason: "Перед natural-language правкой: \(request.prefix(80))",
                    to: &project
                )
            }
            project.assets = current.assets
            project.timelines[index] = result.timeline
        }
        return result
    }

    public func moveTimelineItem(id: UUID, offset: Int) async throws {
        guard offset != 0 else { return }
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last,
                  let oldIndex = project.timelines[timelineIndex].items.firstIndex(where: { $0.id == id }) else { return }
            Self.moveTimelineItem(in: &project.timelines[timelineIndex], from: oldIndex, to: oldIndex + offset)
        }
    }

    public func moveTimelineItem(id: UUID, toIndex requestedIndex: Int) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last,
                  let oldIndex = project.timelines[timelineIndex].items.firstIndex(where: { $0.id == id }) else { return }
            Self.moveTimelineItem(in: &project.timelines[timelineIndex], from: oldIndex, to: requestedIndex)
        }
    }

    public func deleteTimelineItem(id: UUID) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            project.timelines[timelineIndex].items.removeAll { $0.id == id }
            project.timelines[timelineIndex].telemetryItems?.removeAll { $0.targetClipID == id }
            project.timelines[timelineIndex].effects?.removeAll { $0.targetClipID == id }
            project.timelines[timelineIndex].titleItems?.removeAll { $0.targetClipID == id }
            project.timelines[timelineIndex].transitionItems?.removeAll { $0.outgoingClipID == id || $0.incomingClipID == id }
            project.timelines[timelineIndex].items = Self.retimed(project.timelines[timelineIndex].items)
        }
    }

    // MARK: - Independent effects, titles and transitions

    @discardableResult
    public func addEffectTimelineItem(
        type: TimelineEffectType,
        startTime: Double,
        duration: Double,
        targetClipID: UUID? = nil,
        intensity: Double? = nil,
        parameters: [EffectParameter]? = nil,
        explanation: [String] = ["Добавлено вручную"]
    ) async throws -> UUID? {
        var insertedID: UUID?
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            let timeline = project.timelines[timelineIndex]
            guard targetClipID == nil || timeline.items.contains(where: { $0.id == targetClipID }) else { return }
            let start = min(max(0, startTime), max(0, timeline.duration - 0.05))
            let item = EffectTimelineItem(
                effectType: type,
                startTime: start,
                duration: min(max(0.05, duration), max(0.05, timeline.duration - start)),
                parameters: parameters ?? EffectPresetRegistry.preset(for: type).defaultParameters,
                intensity: intensity,
                targetClipID: targetClipID,
                stackOrder: EffectStackEngine.stack(in: timeline, for: targetClipID).count,
                explanation: explanation
            )
            project.timelines[timelineIndex].effects = timeline.effectiveEffects + [item]
            insertedID = item.id
        }
        return insertedID
    }

    public func updateEffectTimelineItem(
        id: UUID,
        startTime: Double? = nil,
        duration: Double? = nil,
        intensity: Double? = nil,
        enabled: Bool? = nil,
        parameters: [EffectParameter]? = nil,
        keyframes: [EffectKeyframe]? = nil
    ) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last,
                  let itemIndex = project.timelines[timelineIndex].effectiveEffects.firstIndex(where: { $0.id == id }) else { return }
            var items = project.timelines[timelineIndex].effectiveEffects
            var item = items[itemIndex]
            let timelineDuration = project.timelines[timelineIndex].duration
            if let startTime { item.startTime = min(max(0, startTime), max(0, timelineDuration - 0.05)) }
            if let duration { item.duration = min(max(0.05, duration), max(0.05, timelineDuration - item.startTime)) }
            if let intensity { item.intensity = min(max(0, intensity), 1) }
            if let enabled { item.enabled = enabled }
            if let parameters { item.parameters = parameters }
            if let keyframes { item.keyframes = keyframes.sorted { $0.time < $1.time } }
            items[itemIndex] = item
            project.timelines[timelineIndex].effects = items
        }
    }

    public func deleteEffectTimelineItem(id: UUID) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            project.timelines[timelineIndex].effects?.removeAll { $0.id == id }
        }
    }

    public func duplicateEffectTimelineItem(id: UUID) async throws -> UUID? {
        var duplicateID: UUID?
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last,
                  var item = project.timelines[timelineIndex].effectiveEffects.first(where: { $0.id == id }) else { return }
            item.id = UUID()
            // Duplicating one component does not duplicate the whole preset,
            // so it must become an ordinary standalone effect rather than
            // visually joining the source preset instance.
            item.effectStackPresetID = nil
            item.effectStackPresetInstanceID = nil
            item.startTime = min(max(0, project.timelines[timelineIndex].duration - item.duration), item.startTime + 0.25)
            project.timelines[timelineIndex].effects = project.timelines[timelineIndex].effectiveEffects + [item]
            duplicateID = item.id
        }
        return duplicateID
    }

    @discardableResult
    public func addTitleTimelineItem(
        kind: TitleTimelineKind,
        templateID: String? = nil,
        text: String,
        additionalText: String? = nil,
        callToAction: String? = nil,
        startTime: Double,
        duration: Double,
        style: TitleStyle? = nil,
        words: [CaptionWord] = [],
        targetClipID: UUID? = nil,
        explanation: [String] = ["Добавлено вручную"]
    ) async throws -> UUID? {
        var insertedID: UUID?
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            let timeline = project.timelines[timelineIndex]
            guard targetClipID == nil || timeline.items.contains(where: { $0.id == targetClipID }) else { return }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            let start = min(max(0, startTime), max(0, timeline.duration - 0.05))
            let template = TitleTemplateRegistry.template(id: templateID) ?? TitleTemplateRegistry.defaultTemplate(for: kind)
            let item = TitleTimelineItem(
                kind: template?.kind ?? kind,
                templateID: template?.id,
                text: clean,
                additionalText: additionalText,
                callToAction: callToAction,
                startTime: start,
                duration: min(max(0.05, duration), max(0.05, timeline.duration - start)),
                style: style ?? template?.defaultStyle ?? TitleStyle(),
                words: words,
                activeWordHighlighting: (template?.kind ?? kind) == .wordLevelCaptions,
                targetClipID: targetClipID,
                explanation: explanation
            )
            project.timelines[timelineIndex].titleItems = timeline.effectiveTitleItems + [item]
            insertedID = item.id
        }
        return insertedID
    }

    public func updateTitleTimelineItem(
        id: UUID,
        text: String? = nil,
        additionalText: String? = nil,
        callToAction: String? = nil,
        startTime: Double? = nil,
        duration: Double? = nil,
        style: TitleStyle? = nil,
        animation: TitleAnimation? = nil,
        words: [CaptionWord]? = nil,
        enabled: Bool? = nil
    ) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last,
                  let itemIndex = project.timelines[timelineIndex].effectiveTitleItems.firstIndex(where: { $0.id == id }) else { return }
            var items = project.timelines[timelineIndex].effectiveTitleItems
            var item = items[itemIndex]
            let timelineDuration = project.timelines[timelineIndex].duration
            if let text {
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { item.text = clean }
            }
            if let additionalText { item.additionalText = additionalText }
            if let callToAction { item.callToAction = callToAction }
            if let startTime { item.startTime = min(max(0, startTime), max(0, timelineDuration - 0.05)) }
            if let duration { item.duration = min(max(0.05, duration), max(0.05, timelineDuration - item.startTime)) }
            if let style { item.style = style }
            if let animation { item.animation = animation }
            if let words { item.words = words.sorted { $0.start < $1.start } }
            if let enabled { item.enabled = enabled }
            SpeechSubtitleBuilder.preservingManualTiming(&item, previous: items[itemIndex], timeline: project.timelines[timelineIndex])
            if item != items[itemIndex] { item.userEdited = true }
            items[itemIndex] = item
            project.timelines[timelineIndex].titleItems = items
        }
    }

    public func deleteTitleTimelineItem(id: UUID) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            if let title = project.timelines[timelineIndex].effectiveTitleItems.first(where: { $0.id == id }) {
                SpeechSubtitleBuilder.suppress(title, in: &project.timelines[timelineIndex])
            }
            project.timelines[timelineIndex].titleItems?.removeAll { $0.id == id }
        }
    }

    @discardableResult
    public func addTransitionTimelineItem(
        style: TransitionStyle,
        outgoingClipID: UUID,
        incomingClipID: UUID,
        duration: Double = 0.45,
        explanation: [String] = ["Добавлено вручную"]
    ) async throws -> UUID? {
        var insertedID: UUID?
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last,
                  let incomingIndex = project.timelines[timelineIndex].items.firstIndex(where: { $0.id == incomingClipID }),
                  project.timelines[timelineIndex].items.contains(where: { $0.id == outgoingClipID }) else { return }
            let start = project.timelines[timelineIndex].items[incomingIndex].timelineStart
            let transition = TimelineTransitionItem(
                style: style,
                outgoingClipID: outgoingClipID,
                incomingClipID: incomingClipID,
                startTime: start,
                duration: duration,
                intensity: TransitionPresetRegistry.preset(for: style).defaultIntensity,
                parameters: TransitionPresetRegistry.preset(for: style).defaultParameters,
                direction: TransitionPresetRegistry.preset(for: style).defaultDirection,
                easing: TransitionPresetRegistry.preset(for: style).defaultEasing,
                explanation: explanation
            )
            project.timelines[timelineIndex].transitionItems?.removeAll { $0.incomingClipID == incomingClipID }
            project.timelines[timelineIndex].transitionItems = project.timelines[timelineIndex].effectiveTransitionItems + [transition]
            project.timelines[timelineIndex].items[incomingIndex].transition = style.rawValue
            insertedID = transition.id
        }
        return insertedID
    }

    public func deleteTransitionTimelineItem(id: UUID) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last,
                  let transition = project.timelines[timelineIndex].effectiveTransitionItems.first(where: { $0.id == id }) else { return }
            project.timelines[timelineIndex].transitionItems?.removeAll { $0.id == id }
            if let incomingIndex = project.timelines[timelineIndex].items.firstIndex(where: { $0.id == transition.incomingClipID }) {
                project.timelines[timelineIndex].items[incomingIndex].transition = nil
            }
        }
    }

    public func updateTransitionTimelineItem(
        id: UUID,
        style: TransitionStyle? = nil,
        duration: Double? = nil,
        enabled: Bool? = nil,
        intensity: Double? = nil,
        parameters: [EffectParameter]? = nil,
        direction: TransitionDirection? = nil,
        easing: KeyframeEasing? = nil
    ) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last,
                  let itemIndex = project.timelines[timelineIndex].effectiveTransitionItems.firstIndex(where: { $0.id == id }) else { return }
            var items = project.timelines[timelineIndex].effectiveTransitionItems
            var item = items[itemIndex]
            if let style {
                item.style = style
                let preset = TransitionPresetRegistry.preset(for: style)
                item.intensity = preset.defaultIntensity
                item.parameters = preset.defaultParameters
                item.direction = preset.defaultDirection
                item.easing = preset.defaultEasing
            }
            if let duration { item.duration = min(max(0.08, duration), 4) }
            if let enabled { item.enabled = enabled }
            if let intensity { item.intensity = min(max(0, intensity), 1) }
            if let parameters { item.parameters = parameters }
            if let direction { item.direction = direction }
            if let easing { item.easing = easing }
            items[itemIndex] = item
            project.timelines[timelineIndex].transitionItems = items
            if let incomingIndex = project.timelines[timelineIndex].items.firstIndex(where: { $0.id == item.incomingClipID }) {
                project.timelines[timelineIndex].items[incomingIndex].transition = item.enabled ? item.style.rawValue : nil
            }
        }
    }

    public func addTelemetryItem(
        sourceID: UUID,
        timelineStart: Double = 0,
        timelineDuration: Double? = nil,
        settings: TelemetryOverlaySettings = TelemetryOverlaySettings()
    ) async throws -> UUID? {
        var insertedID: UUID?
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last,
                  let source = project.effectiveTelemetrySources.first(where: { $0.id == sourceID }) else { return }
            let timeline = project.timelines[timelineIndex]
            let requested = timelineDuration ?? min(max(0.05, source.duration), max(0.05, timeline.duration - timelineStart))
            let item = TimelineTelemetryItem(
                sourceID: source.id,
                linkedAssetID: source.linkedAssetID,
                sourceStart: 0,
                timelineStart: min(max(0, timelineStart), max(0, timeline.duration - 0.05)),
                timelineDuration: min(max(0.05, requested), max(0.05, timeline.duration - timelineStart)),
                syncOffset: source.synchronization.offsetSeconds,
                settings: settings,
                explanation: ["Независимый слой Telemetry Engine"]
            )
            project.timelines[timelineIndex].telemetryItems = project.timelines[timelineIndex].effectiveTelemetryItems + [item]
            insertedID = item.id
        }
        return insertedID
    }

    /// Adds telemetry to a concrete edited video fragment. The source is
    /// resolved from that fragment's asset and is never selected independently
    /// by the widget browser.
    public func addTelemetryItem(
        attachedTo clipID: UUID,
        settings: TelemetryOverlaySettings = TelemetryOverlaySettings()
    ) async throws -> UUID? {
        var insertedID: UUID?
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last,
                  let clip = project.timelines[timelineIndex].items.first(where: {
                      $0.id == clipID && $0.kind == .video && $0.assetID != nil
                  }),
                  let assetID = clip.assetID else { return }
            let requestedKind = settings.resolvedWidgets.first?.kind
            let source = requestedKind.flatMap {
                TelemetrySourceSelector().bestSource(for: $0, linkedAssetID: assetID, sources: project.effectiveTelemetrySources)
            } ?? TelemetrySourceSelector().bestGeneralSource(linkedAssetID: assetID, sources: project.effectiveTelemetrySources)
            let analyzedTelemetry = project.analyses.first(where: { $0.assetID == assetID })?.telemetry
            guard let summary = source?.summary ?? analyzedTelemetry,
                  summary.hasTelemetry,
                  !settings.resolvedWidgets.isEmpty,
                  settings.resolvedWidgets.allSatisfy({ summary.supports($0.kind, presentation: $0.effectivePresentation) }) else { return }

            let item = TimelineTelemetryItem(
                targetClipID: clip.id,
                sourceID: source?.id,
                linkedAssetID: assetID,
                sourceStart: clip.sourceStart,
                timelineStart: clip.timelineStart,
                timelineDuration: clip.timelineDuration,
                syncOffset: source?.synchronization.offsetSeconds ?? 0,
                settings: settings,
                explanation: ["Телеметрия фрагмента \(clip.id.uuidString)"]
            )
            project.timelines[timelineIndex].telemetryItems = project.timelines[timelineIndex].effectiveTelemetryItems + [item]
            insertedID = item.id
        }
        return insertedID
    }

    public func updateTelemetryItem(
        id: UUID,
        sourceStart: Double? = nil,
        timelineStart: Double? = nil,
        timelineDuration: Double? = nil,
        syncOffset: Double? = nil,
        settings: TelemetryOverlaySettings? = nil,
        locked: Bool? = nil
    ) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last,
                  let itemIndex = project.timelines[timelineIndex].effectiveTelemetryItems.firstIndex(where: { $0.id == id }) else { return }
            var items = project.timelines[timelineIndex].effectiveTelemetryItems
            var item = items[itemIndex]
            if let sourceStart { item.sourceStart = max(0, sourceStart) }
            if let timelineStart {
                let clampedStart = min(max(0, timelineStart), max(0, project.timelines[timelineIndex].duration - 0.05))
                item.timelineStart = clampedStart
                if let clip = Self.telemetryTargetClip(at: clampedStart, in: project.timelines[timelineIndex]),
                   let assetID = clip.assetID {
                    let source = project.effectiveTelemetrySources.first(where: { $0.linkedAssetID == assetID })
                    let analyzedTelemetry = project.analyses.first(where: { $0.assetID == assetID })?.telemetry
                    if source?.summary.hasTelemetry == true || analyzedTelemetry?.hasTelemetry == true {
                        item.targetClipID = clip.id
                        item.sourceID = source?.id
                        item.linkedAssetID = assetID
                        item.sourceStart = clip.sourceTime(atTimelineTime: clampedStart)
                        item.syncOffset = source?.synchronization.offsetSeconds ?? 0
                        item.timelineDuration = min(item.timelineDuration, max(0.05, clip.timelineStart + clip.timelineDuration - clampedStart))
                    }
                }
            }
            if let timelineDuration { item.timelineDuration = min(max(0.05, timelineDuration), max(0.05, project.timelines[timelineIndex].duration - item.timelineStart)) }
            if let syncOffset { item.syncOffset = syncOffset.isFinite ? syncOffset : item.syncOffset }
            if let settings { item.settings = settings }
            if let locked { item.locked = locked }
            items[itemIndex] = item
            project.timelines[timelineIndex].telemetryItems = items
        }
    }

    public func duplicateTelemetryItem(id: UUID) async throws -> UUID? {
        var duplicateID: UUID?
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last,
                  var item = project.timelines[timelineIndex].effectiveTelemetryItems.first(where: { $0.id == id }) else { return }
            item.id = UUID()
            item.timelineStart = min(max(0, project.timelines[timelineIndex].duration - item.timelineDuration), item.timelineStart + 0.25)
            item.explanation.append("Копия слоя телеметрии")
            project.timelines[timelineIndex].telemetryItems = project.timelines[timelineIndex].effectiveTelemetryItems + [item]
            duplicateID = item.id
        }
        return duplicateID
    }

    public func deleteTelemetryItem(id: UUID) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            project.timelines[timelineIndex].telemetryItems?.removeAll { $0.id == id }
        }
    }

    public func updateTelemetrySource(
        id: UUID,
        linkedAssetID: UUID? = nil,
        updateLinkedAsset: Bool = false,
        synchronization: TelemetrySynchronization? = nil
    ) async throws {
        try await store.update { project in
            guard let index = project.effectiveTelemetrySources.firstIndex(where: { $0.id == id }) else { return }
            var sources = project.effectiveTelemetrySources
            if updateLinkedAsset { sources[index].linkedAssetID = linkedAssetID }
            if let synchronization { sources[index].synchronization = synchronization }
            project.telemetrySources = sources
            if let synchronization {
                for timelineIndex in project.timelines.indices {
                    var items = project.timelines[timelineIndex].effectiveTelemetryItems
                    for itemIndex in items.indices where items[itemIndex].sourceID == id {
                        items[itemIndex].syncOffset = synchronization.offsetSeconds
                        items[itemIndex].explanation.append("Синхронизация источника: \(synchronization.method.localizedTitle)")
                    }
                    project.timelines[timelineIndex].telemetryItems = items
                }
            }
        }
    }

    public func applyCSVTelemetryMapping(id: UUID, mapping: [String: TelemetryCSVField]) async throws {
        try await store.update { project in
            guard let index = project.effectiveTelemetrySources.firstIndex(where: { $0.id == id }) else { return }
            var sources = project.effectiveTelemetrySources
            sources[index] = TelemetryEngine().applyingCSVMapping(to: sources[index], mapping: mapping)
            project.telemetrySources = sources
        }
    }

    private static func telemetryTargetClip(at timelineTime: Double, in timeline: Timeline) -> TimelineItem? {
        let active = timeline.items.filter {
            $0.kind == .video && $0.assetID != nil &&
            timelineTime >= $0.timelineStart && timelineTime < $0.timelineStart + $0.timelineDuration
        }
        return active.last(where: { $0.overlay != nil }) ?? active.first(where: { $0.overlay == nil }) ?? active.last
    }

    @discardableResult
    public func importMedia(_ urls: [URL], progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> [String] {
        let current = await store.manifest
        let scan = importer.scanInputs(urls)
        let visualURLs = importer.expand(scan.files)
        let audioURLs = importer.expandAudio(scan.files)
        let telemetryURLs = importer.expandTelemetry(scan.files)
        let recognized = Set(visualURLs + audioURLs + telemetryURLs)
        var report = MediaImportReport()
        report.entries = scan.failures + scan.files.filter { !recognized.contains($0) }.map {
            .init(url: $0, outcome: .failed, message: "Формат не поддерживается. Добавьте видео, фото, аудио или файл телеметрии.")
        }
        let results = await importer.importAssets(from: visualURLs, existing: current.assets, conversionDirectory: store.packageURL.appendingPathComponent("Media/Converted"), progress: progress)
        var imported: [MediaAsset] = []
        var seenHashes = Set(current.assets.map(\.contentHash))
        try Task.checkCancellation()
        for (url, result) in zip(visualURLs, results) {
            switch result {
            case .success(let asset):
                imported.append(asset)
                let duplicate = !seenHashes.insert(asset.contentHash).inserted
                report.entries.append(.init(url: url, outcome: duplicate ? .duplicate : .added,
                    message: duplicate ? "Уже в проекте — повторная копия не добавлена" : "Добавлено"))
            case .failure(let error):
                report.entries.append(.init(url: url, outcome: .failed, message: error.localizedDescription))
            }
        }
        for audioURL in audioURLs {
            do {
                _ = try await musicLibrary.importUserTrack(audioURL)
                report.entries.append(.init(url: audioURL, outcome: .added, message: "Добавлено в музыку"))
            } catch MusicLibraryError.duplicateSource {
                report.entries.append(.init(url: audioURL, outcome: .duplicate, message: "Уже в музыкальной библиотеке"))
            } catch {
                report.entries.append(.init(url: audioURL, outcome: .failed, message: error.localizedDescription))
            }
        }
        let unique = Dictionary(imported.map { ($0.contentHash, $0) }, uniquingKeysWith: { old, _ in old }).values
        let availableAssets = current.assets + unique
        var telemetrySources: [TelemetrySource] = []
        for (index, telemetryURL) in telemetryURLs.enumerated() {
            do {
                progress?(ImportProgress(completed: index, total: telemetryURLs.count, currentName: "Телеметрия · \(telemetryURL.lastPathComponent)"))
                var source = try await TelemetryEngine().importSource(url: telemetryURL)
                if let startDate = source.startDate,
                   let closest = availableAssets.compactMap({ asset in
                       asset.kind == .video ? asset.metadata.creationDate.map { (asset, $0) } : nil
                   }).min(by: {
                       abs($0.1.timeIntervalSince(startDate)) < abs($1.1.timeIntervalSince(startDate))
                   }),
                   let videoDate = closest.0.metadata.creationDate,
                   abs(videoDate.timeIntervalSince(startDate)) < 12 * 60 * 60 {
                    source.linkedAssetID = closest.0.id
                    source.synchronization = TelemetryEngine().synchronize(source: source, with: closest.0)
                }
                telemetrySources.append(source)
                let duplicate = current.effectiveTelemetrySources.contains { $0.originalURL?.standardizedFileURL == telemetryURL.standardizedFileURL }
                report.entries.append(.init(url: telemetryURL, outcome: duplicate ? .duplicate : .added,
                    message: duplicate ? "Телеметрия уже в проекте" : "Телеметрия добавлена"))
            } catch {
                report.entries.append(.init(url: telemetryURL, outcome: .failed, message: error.localizedDescription))
            }
        }
        let knownHashes = Set(current.assets.map(\.contentHash))
        let additions = unique.filter { !knownHashes.contains($0.contentHash) }
        let knownTelemetry = Set(current.effectiveTelemetrySources.compactMap { $0.originalURL?.standardizedFileURL })
        let newTelemetry = telemetrySources.filter { source in
            source.originalURL.map { !knownTelemetry.contains($0.standardizedFileURL) } ?? true
        }
        let folders = urls.map { url -> AuthorizedMediaFolder in
            var directory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            return AuthorizedMediaFolder(url: directory.boolValue ? url : url.deletingLastPathComponent())
        }
        let oldFolders = Set((current.authorizedMediaFolders ?? []).map(\.url))
        let newFolders = folders.filter { !oldFolders.contains($0.url) }
        if !additions.isEmpty || !newTelemetry.isEmpty || !newFolders.isEmpty {
            try await store.update { project in
                let known = Set(project.assets.map(\.contentHash))
                project.assets.append(contentsOf: additions.filter { !known.contains($0.contentHash) })
                if !additions.isEmpty || !newTelemetry.isEmpty { project.sourceMap = nil }
                project.telemetrySources = project.effectiveTelemetrySources + newTelemetry
                project.authorizedMediaFolders = (project.authorizedMediaFolders ?? []) + newFolders
            }
        }
        try Task.checkCancellation()
        // An import receipt is operational history, not a timeline edit.
        // Reimporting duplicates must not invalidate analyses or an AI edit's
        // optimistic revision merely because the receipt has a new timestamp.
        try await store.persistOperationalState { $0.lastImportReport = report }
        return report.failures.map { "\($0.url.lastPathComponent): \($0.message)" }
    }

    /// Re-runs only embedded telemetry discovery after extractor support is
    /// expanded. Existing visual analysis and edit decisions remain cached.
    @discardableResult
    public func refreshEmbeddedTelemetryIfNeeded() async throws -> Int {
        let extractionVersion = 2
        let current = await store.manifest
        guard (current.telemetryExtractionVersion ?? 0) < extractionVersion else { return 0 }
        let candidates = current.assets.filter { asset in
            guard asset.kind == .video else { return false }
            let source = current.effectiveTelemetrySources.first { $0.linkedAssetID == asset.id }
            let analysis = current.analyses.first { $0.assetID == asset.id }?.telemetry
            let hasUsefulSource = source?.summary.availableWidgetKinds.contains { $0 != .elapsedTime } == true
            let hasUsefulAnalysis = analysis?.availableWidgetKinds.contains { $0 != .elapsedTime } == true
            return !hasUsefulSource && !hasUsefulAnalysis
        }
        var discovered: [TelemetrySource] = []
        for asset in candidates {
            if let source = await TelemetryEngine().embeddedSource(for: asset) {
                discovered.append(source)
            }
        }
        try await store.update { project in
            for source in discovered {
                project.telemetrySources?.removeAll { $0.linkedAssetID == source.linkedAssetID }
                project.telemetrySources = project.effectiveTelemetrySources + [source]
                if let assetID = source.linkedAssetID,
                   let index = project.analyses.firstIndex(where: { $0.assetID == assetID }) {
                    project.analyses[index].telemetry = source.summary
                }
            }
            project.telemetryExtractionVersion = extractionVersion
        }
        return discovered.count
    }

    @discardableResult
    public func analyzeMissing(
        preferredAssetID: UUID? = nil,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> Int {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "VeloEdit анализирует видео")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let snapshot = await store.snapshot()
        return try await PerformanceTrace.measure(name: "analysis", projectID: snapshot.manifest.id, revision: String(snapshot.revision)) {
            try await self.analyzeMissingImpl(preferredAssetID: preferredAssetID, progress: progress)
        }
    }

    private func analyzeMissingImpl(preferredAssetID: UUID?, progress: (@Sendable (ImportProgress) -> Void)?) async throws -> Int {
        let current = await store.manifest
        let baseProfile = AIAnalysisProfile.resolve(
            mode: current.preferences.effectiveAIPowerMode,
            advanced: current.preferences.effectiveAdvancedAISettings,
            thermalState: .nominal
        )
        let currentModelDigest = analyzer == nil && baseProfile.runtime != .mlx
            ? await LocalAIModelManager.shared.installedModelDigest(model: baseProfile.ollamaModelID) : nil
        let pending = current.assets.filter { asset in
            !current.analyses.contains {
                guard $0.assetID == asset.id,
                      $0.analyzedContentHash == asset.contentHash,
                      $0.schemaVersion == current.analysisSchemaVersion,
                      $0.deepMediaVersion == DeepAnalysisCache.version,
                      $0.analysisProfileKey?.hasPrefix(AIAnalysisProfile.cacheVersion + ":") == true,
                      $0.analyzedSourceIdentity == FrameCacheKey.sourceIdentity(url: asset.originalURL, contentHash: asset.contentHash),
                      currentModelDigest == nil || $0.analysisModelDigest == currentModelDigest,
                      $0.satisfies(baseProfile) else { return false }
                let hasUsableMoment = $0.directorCandidates.contains {
                    !$0.excluded && $0.sourceDuration > 0.05
                }
                return hasUsableMoment
                    && (($0.completedDepth ?? .quick) > baseProfile.targetDepth || $0.analysisProfileKey == baseProfile.cacheKey)
            }
        }
        let initialQueue = await analysisQueue.replace(with: pending, preferredAssetID: preferredAssetID)
        try await store.updateAnalysisProgress { $0.analysisQueue = initialQueue }
        guard !pending.isEmpty else {
            progress?(ImportProgress(completed: 0, total: 1, currentName: "Восстанавливаю хронологию исходников", analysisStage: .sourceOrdering))
            let sourceMap = SourceTimelineAnalyzer().analyze(assets: current.assets, analyses: current.analyses)
            progress?(ImportProgress(completed: 0, total: 1, currentName: "Группирую активности и события", analysisStage: .eventDiscovery))
            let eventDiscovery = EventIntelligenceEngine().discover(assets: current.assets, analyses: current.analyses, sourceMap: sourceMap)
            try await store.updateAnalysisProgress { project in
                project.sourceMap = eventDiscovery.sourceMap
                project.events = eventDiscovery.events
            }
            progress?(ImportProgress(completed: 1, total: 1, currentName: "Хронология и карта исходников обновлены", analysisStage: .persistence))
            return 0
        }

        var analyzedCount = 0
        var failedCount = 0
        var incompleteCount = 0
        let paths = CachePaths(root: await store.cacheURL)
        let frameCache = FrameCache(rootURL: paths.frameCacheDirectory)
        let deepCache = DeepAnalysisCache(rootURL: paths.deepMediaCacheDirectory)
        let scheduler = ThermalAwareScheduler()
        let history = current.analyses.compactMap { result -> TimeInterval? in
            guard result.metrics?.mode == baseProfile.mode else { return nil }
            return result.metrics?.totalDuration
        }
        let eta = AnalysisETAEngine(history: history)
        var fileIndex = 0

        while let entry = await analysisQueue.next() {
            try Task.checkCancellation()
            guard let asset = pending.first(where: { $0.id == entry.assetID }) else {
                await analysisQueue.fail(assetID: entry.assetID, error: "Исходник удалён из проекта")
                continue
            }
            await eta.startFile()
            var thermal = await scheduler.refresh()
            if thermal == .hot {
                progress?(ImportProgress(
                    completed: fileIndex * 100,
                    total: pending.count * 100,
                    currentName: "Снижаем нагрузку для охлаждения Mac…",
                    currentFileIndex: fileIndex + 1,
                    fileCount: pending.count,
                    thermalThrottled: true
                ))
                try await scheduler.waitUntilSafe()
                thermal = await scheduler.refresh()
            }
            let thermalThrottled = thermal != .cool
            // Cooling changes scheduling, never the requested analysis depth.
            let profile = baseProfile
            let heat = await scheduler.statusLabel()
            let fallbackSeconds = Self.analysisFallbackSeconds(for: asset, mode: profile.mode)
            let queueSnapshot = await analysisQueue.snapshot()
            let queuedAssetIDs = Set(queueSnapshot.lazy.filter { $0.status == .queued }.map(\.assetID))
            let queuedFallbackSeconds = pending.lazy
                .filter { queuedAssetIDs.contains($0.id) }
                .reduce(0.0) { partial, queuedAsset in
                    partial + Self.analysisFallbackSeconds(for: queuedAsset, mode: profile.mode)
                }
            let reporter = AnalysisProgressReporter(
                callback: progress,
                eta: eta,
                fileIndex: fileIndex,
                fileCount: pending.count,
                fallbackSecondsPerFile: fallbackSeconds,
                queuedFallbackSeconds: queuedFallbackSeconds
            )
            let metrics = AnalysisMetricsRecorder(mode: profile.mode, metadata: asset.metadata)
            if let startedAt = entry.startedAt {
                await metrics.recordQueueWait(startedAt.timeIntervalSince(entry.enqueuedAt))
            }
            await reporter.publish(
                AnalysisStageUpdate(stage: .metadata, label: "Метаданные · \(heat)", fraction: 0.02),
                fileName: asset.displayName,
                thermalThrottled: thermalThrottled
            )
            await metrics.start(.metadata)
            await metrics.finish(.metadata, workUnits: 1)

            let previous = current.analyses.first {
                $0.assetID == asset.id && $0.analyzedContentHash == asset.contentHash && $0.schemaVersion == current.analysisSchemaVersion
            }
            await metrics.start(.telemetry)
            await reporter.publish(
                AnalysisStageUpdate(stage: .telemetry, label: "OVRLEY / телеметрия", fraction: 0.05),
                fileName: asset.displayName,
                thermalThrottled: thermalThrottled
            )
            let telemetrySource = previous?.telemetry == nil && asset.kind == .video
                ? await TelemetryEngine().embeddedSource(for: asset)
                : nil
            let telemetry = previous?.telemetry ?? telemetrySource?.summary
            await metrics.finish(.telemetry, workUnits: telemetry?.sampleCount ?? 0)

            var analysisURL = asset.originalURL
            var usedProxy = false
            var proxyWarning: String?
            if AnalysisProxyPlanner().shouldGenerateProxy(for: asset, profile: profile) {
                await metrics.start(.proxy)
                await reporter.publish(
                    AnalysisStageUpdate(stage: .proxy, label: "Analysis proxy \(profile.proxyLongEdge)p", fraction: 0.10),
                    fileName: asset.displayName,
                    thermalThrottled: thermalThrottled
                )
                do {
                    analysisURL = try await ProxyGenerator().generate(
                        for: asset,
                        destination: paths.analysisProxy(for: asset, longEdge: profile.proxyLongEdge),
                        longEdge: profile.proxyLongEdge
                    ) { fraction in
                        Task {
                            await reporter.publish(
                                AnalysisStageUpdate(stage: .proxy, label: "Analysis proxy · \(Int(fraction * 100))%", fraction: 0.10 + fraction * 0.20),
                                fileName: asset.displayName,
                                thermalThrottled: thermalThrottled
                            )
                        }
                    }
                    usedProxy = analysisURL != asset.originalURL
                } catch {
                    proxyWarning = "Proxy не создан; анализ использовал оригинал: \(error.localizedDescription)"
                }
                await metrics.finish(.proxy, workUnits: Int(asset.metadata.duration ?? 0))
            } else {
                await reporter.publish(
                    AnalysisStageUpdate(stage: .fastInspection, label: "Без полного proxy", fraction: 0.10),
                    fileName: asset.displayName,
                    thermalThrottled: thermalThrottled
                )
            }

            let customAnalyzer = analyzer
            let task = Task<AnalysisResult, Error> {
                if let customAnalyzer {
                    return try await customAnalyzer.analyze(asset: asset)
                }
                return try await AdaptiveLocalAnalyzer(schemaVersion: current.analysisSchemaVersion, profile: profile)
                    .analyze(
                        asset: asset,
                        analysisURL: analysisURL,
                        usedProxy: usedProxy,
                        telemetry: telemetry,
                        previous: previous,
                        frameCache: frameCache,
                        deepCache: deepCache,
                        metrics: metrics,
                        detailedProgress: { update in
                            let mapped = AnalysisStageUpdate(
                                stage: update.stage,
                                label: update.label,
                                fraction: 0.30 + update.fraction * 0.68,
                                currentScene: update.currentScene,
                                sceneCount: update.sceneCount
                            )
                            Task {
                                await reporter.publish(mapped, fileName: asset.displayName, thermalThrottled: thermalThrottled)
                            }
                        }
                    )
            }
            activeAnalysisAssetID = asset.id
            activeAnalysisTask = task
            do {
                var result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                activeAnalysisTask = nil
                activeAnalysisAssetID = nil
                result.analysisProfileKey = baseProfile.cacheKey
                if result.analyzedSourceIdentity == nil {
                    result.analyzedSourceIdentity = FrameCacheKey.sourceIdentity(url: asset.originalURL, contentHash: asset.contentHash)
                }
                // An explicitly injected analyzer defines its own contract. The
                // production analyzer must retain its measured completion state.
                if customAnalyzer != nil, result.aiExecution == nil {
                    result.aiExecution = AIExecutionEvidence(visualAnalysisCompleted: true)
                    result.completedDepth = max(result.completedDepth ?? .quick, profile.targetDepth)
                }
                if result.deepMediaVersion == nil {
                    result.deepMediaVersion = DeepAnalysisCache.version
                    result.deepMediaDiagnostics = DeepMediaDiagnostics(stages: [
                        DeepAnalysisStageReport(stage: .embeddings, ran: false, reason: "Custom analyzer fallback без frame descriptors")
                    ])
                }
                result.telemetry = telemetry
                if let proxyWarning { result.warnings.append(proxyWarning) }
                if thermalThrottled { result.warnings.append("Нагрузка ограничена для охлаждения Mac; глубина анализа сохранена.") }
                result.metrics = await metrics.snapshot()
                await analysisQueue.complete(assetID: asset.id)
                let queueSnapshot = await analysisQueue.snapshot()
                var resultWasCurrent = false
                PerformanceTrace.current?.event("stage.begin", fields: ["stage": "persistence"])
                try await store.updateAnalysisProgress { project in
                    project.analysisQueue = queueSnapshot
                    guard project.assets.contains(where: {
                        $0.id == asset.id && $0.contentHash == asset.contentHash && !$0.missing
                    }) else { return }
                    resultWasCurrent = true
                    project.analyses.removeAll { $0.assetID == result.assetID }
                    project.analyses.append(result)
                    if let telemetrySource {
                        project.telemetrySources?.removeAll { $0.linkedAssetID == asset.id }
                        project.telemetrySources = project.effectiveTelemetrySources + [telemetrySource]
                    }
                    // Archive-level clustering runs once after cross-video
                    // refinement below. Re-running O(n²) event discovery after
                    // every asset would turn a 300-file import into O(n³) work.
                }
                PerformanceTrace.current?.event("stage.end", fields: ["stage": "persistence"])
                if resultWasCurrent {
                    analyzedCount += 1
                    if result.aiExecution?.isComplete != true { incompleteCount += 1 }
                }
                await eta.finishFile()
                await reporter.publish(
                    AnalysisStageUpdate(stage: .persistence, label: result.aiExecution?.isComplete == true
                        ? "Анализ готов" : "Частичный анализ сохранён; нужен повтор", fraction: 1),
                    fileName: asset.displayName
                )
            } catch is CancellationError {
                activeAnalysisTask = nil
                activeAnalysisAssetID = nil
                await analysisQueue.cancel(assetID: asset.id)
                let queueSnapshot = await analysisQueue.snapshot()
                try? await store.updateAnalysisProgress { $0.analysisQueue = queueSnapshot }
                throw CancellationError()
            } catch {
                activeAnalysisTask = nil
                activeAnalysisAssetID = nil
                failedCount += 1
                await analysisQueue.fail(assetID: asset.id, error: error.localizedDescription)
                let queueSnapshot = await analysisQueue.snapshot()
                try? await store.updateAnalysisProgress { $0.analysisQueue = queueSnapshot }
                progress?(ImportProgress(
                    completed: (fileIndex + 1) * 100,
                    total: pending.count * 100,
                    currentName: "Не удалось проанализировать \(asset.displayName): \(error.localizedDescription)",
                    currentFileIndex: fileIndex + 1,
                    fileCount: pending.count
                ))
            }
            fileIndex += 1
        }

        if analyzedCount > 0 {
            let latest = await store.manifest
            let refinedAnalyses = CrossVideoRelationshipAnalyzer().refine(latest.analyses)
            progress?(ImportProgress(
                completed: pending.count * 100,
                total: pending.count * 100,
                currentName: "Восстанавливаю хронологию исходников",
                analysisStage: .sourceOrdering
            ))
            let sourceMap = SourceTimelineAnalyzer().analyze(assets: latest.assets, analyses: refinedAnalyses)
            progress?(ImportProgress(
                completed: pending.count * 100,
                total: pending.count * 100,
                currentName: "Группирую активности и события",
                analysisStage: .eventDiscovery
            ))
            let eventDiscovery = EventIntelligenceEngine().discover(assets: latest.assets, analyses: refinedAnalyses, sourceMap: sourceMap)
            try await store.updateAnalysisProgress { project in
                project.analyses = refinedAnalyses
                project.sourceMap = eventDiscovery.sourceMap
                project.events = eventDiscovery.events
            }
        }
        let label = failedCount + incompleteCount == 0 ? "Анализ готов"
            : "Анализ завершён, ошибок: \(failedCount), требуют повтора: \(incompleteCount)"
        progress?(ImportProgress(completed: pending.count * 100, total: pending.count * 100, currentName: label))
        return analyzedCount
    }

    private static func analysisFallbackSeconds(for asset: MediaAsset, mode: AIPowerMode) -> TimeInterval {
        let durationMultiplier: Double = switch mode {
        case .fast: 0.18
        case .balanced: 0.42
        case .quality: 0.9
        case .maximum: 1.8
        }
        return max(12, (asset.metadata.duration ?? 5) * durationMultiplier)
    }

    /// Keeps the director usable when deep/scene analysis produced no editing
    /// units even though the imported file has valid media metadata. The
    /// fallback is deliberately neutral and is replaced by a later successful
    /// analysis; its purpose is to prevent a valid source from degenerating
    /// into a zero-second Timeline.
    private static func ensuringMetadataFallbackCandidates(
        in source: [AnalysisResult],
        assets: [MediaAsset],
        schemaVersion: Int
    ) -> [AnalysisResult] {
        var results = source
        for asset in assets {
            let exactIndex = results.firstIndex {
                $0.assetID == asset.id && $0.analyzedContentHash == asset.contentHash
            }
            if let exactIndex {
                if asset.kind == .photo {
                    // Still images have no finite recording length. Upgrade
                    // cached default holds before budgeting a new film, while
                    // retaining explicit locked durations.
                    for index in results[exactIndex].candidates.indices {
                        results[exactIndex].candidates[index].tags.insert("photo")
                        guard !results[exactIndex].candidates[index].locked else { continue }
                        var candidate = results[exactIndex].candidates[index]
                        candidate.sourceDuration = max(candidate.sourceDuration, PhotoPresentationPolicy.duration)
                        if var evidence = candidate.insights?.editorialEvidence {
                            evidence.usableRange.end = candidate.sourceStart + candidate.sourceDuration
                            candidate.insights?.editorialEvidence = evidence
                        }
                        results[exactIndex].candidates[index] = candidate
                    }
                }
                let existing = results[exactIndex].candidates
                let hasUsableCandidate = existing.contains { !$0.excluded && $0.sourceDuration > 0.05 }
                let wasExplicitlyExcluded = !existing.isEmpty && existing.allSatisfy(\.excluded)
                if hasUsableCandidate || wasExplicitlyExcluded { continue }
            }

            let availableDuration: Double
            switch asset.kind {
            case .photo:
                availableDuration = max(PhotoPresentationPolicy.duration, asset.metadata.duration ?? 0)
            case .video:
                availableDuration = max(0, asset.metadata.duration ?? 0)
            }
            guard availableDuration > 0.05 else { continue }

            var tags: Set<String> = ["metadata-fallback"]
            if asset.kind == .photo { tags.insert("photo") }
            if let dimensions = asset.displayDimensions {
                tags.insert(dimensions.width >= dimensions.height ? "horizontal" : "vertical")
            }
            let candidate = Candidate(
                assetID: asset.id,
                sourceStart: 0,
                sourceDuration: availableDuration,
                scores: ClipScores(
                    quality: 0.56,
                    interest: 0.54,
                    action: asset.kind == .photo ? 0.08 : 0.42,
                    stability: asset.kind == .photo ? 1 : 0.58,
                    uniqueness: 0.5
                ),
                tags: tags,
                explanation: ["Резервный монтажный диапазон создан из проверенных метаданных исходника"]
            )
            if let exactIndex {
                results[exactIndex].candidates = [candidate]
                results[exactIndex].warnings.append("AI-анализ не выделил сцены; использован безопасный metadata fallback.")
                if results[exactIndex].aiRuntimeLabel == nil {
                    results[exactIndex].aiRuntimeLabel = "Метаданные · резервный монтаж"
                }
            } else {
                results.removeAll { $0.assetID == asset.id }
                results.append(AnalysisResult(
                    assetID: asset.id,
                    schemaVersion: schemaVersion,
                    analyzedContentHash: asset.contentHash,
                    sceneTags: tags,
                    candidates: [candidate],
                    warnings: ["AI-анализ недоступен; использован безопасный metadata fallback."],
                    aiRuntimeLabel: "Метаданные · резервный монтаж"
                ))
            }
        }
        return results
    }

    public func prioritizeAnalysis(assetID: UUID) async {
        await analysisQueue.promote(assetID: assetID)
    }

    public func cancelCurrentAnalysis() async {
        activeAnalysisTask?.cancel()
        if let activeAnalysisAssetID { await analysisQueue.cancel(assetID: activeAnalysisAssetID) }
    }

    public func cancelAnalysis(assetID: UUID) async {
        if activeAnalysisAssetID == assetID { activeAnalysisTask?.cancel() }
        await analysisQueue.cancel(assetID: assetID)
    }

    public func cancelAllAnalysis() async {
        activeAnalysisTask?.cancel()
        await analysisQueue.cancelAll()
    }

    /// Persists reusable rendered evidence and additional source ranges before
    /// any particular timeline is ranked. This is also an operational prewarm
    /// path for existing projects: it changes analysis knowledge only and does
    /// not create, activate or pretend to verify a film.
    @discardableResult
    public func prepareEditorialIntelligence(requestedDuration: Double? = nil) async throws -> Int {
        let snapshot = await store.snapshot()
        let current = snapshot.manifest
        let usableAssets = current.assets.filter { !$0.excluded && !$0.missing }
        guard !usableAssets.isEmpty else { throw DirectorBriefFulfillmentError.noUsableSourceMaterial }
        var analyses = CrossVideoRelationshipAnalyzer().refine(
            Self.mergingTelemetrySources(into: current.analyses, sources: current.effectiveTelemetrySources)
        )
        analyses = Self.ensuringMetadataFallbackCandidates(
            in: analyses,
            assets: usableAssets,
            schemaVersion: current.analysisSchemaVersion
        )
        let before = analyses.reduce(0) { $0 + $1.candidates.count }
        let cacheURL = await store.cacheURL
        analyses = try await LocalEditorialEvidenceAnalyzer(cacheURL: cacheURL).enrich(
            analyses: analyses,
            assets: usableAssets
        )
        analyses = try await EditorialCandidateMiner().expandIfNeeded(
            analyses: analyses,
            assets: usableAssets,
            requestedDuration: requestedDuration
                ?? current.workspaceState?.directorBrief?.requestedDuration
                ?? current.storyPlans.last?.directorBrief?.requestedDuration,
            analyzer: LocalEditorialEvidenceAnalyzer(cacheURL: cacheURL)
        )
        guard analyses != current.analyses else { return 0 }
        try await store.update(ifRevision: snapshot.revision) { project in
            project.analyses = analyses
        }
        return max(0, analyses.reduce(0) { $0 + $1.candidates.count } - before)
    }

    @discardableResult
    public func createFilm(prompt: String, preset: FilmPreset, targetDuration: Double? = nil, preferredMusicTrackID: UUID? = nil, directorBrief: DirectorBrief? = nil, avoidingTimeline: Timeline? = nil, progress: FilmBuildProgressHandler? = nil) async throws -> Timeline {
        let request = FilmBuildRequest(kind: .create, prompt: prompt, preset: preset, targetDuration: targetDuration, preferredMusicTrackID: preferredMusicTrackID, directorBrief: directorBrief, avoidingTimeline: avoidingTimeline)
        return try await runFilmJob(request, progress: progress)
    }

    public func regenerate(feedback: String, selectedCandidateID: UUID? = nil, preset: FilmPreset? = nil, targetDuration: Double? = nil, preferredMusicTrackID: UUID? = nil, directorBrief: DirectorBrief? = nil, ignoredFeedbackConstraints: StoryConstraintLocks = [], progress: FilmBuildProgressHandler? = nil) async throws -> Timeline {
        let request = FilmBuildRequest(kind: .regenerate, prompt: feedback, preset: preset, targetDuration: targetDuration, preferredMusicTrackID: preferredMusicTrackID, directorBrief: directorBrief, selectedCandidateID: selectedCandidateID, ignoredFeedbackConstraints: ignoredFeedbackConstraints.rawValue)
        return try await runFilmJob(request, progress: progress)
    }

    private func runFilmJob(_ request: FilmBuildRequest, progress: FilmBuildProgressHandler?) async throws -> Timeline {
        if let activeFilmTask {
            guard activeFilmRequest == request else { throw AutonomousOperationError.projectBusy }
            return try await activeFilmTask.value
        }
        activeFilmRequest = request
        let observer = progress ?? FilmBuildReporting.handler
        let task = Task {
            try await AutonomousJobContext.$store.withValue(store) {
                let snapshot = await self.store.snapshot()
                return try await PerformanceTrace.measure(name: "film", projectID: snapshot.manifest.id, revision: String(snapshot.revision)) {
                    let relay = FilmBuildProgressRelay(trace: PerformanceTrace.current, observer: observer)
                    do {
                        let result = try await self.performFilmJob(request, progress: { await relay.report($0) })
                        await relay.finish(status: "success")
                        return result
                    } catch {
                        await relay.finish(status: error is CancellationError ? "cancelled" : "failed")
                        throw error
                    }
                }
            }
        }
        activeFilmTask = task
        defer { activeFilmTask = nil; activeFilmRequest = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func performFilmJob(_ request: FilmBuildRequest, progress: FilmBuildProgressHandler?) async throws -> Timeline {
        let lease = try ProjectOperationLease(package: store.packageURL)
        defer { withExtendedLifetime(lease) {} }
        if let old = await store.manifest.filmBuildRecovery, old.request != request {
            try await store.updateAutonomousJob { $0.state = .cancelled }
        }
        _ = try await store.beginAutonomousJob(kind: .film)
        _ = try await store.beginFilmBuildRecovery(request)
        try await store.updateAutonomousJob { $0.state = .running }
        do {
            let existingPreset = await store.manifest.storyPlans.last?.preset
            if (request.preset ?? existingPreset) != .vlog, await store.recoverableFilmBuild()?.draft == nil {
                if analyzer == nil, !(await store.manifest.assets).isEmpty {
                    let preferences = await store.manifest.preferences
                    let profile = AIAnalysisProfile.resolve(mode: preferences.effectiveAIPowerMode, advanced: preferences.effectiveAdvancedAISettings, thermalState: .nominal)
                    try await store.updateAutonomousJob { $0.stage = .environment }
                    try await LocalAIModelManager.shared.prepareAuthorizedModel(model: profile.ollamaModelID)
                }
                try await store.updateAutonomousJob { $0.stage = .analysis }
                _ = try await recoverMissingSources()
                _ = try await FilmBuildReporting.$handler.withValue(progress) {
                    try await FilmBuildReporting.forwarding { report in
                        try await self.analyzeMissing { update in
                            report(FilmBuildProgress(.analysis, completed: update.completed, total: update.total))
                        }
                    }
                }
            }
            while true {
                try Task.checkCancellation()
                try await store.updateAutonomousJob { $0.stage = .assembly; $0.state = .running }
                do {
                    let result: Timeline
                    switch request.kind {
                    case .create:
                        result = try await executeCreateFilm(prompt: request.prompt, preset: request.preset ?? .story, targetDuration: request.targetDuration, preferredMusicTrackID: request.preferredMusicTrackID, directorBrief: request.directorBrief, avoidingTimeline: request.avoidingTimeline, progress: progress)
                    case .regenerate:
                        result = try await executeRegenerate(feedback: request.prompt, selectedCandidateID: request.selectedCandidateID, preset: request.preset, targetDuration: request.targetDuration, preferredMusicTrackID: request.preferredMusicTrackID, directorBrief: request.directorBrief, ignoredFeedbackConstraints: StoryConstraintLocks(rawValue: request.ignoredFeedbackConstraints), progress: progress)
                    }
                    return result
                } catch {
                    let cause = AutonomousFailureCause.classify(error)
                    guard cause == .transientNetwork || cause == .localService else { throw error }
                    guard let delay = try await store.reserveRecovery(error: error, strategy: "restore-local-session") else { throw error }
                    try await Task.sleep(for: .seconds(delay))
                    try await LocalAIModelManager.shared.ensureService()
                }
            }
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            if !cancelled, AutonomousFailureCause.classify(error) != .revisionConflict {
                await writeAutonomousDiagnostic(error)
                // Never publish a different selection to conceal a failed
                // verification. The exact draft remains available for resume;
                // missing evidence is an error, not a new film from early media.
            }
            try? await store.updateAutonomousJob { job in
                job.state = job.explicitCancellation ? .cancelled : cancelled ? .queued : .failed
            }
            if !cancelled {
                _ = await recordExternalDependencyIfNeeded(error)
                await writeAutonomousDiagnostic(error)
            }
            if AutonomousFailureCause.classify(error) == .mediaDecode {
                throw EditorialGenerationError.unsatisfiedIntent("Нет декодируемых исходников для фильма")
            }
            throw error
        }
    }

    private func writeAutonomousDiagnostic(_ error: Error) async {
        guard let job = await store.manifest.autonomousJob else { return }
        let directory = await store.logsURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.veloEdit.encode(job) {
            try? data.write(to: directory.appendingPathComponent("job-\(job.id.uuidString).json"), options: .atomic)
        }
        try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("job-\(job.id.uuidString)-failure.txt"), options: .atomic)
    }

    private func executeCreateFilm(prompt: String, preset: FilmPreset, targetDuration: Double? = nil, preferredMusicTrackID: UUID? = nil, directorBrief: DirectorBrief? = nil, avoidingTimeline: Timeline? = nil, progress: FilmBuildProgressHandler? = nil) async throws -> Timeline {
        let pendingAtStart = await store.manifest.workspaceState?.pendingDirectorInstructions ?? []
        var prompt = (pendingAtStart.filter { !prompt.contains($0) } + [prompt]).joined(separator: "\n")
        var directorBrief = directorBrief
        for attempt in 0..<2 {
            let workspaceBefore = await store.manifest.workspaceState
            let ids = try await store.beginEditorialGeneration(prompt: prompt, brief: directorBrief)
            do {
                let request = FilmBuildRequest(kind: .create, prompt: prompt, preset: preset, targetDuration: targetDuration, preferredMusicTrackID: preferredMusicTrackID, directorBrief: directorBrief, avoidingTimeline: avoidingTimeline)
                let draft = try await store.beginFilmBuildRecovery(request)
                return try await FilmBuildReporting.$handler.withValue(progress ?? FilmBuildReporting.handler) {
                    if preset == .vlog {
                        return try await self.createVlogFilm(prompt: prompt, brief: directorBrief, targetDuration: targetDuration, preferredMusicTrackID: preferredMusicTrackID, intentIDs: ids, progress: progress)
                    }
                    if let draft {
                        return try await self.finishFilmBuild(draft, snapshot: await self.store.snapshot(), intentIDs: ids, progress: progress)
                    }
                    return try await createFilmAttempt(prompt: prompt, preset: preset, targetDuration: targetDuration, preferredMusicTrackID: preferredMusicTrackID, directorBrief: directorBrief, avoidingTimeline: avoidingTimeline, intentIDs: ids, progress: progress)
                }
            } catch {
                let wasCurrent = await store.isCurrentEditorialGeneration(ids: ids)
                try? await store.failEditorialGeneration(ids: ids, error: error)
                if case ProjectStoreError.staleRevision = error, attempt == 0, wasCurrent {
                    let latest = await store.manifest.workspaceState
                    if latest?.prompt != workspaceBefore?.prompt { prompt = latest?.prompt ?? prompt }
                    if latest?.directorBrief != workspaceBefore?.directorBrief { directorBrief = latest?.directorBrief }
                    if latest?.pendingDirectorInstructions != workspaceBefore?.pendingDirectorInstructions {
                        prompt += "\n" + (latest?.pendingDirectorInstructions ?? []).joined(separator: "\n")
                    }
                    continue
                }
                throw error
            }
        }
        throw EditorialGenerationError.unsatisfiedIntent("Повторный конфликт ревизии")
    }

    @discardableResult
    private func createVlogFilm(prompt: String, brief: DirectorBrief?, targetDuration: Double?, preferredMusicTrackID: UUID?, intentIDs: [UUID], progress: FilmBuildProgressHandler?) async throws -> Timeline {
        await cancelAllAnalysis()
        if let activeAnalysisTask { _ = try? await activeAnalysisTask.value }
        try Task.checkCancellation()
        let snapshot = await store.snapshot()
        let current = snapshot.manifest
        var brief = (brief ?? .legacyDefault).applyingSubtitleCommand(prompt)
        if let targetDuration { brief.requestedDuration = targetDuration; brief.durationMode = .exact }
        let assets = current.assets.filter { !$0.excluded && !$0.missing }
        guard !assets.isEmpty else { throw DirectorBriefFulfillmentError.noUsableSourceMaterial }
        let speechCacheURL = await store.cacheURL
        let recognizer: any LocalSpeechRecognizing = speechRecognizer ?? WhisperKitSpeechRecognizer(cacheURL: speechCacheURL)
        var records: [SpeechSourceRecord] = []
        let audible = assets.filter { $0.kind == .video && $0.metadata.hasAudio }
        // Preflight before touching the previous edit. Fast AI has exactly the
        // same source-wide speech pass as the other modes.
        if !audible.isEmpty, speechRecognizer == nil {
            let manifest = try SpeechPackageManifest.bundled()
            guard await SpeechAssetStore.shared.installedURL(manifest: manifest) != nil else { throw SpeechComponentError.unavailable }
        }
        for (index, asset) in audible.enumerated() {
            await progress?(FilmBuildProgress(.speech, completed: index, total: audible.count, detail: asset.displayName))
            try Task.checkCancellation()
            if let transcript = try await recognizer.transcribe(url: asset.originalURL, localeIdentifier: "ru") {
                records.append(SpeechSourceRecord(assetID: asset.id, transcript: transcript))
            }
        }
        await progress?(FilmBuildProgress(.narrative))
        let analyses = VlogSpeechEvidence.enrich(current.analyses, assets: assets, records: records, schemaVersion: current.analysisSchemaVersion)
        var plan = StoryPlan(prompt: prompt, preset: .vlog, constraints: StoryConstraints(targetDuration: brief.requestedDuration, allowSlowMotion: false, transitionFrequency: 0, pacing: brief.mood.pacing), chapters: [], directorBrief: brief)
        var timeline = VlogAssembly.assemble(assets: assets, records: records, plan: plan)
        timeline = DirectorEffectsPolicyEngine.decorate(timeline, plan: plan, candidates: [:])
        if brief.durationMode == .automatic { plan.constraints.targetDuration = timeline.duration }
        var warnings = records.flatMap(\.warnings)
        if records.allSatisfy({ $0.status == .noSpeech }) { warnings.append("Распознанной речи нет; визуальный рассказ сохранён без речевых субтитров.") }
        let tracks = try await musicSystem.tracks()
        if brief.musicPolicy != .none {
            let explicitID = preferredMusicTrackID ?? brief.musicTrackID
            if let explicitID {
                guard let track = tracks.first(where: { $0.id == explicitID && FileManager.default.fileExists(atPath: $0.localFileURL.path) }) else { throw DirectorBriefFulfillmentError.unavailableMusicTrack(explicitID) }
                timeline = await Self.attachingExplicitMusic(track, to: timeline)
            } else if brief.musicPolicy == .specificTrack { throw DirectorBriefFulfillmentError.specificMusicTrackNotSelected }
            else if let track = tracks.filter({ FileManager.default.fileExists(atPath: $0.localFileURL.path) }).sorted(by: { $0.id.uuidString < $1.id.uuidString }).first {
                timeline = await Self.attachingExplicitMusic(track, to: timeline)
                timeline.music?.volume = brief.musicPolicy == .soft ? 0.12 : 0.20
            } else { warnings.append("В локальной библиотеке нет музыки. Рассказ и голос сохранены; добавьте трек при необходимости.") }
        }
        timeline.originalAudioVolume = brief.sourceAudioPolicy.volume
        timeline.audioDucking = AudioDuckingSettings(enabled: brief.sourceAudioPolicy != .mute)
        await progress?(FilmBuildProgress(.subtitles))
        timeline = SpeechSubtitleBuilder.applying(to: timeline, records: records, enabled: brief.subtitlesEnabled(preset: .vlog), allowMuted: brief.subtitlesWithoutAudio == true, previous: current.timelines.last, style: brief.subtitleStyle)
        let durationRequirement = FilmDurationRequirement.parse(prompt: prompt, explicitSeconds: brief.explicitRequestedDuration, mode: brief.durationMode)
        if !durationRequirement.accepts(duration: timeline.duration, frameRate: timeline.frameRate) {
            warnings.append("Запрошенная длительность несовместима с полным рассказом: сохранено \(Int(timeline.duration.rounded())) с без ускорения и обрезания фраз.")
        }
        await progress?(FilmBuildProgress(.verifying))
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: current.assets, musicTracks: tracks, forceVideoComposition: true)
        guard playback.skippedItemIDs.isEmpty, playback.renderedItemCount > 0 else { throw DirectorBriefFulfillmentError.noUsableSourceMaterial }
        try Task.checkCancellation()
        timeline.filmDeliveryReport = AutomaticFilmDelivery.verifiedReport(for: timeline, plan: plan, assets: current.assets, analyses: analyses, additionalWarnings: warnings)
        let subtitleRequirement = VlogSubtitleCoverage.requirement(timeline: timeline, brief: brief, preset: .vlog)
        timeline.filmDeliveryReport?.requirements?.append(subtitleRequirement)
        timeline.filmDeliveryReport?.requirements?.append(.init(sourcePhrase: "Стиль: Влог", rule: "vlogSpeech", verificationMethod: "Локальное распознавание всех звуковых исходников", passed: records.count == audible.count && records.allSatisfy { $0.status == .ready || $0.status == .noSpeech }, evidence: "Источников: \(records.count); неполных: \(records.filter { $0.status == .partial }.count)"))
        timeline.filmDeliveryReport?.requirements?.append(.init(sourcePhrase: "Сохранить законченные фразы", rule: "vlogChronology", verificationMethod: "Исходный порядок, скорость 1×", passed: timeline.items.allSatisfy { $0.speed == 1 && !$0.isReversed }, evidence: "Удалены только подтверждённые длинные паузы между фразами"))
        await progress?(FilmBuildProgress(.saving))
        try await store.update(ifRevision: snapshot.revision) { project in
            timeline = try ProjectStore.verifyAndFulfillEditorialGeneration(in: &project, ids: intentIDs, timeline: timeline, analyses: analyses)
            if let previous = project.timelines.last { Self.appendCheckpoint(timeline: previous, reason: "Перед сборкой влога", to: &project) }
            timeline.versionName = Self.nextAIEditName(in: project)
            project.analyses = analyses
            project.storyPlans.append(plan); project.timelines.append(timeline)
            project.filmBuildRecovery = nil
            project.autonomousJob?.state = .completed; project.autonomousJob?.resultTimelineID = timeline.id
            Self.recordMusicCredit(from: timeline, tracks: tracks, in: &project)
        }
        return timeline
    }

    private func createFilmAttempt(
        prompt: String,
        preset: FilmPreset,
        targetDuration: Double? = nil,
        preferredMusicTrackID: UUID? = nil,
        directorBrief: DirectorBrief? = nil,
        avoidingTimeline: Timeline? = nil,
        intentIDs: [UUID],
        progress: FilmBuildProgressHandler?
    ) async throws -> Timeline {
        await progress?(FilmBuildProgress(.preparing))
        var projectSnapshot = await store.snapshot()
        var current = projectSnapshot.manifest
        var directorBrief = EditorialIntentEnforcer.updatedBrief(directorBrief, prompt: prompt)
        if let duration = directorBrief?.requestedDuration {
            directorBrief?.requestedDuration = AutomaticFilmDurationPolicy.normalizedRequest(duration)
        }
        let durationRequirement = FilmDurationRequirement.parse(prompt: prompt, explicitSeconds: targetDuration ?? directorBrief?.explicitRequestedDuration, mode: directorBrief?.durationMode)
        let targetDuration = durationRequirement.target
        if let targetDuration { directorBrief?.requestedDuration = targetDuration; directorBrief?.durationMode = durationRequirement.mode }
        if let preferredMusicTrackID, directorBrief != nil {
            // The explicit track parameter represents the latest user action
            // and therefore overrides an older questionnaire-level opt-out.
            directorBrief?.musicPolicy = .specificTrack
            directorBrief?.musicTrackID = preferredMusicTrackID
        }
        let usableAssets = current.assets.filter { !$0.excluded && !$0.missing }
        guard !usableAssets.isEmpty else {
            throw DirectorBriefFulfillmentError.noUsableSourceMaterial
        }
        var analyses = CrossVideoRelationshipAnalyzer().refine(
            Self.mergingTelemetrySources(into: current.analyses, sources: current.effectiveTelemetrySources)
        )
        analyses = Self.ensuringMetadataFallbackCandidates(
            in: analyses,
            assets: usableAssets,
            schemaVersion: current.analysisSchemaVersion
        )
        let usableAssetIDs = Set(usableAssets.map(\.id))
        guard analyses.flatMap(\.directorCandidates).contains(where: {
            usableAssetIDs.contains($0.assetID) && !$0.excluded && $0.sourceDuration > 0.05
        }) else {
            throw DirectorBriefFulfillmentError.noUsableMoments
        }
        if EditorialRolloutPolicy.isEnabled(in: current) {
            await progress?(FilmBuildProgress(.evidence))
            analyses = try await LocalEditorialEvidenceAnalyzer(cacheURL: await store.cacheURL).enrich(analyses: analyses, assets: usableAssets)
            // Legacy projects can appear sufficient when their few old
            // candidates are long, then fail every real sequence once moment
            // boundaries and repetition rules are applied. Productionize the
            // reusable source analysis once before planning instead of waiting
            // for all variants to fail with a duration underflow.
            await progress?(FilmBuildProgress(.moments))
            let needsProductionMining = EditorialCandidateMiner.requiresProductionization(analyses)
            analyses = try await EditorialCandidateMiner().expandIfNeeded(analyses: analyses, assets: usableAssets, requestedDuration: directorBrief?.explicitRequestedDuration ?? targetDuration, force: needsProductionMining, analyzer: LocalEditorialEvidenceAnalyzer(cacheURL: await store.cacheURL))
            if analyses != current.analyses {
                // Evidence mining is reusable project knowledge, not a side
                // effect of one candidate timeline. Persist it before variant
                // ranking so a rejected/cancelled attempt never throws the
                // newly discovered editorial units away.
                try await store.updateFilmBuildAnalyses(analyses, ifRevision: projectSnapshot.revision)
                projectSnapshot = await store.snapshot()
                current = projectSnapshot.manifest
            }
        }
        await progress?(FilmBuildProgress(.planning))
        let eventDiscovery = EventIntelligenceEngine().discover(assets: current.assets, analyses: analyses)
        let deviceTaste = await personalTasteStore.profile()
        let personalTaste = deviceTaste.totalSignalCount > 0 ? deviceTaste : (current.personalTasteProfile ?? deviceTaste)
        let requestedDuration = directorBrief?.explicitRequestedDuration ?? targetDuration
        let resolvedMusicTrackID: UUID?
        if directorBrief?.musicPolicy == DirectorMusicPolicy.none {
            resolvedMusicTrackID = nil
        } else if directorBrief?.musicPolicy == .specificTrack {
            resolvedMusicTrackID = directorBrief?.musicTrackID ?? preferredMusicTrackID
        } else {
            resolvedMusicTrackID = preferredMusicTrackID
        }
        if directorBrief?.musicPolicy == .specificTrack, resolvedMusicTrackID == nil {
            throw DirectorBriefFulfillmentError.specificMusicTrackNotSelected
        }
        var autonomous = AutonomousDirectorEngine().decide(
            prompt: prompt,
            fallbackPreset: preset,
            requestedDuration: requestedDuration,
            assets: current.assets,
            analyses: analyses,
            personalProfile: personalTaste,
            events: eventDiscovery.events,
            requestIsExplicit: directorBrief.map { $0.explicitRequestedDuration != nil }
        )
        if let directorBrief {
            autonomous = Self.applyingDirectorBrief(directorBrief, to: autonomous)
        }
        let allowsAutomaticMusic = directorBrief?.musicPolicy != DirectorMusicPolicy.none
            && directorBrief?.musicPolicy != .specificTrack
        let isAutomaticSoundtrack = allowsAutomaticMusic && resolvedMusicTrackID == nil
        let recentMusicIdentities = isAutomaticSoundtrack
            ? await musicSelectionHistory.recentIdentities()
            : []
        let baseConstraints = PromptInterpreter.defaults(for: preset)
        let explicitlyInterpretedConstraints = PromptInterpreter().interpret(
            prompt: prompt,
            preset: preset,
            base: baseConstraints
        )
        var lockedConstraints = Self.storyConstraintLocks(
            explicitIn: prompt,
            from: baseConstraints,
            to: explicitlyInterpretedConstraints
        )
        if directorBrief != nil {
            // The opening questionnaire is structured source-of-truth. Its
            // duration and mood must not be overridden by descriptive arc
            // text such as “start calmly, then add dynamics”.
            lockedConstraints.remove([.targetDuration, .pacing])
        }
        var constraints = explicitlyInterpretedConstraints
        // Keep requested runtime separate from the estimated source capacity.
        constraints.targetDuration = requestedDuration ?? autonomous.duration.seconds
        constraints.pacing = directorBrief?.mood.pacing ?? autonomous.finalStyle.pacing
        constraints.transitionFrequency = autonomous.grammar.transitionDensity
        constraints.allowSlowMotion = autonomous.grammar.slowMotionDensity > 0.025
        if lockedConstraints.contains(.targetDuration) { constraints.targetDuration = explicitlyInterpretedConstraints.targetDuration }
        if lockedConstraints.contains(.pacing) { constraints.pacing = explicitlyInterpretedConstraints.pacing }
        if lockedConstraints.contains(.transitionFrequency) { constraints.transitionFrequency = explicitlyInterpretedConstraints.transitionFrequency }
        if lockedConstraints.contains(.allowSlowMotion) { constraints.allowSlowMotion = explicitlyInterpretedConstraints.allowSlowMotion }
        let variantSearch = StoryEngine(editorialIntelligenceEnabled: EditorialRolloutPolicy.isEnabled(in: current)).createPlanVariantSearch(prompt: prompt, preset: preset, constraints: constraints, assets: current.assets, analyses: analyses, events: eventDiscovery.events, eventDiagnostics: eventDiscovery.diagnostics, limit: 10, autonomousDecision: autonomous, directorBrief: directorBrief, lockedConstraints: lockedConstraints)
        let storyVariants = variantSearch.variants
        let fallbackPlan = StoryPlan(prompt: prompt, preset: preset, constraints: constraints, chapters: [], autonomousDecision: autonomous, directorBrief: directorBrief)
        var effectiveStories = storyVariants.isEmpty ? [StoryPlanVariant(plan: fallbackPlan, strategy: "fallback", seedScore: 0)] : storyVariants
        if let resolvedMusicTrackID {
            for index in effectiveStories.indices { effectiveStories[index].plan.explicitMusicTrackID = resolvedMusicTrackID }
        }
        var roughTimelines = effectiveStories.map { TimelineComposer().compose(plan: $0.plan, assets: current.assets, analyses: analyses) }
        if let resolvedMusicTrackID,
           let preferredTrack = try await musicSystem.tracks().first(where: {
               $0.id == resolvedMusicTrackID && FileManager.default.fileExists(atPath: $0.localFileURL.path)
           }) {
            for index in roughTimelines.indices {
                roughTimelines[index].music = MusicDirective(
                    style: preferredTrack.suggestedStyle,
                    bpm: preferredTrack.bpm,
                    volume: roughTimelines[index].music?.volume ?? 0.22,
                    trackID: preferredTrack.id,
                    trackTitle: preferredTrack.title
                )
            }
        } else if directorBrief?.musicPolicy == .specificTrack, let resolvedMusicTrackID {
            throw DirectorBriefFulfillmentError.unavailableMusicTrack(resolvedMusicTrackID)
        } else if directorBrief?.musicPolicy != DirectorMusicPolicy.none {
            // Automatic mode intentionally looks for a fresh soundtrack. An
            // explicit local choice above is preserved and avoids a download.
            for index in roughTimelines.indices where roughTimelines[index].music != nil {
                roughTimelines[index].music?.trackID = nil
                roughTimelines[index].music?.trackTitle = nil
                roughTimelines[index].music?.preferDifferentTrack = true
            }
        }
        await progress?(FilmBuildProgress(.findingMusic))
        let resolutionTracks = try await tracksForResolving(
            roughTimelines.first?.music,
            excludingIdentities: recentMusicIdentities
        )
        if resolvedMusicTrackID == nil {
            try await acquireSectionMusic(timelines: roughTimelines, stories: effectiveStories, analyses: analyses, excludingIdentities: recentMusicIdentities)
        }
        let catalogTracks = try await musicSystem.tracks()
        let tracks = resolutionTracks + catalogTracks.filter { candidate in
            !resolutionTracks.contains(where: { $0.id == candidate.id }) &&
                (candidate.noveltyIdentities.isDisjoint(with: recentMusicIdentities) ||
                 (roughTimelines.first?.music?.searchRequests ?? []).contains { $0.exactTrack && $0.matches(title: candidate.title, artist: candidate.author) })
        }
        let variantProber = Self.preliminaryEditorialProber(for: renderedProber)
        var directedTimelines = await Self.directingVariants(
            stories: effectiveStories,
            roughTimelines: roughTimelines,
            tracks: tracks,
            assets: current.assets,
            analyses: analyses,
            allowsAdaptiveSoundtrack: resolvedMusicTrackID == nil,
            telemetry: Self.telemetryLookup(in: current),
            reviewCacheURL: CachePaths(root: await store.cacheURL).previewDerivedMediaDirectory,
            prober: variantProber,
            progress: progress
        )
        try Task.checkCancellation()
        if EditorialRolloutPolicy.isEnabled(in: current), !directedTimelines.contains(where: { $0.editorialReview?.rankingEligible == true }) {
            let fallbacks = ConservativeFallbackBuilder().candidates(stories: effectiveStories, reviewed: directedTimelines, assets: current.assets, analyses: analyses)
            for (index, fallback) in fallbacks.enumerated() {
                await progress?(FilmBuildProgress(.fallback, completed: index, total: fallbacks.count))
                try Task.checkCancellation()
                let checked = await Self.editorialRenderReview(timeline: fallback.timeline, plan: fallback.story.plan, assets: current.assets, analyses: analyses, tracks: tracks, telemetry: Self.telemetryLookup(in: current), cacheURL: CachePaths(root: await store.cacheURL).previewDerivedMediaDirectory, prober: variantProber)
                effectiveStories.append(fallback.story)
                directedTimelines.append(checked)
                if checked.editorialReview?.rankingEligible == true { break }
            }
        }
        try Task.checkCancellation()
        await progress?(FilmBuildProgress(.finishing))
        let tasteContext = TasteContextResolver().resolve(projectStyle: autonomous.projectStyle, assets: current.assets, analyses: analyses)
        let winner = MontageVariantSelector().select(
            stories: effectiveStories,
            timelines: directedTimelines,
            assets: current.assets,
            analyses: analyses,
            searchDiagnostics: variantSearch.diagnostics,
            personalTasteProfile: personalTaste,
            tasteContext: tasteContext,
            avoidingTimeline: avoidingTimeline,
            requireProductionEvidence: false,
            allowsQualityWarnings: true
        )
        guard let winner else {
            if let candidate = directedTimelines.max(by: { $0.duration < $1.duration }),
               let story = effectiveStories.first(where: { $0.plan.id == candidate.storyPlanID }) {
                let draft = FilmBuildDraft(phase: .finishing, timeline: candidate, plan: story.plan,
                    analyses: analyses, tracks: tracks, sourceMap: eventDiscovery.sourceMap,
                    events: eventDiscovery.events, personalTaste: personalTaste,
                    resolvedMusicTrackID: resolvedMusicTrackID, directorBrief: directorBrief,
                    checkpointReason: "Сохранённый черновик незавершённой сборки")
                try await store.checkpointFilmBuild(draft, ifRevision: projectSnapshot.revision)
            }
            if let longest = directedTimelines.max(by: {
                AutomaticFilmDurationPolicy.renderedDuration(of: $0) < AutomaticFilmDurationPolicy.renderedDuration(of: $1)
            }) {
                try AutomaticFilmDurationPolicy.validate(longest)
            }
            throw EditorialGenerationError.noPassingVariant(directedTimelines.flatMap { $0.editorialReview?.findings ?? [] })
        }
        let draft = FilmBuildDraft(
            phase: .finishing, timeline: winner.timeline, plan: winner.story.plan,
            analyses: analyses, tracks: tracks, sourceMap: eventDiscovery.sourceMap,
            events: eventDiscovery.events, personalTaste: personalTaste,
            resolvedMusicTrackID: resolvedMusicTrackID, directorBrief: directorBrief,
            checkpointReason: "Перед полной режиссёрской пересборкой"
        )
        return try await finishFilmBuild(draft, snapshot: projectSnapshot, intentIDs: intentIDs, progress: progress)
    }

    @discardableResult
    private func executeRegenerate(feedback: String, selectedCandidateID: UUID? = nil, preset: FilmPreset? = nil, targetDuration: Double? = nil, preferredMusicTrackID: UUID? = nil, directorBrief: DirectorBrief? = nil, ignoredFeedbackConstraints: StoryConstraintLocks = [], progress: FilmBuildProgressHandler? = nil) async throws -> Timeline {
        let pendingAtStart = await store.manifest.workspaceState?.pendingDirectorInstructions ?? []
        var feedback = (pendingAtStart.filter { !feedback.contains($0) } + [feedback]).joined(separator: "\n")
        var directorBrief = directorBrief
        for attempt in 0..<2 {
            let snapshot = await store.snapshot()
            if snapshot.manifest.storyPlans.isEmpty {
                return try await executeCreateFilm(prompt: feedback, preset: preset ?? .story, targetDuration: targetDuration, preferredMusicTrackID: preferredMusicTrackID, directorBrief: directorBrief, progress: progress)
            }
            let ids = try await store.beginEditorialGeneration(prompt: feedback, brief: directorBrief ?? snapshot.manifest.storyPlans.last?.directorBrief)
            do {
                let request = FilmBuildRequest(kind: .regenerate, prompt: feedback, preset: preset, targetDuration: targetDuration, preferredMusicTrackID: preferredMusicTrackID, directorBrief: directorBrief, selectedCandidateID: selectedCandidateID, ignoredFeedbackConstraints: ignoredFeedbackConstraints.rawValue)
                let draft = try await store.beginFilmBuildRecovery(request)
                return try await FilmBuildReporting.$handler.withValue(progress ?? FilmBuildReporting.handler) {
                    if (preset ?? snapshot.manifest.storyPlans.last?.preset) == .vlog {
                        return try await self.createVlogFilm(prompt: feedback, brief: directorBrief ?? snapshot.manifest.storyPlans.last?.directorBrief, targetDuration: targetDuration, preferredMusicTrackID: preferredMusicTrackID, intentIDs: ids, progress: progress)
                    }
                    if let draft {
                        return try await self.finishFilmBuild(draft, snapshot: await self.store.snapshot(), intentIDs: ids, progress: progress)
                    }
                    return try await regenerateAttempt(feedback: feedback, selectedCandidateID: selectedCandidateID, preset: preset, targetDuration: targetDuration, preferredMusicTrackID: preferredMusicTrackID, directorBrief: directorBrief, ignoredFeedbackConstraints: ignoredFeedbackConstraints, intentIDs: ids, progress: progress)
                }
            } catch {
                let wasCurrent = await store.isCurrentEditorialGeneration(ids: ids)
                try? await store.failEditorialGeneration(ids: ids, error: error)
                if case ProjectStoreError.staleRevision = error, attempt == 0, wasCurrent {
                    let latest = await store.manifest.workspaceState
                    if latest?.prompt != snapshot.manifest.workspaceState?.prompt { feedback = latest?.prompt ?? feedback }
                    if latest?.directorBrief != snapshot.manifest.workspaceState?.directorBrief { directorBrief = latest?.directorBrief }
                    if latest?.pendingDirectorInstructions != snapshot.manifest.workspaceState?.pendingDirectorInstructions {
                        feedback += "\n" + (latest?.pendingDirectorInstructions ?? []).joined(separator: "\n")
                    }
                    continue
                }
                throw error
            }
        }
        throw EditorialGenerationError.unsatisfiedIntent("Повторный конфликт ревизии")
    }

    @discardableResult
    private func regenerateAttempt(
        feedback: String,
        selectedCandidateID: UUID? = nil,
        preset: FilmPreset? = nil,
        targetDuration: Double? = nil,
        preferredMusicTrackID: UUID? = nil,
        directorBrief: DirectorBrief? = nil,
        ignoredFeedbackConstraints: StoryConstraintLocks = [],
        intentIDs: [UUID],
        progress: FilmBuildProgressHandler?
    ) async throws -> Timeline {
        await progress?(FilmBuildProgress(.preparing))
        var projectSnapshot = await store.snapshot()
        var current = projectSnapshot.manifest
        guard let oldPlan = current.storyPlans.last else {
            return try await executeCreateFilm(
                prompt: feedback,
                preset: preset ?? .story,
                targetDuration: targetDuration,
                preferredMusicTrackID: preferredMusicTrackID,
                directorBrief: directorBrief,
                progress: progress
            )
        }
        var candidates = current.analyses.flatMap(\.candidates)
        var updatedSeed = FeedbackEngine().apply(feedback: feedback, to: oldPlan, candidates: &candidates, selectedCandidateID: selectedCandidateID)
        let feedbackPreset = preset ?? oldPlan.preset
        let explicitlyInterpretedConstraints = Self.interpretedFeedbackConstraints(
            feedback,
            preset: feedbackPreset,
            base: oldPlan.constraints,
            ignoredConstraints: ignoredFeedbackConstraints
        )
        var lockedConstraints = Self.storyConstraintLocks(
            explicitIn: feedback,
            from: oldPlan.constraints,
            to: explicitlyInterpretedConstraints
        )
        lockedConstraints.subtract(ignoredFeedbackConstraints)
        if let preset, preset != updatedSeed.preset {
            updatedSeed.preset = preset
            updatedSeed.constraints = PromptInterpreter().interpret(
                prompt: feedback,
                preset: preset,
                base: updatedSeed.constraints
            )
        }
        var effectiveBrief = EditorialIntentEnforcer.updatedBrief(directorBrief ?? updatedSeed.directorBrief, prompt: feedback)
        if let duration = effectiveBrief?.requestedDuration {
            effectiveBrief?.requestedDuration = AutomaticFilmDurationPolicy.normalizedRequest(duration)
        }
        let durationRequirement = FilmDurationRequirement.parse(prompt: feedback, explicitSeconds: targetDuration ?? effectiveBrief?.explicitRequestedDuration, mode: effectiveBrief?.durationMode)
        let targetDuration = durationRequirement.target
        if let targetDuration { effectiveBrief?.requestedDuration = targetDuration; effectiveBrief?.durationMode = durationRequirement.mode }
        if let preferredMusicTrackID, effectiveBrief != nil {
            effectiveBrief?.musicPolicy = .specificTrack
            effectiveBrief?.musicTrackID = preferredMusicTrackID
        }
        let requestedDuration = effectiveBrief?.explicitRequestedDuration ?? targetDuration
        if let requestedDuration { updatedSeed.constraints.targetDuration = AutomaticFilmDurationPolicy.normalizedRequest(requestedDuration) }
        let usableAssets = current.assets.filter { !$0.excluded && !$0.missing }
        guard !usableAssets.isEmpty else {
            throw DirectorBriefFulfillmentError.noUsableSourceMaterial
        }
        var analyses = Self.mergingTelemetrySources(into: current.analyses, sources: current.effectiveTelemetrySources)
        analyses = Self.ensuringMetadataFallbackCandidates(
            in: analyses,
            assets: usableAssets,
            schemaVersion: current.analysisSchemaVersion
        )
        let editedCandidateIDs = Set(candidates.map(\.id))
        candidates.append(contentsOf: analyses.flatMap(\.candidates).filter {
            !editedCandidateIDs.contains($0.id)
        })
        let usableAssetIDs = Set(usableAssets.map(\.id))
        guard analyses.flatMap(\.directorCandidates).contains(where: {
            usableAssetIDs.contains($0.assetID) && !$0.excluded && $0.sourceDuration > 0.05
        }) else {
            throw DirectorBriefFulfillmentError.noUsableMoments
        }
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        for index in analyses.indices { analyses[index].candidates = analyses[index].candidates.compactMap { byID[$0.id] } }
        analyses = CrossVideoRelationshipAnalyzer().refine(analyses)
        if EditorialRolloutPolicy.isEnabled(in: current) {
            await progress?(FilmBuildProgress(.evidence))
            analyses = try await LocalEditorialEvidenceAnalyzer(cacheURL: await store.cacheURL).enrich(analyses: analyses, assets: usableAssets)
            await progress?(FilmBuildProgress(.moments))
            let needsProductionMining = EditorialCandidateMiner.requiresProductionization(analyses)
            analyses = try await EditorialCandidateMiner().expandIfNeeded(analyses: analyses, assets: usableAssets, requestedDuration: effectiveBrief?.explicitRequestedDuration ?? targetDuration, force: needsProductionMining, analyzer: LocalEditorialEvidenceAnalyzer(cacheURL: await store.cacheURL))
            if analyses != current.analyses {
                try await store.updateFilmBuildAnalyses(analyses, ifRevision: projectSnapshot.revision)
                projectSnapshot = await store.snapshot()
                current = projectSnapshot.manifest
            }
        }
        await progress?(FilmBuildProgress(.planning))
        let eventDiscovery = EventIntelligenceEngine().discover(assets: current.assets, analyses: analyses)
        let deviceTaste = await personalTasteStore.profile()
        let personalTaste = deviceTaste.totalSignalCount > 0 ? deviceTaste : (current.personalTasteProfile ?? deviceTaste)
        var autonomous = AutonomousDirectorEngine().decide(
            prompt: updatedSeed.prompt,
            fallbackPreset: updatedSeed.preset,
            requestedDuration: requestedDuration,
            assets: current.assets,
            analyses: analyses,
            personalProfile: personalTaste,
            events: eventDiscovery.events,
            requestIsExplicit: effectiveBrief.map { $0.explicitRequestedDuration != nil }
        )
        if let effectiveBrief {
            autonomous = Self.applyingDirectorBrief(effectiveBrief, to: autonomous)
        }
        let resolvedMusicTrackID: UUID?
        if effectiveBrief?.musicPolicy == DirectorMusicPolicy.none {
            resolvedMusicTrackID = nil
        } else if effectiveBrief?.musicPolicy == .specificTrack {
            resolvedMusicTrackID = effectiveBrief?.musicTrackID ?? preferredMusicTrackID
        } else {
            resolvedMusicTrackID = preferredMusicTrackID
        }
        if effectiveBrief?.musicPolicy == .specificTrack, resolvedMusicTrackID == nil {
            throw DirectorBriefFulfillmentError.specificMusicTrackNotSelected
        }
        updatedSeed.constraints.targetDuration = requestedDuration ?? autonomous.duration.seconds
        updatedSeed.constraints.pacing = effectiveBrief?.mood.pacing ?? autonomous.finalStyle.pacing
        updatedSeed.constraints.transitionFrequency = autonomous.grammar.transitionDensity
        updatedSeed.constraints.allowSlowMotion = autonomous.grammar.slowMotionDensity > 0.025
        if lockedConstraints.contains(.targetDuration) { updatedSeed.constraints.targetDuration = explicitlyInterpretedConstraints.targetDuration }
        if lockedConstraints.contains(.pacing) { updatedSeed.constraints.pacing = explicitlyInterpretedConstraints.pacing }
        if lockedConstraints.contains(.transitionFrequency) { updatedSeed.constraints.transitionFrequency = explicitlyInterpretedConstraints.transitionFrequency }
        if lockedConstraints.contains(.allowSlowMotion) { updatedSeed.constraints.allowSlowMotion = explicitlyInterpretedConstraints.allowSlowMotion }
        let variantSearch = StoryEngine(editorialIntelligenceEnabled: EditorialRolloutPolicy.isEnabled(in: current)).createPlanVariantSearch(prompt: updatedSeed.prompt, preset: updatedSeed.preset, constraints: updatedSeed.constraints, assets: current.assets, analyses: analyses, events: eventDiscovery.events, eventDiagnostics: eventDiscovery.diagnostics, limit: 10, autonomousDecision: autonomous, directorBrief: effectiveBrief, lockedConstraints: lockedConstraints)
        let storyVariants = variantSearch.variants
        let fallbackPlan = StoryPlan(prompt: updatedSeed.prompt, preset: updatedSeed.preset, constraints: updatedSeed.constraints, chapters: [], autonomousDecision: autonomous, directorBrief: effectiveBrief)
        var effectiveStories = storyVariants.isEmpty ? [StoryPlanVariant(plan: fallbackPlan, strategy: "fallback", seedScore: 0)] : storyVariants
        if let resolvedMusicTrackID {
            for index in effectiveStories.indices { effectiveStories[index].plan.explicitMusicTrackID = resolvedMusicTrackID }
        }
        var roughTimelines = effectiveStories.map { TimelineComposer().compose(plan: $0.plan, assets: current.assets, analyses: analyses) }
        if let previous = current.timelines.last {
            for index in roughTimelines.indices {
                roughTimelines[index] = Self.carryEditorAdjustments(from: previous, to: roughTimelines[index], directorBrief: effectiveBrief)
            }
        }
        if let resolvedMusicTrackID,
           let preferredTrack = try await musicSystem.tracks().first(where: {
               $0.id == resolvedMusicTrackID && FileManager.default.fileExists(atPath: $0.localFileURL.path)
           }) {
            for index in roughTimelines.indices {
                roughTimelines[index].music = MusicDirective(
                    style: preferredTrack.suggestedStyle,
                    bpm: preferredTrack.bpm,
                    volume: roughTimelines[index].music?.volume ?? 0.22,
                    trackID: preferredTrack.id,
                    trackTitle: preferredTrack.title
                )
            }
        } else if effectiveBrief?.musicPolicy == .specificTrack, let resolvedMusicTrackID {
            throw DirectorBriefFulfillmentError.unavailableMusicTrack(resolvedMusicTrackID)
        }
        await progress?(FilmBuildProgress(.findingMusic))
        let resolutionTracks = try await tracksForResolving(roughTimelines.first?.music)
        if resolvedMusicTrackID == nil {
            try await acquireSectionMusic(timelines: roughTimelines, stories: effectiveStories, analyses: analyses)
        }
        let catalogTracks = try await musicSystem.tracks()
        let tracks = resolutionTracks + catalogTracks.filter { candidate in
            !resolutionTracks.contains(where: { $0.id == candidate.id })
        }
        let variantProber = Self.preliminaryEditorialProber(for: renderedProber)
        var directedTimelines = await Self.directingVariants(
            stories: effectiveStories,
            roughTimelines: roughTimelines,
            tracks: tracks,
            assets: current.assets,
            analyses: analyses,
            allowsAdaptiveSoundtrack: resolvedMusicTrackID == nil,
            telemetry: Self.telemetryLookup(in: current),
            reviewCacheURL: CachePaths(root: await store.cacheURL).previewDerivedMediaDirectory,
            prober: variantProber,
            progress: progress
        )
        try Task.checkCancellation()
        if EditorialRolloutPolicy.isEnabled(in: current), !directedTimelines.contains(where: { $0.editorialReview?.rankingEligible == true }) {
            let fallbacks = ConservativeFallbackBuilder().candidates(stories: effectiveStories, reviewed: directedTimelines, assets: current.assets, analyses: analyses)
            for (index, fallback) in fallbacks.enumerated() {
                await progress?(FilmBuildProgress(.fallback, completed: index, total: fallbacks.count))
                try Task.checkCancellation()
                let checked = await Self.editorialRenderReview(timeline: fallback.timeline, plan: fallback.story.plan, assets: current.assets, analyses: analyses, tracks: tracks, telemetry: Self.telemetryLookup(in: current), cacheURL: CachePaths(root: await store.cacheURL).previewDerivedMediaDirectory, prober: variantProber)
                effectiveStories.append(fallback.story)
                directedTimelines.append(checked)
                if checked.editorialReview?.rankingEligible == true { break }
            }
        }
        try Task.checkCancellation()
        await progress?(FilmBuildProgress(.finishing))
        let tasteContext = TasteContextResolver().resolve(projectStyle: autonomous.projectStyle, assets: current.assets, analyses: analyses)
        let winner = MontageVariantSelector().select(stories: effectiveStories, timelines: directedTimelines, assets: current.assets, analyses: analyses, searchDiagnostics: variantSearch.diagnostics, personalTasteProfile: personalTaste, tasteContext: tasteContext, requireProductionEvidence: false, allowsQualityWarnings: true)
        guard let winner else {
            if let candidate = directedTimelines.max(by: { $0.duration < $1.duration }),
               let story = effectiveStories.first(where: { $0.plan.id == candidate.storyPlanID }) {
                let draft = FilmBuildDraft(phase: .finishing, timeline: candidate, plan: story.plan,
                    analyses: analyses, tracks: tracks, sourceMap: eventDiscovery.sourceMap,
                    events: eventDiscovery.events, personalTaste: personalTaste,
                    resolvedMusicTrackID: resolvedMusicTrackID, directorBrief: effectiveBrief,
                    checkpointReason: "Сохранённый черновик незавершённой сборки")
                try await store.checkpointFilmBuild(draft, ifRevision: projectSnapshot.revision)
            }
            if let longest = directedTimelines.max(by: {
                AutomaticFilmDurationPolicy.renderedDuration(of: $0) < AutomaticFilmDurationPolicy.renderedDuration(of: $1)
            }) {
                try AutomaticFilmDurationPolicy.validate(longest)
            }
            throw EditorialGenerationError.noPassingVariant(directedTimelines.flatMap { $0.editorialReview?.findings ?? [] })
        }
        let draft = FilmBuildDraft(
            phase: .finishing, timeline: winner.timeline, plan: winner.story.plan,
            analyses: analyses, tracks: tracks, sourceMap: eventDiscovery.sourceMap,
            events: eventDiscovery.events, personalTaste: personalTaste,
            resolvedMusicTrackID: resolvedMusicTrackID, directorBrief: effectiveBrief,
            checkpointReason: "Перед AI re-edit"
        )
        return try await finishFilmBuild(draft, snapshot: projectSnapshot, intentIDs: intentIDs, progress: progress)
    }

    /// Continues the exact request; reopening never silently applies a stale
    /// draft over changed media, settings or manual edits.
    public func resumeFilmBuild(progress: FilmBuildProgressHandler? = nil) async throws -> Timeline {
        guard let recovery = await store.recoverableFilmBuild() else {
            throw EditorialGenerationError.unsatisfiedIntent("Проект изменился после остановки. Запустите новую сборку по текущему брифу.")
        }
        await progress?(FilmBuildProgress(.resuming, detail: recovery.stageTitle))
        let r = recovery.request
        switch r.kind {
        case .create:
            return try await createFilm(prompt: r.prompt, preset: r.preset ?? .story, targetDuration: r.targetDuration, preferredMusicTrackID: r.preferredMusicTrackID, directorBrief: r.directorBrief, avoidingTimeline: r.avoidingTimeline, progress: progress)
        case .regenerate:
            return try await regenerate(feedback: r.prompt, selectedCandidateID: r.selectedCandidateID, preset: r.preset, targetDuration: r.targetDuration, preferredMusicTrackID: r.preferredMusicTrackID, directorBrief: r.directorBrief, ignoredFeedbackConstraints: StoryConstraintLocks(rawValue: r.ignoredFeedbackConstraints), progress: progress)
        }
    }

    private func finishFilmBuild(_ saved: FilmBuildDraft, snapshot: ProjectStoreSnapshot, intentIDs: [UUID], progress: FilmBuildProgressHandler?) async throws -> Timeline {
        var draft = saved
        let preservingSelection = saved.phase == .readyForPlayback
        let current = snapshot.manifest
        var plan = draft.plan
        plan.constraints = PromptInterpreter.removingOverlayTopic(from: plan.constraints, prompt: plan.prompt)
        if let reference = current.preferences.chapterTitleReference {
            plan = reference.applying(to: plan, assets: current.assets)
        }
        let explicitPreferences = await ExplicitEditorialPreferenceStore.shared.snapshot()
        if let style = draft.timeline.music?.style {
            plan.preferredChapterTitleDuration = explicitPreferences.preferredValue(.titles, style: style)
            if let pacing = explicitPreferences.preferredValue(.pacing, style: style),
               !Self.storyConstraintLocks(explicitIn: plan.prompt, from: PromptInterpreter.defaults(for: plan.preset), to: plan.constraints).contains(.pacing) {
                plan.constraints.pacing = min(1, max(0, plan.constraints.pacing + max(-0.1, min(0.1, pacing - plan.constraints.pacing))))
            }
        }
        var analyses = draft.analyses
        let tracks = draft.tracks
        let cacheURL = CachePaths(root: await store.cacheURL).previewDerivedMediaDirectory
        try Task.checkCancellation()
        try await store.checkpointFilmBuild(draft, ifRevision: snapshot.revision)
        var timeline = draft.timeline
        timeline.filmDeliveryReport = nil
        var deliveryWarnings: [String] = []
        let requestedRuntime = FilmDurationRequirement.parse(prompt: plan.prompt,
            explicitSeconds: draft.directorBrief?.explicitRequestedDuration ?? current.filmBuildRecovery?.request.targetDuration,
            mode: draft.directorBrief?.durationMode)
        if !preservingSelection, !requestedRuntime.accepts(duration: AutomaticFilmDurationPolicy.renderedDuration(of: timeline), frameRate: timeline.frameRate) {
            await progress?(FilmBuildProgress(.moments, detail: "Добираю материал до запрошенной длительности"))
            // One bounded source-wide expansion; cached, completed windows are
            // not analyzed again. The draft persists new evidence on failure.
            analyses = try await EditorialCandidateMiner().expandIfNeeded(analyses: analyses,
                assets: current.assets.filter { !$0.excluded && !$0.missing }, requestedDuration: requestedRuntime.target,
                force: true, analyzer: LocalEditorialEvidenceAnalyzer(cacheURL: await store.cacheURL))
            let repaired = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan, analyses: analyses, events: draft.events, assets: current.assets)
            if EditorialRenderSignature.signature(repaired.timeline) != EditorialRenderSignature.signature(timeline) {
                timeline = repaired.timeline
                plan = repaired.plan
                draft.phase = .finishing
            }
            draft.analyses = analyses
        }
        if draft.phase == .finishing {
            await progress?(FilmBuildProgress(.finishing))
            timeline = await Self.finalizePerceptualRenderReview(timeline: timeline, plan: plan, assets: current.assets, analyses: analyses, tracks: tracks, telemetry: Self.telemetryLookup(in: current), derivedMediaCacheURL: cacheURL)
            try Task.checkCancellation()
            let assembled = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan, analyses: analyses, events: draft.events, assets: current.assets)
            timeline = assembled.timeline
            plan = assembled.plan
            timeline = TimelineDeliveryContract().validateAndRepair(timeline: timeline, plan: plan, assets: current.assets, analyses: analyses).timeline
            timeline = await NaturalChapterTransitionPlanner().applying(to: timeline, plan: plan, assets: current.assets, analyses: analyses)
            try Task.checkCancellation()
            await progress?(FilmBuildProgress(.soundtrack))
            if let id = draft.resolvedMusicTrackID, let track = tracks.first(where: { $0.id == id }) {
                timeline = await Self.attachingExplicitMusic(track, to: timeline)
            } else {
                timeline = await Self.applyingAdaptiveSoundtrack(to: timeline, plan: plan, tracks: tracks, analyses: analyses)
            }
            timeline = EditorialIntentEnforcer.enforce(timeline, plan: plan)
            let finalCommands = DirectorRequestContract.commandsAfterGeneration(EditorCommandParser().parse(plan.prompt, preset: plan.preset))
            timeline = Self.clampedToAvailableMedia(EditorCommandExecutor().apply(finalCommands, to: timeline).timeline, assets: current.assets)
            draft.timeline = timeline
            draft.plan = plan
            draft.phase = .verifying
            try Task.checkCancellation()
            try await store.checkpointFilmBuild(draft, ifRevision: snapshot.revision)
        }
        await progress?(FilmBuildProgress(.verifying, detail: "Проверяю названия частей по выбранному материалу"))
        let titleModel = await LocalChapterTitleModel.configured(preferences: current.preferences, previousModelIdentity: timeline.chapterTitleDecisions?.first?.modelID)
        if !preservingSelection {
            timeline = try await SmartChapterTitleEngine().applying(to: timeline, plan: plan, assets: current.assets,
                analyses: analyses, mode: current.preferences.effectiveAIPowerMode, model: titleModel)
        }
        if !preservingSelection, plan.narrativeBeatPlan != nil {
            // Repair the complete preview before paying for delivery encoding.
            // Save that exact repaired edit so a restart resumes its export.
            if renderedProber is LocalEditorialRenderedProber {
                timeline = await Self.editorialRenderReview(timeline: timeline, plan: plan, assets: current.assets, analyses: analyses, tracks: tracks, telemetry: Self.telemetryLookup(in: current), cacheURL: cacheURL, prober: LocalEditorialRenderedProber(verifyExport: false), events: draft.events, analyzeChapterTransitions: true)
                try Task.checkCancellation()
                if timeline.editorialBeatPlan?.reasons.contains(AutomaticEditorialAssembly.marker) == true {
                    plan = AutomaticEditorialAssembly.reconcile(timeline: timeline, plan: plan, analyses: analyses, events: draft.events)
                    plan.contentBudget = timeline.editorialReview?.duration ?? plan.contentBudget
                }
                let delivery = TimelineDeliveryContract().validateAndRepair(timeline: timeline, plan: plan, assets: current.assets, analyses: analyses)
                timeline = delivery.timeline
                deliveryWarnings += delivery.blockingIssues.map(\.message)
                draft.timeline = timeline
                draft.plan = plan
                try await store.checkpointFilmBuild(draft, ifRevision: snapshot.revision)
            }
            timeline = await Self.editorialRenderReview(timeline: timeline, plan: plan, assets: current.assets, analyses: analyses, tracks: tracks, telemetry: Self.telemetryLookup(in: current), cacheURL: cacheURL, prober: renderedProber, events: draft.events, analyzeChapterTransitions: true)
            try Task.checkCancellation()
        }
        let settled = TimelineDeliveryContract().validateAndRepair(timeline: timeline, plan: plan, assets: current.assets, analyses: analyses)
        if !preservingSelection, plan.narrativeBeatPlan != nil,
           EditorialRenderSignature.signature(settled.timeline) != EditorialRenderSignature.signature(timeline),
           AutomaticFilmDelivery.preservesDelivery(settled.timeline, original: timeline, plan: plan) {
            timeline = settled.timeline
            // The last contract repair invalidates all earlier export evidence.
            // Inspect the repaired artifact directly without another edit loop.
            do {
                let frames = try await renderedProber.frames(timeline: timeline, assets: current.assets, tracks: tracks, telemetry: Self.telemetryLookup(in: current), cacheURL: cacheURL)
                timeline.editorialReview = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses, renderedFrames: frames, requireRenderedEvidence: true)
            } catch is CancellationError { throw CancellationError() }
            catch { timeline.editorialReview = nil }
        }
        let beforeDurationRecovery = EditorialRenderSignature.signature(timeline)
        if !preservingSelection {
            timeline = try await FilmDurationRecovery.extend(timeline, requirement: requestedRuntime,
                plan: plan, assets: current.assets, analyses: analyses)
        }
        let didRecoverDuration = EditorialRenderSignature.signature(timeline) != beforeDurationRecovery
        if didRecoverDuration {
            await progress?(FilmBuildProgress(.soundtrack, detail: "Подгоняю звук к полной длительности фильма"))
            if let id = draft.resolvedMusicTrackID, let track = tracks.first(where: { $0.id == id }) {
                timeline = await Self.attachingExplicitMusic(track, to: timeline)
            } else {
                timeline = await Self.applyingAdaptiveSoundtrack(to: timeline, plan: plan, tracks: tracks, analyses: analyses)
            }
        }
        let beforeFinalTitles = EditorialRenderSignature.signature(timeline)
        if !preservingSelection {
            timeline = try await SmartChapterTitleEngine().applying(to: timeline, plan: plan, assets: current.assets,
                analyses: analyses, mode: current.preferences.effectiveAIPowerMode, model: titleModel)
        }
        if let brief = draft.directorBrief, brief.subtitlePolicy == .on || timeline.speechRecords != nil {
            await progress?(FilmBuildProgress(.speech))
            let cache = await store.cacheURL
            let recognizer: any LocalSpeechRecognizing = speechRecognizer ?? WhisperKitSpeechRecognizer(cacheURL: cache)
            var records = timeline.speechRecords ?? []
            if brief.subtitlesEnabled(preset: plan.preset) {
                let ids = Set(timeline.items.compactMap(\.assetID))
                for asset in current.assets where ids.contains(asset.id) && asset.metadata.hasAudio && !records.contains(where: { $0.assetID == asset.id }) {
                    if let transcript = try await recognizer.transcribe(url: asset.originalURL, localeIdentifier: "ru") { records.append(SpeechSourceRecord(assetID: asset.id, transcript: transcript)) }
                }
            }
            timeline.speechRecords = records
            timeline = SpeechSubtitleBuilder.applying(to: timeline, records: records, enabled: brief.subtitlesEnabled(preset: plan.preset), allowMuted: brief.subtitlesWithoutAudio == true, previous: current.timelines.last, style: brief.subtitleStyle)
        }
        let didRenameTitles = EditorialRenderSignature.signature(timeline) != beforeFinalTitles
        var musicVerified = true
        do {
            try Self.validateDirectorMusic(timeline, brief: draft.directorBrief, tracks: tracks)
        } catch {
            musicVerified = false
            deliveryWarnings.append("Запрошенная музыка недоступна. Ролик сохранён с доступным звуком; музыку можно добавить позже.")
        }
        guard AutomaticFilmDelivery.hasContent(timeline) else { throw DirectorBriefFulfillmentError.noUsableSourceMaterial }
        if !AutomaticFilmDurationPolicy.meetsMinimum(timeline) {
            deliveryWarnings.append("Сохранён короткий ролик из доступных фрагментов.")
        }
        let requirement = FilmDurationRequirement.parse(prompt: plan.prompt,
            explicitSeconds: draft.directorBrief?.explicitRequestedDuration ?? current.filmBuildRecovery?.request.targetDuration,
            mode: draft.directorBrief?.durationMode)
        if !requirement.accepts(duration: AutomaticFilmDurationPolicy.renderedDuration(of: timeline), frameRate: timeline.frameRate) {
            deliveryWarnings.append("Доступный монтаж сохранён; его длительность отличается от запрошенной.")
        }
        // Persist the last real selection after every repair, not the earlier
        // preview draft. Resume this phase without reselection or soundtrack changes.
        draft.timeline = timeline
        draft.plan = plan
        draft.analyses = analyses
        draft.phase = .readyForPlayback
        try await store.checkpointFilmBuild(draft, ifRevision: snapshot.revision)
        try await store.updateAutonomousJob { $0.stage = .playback }
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: current.assets, musicTracks: tracks,
            telemetry: Self.telemetryLookup(in: current), forceVideoComposition: true)
        guard playback.skippedItemIDs.isEmpty, playback.renderedItemCount > 0,
              abs(playback.duration - AutomaticFilmDurationPolicy.renderedDuration(of: timeline)) <= 1 / timeline.frameRate + 0.001 else {
            throw AutonomousOperationError.verificationFailed("Просмотр текущей композиции не прошёл проверку: показано \(playback.renderedItemCount), пропущено \(playback.skippedItemIDs.count) [\(playback.skippedItemIDs.map(\.uuidString).joined(separator: ","))]; длительность \(playback.duration) с, ожидается \(AutomaticFilmDurationPolicy.renderedDuration(of: timeline)) с. Выбранный монтаж сохранён для повторной проверки.")
        }
        if preservingSelection {
            try await FilmBuildRecovery.validateSelectedAudio(timeline: timeline, assets: current.assets, tracks: tracks)
        }
        if timeline.editorialReview?.evidenceDomains?.first(where: { $0.domain == .renderDecode })?.isSufficient != true {
            let frames = await PerceptualRenderInspector().inspectAsync(playback: playback, timeline: timeline, maximumSamples: 8)
            guard !frames.isEmpty, frames.allSatisfy({ $0.decodeFailed != true }) else {
                throw AutonomousOperationError.verificationFailed("Кадры текущего фильма не декодируются")
            }
        }
        if preservingSelection || plan.narrativeBeatPlan == nil || didRecoverDuration || didRenameTitles {
            do {
                let frames = try await renderedProber.frames(timeline: timeline, assets: current.assets, tracks: tracks, telemetry: Self.telemetryLookup(in: current), cacheURL: cacheURL)
                timeline.editorialReview = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses, renderedFrames: frames, requireRenderedEvidence: true)
            } catch is CancellationError { throw CancellationError() }
            catch {
                if preservingSelection {
                    throw AutonomousOperationError.verificationFailed("Не удалось проверить сохранённый монтаж: \(error.localizedDescription). Черновик сохранён без замены событий, музыки и титров.")
                }
                deliveryWarnings.append("Фильм сохранён для просмотра; контрольный экспорт будет повторён при сохранении видео.")
            }
        }
        try Task.checkCancellation()
        timeline.filmDeliveryReport = AutomaticFilmDelivery.verifiedReport(for: timeline, plan: plan, assets: current.assets, analyses: analyses, additionalWarnings: deliveryWarnings)
        if !musicVerified {
            timeline.filmDeliveryReport?.requirements?.append(.init(sourcePhrase: plan.prompt, rule: "musicAvailability", verificationMethod: "Resolved local soundtrack file", passed: false, evidence: "Запрошенная музыка недоступна; сохранён фильм с доступным звуком"))
        }
        await progress?(FilmBuildProgress(.saving))
        try await store.update(ifRevision: snapshot.revision) { project in
            timeline = try ProjectStore.verifyAndFulfillEditorialGeneration(in: &project, ids: intentIDs, timeline: timeline, analyses: analyses)
            if let previous = project.timelines.last {
                Self.appendCheckpoint(timeline: previous, reason: draft.checkpointReason, to: &project)
            }
            timeline.versionName = Self.nextAIEditName(in: project)
            project.personalTasteProfile = draft.personalTaste
            project.analyses = analyses
            project.sourceMap = draft.sourceMap
            project.events = draft.events
            project.storyPlans.append(plan)
            project.timelines.append(timeline)
            Self.recordMusicCredit(from: timeline, tracks: tracks, in: &project)
            // Atomic with the Timeline commit: a crash cannot publish it twice.
            project.filmBuildRecovery = nil
            project.autonomousJob?.state = .completed
            project.autonomousJob?.stage = .committing
            project.autonomousJob?.resultTimelineID = timeline.id
        }
        let selected = Set([timeline.music?.trackID].compactMap { $0 } + (timeline.effectiveAdaptiveSoundtrack?.segments.compactMap(\.directive.trackID) ?? []))
        for track in tracks where selected.contains(track.id) { try? await musicSelectionHistory.record(track) }
        return timeline
    }

    /// Records natural editing behavior without paths, text, media IDs or a
    /// manual A/B prompt. Signals update both project-specific and device-local
    /// Bayesian preference state.
    @discardableResult
    public func recordPreferenceSignals(
        before: Timeline,
        after: Timeline,
        source: PreferenceSignalSource = .manualEdit
    ) async throws -> [PreferenceSignal] {
        guard before != after else { return [] }
        let current = await store.manifest
        let analyses = Self.mergingTelemetrySources(into: current.analyses, sources: current.effectiveTelemetrySources)
        let candidates = Dictionary(uniqueKeysWithValues: analyses.flatMap(\.directorCandidates).map { ($0.id, $0) })
        let projectStyle = after.directorRun?.autonomousDecision?.projectStyle
            ?? before.directorRun?.autonomousDecision?.projectStyle
            ?? AutonomousProjectStyleEngine().infer(assets: current.assets, analyses: analyses, fallbackPreset: current.storyPlans.last?.preset ?? .story, events: current.events)
        let context = TasteContextResolver().resolve(projectStyle: projectStyle, timeline: after, assets: current.assets, analyses: analyses)
        let signals = AdaptivePreferenceSignalExtractor().signals(before: before, after: after, context: context, candidates: candidates, source: source)
        guard !signals.isEmpty else { return [] }
        let plan = current.storyPlans.last(where: { $0.id == after.storyPlanID })
            ?? current.storyPlans.last(where: { $0.id == before.storyPlanID })
        let regressionSample: TasteRegressionSample? = plan.map { plan in
            let scorer = DefaultMontageGlobalScorer()
            let beforeGlobal = scorer.score(plan: plan, timeline: before, assets: current.assets, analyses: analyses).total
            let afterGlobal = scorer.score(plan: plan, timeline: after, assets: current.assets, analyses: analyses).total
            let beforePerceptual = before.directorRun?.perceptualScoreAfter ?? before.directorRun?.perceptualScoreBefore ?? beforeGlobal
            let afterPerceptual = after.directorRun?.perceptualScoreAfter ?? after.directorRun?.perceptualScoreBefore ?? afterGlobal
            let extractor = TimelineTasteFeatureExtractor()
            return TasteRegressionSample(
                contextKey: context.key,
                proposedFeatures: extractor.features(timeline: before, candidates: candidates),
                acceptedFeatures: extractor.features(timeline: after, candidates: candidates),
                proposedAutomaticQuality: beforeGlobal * 0.76 + beforePerceptual * 0.24,
                acceptedAutomaticQuality: afterGlobal * 0.76 + afterPerceptual * 0.24
            )
        }
        let learning = try await personalTasteStore.recordValidated(signals, regressionSample: regressionSample)
        let updated = learning.profile
        try await store.update { project in
            project.personalTasteProfile = updated
            var history = project.preferenceSignals ?? []
            history.append(contentsOf: signals)
            if history.count > 240 { history.removeFirst(history.count - 240) }
            project.preferenceSignals = history
            if let index = project.timelines.indices.last, var run = project.timelines[index].directorRun {
                var diagnostics = run.personalTasteDiagnostics ?? PersonalTasteDiagnostics(
                    contextKey: context.key,
                    profileConfidence: updated.adaptiveConfidence,
                    signalCount: updated.totalSignalCount,
                    discoveredStyle: updated.discoveredStyle,
                    explorationApplied: false
                )
                diagnostics.regressionReport = learning.report
                diagnostics.reasons.append(contentsOf: learning.report.reasons)
                run.personalTasteDiagnostics = diagnostics
                project.timelines[index].directorRun = run
            }
        }
        return signals
    }

    public func exportPersonalTasteProfile(to url: URL) async throws {
        try await personalTasteStore.export(to: url)
    }

    public func importPersonalTasteProfile(from url: URL) async throws {
        let imported = try await personalTasteStore.importProfile(from: url)
        try await store.update { project in
            project.personalTasteProfile = imported
        }
    }

    public func resetPersonalTasteProfile() async throws {
        let empty = try await personalTasteStore.reset()
        try await store.update { project in
            project.personalTasteProfile = empty
            project.preferenceSignals = []
        }
    }

    public func timelineCheckpoints() async -> [TimelineCheckpoint] {
        (await store.manifest).timelineCheckpoints ?? []
    }

    @discardableResult
    public func restoreTimelineCheckpoint(id: UUID) async throws -> Timeline? {
        var restored: Timeline?
        try await store.update { project in
            guard let checkpoint = project.timelineCheckpoints?.first(where: { $0.id == id }) else { return }
            if let current = project.timelines.last {
                Self.appendCheckpoint(timeline: current, reason: "Перед восстановлением \(checkpoint.name)", to: &project)
            }
            var timeline = checkpoint.timeline
            timeline.id = UUID()
            timeline.versionName = "Восстановлено · \(checkpoint.name)"
            timeline.createdAt = Date()
            project.timelines.append(timeline)
            restored = timeline
        }
        return restored
    }

    public func generateDerivedMedia(progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws {
        let current = await store.manifest
        let paths = CachePaths(root: await store.cacheURL)
        let thumbnailer = ThumbnailGenerator()
        let proxy = ProxyGenerator()
        for (index, asset) in current.assets.enumerated() {
            progress?(ImportProgress(completed: index, total: current.assets.count, currentName: asset.displayName))
            _ = try? await thumbnailer.generate(for: asset, destination: paths.thumbnail(for: asset))
            if asset.kind == .video { _ = try? await proxy.generate(for: asset, destination: paths.proxy(for: asset)) }
        }
        progress?(ImportProgress(completed: current.assets.count, total: current.assets.count, currentName: "Облегчённые копии готовы"))
    }

    /// Generates only small JPEG previews. Unlike proxies this is quick enough
    /// to run after import and makes the source browser immediately useful.
    @discardableResult
    public func generateThumbnails(progress: (@Sendable (ImportProgress) -> Void)? = nil) async -> [String] {
        let current = await store.manifest
        let paths = CachePaths(root: await store.cacheURL)
        let thumbnailer = ThumbnailGenerator()
        var errors: [String] = []
        for (index, asset) in current.assets.enumerated() {
            if Task.isCancelled { break }
            progress?(ImportProgress(completed: index, total: current.assets.count, currentName: "Кадр: \(asset.displayName)"))
            do { _ = try await thumbnailer.generate(for: asset, destination: paths.thumbnail(for: asset)) }
            catch { errors.append("\(asset.displayName): \(error.localizedDescription)") }
        }
        progress?(ImportProgress(completed: current.assets.count, total: current.assets.count, currentName: "Изображения предварительного просмотра исходников готовы"))
        return errors
    }

    public func thumbnailURLs() async -> [UUID: URL] {
        let current = await store.manifest
        let paths = CachePaths(root: await store.cacheURL)
        return Dictionary(uniqueKeysWithValues: current.assets.compactMap { asset in
            let url = paths.thumbnail(for: asset)
            return FileManager.default.fileExists(atPath: url.path) ? (asset.id, url) : nil
        })
    }

    /// Timeline cards use a frame from the selected source range, not the
    /// generic asset thumbnail. This keeps trims and regenerated edits honest.
    public func timelineThumbnailURLs() async -> [UUID: URL] {
        await timelineFilmstripURLs()
    }

    /// Generates evenly-spaced frames across every edited source range so a
    /// timeline filmstrip communicates motion instead of repeating one poster.
    public func timelineFilmstripURLs(sampleCount: Int = 16) async -> [UUID: URL] {
        let current = await store.manifest
        guard let timeline = current.timelines.last else { return [:] }
        let assets = Dictionary(uniqueKeysWithValues: current.assets.map { ($0.id, $0) })
        let paths = CachePaths(root: await store.cacheURL)
        let thumbnailer = ThumbnailGenerator()
        var result: [UUID: URL] = [:]
        for item in timeline.items {
            guard let assetID = item.assetID, let asset = assets[assetID] else { continue }
            if asset.kind == .photo {
                let url = paths.thumbnail(for: asset)
                if FileManager.default.fileExists(atPath: url.path) { result[item.id] = url }
                continue
            }
            let count = max(1, sampleCount)
            let times = (0..<count).map { index in
                let fraction = (Double(index) + 0.5) / Double(max(1, sampleCount))
                return item.sourceStart + item.sourceDuration * fraction
            }
            let filmstripURL = paths.timelineFilmstrip(for: item, asset: asset, sampleCount: count)
            if let generated = try? await thumbnailer.generateFilmstrip(
                for: asset,
                destination: filmstripURL,
                times: times
            ) {
                result[item.id] = generated
            } else {
                let fallback = paths.thumbnail(for: asset)
                if FileManager.default.fileExists(atPath: fallback.path) { result[item.id] = fallback }
            }
        }
        return result
    }

    /// Returns only already-generated timeline images. Project opening uses
    /// this path so a visible editor is never held behind video frame decoding.
    public func cachedTimelineThumbnailURLs() async -> [UUID: URL] {
        await cachedTimelineFilmstripURLs()
    }

    public func cachedTimelineFilmstripURLs(sampleCount: Int = 16) async -> [UUID: URL] {
        let current = await store.manifest
        guard let timeline = current.timelines.last else { return [:] }
        let assets = Dictionary(uniqueKeysWithValues: current.assets.map { ($0.id, $0) })
        let paths = CachePaths(root: await store.cacheURL)
        return Dictionary(uniqueKeysWithValues: timeline.items.compactMap { item in
            guard let assetID = item.assetID, let asset = assets[assetID] else { return nil }
            if asset.kind == .video {
                let filmstrip = paths.timelineFilmstrip(for: item, asset: asset, sampleCount: max(1, sampleCount))
                if FileManager.default.fileExists(atPath: filmstrip.path) { return (item.id, filmstrip) }
            }
            let preferred = asset.kind == .photo ? paths.thumbnail(for: asset) : paths.timelineThumbnail(for: item, asset: asset)
            if FileManager.default.fileExists(atPath: preferred.path) { return (item.id, preferred) }
            let fallback = paths.thumbnail(for: asset)
            return FileManager.default.fileExists(atPath: fallback.path) ? (item.id, fallback) : nil
        })
    }

    public func makePlayback(
        timeline timelineOverride: Timeline? = nil,
        projectSnapshot: ProjectManifest? = nil,
        interactiveQuality: RenderQuality? = nil,
        interactiveLongEdge: Int? = nil,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> TimelinePlayback {
        let current: ProjectManifest
        if let projectSnapshot {
            // An optimistic edit already has an immutable project snapshot.
            // Do not queue preview behind encoding/writing a large manifest.
            current = projectSnapshot
        } else {
            try await migrateLegacyTimelineAudioSettings()
            current = await store.manifest
        }
        guard var timeline = timelineOverride ?? current.timelines.last else { throw FCPXMLExportError.invalidTimeline("Нет созданного фильма") }
        timeline = AutomaticFramingPolicy.applying(to: timeline, assets: current.assets, analyses: current.analyses)
        if let interactiveQuality {
            timeline = RenderGeometryPolicy.timeline(timeline, for: interactiveQuality)
        } else if let interactiveLongEdge, interactiveLongEdge > 0, max(timeline.width, timeline.height) > interactiveLongEdge {
            let scale = Double(interactiveLongEdge) / Double(max(timeline.width, timeline.height))
            timeline.width = max(2, Int((Double(timeline.width) * scale / 2).rounded()) * 2)
            timeline.height = max(2, Int((Double(timeline.height) * scale / 2).rounded()) * 2)
        }
        let telemetry = Self.telemetryLookup(in: current)
        let musicTracks = try await musicSystem.tracks()
        let referencedIDs = Set(timeline.items.compactMap(\.assetID))
        let largeVideoAssets = current.assets.filter { asset in
            guard referencedIDs.contains(asset.id), asset.kind == .video,
                  let width = asset.metadata.width, let height = asset.metadata.height else { return false }
            return max(width, height) >= 3840
        }
        let paths = CachePaths(root: store.packageURL.appendingPathComponent("Cache", isDirectory: true))
        let proxyGenerator = ProxyGenerator()
        var playbackSources: [UUID: URL] = [:]
        for asset in largeVideoAssets {
            try Task.checkCancellation()
            // Analysis and manually-created copies are just as reusable as
            // the dedicated preview cache. Original playback is a normal
            // cache miss; actual source failures are reported by the player.
            if let proxy = try await proxyGenerator.cachedProxy(for: asset, paths: paths) {
                playbackSources[asset.id] = proxy
            }
        }
        return try await PlaybackEngine().build(
            timeline: timeline,
            assets: current.assets,
            musicTracks: musicTracks,
            telemetry: telemetry,
            preferredVideoSources: playbackSources,
            // Preview the current SDR delivery format, including its HDR-to-SDR
            // conversion. Inferring HDR from any camera clip sends an HLG/PQ
            // surface to AVPlayerView and makes the editor differ from export.
            outputColorProfile: .rec709,
            derivedMediaCacheURL: paths.previewDerivedMediaDirectory,
            // All visual layers remain in the composition so paused frames,
            // live playback and export show the same edit.
            preferStableRealtimePreview: true,
            progress: progress
        )
    }

    /// Optional integrity pass. It is deliberately not part of import because
    /// reading every byte of large camera files makes adding media feel stuck.
    @discardableResult
    public func verifyFullHashes(progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> Int {
        let current = await store.manifest
        let pending = current.assets.filter { $0.fullContentHash == nil && !$0.missing }
        var hashes: [UUID: String] = [:]
        for (index, asset) in pending.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            progress?(ImportProgress(completed: index, total: pending.count, currentName: "Проверка: \(asset.displayName)"))
            hashes[asset.id] = try MediaImporter.sha256(url: asset.originalURL)
        }
        try await store.update { project in
            for index in project.assets.indices {
                if let hash = hashes[project.assets[index].id] { project.assets[index].fullContentHash = hash }
            }
        }
        progress?(ImportProgress(completed: pending.count, total: pending.count, currentName: "Проверка завершена"))
        return pending.count
    }

    public func ensureProxy(for assetID: UUID) async throws -> URL {
        let current = await store.manifest
        guard let asset = current.assets.first(where: { $0.id == assetID }) else { throw MediaImportError.unreadable(URL(fileURLWithPath: "asset://\(assetID)")) }
        let paths = CachePaths(root: await store.cacheURL)
        return try await ProxyGenerator().generate(for: asset, destination: paths.proxy(for: asset))
    }

    public func exportFCPXML(to url: URL, mode: FCPXMLExportMode = .edit) async throws {
        try await migrateLegacyTimelineAudioSettings()
        let current = await store.manifest
        guard let timeline = current.timelines.last else { throw FCPXMLExportError.invalidTimeline("Нет созданного фильма") }
        let exporter = FCPXMLExporter()
        var renderedFallbackURL: URL?
        if mode == .edit, exporter.requiresRenderedFallback(for: timeline) {
            let stem = url.deletingPathExtension().lastPathComponent
            let fallback = url.deletingLastPathComponent()
                .appendingPathComponent("\(stem)-rendered-reference")
                .appendingPathExtension("mp4")
            _ = try await RenderEngine().render(
                timeline: timeline,
                assets: current.assets,
                musicTracks: try await musicSystem.tracks(),
                telemetry: Self.telemetryLookup(in: current),
                quality: .maximum,
                destination: fallback
            )
            renderedFallbackURL = fallback
        }
        try exporter.export(
            timeline: timeline,
            assets: current.assets,
            mode: mode,
            renderedFallbackURL: renderedFallbackURL,
            to: url
        )
    }

    public func defaultVideoDestination() async -> URL {
        ProjectVideoFiles.destination(nextTo: store.packageURL)
    }

    /// Expose an older export without encoding it again. Keep the embedded
    /// original so a failed copy or manifest save cannot lose the user's film.
    public func copyExportNextToProject(jobID: UUID) async throws -> URL {
        let snapshot = await store.snapshot()
        guard let job = snapshot.manifest.renderJobs.first(where: { $0.id == jobID }),
              job.status == .completed else { throw CocoaError(.fileReadNoSuchFile) }
        guard ProjectVideoFiles.isInsideProject(job.outputURL, package: store.packageURL) else { return job.outputURL }
        let destination = ProjectVideoFiles.destination(nextTo: store.packageURL, fileExtension: job.outputURL.pathExtension)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".veloedit-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: job.outputURL, to: staging)
        let hash = try MediaImporter.sha256(url: staging)
        guard hash == (try job.artifactHash ?? MediaImporter.sha256(url: job.outputURL)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        // moveItem never replaces an existing file if another export won the
        // destination between choosing the name and publishing the copy.
        try FileManager.default.moveItem(at: staging, to: destination)
        try await store.update { project in
            guard let index = project.renderJobs.firstIndex(where: { $0.id == jobID && $0.outputURL == job.outputURL }) else { return }
            project.renderJobs[index].outputURL = destination
        }
        return destination
    }

    public func resumeExport(progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> RenderReport? {
        let current = await store.manifest
        guard current.autonomousJob?.kind == .export,
              current.autonomousJob?.state.resumesAutomatically == true,
              current.autonomousJob?.explicitCancellation != true,
              let job = current.renderJobs.last(where: { [.queued, .running].contains($0.status) }) else { return nil }
        return try await render(to: job.outputURL, quality: job.quality, frameRate: job.frameRate,
                                replaceExisting: job.replacesExistingFile == true, progress: progress)
    }

    public func render(to url: URL, quality: RenderQuality, frameRate: Double? = nil, replaceExisting: Bool = false, progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> RenderReport {
        let snapshot = await store.snapshot()
        return try await PerformanceTrace.measure(name: "export", projectID: snapshot.manifest.id, revision: String(snapshot.revision)) {
            try await self.renderImpl(to: url, quality: quality, frameRate: frameRate, replaceExisting: replaceExisting, progress: progress)
        }
    }

    private func renderImpl(to url: URL, quality: RenderQuality, frameRate: Double?, replaceExisting: Bool, progress: (@Sendable (ImportProgress) -> Void)?) async throws -> RenderReport {
        let lease = try ProjectOperationLease(package: store.packageURL)
        defer { withExtendedLifetime(lease) {} }
        try await migrateLegacyTimelineAudioSettings()
        _ = try await recoverMissingSources()
        let current = await store.manifest
        let pending = current.renderJobs.last { $0.outputURL == url && [.queued, .running].contains($0.status) }
        guard let timeline = pending.flatMap({ job in current.timelines.first { $0.id == job.timelineID } }) ?? current.timelines.last else {
            throw FCPXMLExportError.invalidTimeline("Нет созданного фильма")
        }
        let tracks = try await musicSystem.tracks()
        let delivery = ExportSettingsPolicy.timeline(timeline, assets: current.assets, quality: quality, frameRate: frameRate)
        let estimate = ExportPreflight.estimatedOutputBytes(timeline: delivery, quality: quality, profile: .rec709)
        if let capacity = ExportPreflight.availableCapacity(near: url), capacity < estimate {
            _ = try ProjectCacheMaintenance.removeOrphanedArtifacts(package: store.packageURL, manifest: current)
        }
        let signature = EditorialRenderDependencies.signature(timeline: delivery, assets: current.assets, tracks: tracks) + "|" + quality.rawValue
        var job = pending ?? RenderJob(timelineID: timeline.id, quality: quality, outputURL: url)
        if let previous = job.inputSignature, previous != signature {
            throw AutonomousOperationError.verificationFailed("Монтаж изменился после начала экспорта; прежний файл сохранён.")
        }
        if pending == nil, FileManager.default.fileExists(atPath: url.path), !replaceExisting {
            throw CocoaError(.fileWriteFileExists)
        }
        job.frameRate = frameRate
        job.inputSignature = signature
        job.replacesExistingFile = replaceExisting
        job.status = .running
        _ = try await store.beginAutonomousJob(kind: .export)
        try await store.updateAutonomousJob { $0.stage = .export; $0.state = .running }
        try await persistRenderJob(job)
        let staged = url.deletingLastPathComponent().appendingPathComponent(".veloedit-job-\(job.id.uuidString).mp4")
        let settings = ExportVideoSettings(timeline: delivery, quality: quality)
        let duration = AutomaticFilmDurationPolicy.renderedDuration(of: delivery)
        var useSoftware = await store.manifest.autonomousJob?.attempts.contains { $0.strategy == "software-delivery-encoder" } == true
        do {
            while true {
                try Task.checkCancellation()
                do {
                    var verifiedURL: URL?
                    if let hash = job.artifactHash {
                        for candidate in [staged, url] where FileManager.default.fileExists(atPath: candidate.path) {
                            if try MediaImporter.sha256(url: candidate) == hash { verifiedURL = candidate; break }
                        }
                    }
                    let report: RenderReport
                    if let verifiedURL {
                        let info = try await ExportVideoVerifier.verify(url: verifiedURL, settings: settings, duration: duration)
                        report = RenderReport(outputURL: verifiedURL, renderedItemCount: timeline.items.count, skippedItemIDs: [], videoInfo: info)
                    } else {
                        #if DEBUG
                        try AutonomyFaultInjection.check(.export, attempt: (await store.manifest.autonomousJob?.attempts.count ?? 0) + 1)
                        #endif
                        report = try await RenderEngine().render(timeline: timeline, assets: current.assets, analyses: current.analyses,
                            musicTracks: tracks, telemetry: Self.telemetryLookup(in: current), quality: quality, frameRate: frameRate,
                            destination: staged, softwareEncoder: useSoftware, progress: progress)
                        guard report.skippedItemIDs.isEmpty else {
                            throw AutonomousOperationError.verificationFailed("В готовом файле отсутствуют элементы монтажа")
                        }
                        try Task.checkCancellation()
                        job.artifactHash = try MediaImporter.sha256(url: staged)
                        job.verifiedStagingURL = staged
                        job.videoSummary = report.videoInfo?.summary
                        // This verified signature is durable before publication.
                        try await persistRenderJob(job)
                        verifiedURL = staged
                    }
                    try Task.checkCancellation()
                    if verifiedURL == staged {
                        if FileManager.default.fileExists(atPath: url.path) {
                            guard replaceExisting else { throw CocoaError(.fileWriteFileExists) }
                            _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
                        } else { try FileManager.default.moveItem(at: staged, to: url) }
                    }
                    if !current.effectiveMusicCredits.isEmpty {
                        let credits = url.deletingPathExtension().appendingPathExtension("music-credits.json")
                        try LocalProjectRecovery.durableWrite(JSONEncoder.veloEdit.encode(current.effectiveMusicCredits), to: credits)
                    }
                    job.status = .completed
                    job.progress = 1
                    job.completedAt = Date()
                    job.verifiedStagingURL = nil
                    let completedJob = job
                    try await store.persistOperationalState { project in
                        if let index = project.renderJobs.firstIndex(where: { $0.id == completedJob.id }) { project.renderJobs[index] = completedJob }
                        project.autonomousJob?.state = .completed
                        project.autonomousJob?.resultTimelineID = timeline.id
                    }
                    return RenderReport(outputURL: url, renderedItemCount: report.renderedItemCount, skippedItemIDs: [], warnings: report.warnings, videoInfo: report.videoInfo)
                } catch {
                    let cause = AutonomousFailureCause.classify(error)
                    let strategy = cause == .encoder ? "software-delivery-encoder" : "reopen-export-dependencies"
                    guard cause == .encoder || cause == .transientNetwork,
                          let delay = try await store.reserveRecovery(error: error, strategy: strategy) else { throw error }
                    if cause == .encoder { useSoftware = true }
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        } catch {
            let cancelled = await store.manifest.autonomousJob?.explicitCancellation == true
            job.status = cancelled ? .cancelled : error is CancellationError ? .queued : .failed
            job.errorMessage = error.localizedDescription
            try? await persistRenderJob(job)
            try? await store.updateAutonomousJob { $0.state = cancelled ? .cancelled : error is CancellationError ? .queued : .failed }
            if await recordExternalDependencyIfNeeded(error) {
                job.status = .queued
                try? await persistRenderJob(job)
            }
            await writeAutonomousDiagnostic(error)
            throw error
        }
    }

    private func persistRenderJob(_ job: RenderJob) async throws {
        try await store.persistOperationalState { project in
            if let index = project.renderJobs.firstIndex(where: { $0.id == job.id }) { project.renderJobs[index] = job }
            else { project.renderJobs.append(job) }
        }
    }

    public func unfinishedPersistentJobs() async -> [PersistentJobState] {
        await PersistentJobStateStore(directory: await store.logsURL).unfinishedStates()
    }

    public func renderTelemetryOverlay(to url: URL, progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> RenderReport {
        let current = await store.manifest
        guard let timeline = current.timelines.last else { throw FCPXMLExportError.invalidTimeline("Нет созданного фильма") }
        return try await TelemetryAlphaRenderer().render(
            timeline: timeline,
            telemetry: Self.telemetryLookup(in: current),
            destination: url,
            progress: progress
        )
    }

    public func diagnostics() async -> String {
        let project = await store.manifest
        let missing = project.assets.filter { !FileManager.default.fileExists(atPath: $0.originalURL.path) }
        let analyzed = Set(project.analyses.map(\.assetID)).count
        let ovrleyStatus = (try? await OVRLEYBridge().health()) ?? "OVRLEY bridge недоступен"
        let sourceMapLines = (project.sourceMap?.activityGroups ?? []).flatMap { group -> [String] in
            let header = "Группа \(group.order + 1) · \(group.title) · confidence \(Int((group.confidence * 100).rounded()))%"
            let entries = (project.sourceMap?.entries ?? [])
                .filter { $0.activityGroupID == group.id }
                .map { entry in
                    let sequence = entry.sequence.map { " · sequence \($0.displayValue)" } ?? ""
                    return "  \(entry.order + 1). \(entry.displayName)\(sequence) · chronology \(Int((entry.chronologyConfidence * 100).rounded()))%"
                }
            return [header] + entries
        }.joined(separator: "\n")
        return """
        Диагностика VeloEdit
        Проект: \(project.name), версия \(project.projectVersion)
        Материалов: \(project.assets.count), проанализировано: \(analyzed), отсутствует: \(missing.count)
        Событий: \(project.events.count), режиссёрских планов: \(project.storyPlans.count), монтажей: \(project.timelines.count)
        Источников телеметрии: \(project.effectiveTelemetrySources.count)
        Карта исходников: \(project.sourceMap?.entries.count ?? 0) файлов, \(project.sourceMap?.activityGroups.count ?? 0) групп
        \(sourceMapLines)
        Движок: \(ovrleyStatus)
        Тепловое состояние: \(ProcessInfo.processInfo.thermalState.rawValue)
        Отсутствующие файлы:\n\(missing.map { "- \($0.originalURL.path)" }.joined(separator: "\n"))
        """
    }

    private static func retimed(_ items: [TimelineItem]) -> [TimelineItem] {
        TimelineTiming.retimed(items)
    }

    private static func telemetryLookup(in project: ProjectManifest) -> [UUID: TelemetrySummary] {
        var result = Dictionary(uniqueKeysWithValues: project.analyses.compactMap { analysis in
            analysis.telemetry.map { (analysis.assetID, $0) }
        })
        for source in project.effectiveTelemetrySources {
            result[source.id] = source.summary
            if let assetID = source.linkedAssetID { result[assetID] = source.summary }
        }
        return result
    }

    private static func mergingTelemetrySources(into analyses: [AnalysisResult], sources: [TelemetrySource]) -> [AnalysisResult] {
        var result = analyses
        for source in sources {
            guard let assetID = source.linkedAssetID, let index = result.firstIndex(where: { $0.assetID == assetID }) else { continue }
            result[index].telemetry = source.summary
        }
        return result
    }

    private static func nextAIEditName(in project: ProjectManifest) -> String {
        let number = (project.timelineCheckpoints?.count ?? 0) + 1
        return String(format: "AI Edit %02d", number)
    }

    private static func appendCheckpoint(timeline: Timeline, reason: String, to project: inout ProjectManifest) {
        var checkpoints = project.timelineCheckpoints ?? []
        let name = timeline.versionName ?? String(format: "AI Edit %02d", checkpoints.count + 1)
        if checkpoints.last?.timeline != timeline {
            checkpoints.append(TimelineCheckpoint(name: name, reason: reason, timeline: timeline))
        }
        if checkpoints.count > 20 {
            checkpoints.removeFirst(checkpoints.count - 20)
        }
        project.timelineCheckpoints = checkpoints
    }

    private static func clampedToAvailableMedia(_ source: Timeline, assets: [MediaAsset]) -> Timeline {
        let durations = Dictionary(uniqueKeysWithValues: assets.compactMap { asset in
            asset.metadata.duration.map { (asset.id, $0) }
        })
        var timeline = source
        let frame = 1 / max(1, timeline.frameRate)
        for index in timeline.items.indices {
            guard timeline.items[index].kind == .video,
                  let assetID = timeline.items[index].assetID,
                  let assetDuration = durations[assetID],
                  assetDuration.isFinite,
                  assetDuration > 0 else { continue }
            var item = timeline.items[index]
            let preservedTimelineDuration = item.timelineDuration
            item.sourceStart = min(max(0, item.sourceStart), max(0, assetDuration - frame))
            let available = max(frame, assetDuration - item.sourceStart)
            item.sourceDuration = min(max(frame, item.sourceDuration), available)
            if item.isFreezeFrame {
                item.timelineDuration = max(frame, preservedTimelineDuration)
            } else {
                let durationFactor = item.speedRamp?.outputDuration(sourceDuration: 1) ?? (1 / max(0.1, item.speed))
                item.timelineDuration = max(frame, item.sourceDuration * durationFactor)
            }
            timeline.items[index] = item
        }
        timeline.items = retimed(timeline.items)
        return timeline
    }

    static func storyConstraintLocks(
        explicitIn prompt: String,
        from base: StoryConstraints,
        to interpreted: StoryConstraints
    ) -> StoryConstraintLocks {
        var locks: StoryConstraintLocks = []
        if abs(interpreted.targetDuration - base.targetDuration) > 0.000_1 {
            locks.insert(.targetDuration)
        }
        if abs(interpreted.pacing - base.pacing) > 0.000_1 {
            locks.insert(.pacing)
        }
        if abs(interpreted.transitionFrequency - base.transitionFrequency) > 0.000_1 {
            locks.insert(.transitionFrequency)
        }
        if interpreted.allowSlowMotion != base.allowSlowMotion {
            locks.insert(.allowSlowMotion)
        }
        let text = prompt.lowercased().replacingOccurrences(of: "ё", with: "е")
        if AutonomousDurationOptimizer.requestContainsExplicitDuration(text) {
            locks.insert(.targetDuration)
        }
        if ["динамич", "энергич", "быстрый темп", "спокой", "медлен"].contains(where: text.contains) {
            locks.insert(.pacing)
        }
        if text.contains("меньше переход") || text.contains("больше переход") {
            locks.insert(.transitionFrequency)
        }
        if [
            "без slow motion", "не используй slow motion", "убери slow motion", "отключи slow motion",
            "не добавляй slow motion", "никакого slow motion", "не нужен slow motion",
            "без слоу", "без замедления", "не замедляй"
        ].contains(where: text.contains) {
            locks.insert(.allowSlowMotion)
        }
        return locks
    }

    static func interpretedFeedbackConstraints(
        _ feedback: String,
        preset: FilmPreset,
        base: StoryConstraints,
        ignoredConstraints: StoryConstraintLocks
    ) -> StoryConstraints {
        var constraints = PromptInterpreter().interpret(
            prompt: feedback,
            preset: preset,
            base: base
        )
        if ignoredConstraints.contains(.targetDuration) {
            // A phrase such as “selected clip for 3 seconds” is an exact
            // editor command, not a request to compress the whole film.
            constraints.targetDuration = base.targetDuration
        }
        if ignoredConstraints.contains(.pacing) {
            constraints.pacing = base.pacing
        }
        if ignoredConstraints.contains(.transitionFrequency) {
            constraints.transitionFrequency = base.transitionFrequency
        }
        if ignoredConstraints.contains(.allowSlowMotion) {
            constraints.allowSlowMotion = base.allowSlowMotion
        }
        return constraints
    }

    private static func applyingLocalizedEditorCommands(
        _ commands: [EditorCommand],
        to source: Timeline,
        timelineRange: ClosedRange<Double>,
        assets: [MediaAsset]
    ) -> (timeline: Timeline, report: EditorCommandReport) {
        var applied: [String] = []
        var ignored: [String] = []
        var affected = Set<UUID>()
        guard !commands.isEmpty else {
            return (source, EditorCommandReport(recognizedCount: 0, ignored: ["Не удалось составить исполняемый план правки"]))
        }
        var localized = TimelineRangeSlicer.slice(source, for: timelineRange)
        let slicedBaseline = localized.timeline
        var timeline = slicedBaseline

        func targetIDs(for command: EditorCommand, candidates: [UUID]) -> [UUID] {
            guard !candidates.isEmpty else { return [] }
            switch command.timelineRangeTarget ?? .all {
            case .all, .selected:
                return candidates
            case .first:
                return [candidates[0]]
            case .last:
                return [candidates[candidates.count - 1]]
            case .number(let number):
                return candidates.indices.contains(number - 1) ? [candidates[number - 1]] : []
            }
        }

        func appendReport(_ report: EditorCommandReport) {
            applied.append(contentsOf: report.applied)
            ignored.append(contentsOf: report.ignored)
            affected.formUnion(report.affectedItemIDs)
        }

        func appliesToAttachedTarget(_ targetID: UUID?, commandTargets: Set<UUID>) -> Bool {
            guard let targetID else { return true }
            return commandTargets.contains(targetID)
        }

        func finishCommand(from before: Timeline, align: Bool = true) {
            if align { timeline = alignLocalizedTimelineObjects(timeline, from: before) }
            // Subsequent clauses also target objects created by this clause.
            localized.itemIDs += timeline.items.filter { item in !before.items.contains { $0.id == item.id } }.map(\.id)
            localized.audioClipIDs += timeline.effectiveAudioClips.filter { item in !before.effectiveAudioClips.contains { $0.id == item.id } }.map(\.id)
            localized.telemetryItemIDs += timeline.effectiveTelemetryItems.filter { item in !before.effectiveTelemetryItems.contains { $0.id == item.id } }.map(\.id)
            localized.effectItemIDs += timeline.effectiveEffects.filter { item in !before.effectiveEffects.contains { $0.id == item.id } }.map(\.id)
            localized.titleItemIDs += timeline.effectiveTitleItems.filter { item in !before.effectiveTitleItems.contains { $0.id == item.id } }.map(\.id)
        }

        // Resolve targets afresh after each operation, including structural edits.
        for command in commands {
            let beforeCommand = timeline
            let localClipIDs = timeline.items.filter { localized.itemIDs.contains($0.id) && $0.kind != .title }.map(\.id)
            let localLegacyTitleIDs = timeline.items.filter { localized.itemIDs.contains($0.id) && $0.kind == .title }.map(\.id)
            let clipTargets = targetIDs(for: command, candidates: localClipIDs)
            let clipTargetSet = Set(clipTargets)
            let legacyTitleTargets = targetIDs(for: command, candidates: localLegacyTitleIDs)
            let localItems = timeline.items.filter { localClipIDs.contains($0.id) && $0.overlay == nil }
            let lower = localItems.map(\.timelineStart).min() ?? timelineRange.lowerBound
            let upper = localItems.map { $0.timelineStart + $0.timelineDuration }.max() ?? min(timeline.duration, timelineRange.upperBound)
            let currentRange = lower...max(lower, upper)

            switch command {
            case .insertBackground, .insertSource:
                ignored.append("Добавление материала доступно в помощнике монтажа вне выделенного диапазона")
                continue
            case .setMusic, .setMusicVolume, .setAudioDucking:
                if let updated = LocalizedSoundtrackEditing.apply(command, to: timeline, range: currentRange) {
                    timeline = updated
                    applied.append("музыка изменена только внутри выделенного диапазона")
                } else {
                    ignored.append("в выделенном диапазоне нет музыки для этой правки")
                }
                continue
            case .setOriginalAudioVolume(let requested):
                // Rebase the master gain into per-clip gains, preserving the audible
                // level outside the brush even when the master used to be muted.
                let volume = min(1, max(0, requested))
                let master = timeline.effectiveOriginalAudioVolume
                timeline.audioDucking = SourceAudioMixPolicy.musicDucking(in: timeline)
                timeline.originalAudioVolume = 1
                for index in timeline.items.indices where timeline.items[index].kind == .video {
                    var audio = timeline.items[index].effectiveAudioAdjustments
                    audio.volume *= master
                    if clipTargetSet.contains(timeline.items[index].id) {
                        audio.volume = volume
                        audio.muted = volume == 0
                        audio.duckOthers = false
                        affected.insert(timeline.items[index].id)
                    }
                    timeline.items[index].audioAdjustments = audio
                }
                timeline.audioClips = timeline.effectiveAudioClips.map { clip in
                    guard localized.audioClipIDs.contains(clip.id), clip.assetID != nil,
                          [.detached, .dialogue, .naturalSound].contains(clip.role) else { return clip }
                    var copy = clip
                    copy.adjustments.volume = volume
                    copy.adjustments.muted = volume == 0
                    copy.adjustments.duckOthers = false
                    affected.insert(copy.id)
                    return copy
                }
                if volume < 1, let updated = LocalizedSoundtrackEditing.apply(.setAudioDucking(false), to: timeline, range: currentRange) {
                    timeline = updated
                }
                applied.append("громкость исходного звука изменена только внутри выделения")
                continue
            case .addTitle(let text, let position):
                var local = timeline
                local.items = TimelineTiming.retimed(localItems)
                local.titleItems = timeline.effectiveTitleItems.filter { localized.titleItemIDs.contains($0.id) }.map { title in
                    var copy = title; copy.startTime -= lower; return copy
                }
                let existing = Set(local.effectiveTitleItems.map(\.id))
                let result = EditorCommandExecutor().apply([.addTitle(text, position)], to: local)
                let added = result.timeline.effectiveTitleItems.filter { !existing.contains($0.id) }.map { title in
                    var copy = title; copy.startTime += lower; copy.userEdited = true; return copy
                }
                timeline.titleItems = timeline.effectiveTitleItems + added
                appendReport(result.report)
                finishCommand(from: beforeCommand)
                continue
            case .split:
                for id in clipTargets {
                    guard let item = timeline.items.first(where: { $0.id == id }) else { continue }
                    let cut = TimelineTiming.quantized(item.timelineStart + item.timelineDuration / 2, frameRate: timeline.frameRate)
                    let frame = 1 / max(1, timeline.frameRate)
                    guard cut - item.timelineStart >= frame, item.timelineStart + item.timelineDuration - cut >= frame else {
                        ignored.append("фрагмент слишком короткий для разделения")
                        continue
                    }
                    // The slicer preserves reverse/ramp source clocks and cuts every
                    // attached layer at the same boundary, retaining valid owners.
                    timeline = TimelineRangeSlicer.slice(timeline, for: cut...(item.timelineStart + item.timelineDuration)).timeline
                    affected.insert(id)
                    applied.append("фрагмент разделён вместе с привязанными слоями")
                }
                finishCommand(from: beforeCommand, align: false)
                continue
            case .move(_, let position):
                let moving = timeline.items.filter { clipTargetSet.contains($0.id) }
                timeline.items.removeAll { clipTargetSet.contains($0.id) }
                let remaining = timeline.items.indices.filter { localClipIDs.contains(timeline.items[$0].id) }
                let insertion = position == .beginning ? remaining.first : remaining.last.map { $0 + 1 }
                if let insertion {
                    timeline.items.insert(contentsOf: moving, at: insertion)
                } else {
                    timeline = beforeCommand
                }
                timeline.items = retimed(timeline.items)
                if timeline != beforeCommand {
                    affected.formUnion(moving.map(\.id))
                    applied.append("фрагменты перемещены внутри выделения")
                } else { ignored.append("фрагменты уже находятся в указанной позиции выделения") }
                finishCommand(from: beforeCommand)
                continue
            case .setOverlay(let style, _, let backgroundTarget):
                guard let foregroundID = clipTargets.last,
                      let index = timeline.items.firstIndex(where: { $0.id == foregroundID }) else {
                    ignored.append("в выделении нет клипа для наложения"); continue
                }
                if let style {
                    let backgrounds = targetIDs(for: .setOpacity(1, backgroundTarget ?? .first), candidates: localClipIDs)
                    guard let backgroundID = backgrounds.first(where: { $0 != foregroundID }),
                          timeline.items.contains(where: { $0.id == backgroundID && $0.overlay == nil }) else {
                        ignored.append("для наложения выделите основной клип и накладываемый фрагмент"); continue
                    }
                    timeline.items[index].overlay = OverlaySettings(style: style, baseItemID: backgroundID)
                } else { timeline.items[index].overlay = nil }
                timeline.items = retimed(timeline.items)
                affected.insert(foregroundID)
                applied.append("наложение изменено внутри выделения")
                finishCommand(from: beforeCommand)
                continue
            default: break
            }

            if case .removeTitles = command {
                let beforeLegacy = timeline.items.count
                timeline.items.removeAll { localLegacyTitleIDs.contains($0.id) }
                let removedModern = timeline.effectiveTitleItems.filter { localized.titleItemIDs.contains($0.id) }
                timeline.titleItems = timeline.effectiveTitleItems.filter { !localized.titleItemIDs.contains($0.id) }
                affected.formUnion(localLegacyTitleIDs)
                affected.formUnion(removedModern.map(\.id))
                if timeline.items.count != beforeLegacy || !removedModern.isEmpty {
                    applied.append("титры удалены только внутри выделенного диапазона")
                } else {
                    ignored.append("в выделенном диапазоне нет титров")
                }
                timeline.items = retimed(timeline.items)
                finishCommand(from: beforeCommand)
                continue
            }

            let executorTargets = command.targetsLegacyTitles ? legacyTitleTargets : clipTargets
            if let localizedCommand = command.retargetedForTimelineRange() {
                for (offset, itemID) in executorTargets.enumerated() {
                    let commandForItem: EditorCommand
                    switch localizedCommand {
                    case .setTransitionPattern(let styles, let target) where !styles.isEmpty:
                        commandForItem = .setTransition(styles[offset % styles.count], target)
                    case .setEffectPattern(let effects, let target) where !effects.isEmpty:
                        commandForItem = .setEffect(effects[offset % effects.count], target)
                    default:
                        commandForItem = localizedCommand
                    }
                    let result = EditorCommandExecutor().apply(
                        [commandForItem],
                        to: timeline,
                        selectedItemID: itemID
                    )
                    timeline = result.timeline
                    appendReport(result.report)
                }
            }

            // Standalone objects share the same brushed interval. Apply only
            // to sliced IDs (and, when attached, only to resolved local clips).
            switch command {
            case .setClipVolume(let volume, _):
                timeline.audioClips = timeline.effectiveAudioClips.map { clip in
                    guard localized.audioClipIDs.contains(clip.id),
                          appliesToAttachedTarget(clip.attachedToItemID, commandTargets: clipTargetSet) else { return clip }
                    var copy = clip
                    copy.adjustments.volume = min(max(0, volume), 2)
                    if copy != clip { affected.insert(copy.id) }
                    return copy
                }
            case .setClipMuted(let muted, _):
                timeline.audioClips = timeline.effectiveAudioClips.map { clip in
                    guard localized.audioClipIDs.contains(clip.id),
                          appliesToAttachedTarget(clip.attachedToItemID, commandTargets: clipTargetSet) else { return clip }
                    var copy = clip
                    copy.adjustments.muted = muted
                    if copy != clip { affected.insert(copy.id) }
                    return copy
                }
            case .setClipFades(let fadeIn, let fadeOut, _):
                timeline.audioClips = timeline.effectiveAudioClips.map { clip in
                    guard localized.audioClipIDs.contains(clip.id),
                          appliesToAttachedTarget(clip.attachedToItemID, commandTargets: clipTargetSet) else { return clip }
                    var copy = clip
                    copy.adjustments.fadeIn = min(max(0, fadeIn), copy.timelineDuration)
                    copy.adjustments.fadeOut = min(max(0, fadeOut), copy.timelineDuration)
                    if copy != clip { affected.insert(copy.id) }
                    return copy
                }
            case .setNoiseReduction(let amount, _):
                timeline.audioClips = timeline.effectiveAudioClips.map { clip in
                    guard localized.audioClipIDs.contains(clip.id),
                          appliesToAttachedTarget(clip.attachedToItemID, commandTargets: clipTargetSet) else { return clip }
                    var copy = clip
                    copy.adjustments.noiseReduction = min(max(0, amount), 1)
                    if copy != clip { affected.insert(copy.id) }
                    return copy
                }
            case .setEQ(let preset, _):
                timeline.audioClips = timeline.effectiveAudioClips.map { clip in
                    guard localized.audioClipIDs.contains(clip.id),
                          appliesToAttachedTarget(clip.attachedToItemID, commandTargets: clipTargetSet) else { return clip }
                    var copy = clip
                    copy.adjustments.eqPreset = preset
                    if copy != clip { affected.insert(copy.id) }
                    return copy
                }
            case .setTitleText(let text, _):
                let targets = Set(targetIDs(for: command, candidates: localized.titleItemIDs.filter { id in timeline.effectiveTitleItems.contains { $0.id == id } }))
                var renamed = 0
                timeline.titleItems = timeline.effectiveTitleItems.map { title in
                    guard targets.contains(title.id) else { return title }
                    var copy = title
                    copy.text = text
                    copy.userEdited = true
                    if copy != title { affected.insert(copy.id); renamed += 1 }
                    return copy
                }
                if renamed > 0 { applied.append("текст титра изменён на «\(text)» только внутри выделения") }
                if targets.isEmpty && legacyTitleTargets.isEmpty {
                    ignored.append("в выделенном диапазоне нет титра для переименования")
                }
            case .setTitleStyle(let size, let textColor, let backgroundColor, let alignment, _):
                let targets = Set(targetIDs(for: command, candidates: localized.titleItemIDs.filter { id in timeline.effectiveTitleItems.contains { $0.id == id } }))
                timeline.titleItems = timeline.effectiveTitleItems.map { title in
                    guard targets.contains(title.id) else { return title }
                    var copy = title
                    if let size { copy.style.fontSize = min(max(18, size), 220) }
                    if let textColor { copy.style.textColorHex = textColor }
                    if let backgroundColor { copy.style.backgroundColorHex = backgroundColor }
                    if let alignment { copy.style.alignment = alignment }
                    copy.userEdited = true
                    if copy != title { affected.insert(copy.id) }
                    return copy
                }
            case .setOpacity(let opacity, _):
                timeline.titleItems = timeline.effectiveTitleItems.map { title in
                    guard localized.titleItemIDs.contains(title.id),
                          appliesToAttachedTarget(title.targetClipID, commandTargets: clipTargetSet) else { return title }
                    var copy = title
                    copy.style.opacity = min(max(0, opacity), 1)
                    if copy != title { affected.insert(copy.id) }
                    return copy
                }
                timeline.telemetryItems = timeline.effectiveTelemetryItems.map { item in
                    guard localized.telemetryItemIDs.contains(item.id),
                          appliesToAttachedTarget(item.targetClipID, commandTargets: clipTargetSet) else { return item }
                    var copy = item
                    copy.settings.opacity = min(max(0, opacity), 1)
                    if copy != item { affected.insert(copy.id) }
                    return copy
                }
                timeline.effects = timeline.effectiveEffects.map { item in
                    guard localized.effectItemIDs.contains(item.id),
                          appliesToAttachedTarget(item.targetClipID, commandTargets: clipTargetSet) else { return item }
                    var copy = item
                    copy.intensity = min(max(0, opacity), 1)
                    if copy != item { affected.insert(copy.id) }
                    return copy
                }
            case .setDuration(let duration, _):
                timeline.audioClips = timeline.effectiveAudioClips.map { item in
                    guard localized.audioClipIDs.contains(item.id),
                          appliesToAttachedTarget(item.attachedToItemID, commandTargets: clipTargetSet) else { return item }
                    var copy = item
                    copy.timelineDuration = min(copy.sourceDuration, max(0.05, duration))
                    if copy != item { affected.insert(copy.id) }
                    return copy
                }
                timeline.telemetryItems = timeline.effectiveTelemetryItems.map { item in
                    guard localized.telemetryItemIDs.contains(item.id),
                          appliesToAttachedTarget(item.targetClipID, commandTargets: clipTargetSet) else { return item }
                    var copy = item
                    copy.timelineDuration = max(0.05, duration)
                    if copy != item { affected.insert(copy.id) }
                    return copy
                }
                timeline.effects = timeline.effectiveEffects.map { item in
                    guard localized.effectItemIDs.contains(item.id),
                          appliesToAttachedTarget(item.targetClipID, commandTargets: clipTargetSet) else { return item }
                    var copy = item
                    copy.duration = max(0.05, duration)
                    if copy != item { affected.insert(copy.id) }
                    return copy
                }
                timeline.titleItems = timeline.effectiveTitleItems.map { item in
                    guard localized.titleItemIDs.contains(item.id),
                          appliesToAttachedTarget(item.targetClipID, commandTargets: clipTargetSet) else { return item }
                    var copy = item
                    copy.duration = max(0.05, duration)
                    if copy != item { affected.insert(copy.id) }
                    return copy
                }
            case .delete:
                let audio = timeline.effectiveAudioClips.filter {
                    localized.audioClipIDs.contains($0.id) && appliesToAttachedTarget($0.attachedToItemID, commandTargets: clipTargetSet)
                }
                let telemetry = timeline.effectiveTelemetryItems.filter {
                    localized.telemetryItemIDs.contains($0.id) && appliesToAttachedTarget($0.targetClipID, commandTargets: clipTargetSet)
                }
                let effects = timeline.effectiveEffects.filter {
                    localized.effectItemIDs.contains($0.id) && appliesToAttachedTarget($0.targetClipID, commandTargets: clipTargetSet)
                }
                let titles = timeline.effectiveTitleItems.filter {
                    localized.titleItemIDs.contains($0.id) && appliesToAttachedTarget($0.targetClipID, commandTargets: clipTargetSet)
                }
                let audioIDs = Set(audio.map(\.id)), telemetryIDs = Set(telemetry.map(\.id))
                let effectIDs = Set(effects.map(\.id)), titleIDs = Set(titles.map(\.id))
                timeline.audioClips = timeline.effectiveAudioClips.filter { !audioIDs.contains($0.id) }
                timeline.telemetryItems = timeline.effectiveTelemetryItems.filter { !telemetryIDs.contains($0.id) }
                timeline.effects = timeline.effectiveEffects.filter { !effectIDs.contains($0.id) }
                timeline.titleItems = timeline.effectiveTitleItems.filter { !titleIDs.contains($0.id) }
                affected.formUnion(audioIDs); affected.formUnion(telemetryIDs)
                affected.formUnion(effectIDs); affected.formUnion(titleIDs)
            case .setTransition(let style, _):
                let matching = timeline.effectiveTransitionItems.filter { clipTargetSet.contains($0.incomingClipID) }
                if let style {
                    timeline.transitionItems = timeline.effectiveTransitionItems.map { transition in
                        guard clipTargetSet.contains(transition.incomingClipID) else { return transition }
                        var copy = transition
                        copy.style = style
                        copy.intensity = TransitionPresetRegistry.preset(for: style).defaultIntensity
                        copy.parameters = TransitionPresetRegistry.preset(for: style).defaultParameters
                        if copy != transition { affected.insert(copy.id) }
                        return copy
                    }
                } else {
                    let ids = Set(matching.map(\.id))
                    timeline.transitionItems = timeline.effectiveTransitionItems.filter { !ids.contains($0.id) }
                    affected.formUnion(ids)
                }
            case .setEffect(let effect, _):
                if effect == nil {
                    let ids = Set(timeline.effectiveEffects.filter {
                        localized.effectItemIDs.contains($0.id) && appliesToAttachedTarget($0.targetClipID, commandTargets: clipTargetSet)
                    }.map(\.id))
                    timeline.effects = timeline.effectiveEffects.filter { !ids.contains($0.id) }
                    affected.formUnion(ids)
                }
            default:
                break
            }
            timeline = clampedToAvailableMedia(timeline, assets: assets)
            finishCommand(from: beforeCommand)
        }

        timeline = clampedToAvailableMedia(timeline, assets: assets)
        guard timeline != slicedBaseline else {
            if applied.isEmpty, ignored.isEmpty { ignored.append("Правка уже соответствует выделенному диапазону") }
            return (source, EditorCommandReport(
                recognizedCount: commands.count,
                applied: [],
                ignored: deduplicated(ignored),
                affectedItemIDs: []
            ))
        }

        if !affected.isEmpty, applied.isEmpty {
            applied.append("изменены объекты внутри выделенного диапазона")
        }
        return (timeline, EditorCommandReport(
            recognizedCount: commands.count,
            applied: deduplicated(applied),
            ignored: deduplicated(ignored),
            affectedItemIDs: Array(affected)
        ))
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Retiming a brushed clip must ripple every independent layer by the same
    /// timeline mapping. Attached objects also disappear when their target was
    /// deleted, so no dangling UUID can silently disable rendering later.
    private static func alignLocalizedTimelineObjects(_ source: Timeline, from previous: Timeline) -> Timeline {
        var timeline = source
        let oldPrimaries = previous.items.filter { $0.overlay == nil && $0.kind != .title }
            .sorted { $0.timelineStart < $1.timelineStart }
        let currentByID = Dictionary(uniqueKeysWithValues: timeline.items.map { ($0.id, $0) })
        let oldByID = Dictionary(uniqueKeysWithValues: oldPrimaries.map { ($0.id, $0) })

        func mappedTime(_ oldTime: Double) -> Double {
            if let old = oldPrimaries.first(where: {
                oldTime >= $0.timelineStart && oldTime < $0.timelineStart + $0.timelineDuration
                    && currentByID[$0.id] != nil
            }), let current = currentByID[old.id] {
                let fraction = min(max(0, (oldTime - old.timelineStart) / max(0.000_001, old.timelineDuration)), 1)
                return current.timelineStart + fraction * current.timelineDuration
            }
            if let old = oldPrimaries.last(where: {
                $0.timelineStart + $0.timelineDuration <= oldTime && currentByID[$0.id] != nil
            }),
               let current = currentByID[old.id] {
                return current.timelineStart + current.timelineDuration
                    + (oldTime - old.timelineStart - old.timelineDuration)
            }
            if let old = oldPrimaries.first(where: { currentByID[$0.id] != nil }),
               let current = currentByID[old.id] {
                return max(0, current.timelineStart - (old.timelineStart - oldTime))
            }
            return max(0, oldTime)
        }

        func mappedInterval(start: Double, end: Double, targetID: UUID?) -> (Double, Double) {
            if let targetID, let oldTarget = oldByID[targetID], let currentTarget = currentByID[targetID] {
                let startFraction = (start - oldTarget.timelineStart) / max(0.000_001, oldTarget.timelineDuration)
                let endFraction = (end - oldTarget.timelineStart) / max(0.000_001, oldTarget.timelineDuration)
                let mappedStart = currentTarget.timelineStart + startFraction * currentTarget.timelineDuration
                let mappedEnd = currentTarget.timelineStart + endFraction * currentTarget.timelineDuration
                return (max(0, mappedStart), max(mappedStart + 0.05, mappedEnd))
            }
            let mappedStart = mappedTime(start)
            return (mappedStart, max(mappedStart + 0.05, mappedTime(end)))
        }

        let oldAudio = Dictionary(uniqueKeysWithValues: previous.effectiveAudioClips.map { ($0.id, $0) })
        timeline.audioClips = timeline.effectiveAudioClips.compactMap { item in
            if let targetID = item.attachedToItemID, currentByID[targetID] == nil { return nil }
            guard let old = oldAudio[item.id] else { return item }
            var copy = item
            let (start, end) = mappedInterval(
                start: old.timelineStart,
                end: old.timelineEnd,
                targetID: old.attachedToItemID
            )
            copy.timelineStart = start
            copy.timelineDuration = max(0.05, end - start)
            copy.speed = copy.sourceDuration / copy.timelineDuration
            return copy
        }

        let oldTelemetry = Dictionary(uniqueKeysWithValues: previous.effectiveTelemetryItems.map { ($0.id, $0) })
        timeline.telemetryItems = timeline.effectiveTelemetryItems.compactMap { item in
            if let targetID = item.targetClipID, currentByID[targetID] == nil { return nil }
            guard let old = oldTelemetry[item.id] else { return item }
            var copy = item
            let (start, end) = mappedInterval(
                start: old.timelineStart,
                end: old.timelineEnd,
                targetID: old.targetClipID
            )
            copy.timelineStart = start
            copy.timelineDuration = max(0.05, end - start)
            if let targetID = copy.targetClipID, let target = currentByID[targetID] {
                copy.linkedAssetID = target.assetID
                copy.sourceStart = target.sourceTime(atTimelineTime: start)
            }
            return copy
        }

        let oldEffects = Dictionary(uniqueKeysWithValues: previous.effectiveEffects.map { ($0.id, $0) })
        timeline.effects = timeline.effectiveEffects.compactMap { item in
            if let targetID = item.targetClipID, currentByID[targetID] == nil { return nil }
            guard let old = oldEffects[item.id] else { return item }
            var copy = item
            let (start, end) = mappedInterval(
                start: old.startTime,
                end: old.endTime,
                targetID: old.targetClipID
            )
            let ratio = max(0.000_001, end - start) / max(0.000_001, old.duration)
            copy.startTime = start
            copy.duration = max(0.05, end - start)
            copy.keyframes = copy.keyframes.map { keyframe in
                var value = keyframe
                value.time = min(copy.duration, max(0, keyframe.time * ratio))
                return value
            }
            return copy
        }

        let oldTitles = Dictionary(uniqueKeysWithValues: previous.effectiveTitleItems.map { ($0.id, $0) })
        timeline.titleItems = timeline.effectiveTitleItems.compactMap { item in
            if let targetID = item.targetClipID, currentByID[targetID] == nil { return nil }
            guard let old = oldTitles[item.id] else { return item }
            var copy = item
            let (start, end) = mappedInterval(
                start: old.startTime,
                end: old.endTime,
                targetID: old.targetClipID
            )
            let ratio = max(0.000_001, end - start) / max(0.000_001, old.duration)
            copy.startTime = start
            copy.duration = max(0.05, end - start)
            copy.words = copy.words.map { word in
                var value = word
                value.start = min(copy.duration, max(0, word.start * ratio))
                value.end = min(copy.duration, max(value.start, word.end * ratio))
                return value
            }
            return copy
        }

        let validIDs = Set(timeline.items.map(\.id))
        timeline.transitionItems = timeline.effectiveTransitionItems.compactMap { transition in
            guard validIDs.contains(transition.outgoingClipID),
                  validIDs.contains(transition.incomingClipID),
                  let incoming = currentByID[transition.incomingClipID] else { return nil }
            var copy = transition
            copy.startTime = incoming.timelineStart
            copy.duration = min(copy.duration, max(0.08, incoming.timelineDuration * 0.5))
            return copy
        }
        if var plan = timeline.adaptiveSoundtrack, plan.userEdited == true {
            var cursor = 0.0
            plan.segments = plan.segments.compactMap { region in
                var copy = region
                let end = min(timeline.duration, max(cursor, mappedTime(region.timelineEnd)))
                guard end - cursor >= 0.0001 else { return nil }
                copy.timelineStart = cursor
                copy.timelineDuration = end - cursor
                cursor = end
                return copy
            }
            if let last = plan.segments.indices.last {
                plan.segments[last].timelineDuration += max(0, timeline.duration - cursor)
            }
            plan.timelineDuration = timeline.duration
            timeline.adaptiveSoundtrack = plan
        }
        return timeline
    }

    private func tracksForResolving(
        _ directive: MusicDirective?,
        excludingIdentities: Set<String> = []
    ) async throws -> [LocalMusicTrack] {
        lastMusicResolutionError = nil
        let tracks = try await musicSystem.tracks()
        guard let directive else { return tracks }
        let current = await store.manifest
        let previousTrackID = directive.preferDifferentTrack == true
            ? current.timelines.last?.music?.trackID
            : nil
        var effectiveExcludedIdentities = excludingIdentities
        if directive.preferDifferentTrack == true {
            effectiveExcludedIdentities.formUnion(await musicSelectionHistory.recentIdentities())
        }
        if let previousTrackID,
           let previousTrack = tracks.first(where: { $0.id == previousTrackID }) {
            effectiveExcludedIdentities.insert(previousTrack.selectionIdentity)
        }
        let resolution = await musicSystem.resolve(
            MusicIntent(directive: directive),
            requestedTrackID: directive.trackID,
            excluding: previousTrackID,
            excludingIdentities: effectiveExcludedIdentities,
            preferCachedOnline: directive.preferDifferentTrack == true,
            preferFreshOnline: directive.preferDifferentTrack == true
        )
        if !resolution.failures.isEmpty {
            lastMusicResolutionError = resolution.failures
                .map { "\($0.provider): \($0.reason)" }
                .joined(separator: "; ")
        }
        if let track = resolution.track {
            if directive.preferDifferentTrack == true { return [track] }
            return [track] + resolution.catalog.filter { $0.id != track.id }
        }
        if let exact = directive.searchRequests?.first, exact.exactTrack {
            throw DirectorBriefFulfillmentError.requestedMusicUnavailable(exact.query)
        }
        return resolution.catalog.filter { AutomaticSoundtrackSuitability.accepts($0, directive: directive) }
    }

    private func acquireSectionMusic(timelines: [Timeline], stories: [StoryPlanVariant], analyses: [AnalysisResult], excludingIdentities: Set<String> = []) async throws {
        var seen: Set<String> = []
        for (timeline, story) in zip(timelines, stories) {
            for intent in AdaptiveSoundtrackPlanner().requests(for: timeline, plan: story.plan, analyses: analyses) {
                try Task.checkCancellation()
                let key = intent.searchQuery + "|" + (intent.sceneType ?? "") + "|" + String(Int((intent.energy * 5).rounded()))
                guard seen.count < SoundtrackEditorialPolicy.maximumCandidates,
                      seen.insert(key).inserted else { continue }
                let resolution = await musicSystem.resolve(intent, excludingIdentities: excludingIdentities)
                if !resolution.failures.isEmpty {
                    lastMusicResolutionError = resolution.failures.map { "\($0.provider): \($0.reason)" }.joined(separator: "; ")
                }
            }
        }
    }

    private static func musicIntent(from autonomous: AutonomousMusicIntent) -> MusicIntent {
        MusicIntent(directive: MusicDirective(
            style: autonomous.style,
            bpm: autonomous.desiredBPM,
            preferDifferentTrack: true,
            autonomousIntent: autonomous
        ))
    }

    /// Converts the questionnaire mood from a suggestion into an editorial
    /// constraint. Content analysis still supplies the story, while pace,
    /// energy and music intent remain inside the range the user selected.
    private static func applyingDirectorBrief(
        _ brief: DirectorBrief,
        to source: AutonomousDirectorDecision
    ) -> AutonomousDirectorDecision {
        var result = source
        var style = result.finalStyle
        switch brief.mood {
        case .calm:
            style.energy = min(style.energy, 0.42)
            style.action = min(style.action, 0.40)
            style.atmosphere = max(style.atmosphere, 0.68)
            style.pacing = brief.mood.pacing
            style.shotDuration = max(style.shotDuration, 0.70)
            style.transitionIntensity = min(style.transitionIntensity, 0.14)
            style.musicIntensity = min(style.musicIntensity, 0.38)
        case .cinematic:
            style.cinematic = max(style.cinematic, 0.82)
            style.atmosphere = max(style.atmosphere, 0.66)
            style.pacing = brief.mood.pacing
            style.shotDuration = max(style.shotDuration, 0.58)
            style.transitionIntensity = min(style.transitionIntensity, 0.22)
        case .dynamic:
            style.energy = max(style.energy, 0.82)
            style.action = max(style.action, 0.72)
            style.pacing = brief.mood.pacing
            style.visualDensity = max(style.visualDensity, 0.74)
            style.shotDuration = min(style.shotDuration, 0.32)
            style.musicIntensity = max(style.musicIntensity, 0.76)
        }
        result.finalStyle = style
        result.grammar = AutonomousEditingGrammar(
            style: style,
            project: result.projectStyle,
            confidence: min(result.projectConfidence, max(0.35, result.grammar.confidence)),
            personalAdjustments: result.personalSignalAdjustments ?? [:]
        )
        switch brief.titlePolicy {
        case .none:
            result.grammar.titleDensity = 0
        case .keyOnly:
            // Confirmed story parts determine chapter title frequency.
            break
        case .minimal:
            result.grammar.titleDensity = min(result.grammar.titleDensity, 0.055)
        }
        result.music = AutonomousDirectorEngine.musicIntent(
            style: style,
            story: result.story,
            duration: result.duration,
            confidence: min(result.projectConfidence, result.story.confidence)
        )
        result.music.desiredDuration = brief.requestedDuration
        if brief.musicPolicy == .soft {
            result.music.style = .calm
            result.music.desiredEnergy = min(result.music.desiredEnergy, 0.28)
            result.music.desiredBPM = min(result.music.desiredBPM, 92)
            result.music.needsBuildAndDrop = false
            result.music.beatSyncIntensity = min(result.music.beatSyncIntensity, 0.24)
            result.music.reasons.append("Стартовый бриф: мягкая и ненавязчивая музыка")
        }
        result.explanations.append("Стартовый бриф зафиксирован как обязательный production contract")
        return result
    }

    private static func validateDirectorMusic(
        _ timeline: Timeline,
        brief: DirectorBrief?,
        tracks: [LocalMusicTrack]
    ) throws {
        guard let brief else { return }
        switch brief.musicPolicy {
        case .none:
            return
        case .specificTrack:
            guard let requestedID = brief.musicTrackID else {
                throw DirectorBriefFulfillmentError.specificMusicTrackNotSelected
            }
            guard timeline.music?.trackID == requestedID,
                  tracks.contains(where: {
                      $0.id == requestedID && FileManager.default.fileExists(atPath: $0.localFileURL.path)
                  }) else {
                throw DirectorBriefFulfillmentError.unavailableMusicTrack(requestedID)
            }
        case .matchVideo, .soft:
            guard let resolvedID = timeline.music?.trackID,
                  tracks.contains(where: {
                      $0.id == resolvedID && FileManager.default.fileExists(atPath: $0.localFileURL.path)
                  }) else {
                throw DirectorBriefFulfillmentError.automaticMusicUnavailable
            }
        }
    }

    private static func musicDirective(
        _ directive: MusicDirective?,
        replacing previousTrackID: UUID?
    ) -> MusicDirective? {
        guard var directive else { return nil }
        if previousTrackID != nil, directive.trackID == nil {
            // A new music instruction for an existing montage is a replacement,
            // even when the user names only the desired mood. Keeping the old
            // track would make requests such as “поставь спокойную музыку” a no-op.
            directive.preferDifferentTrack = true
        }
        return directive
    }

    private static func resolvingMusic(
        in timeline: Timeline,
        tracks: [LocalMusicTrack],
        structures: [UUID: MusicStructure] = [:],
        excluding: UUID? = nil,
        preserveDuration: Bool = false
    ) async -> Timeline {
        var result = timeline
        // Any prior adaptive map was calculated for another global music
        // resolution or another edit clock. The automatic directing pass will
        // rebuild it after the current track and final timing are known.
        result.adaptiveSoundtrack = nil
        guard var directive = result.music else { return result }
        let track: LocalMusicTrack?
        if let exact = directive.searchRequests?.first, exact.exactTrack {
            track = tracks.first { $0.isPlayable && exact.matches(title: $0.title, artist: $0.author) }
        } else if directive.preferDifferentTrack == true,
           directive.trackID == nil,
           let providerResolved = tracks.first(where: { $0.isPlayable && $0.id != excluding }) {
            // tracksForResolving places the provider's chosen fresh result at
            // the front. Preserve that decision while still exposing the rest
            // of the catalog to the adaptive soundtrack planner.
            track = providerResolved
        } else if let intent = directive.autonomousIntent {
            let available = tracks.filter {
                $0.id != excluding && AutomaticSoundtrackSuitability.accepts($0, directive: directive) && FileManager.default.fileExists(atPath: $0.localFileURL.path)
            }
            if let requestedID = directive.trackID, let requested = available.first(where: { $0.id == requestedID }) {
                track = requested
            } else {
                let scorer = AutonomousMusicTrackScorer()
                track = available.max {
                    scorer.score(track: $0, structure: structures[$0.id], intent: intent)
                        < scorer.score(track: $1, structure: structures[$1.id], intent: intent)
                }
            }
        } else {
            track = LocalMusicSelector().select(for: directive, from: tracks, excluding: excluding)
        }
        guard let track else { return result }
        directive.trackID = track.id
        directive.trackTitle = track.title
        directive.bpm = track.bpm
        directive.preferDifferentTrack = nil
        result.music = directive
        let structure: MusicStructure
        if let cached = structures[track.id] {
            structure = cached
        } else {
            structure = await MusicStructureCache.shared.structure(for: track)
        }
        result = SoundtrackEditorialPolicy.applying(track: track, structure: structure, to: result)
        if preserveDuration {
            // The chosen track and its measured structure are still attached,
            // but beat snapping may only shorten clips. A hard user duration
            // therefore keeps visual timing and uses the music under that cut.
            return MusicBeatSynchronizer().refreshingStructure(in: result, for: track, analyzedStructure: structure)
        }
        return MusicBeatSynchronizer().synchronize(result, to: track, analyzedStructure: structure, structuralOnly: true)
    }

    private static func attachingExplicitMusic(_ track: LocalMusicTrack, to timeline: Timeline) async -> Timeline {
        var result = timeline
        result.adaptiveSoundtrack = nil
        result.music = MusicDirective(
            style: track.suggestedStyle,
            bpm: track.bpm,
            volume: timeline.music?.volume ?? 0.22,
            trackID: track.id,
            trackTitle: track.title,
            structure: await MusicStructureCache.shared.structure(for: track)
        )
        return result
    }

    private static func directingVariants(
        stories: [StoryPlanVariant],
        roughTimelines: [Timeline],
        tracks: [LocalMusicTrack],
        assets: [MediaAsset],
        analyses: [AnalysisResult],
        allowsAdaptiveSoundtrack: Bool,
        telemetry: [UUID: TelemetrySummary],
        reviewCacheURL: URL,
        prober: any EditorialRenderedProbing,
        progress: FilmBuildProgressHandler? = nil
    ) async -> [Timeline] {
        // AVAssetReader can deadlock its media-service pipeline when several
        // unrelated audio files are decoded concurrently in one process. The
        // catalogue is small and every result is cached, so warm it
        // sequentially before the CPU-only variant work fans out below.
        var structures: [UUID: MusicStructure] = [:]
        var resourcePacer = ResourceWorkPacer()
        let analysisTracks = musicAnalysisShortlist(tracks: tracks, timelines: roughTimelines)
        for (index, track) in analysisTracks.enumerated() {
            do { try await resourcePacer.checkpoint() }
            catch { return [] }
            await progress?(FilmBuildProgress(.analyzingMusic, completed: index, total: analysisTracks.count))
            structures[track.id] = await MusicStructureCache.shared.structure(for: track)
        }
        await progress?(FilmBuildProgress(.assembling, completed: 0, total: roughTimelines.count))
        var ordered = Array<Timeline?>(repeating: nil, count: stories.count)
        var completed = 0
        var nextIndex = 0
        let variantCount = min(stories.count, roughTimelines.count)
        while nextIndex < variantCount {
            do { try await resourcePacer.checkpoint() }
            catch { return [] }
            let resources = await SystemResourceMonitor.shared.snapshot()
            let batchSize = resources.workLimit == .unrestricted ? 2 : 1
            let batchEnd = min(variantCount, nextIndex + batchSize)
            await withTaskGroup(of: (Int, Timeline).self) { group in
                for index in nextIndex..<batchEnd {
                    let story = stories[index]
                    let rough = roughTimelines[index]
                    group.addTask {
                        let preservesExactDuration = story.plan.requiresExactDuration
                        var timeline = await Self.resolvingMusic(
                            in: rough,
                            tracks: tracks,
                            structures: structures,
                            preserveDuration: preservesExactDuration
                        )
                        timeline = AIDirectorEngine().direct(plan: story.plan, initialTimeline: timeline, assets: assets, analyses: analyses)
                        timeline = await Self.resolvingMusic(
                            in: timeline,
                            tracks: tracks,
                            structures: structures,
                            preserveDuration: preservesExactDuration
                        )
                        if allowsAdaptiveSoundtrack {
                            timeline = AdaptiveSoundtrackPlanner().applying(
                                to: timeline,
                                plan: story.plan,
                                tracks: tracks,
                                analyses: analyses,
                                structures: structures
                            )
                        }
                        return (index, timeline)
                    }
                }
                for await (index, timeline) in group {
                    ordered[index] = timeline
                    completed += 1
                    await progress?(FilmBuildProgress(.assembling, completed: completed, total: roughTimelines.count))
                }
            }
            nextIndex = batchEnd
        }
        let directed = ordered.compactMap { $0 }
        var reviewed: [Timeline] = []
        for (index, pair) in zip(stories, directed).enumerated() {
            let (story, timeline) = pair
            if Task.isCancelled { break }
            await progress?(FilmBuildProgress(.reviewing, completed: index, total: directed.count))
            if story.plan.narrativeBeatPlan != nil {
                reviewed.append(await editorialRenderReview(timeline: timeline, plan: story.plan, assets: assets, analyses: analyses, tracks: tracks, telemetry: telemetry, cacheURL: reviewCacheURL, prober: prober))
            } else { reviewed.append(timeline) }
        }
        await progress?(FilmBuildProgress(.reviewing, completed: reviewed.count, total: directed.count))
        return reviewed
    }

    private static func preliminaryEditorialProber(
        for prober: any EditorialRenderedProbing
    ) -> any EditorialRenderedProbing {
        // Rank variants from real composition frames, then spend the expensive
        // control-export/parity/loudness pass only on the automatic winner.
        // Injected test/host probers keep their own deterministic behaviour.
        if prober is LocalEditorialRenderedProber {
            // Preliminary ranking only needs broad whole-film coverage. The
            // winner still receives the complete schedule and control export.
            // Keeping this pass small prevents ten Vision variants from
            // retaining several gigabytes of decoder state on 5K sources.
            return LocalEditorialRenderedProber(verifyExport: false, maximumSamples: 20)
        }
        return prober
    }

    static func applyingAdaptiveSoundtrack(
        to timeline: Timeline,
        plan: StoryPlan,
        tracks: [LocalMusicTrack],
        analyses: [AnalysisResult]
    ) async -> Timeline {
        var result = timeline
        guard plan.directorBrief?.musicPolicy != DirectorMusicPolicy.none,
              let directive = result.music else { result.adaptiveSoundtrack = nil; return result }
        let shortlist = musicAnalysisShortlist(tracks: tracks, timelines: [timeline])
        var structures: [UUID: MusicStructure] = [:]
        for track in shortlist where track.isPlayable {
            if Task.isCancelled { return result }
            structures[track.id] = await MusicStructureCache.shared.structure(for: track)
        }
        let explicit = plan.directorBrief?.musicPolicy == .specificTrack || plan.explicitMusicTrackID != nil || directive.searchRequests?.contains(where: { $0.exactTrack }) == true
        let preferences = await ExplicitEditorialPreferenceStore.shared.snapshot()
        let recent = await LocalMusicSelectionHistoryStore.shared.recentIdentities()
        let candidates = explicit ? shortlist.filter { $0.id == directive.trackID } : shortlist.filter { !preferences.excludes($0) && AutomaticSoundtrackSuitability.accepts($0, directive: directive) }
        func score(_ track: LocalMusicTrack) -> Double {
            let window = SoundtrackEditorialPolicy.window(track: track, structure: structures[track.id], timeline: result, analyses: analyses)
            let novelty = track.noveltyIdentities.isDisjoint(with: recent) ? 0.025 : 0
            return LocalMusicSelector().score(track, directive: directive) * 0.7 + window.score * 0.3 + preferences.musicAdjustment(track, style: directive.style) + novelty
        }
        let ranked = candidates.sorted { a, b in score(a) == score(b) ? a.selectionIdentity < b.selectionIdentity : score(a) > score(b) }
        if let track = ranked.first ?? tracks.first(where: { $0.id == directive.trackID }) {
            result = SoundtrackEditorialPolicy.applying(track: track, structure: structures[track.id], to: result, analyses: analyses,
                alternatives: ranked.dropFirst().map { "\($0.title): ниже совместная оценка характера и участка" })
        }
        guard plan.directorBrief?.musicPolicy != .specificTrack else { result.adaptiveSoundtrack = nil; return result }
        return AdaptiveSoundtrackPlanner().applying(to: result, plan: plan, tracks: shortlist,
            analyses: analyses, structures: structures)
    }

    private static func musicAnalysisShortlist(tracks: [LocalMusicTrack], timelines: [Timeline]) -> [LocalMusicTrack] {
        let directives = timelines.compactMap(\.music)
        let selected = Set(directives.compactMap(\.trackID))
        let playable = tracks.filter { $0.isPlayable }
        let required = playable.filter { selected.contains($0.id) }
        let ranked = playable.filter { track in !selected.contains(track.id) && directives.contains { AutomaticSoundtrackSuitability.accepts(track, directive: $0) } }
            .sorted { a, b in
                let x = directives.map { LocalMusicSelector().score(a, directive: $0) }.max() ?? 0
                let y = directives.map { LocalMusicSelector().score(b, directive: $0) }.max() ?? 0
                return x == y ? a.selectionIdentity < b.selectionIdentity : x > y
            }
        return required + ranked.prefix(max(0, SoundtrackEditorialPolicy.maximumCandidates - required.count))
    }

    /// Read-only preparation. No online search or project write is performed
    /// by opening, switching, or dismissing the comparison.
    public func musicAlternatives(for timeline: Timeline, limit: Int = 3) async throws -> [Timeline] {
        guard var directive = timeline.music else { return [] }
        let current = await store.manifest
        let tracks = try await musicSystem.tracks()
        let previous = tracks.first { $0.id == directive.trackID }
        directive.trackID = nil; directive.trackTitle = nil
        directive.searchRequests = directive.searchRequests?.filter { !$0.exactTrack }
        let preferences = await ExplicitEditorialPreferenceStore.shared.snapshot()
        var identities = previous?.noveltyIdentities ?? []
        let ranked = tracks.filter { $0.isPlayable && AutomaticSoundtrackSuitability.accepts($0, directive: directive) && !preferences.excludes($0) }
            .sorted { a, b in
                let x = LocalMusicSelector().score(a, directive: directive) + preferences.musicAdjustment(a, style: directive.style, projectID: current.id)
                let y = LocalMusicSelector().score(b, directive: directive) + preferences.musicAdjustment(b, style: directive.style, projectID: current.id)
                return x == y ? a.selectionIdentity < b.selectionIdentity : x > y
            }
        var options: [Timeline] = []
        for track in ranked {
            guard options.count < min(3, max(0, limit)) else { break }
            guard identities.isDisjoint(with: track.noveltyIdentities) else { continue }
            identities.formUnion(track.noveltyIdentities)
            try Task.checkCancellation()
            var option = timeline
            option.adaptiveSoundtrack = nil
            option.music = directive
            option = SoundtrackEditorialPolicy.applying(track: track,
                structure: await MusicStructureCache.shared.structure(for: track), to: option, analyses: current.analyses)
            options.append(option)
        }
        return options.sorted { ($0.music?.selectionEvidence?.window.score ?? 0) > ($1.music?.selectionEvidence?.window.score ?? 0) }
    }

    /// The expensive P6 pass is intentionally reserved for the automatic
    /// winner. It builds one real AVComposition, samples only risky places and
    /// may rebuild once when a render-grounded repair is accepted.
    private static func finalizePerceptualRenderReview(
        timeline source: Timeline,
        plan: StoryPlan,
        assets: [MediaAsset],
        analyses: [AnalysisResult],
        tracks: [LocalMusicTrack],
        telemetry: [UUID: TelemetrySummary],
        derivedMediaCacheURL: URL
    ) async -> Timeline {
        var timeline = source
        guard timeline.directorRun != nil else { return timeline }
        do {
            let playback = try await PlaybackEngine().build(
                timeline: timeline,
                assets: assets,
                musicTracks: tracks,
                telemetry: telemetry,
                derivedMediaCacheURL: derivedMediaCacheURL,
                forceVideoComposition: true
            )
            let evidence = await PerceptualRenderInspector().inspectAsync(playback: playback, timeline: timeline)
            guard !evidence.isEmpty else {
                if var run = timeline.directorRun, var summary = run.perceptualReview {
                    summary.renderReviewStatus = "render-built-no-decodable-samples"
                    run.recordPerceptualReview(summary)
                    timeline.directorRun = run
                }
                return timeline
            }
            let renderedPass = PerceptualReviewEngine().run(
                timeline: timeline,
                plan: plan,
                assets: assets,
                analyses: analyses,
                renderedFrames: evidence,
                budget: PerceptualReviewBudget(maximumIterations: 1, maximumRepairsPerIteration: 5, maximumBeamCandidates: 10, minimumScoreImprovement: 0.005, automaticRepairConfidence: 0.74)
            )
            let previousSummary = timeline.directorRun?.perceptualReview
            timeline = renderedPass.timeline
            var finalSummary = renderedPass.summary

            // A committed render repair gets one post-repair visual check. No
            // further loop is allowed here, so preview preparation is bounded.
            if !renderedPass.appliedCalls.isEmpty {
                let repairedPlayback = try await PlaybackEngine().build(
                    timeline: timeline,
                    assets: assets,
                    musicTracks: tracks,
                    telemetry: telemetry,
                    derivedMediaCacheURL: derivedMediaCacheURL,
                    forceVideoComposition: true
                )
                let repairedEvidence = await PerceptualRenderInspector().inspectAsync(playback: repairedPlayback, timeline: timeline)
                let validation = PerceptualReviewEngine().run(
                    timeline: timeline,
                    plan: plan,
                    assets: assets,
                    analyses: analyses,
                    renderedFrames: repairedEvidence,
                    budget: PerceptualReviewBudget(maximumIterations: 0)
                )
                finalSummary.findings = validation.summary.findings
                finalSummary.highSeverityFindings = validation.summary.highSeverityFindings
                finalSummary.finalScore = validation.summary.finalScore
                finalSummary.perceptualScoreAfter = validation.summary.perceptualScoreAfter
                finalSummary.cutScores = validation.summary.cutScores
                finalSummary.renderedFrameSampleCount += validation.summary.renderedFrameSampleCount
                finalSummary.renderReviewStatus = "selective-render-repaired-and-verified"
            }
            if let previousSummary {
                finalSummary.initialScore = previousSummary.initialScore
                finalSummary.perceptualScoreBefore = previousSummary.perceptualScoreBefore
                finalSummary.perceptualReviewIterations += previousSummary.perceptualReviewIterations
                finalSummary.repairsAttempted += previousSummary.repairsAttempted
                finalSummary.repairsAccepted += previousSummary.repairsAccepted
                finalSummary.repairsRejected += previousSummary.repairsRejected
                finalSummary.rollbackCount += previousSummary.rollbackCount
                finalSummary.repairAttempts = previousSummary.repairAttempts + finalSummary.repairAttempts
            }
            if var run = timeline.directorRun {
                run.appliedToolNames.append(contentsOf: renderedPass.appliedCalls.map { $0.tool.rawValue })
                run.decisionReasons.append(contentsOf: renderedPass.appliedCalls.map(\.reason))
                run.rejectedOperations.append(contentsOf: renderedPass.rejectedOperations)
                run.globalScore = DefaultMontageGlobalScorer().score(plan: plan, timeline: timeline, assets: assets, analyses: analyses).total
                run.recordPerceptualReview(finalSummary)
                timeline.directorRun = run
            }
            return timeline
        } catch {
            // A corrupt/missing source remains visible as a production
            // diagnostic, while metadata repairs already accepted by P6 stay
            // intact and no valid Timeline is discarded.
            if var run = timeline.directorRun, var summary = run.perceptualReview {
                summary.renderReviewStatus = "render-review-unavailable: \(error.localizedDescription)"
                run.rejectedOperations.append("P6 render-aware review недоступен: \(error.localizedDescription)")
                run.recordPerceptualReview(summary)
                timeline.directorRun = run
            }
            return timeline
        }
    }

    /// Story regeneration may replace/reorder candidates, but visual and audio
    /// edits attached to surviving candidates must not disappear.
    static func carryEditorAdjustments(
        from previous: Timeline,
        to generated: Timeline,
        directorBrief: DirectorBrief? = nil
    ) -> Timeline {
        var result = generated
        if let format = directorBrief?.canvasFormat {
            result.width = format.width
            result.height = format.height
        } else {
            // Preserve a manually selected canvas for legacy projects whose
            // StoryPlan predates the structured Director brief.
            result.width = previous.width
            result.height = previous.height
        }
        let previousByCandidate = Dictionary(
            previous.items.compactMap { item in item.candidateID.map { ($0, item) } },
            uniquingKeysWith: { first, _ in first }
        )
        var newIDByOldID: [UUID: UUID] = [:]
        for index in result.items.indices {
            guard let candidateID = result.items[index].candidateID,
                  let old = previousByCandidate[candidateID] else { continue }
            result.items[index].sourceStart = old.sourceStart
            result.items[index].sourceDuration = old.sourceDuration
            result.items[index].speed = old.speed
            result.items[index].speedRamp = old.speedRamp
            result.items[index].timelineDuration = max(0.05, old.speedRamp?.outputDuration(sourceDuration: old.sourceDuration) ?? (old.sourceDuration / old.speed))
            result.items[index].transition = old.transition
            result.items[index].effect = old.effect
            result.items[index].videoAdjustments = old.videoAdjustments
            result.items[index].audioAdjustments = old.audioAdjustments
            result.items[index].overlay = old.overlay
            // Telemetry is request-scoped. Carrying this legacy clip-wide
            // field makes an old automatic HUD reappear across the entire
            // clip even when the regenerated brief does not request it. Keep
            // only the value produced by the current generation; manual
            // Timeline telemetry remains available as an independent layer.
            result.items[index].locked = old.locked
            newIDByOldID[old.id] = result.items[index].id
        }
        for index in result.items.indices {
            if let oldBaseID = result.items[index].overlay?.baseItemID {
                result.items[index].overlay?.baseItemID = newIDByOldID[oldBaseID]
                if result.items[index].overlay?.baseItemID == nil {
                    result.items[index].overlay = nil
                }
            }
        }
        // Freeze frames are standalone editor-created clips (candidateID=nil),
        // so candidate-based regeneration cannot recreate them. Anchor each
        // hold to the surviving source clip that preceded it and reinsert it
        // immediately after that clip before magnetic retiming.
        var freezesByAnchorID: [UUID: [TimelineItem]] = [:]
        for (index, item) in previous.items.enumerated() where item.isFreezeFrame {
            guard let oldAnchor = previous.items[..<index].last(where: {
                $0.overlay == nil && $0.kind != .title && !$0.isFreezeFrame && newIDByOldID[$0.id] != nil
            }), let newAnchorID = newIDByOldID[oldAnchor.id] else { continue }
            freezesByAnchorID[newAnchorID, default: []].append(item)
        }
        for index in result.items.indices.reversed() {
            guard let freezes = freezesByAnchorID[result.items[index].id], !freezes.isEmpty else { continue }
            result.items.insert(contentsOf: freezes, at: index + 1)
        }
        let oldTitles = previous.items.filter { $0.kind == .title }
        for title in oldTitles {
            if title.timelineStart < previous.duration * 0.5 {
                result.items.insert(title, at: 0)
            } else {
                result.items.append(title)
            }
        }
        result.music = previous.music
        result.originalAudioVolume = previous.originalAudioVolume
        result.audioDucking = previous.audioDucking
        result.items = retimed(result.items)
        return TitleEditPreservation.applying(from: previous, to: result, clipIDs: newIDByOldID)
    }

    private func migrateLegacyTimelineAudioSettings() async throws {
        let current = await store.manifest
        let needsMigration = current.timelines.contains { timeline in
            let sanitized = AutomatedTitlePolicy.sanitized(timeline.effectiveTitleItems, timelineDuration: timeline.duration)
            return timeline.originalAudioVolume == nil || sanitized != timeline.effectiveTitleItems
        }
        guard needsMigration else { return }
        try await store.update { project in
            let plans = Dictionary(uniqueKeysWithValues: project.storyPlans.map { ($0.id, $0) })
            for index in project.timelines.indices {
                let timeline = project.timelines[index]
                let prompt = plans[timeline.storyPlanID]?.prompt ?? ""
                let sanitizedTitles = AutomatedTitlePolicy.sanitized(
                    timeline.effectiveTitleItems,
                    timelineDuration: timeline.duration
                )
                let repairedGeneratedTitles = sanitizedTitles != timeline.effectiveTitleItems
                if repairedGeneratedTitles {
                    project.timelines[index].titleItems = sanitizedTitles
                }
                if timeline.originalAudioVolume == nil || repairedGeneratedTitles,
                   let requestedVolume = OriginalAudioPromptInterpreter().volume(prompt: prompt) {
                    project.timelines[index].originalAudioVolume = requestedVolume
                    if repairedGeneratedTitles, requestedVolume < 0.999 {
                        project.timelines[index].audioClips = timeline.effectiveAudioClips.map { clip in
                            guard clip.title.contains("J/L-cut") || clip.title.contains("L-cut") else { return clip }
                            var copy = clip
                            copy.adjustments.volume = min(copy.adjustments.volume, requestedVolume)
                            return copy
                        }
                    }
                } else if timeline.originalAudioVolume == nil {
                    project.timelines[index].originalAudioVolume = 1
                }
            }
        }
    }

    private static func recordMusicCredit(
        from timeline: Timeline,
        tracks: [LocalMusicTrack],
        in project: inout ProjectManifest
    ) {
        var credits = project.musicCredits ?? []
        let trackIDs = Set(
            [timeline.music?.trackID].compactMap { $0 } +
            (timeline.effectiveAdaptiveSoundtrack?.segments.compactMap(\.directive.trackID) ?? [])
        )
        for track in tracks where trackIDs.contains(track.id) {
            let credit = MusicCredit(track: track)
            credits.removeAll { $0.id == credit.id }
            credits.append(credit)
        }
        project.musicCredits = credits
    }

    private static func moveTimelineItem(in timeline: inout Timeline, from oldIndex: Int, to requestedIndex: Int) {
        let newIndex = min(max(0, requestedIndex), timeline.items.count - 1)
        guard oldIndex != newIndex else { return }
        let previousClips = Dictionary(uniqueKeysWithValues: timeline.items.map { ($0.id, $0) })
        let item = timeline.items.remove(at: oldIndex)
        timeline.items.insert(item, at: newIndex)
        timeline.items = retimed(timeline.items)
        alignTelemetryItems(in: &timeline, previousClips: previousClips)
    }

    private static func alignTelemetryItems(in timeline: inout Timeline, previousClips: [UUID: TimelineItem]) {
        guard !timeline.effectiveTelemetryItems.isEmpty else { return }
        let clips = Dictionary(uniqueKeysWithValues: timeline.items.map { ($0.id, $0) })
        timeline.telemetryItems = timeline.effectiveTelemetryItems.compactMap { source in
            guard let targetID = source.targetClipID else { return source }
            guard let clip = clips[targetID] else { return nil }
            var item = source
            if let previous = previousClips[targetID] {
                let coveredWholeClip = abs(item.timelineStart - previous.timelineStart) < 0.001 &&
                    abs(item.timelineDuration - previous.timelineDuration) < 0.001
                if coveredWholeClip {
                    item.timelineStart = clip.timelineStart
                    item.timelineDuration = max(0.05, clip.timelineDuration)
                } else {
                    let offset = item.timelineStart - previous.timelineStart
                    item.timelineStart = min(max(clip.timelineStart, clip.timelineStart + offset), max(clip.timelineStart, clip.timelineStart + clip.timelineDuration - 0.05))
                    item.timelineDuration = min(item.timelineDuration, max(0.05, clip.timelineStart + clip.timelineDuration - item.timelineStart))
                }
            }
            item.linkedAssetID = clip.assetID
            item.sourceStart = clip.sourceTime(atTimelineTime: item.timelineStart)
            return item
        }
    }
}

private extension EditorCommand {
    /// Reuses the command's ordinary clip target inside a brushed timeline
    /// range. Global commands return `nil` and are handled by the range safety
    /// policy below.
    var timelineRangeTarget: EditorCommandTarget? {
        switch self {
        case .setSpeed(_, let target),
             .removeSlowMotion(let target),
             .setSpeedRamp(_, let target),
             .setDuration(_, let target),
             .setFilter(_, let target),
             .setCrop(_, let target),
             .rotate(_, let target),
             .setBrightness(_, let target),
             .setContrast(_, let target),
             .setSaturation(_, let target),
             .setWarmth(_, let target),
             .setOpacity(_, let target),
             .setExposure(_, let target),
             .setHighlights(_, let target),
             .setShadows(_, let target),
             .setVignette(_, let target),
             .setGrain(_, let target),
             .setSharpening(_, let target),
             .setVideoDenoise(_, let target),
             .setBlur(_, let target),
             .setStabilization(_, let target),
             .setRollingShutterCorrection(_, let target),
             .setSmoothSlowMotion(_, let target),
             .autoEnhance(let target),
             .setClipVolume(_, let target),
             .setClipMuted(_, let target),
             .setNoiseReduction(_, let target),
             .setEQ(_, let target),
             .detachAudio(let target),
             .setTransition(_, let target),
             .setTransitionPattern(_, let target),
             .setEffect(_, let target),
             .addLibraryEffect(_, let target),
             .setEffectPattern(_, let target),
             .setTelemetryOverlay(_, let target),
             .insertFreezeFrame(_, let target),
             .insertInstantReplay(_, let target),
             .setReverse(_, let target),
             .delete(let target),
             .duplicate(let target),
             .split(let target),
             .move(let target, _):
            return target
        case .setClipFades(_, _, let target):
            return target
        case .setOverlay(_, let target, _):
            return target
        case .setTitleText(_, let target), .setTitleStyle(_, _, _, _, let target), .applyTitleTemplate(_, let target):
            return target
        case .insertBackground, .insertSource, .addTitle, .removeTitles, .setAudioDucking,
             .setOriginalAudioVolume, .setMusic, .setMusicVolume:
            return nil
        }
    }

    /// The ordinary executor keeps legacy title cards in `Timeline.items`, so
    /// title styling must resolve against those IDs instead of video clip IDs.
    var targetsLegacyTitles: Bool {
        switch self {
        case .setTitleText, .setTitleStyle, .applyTitleTemplate:
            return true
        default:
            return false
        }
    }

    /// A range edit resolves concrete item IDs before execution. Retargeting
    /// each typed command to `.selected` prevents an `.all`/`.first` target
    /// from escaping that resolved set when the executor is called per item.
    func retargetedForTimelineRange() -> EditorCommand? {
        let target: EditorCommandTarget = .selected
        switch self {
        case .insertBackground, .insertSource: return nil
        case .addLibraryEffect(let type, _): return .addLibraryEffect(type, target)
        case .applyTitleTemplate(let id, _): return .applyTitleTemplate(id, target)
        case .setSpeed(let value, _): return .setSpeed(value, target)
        case .removeSlowMotion: return .removeSlowMotion(target)
        case .setSpeedRamp(let value, _): return .setSpeedRamp(value, target)
        case .setDuration(let value, _): return .setDuration(value, target)
        case .setFilter(let value, _): return .setFilter(value, target)
        case .setCrop(let value, _): return .setCrop(value, target)
        case .rotate(let value, _): return .rotate(value, target)
        case .setBrightness(let value, _): return .setBrightness(value, target)
        case .setContrast(let value, _): return .setContrast(value, target)
        case .setSaturation(let value, _): return .setSaturation(value, target)
        case .setWarmth(let value, _): return .setWarmth(value, target)
        case .setOpacity(let value, _): return .setOpacity(value, target)
        case .setExposure(let value, _): return .setExposure(value, target)
        case .setHighlights(let value, _): return .setHighlights(value, target)
        case .setShadows(let value, _): return .setShadows(value, target)
        case .setVignette(let value, _): return .setVignette(value, target)
        case .setGrain(let value, _): return .setGrain(value, target)
        case .setSharpening(let value, _): return .setSharpening(value, target)
        case .setVideoDenoise(let value, _): return .setVideoDenoise(value, target)
        case .setBlur(let value, _): return .setBlur(value, target)
        case .setStabilization(let value, _): return .setStabilization(value, target)
        case .setRollingShutterCorrection(let value, _): return .setRollingShutterCorrection(value, target)
        case .setSmoothSlowMotion(let value, _): return .setSmoothSlowMotion(value, target)
        case .autoEnhance: return .autoEnhance(target)
        case .setClipVolume(let value, _): return .setClipVolume(value, target)
        case .setClipMuted(let value, _): return .setClipMuted(value, target)
        case .setClipFades(let fadeIn, let fadeOut, _): return .setClipFades(fadeIn, fadeOut, target)
        case .setNoiseReduction(let value, _): return .setNoiseReduction(value, target)
        case .setEQ(let value, _): return .setEQ(value, target)
        case .detachAudio: return .detachAudio(target)
        case .setTransition(let value, _): return .setTransition(value, target)
        case .setTransitionPattern(let value, _): return .setTransitionPattern(value, target)
        case .setEffect(let value, _): return .setEffect(value, target)
        case .setEffectPattern(let value, _): return .setEffectPattern(value, target)
        case .setTelemetryOverlay(let value, _): return .setTelemetryOverlay(value, target)
        case .insertFreezeFrame(let value, _): return .insertFreezeFrame(value, target)
        case .insertInstantReplay(let value, _): return .insertInstantReplay(value, target)
        case .setReverse(let value, _): return .setReverse(value, target)
        case .setTitleText(let value, _): return .setTitleText(value, target)
        case .setTitleStyle(let size, let textColor, let backgroundColor, let alignment, _):
            return .setTitleStyle(size, textColor, backgroundColor, alignment, target)
        case .delete: return .delete(target)
        case .duplicate: return .duplicate(target)
        case .split: return .split(target)
        case .setAudioDucking, .setOverlay, .addTitle, .removeTitles, .move,
             .setOriginalAudioVolume, .setMusic, .setMusicVolume:
            return nil
        }
    }


}
