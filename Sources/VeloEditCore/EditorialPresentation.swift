import Foundation

public enum EditorialPresentationPolicy {
    /// Exact compact chapter typography of the approved film reference.
    /// Explicit values keep template/default-font changes from altering it.
    static let compactChapterStyle = TitleStyle(fontSize: 72, textColorHex: "#FFFFFF",
        backgroundColorHex: "#111111", alignment: .left, fontFamily: "Avenir Next", fontWeight: 0.88,
        xPosition: 0.36, yPosition: 0.78, shadow: 0.25, backgroundOpacity: 0.75)

    static func hardeningReadability(_ title: TitleTimelineItem) -> TitleTimelineItem {
        guard title.userEdited != true else { return title }
        var value = title
        if AutomatedTitlePolicy.isGenerated(title), title.kind == .chapter,
           title.explanation.contains(where: { $0.hasPrefix("Rendered OCR repair:") }),
           title.style.fontFamily == "Helvetica Neue" {
            value.style = compactChapterStyle
            value.templateID = "title.minimal-clean.v1"
        }
        value.style.backgroundOpacity = 1
        value.style.strokeWidth = max(value.style.strokeWidth ?? 0, 1.5)
        value.style.shadow = max(value.style.shadow ?? 0, 0.45)
        value.style.opacity = 1
        value.animation = TitleAnimation(entrance: .none, exit: .none, duration: 0)
        value.targetClipID = nil
        let reason = "Rendered OCR repair: high-contrast static title"
        if !value.explanation.contains(reason) { value.explanation.append(reason) }
        return value
    }

    /// Generation is idempotent: rebuilding a film may reuse its opening.
    /// Share the same visibility check with the transaction's intent verifier.
    public static func hasReadableTitle(in timeline: Timeline) -> Bool {
        timeline.effectiveTitleItems.contains { title in
            title.enabled && !title.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && title.startTime.isFinite && title.duration.isFinite
                && title.startTime >= 0 && title.duration >= 1.25
                && title.endTime <= timeline.duration + 0.000_001
        }
    }

    /// Sparse photo albums may have no confirmed activity/chapter name. An
    /// explicit title request still gets a neutral opening, before render QA.
    public static func ensuringRequestedTitle(in source: Timeline, plan: StoryPlan) -> Timeline {
        guard EditorialIntentEnforcer.requestsAdditionalTitles(plan.prompt),
              !ExplicitDeliveryRequirements(plan: plan).forbidsTitles,
              !hasReadableTitle(in: source), source.duration.isFinite, source.duration >= 1.25 else { return source }
        let media = source.items.filter { $0.overlay == nil && $0.kind != .title }
            .sorted { $0.timelineStart < $1.timelineStart }
        guard let first = media.first, source.duration - first.timelineStart >= 1.25 else { return source }
        let chapter = plan.chapters.first { chapter in media.contains { item in item.candidateID.map(chapter.candidateIDs.contains) == true } }
        let proposed = chapter?.chapterCardTitle ?? chapter?.title
        let visualStyle = DirectorVisualStyle(plan: plan)
        let decision = SmartTitleEngine().decide(.init(purpose: .filmOpening, requestedText: proposed, mood: visualStyle.mood))
        let kinds = Set(media.map(\.kind))
        let neutral = kinds == [.photo] ? "Фотоистория" : kinds == [.video] ? "Видеоистория" : "История в кадрах"
        let text = decision?.primaryText ?? neutral
        var timeline = source
        let template = TitleTemplateRegistry.template(id: visualStyle.templateID(for: .filmOpening))!
        let title = TitleTimelineItem(kind: template.kind, templateID: template.id, text: text,
            startTime: first.timelineStart, duration: min(source.duration - first.timelineStart, visualStyle.duration(text: text, purpose: .filmOpening)),
            style: visualStyle.style(for: template), animation: TitleAnimation(entrance: .none),
            explanation: ["Автоматический титр по явному запросу; резерв для материала без названия события"])
        timeline.titleItems = AutomatedTitlePolicy.reviewed(source.effectiveTitleItems + [title], timelineDuration: source.duration).titles
        return timeline
    }

