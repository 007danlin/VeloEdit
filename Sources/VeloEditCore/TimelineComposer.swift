import Foundation

public struct TimelineComposer: Sendable {
    public init() {}

    public func compose(plan: StoryPlan, assets: [MediaAsset], analyses: [AnalysisResult]) -> Timeline {
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let analysesByAssetID = Dictionary(uniqueKeysWithValues: analyses.map { ($0.assetID, $0) })
        let candidates = Dictionary(uniqueKeysWithValues: analyses.flatMap(\.directorCandidates).map { ($0.id, $0) })
        let telemetryByAsset = Dictionary(uniqueKeysWithValues: analyses.compactMap { result in
            result.telemetry.map { (result.assetID, $0) }
        })
        let prompt = plan.prompt.lowercased()
        let directorBrief = plan.directorBrief
        let titlePolicy = directorBrief?.titlePolicy
        let grammar = plan.autonomousDecision?.grammar
        let explicitlyAsksTelemetry = TelemetryOverlayRequestPolicy.requestsOverlay(in: prompt)
        let asksPhotoLayout = ["фотоколлаж", "коллаж", "несколько фото", "фото рядом", "split screen фото"].contains(where: prompt.contains)
        let explicitlyDisablesTransitions = ["без переход", "убери переход", "никаких переход", "no transition"].contains(where: prompt.contains)
        let explicitlyRequestsTransitions = !explicitlyDisablesTransitions
            && ["переход", "transition", "dissolve", "раствор", "через чёрн", "вспыш"].contains(where: prompt.contains)
        var cursor = 0.0
        var tagDurations: [String: Double] = [:]
        var eventDurations: [UUID: Double] = [:]
        var items: [TimelineItem] = []
        var telemetryItems: [TimelineTelemetryItem] = []
        var titleItems: [TitleTimelineItem] = []
        var usedTitleTexts: [String] = []
        var titleSceneScopeByID: [UUID: UUID] = [:]
        var titleEventScopeByID: [UUID: UUID] = [:]
        var directTitleContainment: [UUID: ClosedRange<Double>] = [:]
        var insertedProjectTitle = false
        var lastTelemetryEnd = -Double.greatestFiniteMagnitude
        var telemetryAccentCount = 0
        let maximumTelemetryAccents = max(1, Int(ceil(plan.constraints.targetDuration / 18)))
        let explicitRanges = exactCandidateRanges(plan: plan, candidates: candidates, assets: assetsByID)
        // Native transition overlaps shorten the rendered AVComposition clock.
        // Exact-duration films therefore use clean cuts automatically; this
        // keeps the exported file, not only the magnetic Timeline, on target.
        let preservesExactRenderedDuration = !explicitRanges.isEmpty

        func smartTitle(
            purpose: SmartTitlePurpose,
            requestedText: String?,
            chapter: StoryChapter,
            sequenceIndex: Int?,
            preferredTemplateID: String? = nil
        ) -> SmartTitleDecision? {
            let chapterCandidates = chapter.candidateIDs.compactMap { candidates[$0] }
            let chapterAssets = chapterCandidates.compactMap { assetsByID[$0.assetID] }
            let tags = chapterCandidates.reduce(into: Set<String>()) { $0.formUnion($1.tags) }
            let summaries = chapterCandidates.compactMap { $0.insights?.sceneSummary }
            let semanticLocations = chapterAssets.compactMap { asset in
                analysesByAssetID[asset.id]?.scenes?.compactMap(\.location).first
            }
            let avoidRegions = chapterCandidates.compactMap { candidate -> NormalizedRegion? in
                candidate.insights?.subjectTracking?.mainSubject?.observations
                    .max(by: { $0.confidence * $0.region.area < $1.confidence * $1.region.area })?.region
            }
            let eventEntry = chapter.eventID.flatMap { id in plan.eventStory?.entries.first { $0.eventID == id } }
            return SmartTitleEngine().decide(SmartTitleContext(
                purpose: purpose,
                requestedText: requestedText,
                tags: tags,
                summaries: summaries,
                locationName: semanticLocations.first,
                locationConfidence: semanticLocations.isEmpty ? 0 : 0.64,
                captureDate: eventEntry?.startDate ?? chapterAssets.compactMap { $0.metadata.effectiveCaptureDate }.min(),
                dateAddsContext: (plan.eventStory?.entries.count ?? 0) > 1,
                sequenceIndex: sequenceIndex,
                sequenceCount: plan.eventStory?.entries.count,
                usedTitles: usedTitleTexts,
                avoidRegions: avoidRegions,
                preferredTemplateID: preferredTemplateID
            ))
        }

        @discardableResult
        func appendTitle(
            _ decision: SmartTitleDecision,
            at startTime: Double,
            reason: String,
            sceneID: UUID? = nil,
            eventID: UUID? = nil
        ) -> UUID? {
            guard let template = TitleTemplateRegistry.template(id: decision.templateID) else { return nil }
            let identity = decision.primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !usedTitleTexts.contains(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == identity
            }) else { return nil }
            let item = TitleTimelineItem(
                kind: template.kind,
                templateID: template.id,
                text: decision.primaryText,
                additionalText: decision.secondaryText,
                startTime: startTime,
                duration: decision.duration,
                style: template.defaultStyle,
                explanation: [reason] + decision.explanation
            )
            titleItems.append(item)
            usedTitleTexts.append(decision.primaryText)
            if let sceneID {
                titleSceneScopeByID[item.id] = sceneID
            } else if let eventID {
                titleEventScopeByID[item.id] = eventID
            }
            return item.id
        }

