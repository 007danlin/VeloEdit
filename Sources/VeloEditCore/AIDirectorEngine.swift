import Foundation

/// The complete public vocabulary available to the director. The model never
/// emits Swift or renderer code: it can only select from these capabilities,
/// which are validated before the Timeline is changed.
public enum DirectorEditingTool: String, Codable, CaseIterable, Identifiable, Sendable {
    case cut, split, trim, rippleDelete, reorder, insert, replace, duplicate
    case format, subtitles
    case crop, zoom, pan, kenBurns, speedChange, slowMotion, speedRamp, freezeFrame
    case stabilization, exposure, color, contrast, saturation, sharpening, videoDenoise, blur
    case transitions, dissolve, fade, dipToBlack, wipe, lightTransition
    case music, trimMusic, audioFade, volume, ducking, noiseReduction, eq, detachAudio
    case bRoll, overlay, pictureInPicture, splitScreen, titles, telemetry, beatSynchronization
    case addEffect, removeEffect, moveEffect, trimEffect, setEffectParameter, animateParameter, addKeyframe, removeKeyframe, applyEffectPreset
    case editTitle, removeTitle, addTransition, removeTransition, syncToBeat

    public var id: String { rawValue }
}

/// Compile-time typed editing calls used by the autonomous director. Associated
/// values make missing IDs/ranges impossible to hide in a free-form payload.
public enum DirectorToolCall: Hashable, Sendable {
    case split(itemID: UUID, fraction: Double, reason: String)
    case trim(itemID: UUID, sourceStart: Double, sourceDuration: Double, reason: String)
    case rippleDelete(itemID: UUID, reason: String)
    case reorder(itemID: UUID, beforeItemID: UUID?, reason: String)
    case swap(itemID: UUID, withItemID: UUID, reason: String)
    case insert(candidateID: UUID, sourceStart: Double, sourceDuration: Double, afterItemID: UUID?, role: StoryRole, reason: String)
    case replace(itemID: UUID, candidateID: UUID, sourceStart: Double, sourceDuration: Double, role: StoryRole, reason: String)
    case duplicate(itemID: UUID, afterItemID: UUID?, reason: String)
    case setCrop(itemID: UUID, crop: CropStyle, reason: String)
    case setMotion(itemID: UUID, effect: ClipEffect?, reason: String)
    case setSpeed(itemID: UUID, rate: Double, reason: String)
    case setSpeedRamp(itemID: UUID, ramp: SpeedRamp?, reason: String)
    case freezeFrame(itemID: UUID, duration: Double, reason: String)
    case setVideoAdjustments(itemID: UUID, adjustments: VideoAdjustments, reason: String)
    case setTransition(itemID: UUID, transition: TransitionStyle?, reason: String)
    case setAudioAdjustments(itemID: UUID, adjustments: AudioAdjustments, reason: String)
    case setDucking(AudioDuckingSettings?, reason: String)
    case detachAudio(itemID: UUID, reason: String)
    case insertOverlay(candidateID: UUID, baseItemID: UUID, sourceStart: Double, sourceDuration: Double, style: OverlayStyle, reason: String)
    case setTelemetry(itemID: UUID, settings: TelemetryOverlaySettings?, reason: String)
    case addTitle(text: String, atEnd: Bool, reason: String)
    case addEffect(type: TimelineEffectType, startTime: Double, duration: Double, targetClipID: UUID?, reason: String)
    case addAnimatedEffect(type: TimelineEffectType, startTime: Double, duration: Double, targetClipID: UUID?, keyframes: [EffectKeyframe], reason: String)
    case applyEffectPreset(presetID: String, startTime: Double, duration: Double, targetClipID: UUID?, reason: String)
    case removeEffect(effectID: UUID, reason: String)
    case moveEffect(effectID: UUID, startTime: Double, reason: String)
    case trimEffect(effectID: UUID, duration: Double, reason: String)
    case setEffectParameter(effectID: UUID, name: String, value: Double, reason: String)
    case animateParameter(effectID: UUID, parameter: String, fromValue: Double, toValue: Double, startTime: Double, endTime: Double, easing: KeyframeEasing, reason: String)
    case addEffectKeyframe(effectID: UUID, keyframe: EffectKeyframe, reason: String)
    case removeEffectKeyframe(effectID: UUID, keyframeID: UUID, reason: String)
    case addTitleObject(text: String, kind: TitleTimelineKind, templateID: String?, startTime: Double, duration: Double, reason: String)
    case editTitleObject(titleID: UUID, text: String?, style: TitleStyle?, animation: TitleAnimation?, reason: String)
    case removeTitleObject(titleID: UUID, reason: String)
    case addTransitionObject(outgoingClipID: UUID, incomingClipID: UUID, style: TransitionStyle, duration: Double, reason: String)
    case editTransitionObject(transitionID: UUID, duration: Double?, intensity: Double?, direction: TransitionDirection?, easing: KeyframeEasing?, reason: String)
    case removeTransitionObject(transitionID: UUID, reason: String)
    case syncToBeat(bpm: Double, reason: String)
    case setCanvas(width: Int, height: Int, subjectAware: Bool, reason: String)
    case replaceSubtitles(items: [TitleTimelineItem], reason: String)

    public var tool: DirectorEditingTool {
        switch self {
        case .split: return .split
        case .trim: return .trim
        case .rippleDelete: return .rippleDelete
        case .reorder: return .reorder
        case .swap: return .reorder
        case .insert: return .insert
        case .replace: return .replace
        case .duplicate: return .duplicate
        case .setCrop: return .crop
        case .setMotion(_, let effect, _):
            switch effect {
            case .kenBurns: return .kenBurns
            case .zoomIn, .zoomOut, .pushIn, .pullOut: return .zoom
            case .panLeft, .panRight: return .pan
            default: return .zoom
            }
        case .setSpeed(_, let rate, _): return rate < 1 ? .slowMotion : .speedChange
        case .setSpeedRamp: return .speedRamp
        case .freezeFrame: return .freezeFrame
        case .setVideoAdjustments: return .color
        case .setTransition(_, let transition, _):
            switch transition {
            case .crossDissolve, .blurDissolve: return .dissolve
            case .fade: return .fade
            case .fadeThroughBlack: return .dipToBlack
            case .wipeLeft, .wipeRight: return .wipe
            case .lightFlash: return .lightTransition
            default: return .transitions
            }
        case .setAudioAdjustments: return .volume
        case .setDucking: return .ducking
        case .detachAudio: return .detachAudio
        case .insertOverlay(_, _, _, _, let style, _):
            switch style {
            case .cutaway: return .bRoll
            case .pictureInPicture: return .pictureInPicture
            case .splitScreen: return .splitScreen
            case .greenScreen: return .overlay
            }
        case .setTelemetry: return .telemetry
        case .addTitle: return .titles
        case .addEffect, .addAnimatedEffect: return .addEffect
        case .applyEffectPreset: return .applyEffectPreset
        case .removeEffect: return .removeEffect
        case .moveEffect: return .moveEffect
        case .trimEffect: return .trimEffect
        case .setEffectParameter: return .setEffectParameter
        case .animateParameter: return .animateParameter
        case .addEffectKeyframe: return .addKeyframe
        case .removeEffectKeyframe: return .removeKeyframe
        case .addTitleObject: return .titles
        case .editTitleObject: return .editTitle
        case .removeTitleObject: return .removeTitle
        case .addTransitionObject: return .addTransition
        case .editTransitionObject: return .transitions
        case .removeTransitionObject: return .removeTransition
        case .syncToBeat: return .syncToBeat
        case .setCanvas: return .format
        case .replaceSubtitles: return .subtitles
        }
    }

    public var reason: String {
        switch self {
        case .split(_, _, let value), .trim(_, _, _, let value), .rippleDelete(_, let value),
             .reorder(_, _, let value), .swap(_, _, let value), .insert(_, _, _, _, _, let value),
             .replace(_, _, _, _, _, let value), .duplicate(_, _, let value),
             .setCrop(_, _, let value), .setMotion(_, _, let value), .setSpeed(_, _, let value),
             .setSpeedRamp(_, _, let value), .freezeFrame(_, _, let value),
             .setVideoAdjustments(_, _, let value), .setTransition(_, _, let value),
             .setAudioAdjustments(_, _, let value), .setDucking(_, let value),
             .detachAudio(_, let value), .insertOverlay(_, _, _, _, _, let value),
             .setTelemetry(_, _, let value), .addTitle(_, _, let value),
             .addEffect(_, _, _, _, let value), .addAnimatedEffect(_, _, _, _, _, let value),
             .applyEffectPreset(_, _, _, _, let value), .removeEffect(_, let value),
             .moveEffect(_, _, let value), .trimEffect(_, _, let value),
             .setEffectParameter(_, _, _, let value), .animateParameter(_, _, _, _, _, _, _, let value),
             .addEffectKeyframe(_, _, let value),
             .removeEffectKeyframe(_, _, let value), .addTitleObject(_, _, _, _, _, let value),
             .editTitleObject(_, _, _, _, let value), .removeTitleObject(_, let value),
             .addTransitionObject(_, _, _, _, let value), .editTransitionObject(_, _, _, _, _, let value),
             .removeTransitionObject(_, let value),
             .syncToBeat(_, let value), .setCanvas(_, _, _, let value),
             .replaceSubtitles(_, let value):
            return value
        }
    }
}

public struct DirectorToolExecutionReport: Hashable, Sendable {
    public var applied: [DirectorToolCall]
    public var rejected: [String]

    public init(applied: [DirectorToolCall] = [], rejected: [String] = []) {
        self.applied = applied
        self.rejected = rejected
    }
}

/// The sole mutation boundary for autonomous editing. It validates references,
/// source bounds, lock state and numeric values, then retimes the magnetic
/// storyline. No operation writes to a source URL.
public struct DirectorEditingTools: Sendable {
    public init() {}

