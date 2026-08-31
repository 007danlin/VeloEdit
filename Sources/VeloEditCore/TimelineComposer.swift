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
        let grammar = plan.autonomousDecision?.grammar
        let explicitlyAsksTelemetry = ["телеметри", "gps", "маршрут", "скорост", "высот", "g-force", "перегрузк"].contains(where: prompt.contains)
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
        var insertedProjectTitle = false
        var lastTelemetryEnd = -Double.greatestFiniteMagnitude
        var telemetryAccentCount = 0
        let maximumTelemetryAccents = max(1, Int(ceil(plan.constraints.targetDuration / 18)))

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

        func appendTitle(_ decision: SmartTitleDecision, at startTime: Double, reason: String) {
            guard let template = TitleTemplateRegistry.template(id: decision.templateID) else { return }
            titleItems.append(TitleTimelineItem(
                kind: template.kind,
                templateID: template.id,
                text: decision.primaryText,
                additionalText: decision.secondaryText,
                startTime: startTime,
                duration: decision.duration,
                style: template.defaultStyle,
                explanation: [reason] + decision.explanation
            ))
            usedTitleTexts.append(decision.primaryText)
        }

        for (chapterIndex, chapter) in plan.chapters.enumerated() {
            var chapterTitleStartOffset = 0.0
            if !insertedProjectTitle,
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
                    appendTitle(decision, at: cursor, reason: "Название фильма создано из event hierarchy")
                    chapterTitleStartOffset = decision.duration + 0.15
                }
                insertedProjectTitle = true
            }
            if let chapterTitle = chapter.chapterCardTitle,
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
                    appendTitle(
                        decision,
                        at: cursor + chapterTitleStartOffset,
                        reason: "Автоматическая глава события использует существующий шаблон"
                    )
                }
            } else if plan.eventStory == nil,
               plan.constraints.targetDuration >= 10 * 60,
               plan.constraints.targetClipCount == nil {
                if let decision = smartTitle(
                    purpose: .chapter,
                    requestedText: chapter.title,
                    chapter: chapter,
                    sequenceIndex: chapterIndex + 1,
                    preferredTemplateID: "title.chapter.v1"
                ) {
                    appendTitle(decision, at: cursor, reason: chapter.purpose ?? "Автоматическая глава длинного фильма")
                }
            }
            for id in chapter.candidateIDs {
                guard let candidate = candidates[id], let asset = assetsByID[candidate.assetID], !candidate.excluded else { continue }
                let preferred = preferredDuration(candidate: candidate, role: chapter.role, pacing: plan.constraints.pacing, grammar: grammar)
                let remaining = plan.constraints.targetDuration - cursor
                guard remaining > 0.5 else { break }
                let eventAllowance: Double = {
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
                let sourceRange = MomentPhaseTrimmer().range(for: candidate, desiredDuration: duration)
                let previousPrimary = items.last { $0.kind != .title && $0.overlay == nil }
                let previousCandidate = previousPrimary?.candidateID.flatMap { candidates[$0] }
                let boundaryDecision = motivatedBoundary(
                    previous: previousPrimary,
                    previousCandidate: previousCandidate,
                    incomingCandidate: candidate,
                    incomingAsset: asset,
                    chapter: chapter,
                    plan: plan,
                    transitionsDisabled: explicitlyDisablesTransitions,
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
                    guard telemetryAccentCount < maximumTelemetryAccents,
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
        }
        if asksPhotoLayout {
            for index in items.indices.dropFirst() where items[index].kind == .photo && items[index - 1].kind == .photo && items[index - 1].overlay == nil {
                items[index].overlay = OverlaySettings(style: .splitScreen, baseItemID: items[index - 1].id, scale: 0.5)
            }
            items = TimelineTiming.retimed(items)
        }
        let originalAudioVolume = OriginalAudioPromptInterpreter().volume(prompt: plan.prompt) ?? 1
        let audioClips = originalAudioVolume > 0.0001
            ? makeSoundBridges(items: &items, candidates: candidates, assets: assetsByID)
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
        let music = explicitlyNoMusic ? nil : explicitMusic ?? autonomousMusic ?? MusicPromptInterpreter().interpret(
            prompt: musicPrompt,
            preset: plan.preset,
            automaticDefault: true
        )
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
        return Timeline(
            storyPlanID: plan.id,
            items: items,
            audioClips: audioClips,
            telemetryItems: telemetryItems,
            titleItems: titleItems.compactMap { item in
                guard item.startTime < cursor else { return nil }
                var copy = item
                copy.duration = min(copy.duration, max(0.05, cursor - copy.startTime))
                return copy
            },
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
        assets: [UUID: MediaAsset]
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