        for (chapterIndex, chapter) in plan.chapters.enumerated() {
            let chapterStart = cursor
            var chapterGeneratedTitleIDs: [UUID] = []
            var directlyChapterScopedTitleIDs: [UUID] = []
            var chapterTitleStartOffset = 0.0
            if titlePolicy != DirectorTitlePolicy.none,
               !insertedProjectTitle,
               chapter.isColdOpen != true,
               let projectTitle = plan.eventStory?.projectTitle,
               !projectTitle.isEmpty {
                if let decision = smartTitle(
                    purpose: .filmOpening,
                    requestedText: projectTitle,
                    chapter: chapter,
                    sequenceIndex: nil,
                    preferredTemplateID: plan.preset == .cinematic ? "title.cinematic.v1" : nil
                ) {
                    if let id = appendTitle(decision, at: cursor, reason: "Название фильма создано из event hierarchy") {
                        chapterGeneratedTitleIDs.append(id)
                    }
                    chapterTitleStartOffset = decision.duration + 0.15
                }
                insertedProjectTitle = true
            }
            if titlePolicy != DirectorTitlePolicy.none,
               let chapterTitle = chapter.chapterCardTitle,
               plan.eventStory?.chapterCardsEnabled == true,
               !chapterTitle.isEmpty {
                let eventIndex = chapter.eventID.flatMap { eventID in
                    plan.eventStory?.entries.firstIndex { $0.eventID == eventID }.map { $0 + 1 }
                }
                if let decision = smartTitle(
                    purpose: .chapter,
                    requestedText: chapterTitle,
                    chapter: chapter,
                    sequenceIndex: eventIndex,
                    preferredTemplateID: "title.chapter.v1"
                ) {
                    if let id = appendTitle(
                        decision,
                        at: cursor + chapterTitleStartOffset,
                        reason: "Автоматическая глава события использует существующий шаблон",
                        sceneID: chapter.eventSceneID,
                        eventID: chapter.eventID
                    ) {
                        chapterGeneratedTitleIDs.append(id)
                    }
                }
            } else if titlePolicy != DirectorTitlePolicy.none,
               plan.eventStory == nil,
               plan.constraints.targetDuration >= 10 * 60,
               plan.constraints.targetClipCount == nil {
                if let decision = smartTitle(
                    purpose: .chapter,
                    requestedText: chapter.title,
                    chapter: chapter,
                    sequenceIndex: chapterIndex + 1,
                    preferredTemplateID: "title.chapter.v1"
                ) {
                    if let id = appendTitle(decision, at: cursor, reason: chapter.purpose ?? "Автоматическая глава длинного фильма") {
                        chapterGeneratedTitleIDs.append(id)
                        directlyChapterScopedTitleIDs.append(id)
                    }
                }
            }
            for id in chapter.candidateIDs {
                guard let candidate = candidates[id], let asset = assetsByID[candidate.assetID], !candidate.excluded else { continue }
                let preferred = explicitRanges[id]?.sourceDuration
                    ?? preferredDuration(candidate: candidate, role: chapter.role, pacing: plan.constraints.pacing, grammar: grammar)
                let remaining = plan.constraints.targetDuration - cursor
                guard remaining > 0.5 else { break }
                let eventAllowance: Double = {
                    // exactCandidateRanges has already reconciled event shares
                    // against real non-overlapping source capacity. Reapplying
                    // the original quality cap here would recreate the deficit.
                    if explicitRanges[id] != nil { return remaining }
                    guard let eventID = chapter.eventID,
                          let allocation = plan.eventStory?.entries.first(where: { $0.eventID == eventID })?.allocatedDuration else {
                        return remaining
                    }
                    return max(0, allocation - eventDurations[eventID, default: 0])
                }()
                let tagAllowance = candidate.tags.reduce(remaining) { allowance, tag in
                    guard let maximumShare = plan.constraints.maximumTagShares[tag] else { return allowance }
                    let maximumDuration = plan.constraints.targetDuration * maximumShare
                    return min(allowance, max(0, maximumDuration - tagDurations[tag, default: 0]))
                }
                let duration = min(preferred, remaining, tagAllowance, eventAllowance)
                guard duration > 0.5 else { continue }
                let sourceRange = explicitRanges[id].map { range in
                    ExactCandidateRange(sourceStart: range.sourceStart, sourceDuration: min(range.sourceDuration, duration))
                } ?? {
                    let trimmed = MomentPhaseTrimmer().range(for: candidate, desiredDuration: duration)
                    return ExactCandidateRange(sourceStart: trimmed.sourceStart, sourceDuration: trimmed.sourceDuration)
                }()
                let previousPrimary = items.last { $0.kind != .title && $0.overlay == nil }
                let previousCandidate = previousPrimary?.candidateID.flatMap { candidates[$0] }
                let boundaryDecision = motivatedBoundary(
                    previous: previousPrimary,
                    previousCandidate: previousCandidate,
                    incomingCandidate: candidate,
                    incomingAsset: asset,
                    chapter: chapter,
                    plan: plan,
                    transitionsDisabled: explicitlyDisablesTransitions || preservesExactRenderedDuration,
                    explicitlyRequestsTransitions: explicitlyRequestsTransitions,
                    boundaryIndex: items.filter { $0.kind != .title && $0.overlay == nil }.count
                )
                let transition = boundaryDecision?.transitionStyle?.rawValue
                let photoEffects: [ClipEffect] = [.kenBurns, .panLeft, .zoomOut, .panRight]
                let effect = asset.kind == .photo && (grammar?.photoMotionIntensity ?? 0.5) >= 0.14
                    ? photoEffects[items.count % photoEffects.count].rawValue
                    : nil
                var item = TimelineItem(candidateID: candidate.id, assetID: asset.id, kind: asset.kind == .photo ? .photo : .video, sourceStart: sourceRange.sourceStart, sourceDuration: sourceRange.sourceDuration, timelineStart: cursor, timelineDuration: sourceRange.sourceDuration, transition: transition, effect: effect, telemetryOverlay: nil, storyRole: chapter.role, editorialPurpose: chapter.purpose, incomingEditDecision: boundaryDecision, eventID: chapter.eventID, eventSceneID: chapter.eventSceneID, locked: candidate.locked, explanation: candidate.explanation + [chapter.purpose, boundaryDecision?.motivation].compactMap { $0 })
                let mainSubject = candidate.insights?.subjectTracking?.mainSubject
                let avoidRegions = mainSubject?.observations.map(\.region) ?? []
                let aspectRatio: Double = {
                    guard let width = asset.metadata.width, let height = asset.metadata.height, width > 0, height > 0 else {
                        return 16.0 / 9.0
                    }
                    return Double(width) / Double(height)
                }()
                let telemetryDecision: SmartTelemetryDecision? = {
                    // Sensor data is editorial source material, not permission
                    // to put a HUD over the picture. Keep it invisible until
                    // the user explicitly asks for telemetry; manual Timeline
                    // widgets continue to use the same renderer.
                    guard explicitlyAsksTelemetry,
                          telemetryAccentCount < maximumTelemetryAccents,
                          cursor - lastTelemetryEnd >= 5.5,
                          let summary = telemetryByAsset[asset.id], summary.hasTelemetry else { return nil }
                    return SmartTelemetryEngine().decide(SmartTelemetryContext(
                        telemetry: summary,
                        clip: item,
                        tags: candidate.tags,
                        role: chapter.role,
                        avoidRegions: avoidRegions,
                        subjectMovementX: mainSubject?.movementX ?? 0,
                        aspectRatio: aspectRatio,
                        sceneComplexity: 0.62 * (1 - (candidate.insights?.composition ?? 0.5)) + 0.38 * (candidate.insights?.dynamics ?? candidate.scores.action),
                        explicitRequest: explicitlyAsksTelemetry ? plan.prompt : nil
                    ))
                }()
                if let telemetryDecision {
                    item.telemetryOverlay = telemetryDecision.settings
                }
                items.append(item)
                if let telemetryDecision {
                    telemetryItems.append(TimelineTelemetryItem(
                        targetClipID: item.id,
                        linkedAssetID: asset.id,
                        sourceStart: telemetryDecision.sourceMoment,
                        timelineStart: telemetryDecision.timelineStart,
                        timelineDuration: telemetryDecision.duration,
                        settings: telemetryDecision.settings,
                        explanation: telemetryDecision.explanation
                    ))
                    telemetryAccentCount += 1
                    lastTelemetryEnd = telemetryDecision.timelineStart + telemetryDecision.duration
                }
                cursor += sourceRange.sourceDuration
                if let eventID = chapter.eventID { eventDurations[eventID, default: 0] += sourceRange.sourceDuration }
                candidate.tags.forEach { tagDurations[$0, default: 0] += sourceRange.sourceDuration }
            }
            // Auto titles belong to this story block. A collision must never
            // push a label into the next activity; shorten it to the actual
            // block and omit unreadable flashes instead.
            let minimumReadableTitleDuration = 1.25
            titleItems.removeAll { item in
                guard chapterGeneratedTitleIDs.contains(item.id) else { return false }
                let available = cursor - item.startTime
                return available < minimumReadableTitleDuration
            }
            for index in titleItems.indices where chapterGeneratedTitleIDs.contains(titleItems[index].id) {
                titleItems[index].duration = min(titleItems[index].duration, cursor - titleItems[index].startTime)
            }
            for titleID in directlyChapterScopedTitleIDs {
                directTitleContainment[titleID] = chapterStart...cursor
            }
        }
        if asksPhotoLayout {
            for index in items.indices.dropFirst() where items[index].kind == .photo && items[index - 1].kind == .photo && items[index - 1].overlay == nil {
                items[index].overlay = OverlaySettings(style: .splitScreen, baseItemID: items[index - 1].id, scale: 0.5)
            }
            items = TimelineTiming.retimed(items)
        }
        let originalAudioVolume = directorBrief?.sourceAudioPolicy.volume
            ?? OriginalAudioPromptInterpreter().volume(prompt: plan.prompt)
            ?? 1
        let audioClips = originalAudioVolume > 0.0001
            ? makeSoundBridges(
                items: &items,
                candidates: candidates,
                assets: assetsByID,
                originalAudioVolume: originalAudioVolume
            )
            : []
        // The visual analyzer's tags are part of the creative brief. This lets
        // an otherwise generic request select an energetic soundtrack for a
        // cycling/sports film while an explicitly requested mood still wins.
        let analyzedContent = tagDurations
            .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value }
            .prefix(12)
            .map { $0.key.lowercased() }
            .joined(separator: " ")
        let musicPrompt = analyzedContent.isEmpty ? plan.prompt : "\(plan.prompt)\nРаспознано в кадре: \(analyzedContent)"
        let explicitlyNoMusic = prompt.contains("без музы") || prompt.contains("убери музыку") || prompt.contains("no music")
        let explicitMusic = MusicPromptInterpreter().interpret(prompt: plan.prompt, preset: plan.preset)
        let autonomousMusic = plan.autonomousDecision.map { decision in
            MusicDirective(
                style: decision.music.style,
                bpm: decision.music.desiredBPM,
                volume: 0.12 + decision.finalStyle.musicIntensity * 0.13,
                autonomousIntent: decision.music
            )
        }
        let contentAwareMusic = autonomousMusic ?? MusicPromptInterpreter().interpret(
            prompt: musicPrompt,
            preset: plan.preset,
            automaticDefault: true
        )
        let music: MusicDirective? = {
            guard let directorBrief else {
                return explicitlyNoMusic ? nil : explicitMusic ?? contentAwareMusic
            }
            switch directorBrief.musicPolicy {
            case .none:
                return nil
            case .soft:
                return MusicDirective(style: .calm, bpm: 68, volume: 0.12)
            case .matchVideo:
                // The questionnaire's generic "match the video" wording is not
                // an explicit genre. Selection remains driven by analyzed
                // content and the autonomous music intent.
                return contentAwareMusic
            case .specificTrack:
                var directive = contentAwareMusic
                    ?? MusicPromptInterpreter().interpret(
                        prompt: musicPrompt,
                        preset: plan.preset,
                        automaticDefault: true
                    )
                    ?? MusicDirective(style: .cinematic, bpm: 82)
                directive.trackID = directorBrief.musicTrackID
                directive.preferDifferentTrack = nil
                return directive
            }
        }()
        let primaryItems = items.filter { $0.overlay == nil }
        let transitionItems: [TimelineTransitionItem] = primaryItems.indices.dropFirst().compactMap { index in
            let incoming = primaryItems[index]
            let outgoing = primaryItems[index - 1]
            guard let rawStyle = incoming.transition,
                  let style = TransitionStyle(rawValue: rawStyle), style != .cut else { return nil }
            let preset = TransitionPresetRegistry.preset(for: style)
            return TimelineTransitionItem(
                style: style,
                outgoingClipID: outgoing.id,
                incomingClipID: incoming.id,
                startTime: incoming.timelineStart,
                duration: preset.defaultDuration,
                intensity: preset.defaultIntensity,
                parameters: preset.defaultParameters,
                explanation: [
                    "AI выбрал \(style.localizedTitle) по контексту соседних сцен",
                    incoming.incomingEditDecision?.motivation
                ].compactMap { $0 }
            )
        }
        let boundedTitles = titleItems.compactMap { item -> TitleTimelineItem? in
            guard item.startTime < cursor else { return nil }
            var copy = item
            copy.duration = min(copy.duration, max(0.05, cursor - copy.startTime))
            if let sceneID = titleSceneScopeByID[item.id] {
                copy.targetClipID = items.first { $0.overlay == nil && $0.eventSceneID == sceneID }?.id
            } else if let eventID = titleEventScopeByID[item.id] {
                copy.targetClipID = items.first { $0.overlay == nil && $0.eventID == eventID }?.id
            } else if let scope = directTitleContainment[item.id] {
                copy.targetClipID = items.first {
                    $0.overlay == nil && $0.timelineStart >= scope.lowerBound && $0.timelineStart < scope.upperBound
                }?.id
            }
            return copy
        }
        var containmentByTitleID = directTitleContainment
        for (titleID, sceneID) in titleSceneScopeByID {
            let block = items.filter { $0.overlay == nil && $0.eventSceneID == sceneID }
            if let start = block.map(\.timelineStart).min(),
               let end = block.map({ $0.timelineStart + $0.timelineDuration }).max(),
               end > start {
                containmentByTitleID[titleID] = start...end
            }
        }
        for (titleID, eventID) in titleEventScopeByID where containmentByTitleID[titleID] == nil {
            let block = items.filter { $0.overlay == nil && $0.eventID == eventID }
            if let start = block.map(\.timelineStart).min(),
               let end = block.map({ $0.timelineStart + $0.timelineDuration }).max(),
               end > start {
                containmentByTitleID[titleID] = start...end
            }
        }
        let titleReview = AutomatedTitlePolicy.reviewed(
            boundedTitles,
            timelineDuration: cursor,
            containmentByTitleID: containmentByTitleID
        )
        let finalTitles = titlePolicy.map {
            DirectorTitlePolicyEngine.applying($0, to: titleReview.titles, timelineDuration: cursor)
        } ?? titleReview.titles
        if !titleReview.diagnostics.isEmpty,
           let diagnosticItemIndex = items.firstIndex(where: { $0.overlay == nil && $0.kind != .title }) {
            items[diagnosticItemIndex].explanation.append(contentsOf: titleReview.diagnostics.map {
                "Title quality gate [\($0.code)]: \($0.message)"
            })
        }
        return Timeline(
            storyPlanID: plan.id,
            width: directorBrief?.canvasFormat.width ?? 1920,
            height: directorBrief?.canvasFormat.height ?? 1080,
            items: items,
            audioClips: audioClips,
            telemetryItems: telemetryItems,
            titleItems: finalTitles,
            transitionItems: transitionItems,
            music: music,
            originalAudioVolume: originalAudioVolume,
            audioDucking: audioClips.isEmpty ? nil : AudioDuckingSettings()
        )
    }

    private func motivatedBoundary(
        previous: TimelineItem?,
        previousCandidate: Candidate?,
        incomingCandidate: Candidate,
        incomingAsset: MediaAsset,
        chapter: StoryChapter,
        plan: StoryPlan,
        transitionsDisabled: Bool,
        explicitlyRequestsTransitions: Bool,
        boundaryIndex: Int
    ) -> EditorialBoundaryDecision? {
        guard let previous else { return nil }
        let eventChanged = previous.eventID != nil && chapter.eventID != nil && previous.eventID != chapter.eventID
        let sceneChanged = previous.eventSceneID != nil && chapter.eventSceneID != nil && previous.eventSceneID != chapter.eventSceneID
        let entersClimax = chapter.role == .climax && previous.storyRole != .climax
        let bothPhotos = previous.kind == .photo && incomingAsset.kind == .photo
        let previousEnergy = previousCandidate.map { $0.insights?.dynamics ?? $0.scores.action } ?? 0.5
        let incomingEnergy = incomingCandidate.insights?.dynamics ?? incomingCandidate.scores.action
        let previousMotion = previousCandidate?.insights?.subjectTracking?.mainSubject
        let incomingMotion = incomingCandidate.insights?.subjectTracking?.mainSubject
        let previousTags = previousCandidate?.tags ?? []
        let scaleTokens: Set<String> = ["close-up", "closeup", "wide", "detail", "крупный", "общий", "деталь"]
        let previousScales = Set(previousTags.filter { tag in scaleTokens.contains(where: { tag.lowercased().contains($0) }) })
        let incomingScales = Set(incomingCandidate.tags.filter { tag in scaleTokens.contains(where: { tag.lowercased().contains($0) }) })
        let semanticContext = TransitionSemanticContext(
            sceneChanged: sceneChanged,
            eventOrTimeChanged: eventChanged,
            energy: max(previousEnergy, incomingEnergy),
            previousMovementX: previousMotion?.movementX ?? 0,
            incomingMovementX: incomingMotion?.movementX ?? 0,
            previousMovementY: previousMotion?.movementY ?? 0,
            incomingMovementY: incomingMotion?.movementY ?? 0,
            emotion: incomingCandidate.insights?.emotion,
            tags: previousTags.union(incomingCandidate.tags),
            beatAccent: false,
            musicDrop: false,
            explicitCreativeRequest: plan.prompt.lowercased().contains("glitch") || plan.prompt.lowercased().contains("глитч"),
            shotScaleChanged: !previousScales.isEmpty && !incomingScales.isEmpty && previousScales != incomingScales,
            locationChanged: sceneChanged,
            recentStyles: previous.transition.flatMap(TransitionStyle.init(rawValue:)).map { [$0] } ?? []
        )

        if transitionsDisabled {
            return EditorialBoundaryDecision(choice: .cut, motivation: "Пользователь явно запросил только прямые склейки", confidence: 0.98)
        }

        if entersClimax, incomingEnergy >= 0.72, plan.constraints.pacing >= 0.72 {
            return EditorialBoundaryDecision(choice: .transition, motivation: "Один световой переход отмечает сюжетную кульминацию", confidence: 0.78, transitionStyle: .exposureFlash)
        }
        if eventChanged, (plan.preset == .cinematic || plan.preset == .memories), max(previousEnergy, incomingEnergy) < 0.68,
           let decision = TransitionSemanticSelector().select(for: semanticContext) {
            return EditorialBoundaryDecision(choice: .transition, motivation: decision.explanation, confidence: decision.confidence, transitionStyle: decision.style)
        }
        if bothPhotos, sceneChanged || explicitlyRequestsTransitions {
            return EditorialBoundaryDecision(choice: .transition, motivation: "Растворение связывает два неподвижных изображения", confidence: 0.76, transitionStyle: .crossDissolve)
        }
        if explicitlyRequestsTransitions {
            let density = max(0.04, plan.autonomousDecision?.grammar.transitionDensity ?? plan.constraints.transitionFrequency)
            let cadence = max(2, Int((1 / density).rounded()))
            if boundaryIndex.isMultiple(of: cadence) {
                if let decision = TransitionSemanticSelector().select(for: semanticContext) {
                    return EditorialBoundaryDecision(choice: .transition, motivation: decision.explanation, confidence: decision.confidence, transitionStyle: decision.style)
                }
                return EditorialBoundaryDecision(choice: .transition, motivation: "Пользователь явно запросил переходы; редкое растворение сохраняет профессиональную сдержанность", confidence: 0.70, transitionStyle: .crossDissolve)
            }
        }
        let motivation: String
        if eventChanged || sceneChanged {
            motivation = "Прямая склейка ясно переносит в новую сцену без декоративного эффекта"
        } else if chapter.role != previous.storyRole {
            motivation = "Прямая склейка открывает следующую сюжетную функцию"
        } else {
            motivation = "Прямая склейка сохраняет темп; входящий кадр даёт новый материал"
        }
        return EditorialBoundaryDecision(choice: .cut, motivation: motivation, confidence: 0.72)
    }

    private func makeSoundBridges(
        items: inout [TimelineItem],
        candidates: [UUID: Candidate],
        assets: [UUID: MediaAsset],
        originalAudioVolume: Double
    ) -> [TimelineAudioClip] {
        var result: [TimelineAudioClip] = []
        for index in items.indices where items[index].kind == .video && items[index].overlay == nil {
            guard let candidateID = items[index].candidateID,
                  let candidate = candidates[candidateID],
                  let assetID = items[index].assetID,
                  let asset = assets[assetID],
                  asset.metadata.hasAudio == true else { continue }
            let insight = candidate.insights
            let speech = insight?.speech
            let usefulSpeech = (speech?.confidence ?? 0) >= 0.52 && (insight?.originalAudioUsefulness ?? 0) >= 0.56
            let usefulEvent = (insight?.audioEvents ?? []).contains { event in
                [.laughter, .applause, .scream, .impact, .splash].contains(event.kind) && event.confidence >= 0.58
            }
            let roleNeedsReaction = items[index].storyRole == .reaction || items[index].storyRole == .climax
            guard usefulSpeech || usefulEvent || (roleNeedsReaction && (insight?.originalAudioUsefulness ?? 0) >= 0.76) else { continue }

            let requestedPreRoll = usefulSpeech && index > 0 ? 0.28 : 0
            let preRoll = min(requestedPreRoll, min(items[index].sourceStart, items[index].timelineStart))
            let assetDuration = asset.metadata.duration ?? (items[index].sourceStart + items[index].sourceDuration)
            let requestedPostRoll = usefulEvent || roleNeedsReaction ? 0.36 : 0.16
            let postRoll = min(requestedPostRoll, max(0, assetDuration - items[index].sourceStart - items[index].sourceDuration))
            guard preRoll + postRoll >= 0.08 else { continue }

            var adjustments = items[index].effectiveAudioAdjustments
            adjustments.muted = false
            // Detached J/L-cuts bypass the primary original-audio mix. Apply
            // the brief's source level here as well so a cinematic sound bridge
            // never jumps back to full camera volume.
            adjustments.volume *= min(max(0, originalAudioVolume), 1)
            adjustments.fadeIn = max(adjustments.fadeIn, 0.06)
            adjustments.fadeOut = max(adjustments.fadeOut, 0.08)
            adjustments.duckOthers = usefulSpeech
            result.append(TimelineAudioClip(
                assetID: assetID,
                title: usefulSpeech ? "J/L-cut · диалог" : "L-cut · синхронный звук",
                role: usefulSpeech ? .dialogue : .naturalSound,
                sourceStart: items[index].sourceStart - preRoll,
                sourceDuration: items[index].sourceDuration + preRoll + postRoll,
                timelineStart: items[index].timelineStart - preRoll,
                timelineDuration: items[index].timelineDuration + preRoll + postRoll,
                attachedToItemID: items[index].id,
                attachmentOffset: -preRoll,
                adjustments: adjustments
            ))
            var muted = items[index].effectiveAudioAdjustments
            muted.muted = true
            items[index].audioAdjustments = muted
            items[index].explanation.append(usefulSpeech
                ? "Audio edit: J/L-cut сохраняет фразу за пределами визуальной склейки"
                : "Audio edit: L-cut сохраняет завершение слышимого события")
        }
        return result
    }

    private func preferredDuration(candidate: Candidate, role: StoryRole?, pacing: Double, grammar: AutonomousEditingGrammar?) -> Double {
        let base: Double
        switch role {
        case .intro, .outro: base = 8.5
        case .reaction: base = 5.8
        case .setup: base = 7
        case .buildup: base = 5.5
        case .action: base = 3.4
        case .climax: base = 5.2
        case .bRoll: base = 2.8
        case nil: base = 6
        }
        let interest = candidate.insights?.storyValue ?? candidate.scores.interest
        let actionAdjustment = role == .action ? 1 - candidate.scores.action * 0.28 : 1
        let pacingAdjustment = 1.22 - pacing * 0.42
        let legacy = base * pacingAdjustment * actionAdjustment * (0.72 + interest * 0.42)
        let desired = grammar.map { grammar in
            let roleFactor: Double = role == .action ? 0.68 : role == .climax ? 1.12 : role == .intro || role == .outro ? 1.18 : 1
            return grammar.meanShotDuration * roleFactor * (0.78 + interest * 0.38)
        } ?? legacy
        return min(candidate.sourceDuration, max(role == .action ? 0.85 : 1.35, desired))
    }

    private struct ExactCandidateRange: Sendable {
        var sourceStart: Double
        var sourceDuration: Double
    }

    /// Allocates an explicitly requested duration across selected moments. The
    /// analyzed range remains the editorial anchor, but long camera sources may
    /// contribute adjacent continuity up to non-overlapping midpoints between
    /// anchors. This respects a five-minute brief without repeating five-second
    /// snippets or inventing duplicate cuts.
    private func exactCandidateRanges(
        plan: StoryPlan,
        candidates: [UUID: Candidate],
        assets: [UUID: MediaAsset]
    ) -> [UUID: ExactCandidateRange] {
        guard plan.requiresExactDuration,
              let decision = plan.autonomousDecision?.duration,
              abs(decision.safeRange.upperBound - decision.safeRange.lowerBound) < 0.001 else { return [:] }

        struct SelectedMoment {
            let id: UUID
            let candidate: Candidate
            let role: StoryRole?
            let eventID: UUID?
            var lowerBound: Double = 0
            var upperBound: Double = 0

            var capacity: Double { max(0, upperBound - lowerBound) }
        }
        var selected = plan.chapters.flatMap { chapter in
            chapter.candidateIDs.compactMap { id in
                candidates[id].map { SelectedMoment(id: id, candidate: $0, role: chapter.role, eventID: chapter.eventID) }
            }
        }
        guard !selected.isEmpty else { return [:] }

        for assetID in Set(selected.map { $0.candidate.assetID }) {
            let positions = selected.indices.filter { selected[$0].candidate.assetID == assetID }.sorted {
                let left = selected[$0].candidate.sourceStart + selected[$0].candidate.sourceDuration * 0.5
                let right = selected[$1].candidate.sourceStart + selected[$1].candidate.sourceDuration * 0.5
                if left != right { return left < right }
                if selected[$0].candidate.sourceStart != selected[$1].candidate.sourceStart {
                    return selected[$0].candidate.sourceStart < selected[$1].candidate.sourceStart
                }
                return selected[$0].id.uuidString < selected[$1].id.uuidString
            }
            guard !positions.isEmpty else { continue }
            let asset = assets[assetID]
            let assetEnd = max(
                asset?.metadata.duration ?? 0,
                positions.map { selected[$0].candidate.sourceStart + selected[$0].candidate.sourceDuration }.max() ?? 0
            )
            // Give adjacent anchors one shared boundary. Sorting and splitting
            // by center (rather than independently by start/end midpoints)
            // also handles containment such as [0, 100] plus [10, 15]: every
            // allocated source window remains monotonic and disjoint.
            let anchors = positions.map { position in
                min(assetEnd, max(0,
                    selected[position].candidate.sourceStart
                        + selected[position].candidate.sourceDuration * 0.5
                ))
            }
            let boundaries = zip(anchors, anchors.dropFirst()).map { left, right in
                min(assetEnd, max(0, (left + right) * 0.5))
            }
            for offset in positions.indices {
                let index = positions[offset]
                let candidate = selected[index].candidate
                let candidateEnd = candidate.sourceStart + candidate.sourceDuration
                let lower = offset == positions.startIndex ? 0 : boundaries[offset - 1]
                let upper = offset == positions.index(before: positions.endIndex) ? assetEnd : boundaries[offset]
                selected[index].lowerBound = max(0, min(candidateEnd, lower))
                selected[index].upperBound = max(selected[index].lowerBound, min(assetEnd, upper))
                if asset?.kind == .photo {
                    selected[index].lowerBound = candidate.sourceStart
                    selected[index].upperBound = candidateEnd
                }
            }
        }

        func allocate(_ moments: [SelectedMoment], target: Double) -> [UUID: Double] {
            guard !moments.isEmpty, target > 0 else { return [:] }
            var values = Dictionary(uniqueKeysWithValues: moments.map { moment in
                let preferred = preferredDuration(
                    candidate: moment.candidate,
                    role: moment.role,
                    pacing: plan.constraints.pacing,
                    grammar: plan.autonomousDecision?.grammar
                )
                return (moment.id, min(preferred, moment.capacity))
            })
            let preferredTotal = values.values.reduce(0, +)
            if preferredTotal > target + 0.000_001 {
                let scale = target / preferredTotal
                for id in values.keys { values[id, default: 0] *= scale }
                return values
            }
            var remaining = max(0, target - preferredTotal)
            var active = moments.filter { moment in
                (values[moment.id] ?? 0) + 0.001 < moment.capacity
            }
            while remaining > 0.000_001, !active.isEmpty {
                let fairShare = remaining / Double(active.count)
                var consumed = 0.0
                for moment in active {
                    let current = values[moment.id] ?? 0
                    let addition = min(fairShare, max(0, moment.capacity - current))
                    values[moment.id] = current + addition
                    consumed += addition
                }
                guard consumed > 0.000_001 else { break }
                remaining -= consumed
                active.removeAll { moment in
                    (values[moment.id] ?? 0) + 0.001 >= moment.capacity
                }
            }
            return values
        }

        func toppingUp(
            _ moments: [SelectedMoment],
            durations source: [UUID: Double],
            target: Double
        ) -> [UUID: Double] {
            var values = source
            var remaining = max(0, target - values.values.reduce(0, +))
            var active = moments.filter { moment in
                (values[moment.id] ?? 0) + 0.001 < moment.capacity
            }
            while remaining > 0.000_001, !active.isEmpty {
                let fairShare = remaining / Double(active.count)
                var consumed = 0.0
                for moment in active {
                    let current = values[moment.id] ?? 0
                    let addition = min(fairShare, max(0, moment.capacity - current))
                    values[moment.id] = current + addition
                    consumed += addition
                }
                guard consumed > 0.000_001 else { break }
                remaining -= consumed
                active.removeAll { moment in
                    (values[moment.id] ?? 0) + 0.001 >= moment.capacity
                }
            }
            return values
        }

        func expandedRanges(_ moments: [SelectedMoment], durations: [UUID: Double]) -> [UUID: ExactCandidateRange] {
            Dictionary(uniqueKeysWithValues: moments.compactMap { moment in
                guard let requested = durations[moment.id], moment.capacity > 0.05 else { return nil }
                let duration = min(max(0.05, requested), moment.capacity)
                let candidate = moment.candidate
                if duration + 0.001 < candidate.sourceDuration {
                    let trimmed = MomentPhaseTrimmer().range(for: candidate, desiredDuration: duration)
                    let start = min(
                        max(moment.lowerBound, trimmed.sourceStart),
                        max(moment.lowerBound, moment.upperBound - duration)
                    )
                    return (moment.id, ExactCandidateRange(sourceStart: start, sourceDuration: duration))
                }

                let anchorStart = max(moment.lowerBound, candidate.sourceStart)
                let anchorEnd = min(moment.upperBound, candidate.sourceStart + candidate.sourceDuration)
                var start = anchorStart
                var end = anchorEnd
                var extra = max(0, duration - (end - start))
                let before = min(extra * 0.5, max(0, start - moment.lowerBound))
                start -= before
                extra -= before
                let after = min(extra, max(0, moment.upperBound - end))
                end += after
                extra -= after
                if extra > 0 {
                    let finalBefore = min(extra, max(0, start - moment.lowerBound))
                    start -= finalBefore
                }
                return (moment.id, ExactCandidateRange(sourceStart: start, sourceDuration: min(duration, end - start)))
            })
        }

        guard let eventStory = plan.eventStory, !eventStory.entries.isEmpty else {
            return expandedRanges(selected, durations: allocate(selected, target: plan.constraints.targetDuration))
        }
        var durations: [UUID: Double] = [:]
        for entry in eventStory.entries {
            durations.merge(
                allocate(selected.filter { $0.eventID == entry.eventID }, target: entry.allocatedDuration),
                uniquingKeysWith: { _, new in new }
            )
        }
        let ungrouped = selected.filter { $0.eventID == nil }
        if !ungrouped.isEmpty {
            let allocated = eventStory.entries.reduce(0) { $0 + $1.allocatedDuration }
            durations.merge(
                allocate(ungrouped, target: max(0, plan.constraints.targetDuration - allocated)),
                uniquingKeysWith: { _, new in new }
            )
        }
        // An event's editorial share can exceed the source capacity of its
        // selected moments. Borrow the deficit from other selected events with
        // unused source before declaring an exact user duration impossible.
        durations = toppingUp(selected, durations: durations, target: plan.constraints.targetDuration)
        return expandedRanges(selected, durations: durations)
    }
}

public struct Timecode: Hashable, Sendable, CustomStringConvertible {
    public let frames: Int64
    public let frameRate: Int32
    public init(seconds: Double, frameRate: Int32) {
        self.frameRate = max(1, frameRate)
        self.frames = Int64((seconds * Double(self.frameRate)).rounded())
    }
    public init(frames: Int64, frameRate: Int32) {
        self.frames = max(0, frames)
        self.frameRate = max(1, frameRate)
    }
    public var seconds: Double { Double(frames) / Double(frameRate) }
    public var description: String {
        let ff = frames % Int64(frameRate)
        let totalSeconds = frames / Int64(frameRate)
        let ss = totalSeconds % 60
        let mm = (totalSeconds / 60) % 60
        let hh = totalSeconds / 3600
        return String(format: "%02lld:%02lld:%02lld:%02lld", hh, mm, ss, ff)
    }
}