    public func apply(
        _ calls: [DirectorToolCall],
        to source: Timeline,
        assets: [MediaAsset],
        analyses: [AnalysisResult],
        plan: StoryPlan? = nil
    ) -> (timeline: Timeline, report: DirectorToolExecutionReport) {
        var timeline = source
        var report = DirectorToolExecutionReport()
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let candidatesByID = Dictionary(uniqueKeysWithValues: analyses.flatMap(\.directorCandidates).map { ($0.id, $0) })
        let eventContextByCandidate = Dictionary(uniqueKeysWithValues: (plan?.chapters ?? []).flatMap { chapter in
            chapter.candidateIDs.map { ($0, (chapter.eventID, chapter.eventSceneID)) }
        })
        let effectBudget = AIEffectBudgetPolicy.budget(for: plan?.preset)

        func itemIndex(_ id: UUID) -> Int? { timeline.items.firstIndex { $0.id == id } }
        func rejection(_ call: DirectorToolCall, _ message: String) {
            report.rejected.append("\(call.tool.rawValue): \(message)")
        }
        func validRange(candidate: Candidate, start: Double, duration: Double) -> Bool {
            guard start.isFinite, duration.isFinite, start >= 0, duration >= 0.05 else { return false }
            let candidateEnd = candidate.sourceStart + candidate.sourceDuration
            let assetEnd = assetsByID[candidate.assetID]?.metadata.duration ?? candidateEnd
            return start + duration <= min(candidateEnd, assetEnd) + 0.001
        }
        func makeItem(candidate: Candidate, start: Double, duration: Double, role: StoryRole, reason: String) -> TimelineItem? {
            guard let asset = assetsByID[candidate.assetID], validRange(candidate: candidate, start: start, duration: duration) else { return nil }
            return TimelineItem(
                candidateID: candidate.id,
                assetID: candidate.assetID,
                kind: asset.kind == .photo ? .photo : .video,
                sourceStart: start,
                sourceDuration: duration,
                timelineStart: 0,
                timelineDuration: duration,
                storyRole: role,
                editorialPurpose: reason,
                eventID: eventContextByCandidate[candidate.id]?.0,
                eventSceneID: eventContextByCandidate[candidate.id]?.1,
                explanation: candidate.explanation + [reason]
            )
        }

        for call in calls {
            switch call {
            case .split(let itemID, let fraction, _):
                guard let index = itemIndex(itemID), !timeline.items[index].locked,
                      fraction.isFinite, fraction >= 0.1, fraction <= 0.9,
                      timeline.items[index].kind != .title else {
                    rejection(call, "недопустимая или заблокированная цель")
                    continue
                }
                var left = timeline.items[index]
                var right = left
                let sourceSplit = left.sourceDuration * fraction
                let timelineSplit = left.timelineDuration * fraction
                left.sourceDuration = sourceSplit
                left.timelineDuration = timelineSplit
                right.id = UUID()
                right.candidateID = nil
                right.sourceStart += sourceSplit
                right.sourceDuration -= sourceSplit
                right.timelineDuration -= timelineSplit
                right.transition = nil
                timeline.items[index] = left
                timeline.items.insert(right, at: index + 1)
                report.applied.append(call)

            case .trim(let itemID, let start, let duration, _):
                guard let index = itemIndex(itemID), !timeline.items[index].locked,
                      start.isFinite, duration.isFinite, start >= 0, duration >= 0.05 else {
                    rejection(call, "недопустимый диапазон или заблокированная цель")
                    continue
                }
                let item = timeline.items[index]
                let assetEnd = item.assetID.flatMap { assetsByID[$0]?.metadata.duration } ?? (item.sourceStart + item.sourceDuration)
                guard start + duration <= assetEnd + 0.001 else {
                    rejection(call, "диапазон выходит за пределы исходника")
                    continue
                }
                timeline.items[index].sourceStart = start
                timeline.items[index].sourceDuration = duration
                timeline.items[index].timelineDuration = max(0.05, timeline.items[index].speedRamp?.outputDuration(sourceDuration: duration) ?? duration / timeline.items[index].speed)
                timeline.items[index].editorialPurpose = call.reason
                timeline.items[index].explanation.append(call.reason)
                report.applied.append(call)

            case .rippleDelete(let itemID, _):
                guard let index = itemIndex(itemID), !timeline.items[index].locked else {
                    rejection(call, "цель не найдена или заблокирована")
                    continue
                }
                timeline.items.remove(at: index)
                timeline.items.removeAll { $0.overlay?.baseItemID == itemID }
                timeline.effects = timeline.effectiveEffects.filter { $0.targetClipID != itemID }
                timeline.titleItems = timeline.effectiveTitleItems.filter { $0.targetClipID != itemID }
                timeline.transitionItems = timeline.effectiveTransitionItems.filter {
                    $0.outgoingClipID != itemID && $0.incomingClipID != itemID
                }
                report.applied.append(call)

            case .reorder(let itemID, let beforeItemID, _):
                guard let index = itemIndex(itemID), !timeline.items[index].locked,
                      timeline.items[index].overlay == nil else {
                    rejection(call, "перемещать можно только незаблокированный основной клип")
                    continue
                }
                let item = timeline.items.remove(at: index)
                if let beforeItemID, let destination = timeline.items.firstIndex(where: { $0.id == beforeItemID }) {
                    timeline.items.insert(item, at: destination)
                } else {
                    let lastPrimary = timeline.items.lastIndex { $0.overlay == nil }.map { $0 + 1 } ?? timeline.items.endIndex
                    timeline.items.insert(item, at: lastPrimary)
                }
                report.applied.append(call)

            case .swap(let itemID, let otherItemID, _):
                guard itemID != otherItemID,
                      let firstIndex = itemIndex(itemID),
                      let secondIndex = itemIndex(otherItemID),
                      !timeline.items[firstIndex].locked,
                      !timeline.items[secondIndex].locked,
                      timeline.items[firstIndex].overlay == nil,
                      timeline.items[secondIndex].overlay == nil else {
                    rejection(call, "обе сцены должны быть доступными основными клипами")
                    continue
                }
                timeline.items.swapAt(firstIndex, secondIndex)
                report.applied.append(call)

            case .insert(let candidateID, let start, let duration, let afterItemID, let role, _):
                guard let candidate = candidatesByID[candidateID], !candidate.excluded,
                      let item = makeItem(candidate: candidate, start: start, duration: duration, role: role, reason: call.reason) else {
                    rejection(call, "кандидат или его диапазон недоступен")
                    continue
                }
                let destination = afterItemID.flatMap(itemIndex).map { $0 + 1 }
                    ?? (timeline.items.lastIndex { $0.overlay == nil }.map { $0 + 1 } ?? 0)
                timeline.items.insert(item, at: destination)
                report.applied.append(call)

            case .replace(let itemID, let candidateID, let start, let duration, let role, _):
                guard let index = itemIndex(itemID), !timeline.items[index].locked,
                      let candidate = candidatesByID[candidateID], !candidate.excluded,
                      var replacement = makeItem(candidate: candidate, start: start, duration: duration, role: role, reason: call.reason) else {
                    rejection(call, "цель заблокирована либо кандидат недоступен")
                    continue
                }
                replacement.id = timeline.items[index].id
                replacement.timelineStart = timeline.items[index].timelineStart
                replacement.transition = timeline.items[index].transition
                timeline.items[index] = replacement
                report.applied.append(call)

            case .duplicate(let itemID, let afterItemID, _):
                guard let index = itemIndex(itemID), timeline.items[index].kind != .title else {
                    rejection(call, "клип для повторного использования не найден")
                    continue
                }
                var copy = timeline.items[index]
                copy.id = UUID()
                copy.locked = false
                copy.transition = nil
                copy.editorialPurpose = call.reason
                copy.explanation.append(call.reason)
                let destination = afterItemID.flatMap(itemIndex).map { $0 + 1 } ?? index + 1
                timeline.items.insert(copy, at: destination)
                report.applied.append(call)

            case .setCrop(let itemID, let crop, _):
                guard let index = itemIndex(itemID) else { rejection(call, "клип не найден"); continue }
                var value = timeline.items[index].effectiveVideoAdjustments
                value.crop = crop
                timeline.items[index].videoAdjustments = value.isNeutral ? nil : value
                report.applied.append(call)

            case .setMotion(let itemID, let effect, _):
                guard let index = itemIndex(itemID) else { rejection(call, "клип не найден"); continue }
                timeline.items[index].effect = effect?.rawValue
                report.applied.append(call)

            case .setSpeed(let itemID, let rate, _):
                guard let index = itemIndex(itemID), !timeline.items[index].locked,
                      rate.isFinite, rate >= 0.1, rate <= 8 else {
                    rejection(call, "скорость вне безопасного диапазона")
                    continue
                }
                timeline.items[index].speed = rate
                timeline.items[index].speedRamp = nil
                timeline.items[index].timelineDuration = max(0.05, timeline.items[index].sourceDuration / rate)
                report.applied.append(call)

            case .setSpeedRamp(let itemID, let ramp, _):
                guard let index = itemIndex(itemID), !timeline.items[index].locked else {
                    rejection(call, "клип не найден или заблокирован")
                    continue
                }
                timeline.items[index].speed = 1
                timeline.items[index].speedRamp = ramp
                timeline.items[index].timelineDuration = max(0.05, ramp?.outputDuration(sourceDuration: timeline.items[index].sourceDuration) ?? timeline.items[index].sourceDuration)
                report.applied.append(call)

            case .freezeFrame(let itemID, let duration, _):
                guard let index = itemIndex(itemID), duration.isFinite, duration >= 0.25, duration <= 30 else {
                    rejection(call, "некорректная цель или длительность стоп-кадра")
                    continue
                }
                let original = timeline.items[index]
                var freeze = original
                freeze.id = UUID()
                freeze.candidateID = nil
                freeze.sourceStart += original.sourceDuration * 0.5
                freeze.sourceDuration = original.kind == .video ? 1 / max(1, timeline.frameRate) : duration
                freeze.timelineDuration = duration
                freeze.speed = 1
                freeze.speedRamp = nil
                freeze.freezeFrame = true
                freeze.overlay = nil
                freeze.transition = nil
                freeze.audioAdjustments = AudioAdjustments(muted: true)
                freeze.editorialPurpose = call.reason
                timeline.items.insert(freeze, at: index + 1)
                report.applied.append(call)

            case .setVideoAdjustments(let itemID, let adjustments, _):
                guard let index = itemIndex(itemID) else { rejection(call, "клип не найден"); continue }
                timeline.items[index].videoAdjustments = adjustments.isNeutral ? nil : adjustments
                report.applied.append(call)

            case .setTransition(let itemID, let transition, _):
                guard let index = itemIndex(itemID), timeline.items[index].overlay == nil else {
                    rejection(call, "входящий основной клип не найден")
                    continue
                }
                let resolvedTransition = transition == .cut ? nil : transition
                timeline.items[index].transition = resolvedTransition?.rawValue
                var objects = timeline.effectiveTransitionItems
                objects.removeAll { $0.incomingClipID == itemID }
                if let transition = resolvedTransition,
                   let outgoing = timeline.items[..<index].last(where: { $0.overlay == nil && $0.kind != .title }) {
                    guard AIEffectBudgetPolicy.canAddTransition(to: timeline, budget: effectBudget) else {
                        rejection(call, "переход отклонён AI-бюджетом")
                        continue
                    }
                    let preset = TransitionPresetRegistry.preset(for: transition)
                    objects.append(TimelineTransitionItem(
                        style: transition,
                        outgoingClipID: outgoing.id,
                        incomingClipID: itemID,
                        startTime: timeline.items[index].timelineStart,
                        duration: preset.defaultDuration,
                        intensity: min(preset.defaultIntensity, 0.72),
                        parameters: preset.defaultParameters,
                        direction: preset.defaultDirection,
                        easing: preset.defaultEasing,
                        explanation: [call.reason]
                    ))
                }
                timeline.transitionItems = objects
                report.applied.append(call)

            case .setAudioAdjustments(let itemID, let adjustments, _):
                guard let index = itemIndex(itemID), timeline.items[index].kind != .title else {
                    rejection(call, "клип со звуком не найден")
                    continue
                }
                timeline.items[index].audioAdjustments = adjustments.isNeutral ? nil : adjustments
                report.applied.append(call)

            case .setDucking(let settings, _):
                timeline.audioDucking = settings
                report.applied.append(call)

            case .detachAudio(let itemID, _):
                guard let index = itemIndex(itemID), let assetID = timeline.items[index].assetID,
                      assetsByID[assetID]?.metadata.hasAudio == true else {
                    rejection(call, "у клипа нет доступной аудиодорожки")
                    continue
                }
                let item = timeline.items[index]
                var clips = timeline.effectiveAudioClips
                clips.append(TimelineAudioClip(
                    assetID: assetID,
                    title: "Audio · \(assetsByID[assetID]?.displayName ?? "клип")",
                    role: .detached,
                    sourceStart: item.sourceStart,
                    sourceDuration: item.sourceDuration,
                    timelineStart: item.timelineStart,
                    timelineDuration: item.timelineDuration,
                    attachedToItemID: item.id
                ))
                timeline.audioClips = clips
                var muted = item.effectiveAudioAdjustments
                muted.muted = true
                timeline.items[index].audioAdjustments = muted
                report.applied.append(call)

            case .insertOverlay(let candidateID, let baseItemID, let start, let duration, let style, _):
                guard let baseIndex = itemIndex(baseItemID), timeline.items[baseIndex].overlay == nil,
                      let candidate = candidatesByID[candidateID], !candidate.excluded,
                      var overlay = makeItem(candidate: candidate, start: start, duration: duration, role: .bRoll, reason: call.reason) else {
                    rejection(call, "B-roll или базовый клип недоступен")
                    continue
                }
                let overlaySettings = OverlaySettings(style: style, baseItemID: baseItemID, startOffset: min(0.6, timeline.items[baseIndex].timelineDuration * 0.18))
                overlay.overlay = overlaySettings
                overlay.timelineDuration = min(duration, max(0.25, timeline.items[baseIndex].timelineDuration - overlaySettings.effectiveStartOffset))
                timeline.items.append(overlay)
                report.applied.append(call)

            case .setTelemetry(let itemID, let settings, _):
                guard let index = itemIndex(itemID), let assetID = timeline.items[index].assetID,
                      settings == nil || analyses.first(where: { $0.assetID == assetID })?.telemetry?.hasTelemetry == true else {
                    rejection(call, "телеметрия отсутствует у исходника")
                    continue
                }
                timeline.items[index].telemetryOverlay = settings
                var telemetryItems = timeline.effectiveTelemetryItems
                telemetryItems.removeAll { $0.linkedAssetID == assetID && abs($0.timelineStart - timeline.items[index].timelineStart) < 0.001 }
                if let settings {
                    telemetryItems.append(TimelineTelemetryItem(
                        targetClipID: timeline.items[index].id,
                        linkedAssetID: assetID,
                        sourceStart: timeline.items[index].sourceStart,
                        timelineStart: timeline.items[index].timelineStart,
                        timelineDuration: timeline.items[index].timelineDuration,
                        settings: settings,
                        explanation: [call.reason]
                    ))
                }
                timeline.telemetryItems = telemetryItems
                report.applied.append(call)

            case .addTitle(let text, let atEnd, _):
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { rejection(call, "пустой титр"); continue }
                let primaryItems = timeline.items.filter { $0.kind != .title && $0.overlay == nil }
                let contextItem = atEnd ? primaryItems.last : primaryItems.first
                let contextCandidate = contextItem?.candidateID.flatMap { candidatesByID[$0] }
                let contextAsset = contextCandidate.flatMap { assetsByID[$0.assetID] }
                let avoidRegions = contextCandidate?.insights?.subjectTracking?.mainSubject?.observations
                    .max(by: { $0.confidence * $0.region.area < $1.confidence * $1.region.area }).map { [$0.region] } ?? []
                let decision = SmartTitleEngine().decide(SmartTitleContext(
                    purpose: atEnd ? .ending : .filmOpening,
                    requestedText: clean,
                    tags: contextCandidate?.tags ?? [],
                    summaries: [contextCandidate?.insights?.sceneSummary].compactMap { $0 },
                    captureDate: contextAsset?.metadata.effectiveCaptureDate,
                    usedTitles: timeline.effectiveTitleItems.map(\.text),
                    avoidRegions: avoidRegions,
                    preferredTemplateID: atEnd ? "title.end-card.v1" : "title.minimal-clean.v1"
                ))
                let template = TitleTemplateRegistry.template(id: decision?.templateID)
                    ?? TitleTemplateRegistry.template(id: atEnd ? "title.end-card.v1" : "title.minimal-clean.v1")
                let duration = min(decision?.duration ?? template?.duration ?? 3.2, max(0.05, timeline.duration))
                let title = TitleTimelineItem(
                    kind: template?.kind ?? .title,
                    templateID: template?.id,
                    text: decision?.primaryText ?? clean,
                    additionalText: decision?.secondaryText,
                    callToAction: atEnd ? template?.preview.callToAction : nil,
                    startTime: atEnd ? max(0, timeline.duration - duration) : 0,
                    duration: duration,
                    style: template?.defaultStyle ?? TitleStyle(),
                    explanation: [call.reason] + (decision?.explanation ?? [])
                )
                timeline.titleItems = timeline.effectiveTitleItems + [title]
                report.applied.append(call)

            case .addEffect(let type, let startTime, let duration, let targetClipID, _):
                guard startTime.isFinite, duration.isFinite, startTime >= 0, duration >= 0.05,
                      targetClipID.map({ itemIndex($0) != nil }) ?? true else {
                    rejection(call, "некорректные границы эффекта или цель")
                    continue
                }
                let normalizedReason = call.reason.lowercased()
                let explicitCreative = EffectPresetRegistry.preset(for: type).aiUsage.requiresExplicitCreativeRequest &&
                    ["glitch", "глитч", "digital", "vhs", "креатив", "creative"].contains { normalizedReason.contains($0) }
                guard AIEffectBudgetPolicy.canAddEffect(type, targetClipID: targetClipID, to: timeline, budget: effectBudget, explicitCreativeRequest: explicitCreative) else {
                    rejection(call, "эффект отклонён AI-бюджетом или требует явного creative-запроса")
                    continue
                }
                var effects = timeline.effectiveEffects
                let preset = EffectPresetRegistry.preset(for: type)
                effects.append(EffectTimelineItem(
                    effectType: type,
                    startTime: startTime,
                    duration: duration,
                    parameters: preset.defaultParameters,
                    intensity: min(type.defaultIntensity, preset.aiUsage.maximumRecommendedIntensity),
                    targetClipID: targetClipID,
                    stackOrder: EffectStackEngine.stack(in: timeline, for: targetClipID).count,
                    explanation: [call.reason, "AI создал обычный редактируемый объект Timeline по metadata preset"]
                ))
                timeline.effects = effects
                report.applied.append(call)

            case .addAnimatedEffect(let type, let startTime, let duration, let targetClipID, let requestedKeyframes, _):
                guard startTime.isFinite, duration.isFinite, startTime >= 0, duration >= 0.05,
                      targetClipID.map({ itemIndex($0) != nil }) ?? true,
                      AIEffectBudgetPolicy.canAddEffect(type, targetClipID: targetClipID, to: timeline, budget: effectBudget) else {
                    rejection(call, "анимированный эффект выходит за границы или AI-бюджет")
                    continue
                }
                let preset = EffectPresetRegistry.preset(for: type)
                let keyframes = requestedKeyframes.compactMap { frame -> EffectKeyframe? in
                    guard let descriptor = preset.parameter(named: frame.parameter), descriptor.supportsKeyframes,
                          frame.time.isFinite, frame.time >= 0, frame.time <= duration else { return nil }
                    var safe = frame
                    let value = min(max(descriptor.range.lowerBound, frame.effectiveNumericValue), descriptor.range.upperBound)
                    safe.value = value
                    safe.typedValue = EffectParameterValue.scalar(value, as: descriptor.valueType)
                    return safe
                }.sorted { $0.time < $1.time }
                guard keyframes.count >= 2 else { rejection(call, "для анимации нужны минимум два корректных keyframe"); continue }
                var effects = timeline.effectiveEffects
                effects.append(EffectTimelineItem(
                    effectType: type,
                    startTime: startTime,
                    duration: duration,
                    parameters: preset.defaultParameters,
                    intensity: min(type.defaultIntensity, preset.aiUsage.maximumRecommendedIntensity),
                    keyframes: keyframes,
                    targetClipID: targetClipID,
                    stackOrder: EffectStackEngine.stack(in: timeline, for: targetClipID).count,
                    explanation: [call.reason, "AI создал реальную keyframe-анимацию"]
                ))
                timeline.effects = effects
                report.applied.append(call)

            case .applyEffectPreset(let presetID, let startTime, let duration, let targetClipID, _):
                guard let preset = EffectStackPresetRegistry.preset(id: presetID), startTime.isFinite, duration.isFinite,
                      duration >= 0.05, targetClipID.map({ itemIndex($0) != nil }) ?? true else {
                    rejection(call, "пресет эффекта или его границы некорректны")
                    continue
                }
                let allowed = preset.components.allSatisfy {
                    AIEffectBudgetPolicy.canAddEffect($0.type, targetClipID: targetClipID, to: timeline, budget: effectBudget)
                } && EffectStackEngine.stack(in: timeline, for: targetClipID).count + preset.components.count <= effectBudget.maximumEffectsPerClip
                guard allowed else { rejection(call, "пресет превышает AI-бюджет эффектов"); continue }
                EffectStackPresetRegistry.apply(
                    preset,
                    to: &timeline,
                    targetClipID: targetClipID,
                    startTime: startTime,
                    duration: duration,
                    explanation: call.reason
                )
                report.applied.append(call)

            case .removeEffect(let effectID, _):
                var effects = timeline.effectiveEffects
                guard effects.contains(where: { $0.id == effectID }) else { rejection(call, "эффект не найден"); continue }
                effects.removeAll { $0.id == effectID }
                timeline.effects = effects
                report.applied.append(call)

            case .moveEffect(let effectID, let startTime, _):
                var effects = timeline.effectiveEffects
                guard startTime.isFinite, startTime >= 0, let index = effects.firstIndex(where: { $0.id == effectID }) else {
                    rejection(call, "эффект не найден или новая позиция некорректна"); continue
                }
                effects[index].startTime = startTime
                effects[index].explanation.append(call.reason)
                timeline.effects = effects
                report.applied.append(call)

            case .trimEffect(let effectID, let duration, _):
                var effects = timeline.effectiveEffects
                guard duration.isFinite, duration >= 0.05, let index = effects.firstIndex(where: { $0.id == effectID }) else {
                    rejection(call, "эффект не найден или длительность некорректна"); continue
                }
                effects[index].duration = duration
                effects[index].keyframes.removeAll { $0.time > duration }
                effects[index].explanation.append(call.reason)
                timeline.effects = effects
                report.applied.append(call)

            case .setEffectParameter(let effectID, let name, let value, _):
                var effects = timeline.effectiveEffects
                let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.isFinite, !cleanName.isEmpty, let index = effects.firstIndex(where: { $0.id == effectID }),
                      let descriptor = EffectPresetRegistry.preset(for: effects[index].effectType).parameter(named: cleanName) else {
                    rejection(call, "эффект или параметр не найден"); continue
                }
                let safeValue = min(max(descriptor.range.lowerBound, value), descriptor.range.upperBound)
                if cleanName == "intensity" { effects[index].intensity = safeValue }
                else {
                    effects[index].parameters.removeAll { $0.name == cleanName }
                    effects[index].parameters.append(descriptor.parameter(value: safeValue))
                }
                effects[index].explanation.append(call.reason)
                timeline.effects = effects
                report.applied.append(call)

            case .animateParameter(let effectID, let parameter, let fromValue, let toValue, let startTime, let endTime, let easing, _):
                var effects = timeline.effectiveEffects
                guard let index = effects.firstIndex(where: { $0.id == effectID }),
                      let descriptor = EffectPresetRegistry.preset(for: effects[index].effectType).parameter(named: parameter),
                      descriptor.supportsKeyframes, startTime.isFinite, endTime.isFinite,
                      startTime >= 0, endTime > startTime, endTime <= effects[index].duration else {
                    rejection(call, "параметр нельзя анимировать или диапазон keyframes некорректен")
                    continue
                }
                let first = min(max(descriptor.range.lowerBound, fromValue), descriptor.range.upperBound)
                let last = min(max(descriptor.range.lowerBound, toValue), descriptor.range.upperBound)
                effects[index].keyframes.removeAll { $0.parameter == parameter && $0.time >= startTime && $0.time <= endTime }
                effects[index].keyframes.append(contentsOf: [
                    EffectKeyframe(parameter: parameter, time: startTime, value: first, easing: easing, typedValue: EffectParameterValue.scalar(first, as: descriptor.valueType)),
                    EffectKeyframe(parameter: parameter, time: endTime, value: last, easing: easing, typedValue: EffectParameterValue.scalar(last, as: descriptor.valueType))
                ])
                effects[index].keyframes.sort { $0.time < $1.time }
                effects[index].explanation.append(call.reason)
                timeline.effects = effects
                report.applied.append(call)

            case .addEffectKeyframe(let effectID, let keyframe, _):
                var effects = timeline.effectiveEffects
                guard let index = effects.firstIndex(where: { $0.id == effectID }), keyframe.time <= effects[index].duration,
                      let descriptor = EffectPresetRegistry.preset(for: effects[index].effectType).parameter(named: keyframe.parameter),
                      descriptor.supportsKeyframes else {
                    rejection(call, "эффект не найден или keyframe выходит за его границы"); continue
                }
                var keyframe = keyframe
                let value = min(max(descriptor.range.lowerBound, keyframe.effectiveNumericValue), descriptor.range.upperBound)
                keyframe.value = value
                if keyframe.typedValue != nil {
                    keyframe.typedValue = EffectParameterValue.scalar(value, as: descriptor.valueType)
                }
                effects[index].keyframes.removeAll { $0.id == keyframe.id }
                effects[index].keyframes.append(keyframe)
                effects[index].keyframes.sort { $0.time < $1.time }
                timeline.effects = effects
                report.applied.append(call)

            case .removeEffectKeyframe(let effectID, let keyframeID, _):
                var effects = timeline.effectiveEffects
                guard let index = effects.firstIndex(where: { $0.id == effectID }),
                      effects[index].keyframes.contains(where: { $0.id == keyframeID }) else {
                    rejection(call, "keyframe не найден"); continue
                }
                effects[index].keyframes.removeAll { $0.id == keyframeID }
                timeline.effects = effects
                report.applied.append(call)

            case .addTitleObject(let text, let kind, let templateID, let startTime, let duration, _):
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, startTime.isFinite, duration.isFinite, startTime >= 0, duration >= 0.05 else {
                    rejection(call, "текст или границы титра некорректны"); continue
                }
                let words: [CaptionWord]
                if kind.category == .captions {
                    let tokens = clean.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    let interval = duration / Double(max(1, tokens.count))
                    words = tokens.enumerated().map { index, word in
                        CaptionWord(word: word, start: Double(index) * interval, end: Double(index + 1) * interval)
                    }
                } else { words = [] }
                var titles = timeline.effectiveTitleItems
                let template = TitleTemplateRegistry.template(id: templateID) ?? TitleTemplateRegistry.defaultTemplate(for: kind)
                titles.append(TitleTimelineItem(
                    kind: template?.kind ?? kind,
                    templateID: template?.id,
                    text: clean,
                    startTime: startTime,
                    duration: duration,
                    style: template?.defaultStyle ?? TitleStyle(),
                    words: words,
                    explanation: [call.reason]
                ))
                timeline.titleItems = titles
                report.applied.append(call)

            case .editTitleObject(let titleID, let text, let style, let animation, _):
                var titles = timeline.effectiveTitleItems
                guard let index = titles.firstIndex(where: { $0.id == titleID }) else { rejection(call, "титр не найден"); continue }
                if let text {
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { rejection(call, "пустой текст титра"); continue }
                    titles[index].text = clean
                }
                if titles[index].templateID == nil {
                    if let style { titles[index].style = style }
                    if let animation { titles[index].animation = animation }
                } else if style != nil || animation != nil {
                    titles[index].explanation.append("AI-изменение layout/typography/animation отклонено: дизайн принадлежит шаблону")
                }
                titles[index].explanation.append(call.reason)
                timeline.titleItems = titles
                report.applied.append(call)

            case .removeTitleObject(let titleID, _):
                var titles = timeline.effectiveTitleItems
                guard titles.contains(where: { $0.id == titleID }) else { rejection(call, "титр не найден"); continue }
                titles.removeAll { $0.id == titleID }
                timeline.titleItems = titles
                report.applied.append(call)

            case .addTransitionObject(let outgoingID, let incomingID, let style, let duration, _):
                guard duration.isFinite, duration >= 0.08, duration <= 4,
                      let outgoingIndex = itemIndex(outgoingID), let incomingIndex = itemIndex(incomingID),
                      outgoingIndex < incomingIndex, timeline.items[outgoingIndex].overlay == nil,
                      timeline.items[incomingIndex].overlay == nil else {
                    rejection(call, "пара клипов или длительность перехода некорректна"); continue
                }
                var transitions = timeline.effectiveTransitionItems
                transitions.removeAll { $0.incomingClipID == incomingID }
                if style == .cut {
                    timeline.items[incomingIndex].transition = nil
                    timeline.transitionItems = transitions
                    report.applied.append(call)
                    continue
                }
                guard AIEffectBudgetPolicy.canAddTransition(to: timeline, budget: effectBudget) else {
                    rejection(call, "переход отклонён AI-бюджетом")
                    continue
                }
                let preset = TransitionPresetRegistry.preset(for: style)
                timeline.items[incomingIndex].transition = style.rawValue
                transitions.append(TimelineTransitionItem(
                    style: style,
                    outgoingClipID: outgoingID,
                    incomingClipID: incomingID,
                    startTime: timeline.items[incomingIndex].timelineStart,
                    duration: duration,
                    intensity: min(preset.defaultIntensity, 0.72),
                    parameters: preset.defaultParameters,
                    direction: preset.defaultDirection,
                    easing: preset.defaultEasing,
                    explanation: [call.reason]
                ))
                timeline.transitionItems = transitions
                report.applied.append(call)

            case .removeTransitionObject(let transitionID, _):
                var transitions = timeline.effectiveTransitionItems
                guard let transition = transitions.first(where: { $0.id == transitionID }) else { rejection(call, "переход не найден"); continue }
                transitions.removeAll { $0.id == transitionID }
                timeline.transitionItems = transitions
                if let index = itemIndex(transition.incomingClipID) { timeline.items[index].transition = nil }
                report.applied.append(call)

            case .editTransitionObject(let transitionID, let duration, let intensity, let direction, let easing, _):
                var transitions = timeline.effectiveTransitionItems
                guard let index = transitions.firstIndex(where: { $0.id == transitionID }) else {
                    rejection(call, "переход не найден")
                    continue
                }
                let preset = TransitionPresetRegistry.preset(for: transitions[index].style)
                if let duration {
                    transitions[index].duration = min(max(preset.durationRange.lowerBound, duration), preset.durationRange.upperBound)
                }
                if let intensity { transitions[index].intensity = min(max(0, intensity), 1) }
                if let direction { transitions[index].direction = direction }
                if let easing { transitions[index].easing = easing }
                transitions[index].explanation.append(call.reason)
                timeline.transitionItems = transitions
                report.applied.append(call)

            case .syncToBeat(let bpm, _):
                guard bpm.isFinite, bpm >= 40, bpm <= 240 else { rejection(call, "BPM вне допустимого диапазона"); continue }
                if let structure = timeline.music?.structure {
                    timeline = MusicSyncEngine().synchronize(timeline, structure: structure)
                } else {
                    timeline = MusicSyncEngine().synchronize(timeline, bpm: bpm)
                }
                report.applied.append(call)

            case .setCanvas(let width, let height, let subjectAware, _):
                guard (64...8_192).contains(width), (64...8_192).contains(height) else {
                    rejection(call, "размер кадра вне безопасного диапазона")
                    continue
                }
                let evenWidth = max(64, width - width % 2)
                let evenHeight = max(64, height - height % 2)
                timeline.width = evenWidth
                timeline.height = evenHeight
                let targetAspect = Double(evenWidth) / Double(evenHeight)
                if subjectAware {
                    for index in timeline.items.indices where timeline.items[index].kind != .title {
                        guard let candidateID = timeline.items[index].candidateID,
                              let candidate = candidatesByID[candidateID],
                              let assetID = timeline.items[index].assetID,
                              let asset = assetsByID[assetID] else { continue }
                        let sourceAspect = Double(max(1, asset.metadata.width ?? evenWidth)) /
                            Double(max(1, asset.metadata.height ?? evenHeight))
                        var adjustments = timeline.items[index].effectiveVideoAdjustments
                        if let tracking = candidate.insights?.subjectTracking,
                           let reframe = SubjectAwareReframeEngine().plan(
                               tracking: tracking,
                               sourceAspectRatio: sourceAspect,
                               targetAspectRatio: targetAspect,
                               isPhoto: timeline.items[index].kind == .photo
                           ) {
                            adjustments.crop = .fill
                            adjustments.subjectReframe = reframe
                        } else if abs(sourceAspect - targetAspect) > 0.18 {
                            // Without a reliable subject track, fitting is safer
                            // than silently cutting a face or important object.
                            adjustments.crop = .fit
                            adjustments.subjectReframe = nil
                        }
                        timeline.items[index].videoAdjustments = adjustments.isNeutral ? nil : adjustments
                    }
                }
                report.applied.append(call)

            case .replaceSubtitles(let items, _):
                let validClipIDs = Set(timeline.items.map(\.id))
                let captions = items.compactMap { source -> TitleTimelineItem? in
                    guard source.kind == .automaticSubtitles || source.kind == .wordLevelCaptions,
                          !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          source.startTime.isFinite, source.duration.isFinite,
                          source.startTime >= 0, source.duration >= 0.05,
                          source.startTime < timeline.duration + 0.001,
                          source.targetClipID.map(validClipIDs.contains) ?? true else { return nil }
                    var item = source
                    item.duration = min(item.duration, max(0.05, timeline.duration - item.startTime))
                    item.words = item.words.filter { $0.start < item.duration }.map { word in
                        CaptionWord(
                            id: word.id,
                            word: word.word,
                            start: min(max(0, word.start), item.duration),
                            end: min(max(0, word.end), item.duration)
                        )
                    }
                    return item
                }
                var titles = timeline.effectiveTitleItems.filter {
                    $0.kind != .automaticSubtitles && $0.kind != .wordLevelCaptions
                }
                titles.append(contentsOf: captions)
                timeline.titleItems = titles.sorted { $0.startTime < $1.startTime }
                if captions.count == items.count {
                    report.applied.append(call)
                } else {
                    rejection(call, "часть субтитров вышла за границы Timeline")
                    if !captions.isEmpty { report.applied.append(call) }
                }
            }
        }

        timeline.items = TimelineTiming.retimed(timeline.items)
        timeline.transitionItems = timeline.effectiveTransitionItems.compactMap { transition in
            guard let incoming = timeline.items.first(where: { $0.id == transition.incomingClipID }) else { return nil }
            var copy = transition
            copy.startTime = incoming.timelineStart
            return copy
        }
        return (timeline, report)
    }
}