    public static func chapters(in source: Timeline, plan: StoryPlan) -> Timeline {
        if requiresChapterTitles(plan) || source.filmParts != nil { return ensuringChapterTitles(in: source, plan: plan, preserveExistingPresentation: source.filmParts != nil) }
        guard plan.narrativeBeatPlan != nil, !ExplicitDeliveryRequirements(plan: plan).forbidsTitles else { return source }
        var timeline = source
        let items = timeline.items.filter { $0.overlay == nil && $0.kind != .title }.sorted { $0.timelineStart < $1.timelineStart }
        let visualStyle = DirectorVisualStyle(plan: plan)
        let asksTitles = EditorialIntentEnforcer.requestsAdditionalTitles(plan.prompt)
        guard plan.eventStory?.chapterCardsEnabled == true || asksTitles else { return timeline }
        let automaticChapters = timeline.effectiveTitleItems.filter { title in
            title.kind == .chapter && title.explanation.contains { $0.localizedCaseInsensitiveContains("автомат") || $0.contains("Editorial chapter") }
        }
        let automaticIDs = Set(automaticChapters.map(\.id))
        timeline.titleItems = timeline.effectiveTitleItems.filter { !automaticIDs.contains($0.id) }
        let titleEveryActivityBlock = plan.directorBrief?.titlePolicy == .keyOnly
        // Narrative beats can split one activity into several short shots.
        // Readability belongs to the complete contiguous part, not its first shot.
        var blocks: [(eventID: UUID?, text: String, items: [TimelineItem])] = []
        for item in items {
            let chapter = item.candidateID.flatMap { candidateID in
                plan.chapters.first { $0.candidateIDs.contains(candidateID) }
            }
            let text = (chapter?.chapterCardTitle ?? chapter?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let eventID = chapter?.eventID ?? item.eventID
            if let last = blocks.last, last.eventID == eventID, last.text == text {
                blocks[blocks.count - 1].items.append(item)
            } else {
                blocks.append((eventID, text, [item]))
            }
        }
        var used = Set<String>()
        var reusedTitleIDs = Set<UUID>()
        var blockContainment: [UUID: ClosedRange<Double>] = [:]
        for block in blocks {
            let text = block.text
            guard let item = block.items.first,
                  let end = block.items.map({ $0.timelineStart + $0.timelineDuration }).max(),
                  !SmartTitleEngine.isPlaceholderTitle(text),
                  titleEveryActivityBlock || !used.contains(text), end - item.timelineStart >= 1.25 else { continue }
            used.insert(text)
            if timeline.effectiveTitleItems.contains(where: {
                $0.text == text && (!titleEveryActivityBlock || ($0.startTime < end && $0.endTime > item.timelineStart))
            }) { continue }
            let duration = min(end - item.timelineStart, visualStyle.duration(text: text, purpose: .chapter))
            // A short chapter replaces an automatic opening that otherwise
            // consumes its whole readable interval. User-authored titles stay.
            timeline.titleItems = timeline.effectiveTitleItems.filter { existing in
                let overlaps = existing.startTime < item.timelineStart + duration && existing.endTime > item.timelineStart
                let automatic = existing.explanation.contains { $0.contains("Автомат") || $0.contains("авто") || $0.contains("event hierarchy") }
                return !(overlaps && automatic)
            }
            var titles = timeline.effectiveTitleItems
            let reusable = automaticChapters.filter { $0.text == text && !reusedTitleIDs.contains($0.id) }
                .min { abs($0.startTime - item.timelineStart) < abs($1.startTime - item.timelineStart) }
            var title = reusable ?? TitleTimelineItem(kind: .chapter, templateID: "title.minimal-clean.v1", text: text, startTime: item.timelineStart, duration: duration, targetClipID: item.id, explanation: ["Editorial chapter: подтверждённая смена события/активности"])
            reusedTitleIDs.insert(title.id)
            let template = TitleTemplateRegistry.template(id: visualStyle.templateID(for: .chapter))!
            title.templateID = template.id
            title.style = visualStyle.style(for: template)
            title.animation.entrance = .none
            title.startTime = item.timelineStart
            title.duration = duration
            title.targetClipID = item.timelineDuration >= duration ? item.id : nil
            title.anchorClipID = item.id
            titles.append(title)
            blockContainment[title.id] = item.timelineStart...end
            let containment = AutomatedTitlePolicy.inferredContainmentByTitleID(titles, timeline: timeline)
                .merging(blockContainment) { _, block in block }
            timeline.titleItems = AutomatedTitlePolicy.reviewed(titles, timelineDuration: timeline.duration, containmentByTitleID: containment).titles
        }
        return timeline
    }

    public static func requiresChapterTitles(_ plan: StoryPlan) -> Bool {
        !ExplicitDeliveryRequirements(plan: plan).forbidsTitles
            && (plan.directorBrief?.titlePolicy == .keyOnly || DirectorRequestContract.requestsChapterTitles(plan.prompt))
    }

    public struct ChapterBlock: Sendable {
        public var partID: UUID? = nil
        public var text: String
        public var eventID: UUID?
        public var sceneID: UUID?
        public var items: [TimelineItem]
        public var start: Double { items[0].timelineStart }
        public var end: Double { items.map { $0.timelineStart + $0.timelineDuration }.max() ?? start }
    }

    /// Resolve a label across the entire scene before placing anything. A
    /// cold-open beat without a card must not delay its part's title.
    public static func chapterBlocks(in timeline: Timeline, plan: StoryPlan) -> [ChapterBlock] {
        let media = timeline.items.filter { $0.overlay == nil && $0.kind != .title }.sorted { $0.timelineStart < $1.timelineStart }
        if timeline.filmParts != nil {
            return FilmPartPolicy.parts(in: timeline, plan: plan).enumerated().compactMap { index, part in
                let ids = Set(part.itemIDs)
                let items = media.filter { ids.contains($0.id) }
                guard let first = items.first else { return nil }
                let manual = timeline.effectiveTitleItems.first {
                    $0.kind == .chapter && !AutomatedTitlePolicy.isGenerated($0)
                        && ($0.filmPartID == part.id || abs($0.startTime - first.timelineStart) < 0.001)
                }
                let text = manual?.text ?? timeline.chapterTitleDecisions?.first { $0.partID == part.id }?.text
                    ?? "Часть \(index + 1)"
                return ChapterBlock(partID: part.id, text: text, eventID: part.eventID, sceneID: nil, items: items)
            }
        }
        func usable(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !SmartTitleEngine.isPlaceholderTitle(text) else { return nil }
            return text
        }
        var blocks: [ChapterBlock] = []
        var unnamedScopes: [UUID] = []
        for item in media {
            let chapter = item.candidateID.flatMap { id in plan.chapters.first { $0.candidateIDs.contains(id) } }
            let eventID = chapter?.eventID ?? item.eventID
            let sceneID = chapter?.eventSceneID ?? item.eventSceneID
            let siblings = plan.chapters.filter {
                if let sceneID { return $0.eventSceneID == sceneID }
                if let eventID { return $0.eventID == eventID }
                return $0.id == chapter?.id
            }
            let event = eventID.flatMap { id in plan.eventStory?.entries.first { $0.eventID == id } }
            let existingLabel = chapter == nil ? timeline.effectiveTitleItems.first {
                $0.enabled && $0.kind == .chapter && abs($0.startTime - item.timelineStart) < 0.001
            }?.text : nil
            let scope = sceneID ?? eventID ?? item.assetID ?? item.id
            if !unnamedScopes.contains(scope) { unnamedScopes.append(scope) }
            // Prefer the scene's actual name over an inherited event card.
            // Dates and neutral numbered parts cover uncertain recognition;
            // missing semantics must not silently remove a requested title.
            let text = usable(chapter?.title)
                ?? siblings.compactMap { usable($0.chapterCardTitle) }.first
                ?? usable(event?.title)
                ?? usable(existingLabel)
                ?? "Часть \((unnamedScopes.firstIndex(of: scope) ?? 0) + 1)"
            if let last = blocks.last, last.eventID == eventID, last.sceneID == sceneID {
                blocks[blocks.count - 1].items.append(item)
            } else {
                blocks.append(ChapterBlock(text: text, eventID: eventID, sceneID: sceneID, items: [item]))
            }
        }
        return blocks
    }

    public static func missingChapterTitles(in timeline: Timeline, plan: StoryPlan) -> [ChapterBlock] {
        guard requiresChapterTitles(plan) else { return [] }
        let tolerance = 1 / max(1, timeline.frameRate)
        let titles = timeline.effectiveTitleItems
        var missing: [ChapterBlock] = []
        for block in chapterBlocks(in: timeline, plan: plan) {
            guard block.end - block.start >= 1.25 else { continue }
            let covered = titles.contains { title in
                if block.partID != nil && title.kind != .chapter { return false }
                guard title.enabled, (title.text == block.text || title.userEdited == true),
                      !title.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      (title.style.opacity ?? 1) > 0 else { return false }
                guard abs(title.startTime - block.start) <= tolerance else { return false }
                return title.duration >= 1.25 && title.endTime <= block.end + tolerance
            }
            if !covered { missing.append(block) }
        }
        return missing
    }

    public static func ensuringChapterTitles(in source: Timeline, plan: StoryPlan, preserveExistingPresentation: Bool = false) -> Timeline {
        guard !ExplicitDeliveryRequirements(plan: plan).forbidsTitles,
              requiresChapterTitles(plan) || source.filmParts != nil else { return source }
        var timeline = source
        let blocks = chapterBlocks(in: source, plan: plan)
        let visualStyle = DirectorVisualStyle(plan: plan)
        let automatic = source.effectiveTitleItems.filter { title in
            AutomatedTitlePolicy.isGenerated(title)
        }
        let blockLabels = Set(blocks.map(\.text))
        let replaceable = automatic.filter { title in
            guard ![.subtitle, .automaticSubtitles, .wordLevelCaptions].contains(title.kind) else { return false }
            if source.filmParts != nil {
                return title.kind == .chapter || title.explanation.contains {
                    $0.contains("глава события") || $0.contains("event hierarchy") || $0.contains("Editorial chapter")
                } || blocks.first.map { title.startTime < min($0.end, $0.start + 3.5) } == true
            }
            // A requested chapter heading replaces an automatic event opener
            // occupying the same interval, even when their wording differs.
            let overlapsHeading = blocks.contains { block in
                let headingEnd = min(block.end, block.start + visualStyle.duration(text: block.text, purpose: .chapter))
                return title.startTime < headingEnd && title.endTime > block.start
            }
            return blockLabels.contains(title.text) || title.explanation.contains { $0.contains("Editorial chapter") } || overlapsHeading
        }
        let automaticIDs = Set(replaceable.map(\.id))
        var titles = source.effectiveTitleItems.filter { !automaticIDs.contains($0.id) }
        var used = Set<UUID>()
        for block in blocks where block.end - block.start >= 1.25 {
            if let manualIndex = titles.firstIndex(where: {
                $0.kind == .chapter && !AutomatedTitlePolicy.isGenerated($0)
                    && ($0.filmPartID == block.partID && block.partID != nil || abs($0.startTime - block.start) < 0.001)
            }) {
                titles[manualIndex].filmPartID = block.partID
                continue
            }
            if titles.contains(where: { (block.partID == nil || $0.kind == .chapter) && $0.enabled && $0.text == block.text && abs($0.startTime - block.start) < 0.001 && $0.duration >= 1.25 && $0.endTime <= block.end }) { continue }
            let existing = replaceable.filter {
                !used.contains($0.id) && (block.partID != nil
                    ? $0.filmPartID == block.partID || ($0.kind == .chapter && abs($0.startTime - block.start) < 0.001)
                    : $0.text == block.text)
            }
                .min { abs($0.startTime - block.start) < abs($1.startTime - block.start) }
            var title = existing ?? TitleTimelineItem(kind: .chapter, templateID: "title.minimal-clean.v1", text: block.text, startTime: block.start, duration: 2.5)
            used.insert(title.id)
            title.kind = .chapter
            title.filmPartID = block.partID
            title.text = block.text
            title.startTime = block.start
            let requestedDuration = plan.chapterTitleReference?.duration ?? max(plan.preferredChapterTitleDuration ?? 3.5, 3.5, 2.2 + Double(block.text.count) / 12)
            title.duration = min(block.end - block.start, block.partID != nil && existing != nil ? max(title.duration, requestedDuration) : requestedDuration)
            let hasReadabilityRepair = title.explanation.contains { $0.hasPrefix("Rendered OCR repair:") }
            let legacyCompact = title.templateID == "title.minimal-clean.v1" &&
                title.style == TitleStyle(fontSize: 72, backgroundColorHex: "#101010", xPosition: 0.36, yPosition: 0.78, backgroundOpacity: 0.75)
            if !(preserveExistingPresentation && existing != nil) || (block.partID == nil && (legacyCompact || plan.chapterTitleReference != nil || hasReadabilityRepair)) {
                title.templateID = "title.minimal-clean.v1"
                title.style = plan.chapterTitleReference?.style ?? compactChapterStyle
                title.animation = plan.chapterTitleReference?.animation ?? TitleAnimation(entrance: .none, exit: .none, duration: 0)
                if hasReadabilityRepair { title = hardeningReadability(title) }
            }
            // A heading belongs to the whole part. Attaching a five-second
            // title to its first two-second shot makes the compositor hide it
            // at that cut while OCR still expects it to be on screen.
            title.targetClipID = nil
            title.anchorClipID = source.items.first { $0.overlay == nil && abs($0.timelineStart - block.start) < 0.001 }?.id
            title.enabled = true
            // A part begins with a visible title, including the first frame.
            if block.partID == nil || existing == nil {
                title.animation.entrance = .none
                title.style.opacity = 1
            }
            let reason = "Editorial chapter: автоматический титр в начале каждой части"
            if !title.explanation.contains(reason) { title.explanation.append(reason) }
            titles.append(title)
        }
        timeline.titleItems = titles.sorted { $0.startTime < $1.startTime }
        return timeline
    }

    /// Apply the selected mood to generated openings and event labels too.
    /// Subtitles keep their speech timing; manually authored titles keep their edits.
    public static func stylingGeneratedTitles(in source: Timeline, plan: StoryPlan) -> Timeline {
        var timeline = source
        let visualStyle = DirectorVisualStyle(plan: plan)
        let blocks = chapterBlocks(in: source, plan: plan)
        timeline.titleItems = source.effectiveTitleItems.map { original in
            guard AutomatedTitlePolicy.isGenerated(original),
                  !(original.kind == .chapter && (requiresChapterTitles(plan) || source.filmParts != nil)),
                  ![.subtitle, .automaticSubtitles, .wordLevelCaptions].contains(original.kind),
                  !original.explanation.contains(where: { $0.hasPrefix("Rendered OCR repair:") }) else { return original }
            var title = original
            if SmartTitleEngine.isPlaceholderTitle(title.text, allowsNumericText: title.kind == .date) {
                // Old/generated beat labels are internal structure. Replace
                // them before rendering, preserving an explicit title request.
                let blockIndex = blocks.firstIndex { title.startTime >= $0.start && title.startTime < $0.end }
                let label = blockIndex.map { blocks[$0].text }
                title.text = label.flatMap { SmartTitleEngine.isPlaceholderTitle($0) ? nil : $0 }
                    ?? (title.kind == .chapter ? "Часть \((blockIndex ?? 0) + 1)" : "История в кадрах")
            }
            let purpose: SmartTitlePurpose
            switch title.kind {
            case .chapter: purpose = .chapter
            case .endCard: purpose = .ending
            case .location: purpose = .location
            case .date: purpose = .dateChronicle
            default: purpose = title.startTime < 0.001 ? .filmOpening : .activity
            }
            if let template = TitleTemplateRegistry.template(id: visualStyle.templateID(for: purpose)) {
                title.templateID = template.id
                title.style = visualStyle.style(for: template)
            }
            let blockEnd = blocks.first { title.startTime >= $0.start && title.startTime < $0.end }?.end ?? source.duration
            let next = source.effectiveTitleItems.filter {
                $0.enabled && $0.track == title.track && $0.id != title.id && $0.startTime > title.startTime
            }.map(\.startTime).min().map { $0 - 0.08 } ?? source.duration
            let available = max(0.05, min(blockEnd, next, source.duration) - title.startTime)
            title.duration = min(available, visualStyle.duration(text: title.text, secondary: title.additionalText, purpose: purpose))
            if purpose == .chapter || title.startTime < 0.001 { title.animation.entrance = .none }
            return title
        }
        return timeline
    }
}

extension EditorialIntentEnforcer {
    /// Resolve the latest title instruction locally, so an unrelated "add
    /// music" never turns a mention of titles into a mandatory title request.
    public static func titleRequest(_ prompt: String) -> Bool? {
        var result: Bool?
        for clause in prompt.lowercased().components(separatedBy: CharacterSet(charactersIn: ".!?;\n")) {
            let mentionsTitle = ["титр", "title", "caption", "надпис"].contains(where: clause.contains)
            guard mentionsTitle else { continue }
            if ["без титр", "без надпис", "убери титр", "убрать титр", "удали титр", "не добавляй титр", "не добавлять титр", "титры не нужны", "no title", "without title", "remove title", "no caption", "without caption", "remove caption", "don't add title", "do not add title"].contains(where: clause.contains) {
                result = false
            } else if clause.range(of: #"(?:добав\p{L}*|больше|побольше|нужны|сделай|создай|add|more|include)\s+(?:\p{L}+\s+){0,3}(?:титр\p{L}*|надпис\p{L}*|titles?\b|captions?\b)"#, options: .regularExpression) != nil
                || ["с титрами", "with titles", "with captions", "титры: названия", "титры в каждой", "титры для каждой", "титр в начале", "титры в начале", "title each", "titles for each", "title every"].contains(where: clause.contains) {
                result = true
            }
        }
        return result
    }

    public static func requestsAdditionalTitles(_ prompt: String) -> Bool {
        titleRequest(prompt) == true
    }

    public static func updatedBrief(_ brief: DirectorBrief?, prompt: String) -> DirectorBrief? {
        guard var result = brief?.applyingSubtitleCommand(prompt) else { return nil }
        let text = prompt.lowercased()
        if let volume = OriginalAudioPromptInterpreter().volume(prompt: prompt) {
            result.sourceAudioPolicy = volume == 0 ? .mute : volume < 1 ? .duck : .preserve
        }
        // A persisted automatic canvas may predate the user's explicit format.
        // Read the latest line that specifies one, using the same parser as edits.
        if let format = prompt.components(separatedBy: .newlines).reversed().compactMap({ NaturalLanguageDirector.canvasFormat(from: $0) }).first {
            result.canvasFormat = format
            result.canvasFormatIsAutomatic = false
        }
        if let titles = titleRequest(text) {
            result.titlePolicy = titles ? (DirectorRequestContract.requestsChapterTitles(prompt) ? .keyOnly : result.titlePolicy == .none ? .minimal : result.titlePolicy) : .none
        }
        return result
    }
}
