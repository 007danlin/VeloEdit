import Foundation

public actor VeloEditPipeline {
    public let store: ProjectStore
    private let importer: MediaImporter
    private let analyzer: (any VisionModelProtocol)?
    private let musicLibrary: LocalMusicLibrary
    private let musicSystem: MusicLibrary
    private let personalTasteStore: LocalPersonalTasteStore
    private var lastMusicResolutionError: String?
    private let analysisQueue = AnalysisBackgroundQueue()
    private var activeAnalysisTask: Task<AnalysisResult, Error>?
    private var activeAnalysisAssetID: UUID?
    private var latestClientTimelineRevision: UInt64 = 0

    public init(
        store: ProjectStore,
        importer: MediaImporter = MediaImporter(),
        analyzer: (any VisionModelProtocol)? = nil,
        musicLibrary: LocalMusicLibrary? = nil,
        freeToUseProvider: FreeToUseMusicProvider? = nil,
        personalTasteStore: LocalPersonalTasteStore = LocalPersonalTasteStore()
    ) {
        self.store = store
        self.importer = importer
        self.analyzer = analyzer
        let projectMusicLibrary = musicLibrary ?? LocalMusicLibrary(rootURL: store.musicLibraryURL)
        self.musicLibrary = projectMusicLibrary
        let bundledProvider = BundledMusicProvider(library: projectMusicLibrary)
        let localProvider = LocalMusicProvider(library: projectMusicLibrary)
        let onlineFreeToUseProvider = freeToUseProvider ?? FreeToUseMusicProvider(library: projectMusicLibrary)
        let openverseProvider = OpenverseMusicProvider(library: projectMusicLibrary)
        self.musicSystem = MusicLibrary(
            localLibrary: projectMusicLibrary,
            providers: [bundledProvider, localProvider, onlineFreeToUseProvider, openverseProvider]
        )
        self.personalTasteStore = personalTasteStore
    }

    public func updateAISettings(mode: AIPowerMode, advanced: AdvancedAISettings) async throws {
        try await store.update { project in
            project.preferences.aiPowerMode = mode
            project.preferences.advancedAISettings = advanced
        }
    }

    public func updateWorkspaceState(_ state: ProjectWorkspaceState) async throws {
        try await store.update { project in
            project.workspaceState = state
        }
    }

    public func save() async throws {
        try await store.save()
    }

    /// Persists an already-normalized optimistic Timeline. Calls may arrive out
    /// of order after preview work; only the newest client revision is allowed
    /// to become project state.
    @discardableResult
    public func commitLatestTimeline(_ timeline: Timeline, clientRevision: UInt64) async throws -> Bool {
        guard clientRevision >= latestClientTimelineRevision else { return false }
        latestClientTimelineRevision = clientRevision
        let tracks = (try? await musicSystem.tracks()) ?? []
        try await store.update { project in
            guard let index = project.timelines.indices.last else { return }
            project.timelines[index] = timeline
            Self.recordMusicCredit(from: timeline, tracks: tracks, in: &project)
        }
        return true
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
            var timeline = project.timelines[timelineIndex]
            timeline.items = Self.retimed(timeline.items)
            guard let index = timeline.items.firstIndex(where: { $0.id == id }),
                  timeline.items[index].kind != .title else { return }
            let original = timeline.items[index]
            let frame = 1 / max(1, timeline.frameRate)
            let splitTime = TimelineTiming.quantized(requestedTime, frameRate: timeline.frameRate)
            let localTime = splitTime - original.timelineStart
            guard localTime >= frame, original.timelineDuration - localTime >= frame else { return }
            let fraction = localTime / original.timelineDuration
            let firstSourceDuration = original.sourceDuration * fraction
            var left = original
            left.sourceDuration = firstSourceDuration
            left.timelineDuration = localTime
            var right = original
            right.id = UUID()
            right.sourceStart = original.sourceStart + firstSourceDuration
            right.sourceDuration = original.sourceDuration - firstSourceDuration
            right.timelineStart = splitTime
            right.timelineDuration = original.timelineDuration - localTime
            right.transition = nil
            if right.overlay != nil {
                right.overlay?.startOffset = (original.overlay?.effectiveStartOffset ?? 0) + localTime
            }
            timeline.items[index] = left
            timeline.items.insert(right, at: index + 1)
            timeline.items = Self.retimed(timeline.items)
            project.timelines[timelineIndex] = timeline
            createdID = right.id
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
            var timeline = project.timelines[timelineIndex]
            timeline.items = Self.retimed(timeline.items)
            guard let itemIndex = timeline.items.firstIndex(where: { $0.id == itemID }),
                  timeline.items[itemIndex].kind == .video,
                  let assetID = timeline.items[itemIndex].assetID,
                  let asset = project.assets.first(where: { $0.id == assetID }),
                  asset.metadata.hasAudio else { return }
            if let existing = timeline.effectiveAudioClips.first(where: {
                $0.assetID == assetID && $0.sourceStart == timeline.items[itemIndex].sourceStart && $0.role == .detached
            }) {
                createdID = existing.id
                return
            }
            let item = timeline.items[itemIndex]
            let id = UUID()
            let clip = TimelineAudioClip(
                id: id,
                assetID: assetID,
                title: "Звук — \(asset.displayName)",
                role: .detached,
                sourceStart: item.sourceStart,
                sourceDuration: item.sourceDuration,
                timelineStart: item.timelineStart,
                timelineDuration: item.timelineDuration,
                adjustments: item.effectiveAudioAdjustments
            )
            var embedded = item.effectiveAudioAdjustments
            embedded.muted = true
            timeline.items[itemIndex].audioAdjustments = embedded
            var clips = timeline.effectiveAudioClips
            clips.append(clip)
            timeline.audioClips = clips
            project.timelines[timelineIndex] = timeline
            createdID = id
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
            var timeline = project.timelines[timelineIndex]
            var clips = timeline.effectiveAudioClips
            guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
            let original = clips[index]
            let frame = 1 / max(1, timeline.frameRate)
            let split = TimelineTiming.quantized(requestedTime, frameRate: timeline.frameRate)
            let local = split - original.timelineStart
            guard local >= frame, original.timelineDuration - local >= frame else { return }
            var left = original
            left.sourceDuration = min(left.sourceDuration, local)
            left.timelineDuration = local
            var right = original
            right.id = UUID()
            right.sourceStart += local
            right.sourceDuration = max(0.05, original.sourceDuration - local)
            right.timelineStart = split
            right.timelineDuration = original.timelineDuration - local
            clips[index] = left
            clips.insert(right, at: index + 1)
            timeline.audioClips = clips
            project.timelines[timelineIndex] = timeline
            createdID = right.id
        }
        return createdID
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
    @discardableResult
    public func applyEditorCommands(
        _ prompt: String,
        timelineRange: ClosedRange<Double>,
        preset: FilmPreset = .story
    ) async throws -> EditorCommandReport {
        let parsed = EditorCommandParser().parse("выбранный фрагмент, \(prompt)", preset: preset)
        return try await applyEditorCommands(parsed, timelineRange: timelineRange)
    }

    /// Executes a language model's typed plan inside the brushed range. Global
    /// operations are rejected before slicing, so an AI-selected tool cannot
    /// accidentally leak into the rest of the film.
    @discardableResult
    public func applyEditorCommands(
        _ commands: [EditorCommand],
        timelineRange: ClosedRange<Double>
    ) async throws -> EditorCommandReport {
        let localCommands = commands.filter(\.canApplyInsideTimelineRange)
        var report = EditorCommandReport(recognizedCount: commands.count)

        guard !localCommands.isEmpty else {
            report.ignored.append("Эта команда относится ко всему фильму и недоступна для локального диапазона")
            return report
        }

        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            Self.appendCheckpoint(
                timeline: project.timelines[timelineIndex],
                reason: "Перед локальной правкой Волшебной кистью",
                to: &project
            )
            let localized = Self.sliced(project.timelines[timelineIndex], for: timelineRange)
            var timeline = localized.timeline
            var applied: [String] = []
            var ignored: [String] = []
            var affected = Set<UUID>()

            for itemID in localized.itemIDs {
                let result = EditorCommandExecutor().apply(
                    localCommands,
                    to: timeline,
                    selectedItemID: itemID
                )
                timeline = result.timeline
                applied.append(contentsOf: result.report.applied)
                ignored.append(contentsOf: result.report.ignored)
                affected.formUnion(result.report.affectedItemIDs)
            }

            // Standalone objects share the same brushed interval. Apply the
            // command kinds that are meaningful for each object type to the
            // sliced IDs, so audio, titles, telemetry and effects cannot be
            // visually selected yet silently ignored.
            for command in localCommands {
                switch command {
                case .setClipVolume(let volume, _):
                    timeline.audioClips = timeline.effectiveAudioClips.map { clip in
                        guard localized.audioClipIDs.contains(clip.id) else { return clip }
                        var copy = clip; copy.adjustments.volume = min(max(0, volume), 2); affected.insert(copy.id); return copy
                    }
                case .setClipMuted(let muted, _):
                    timeline.audioClips = timeline.effectiveAudioClips.map { clip in
                        guard localized.audioClipIDs.contains(clip.id) else { return clip }
                        var copy = clip; copy.adjustments.muted = muted; affected.insert(copy.id); return copy
                    }
                case .setClipFades(let fadeIn, let fadeOut, _):
                    timeline.audioClips = timeline.effectiveAudioClips.map { clip in
                        guard localized.audioClipIDs.contains(clip.id) else { return clip }
                        var copy = clip
                        copy.adjustments.fadeIn = min(max(0, fadeIn), copy.timelineDuration)
                        copy.adjustments.fadeOut = min(max(0, fadeOut), copy.timelineDuration)
                        affected.insert(copy.id); return copy
                    }
                case .setNoiseReduction(let amount, _):
                    timeline.audioClips = timeline.effectiveAudioClips.map { clip in
                        guard localized.audioClipIDs.contains(clip.id) else { return clip }
                        var copy = clip; copy.adjustments.noiseReduction = min(max(0, amount), 1); affected.insert(copy.id); return copy
                    }
                case .setEQ(let preset, _):
                    timeline.audioClips = timeline.effectiveAudioClips.map { clip in
                        guard localized.audioClipIDs.contains(clip.id) else { return clip }
                        var copy = clip; copy.adjustments.eqPreset = preset; affected.insert(copy.id); return copy
                    }
                case .setTitleStyle(let size, let textColor, let backgroundColor, let alignment, _):
                    timeline.titleItems = timeline.effectiveTitleItems.map { title in
                        guard localized.titleItemIDs.contains(title.id) else { return title }
                        var copy = title
                        if let size { copy.style.fontSize = min(max(18, size), 220) }
                        if let textColor { copy.style.textColorHex = textColor }
                        if let backgroundColor { copy.style.backgroundColorHex = backgroundColor }
                        if let alignment { copy.style.alignment = alignment }
                        affected.insert(copy.id); return copy
                    }
                case .setOpacity(let opacity, _):
                    timeline.titleItems = timeline.effectiveTitleItems.map { title in
                        guard localized.titleItemIDs.contains(title.id) else { return title }
                        var copy = title; copy.style.opacity = min(max(0, opacity), 1); affected.insert(copy.id); return copy
                    }
                    timeline.telemetryItems = timeline.effectiveTelemetryItems.map { item in
                        guard localized.telemetryItemIDs.contains(item.id) else { return item }
                        var copy = item; copy.settings.opacity = min(max(0, opacity), 1); affected.insert(copy.id); return copy
                    }
                    timeline.effects = timeline.effectiveEffects.map { item in
                        guard localized.effectItemIDs.contains(item.id) else { return item }
                        var copy = item; copy.intensity = min(max(0, opacity), 1); affected.insert(copy.id); return copy
                    }
                case .setDuration(let duration, _):
                    timeline.audioClips = timeline.effectiveAudioClips.map { item in
                        guard localized.audioClipIDs.contains(item.id) else { return item }
                        var copy = item; copy.timelineDuration = min(copy.sourceDuration, max(0.05, duration)); affected.insert(copy.id); return copy
                    }
                    timeline.telemetryItems = timeline.effectiveTelemetryItems.map { item in
                        guard localized.telemetryItemIDs.contains(item.id) else { return item }
                        var copy = item; copy.timelineDuration = max(0.05, duration); affected.insert(copy.id); return copy
                    }
                    timeline.effects = timeline.effectiveEffects.map { item in
                        guard localized.effectItemIDs.contains(item.id) else { return item }
                        var copy = item; copy.duration = max(0.05, duration); affected.insert(copy.id); return copy
                    }
                    timeline.titleItems = timeline.effectiveTitleItems.map { item in
                        guard localized.titleItemIDs.contains(item.id) else { return item }
                        var copy = item; copy.duration = max(0.05, duration); affected.insert(copy.id); return copy
                    }
                case .removeTitles:
                    timeline.titleItems = timeline.effectiveTitleItems.filter { !localized.titleItemIDs.contains($0.id) }
                    affected.formUnion(localized.titleItemIDs)
                case .delete:
                    timeline.audioClips = timeline.effectiveAudioClips.filter { !localized.audioClipIDs.contains($0.id) }
                    timeline.telemetryItems = timeline.effectiveTelemetryItems.filter { !localized.telemetryItemIDs.contains($0.id) }
                    timeline.effects = timeline.effectiveEffects.filter { !localized.effectItemIDs.contains($0.id) }
                    timeline.titleItems = timeline.effectiveTitleItems.filter { !localized.titleItemIDs.contains($0.id) }
                    affected.formUnion(localized.audioClipIDs + localized.telemetryItemIDs + localized.effectItemIDs + localized.titleItemIDs)
                default:
                    break
                }
            }

            project.timelines[timelineIndex] = Self.clampedToAvailableMedia(timeline, assets: project.assets)
            if !affected.isEmpty, applied.isEmpty {
                applied.append("изменены объекты внутри выделенного диапазона")
            }
            report.applied = applied
            report.ignored = ignored
            report.affectedItemIDs = Array(affected)
        }
        return report
    }

    public func updateMusic(_ directive: MusicDirective?) async throws {
        let current = await store.manifest
        let previousTrackID = current.timelines.last?.music?.trackID
        let requested = Self.musicDirective(directive, replacing: previousTrackID)
        let tracks = try await tracksForResolving(requested)
        if let requested, requested.trackID == nil,
           LocalMusicSelector().select(
               for: requested,
               from: tracks,
               excluding: requested.preferDifferentTrack == true ? previousTrackID : nil
           ) == nil {
            throw FreeToUseAPIError.providerFailure(
                lastMusicResolutionError ?? "в локальной библиотеке нет доступного аудиофайла"
            )
        }
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            let previousTrackID = project.timelines[timelineIndex].music?.trackID
            var resolved = requested
            if var value = resolved, value.trackID == nil,
               let track = LocalMusicSelector().select(
                   for: value,
                   from: tracks,
                   excluding: value.preferDifferentTrack == true ? previousTrackID : nil
               ) {
                value.trackID = track.id
                value.trackTitle = track.title
                value.bpm = track.bpm
                value.preferDifferentTrack = nil
                resolved = value
            } else if resolved?.preferDifferentTrack == true, previousTrackID != nil {
                // Do not make an existing montage unplayable when the local
                // catalog has no second matching file.
                resolved = project.timelines[timelineIndex].music
            }
            project.timelines[timelineIndex].music = resolved
            if let trackID = resolved?.trackID,
               trackID != previousTrackID,
               let track = tracks.first(where: { $0.id == trackID }) {
                project.timelines[timelineIndex] = MusicBeatSynchronizer().refreshingStructure(in: project.timelines[timelineIndex], for: track)
            }
            Self.recordMusicCredit(from: project.timelines[timelineIndex], tracks: tracks, in: &project)
        }
    }

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
            for index in project.timelines.indices where project.timelines[index].music?.trackID == id {
                project.timelines[index].music = nil
            }
        }
    }

    public func updateOriginalAudioVolume(_ volume: Double) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            project.timelines[timelineIndex].originalAudioVolume = min(max(0, volume), 1)
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
        var report = EditorCommandReport(recognizedCount: commands.count)
        let current = await store.manifest
        let previousTrackID = current.timelines.last?.music?.trackID
        let parsedMusic = commands.reversed().compactMap { command -> MusicDirective? in
            if case .setMusic(let directive?) = command { return directive }
            return nil
        }.first
        let requestedMusic = Self.musicDirective(parsedMusic, replacing: previousTrackID)
        let tracks = try await tracksForResolving(requestedMusic)
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            if createCheckpoint, !commands.isEmpty {
                Self.appendCheckpoint(
                    timeline: project.timelines[timelineIndex],
                    reason: "Перед применением AI editing tools",
                    to: &project
                )
            }
            let previousTrackID = project.timelines[timelineIndex].music?.trackID
            let result = EditorCommandExecutor().apply(
                commands,
                to: project.timelines[timelineIndex],
                selectedItemID: selectedItemID,
                selectedCandidateID: selectedCandidateID
            )
            var timeline = Self.clampedToAvailableMedia(result.timeline, assets: project.assets)
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
                timeline.music = project.timelines[timelineIndex].music
            }
            if let trackID = timeline.music?.trackID,
               trackID != previousTrackID,
               let track = tracks.first(where: { $0.id == trackID }) {
                timeline = MusicBeatSynchronizer().refreshingStructure(in: timeline, for: track)
            }
            project.timelines[timelineIndex] = timeline
            report = result.report
            let replacementFailed = requestedMusic?.preferDifferentTrack == true
                && previousTrackID != nil
                && timeline.music?.trackID == previousTrackID
            if requestedMusic != nil, timeline.music?.trackID == nil || replacementFailed {
                report.applied.removeAll { $0.hasPrefix("музыка «") }
                let reason = self.lastMusicResolutionError
                    ?? "в локальной библиотеке нет доступного аудиофайла"
                let action = replacementFailed ? "не изменён" : "не добавлен"
                report.ignored.append("саундтрек \(action): \(reason)")
            }
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
        let current = snapshot.manifest
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
        let input = NaturalLanguageDirectorInput(
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
        try await store.update(ifRevision: snapshot.revision) { project in
            guard let index = project.timelines.indices.last else { return }
            if createCheckpoint {
                Self.appendCheckpoint(
                    timeline: project.timelines[index],
                    reason: "Перед natural-language правкой: \(request.prefix(80))",
                    to: &project
                )
            }
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
            items[itemIndex] = item
            project.timelines[timelineIndex].titleItems = items
        }
    }

    public func deleteTitleTimelineItem(id: UUID) async throws {
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
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
        let visualURLs = importer.expand(urls)
        let audioURLs = importer.expandAudio(urls)
        let telemetryURLs = importer.expandTelemetry(urls)
        guard !visualURLs.isEmpty || !audioURLs.isEmpty || !telemetryURLs.isEmpty else {
            return ["Поддерживаются фото, видео, аудио и телеметрия GPX/FIT/SRT/CSV/VBO."]
        }
        let results = await importer.importAssets(from: visualURLs, existing: current.assets, progress: progress)
        var imported: [MediaAsset] = []
        var errors: [String] = []
        for result in results {
            switch result {
            case .success(let asset): imported.append(asset)
            case .failure(let error): errors.append(error.localizedDescription)
            }
        }
        for audioURL in audioURLs {
            do {
                _ = try await musicLibrary.importUserTrack(audioURL)
            } catch MusicLibraryError.duplicateSource {
                // Reimporting a selected folder should be idempotent.
            } catch {
                errors.append("\(audioURL.lastPathComponent): \(error.localizedDescription)")
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
            } catch {
                errors.append("\(telemetryURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        try await store.update { project in
            let known = Set(project.assets.map(\.contentHash))
            project.assets.append(contentsOf: unique.filter { !known.contains($0.contentHash) })
            if !unique.isEmpty || !telemetrySources.isEmpty { project.sourceMap = nil }
            let knownTelemetry = Set(project.effectiveTelemetrySources.compactMap { $0.originalURL?.standardizedFileURL })
            project.telemetrySources = project.effectiveTelemetrySources + telemetrySources.filter { source in
                guard let url = source.originalURL?.standardizedFileURL else { return true }
                return !knownTelemetry.contains(url)
            }
        }
        return errors
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
        let current = await store.manifest
        let baseProfile = AIAnalysisProfile.resolve(
            mode: current.preferences.effectiveAIPowerMode,
            advanced: current.preferences.effectiveAdvancedAISettings,
            thermalState: .nominal
        )
        let pending = current.assets.filter { asset in
            !current.analyses.contains {
                guard $0.assetID == asset.id,
                      $0.analyzedContentHash == asset.contentHash,
                      $0.schemaVersion == current.analysisSchemaVersion,
                      $0.deepMediaVersion == DeepAnalysisCache.version,
                      $0.satisfies(baseProfile) else { return false }
                return ($0.completedDepth ?? .quick) > baseProfile.targetDepth || $0.analysisProfileKey == baseProfile.cacheKey
            }
        }
        let initialQueue = await analysisQueue.replace(with: pending, preferredAssetID: preferredAssetID)
        try await store.update { $0.analysisQueue = initialQueue }
        guard !pending.isEmpty else {
            progress?(ImportProgress(completed: 0, total: 1, currentName: "Восстанавливаю хронологию исходников", analysisStage: .sourceOrdering))
            let sourceMap = SourceTimelineAnalyzer().analyze(assets: current.assets, analyses: current.analyses)
            progress?(ImportProgress(completed: 0, total: 1, currentName: "Группирую активности и события", analysisStage: .eventDiscovery))
            let eventDiscovery = EventIntelligenceEngine().discover(assets: current.assets, analyses: current.analyses, sourceMap: sourceMap)
            try await store.update { project in
                project.sourceMap = eventDiscovery.sourceMap
                project.events = eventDiscovery.events
            }
            progress?(ImportProgress(completed: 1, total: 1, currentName: "Хронология и карта исходников обновлены", analysisStage: .persistence))
            return 0
        }

        var analyzedCount = 0
        var failedCount = 0
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
            let profile = AIAnalysisProfile.resolve(
                mode: current.preferences.effectiveAIPowerMode,
                advanced: current.preferences.effectiveAdvancedAISettings,
                thermalState: ProcessInfo.processInfo.thermalState
            )
            let heat = await scheduler.statusLabel()
            let fallbackSeconds = max(12, (asset.metadata.duration ?? 5) * {
                switch profile.mode { case .fast: return 0.18; case .balanced: return 0.42; case .quality: return 0.9; case .maximum: return 1.8 }
            }())
            let reporter = AnalysisProgressReporter(
                callback: progress,
                eta: eta,
                fileIndex: fileIndex,
                fileCount: pending.count,
                fallbackSecondsPerFile: fallbackSeconds
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
                var result = try await task.value
                activeAnalysisTask = nil
                activeAnalysisAssetID = nil
                result.analysisProfileKey = baseProfile.cacheKey
                result.completedDepth = max(result.completedDepth ?? .quick, profile.targetDepth)
                if result.deepMediaVersion == nil {
                    result.deepMediaVersion = DeepAnalysisCache.version
                    result.deepMediaDiagnostics = DeepMediaDiagnostics(stages: [
                        DeepAnalysisStageReport(stage: .embeddings, ran: false, reason: "Custom analyzer fallback без frame descriptors")
                    ])
                }
                result.telemetry = telemetry
                if let proxyWarning { result.warnings.append(proxyWarning) }
                if thermal == .hot { result.warnings.append("Глубина AI-анализа автоматически снижена из-за температуры Mac.") }
                await metrics.start(.persistence)
                await metrics.finish(.persistence, workUnits: 1)
                result.metrics = await metrics.snapshot()
                await analysisQueue.complete(assetID: asset.id)
                let queueSnapshot = await analysisQueue.snapshot()
                var resultWasCurrent = false
                try await store.update { project in
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
                if resultWasCurrent { analyzedCount += 1 }
                await eta.finishFile()
                await reporter.publish(
                    AnalysisStageUpdate(stage: .persistence, label: "Анализ готов", fraction: 1),
                    fileName: asset.displayName
                )
            } catch is CancellationError {
                activeAnalysisTask = nil
                activeAnalysisAssetID = nil
                await analysisQueue.cancel(assetID: asset.id)
                let queueSnapshot = await analysisQueue.snapshot()
                try? await store.update { $0.analysisQueue = queueSnapshot }
                throw CancellationError()
            } catch {
                activeAnalysisTask = nil
                activeAnalysisAssetID = nil
                failedCount += 1
                await analysisQueue.fail(assetID: asset.id, error: error.localizedDescription)
                let queueSnapshot = await analysisQueue.snapshot()
                try? await store.update { $0.analysisQueue = queueSnapshot }
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
            try await store.update { project in
                project.analyses = refinedAnalyses
                project.sourceMap = eventDiscovery.sourceMap
                project.events = eventDiscovery.events
            }
        }
        let label = failedCount == 0 ? "Анализ готов" : "Анализ завершён, ошибок: \(failedCount)"
        progress?(ImportProgress(completed: pending.count * 100, total: pending.count * 100, currentName: label))
        return analyzedCount
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

    @discardableResult
    public func createFilm(
        prompt: String,
        preset: FilmPreset,
        targetDuration: Double? = nil,
        preferredMusicTrackID: UUID? = nil
    ) async throws -> Timeline {
        let projectSnapshot = await store.snapshot()
        let current = projectSnapshot.manifest
        let analyses = Self.mergingTelemetrySources(into: current.analyses, sources: current.effectiveTelemetrySources)
        let eventDiscovery = EventIntelligenceEngine().discover(assets: current.assets, analyses: analyses)
        let deviceTaste = await personalTasteStore.profile()
        let personalTaste = deviceTaste.totalSignalCount > 0 ? deviceTaste : (current.personalTasteProfile ?? deviceTaste)
        let autonomous = AutonomousDirectorEngine().decide(
            prompt: prompt,
            fallbackPreset: preset,
            requestedDuration: targetDuration,
            assets: current.assets,
            analyses: analyses,
            personalProfile: personalTaste,
            events: eventDiscovery.events
        )
        if preferredMusicTrackID == nil {
            await musicSystem.scheduleOnlineTrack(for: Self.musicIntent(from: autonomous.music))
        }
        var constraints = PromptInterpreter().interpret(prompt: prompt, preset: preset)
        constraints.targetDuration = autonomous.duration.seconds
        constraints.pacing = autonomous.finalStyle.pacing
        constraints.transitionFrequency = autonomous.grammar.transitionDensity
        constraints.allowSlowMotion = autonomous.grammar.slowMotionDensity > 0.025
        let variantSearch = StoryEngine().createPlanVariantSearch(prompt: prompt, preset: preset, constraints: constraints, assets: current.assets, analyses: analyses, events: eventDiscovery.events, eventDiagnostics: eventDiscovery.diagnostics, limit: 10, autonomousDecision: autonomous)
        let storyVariants = variantSearch.variants
        let fallbackPlan = StoryPlan(prompt: prompt, preset: preset, constraints: constraints, chapters: [], autonomousDecision: autonomous)
        let effectiveStories = storyVariants.isEmpty ? [StoryPlanVariant(plan: fallbackPlan, strategy: "fallback", seedScore: 0)] : storyVariants
        var roughTimelines = effectiveStories.map { TimelineComposer().compose(plan: $0.plan, assets: current.assets, analyses: analyses) }
        if let preferredMusicTrackID,
           let preferredTrack = try await musicSystem.tracks().first(where: {
               $0.id == preferredMusicTrackID && FileManager.default.fileExists(atPath: $0.localFileURL.path)
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
        } else {
            // Automatic mode intentionally looks for a fresh soundtrack. An
            // explicit local choice above is preserved and avoids a download.
            for index in roughTimelines.indices where roughTimelines[index].music != nil {
                roughTimelines[index].music?.trackID = nil
                roughTimelines[index].music?.trackTitle = nil
                roughTimelines[index].music?.preferDifferentTrack = true
            }
        }
        let tracks = try await tracksForResolving(roughTimelines.first?.music)
        let directedTimelines = await Self.directingVariants(stories: effectiveStories, roughTimelines: roughTimelines, tracks: tracks, assets: current.assets, analyses: analyses)
        let tasteContext = TasteContextResolver().resolve(projectStyle: autonomous.projectStyle, assets: current.assets, analyses: analyses)
        let winner = MontageVariantSelector().select(stories: effectiveStories, timelines: directedTimelines, assets: current.assets, analyses: analyses, searchDiagnostics: variantSearch.diagnostics, personalTasteProfile: personalTaste, tasteContext: tasteContext)
        let plan = winner?.story.plan ?? effectiveStories[0].plan
        var timeline = winner?.timeline ?? directedTimelines[0]
        timeline = await Self.finalizePerceptualRenderReview(
            timeline: timeline,
            plan: plan,
            assets: current.assets,
            analyses: analyses,
            tracks: tracks,
            telemetry: Self.telemetryLookup(in: current),
            derivedMediaCacheURL: CachePaths(root: await store.cacheURL).previewDerivedMediaDirectory
        )
        try await store.update(ifRevision: projectSnapshot.revision) { project in
            if let previous = project.timelines.last {
                Self.appendCheckpoint(timeline: previous, reason: "Перед полной режиссёрской пересборкой", to: &project)
            }
            timeline.versionName = Self.nextAIEditName(in: project)
            project.personalTasteProfile = personalTaste
            project.sourceMap = eventDiscovery.sourceMap
            project.events = eventDiscovery.events
            project.storyPlans.append(plan)
            project.timelines.append(timeline)
            Self.recordMusicCredit(from: timeline, tracks: tracks, in: &project)
        }
        return timeline
    }

    @discardableResult
    public func regenerate(
        feedback: String,
        selectedCandidateID: UUID? = nil,
        preset: FilmPreset? = nil,
        targetDuration: Double? = nil,
        preferredMusicTrackID: UUID? = nil
    ) async throws -> Timeline {
        let projectSnapshot = await store.snapshot()
        let current = projectSnapshot.manifest
        guard let oldPlan = current.storyPlans.last else {
            return try await createFilm(
                prompt: feedback,
                preset: preset ?? .story,
                targetDuration: targetDuration,
                preferredMusicTrackID: preferredMusicTrackID
            )
        }
        var candidates = current.analyses.flatMap(\.candidates)
        var updatedSeed = FeedbackEngine().apply(feedback: feedback, to: oldPlan, candidates: &candidates, selectedCandidateID: selectedCandidateID)
        if let preset, preset != updatedSeed.preset {
            updatedSeed.preset = preset
            updatedSeed.constraints = PromptInterpreter().interpret(
                prompt: feedback,
                preset: preset,
                base: updatedSeed.constraints
            )
        }
        if let targetDuration { updatedSeed.constraints.targetDuration = max(5, targetDuration) }
        var analyses = Self.mergingTelemetrySources(into: current.analyses, sources: current.effectiveTelemetrySources)
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        for index in analyses.indices { analyses[index].candidates = analyses[index].candidates.compactMap { byID[$0.id] } }
        let eventDiscovery = EventIntelligenceEngine().discover(assets: current.assets, analyses: analyses)
        let deviceTaste = await personalTasteStore.profile()
        let personalTaste = deviceTaste.totalSignalCount > 0 ? deviceTaste : (current.personalTasteProfile ?? deviceTaste)
        let autonomous = AutonomousDirectorEngine().decide(
            prompt: updatedSeed.prompt,
            fallbackPreset: updatedSeed.preset,
            requestedDuration: targetDuration,
            assets: current.assets,
            analyses: analyses,
            personalProfile: personalTaste,
            events: eventDiscovery.events
        )
        if preferredMusicTrackID == nil {
            await musicSystem.scheduleOnlineTrack(for: Self.musicIntent(from: autonomous.music))
        }
        updatedSeed.constraints.targetDuration = autonomous.duration.seconds
        updatedSeed.constraints.pacing = autonomous.finalStyle.pacing
        updatedSeed.constraints.transitionFrequency = autonomous.grammar.transitionDensity
        updatedSeed.constraints.allowSlowMotion = autonomous.grammar.slowMotionDensity > 0.025
        let variantSearch = StoryEngine().createPlanVariantSearch(prompt: updatedSeed.prompt, preset: updatedSeed.preset, constraints: updatedSeed.constraints, assets: current.assets, analyses: analyses, events: eventDiscovery.events, eventDiagnostics: eventDiscovery.diagnostics, limit: 10, autonomousDecision: autonomous)
        let storyVariants = variantSearch.variants
        let fallbackPlan = StoryPlan(prompt: updatedSeed.prompt, preset: updatedSeed.preset, constraints: updatedSeed.constraints, chapters: [], autonomousDecision: autonomous)
        let effectiveStories = storyVariants.isEmpty ? [StoryPlanVariant(plan: fallbackPlan, strategy: "fallback", seedScore: 0)] : storyVariants
        var roughTimelines = effectiveStories.map { TimelineComposer().compose(plan: $0.plan, assets: current.assets, analyses: analyses) }
        if let previous = current.timelines.last {
            for index in roughTimelines.indices {
                roughTimelines[index] = Self.carryEditorAdjustments(from: previous, to: roughTimelines[index])
            }
        }
        if let preferredMusicTrackID,
           let preferredTrack = try await musicSystem.tracks().first(where: {
               $0.id == preferredMusicTrackID && FileManager.default.fileExists(atPath: $0.localFileURL.path)
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
        }
        let tracks = try await tracksForResolving(roughTimelines.first?.music)
        let directedTimelines = await Self.directingVariants(stories: effectiveStories, roughTimelines: roughTimelines, tracks: tracks, assets: current.assets, analyses: analyses)
        let tasteContext = TasteContextResolver().resolve(projectStyle: autonomous.projectStyle, assets: current.assets, analyses: analyses)
        let winner = MontageVariantSelector().select(stories: effectiveStories, timelines: directedTimelines, assets: current.assets, analyses: analyses, searchDiagnostics: variantSearch.diagnostics, personalTasteProfile: personalTaste, tasteContext: tasteContext)
        let plan = winner?.story.plan ?? effectiveStories[0].plan
        var timeline = winner?.timeline ?? directedTimelines[0]
        timeline = await Self.finalizePerceptualRenderReview(
            timeline: timeline,
            plan: plan,
            assets: current.assets,
            analyses: analyses,
            tracks: tracks,
            telemetry: Self.telemetryLookup(in: current),
            derivedMediaCacheURL: CachePaths(root: await store.cacheURL).previewDerivedMediaDirectory
        )
        try await store.update(ifRevision: projectSnapshot.revision) { project in
            if let previous = project.timelines.last {
                Self.appendCheckpoint(timeline: previous, reason: "Перед AI re-edit", to: &project)
            }
            timeline.versionName = Self.nextAIEditName(in: project)
            project.analyses = analyses
            project.sourceMap = eventDiscovery.sourceMap
            project.events = eventDiscovery.events
            project.personalTasteProfile = personalTaste
            project.storyPlans.append(plan)
            project.timelines.append(timeline)
            Self.recordMusicCredit(from: timeline, tracks: tracks, in: &project)
        }
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
            let url = paths.timelineThumbnail(for: item, asset: asset)
            do {
                let time = item.sourceStart + item.sourceDuration * 0.5
                result[item.id] = try await thumbnailer.generate(for: asset, destination: url, videoTime: time)
            } catch {
                let fallback = paths.thumbnail(for: asset)
                if FileManager.default.fileExists(atPath: fallback.path) { result[item.id] = fallback }
            }
        }
        return result
    }

    public func makePlayback(
        timeline timelineOverride: Timeline? = nil,
        interactiveLongEdge: Int? = nil,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> TimelinePlayback {
        try await migrateLegacyTimelineAudioSettings()
        let current = await store.manifest
        guard var timeline = timelineOverride ?? current.timelines.last else { throw FCPXMLExportError.invalidTimeline("Нет созданного фильма") }
        if let interactiveLongEdge, interactiveLongEdge > 0, max(timeline.width, timeline.height) > interactiveLongEdge {
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
        let paths = CachePaths(root: await store.cacheURL)
        let proxyGenerator = ProxyGenerator()
        var playbackSources: [UUID: URL] = [:]
        var sourceWarnings: [String] = []
        for (index, asset) in largeVideoAssets.enumerated() {
            try Task.checkCancellation()
            do {
                let proxy = try await proxyGenerator.generate(for: asset, destination: paths.proxy(for: asset)) { fraction in
                    let percent = Int((fraction * 100).rounded())
                    progress?(ImportProgress(
                        completed: index,
                        total: max(1, largeVideoAssets.count),
                        currentName: "Оптимизирую просмотр: \(asset.displayName) · \(percent)%"
                    ))
                }
                playbackSources[asset.id] = proxy
            } catch {
                sourceWarnings.append("\(asset.displayName): облегчённая копия недоступна; использую оригинал (\(error.localizedDescription))")
            }
        }
        return try await PlaybackEngine().build(
            timeline: timeline,
            assets: current.assets,
            musicTracks: musicTracks,
            telemetry: telemetry,
            preferredVideoSources: playbackSources,
            sourceWarnings: sourceWarnings,
            derivedMediaCacheURL: paths.previewDerivedMediaDirectory,
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

    public func render(to url: URL, quality: RenderQuality, frameRate: Double? = nil, progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> RenderReport {
        try await migrateLegacyTimelineAudioSettings()
        let current = await store.manifest
        guard var timeline = current.timelines.last else { throw FCPXMLExportError.invalidTimeline("Нет созданного фильма") }
        if let frameRate { timeline.frameRate = min(max(1, frameRate), 240) }
        let telemetry = Self.telemetryLookup(in: current)
        return try await RenderEngine().render(timeline: timeline, assets: current.assets, musicTracks: try await musicSystem.tracks(), telemetry: telemetry, quality: quality, destination: url, progress: progress)
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
            item.sourceStart = min(max(0, item.sourceStart), max(0, assetDuration - frame))
            let available = max(frame, assetDuration - item.sourceStart)
            item.sourceDuration = min(max(frame, item.sourceDuration), available)
            let durationFactor = item.speedRamp?.outputDuration(sourceDuration: 1) ?? (1 / max(0.1, item.speed))
            item.timelineDuration = max(frame, item.sourceDuration * durationFactor)
            timeline.items[index] = item
        }
        timeline.items = retimed(timeline.items)
        return timeline
    }

    private struct LocalizedTimelineSlice {
        var timeline: Timeline
        var itemIDs: [UUID]
        var audioClipIDs: [UUID]
        var telemetryItemIDs: [UUID]
        var effectItemIDs: [UUID]
        var titleItemIDs: [UUID]
    }

    /// Cuts primary-storyline clips on both brush boundaries and returns only
    /// the IDs fully contained by the brushed interval.
    private static func sliced(_ source: Timeline, for requestedRange: ClosedRange<Double>) -> LocalizedTimelineSlice {
        var timeline = source
        let originalItems = retimed(source.items)
        let lower = min(max(0, requestedRange.lowerBound), source.duration)
        let upperCandidate = min(max(lower, requestedRange.upperBound), source.duration)
        let upper = upperCandidate > lower ? upperCandidate : min(source.duration, lower + 1 / max(1, source.frameRate))
        var items: [TimelineItem] = []
        var selectedIDs: [UUID] = []
        let epsilon = 0.0001

        for original in originalItems {
            let itemStart = original.timelineStart
            let itemEnd = itemStart + original.timelineDuration
            guard original.overlay == nil,
                  original.timelineDuration > epsilon,
                  itemEnd > lower + epsilon,
                  itemStart < upper - epsilon else {
                items.append(original)
                if original.overlay != nil, itemEnd > lower + epsilon, itemStart < upper - epsilon {
                    selectedIDs.append(original.id)
                }
                continue
            }

            var cuts = [itemStart, itemEnd]
            if lower > itemStart + epsilon, lower < itemEnd - epsilon { cuts.append(lower) }
            if upper > itemStart + epsilon, upper < itemEnd - epsilon { cuts.append(upper) }
            cuts.sort()

            for segmentIndex in 0..<(cuts.count - 1) {
                let segmentStart = cuts[segmentIndex]
                let segmentEnd = cuts[segmentIndex + 1]
                let timelineFractionStart = (segmentStart - itemStart) / original.timelineDuration
                let timelineFractionDuration = (segmentEnd - segmentStart) / original.timelineDuration
                var segment = original
                if segmentIndex > 0 {
                    segment.id = UUID()
                    segment.transition = nil
                }
                segment.sourceStart = original.sourceStart + original.sourceDuration * timelineFractionStart
                segment.sourceDuration = max(epsilon, original.sourceDuration * timelineFractionDuration)
                segment.timelineStart = segmentStart
                segment.timelineDuration = max(epsilon, segmentEnd - segmentStart)
                items.append(segment)
                if segmentStart >= lower - epsilon, segmentEnd <= upper + epsilon {
                    selectedIDs.append(segment.id)
                }
            }
        }

        timeline.items = retimed(items)

        func segmentBounds(start: Double, end: Double) -> [(start: Double, end: Double, selected: Bool)] {
            guard end > lower + epsilon, start < upper - epsilon else {
                return [(start, end, false)]
            }
            var cuts = [start, end]
            if lower > start + epsilon, lower < end - epsilon { cuts.append(lower) }
            if upper > start + epsilon, upper < end - epsilon { cuts.append(upper) }
            cuts.sort()
            return zip(cuts, cuts.dropFirst()).map { left, right in
                (left, right, left >= lower - epsilon && right <= upper + epsilon)
            }
        }

        var audioIDs: [UUID] = []
        timeline.audioClips = source.effectiveAudioClips.flatMap { original in
            segmentBounds(start: original.timelineStart, end: original.timelineEnd).enumerated().map { index, bounds in
                var segment = original
                if index > 0 { segment.id = UUID() }
                let offset = bounds.start - original.timelineStart
                segment.timelineStart = bounds.start
                segment.timelineDuration = max(epsilon, bounds.end - bounds.start)
                segment.sourceStart = original.sourceStart + offset
                segment.sourceDuration = segment.timelineDuration
                if bounds.selected { audioIDs.append(segment.id) }
                return segment
            }
        }

        var telemetryIDs: [UUID] = []
        timeline.telemetryItems = source.effectiveTelemetryItems.flatMap { original in
            segmentBounds(start: original.timelineStart, end: original.timelineEnd).enumerated().map { index, bounds in
                var segment = original
                if index > 0 { segment.id = UUID() }
                let offset = bounds.start - original.timelineStart
                segment.timelineStart = bounds.start
                segment.timelineDuration = max(epsilon, bounds.end - bounds.start)
                segment.sourceStart = original.sourceStart + offset
                if bounds.selected { telemetryIDs.append(segment.id) }
                return segment
            }
        }

        var effectIDs: [UUID] = []
        timeline.effects = source.effectiveEffects.flatMap { original in
            segmentBounds(start: original.startTime, end: original.endTime).enumerated().map { index, bounds in
                var segment = original
                if index > 0 { segment.id = UUID() }
                let offset = bounds.start - original.startTime
                segment.startTime = bounds.start
                segment.duration = max(epsilon, bounds.end - bounds.start)
                segment.keyframes = original.keyframes.compactMap { keyframe in
                    let absolute = original.startTime + keyframe.time
                    guard absolute >= bounds.start - epsilon, absolute <= bounds.end + epsilon else { return nil }
                    var copy = keyframe
                    copy.time = max(0, absolute - bounds.start)
                    return copy
                }
                if offset > 0, segment.keyframes.isEmpty { segment.keyframes = [] }
                if bounds.selected { effectIDs.append(segment.id) }
                return segment
            }
        }

        var titleIDs: [UUID] = []
        timeline.titleItems = source.effectiveTitleItems.flatMap { original in
            segmentBounds(start: original.startTime, end: original.endTime).enumerated().map { index, bounds in
                var segment = original
                if index > 0 { segment.id = UUID() }
                segment.startTime = bounds.start
                segment.duration = max(epsilon, bounds.end - bounds.start)
                segment.words = original.words.compactMap { word in
                    let absoluteStart = original.startTime + word.start
                    let absoluteEnd = original.startTime + word.end
                    guard absoluteEnd > bounds.start, absoluteStart < bounds.end else { return nil }
                    var copy = word
                    copy.start = max(0, absoluteStart - bounds.start)
                    copy.end = min(segment.duration, absoluteEnd - bounds.start)
                    return copy
                }
                if bounds.selected { titleIDs.append(segment.id) }
                return segment
            }
        }

        return LocalizedTimelineSlice(
            timeline: timeline,
            itemIDs: selectedIDs,
            audioClipIDs: audioIDs,
            telemetryItemIDs: telemetryIDs,
            effectItemIDs: effectIDs,
            titleItemIDs: titleIDs
        )
    }

    private func tracksForResolving(_ directive: MusicDirective?) async throws -> [LocalMusicTrack] {
        lastMusicResolutionError = nil
        let tracks = try await musicSystem.tracks()
        guard let directive else { return tracks }
        let current = await store.manifest
        let previousTrackID = directive.preferDifferentTrack == true
            ? current.timelines.last?.music?.trackID
            : nil
        let resolution = await musicSystem.resolve(
            MusicIntent(directive: directive),
            requestedTrackID: directive.trackID,
            excluding: previousTrackID,
            preferCachedOnline: directive.preferDifferentTrack == true
        )
        if !resolution.failures.isEmpty {
            lastMusicResolutionError = resolution.failures
                .map { "\($0.provider): \($0.reason)" }
                .joined(separator: "; ")
        }
        if directive.preferDifferentTrack == true, let track = resolution.track {
            return [track]
        }
        return resolution.catalog
    }

    private static func musicIntent(from autonomous: AutonomousMusicIntent) -> MusicIntent {
        MusicIntent(directive: MusicDirective(
            style: autonomous.style,
            bpm: autonomous.desiredBPM,
            preferDifferentTrack: true,
            autonomousIntent: autonomous
        ))
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

    private static func resolvingMusic(in timeline: Timeline, tracks: [LocalMusicTrack], structures: [UUID: MusicStructure] = [:], excluding: UUID? = nil) async -> Timeline {
        var result = timeline
        guard var directive = result.music else { return result }
        let track: LocalMusicTrack?
        if let intent = directive.autonomousIntent {
            let available = tracks.filter {
                $0.id != excluding && FileManager.default.fileExists(atPath: $0.localFileURL.path)
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
        return MusicBeatSynchronizer().synchronize(result, to: track, analyzedStructure: structure, structuralOnly: true)
    }

    private static func directingVariants(
        stories: [StoryPlanVariant],
        roughTimelines: [Timeline],
        tracks: [LocalMusicTrack],
        assets: [MediaAsset],
        analyses: [AnalysisResult]
    ) async -> [Timeline] {
        let structures = await withTaskGroup(of: (UUID, MusicStructure).self, returning: [UUID: MusicStructure].self) { group in
            for track in tracks {
                group.addTask { (track.id, await MusicStructureCache.shared.structure(for: track)) }
            }
            var values: [UUID: MusicStructure] = [:]
            for await (id, structure) in group { values[id] = structure }
            return values
        }
        return await withTaskGroup(of: (Int, Timeline).self, returning: [Timeline].self) { group in
            for index in stories.indices where roughTimelines.indices.contains(index) {
                let story = stories[index]
                let rough = roughTimelines[index]
                group.addTask {
                    var timeline = await Self.resolvingMusic(in: rough, tracks: tracks, structures: structures)
                    timeline = AIDirectorEngine().direct(plan: story.plan, initialTimeline: timeline, assets: assets, analyses: analyses)
                    timeline = await Self.resolvingMusic(in: timeline, tracks: tracks, structures: structures)
                    return (index, timeline)
                }
            }
            var ordered = Array<Timeline?>(repeating: nil, count: stories.count)
            for await (index, timeline) in group { ordered[index] = timeline }
            return ordered.compactMap { $0 }
        }
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
            let evidence = PerceptualRenderInspector().inspect(playback: playback, timeline: timeline)
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
                let repairedEvidence = PerceptualRenderInspector().inspect(playback: repairedPlayback, timeline: timeline)
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
    private static func carryEditorAdjustments(from previous: Timeline, to generated: Timeline) -> Timeline {
        var result = generated
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
            result.items[index].telemetryOverlay = old.telemetryOverlay
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
        return result
    }

    private func migrateLegacyTimelineAudioSettings() async throws {
        let current = await store.manifest
        guard current.timelines.contains(where: { $0.originalAudioVolume == nil }) else { return }
        try await store.update { project in
            let plans = Dictionary(uniqueKeysWithValues: project.storyPlans.map { ($0.id, $0) })
            for index in project.timelines.indices where project.timelines[index].originalAudioVolume == nil {
                let prompt = plans[project.timelines[index].storyPlanID]?.prompt ?? ""
                project.timelines[index].originalAudioVolume = OriginalAudioPromptInterpreter().volume(prompt: prompt) ?? 1
            }
        }
    }

    private static func recordMusicCredit(
        from timeline: Timeline,
        tracks: [LocalMusicTrack],
        in project: inout ProjectManifest
    ) {
        guard let trackID = timeline.music?.trackID,
              let track = tracks.first(where: { $0.id == trackID }) else { return }
        let credit = MusicCredit(track: track)
        var credits = project.musicCredits ?? []
        credits.removeAll { $0.id == credit.id }
        credits.append(credit)
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
    /// Global music/story commands are deliberately rejected here: a brushed
    /// edit must never leak outside the highlighted interval.
    var canApplyInsideTimelineRange: Bool {
        switch self {
        case .addTitle, .setOriginalAudioVolume, .setMusic, .setMusicVolume, .setAudioDucking, .setOverlay, .move:
            return false
        default:
            return true
        }
    }
}