public enum DirectorReviewIssueKind: String, Codable, Hashable, Sendable {
    case weakOpening, weakClimax, repeatedRange, repeatedScene, overlongClip
    case lowQualityShot, actionImbalance
    case cutDensityTooHigh, pacingTooSlow, transitionOverload, missingStoryArc
}

public struct DirectorReviewIssue: Codable, Hashable, Sendable {
    public var kind: DirectorReviewIssueKind
    public var severity: Double
    public var itemIDs: [UUID]
    public var message: String

    public init(kind: DirectorReviewIssueKind, severity: Double, itemIDs: [UUID] = [], message: String) {
        self.kind = kind
        self.severity = min(max(0, severity), 1)
        self.itemIDs = itemIDs
        self.message = message
    }
}

public struct DirectorReview: Codable, Hashable, Sendable {
    public var score: Double
    public var issues: [DirectorReviewIssue]

    public init(score: Double, issues: [DirectorReviewIssue]) {
        self.score = min(max(0, score), 1)
        self.issues = issues
    }
}

public struct DirectorRunSummary: Codable, Hashable, Sendable {
    public var reviewIterations: Int
    public var appliedToolNames: [String]
    public var decisionReasons: [String]
    public var rejectedOperations: [String]
    public var initialReview: DirectorReview
    public var finalReview: DirectorReview
    public var evaluatedVariantCount: Int?
    public var globalScore: Double?
    public var variantDiagnostics: VariantSelectionDiagnostics?
    public var deepMediaDiagnostics: DeepMediaDiagnostics?
    public var autonomousDecision: AutonomousDirectorDecision?
    public var paretoFrontStrategies: [String]?
    public var eventDiagnostics: EventRunDiagnostics?
    /// P7 automatic personalization diagnostics. This is intentionally
    /// separate from P1 global scores and P6 perceptual review evidence.
    public var personalTasteDiagnostics: PersonalTasteDiagnostics?
    /// P6 remains a separate quality loop: these fields intentionally do not
    /// overwrite legacy self-review or MontageGlobalScore diagnostics.
    public var perceptualReviewIterations: Int?
    public var perceptualFindings: [PerceptualFinding]?
    public var highSeverityFindings: Int?
    public var perceptualRepairsAttempted: Int?
    public var perceptualRepairsAccepted: Int?
    public var perceptualRepairsRejected: Int?
    public var perceptualRollbackCount: Int?
    public var perceptualScoreBefore: Double?
    public var perceptualScoreAfter: Double?
    public var perceptualReview: PerceptualReviewSummary?
    public var completedAt: Date

    public init(reviewIterations: Int, appliedToolNames: [String], decisionReasons: [String], rejectedOperations: [String], initialReview: DirectorReview, finalReview: DirectorReview, evaluatedVariantCount: Int? = nil, globalScore: Double? = nil, variantDiagnostics: VariantSelectionDiagnostics? = nil, deepMediaDiagnostics: DeepMediaDiagnostics? = nil, autonomousDecision: AutonomousDirectorDecision? = nil, paretoFrontStrategies: [String]? = nil, eventDiagnostics: EventRunDiagnostics? = nil, personalTasteDiagnostics: PersonalTasteDiagnostics? = nil, perceptualReview: PerceptualReviewSummary? = nil, completedAt: Date = Date()) {
        self.reviewIterations = reviewIterations
        self.appliedToolNames = appliedToolNames
        self.decisionReasons = decisionReasons
        self.rejectedOperations = rejectedOperations
        self.initialReview = initialReview
        self.finalReview = finalReview
        self.evaluatedVariantCount = evaluatedVariantCount
        self.globalScore = globalScore
        self.variantDiagnostics = variantDiagnostics
        self.deepMediaDiagnostics = deepMediaDiagnostics
        self.autonomousDecision = autonomousDecision
        self.paretoFrontStrategies = paretoFrontStrategies
        self.eventDiagnostics = eventDiagnostics
        self.personalTasteDiagnostics = personalTasteDiagnostics
        self.perceptualReviewIterations = perceptualReview?.perceptualReviewIterations
        self.perceptualFindings = perceptualReview?.findings
        self.highSeverityFindings = perceptualReview?.highSeverityFindings
        self.perceptualRepairsAttempted = perceptualReview?.repairsAttempted
        self.perceptualRepairsAccepted = perceptualReview?.repairsAccepted
        self.perceptualRepairsRejected = perceptualReview?.repairsRejected
        self.perceptualRollbackCount = perceptualReview?.rollbackCount
        self.perceptualScoreBefore = perceptualReview?.perceptualScoreBefore
        self.perceptualScoreAfter = perceptualReview?.perceptualScoreAfter
        self.perceptualReview = perceptualReview
        self.completedAt = completedAt
    }
}

public struct TimelineReviewTransactionResult: Sendable {
    public var timeline: Timeline
    public var review: DirectorReview
    public var committed: Bool
    public var combinedScore: Double
    public var safetyViolations: [String]

    public init(timeline: Timeline, review: DirectorReview, committed: Bool, combinedScore: Double, safetyViolations: [String] = []) {
        self.timeline = timeline
        self.review = review
        self.committed = committed
        self.combinedScore = combinedScore.clamped01
        self.safetyViolations = safetyViolations
    }
}

public struct TimelineReviewTransaction: Sendable {
    public init() {}

    public func commitIfImproved(
        original: Timeline,
        candidate: Timeline,
        currentReview: DirectorReview,
        plan: StoryPlan,
        analyses: [AnalysisResult],
        assets: [MediaAsset] = [],
        scoringFeatures: MontageScoringFeatures? = nil,
        currentCombinedScore: Double? = nil
    ) -> TimelineReviewTransactionResult {
        let candidateReview = TimelineSelfReviewer().review(candidate, plan: plan, analyses: analyses)
        let safetyViolations = TimelineSafetyValidator().violations(candidate: candidate, comparedTo: original, plan: plan, analyses: analyses)
        let scorer = DefaultMontageGlobalScorer()
        let features = scoringFeatures ?? MontageScoringFeatures(assets: assets, analyses: analyses)
        let originalGlobal = currentCombinedScore == nil
            ? scorer.score(plan: plan, timeline: original, features: features, analyses: analyses).total
            : 0
        let candidateGlobal = scorer.score(plan: plan, timeline: candidate, features: features, analyses: analyses).total
        let originalCombined = currentCombinedScore ?? (originalGlobal * 0.72 + currentReview.score * 0.28)
        let candidateCombined = candidateGlobal * 0.72 + candidateReview.score * 0.28
        guard safetyViolations.isEmpty, candidateCombined > originalCombined + 0.001 else {
            return TimelineReviewTransactionResult(
                timeline: original,
                review: currentReview,
                committed: false,
                combinedScore: originalCombined,
                safetyViolations: safetyViolations
            )
        }
        return TimelineReviewTransactionResult(timeline: candidate, review: candidateReview, committed: true, combinedScore: candidateCombined)
    }
}

public struct TimelineCheckpoint: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var reason: String
    public var timeline: Timeline
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, reason: String, timeline: Timeline, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.reason = reason
        self.timeline = timeline
        self.createdAt = createdAt
    }
}

public struct TimelineSelfReviewer: Sendable {
    public init() {}

    public func review(_ timeline: Timeline, plan: StoryPlan, analyses: [AnalysisResult]) -> DirectorReview {
        let candidateByID = Dictionary(uniqueKeysWithValues: analyses.flatMap(\.directorCandidates).map { ($0.id, $0) })
        let primaries = timeline.items.filter { $0.kind != .title && $0.overlay == nil }
        guard !primaries.isEmpty else {
            return DirectorReview(score: 0, issues: [DirectorReviewIssue(kind: .missingStoryArc, severity: 1, message: "В Timeline нет монтажных фрагментов")])
        }
        var issues: [DirectorReviewIssue] = []
        let scored = primaries.compactMap { item in item.candidateID.flatMap { candidateByID[$0] }.map { (item, $0) } }
        let rankingContext = HighlightRankingContext(prompt: plan.prompt, preset: plan.preset, constraints: plan.constraints, autonomousStyle: plan.autonomousDecision?.finalStyle)
        let ranker = ContextualHighlightRanker()

        if let first = scored.first, let strongest = scored.max(by: {
            ranker.score($0.1, asset: nil, context: rankingContext) < ranker.score($1.1, asset: nil, context: rankingContext)
        }),
           ranker.score(first.1, asset: nil, context: rankingContext) + 0.12 < ranker.score(strongest.1, asset: nil, context: rankingContext),
           first.1.scores.interest < 0.68 {
            issues.append(DirectorReviewIssue(kind: .weakOpening, severity: 0.72, itemIDs: [first.0.id], message: "Первый кадр заметно слабее доступных выразительных моментов"))
        }

        let climaxItems = scored.filter { $0.0.storyRole == .climax }
        if let strongestAction = scored.max(by: { Self.climaxScore($0.1) < Self.climaxScore($1.1) }) {
            let current = climaxItems.map { Self.climaxScore($0.1) }.max() ?? 0
            if current + 0.10 < Self.climaxScore(strongestAction.1) {
                issues.append(DirectorReviewIssue(kind: .weakClimax, severity: 0.84, itemIDs: climaxItems.map { $0.0.id }, message: "Лучший action-момент не работает как кульминация"))
            }
        }

        let technicallyWeak = scored.filter { item, candidate in
            guard !item.locked else { return false }
            let insights = candidate.insights
            return candidate.scores.quality < 0.42 ||
                (insights?.sharpness ?? 1) < 0.34 ||
                (insights?.exposureQuality ?? 1) < 0.32
        }
        if !technicallyWeak.isEmpty {
            issues.append(DirectorReviewIssue(
                kind: .lowQualityShot,
                severity: 0.74,
                itemIDs: technicallyWeak.map { $0.0.id },
                message: "В rough cut остались технически слабые кадры, не оправданные историей"
            ))
        }

        for pair in zip(primaries, primaries.dropFirst()) {
            guard pair.0.assetID == pair.1.assetID else { continue }
            let overlap = max(0, min(pair.0.sourceStart + pair.0.sourceDuration, pair.1.sourceStart + pair.1.sourceDuration) - max(pair.0.sourceStart, pair.1.sourceStart))
            let share = overlap / max(0.05, min(pair.0.sourceDuration, pair.1.sourceDuration))
            if share > 0.35 || pair.0.candidateID == pair.1.candidateID {
                issues.append(DirectorReviewIssue(kind: .repeatedRange, severity: 0.78, itemIDs: [pair.0.id, pair.1.id], message: "Соседние клипы повторяют один и тот же диапазон исходника"))
            }
        }

        for item in primaries where item.timelineDuration > Self.maximumDuration(for: item.storyRole, pacing: plan.constraints.pacing) * 1.35 {
            issues.append(DirectorReviewIssue(kind: .overlongClip, severity: 0.58, itemIDs: [item.id], message: "Фрагмент длиннее, чем допускает его роль и темп фильма"))
        }

        let average = primaries.reduce(0) { $0 + $1.timelineDuration } / Double(primaries.count)
        if primaries.count >= 5, average < 1.15 {
            issues.append(DirectorReviewIssue(kind: .cutDensityTooHigh, severity: 0.62, itemIDs: primaries.map(\.id), message: "Слишком высокая плотность склеек"))
        }
        if primaries.count >= 5, plan.constraints.pacing > 0.62, average > 7.5 {
            issues.append(DirectorReviewIssue(kind: .pacingTooSlow, severity: 0.60, itemIDs: primaries.map(\.id), message: "Средняя длина кадра слишком велика для заданной динамики"))
        }
        let actionDuration = scored.filter { $0.1.scores.action >= 0.72 }.reduce(0) { $0 + $1.0.timelineDuration }
        let actionShare = actionDuration / max(0.05, primaries.reduce(0) { $0 + $1.timelineDuration })
        if primaries.count >= 6,
           (plan.constraints.pacing >= 0.68 && actionShare < 0.16 ||
            plan.constraints.pacing <= 0.45 && actionShare > 0.78) {
            issues.append(DirectorReviewIssue(
                kind: .actionImbalance,
                severity: 0.57,
                itemIDs: primaries.map(\.id),
                message: "Баланс action и спокойных сцен не соответствует режиссёрскому темпу"
            ))
        }
        let transitionShare = Double(primaries.filter { $0.transition != nil }.count) / Double(max(1, primaries.count - 1))
        if transitionShare > max(0.42, plan.constraints.transitionFrequency + 0.28) {
            issues.append(DirectorReviewIssue(kind: .transitionOverload, severity: 0.55, itemIDs: primaries.filter { $0.transition != nil }.map(\.id), message: "Переходы используются чаще, чем требуют история и темп"))
        }
        let roles = Set(primaries.compactMap(\.storyRole))
        if primaries.count >= 5 && (!roles.contains(.intro) || !roles.contains(.climax) || !roles.contains(.outro)) {
            issues.append(DirectorReviewIssue(kind: .missingStoryArc, severity: 0.82, itemIDs: primaries.map(\.id), message: "В Timeline отсутствует полный сюжетный контур intro–climax–outro"))
        }

        let penalty = issues.reduce(0) { $0 + $1.severity * 0.13 }
        return DirectorReview(score: max(0, 1 - penalty), issues: issues)
    }

    fileprivate static func climaxScore(_ candidate: Candidate) -> Double {
        let insight = candidate.insights
        return candidate.scores.action * 0.42 + candidate.scores.interest * 0.28 +
            candidate.scores.quality * 0.12 + candidate.scores.uniqueness * 0.08 +
            (insight?.roleScores[.climax] ?? insight?.storyValue ?? 0.5) * 0.10
    }

    fileprivate static func maximumDuration(for role: StoryRole?, pacing: Double) -> Double {
        let base: Double
        switch role {
        case .intro, .outro: base = 9
        case .reaction: base = 6.5
        case .setup: base = 7.5
        case .buildup: base = 6
        case .action: base = 4.5
        case .climax: base = 6
        case .bRoll: base = 3.5
        case nil: base = 7
        }
        return max(2, base * (1.18 - pacing * 0.38))
    }
}

public struct AIDirectorEngine: Sendable {
    public var maximumReviewIterations: Int

    public init(maximumReviewIterations: Int = 2) {
        self.maximumReviewIterations = min(max(0, maximumReviewIterations), 3)
    }

    public func direct(
        plan: StoryPlan,
        initialTimeline: Timeline,
        assets: [MediaAsset],
        analyses: [AnalysisResult]
    ) -> Timeline {
        let tools = DirectorEditingTools()
        var timeline = initialTimeline
        var applied: [DirectorToolCall] = []
        var rejected: [String] = []

        let decisions = initialDecisions(timeline: timeline, plan: plan, assets: assets, analyses: analyses)
        let firstExecution = tools.apply(decisions, to: timeline, assets: assets, analyses: analyses, plan: plan)
        timeline = firstExecution.timeline
        applied.append(contentsOf: firstExecution.report.applied)
        rejected.append(contentsOf: firstExecution.report.rejected)

        let reviewer = TimelineSelfReviewer()
        let scoringFeatures = MontageScoringFeatures(assets: assets, analyses: analyses)
        let globalScorer = DefaultMontageGlobalScorer()
        let initialReview = reviewer.review(timeline, plan: plan, analyses: analyses)
        var finalReview = initialReview
        var iterations = 0
        while iterations < maximumReviewIterations, !finalReview.issues.isEmpty {
            let repairs = repairCalls(for: finalReview, timeline: timeline, plan: plan, analyses: analyses)
            guard !repairs.isEmpty else { break }
            // Repairs are speculative. Evaluate single repairs and bounded pairs
            // so one harmful operation cannot block an independently useful one.
            let originalTimeline = timeline
            let originalGlobal = globalScorer.score(plan: plan, timeline: originalTimeline, features: scoringFeatures, analyses: analyses).total
            let originalCombined = originalGlobal * 0.72 + finalReview.score * 0.28
            let bounded = Array(repairs.prefix(8))
            var beams = bounded.map { [$0] }
            if bounded.count > 1 {
                for first in bounded.indices {
                    for second in bounded.indices where second > first && beams.count < 20 {
                        beams.append([bounded[first], bounded[second]])
                    }
                }
            }
            var best: (result: TimelineReviewTransactionResult, report: DirectorToolExecutionReport)?
            for beam in beams {
                let execution = tools.apply(beam, to: originalTimeline, assets: assets, analyses: analyses, plan: plan)
                guard !execution.report.applied.isEmpty else { continue }
                let transaction = TimelineReviewTransaction().commitIfImproved(
                    original: originalTimeline,
                    candidate: execution.timeline,
                    currentReview: finalReview,
                    plan: plan,
                    analyses: analyses,
                    assets: assets,
                    scoringFeatures: scoringFeatures,
                    currentCombinedScore: originalCombined
                )
                guard transaction.committed else { continue }
                if best.map({ transaction.combinedScore > $0.result.combinedScore }) ?? true {
                    best = (transaction, execution.report)
                }
            }
            guard let best else {
                rejected.append("Self-review beam отклонён: combined global score не улучшился или нарушены safety constraints")
                break
            }
            timeline = best.result.timeline
            finalReview = best.result.review
            applied.append(contentsOf: best.report.applied)
            rejected.append(contentsOf: best.report.rejected)
            iterations += 1
        }

        // P6 observes the result as a sequence of finished shots and cuts. It
        // speculates through the same typed tools and commits only through the
        // existing global scorer + hard safety boundary.
        let perceptual = PerceptualReviewEngine().run(
            timeline: timeline,
            plan: plan,
            assets: assets,
            analyses: analyses
        )
        timeline = perceptual.timeline
        applied.append(contentsOf: perceptual.appliedCalls)
        rejected.append(contentsOf: perceptual.rejectedOperations)
        finalReview = reviewer.review(timeline, plan: plan, analyses: analyses)

        timeline.directorRun = DirectorRunSummary(
            reviewIterations: iterations,
            appliedToolNames: applied.map { $0.tool.rawValue },
            decisionReasons: Array(Set(applied.map(\.reason))).sorted() + (plan.autonomousDecision?.explanations ?? []),
            rejectedOperations: rejected,
            initialReview: initialReview,
            finalReview: finalReview,
            deepMediaDiagnostics: DeepMediaDiagnostics.aggregate(analyses.compactMap(\.deepMediaDiagnostics)),
            autonomousDecision: plan.autonomousDecision,
            eventDiagnostics: plan.eventStory?.diagnostics,
            perceptualReview: perceptual.summary
        )
        return timeline
    }

    private func initialDecisions(
        timeline: Timeline,
        plan: StoryPlan,
        assets: [MediaAsset],
        analyses: [AnalysisResult]
    ) -> [DirectorToolCall] {
        let candidates = Dictionary(uniqueKeysWithValues: analyses.flatMap(\.directorCandidates).map { ($0.id, $0) })
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let primaries = timeline.items.filter { $0.kind != .title && $0.overlay == nil }
        let grammar = plan.autonomousDecision?.grammar
        var calls: [DirectorToolCall] = []

        for (position, item) in primaries.enumerated() {
            guard let candidateID = item.candidateID, let candidate = candidates[candidateID] else { continue }
            let role = item.storyRole
            let prompt = plan.prompt.lowercased()
            let semanticEffect = EffectSemanticSelector().select(for: EffectSemanticContext(
                isPhoto: item.kind == .photo,
                energy: candidate.insights?.dynamics ?? candidate.scores.action,
                stability: candidate.scores.stability,
                emotion: candidate.insights?.emotion,
                tags: candidate.tags,
                cinematicIntent: plan.preset == .cinematic || plan.preset == .memories,
                explicitCreativeRequest: prompt.contains("glitch") || prompt.contains("глитч") || prompt.contains("rgb")
            ))
            let legacyMaximum = TimelineSelfReviewer.maximumDuration(for: role, pacing: plan.constraints.pacing)
            let grammarMaximum = grammar.map { value in
                value.meanShotDuration * (role == .action ? 0.82 : role == .climax ? 1.28 : 1.18)
            }
            let maximum = min(legacyMaximum, grammarMaximum ?? legacyMaximum)
            let minimum = role == .action ? 1.15 : 1.6
            let desired = min(candidate.sourceDuration, max(minimum, maximum * (0.58 + candidate.scores.interest * 0.42)))
            if item.sourceDuration > desired + 0.35 {
                let range = MomentPhaseTrimmer().range(for: candidate, desiredDuration: desired)
                calls.append(.trim(itemID: item.id, sourceStart: range.sourceStart, sourceDuration: range.sourceDuration, reason: "Длительность выбрана по роли \(role?.localizedTitle ?? "сцены") с сохранением anticipation и reaction вокруг peak"))
            }

            var decidedVideo = item.effectiveVideoAdjustments
            var videoReasons: [String] = []
            let sourceAspect: Double = {
                guard let asset = assetsByID[candidate.assetID],
                      let width = asset.metadata.width, let height = asset.metadata.height,
                      width > 0, height > 0 else { return 16.0 / 9.0 }
                let rotated = abs(asset.metadata.orientationDegrees / 90).isMultiple(of: 2) == false
                return rotated ? Double(height) / Double(width) : Double(width) / Double(height)
            }()
            let targetAspect = Double(max(1, timeline.width)) / Double(max(1, timeline.height))
            let reframe = candidate.insights?.subjectTracking.flatMap {
                SubjectAwareReframeEngine().plan(
                    tracking: $0,
                    sourceAspectRatio: sourceAspect,
                    targetAspectRatio: targetAspect,
                    isPhoto: item.kind == .photo
                )
            }
            if let reframe, reframe.confidence >= 0.42 {
                decidedVideo.subjectReframe = reframe
                videoReasons.append(contentsOf: reframe.reasons)
            }
            if item.kind == .photo {
                let motion: ClipEffect
                if let reframe {
                    if reframe.endCenterX > reframe.startCenterX + 0.025 { motion = .panRight }
                    else if reframe.endCenterX < reframe.startCenterX - 0.025 { motion = .panLeft }
                    else { motion = .kenBurns }
                } else {
                    let motions: [ClipEffect] = [.kenBurns, .panLeft, .zoomOut, .panRight]
                    motion = motions[position % motions.count]
                }
                calls.append(.setMotion(itemID: item.id, effect: motion, reason: reframe == nil ? "Фото получает спокойное осмысленное движение" : "Subject-aware Ken Burns удерживает главный объект"))
                if let semanticEffect,
                   Self.shouldApply(density: grammar?.effectDensity ?? 0.18, position: position, salt: 19) {
                    calls.append(.addEffect(
                        type: semanticEffect.type,
                        startTime: item.timelineStart,
                        duration: item.timelineDuration,
                        targetClipID: item.id,
                        reason: semanticEffect.explanation
                    ))
                }
            } else {
                let frameRate = item.assetID.flatMap { assetsByID[$0]?.metadata.frameRate } ?? 30
                let slowSuitability = candidate.insights?.slowMotionSuitability
                    ?? min(1, candidate.scores.action * 0.65 + candidate.scores.stability * 0.35)
                let rampSuitability = candidate.insights?.speedRampSuitability
                    ?? min(1, candidate.scores.action * 0.75 + candidate.scores.interest * 0.25)
                let measuredDynamics = candidate.insights?.dynamics ?? candidate.scores.action
                if plan.constraints.allowSlowMotion,
                   role == .climax,
                   frameRate >= 50,
                   candidate.scores.action >= 0.78,
                   measuredDynamics >= 0.76,
                   slowSuitability >= 0.84 {
                    calls.append(.setSpeed(itemID: item.id, rate: 0.5, reason: "Высокая частота кадров и сильная кульминация подходят для slow motion"))
                    decidedVideo.smoothSlowMotion = true
                    videoReasons.append("сглаживание кульминационного замедления")
                } else if role == .action, rampSuitability >= 0.72, item.sourceDuration >= 2.5,
                          Self.shouldApply(density: grammar?.speedRampDensity ?? 0.22, position: position, salt: 31) {
                    calls.append(.setSpeedRamp(itemID: item.id, ramp: .action, reason: "Speed ramp подчёркивает рост действия, не превращая весь фильм в ускорение"))
                }

                if candidate.scores.stability < 0.56 || (candidate.insights?.shake ?? 0) > 0.48 {
                    decidedVideo.stabilization = min(0.72, max(0.30, 1 - candidate.scores.stability))
                    videoReasons.append("стабилизация технически слабого кадра")
                }
                if let semanticEffect,
                   Self.shouldApply(density: grammar?.effectDensity ?? 0.12, position: position, salt: 47) {
                    calls.append(.addEffect(
                        type: semanticEffect.type,
                        startTime: item.timelineStart,
                        duration: item.timelineDuration,
                        targetClipID: item.id,
                        reason: semanticEffect.explanation
                    ))
                }
            }

            if candidate.scores.quality < 0.62 || (candidate.insights?.exposureQuality ?? 1) < 0.58 {
                decidedVideo.exposure = max(decidedVideo.exposure ?? 0, 0.12)
                decidedVideo.contrast = max(decidedVideo.contrast, 1.06)
                decidedVideo.saturation = max(decidedVideo.saturation, 1.04)
                videoReasons.append("лёгкая коррекция измеренных проблем изображения")
            }
            if decidedVideo != item.effectiveVideoAdjustments {
                calls.append(.setVideoAdjustments(
                    itemID: item.id,
                    adjustments: decidedVideo,
                    reason: videoReasons.joined(separator: "; ")
                ))
            }

            let audioUsefulness = candidate.insights?.originalAudioUsefulness
                ?? (candidate.tags.contains("people") || candidate.tags.contains("action") ? 0.72 : 0.35)
            if assetsByID[candidate.assetID]?.metadata.hasAudio == true {
                let speech = candidate.insights?.speech
                let usefulEvent = candidate.insights?.audioEvents?.contains { [.impact, .splash, .laughter, .applause, .scream].contains($0.kind) && $0.confidence >= 0.52 } == true
                let audible = role == .action || role == .climax || audioUsefulness >= 0.68 || (speech?.confidence ?? 0) >= 0.48 || usefulEvent
                let fadeIn = speech.map { min(0.18, max(0.04, $0.silenceBefore * 0.45)) } ?? 0.12
                let fadeOut = speech.map { min(0.22, max(0.05, $0.silenceAfter * 0.45)) } ?? 0.18
                let audio = AudioAdjustments(volume: audible ? 0.92 : 0.38, fadeIn: fadeIn, fadeOut: fadeOut, noiseReduction: audioUsefulness < 0.4 ? 0.25 : 0, eqPreset: speech == nil ? .flat : .voice)
                let reason = speech != nil
                    ? "ASR phrase boundaries и полезная речь сохранены целиком"
                    : usefulEvent ? "Синхронное аудиособытие усиливает момент" : audible ? "Полезный реальный звук сохраняет присутствие" : "Фоновый звук уступает место музыке"
                calls.append(.setAudioAdjustments(itemID: item.id, adjustments: audio, reason: reason))
            }

            // TimelineComposer owns automatic telemetry accents because it can
            // trim an independent overlay exactly around the detected sensor
            // event. Applying the legacy clip-wide setting here would turn it
            // into a permanent HUD and duplicate the Timeline object.

            if position > 0,
               let decision = item.incomingEditDecision,
               decision.choice == .transition,
               let style = decision.transitionStyle {
                calls.append(.setTransition(itemID: item.id, transition: style, reason: decision.motivation))
            }
        }

        if timeline.music != nil, primaries.contains(where: { ($0.effectiveAudioAdjustments.effectiveVolume) > 0.55 }) {
            calls.append(.setDucking(AudioDuckingSettings(enabled: true, attenuation: 0.34, attack: 0.16, release: 0.34), reason: "Музыка автоматически уступает полезному оригинальному звуку"))
        }
        if let music = timeline.music,
           (music.autonomousIntent?.beatSyncIntensity ?? 0.72) >= 0.30 {
            calls.append(.syncToBeat(bpm: music.bpm, reason: "Эффекты и монтажные акценты синхронизированы с битовой сеткой выбранного трека"))
        }
        if timeline.effectiveTitleItems.isEmpty,
           let firstChapter = plan.chapters.first,
           (grammar?.titleDensity ?? 0.15) >= 0.055 {
            let titleCandidates = firstChapter.candidateIDs.compactMap { candidates[$0] }
            let titleAssets = titleCandidates.compactMap { assetsByID[$0.assetID] }
            let tags = titleCandidates.reduce(into: Set<String>()) { $0.formUnion($1.tags) }
            let requested = plan.eventStory?.projectTitle ?? firstChapter.chapterCardTitle ?? firstChapter.title
            let avoidRegions = titleCandidates.compactMap { candidate in
                candidate.insights?.subjectTracking?.mainSubject?.observations
                    .max(by: { $0.confidence * $0.region.area < $1.confidence * $1.region.area })?.region
            }
            let decision = SmartTitleEngine().decide(SmartTitleContext(
                purpose: .filmOpening,
                requestedText: requested,
                tags: tags,
                summaries: titleCandidates.compactMap { $0.insights?.sceneSummary },
                captureDate: titleAssets.compactMap { $0.metadata.effectiveCaptureDate }.min(),
                dateAddsContext: (plan.eventStory?.entries.count ?? 0) > 1,
                usedTitles: timeline.effectiveTitleItems.map(\.text),
                avoidRegions: avoidRegions,
                preferredTemplateID: plan.preset == .cinematic ? "title.cinematic.v1" : nil
            ))
            if let decision, let template = TitleTemplateRegistry.template(id: decision.templateID) {
                calls.append(.addTitleObject(
                    text: decision.primaryText,
                    kind: template.kind,
                    templateID: template.id,
                    startTime: 0,
                    duration: decision.duration,
                    reason: "AI Director выбрал содержание и существующий шаблон: \(decision.explanation.joined(separator: "; "))"
                ))
            }
        }

        let selectedIDs = Set(primaries.compactMap(\.candidateID))
        let candidatesByID = Dictionary(uniqueKeysWithValues: analyses.flatMap(\.directorCandidates).map { ($0.id, $0) })
        var unusedBroll = analyses.flatMap(\.directorCandidates)
            .filter { !selectedIDs.contains($0.id) && !$0.excluded }
        let bases = primaries.filter { $0.storyRole == .setup || $0.storyRole == .buildup || $0.storyRole == .action }
        let desiredBroll = grammar.map { Int((Double(primaries.count) * $0.bRollFrequency).rounded()) }
            ?? max(0, primaries.count / 7)
        let overlayCount = min(unusedBroll.count, min(3, desiredBroll))
        for index in 0..<overlayCount where bases.indices.contains(index) {
            let base = bases[index]
            guard let baseCandidateID = base.candidateID, let baseCandidate = candidatesByID[baseCandidateID],
                  let candidate = unusedBroll.max(by: {
                      Self.bRollFit($0, base: baseCandidate, role: base.storyRole) < Self.bRollFit($1, base: baseCandidate, role: base.storyRole)
                  }) else { continue }
            unusedBroll.removeAll { $0.id == candidate.id }
            let duration = min(candidate.sourceDuration, max(1.2, min(3.2, base.timelineDuration * 0.62)))
            let purpose = (baseCandidate.insights?.speech?.confidence ?? 0) >= 0.48
                ? "B-roll визуализирует контекст фразы, сохраняя непрерывный голос основного кадра"
                : base.storyRole == .action
                    ? "B-roll уточняет деталь действия, не подменяя его случайным красивым планом"
                    : "B-roll устанавливает среду и поддерживает конкретную функцию основной сцены"
            calls.append(.insertOverlay(candidateID: candidate.id, baseItemID: base.id, sourceStart: candidate.sourceStart, sourceDuration: duration, style: .cutaway, reason: purpose))
        }
        return calls
    }

    private static func shouldApply(density: Double, position: Int, salt: Int) -> Bool {
        let threshold = density.clamped01
        guard threshold > 0 else { return false }
        let deterministic = Double((position &* 37 &+ salt) % 100) / 100
        return deterministic < threshold
    }

    private func repairCalls(
        for review: DirectorReview,
        timeline: Timeline,
        plan: StoryPlan,
        analyses: [AnalysisResult]
    ) -> [DirectorToolCall] {
        let allCandidates = analyses.flatMap(\.directorCandidates).filter { !$0.excluded }
        let used = Set(timeline.items.compactMap(\.candidateID))
        let primaries = timeline.items.filter { $0.kind != .title && $0.overlay == nil }
        let rankingContext = HighlightRankingContext(prompt: plan.prompt, preset: plan.preset, constraints: plan.constraints)
        let ranker = ContextualHighlightRanker()
        var calls: [DirectorToolCall] = []
        func phaseRange(_ candidate: Candidate, maximum: Double) -> MomentTrimRange {
            MomentPhaseTrimmer().range(for: candidate, desiredDuration: min(candidate.sourceDuration, maximum))
        }

        for issue in review.issues.sorted(by: { $0.severity > $1.severity }) {
            switch issue.kind {
            case .weakOpening:
                guard let target = issue.itemIDs.first,
                      let candidate = allCandidates.filter({ !used.contains($0.id) }).max(by: { Self.introScore($0, constraints: plan.constraints) < Self.introScore($1, constraints: plan.constraints) }) else { continue }
                let range = phaseRange(candidate, maximum: 6.5)
                calls.append(.replace(itemID: target, candidateID: candidate.id, sourceStart: range.sourceStart, sourceDuration: range.sourceDuration, role: .intro, reason: "Self-review заменил слабое открытие более ясным и выразительным кадром"))

            case .weakClimax:
                guard let target = issue.itemIDs.first ?? primaries.first(where: { $0.storyRole == .action })?.id,
                      let candidate = allCandidates.max(by: { TimelineSelfReviewer.climaxScore($0) < TimelineSelfReviewer.climaxScore($1) }) else { continue }
                let range = phaseRange(candidate, maximum: 5.5)
                calls.append(.replace(itemID: target, candidateID: candidate.id, sourceStart: range.sourceStart, sourceDuration: range.sourceDuration, role: .climax, reason: "Self-review ставит самый сильный подтверждённый action-момент в кульминацию"))

            case .repeatedRange, .repeatedScene:
                guard let target = issue.itemIDs.last,
                      let targetItem = timeline.items.first(where: { $0.id == target }),
                      let replacement = allCandidates.filter({ !used.contains($0.id) && $0.assetID != targetItem.assetID }).max(by: {
                          ranker.score($0, asset: nil, context: rankingContext) < ranker.score($1, asset: nil, context: rankingContext)
                      }) else { continue }
                let range = phaseRange(replacement, maximum: targetItem.sourceDuration)
                calls.append(.replace(itemID: target, candidateID: replacement.id, sourceStart: range.sourceStart, sourceDuration: range.sourceDuration, role: targetItem.storyRole ?? .buildup, reason: "Self-review убирает визуальный повтор и возвращает разнообразие"))

            case .lowQualityShot:
                for target in issue.itemIDs {
                    guard let targetItem = timeline.items.first(where: { $0.id == target }) else { continue }
                    if primaries.count - calls.filter({ $0.tool == .rippleDelete }).count > 5 {
                        calls.append(.rippleDelete(itemID: target, reason: "Self-review удаляет технически слабый кадр"))
                    } else if let replacement = allCandidates
                        .filter({ !used.contains($0.id) && $0.assetID != targetItem.assetID && $0.scores.quality >= 0.62 })
                        .max(by: { ranker.score($0, asset: nil, context: rankingContext) < ranker.score($1, asset: nil, context: rankingContext) }) {
                        let range = phaseRange(replacement, maximum: targetItem.sourceDuration)
                        calls.append(.replace(itemID: target, candidateID: replacement.id, sourceStart: range.sourceStart, sourceDuration: range.sourceDuration, role: targetItem.storyRole ?? .buildup, reason: "Self-review заменяет технически слабый кадр"))
                    }
                }

            case .actionImbalance:
                let wantsAction = plan.constraints.pacing >= 0.68
                guard let target = primaries
                    .filter({ !$0.locked })
                    .min(by: { left, right in
                        let leftScore = left.candidateID.flatMap { id in allCandidates.first(where: { $0.id == id })?.scores.action } ?? 0.5
                        let rightScore = right.candidateID.flatMap { id in allCandidates.first(where: { $0.id == id })?.scores.action } ?? 0.5
                        return wantsAction ? leftScore < rightScore : leftScore > rightScore
                    }),
                      let replacement = allCandidates
                        .filter({ !used.contains($0.id) })
                        .max(by: { wantsAction ? $0.scores.action < $1.scores.action : $0.scores.action > $1.scores.action }) else { continue }
                let range = phaseRange(replacement, maximum: target.sourceDuration)
                calls.append(.replace(itemID: target.id, candidateID: replacement.id, sourceStart: range.sourceStart, sourceDuration: range.sourceDuration, role: target.storyRole ?? .action, reason: "Self-review восстанавливает баланс action и спокойных сцен"))

            case .overlongClip:
                for id in issue.itemIDs {
                    guard let item = timeline.items.first(where: { $0.id == id }) else { continue }
                    let duration = min(item.sourceDuration, TimelineSelfReviewer.maximumDuration(for: item.storyRole, pacing: plan.constraints.pacing))
                    if let candidateID = item.candidateID, let candidate = allCandidates.first(where: { $0.id == candidateID }) {
                        let range = phaseRange(candidate, maximum: duration)
                        calls.append(.trim(itemID: id, sourceStart: range.sourceStart, sourceDuration: range.sourceDuration, reason: "Self-review сокращает затянутый участок, сохраняя peak и reaction"))
                    } else {
                        calls.append(.trim(itemID: id, sourceStart: item.sourceStart, sourceDuration: duration, reason: "Self-review сокращает затянутый участок"))
                    }
                }

            case .pacingTooSlow:
                let slowest = primaries.filter { !$0.locked }.sorted { $0.timelineDuration > $1.timelineDuration }.prefix(max(1, primaries.count / 4))
                for item in slowest {
                    let duration = max(1.2, item.sourceDuration * 0.72)
                    if let candidateID = item.candidateID, let candidate = allCandidates.first(where: { $0.id == candidateID }) {
                        let range = phaseRange(candidate, maximum: duration)
                        calls.append(.trim(itemID: item.id, sourceStart: range.sourceStart, sourceDuration: range.sourceDuration, reason: "Self-review увеличивает плотность действия вокруг peak"))
                    } else {
                        calls.append(.trim(itemID: item.id, sourceStart: item.sourceStart, sourceDuration: duration, reason: "Self-review увеличивает плотность действия"))
                    }
                }

            case .transitionOverload:
                for (offset, item) in primaries.filter({ $0.transition != nil }).enumerated() where offset % 2 == 0 {
                    calls.append(.setTransition(itemID: item.id, transition: nil, reason: "Self-review заменяет лишний эффект профессиональной прямой склейкой"))
                }

            case .cutDensityTooHigh, .missingStoryArc:
                continue
            }
        }
        return calls
    }

    private static func introScore(_ candidate: Candidate, constraints: StoryConstraints) -> Double {
        let preferred = constraints.preferredIntroTags?.isDisjoint(with: candidate.tags) == false ? 0.35 : 0
        let atmosphere = candidate.tags.contains("atmosphere") || candidate.tags.contains("nature") || candidate.tags.contains("landscape") ? 0.18 : 0
        return candidate.scores.interest * 0.34 + candidate.scores.quality * 0.28 + candidate.scores.stability * 0.20 + (candidate.insights?.roleScores[.intro] ?? 0.5) * 0.18 + preferred + atmosphere
    }

    private static func bRollScore(_ candidate: Candidate) -> Double {
        candidate.scores.quality * 0.30 + candidate.scores.interest * 0.28 + candidate.scores.stability * 0.27 + (candidate.insights?.composition ?? 0.5) * 0.15
    }

    private static func bRollFit(_ candidate: Candidate, base: Candidate, role: StoryRole?) -> Double {
        let sharedTags = candidate.tags.intersection(base.tags)
        let semantic = Double(sharedTags.count) / Double(max(1, candidate.tags.union(base.tags).count))
        let visualDifference = abs((candidate.insights?.composition ?? candidate.scores.quality) - (base.insights?.composition ?? base.scores.quality))
        let detailBoost = candidate.tags.contains("detail") || candidate.tags.contains("close-up") ? 0.12 : 0
        let roleBoost = role == .action ? candidate.scores.action * 0.08 : candidate.scores.stability * 0.08
        return bRollScore(candidate) * 0.52 + semantic * 0.28 + min(0.14, visualDifference * 0.20) + detailBoost + roleBoost
    }
}
