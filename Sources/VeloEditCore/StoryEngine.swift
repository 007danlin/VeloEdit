import Foundation

public struct PromptInterpreter: LanguageDirectorProtocol {
    public init() {}

    public func constraints(prompt: String, preset: FilmPreset, base: StoryConstraints) async throws -> StoryConstraints {
        interpret(prompt: prompt, preset: preset, base: base)
    }

    public func interpret(prompt: String, preset: FilmPreset, base: StoryConstraints? = nil) -> StoryConstraints {
        let lower = prompt.lowercased()
        var result = base ?? Self.defaults(for: preset)
        if let seconds = Self.duration(from: lower) { result.targetDuration = seconds }
        if let clipCount = Self.requestedClipCount(from: lower) { result.targetClipCount = clipCount }
        let tags: [(String, [String])] = [
            ("bike", ["велосип", "bike"]), ("buggy", ["багги", "buggy"]),
            ("fishing", ["рыбал", "fishing"]), ("nature", ["природ", "nature", "пейзаж"]),
            ("sunset", ["закат", "sunset"]), ("people", ["люд", "семь", "people"]),
            ("high-speed", ["скорост", "разгон", "high speed"]),
            ("g-force", ["перегруз", "g-force", "сильный удар"]),
            ("elevation-change", ["прыж", "перепад", "спуск", "подъём"]),
            ("turn", ["поворот", "вираж"]),
            ("telemetry-event", ["телеметри"]),
            ("action", ["экшен", "трюк", "action"])
        ]
        for (tag, words) in tags where words.contains(where: lower.contains) { result.includeTags.insert(tag) }
        let introAnchors = ["начал", "вступлен", "откры", "intro"]
        let climaxAnchors = ["кульминац", "пик", "главным момент", "climax"]
        let outroAnchors = ["финал", "концов", "заверши", "outro"]
        for (tag, words) in tags where words.contains(where: lower.contains) {
            if introAnchors.contains(where: lower.contains) {
                result.preferredIntroTags = (result.preferredIntroTags ?? []).union([tag])
            }
            if climaxAnchors.contains(where: lower.contains) {
                result.preferredClimaxTags = (result.preferredClimaxTags ?? []).union([tag])
            }
            if outroAnchors.contains(where: lower.contains) {
                result.preferredOutroTags = (result.preferredOutroTags ?? []).union([tag])
            }
        }
        if lower.contains("больше фото") || lower.contains("больше фотограф") { result.preferPhotos = true }
        if lower.contains("без slow motion") || lower.contains("не используй slow motion") || lower.contains("без слоу") { result.allowSlowMotion = false }
        let energeticPosition = Self.lastPosition(of: ["динамич", "энергич", "быстрый темп"], in: lower)
        let calmPosition = Self.lastPosition(of: ["спокой", "медлен"], in: lower)
        if let energeticPosition, energeticPosition > (calmPosition ?? -1) {
            result.pacing = min(1, result.pacing + 0.2)
        } else if calmPosition != nil {
            result.pacing = max(0, result.pacing - 0.2)
        }
        if lower.contains("меньше переход") { result.transitionFrequency = max(0, result.transitionFrequency - 0.15) }
        if lower.contains("больше переход") { result.transitionFrequency = min(1, result.transitionFrequency + 0.15) }
        for (tag, words) in tags {
            for word in words {
                if let share = Self.maximumShare(in: lower, near: word) { result.maximumTagShares[tag] = share }
                if lower.contains("без \(word)") || lower.contains("не показывай \(word)") { result.excludeTags.insert(tag) }
            }
        }
        return result
    }

    public static func defaults(for preset: FilmPreset) -> StoryConstraints {
        switch preset {
        case .highlight: return StoryConstraints(targetDuration: 120, transitionFrequency: 0.12, pacing: 0.88)
        case .adventure: return StoryConstraints(targetDuration: 8 * 60, transitionFrequency: 0.16, pacing: 0.78)
        case .story: return StoryConstraints(targetDuration: 10 * 60, transitionFrequency: 0.12, pacing: 0.62)
        case .summerFilm: return StoryConstraints(targetDuration: 30 * 60, preferPhotos: true, transitionFrequency: 0.10, pacing: 0.55)
        case .memories: return StoryConstraints(targetDuration: 12 * 60, preferPhotos: true, transitionFrequency: 0.08, pacing: 0.35)
        case .cinematic: return StoryConstraints(targetDuration: 8 * 60, transitionFrequency: 0.05, pacing: 0.25)
        }
    }

    public static func requestedClipCount(from text: String) -> Int? {
        let pattern = #"(?:из|на|выбери|оставь|используй)?\s*(\d{1,3})\s*(?:лучших\s*)?(?:момент|фрагмент|кадр|эпизод)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range(at: 1), in: text),
              let count = Int(text[range]) else { return nil }
        return min(200, max(1, count))
    }

    private static func duration(from text: String) -> Double? {
        let patterns: [(String, Double)] = [(#"(\d+(?:[\.,]\d+)?)\s*(?:минут|мин\b|min\b)"#, 60), (#"(\d+(?:[\.,]\d+)?)\s*(?:секунд|сек\b|sec\b)"#, 1)]
        var latest: (location: Int, seconds: Double)?
        for (pattern, multiplier) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
                  let range = Range(match.range(at: 1), in: text),
                  let value = Double(text[range].replacingOccurrences(of: ",", with: ".")) else { continue }
            if latest.map({ match.range.location > $0.location }) ?? true {
                latest = (match.range.location, value * multiplier)
            }
        }
        return latest?.seconds
    }

    private static func lastPosition(of needles: [String], in text: String) -> Int? {
        needles.compactMap { needle in
            text.range(of: needle, options: .backwards).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
        }.max()
    }

    private static func maximumShare(in text: String, near word: String) -> Double? {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let patterns = ["\(escaped)[^\\d%]{0,24}(?:максимум|не больше|max)?[^\\d]{0,8}(\\d{1,3})\\s*%", "(?:максимум|не больше|max)[^\\d]{0,8}(\\d{1,3})\\s*%[^а-яa-z]{0,8}\(escaped)"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text), let percent = Double(text[range]) else { continue }
            return min(1, max(0, percent / 100))
        }
        return nil
    }
}

public struct HighlightRankingContext: Sendable {
    public var prompt: String
    public var preset: FilmPreset
    public var constraints: StoryConstraints
    public var autonomousStyle: DirectorStyleVector?

    public init(prompt: String, preset: FilmPreset, constraints: StoryConstraints, autonomousStyle: DirectorStyleVector? = nil) {
        self.prompt = prompt
        self.preset = preset
        self.constraints = constraints
        self.autonomousStyle = autonomousStyle
    }
}

/// Injection point for a future automatically calibrated contextual ranker.
/// Implementations return a comparable editorial utility, not a probability.
public protocol HighlightRanking: Sendable {
    func score(_ candidate: Candidate, asset: MediaAsset?, context: HighlightRankingContext) -> Double
}

public struct ContextualHighlightRanker: HighlightRanking, Sendable {
    public init() {}

    public func score(_ candidate: Candidate, asset: MediaAsset?, context: HighlightRankingContext) -> Double {
        let insight = candidate.insights
        let quality = candidate.scores.quality
        let interest = candidate.scores.interest
        let action = candidate.scores.action
        let stability = candidate.scores.stability
        let uniqueness = candidate.scores.uniqueness
        let story = insight?.storyValue ?? interest
        let composition = insight?.composition ?? quality
        let audio = insight?.originalAudioUsefulness ?? 0
        let subject = insight?.subjectTracking?.mainSubjectVisibility ?? 0.42
        let speech = insight?.speech?.editorialImportance ?? 0
        let audioEvent = insight?.audioEvents?.filter { ![.silence, .wind].contains($0.kind) }.map { $0.confidence * $0.intensity }.max() ?? 0
        let bestTake = insight?.bestTakeScore ?? 0.5
        let emotion = insight?.emotion?.isEmpty == false ? 1.0 : (candidate.tags.contains("people") ? 0.62 : 0.25)
        let base: Double
        switch context.preset {
        case .highlight:
            base = interest * 0.27 + action * 0.27 + quality * 0.16 + story * 0.14 + uniqueness * 0.10 + stability * 0.06
        case .adventure:
            base = action * 0.25 + story * 0.22 + interest * 0.20 + quality * 0.12 + uniqueness * 0.11 + stability * 0.10
        case .story:
            base = story * 0.30 + interest * 0.19 + emotion * 0.15 + audio * 0.12 + quality * 0.10 + uniqueness * 0.09 + stability * 0.05
        case .summerFilm:
            base = story * 0.22 + emotion * 0.20 + composition * 0.18 + interest * 0.15 + quality * 0.10 + uniqueness * 0.10 + stability * 0.05
        case .memories:
            base = emotion * 0.27 + story * 0.25 + stability * 0.14 + quality * 0.12 + interest * 0.10 + audio * 0.07 + uniqueness * 0.05
        case .cinematic:
            base = composition * 0.25 + quality * 0.20 + stability * 0.17 + story * 0.17 + interest * 0.11 + uniqueness * 0.10
        }
        var result = base
        if let style = context.autonomousStyle {
            let atmosphere = candidate.tags.isDisjoint(with: ["nature", "landscape", "sunset", "atmosphere", "scenic"]) ? 0.22 : 0.88
            let intimacy = candidate.tags.contains("people") ? max(0.62, emotion) : emotion * 0.48
            let continuous = action * style.action * 0.23
                + story * (style.emotional * 0.12 + style.intimacy * 0.10)
                + composition * style.cinematic * 0.18
                + atmosphere * style.atmosphere * 0.15
                + interest * style.visualDensity * 0.10
                + dynamicsFit(candidate: candidate, desired: style.energy) * 0.12
            result = base * 0.56 + continuous * 0.44 + intimacy * style.intimacy * 0.05
        }
        if !context.constraints.includeTags.isDisjoint(with: candidate.tags) { result += 0.22 }
        if context.constraints.preferPhotos && asset?.kind == .photo { result += 0.16 }
        if asset?.favorite == true { result += 0.25 }
        if candidate.locked { result += 10 }
        if let boundary = candidate.momentBoundary { result += boundary.confidence * 0.06 }
        result += subject * 0.045 + speech * (context.preset == .story || context.preset == .memories ? 0.075 : 0.025)
        result += audioEvent * 0.045 + bestTake * 0.035
        return result
    }

    private func dynamicsFit(candidate: Candidate, desired: Double) -> Double {
        max(0, 1 - abs((candidate.insights?.dynamics ?? candidate.scores.action) - desired))
    }
}

public struct StoryPlanVariant: Sendable {
    public var plan: StoryPlan
    public var strategy: String
    public var seedScore: Double

    public init(plan: StoryPlan, strategy: String, seedScore: Double) {
        self.plan = plan
        self.strategy = strategy
        self.seedScore = seedScore
    }
}

public struct StoryEngine: Sendable {
    private let ranker: any HighlightRanking

    public init(ranker: any HighlightRanking = ContextualHighlightRanker()) {
        self.ranker = ranker
    }

    public func createPlan(prompt: String, preset: FilmPreset, constraints: StoryConstraints, assets: [MediaAsset], analyses: [AnalysisResult], events: [Event] = [], eventDiagnostics: EventRunDiagnostics? = nil, autonomousDecision: AutonomousDirectorDecision? = nil) -> StoryPlan {
        createPlanVariants(prompt: prompt, preset: preset, constraints: constraints, assets: assets, analyses: analyses, events: events, eventDiagnostics: eventDiagnostics, autonomousDecision: autonomousDecision).first?.plan
            ?? StoryPlan(prompt: prompt, preset: preset, constraints: constraints, chapters: [], autonomousDecision: autonomousDecision)
    }

    /// Produces complete alternative stories. The pipeline composes and directs
    /// every variant before global scoring; no partial variant reaches the UI.
    public func createPlanVariants(prompt: String, preset: FilmPreset, constraints: StoryConstraints, assets: [MediaAsset], analyses: [AnalysisResult], events: [Event] = [], eventDiagnostics: EventRunDiagnostics? = nil, limit: Int = 10, autonomousDecision: AutonomousDirectorDecision? = nil) -> [StoryPlanVariant] {
        createPlanVariantSearch(
            prompt: prompt,
            preset: preset,
            constraints: constraints,
            assets: assets,
            analyses: analyses,
            events: events,
            eventDiagnostics: eventDiagnostics,
            limit: limit,
            autonomousDecision: autonomousDecision
        ).variants
    }

    public func createPlanVariantSearch(
        prompt: String,
        preset: FilmPreset,
        constraints: StoryConstraints,
        assets: [MediaAsset],
        analyses: [AnalysisResult],
        events: [Event] = [],
        eventDiagnostics: EventRunDiagnostics? = nil,
        limit: Int = 10,
        minimumDistance: Double = 0.16,
        autonomousDecision: AutonomousDirectorDecision? = nil
    ) -> StoryVariantSearchResult {
        let assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        // Story selection and Director review intentionally share the same
        // scene-enriched evidence. Candidate IDs and source ranges remain stable.
        let candidates = analyses.flatMap(\.directorCandidates).filter { candidate in
            guard !candidate.excluded, let asset = assetByID[candidate.assetID], !asset.excluded, !asset.missing else { return false }
            return constraints.excludeTags.isDisjoint(with: candidate.tags)
        }
        let baseStrategies = [
            "contextual", "story", "action", "technical", "emotional",
            "scenic", "original-audio", "novelty", "contrast", "chronology",
            "quiet-observational", "people-first", "telemetry-action", "closure-first",
            "opening-first", "balanced-energy", "documentary", "cinematic-motion"
        ]
        let preferredStrategies: [String]
        switch autonomousDecision?.story.pattern {
        case .coldOpen, .rapidPeakReaction:
            preferredStrategies = ["action", "opening-first", "telemetry-action", "contrast"]
        case .journeyDiscovery:
            preferredStrategies = ["chronology", "story", "scenic", "cinematic-motion"]
        case .emotionalJourney:
            preferredStrategies = ["emotional", "people-first", "original-audio", "closure-first"]
        case .atmosphericObservation:
            preferredStrategies = ["quiet-observational", "scenic", "cinematic-motion", "technical"]
        case .minimalMontage:
            preferredStrategies = ["contextual", "technical", "closure-first"]
        case .adaptiveArc, nil:
            preferredStrategies = ["contextual", "story", "balanced-energy", "novelty"]
        }
        let strategies = preferredStrategies + baseStrategies.filter { !preferredStrategies.contains($0) }
        let requestedLimit = max(1, min(10, limit))
        let requiredDistance = minimumDistance.clamped01
        var variants: [StoryPlanVariant] = []
        var roughTimelines: [Timeline] = []
        var usageCounts: [UUID: Int] = [:]
        var attempted = 0
        var rejectedAsSimilar = 0
        var rejectionRecords: [VariantRejectionRecord] = []
        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let distanceCalculator = VariantDistanceCalculator()
        for strategy in strategies where variants.count < requestedLimit {
            attempted += 1
            let variantDecision = autonomousDecision?.variant(for: strategy)
            var variantConstraints = constraints
            if let variantDecision {
                variantConstraints.targetDuration = variantDecision.duration.seconds
                variantConstraints.pacing = variantDecision.finalStyle.pacing
                variantConstraints.transitionFrequency = variantDecision.grammar.transitionDensity
                variantConstraints.allowSlowMotion = variantDecision.grammar.slowMotionDensity > 0.025
            }
            let context = HighlightRankingContext(prompt: prompt, preset: preset, constraints: variantConstraints, autonomousStyle: variantDecision?.finalStyle)
            let ranked = candidates.sorted { lhs, rhs in
                let leftPenalty = lhs.locked ? 0 : Double(usageCounts[lhs.id, default: 0]) * 0.16
                let rightPenalty = rhs.locked ? 0 : Double(usageCounts[rhs.id, default: 0]) * 0.16
                return variantRank(lhs, strategy: strategy, context: context, asset: assetByID[lhs.assetID]) - leftPenalty
                    > variantRank(rhs, strategy: strategy, context: context, asset: assetByID[rhs.assetID]) - rightPenalty
            }
            let eventAware = events.isEmpty ? nil : makeEventAwarePlan(
                prompt: prompt,
                preset: preset,
                constraints: variantConstraints,
                events: events,
                diagnostics: eventDiagnostics,
                rankedCandidates: ranked,
                allCandidates: candidates,
                assets: assetByID,
                strategy: strategy,
                autonomousDecision: variantDecision
            )
            let selected = eventAware?.selectedCandidates ?? select(ranked, constraints: variantConstraints)
            let ordered = eventAware?.orderedCandidates
                ?? narrativeOrder(selected, constraints: variantConstraints, assets: assetByID, story: variantDecision?.story)
            // Count attempted use too: a rejected near-duplicate must push the
            // next strategy farther into the candidate pool.
            ordered.forEach { usageCounts[$0.id, default: 0] += 1 }
            let chapters = eventAware?.chapters
                ?? makeChapters(selected: ordered, constraints: variantConstraints, story: variantDecision?.story)
            let plan = StoryPlan(
                prompt: prompt,
                preset: preset,
                constraints: variantConstraints,
                chapters: chapters,
                autonomousDecision: variantDecision,
                eventStory: eventAware?.story
            )
            let rough = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
            let nearest = roughTimelines.indices.map { index in
                (index, distanceCalculator.distance(between: rough, and: roughTimelines[index], candidates: candidateByID))
            }.min { $0.1.total < $1.1.total }
            guard variants.isEmpty || (nearest?.1.total ?? 1) + 0.000_001 >= requiredDistance else {
                rejectedAsSimilar += 1
                rejectionRecords.append(VariantRejectionRecord(
                    strategy: strategy,
                    stage: "rough diversity gate",
                    reason: "Вариант отклонён до production pass: дистанция ниже \(String(format: "%.2f", requiredDistance))",
                    comparedToStrategy: nearest.map { variants[$0.0].strategy },
                    distance: nearest?.1
                ))
                continue
            }
            let mean = ordered.isEmpty ? 0 : ordered.reduce(0) {
                $0 + ranker.score($1, asset: assetByID[$1.assetID], context: context)
            } / Double(ordered.count)
            variants.append(StoryPlanVariant(plan: plan, strategy: strategy, seedScore: mean))
            roughTimelines.append(rough)
        }
        let sorted = variants.sorted { $0.seedScore > $1.seedScore }
        var pairDistances: [VariantPairDistance] = []
        if variants.count > 1 {
            for first in variants.indices {
                for second in variants.indices where second > first {
                    pairDistances.append(VariantPairDistance(
                        firstStrategy: variants[first].strategy,
                        secondStrategy: variants[second].strategy,
                        metrics: distanceCalculator.distance(
                            between: roughTimelines[first],
                            and: roughTimelines[second],
                            candidates: candidateByID
                        )
                    ))
                }
            }
        }
        let totals = pairDistances.map(\.metrics.total)
        let diagnostics = VariantSelectionDiagnostics(
            minimumRequiredDistance: requiredDistance,
            attemptedStrategyCount: attempted,
            acceptedVariantCount: sorted.count,
            rejectedAsTooSimilar: rejectedAsSimilar,
            pairDistances: pairDistances,
            minimumDistance: totals.min(),
            meanDistance: totals.isEmpty ? nil : totals.reduce(0, +) / Double(totals.count),
            selectionReasons: [
                "Story search проверил \(attempted) стратегий",
                "Принято существенно разных вариантов: \(sorted.count)",
                "Отклонено как слишком похожих: \(rejectedAsSimilar)"
            ],
            rejectedVariants: rejectionRecords
        )
        return StoryVariantSearchResult(variants: sorted, diagnostics: diagnostics)
    }

    private struct EventAwarePlanBuild {
        var selectedCandidates: [Candidate]
        var orderedCandidates: [Candidate]
        var chapters: [StoryChapter]
        var story: EventStoryPlan
    }

    private func makeEventAwarePlan(
        prompt: String,
        preset: FilmPreset,
        constraints: StoryConstraints,
        events: [Event],
        diagnostics: EventRunDiagnostics?,
        rankedCandidates: [Candidate],
        allCandidates: [Candidate],
        assets: [UUID: MediaAsset],
        strategy: String,
        autonomousDecision: AutonomousDirectorDecision?
    ) -> EventAwarePlanBuild? {
        let candidateByID = Dictionary(uniqueKeysWithValues: allCandidates.map { ($0.id, $0) })
        let availableCandidateIDs = Set(candidateByID.keys)
        let validEvents = events.filter { event in
            !Set(event.assetIDs).isDisjoint(with: Set(allCandidates.map(\.assetID)))
                && (event.effectiveScenes.isEmpty || event.effectiveScenes.contains { !availableCandidateIDs.isDisjoint(with: Set($0.candidateIDs)) })
        }
        guard !validEvents.isEmpty else { return nil }

        let maximumEventCount = min(validEvents.count, max(1, Int((constraints.targetDuration / 10).rounded(.up))))
        let strategyRanked = validEvents.sorted {
            eventRank($0, strategy: strategy, constraints: constraints) > eventRank($1, strategy: strategy, constraints: constraints)
        }
        var selectedEvents = Array(strategyRanked.prefix(maximumEventCount))
        if selectedEvents.count > 1 {
            let strongExists = selectedEvents.contains { ($0.quality?.total ?? 0.45) >= 0.48 }
            if strongExists {
                selectedEvents.removeAll { event in
                    let quality = event.quality
                    return (quality?.total ?? 0.45) < 0.27 && (quality?.usableMaterial ?? 0.35) < 0.18
                }
            }
        }
        if selectedEvents.isEmpty, let first = strategyRanked.first { selectedEvents = [first] }
        // Event blocks are chronological. A deliberate cold open is represented
        // separately and never turns the archive body into a shuffled playlist.
        selectedEvents.sort {
            let lhs = $0.startDate ?? .distantFuture
            let rhs = $1.startDate ?? .distantFuture
            if lhs != rhs { return lhs < rhs }
            return $0.id.uuidString < $1.id.uuidString
        }

        let chapterPreference = autonomousDecision?.personalSignalAdjustments?["chapterTitles"] ?? 0
        let chapterCardsEnabled = selectedEvents.count > 1 && chapterPreference > -0.60
        let projectTitle: String?
        switch preset {
        case .summerFilm: projectTitle = "Моё лето"
        case .memories: projectTitle = "Воспоминания"
        default: projectTitle = nil
        }
        // Template titles are overlays on the existing storyline and no longer
        // consume separate black-card duration.
        let titleOverhead = 0.0
        let allocations = EventDurationAllocator().allocate(
            events: selectedEvents,
            totalDuration: max(5, constraints.targetDuration - titleOverhead),
            strategy: strategy,
            personalAdjustments: autonomousDecision?.personalSignalAdjustments ?? [:]
        )
        let selectionScale: Double = {
            let lower = strategy.lowercased()
            if lower.contains("quiet-observational") { return 0.62 }
            if ["scenic", "cinematic-motion", "technical"].contains(where: lower.contains) { return 0.72 }
            if ["emotional", "people-first", "original-audio"].contains(where: lower.contains) { return 0.78 }
            if ["closure-first", "opening-first"].contains(where: lower.contains) { return 0.84 }
            return 1
        }()
        let hasEditorialChoice = allCandidates.count > selectedEvents.count * 2
        let editorialAllocations = Dictionary(uniqueKeysWithValues: selectedEvents.map { event in
            let value = allocations[event.id, default: max(3, constraints.targetDuration / Double(selectedEvents.count))]
            // EventScene is the activity grouping produced before Story
            // Engine. Preserve its coverage instead of shrinking a multi-
            // activity event back to one globally strongest source.
            let preservesActivityGroups = event.effectiveScenes.count > 1
            let editorialValue = hasEditorialChoice && !preservesActivityGroups
                ? max(2.2, value * selectionScale)
                : value
            return (event.id, editorialValue)
        })
        let rankedIndex = Dictionary(uniqueKeysWithValues: rankedCandidates.enumerated().map { ($0.element.id, $0.offset) })
        var selectedByEvent: [UUID: [Candidate]] = [:]
        for event in selectedEvents {
            let eventCandidates = allCandidates.filter { event.assetIDs.contains($0.assetID) }
            selectedByEvent[event.id] = selectWithinEvent(
                event: event,
                candidates: eventCandidates,
                allocatedDuration: editorialAllocations[event.id, default: max(3, constraints.targetDuration / Double(selectedEvents.count))],
                constraints: constraints,
                rankedIndex: rankedIndex,
                assets: assets,
                strategy: strategy
            )
        }

        let mayUseColdOpen = selectedEvents.count > 1
            && (autonomousDecision?.story.pattern == .coldOpen || autonomousDecision?.story.pattern == .rapidPeakReaction)
            && strategy != "chronology" && strategy != "documentary"
        let firstChronologicalID = selectedEvents.first?.id
        let coldOpen = mayUseColdOpen ? selectedEvents
            .filter { $0.id != firstChronologicalID }
            .flatMap { selectedByEvent[$0.id] ?? [] }
            .max { coldOpenScore($0) < coldOpenScore($1) } : nil
        if let coldOpen {
            for event in selectedEvents {
                selectedByEvent[event.id]?.removeAll { $0.id == coldOpen.id }
            }
        }

        var chapters: [StoryChapter] = []
        if let coldOpen,
           let event = selectedEvents.first(where: { $0.assetIDs.contains(coldOpen.assetID) }) {
            let scene = event.effectiveScenes.first { $0.candidateIDs.contains(coldOpen.id) }
            chapters.append(StoryChapter(
                title: "Cold Open",
                candidateIDs: [coldOpen.id],
                role: .action,
                purpose: "Осознанный cold open перед хронологической историей",
                eventID: event.id,
                eventSceneID: scene?.id,
                isColdOpen: true
            ))
        }
        for event in selectedEvents {
            let chosen = selectedByEvent[event.id] ?? []
            guard !chosen.isEmpty else { continue }
            let scenes = event.effectiveScenes
            let eventCardTitle = chapterCardsEnabled
                && (event.titleConfidence ?? 0) >= 0.42
                && !SmartTitleEngine.isMeaningless(event.title)
                ? event.title
                : nil
            var firstChapter = true
            var consumed = Set<UUID>()
            for scene in scenes {
                let ids = scene.candidateIDs.filter { id in chosen.contains(where: { $0.id == id }) }
                guard !ids.isEmpty else { continue }
                chapters.append(StoryChapter(
                    title: scene.title,
                    candidateIDs: ids,
                    role: scene.phase.storyRole,
                    purpose: "Сцена \(scene.title) внутри события \(event.title)",
                    eventID: event.id,
                    eventSceneID: scene.id,
                    chapterCardTitle: firstChapter ? eventCardTitle : nil,
                    allocatedDuration: firstChapter ? editorialAllocations[event.id] : nil,
                    coveragePlan: coveragePlan(for: scene, eventID: event.id)
                ))
                firstChapter = false
                consumed.formUnion(ids)
            }
            let fallback = chosen.filter { !consumed.contains($0.id) }
            if !fallback.isEmpty {
                let roles = autonomousDecision?.story.roles(count: fallback.count)
                    ?? fallback.indices.map { role(at: $0, count: fallback.count) }
                var start = 0
                while start < fallback.count {
                    let role = roles[start]
                    var end = start + 1
                    while end < fallback.count, roles[end] == role { end += 1 }
                    chapters.append(StoryChapter(
                        title: role.localizedTitle,
                        candidateIDs: Array(fallback[start..<end]).map(\.id),
                        role: role,
                        purpose: "Дополнительные моменты события \(event.title)",
                        eventID: event.id,
                        chapterCardTitle: firstChapter ? eventCardTitle : nil,
                        allocatedDuration: firstChapter ? editorialAllocations[event.id] : nil,
                        coveragePlan: coveragePlan(for: role, eventID: event.id)
                    ))
                    firstChapter = false
                    start = end
                }
            }
        }
        let ordered = chapters.flatMap(\.candidateIDs).compactMap { candidateByID[$0] }
        guard !ordered.isEmpty else { return nil }
        let entries = selectedEvents.compactMap { event -> EventStoryEntry? in
            guard !(selectedByEvent[event.id] ?? []).isEmpty else { return nil }
            return EventStoryEntry(
                eventID: event.id,
                title: event.title,
                startDate: event.startDate,
                endDate: event.endDate,
                allocatedDuration: editorialAllocations[event.id, default: 0],
                quality: event.quality?.total ?? 0.45,
                sceneIDs: event.effectiveScenes.map(\.id)
            )
        }
        var effectiveDiagnostics = diagnostics
        effectiveDiagnostics?.eventOrder = entries.map(\.eventID)
        return EventAwarePlanBuild(
            selectedCandidates: ordered,
            orderedCandidates: ordered,
            chapters: chapters,
            story: EventStoryPlan(
                projectTitle: projectTitle,
                entries: entries,
                chronologicalByDefault: true,
                coldOpenCandidateID: coldOpen?.id,
                chapterCardsEnabled: chapterCardsEnabled,
                diagnostics: effectiveDiagnostics
            )
        )
    }

    private func eventRank(_ event: Event, strategy: String, constraints: StoryConstraints) -> Double {
        let quality = event.quality ?? EventQuality(total: 0.45, visualQuality: 0.45, semanticCoherence: 0.45, temporalCoherence: 0.45, usableMaterial: 0.35, emotionalValue: 0.35, action: 0.35, uniqueness: 0.45, storyPotential: 0.45, diversity: 0.35)
        var value = quality.total * 0.52 + quality.storyPotential * 0.20 + quality.usableMaterial * 0.12 + quality.diversity * 0.09 + event.effectiveConfidence * 0.07
        switch strategy {
        case "action", "telemetry-action": value += quality.action * 0.34
        case "emotional", "people-first", "original-audio": value += quality.emotionalValue * 0.32
        case "technical", "cinematic-motion": value += quality.visualQuality * 0.25
        case "novelty", "contrast": value += quality.uniqueness * 0.28 + quality.diversity * 0.12
        case "chronology", "documentary": value += quality.temporalCoherence * 0.18 + quality.semanticCoherence * 0.12
        default: break
        }
        if !constraints.includeTags.isDisjoint(with: event.tags) { value += 0.24 }
        return value
    }

    private func selectWithinEvent(
        event: Event,
        candidates: [Candidate],
        allocatedDuration: Double,
        constraints: StoryConstraints,
        rankedIndex: [UUID: Int],
        assets: [UUID: MediaAsset],
        strategy: String
    ) -> [Candidate] {
        guard !candidates.isEmpty else { return [] }
        // Scene discovery normally produces disjoint groups, but imported or
        // migrated manifests may contain overlapping scene ranges. Preserve
        // the first chronological assignment instead of trapping on a
        // duplicate key in production.
        let sceneByCandidate = event.effectiveScenes.reduce(into: [UUID: EventScene]()) { index, scene in
            for candidateID in scene.candidateIDs where index[candidateID] == nil {
                index[candidateID] = scene
            }
        }
        let totalRanked = max(1, rankedIndex.count)
        func utility(_ candidate: Candidate, usedDevices: Set<String>, selected: [Candidate]) -> Double {
            let position = rankedIndex[candidate.id] ?? totalRanked
            let rank = 1 - Double(min(totalRanked, position)) / Double(totalRanked)
            let device = assets[candidate.assetID].map(EventDeviceIdentity.key(for:)) ?? "unknown"
            let deviceNovelty = usedDevices.contains(device) ? 0 : 0.12
            let phase = sceneByCandidate[candidate.id]?.phase
            let roleFit = phase.map { candidate.insights?.roleScores[$0.storyRole] ?? 0.45 } ?? 0.45
            let sameSemanticCount = candidate.insights?.semanticEventID.map { semanticID in
                selected.filter { $0.insights?.semanticEventID == semanticID }.count
            } ?? 0
            let candidateArea = candidate.insights?.subjectTracking?.mainSubject?.observations.first?.region.area
            let scaleNovelty: Double = candidateArea.map { area in
                selected.compactMap { $0.insights?.subjectTracking?.mainSubject?.observations.last?.region.area }
                    .map { other in min(1, abs(log(max(area, 0.001) / max(other, 0.001))) / 1.25) }
                    .max() ?? 0.55
            } ?? 0.5
            let duplicatePenalty = min(0.30, Double(sameSemanticCount) * 0.16)
            return rank * 0.58 + roleFit * 0.16 + candidate.scores.uniqueness * 0.08
                + candidate.scores.quality * 0.07 + deviceNovelty + scaleNovelty * 0.07 - duplicatePenalty
        }
        var selected: [Candidate] = candidates.filter(\.locked)
        var selectedIDs = Set(selected.map(\.id))
        var usedDevices = Set(selected.compactMap { assets[$0.assetID].map(EventDeviceIdentity.key(for:)) })
        var usedDuration = selected.reduce(0) { $0 + clipDuration($1, pacing: constraints.pacing) }
        // First reserve one best usable moment per scene/phase. Large events
        // therefore produce setup → action → peak → reaction, not 20 near-
        // duplicate clips from the strongest source.
        let uncoveredScenes = event.effectiveScenes.filter { scene in
            selectedIDs.isDisjoint(with: Set(scene.candidateIDs))
                && candidates.contains { scene.candidateIDs.contains($0.id) }
        }
        for (sceneIndex, scene) in uncoveredScenes.enumerated() {
            let sceneCandidates = candidates.filter { scene.candidateIDs.contains($0.id) && !selectedIDs.contains($0.id) }
            guard let best = sceneCandidates.max(by: {
                utility($0, usedDevices: usedDevices, selected: selected) < utility($1, usedDevices: usedDevices, selected: selected)
            }) else { continue }
            let duration = clipDuration(best, pacing: constraints.pacing)
            let scenesRemaining = max(1, uncoveredScenes.count - sceneIndex)
            let remainingBudget = max(0, allocatedDuration - usedDuration)
            // Every activity group gets a fair reservable share. Timeline
            // Composer can trim a longer source moment to this share later.
            let reservedDuration = min(duration, remainingBudget / Double(scenesRemaining))
            guard reservedDuration > 0.5 else { continue }
            selected.append(best)
            selectedIDs.insert(best.id)
            usedDuration += reservedDuration
            if let asset = assets[best.assetID] { usedDevices.insert(EventDeviceIdentity.key(for: asset)) }
        }
        while usedDuration < allocatedDuration - 0.75 {
            let remaining = candidates.filter { !selectedIDs.contains($0.id) }
            guard let best = remaining.max(by: {
                utility($0, usedDevices: usedDevices, selected: selected) < utility($1, usedDevices: usedDevices, selected: selected)
            }) else { break }
            let duration = clipDuration(best, pacing: constraints.pacing)
            guard duration >= 0.75 else { selectedIDs.insert(best.id); continue }
            selected.append(best)
            selectedIDs.insert(best.id)
            usedDuration += duration
            if let asset = assets[best.assetID] { usedDevices.insert(EventDeviceIdentity.key(for: asset)) }
        }
        let sourceOrder = Dictionary(uniqueKeysWithValues: event.assetIDs.enumerated().map { ($0.element, $0.offset) })
        return selected.sorted {
            let leftScene = sceneByCandidate[$0.id].flatMap { scene in event.effectiveScenes.firstIndex(where: { $0.id == scene.id }) } ?? Int.max
            let rightScene = sceneByCandidate[$1.id].flatMap { scene in event.effectiveScenes.firstIndex(where: { $0.id == scene.id }) } ?? Int.max
            if leftScene != rightScene { return leftScene < rightScene }
            let leftSource = sourceOrder[$0.assetID] ?? Int.max
            let rightSource = sourceOrder[$1.assetID] ?? Int.max
            if leftSource != rightSource { return leftSource < rightSource }
            // Event and scene blocks remain stable, while candidates inside a
            // broad scene can express genuinely different editorial arcs.
            // This matters for long single-camera scenes where every strong
            // moment fits the duration and candidate selection alone cannot
            // create a distinct variant.
            let lower = strategy.lowercased()
            if ["action", "telemetry", "balanced-energy"].contains(where: lower.contains) {
                let lhs = $0.insights?.dynamics ?? $0.scores.action
                let rhs = $1.insights?.dynamics ?? $1.scores.action
                if abs(lhs - rhs) > 0.025 { return lhs < rhs }
            } else if ["opening-first", "contrast", "novelty"].contains(where: lower.contains) {
                let lhs = $0.scores.action * 0.58 + $0.scores.uniqueness * 0.42
                let rhs = $1.scores.action * 0.58 + $1.scores.uniqueness * 0.42
                if abs(lhs - rhs) > 0.025 { return lhs > rhs }
            } else if ["emotional", "people", "original-audio", "closure"].contains(where: lower.contains) {
                let lhs = ($0.insights?.storyValue ?? $0.scores.interest) * 0.62 + ($0.insights?.originalAudioUsefulness ?? 0) * 0.38
                let rhs = ($1.insights?.storyValue ?? $1.scores.interest) * 0.62 + ($1.insights?.originalAudioUsefulness ?? 0) * 0.38
                if abs(lhs - rhs) > 0.025 { return lhs < rhs }
            } else if ["scenic", "cinematic", "quiet"].contains(where: lower.contains) {
                let lhs = ($0.insights?.composition ?? $0.scores.quality) * 0.62 + $0.scores.stability * 0.38
                let rhs = ($1.insights?.composition ?? $1.scores.quality) * 0.62 + $1.scores.stability * 0.38
                if abs(lhs - rhs) > 0.025 { return lhs > rhs }
            }
            let leftDate = assets[$0.assetID]?.metadata.effectiveCaptureDate ?? .distantFuture
            let rightDate = assets[$1.assetID]?.metadata.effectiveCaptureDate ?? .distantFuture
            if leftDate != rightDate { return leftDate < rightDate }
            return $0.sourceStart < $1.sourceStart
        }
    }

    private func coldOpenScore(_ candidate: Candidate) -> Double {
        candidate.scores.action * 0.42 + candidate.scores.interest * 0.25 + candidate.scores.quality * 0.12
            + candidate.scores.uniqueness * 0.09 + (candidate.insights?.roleScores[.climax] ?? 0.5) * 0.12
    }

    private func coveragePlan(for scene: EventScene, eventID: UUID) -> SceneCoveragePlan {
        let requirements: [SceneCoverageRequirement]
        switch scene.phase {
        case .setup:
            requirements = [SceneCoverageRequirement(purpose: .establishing, priority: 0.92, explanation: "Показать пространство, героя и направление события")]
        case .preparation:
            requirements = [SceneCoverageRequirement(purpose: .context, priority: 0.78, prefersOriginalAudio: true, explanation: "Объяснить подготовку до начала действия")]
        case .action:
            requirements = [SceneCoverageRequirement(purpose: .action, priority: 0.90, prefersOriginalAudio: true, explanation: "Сохранить читаемое действие целиком")]
        case .peak:
            requirements = [SceneCoverageRequirement(purpose: .peak, priority: 1, prefersOriginalAudio: true, explanation: "Отдать подтверждённую кульминацию без premature cut")]
        case .reaction:
            requirements = [SceneCoverageRequirement(purpose: .reaction, priority: 0.94, prefersOriginalAudio: true, explanation: "Показать последствия и человеческую реакцию")]
        case .conclusion:
            requirements = [SceneCoverageRequirement(purpose: .exit, priority: 0.76, explanation: "Закрыть сцену и вернуть зрителю ориентацию")]
        }
        return SceneCoveragePlan(eventID: eventID, sceneID: scene.id, requirements: requirements, explanation: "Coverage строится от функции сцены, а не от количества красивых кадров")
    }

    private func coveragePlan(for role: StoryRole, eventID: UUID) -> SceneCoveragePlan {
        let purpose: CoveragePurpose
        switch role {
        case .intro: purpose = .establishing
        case .setup, .buildup: purpose = .context
        case .action: purpose = .action
        case .climax: purpose = .peak
        case .reaction: purpose = .reaction
        case .outro: purpose = .exit
        case .bRoll: purpose = .detail
        }
        return SceneCoveragePlan(
            eventID: eventID,
            requirements: [SceneCoverageRequirement(purpose: purpose, priority: role == .climax ? 1 : 0.72, prefersOriginalAudio: role == .action || role == .reaction, explanation: "Закрыть редакционную функцию (role.localizedTitle.lowercased())")],
            explanation: "Fallback coverage для кандидатов без отдельной scene cluster"
        )
    }

    private func select(_ candidates: [Candidate], constraints: StoryConstraints) -> [Candidate] {
        var selected = candidates.filter(\.locked)
        var duration = selected.reduce(0) { $0 + clipDuration($1, pacing: constraints.pacing) }
        var tagDurations: [String: Double] = [:]
        var assetDurations: [UUID: Double] = [:]
        var selectedSemanticEvents = Set(selected.compactMap { $0.insights?.semanticEventID })
        selected.forEach { candidate in candidate.tags.forEach { tagDurations[$0, default: 0] += clipDuration(candidate, pacing: constraints.pacing) } }
        selected.forEach { assetDurations[$0.assetID, default: 0] += clipDuration($0, pacing: constraints.pacing) }
        let distinctAssetCount = Set(candidates.map(\.assetID)).count
        let maximumAssetShare = distinctAssetCount > 1 ? max(0.45, min(0.75, 1.5 / Double(distinctAssetCount))) : 1
        let longestPreferredClip = candidates.map { clipDuration($0, pacing: constraints.pacing) }.max() ?? 0
        let maximumAssetDuration = max(constraints.targetDuration * maximumAssetShare, longestPreferredClip)
        for candidate in candidates where !selected.contains(where: { $0.id == candidate.id }) {
            if let targetClipCount = constraints.targetClipCount, selected.count >= targetClipCount { break }
            if duration >= constraints.targetDuration { break }
            let clip = min(clipDuration(candidate, pacing: constraints.pacing), constraints.targetDuration - duration)
            guard clip >= 0.75 else { continue }
            if !candidate.locked,
               let semanticEventID = candidate.insights?.semanticEventID,
               selectedSemanticEvents.contains(semanticEventID) {
                continue
            }
            // Technical tags such as `4k` and `horizontal` are shared by most
            // camera clips and must never collapse a film to one fragment.
            // A soft per-source cap keeps several imported videos represented.
            if !candidate.locked,
               assetDurations[candidate.assetID, default: 0] + clip > maximumAssetDuration + 0.001 {
                continue
            }
            let violatesShare = candidate.tags.contains { tag in
                guard let maximum = constraints.maximumTagShares[tag] else { return false }
                return (tagDurations[tag, default: 0] + clip) / max(constraints.targetDuration, 1) > maximum
            }
            if violatesShare { continue }
            selected.append(candidate)
            if let semanticEventID = candidate.insights?.semanticEventID { selectedSemanticEvents.insert(semanticEventID) }
            duration += clip
            assetDurations[candidate.assetID, default: 0] += clip
            candidate.tags.forEach { tagDurations[$0, default: 0] += clip }
        }
        return selected
    }

    private func variantRank(_ candidate: Candidate, strategy: String, context: HighlightRankingContext, asset: MediaAsset?) -> Double {
        let contextual = ranker.score(candidate, asset: asset, context: context)
        switch strategy {
        case "story": return contextual * 0.62 + (candidate.insights?.storyValue ?? candidate.scores.interest) * 0.38
        case "action": return contextual * 0.56 + candidate.scores.action * 0.34 + (candidate.insights?.speedRampSuitability ?? candidate.scores.action) * 0.10
        case "technical": return contextual * 0.60 + candidate.scores.quality * 0.24 + candidate.scores.stability * 0.16
        case "emotional":
            let emotion = candidate.insights?.emotion?.isEmpty == false ? 1.0 : (candidate.tags.contains("people") ? 0.62 : 0.18)
            return contextual * 0.42 + emotion * 0.30 + (candidate.insights?.storyValue ?? candidate.scores.interest) * 0.28
        case "scenic":
            return contextual * 0.40 + (candidate.insights?.composition ?? candidate.scores.quality) * 0.32 + candidate.scores.stability * 0.18 + candidate.scores.uniqueness * 0.10
        case "original-audio":
            return contextual * 0.42 + (candidate.insights?.originalAudioUsefulness ?? 0) * 0.40 + (candidate.insights?.storyValue ?? candidate.scores.interest) * 0.18
        case "novelty":
            return contextual * 0.38 + candidate.scores.uniqueness * 0.42 + candidate.scores.interest * 0.20
        case "contrast":
            let contrast = abs(candidate.scores.action - 0.5) * 2
            return contextual * 0.38 + contrast * 0.32 + (candidate.insights?.storyValue ?? candidate.scores.interest) * 0.30
        case "chronology":
            let timestamp = asset?.metadata.creationDate?.timeIntervalSince1970 ?? 0
            let chronologicalTieBreak = timestamp.truncatingRemainder(dividingBy: 10_000) / 10_000
            return contextual * 0.52 + candidate.scores.interest * 0.22 + candidate.scores.stability * 0.16 + chronologicalTieBreak * 0.10
        case "quiet-observational":
            return contextual * 0.30 + (1 - candidate.scores.action) * 0.28 + candidate.scores.stability * 0.22 + (candidate.insights?.composition ?? candidate.scores.quality) * 0.20
        case "people-first":
            let people = candidate.tags.contains("people") || candidate.insights?.emotion?.isEmpty == false ? 1.0 : 0.12
            return contextual * 0.34 + people * 0.36 + (candidate.insights?.originalAudioUsefulness ?? 0) * 0.16 + (candidate.insights?.storyValue ?? candidate.scores.interest) * 0.14
        case "telemetry-action":
            let telemetry = !candidate.tags.isDisjoint(with: ["telemetry-event", "g-force", "high-speed", "elevation-change", "turn"]) ? 1.0 : 0
            return contextual * 0.32 + telemetry * 0.34 + candidate.scores.action * 0.26 + candidate.scores.stability * 0.08
        case "closure-first":
            return contextual * 0.34 + (candidate.insights?.roleScores[.outro] ?? 0.3) * 0.34 + candidate.scores.stability * 0.16 + (candidate.insights?.storyValue ?? candidate.scores.interest) * 0.16
        case "opening-first":
            return contextual * 0.34 + (candidate.insights?.roleScores[.intro] ?? 0.3) * 0.34 + (candidate.insights?.composition ?? candidate.scores.quality) * 0.18 + candidate.scores.interest * 0.14
        case "balanced-energy":
            let balance = max(0, 1 - abs(candidate.scores.action - 0.58) * 1.8)
            return contextual * 0.34 + balance * 0.30 + (candidate.insights?.storyValue ?? candidate.scores.interest) * 0.22 + candidate.scores.quality * 0.14
        case "documentary":
            return contextual * 0.30 + (candidate.insights?.originalAudioUsefulness ?? 0) * 0.26 + (candidate.insights?.storyValue ?? candidate.scores.interest) * 0.26 + candidate.scores.stability * 0.18
        case "cinematic-motion":
            return contextual * 0.30 + (candidate.insights?.composition ?? candidate.scores.quality) * 0.26 + (candidate.insights?.dynamics ?? candidate.scores.action) * 0.22 + candidate.scores.stability * 0.22
        default: return contextual
        }
    }

    private func clipDuration(_ candidate: Candidate, pacing: Double) -> Double {
        let preferred = 8 - pacing * 4.8
        return min(candidate.sourceDuration, max(1.5, preferred))
    }

    private func narrativeOrder(_ candidates: [Candidate], constraints: StoryConstraints, assets: [UUID: MediaAsset], story: AutonomousStoryDecision? = nil) -> [Candidate] {
        guard candidates.count >= 3 else { return chronological(candidates, assets: assets) }
        var remaining = candidates

        func takeBest(_ role: StoryRole) -> Candidate? {
            guard let candidate = remaining.max(by: {
                roleScore($0, role: role, constraints: constraints) < roleScore($1, role: role, constraints: constraints)
            }), let index = remaining.firstIndex(where: { $0.id == candidate.id }) else { return nil }
            return remaining.remove(at: index)
        }

        if story?.pattern == .minimalMontage {
            return chronological(candidates, assets: assets)
        }
        if story?.pattern == .atmosphericObservation {
            let intro = takeBest(.intro)
            let outro = takeBest(.outro)
            let middle = remaining.sorted {
                let lhs = (1 - $0.scores.action) * 0.34 + ($0.insights?.composition ?? $0.scores.quality) * 0.40 + $0.scores.stability * 0.26
                let rhs = (1 - $1.scores.action) * 0.34 + ($1.insights?.composition ?? $1.scores.quality) * 0.40 + $1.scores.stability * 0.26
                return lhs > rhs
            }
            return [intro].compactMap { $0 } + middle + [outro].compactMap { $0 }
        }
        if story?.pattern == .coldOpen || story?.pattern == .rapidPeakReaction {
            let opening = takeBest(.action)
            let climax = takeBest(.climax)
            let reaction = takeBest(.reaction)
            let middle = chronological(remaining, assets: assets).sorted {
                ($0.insights?.dynamics ?? $0.scores.action) < ($1.insights?.dynamics ?? $1.scores.action)
            }
            let climaxPosition = min(middle.count, max(0, Int((Double(middle.count) * 0.72).rounded())))
            return [opening].compactMap { $0 }
                + Array(middle.prefix(climaxPosition))
                + [climax].compactMap { $0 }
                + Array(middle.dropFirst(climaxPosition))
                + [reaction].compactMap { $0 }
        }

        let intro = takeBest(.intro)
        let climax = takeBest(.climax)
        let outro = takeBest(.outro)
        let middle = chronological(remaining, assets: assets).sorted {
            let left = $0.scores.action * 0.58 + $0.scores.interest * 0.42
            let right = $1.scores.action * 0.58 + $1.scores.interest * 0.42
            if abs(left - right) > 0.20 { return left < right }
            return (assets[$0.assetID]?.metadata.creationDate ?? .distantPast) < (assets[$1.assetID]?.metadata.creationDate ?? .distantPast)
        }
        // Put the deliberately selected peak into the first slot that will
        // actually receive the semantic `.climax` role below. Using a share of
        // only the remaining middle clips could leave the strongest moment in
        // the preceding `.action` chapter on shorter edits.
        let firstClimaxIndex = Int((Double(max(1, candidates.count - 1)) * 0.76).rounded(.up))
        let climaxPosition = min(middle.count, max(0, firstClimaxIndex - 1))
        var result: [Candidate] = []
        if let intro { result.append(intro) }
        result.append(contentsOf: middle.prefix(climaxPosition))
        if let climax { result.append(climax) }
        result.append(contentsOf: middle.dropFirst(climaxPosition))
        if let outro { result.append(outro) }
        return result
    }

    private func chronological(_ candidates: [Candidate], assets: [UUID: MediaAsset]) -> [Candidate] {
        let sourceMap = SourceTimelineAnalyzer().analyze(assets: Array(assets.values), analyses: [])
        let sourceOrder = Dictionary(uniqueKeysWithValues: sourceMap.entries.map { ($0.assetID, $0.order) })
        return candidates.sorted {
            let leftOrder = sourceOrder[$0.assetID] ?? Int.max
            let rightOrder = sourceOrder[$1.assetID] ?? Int.max
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            if $0.assetID == $1.assetID, $0.sourceStart != $1.sourceStart { return $0.sourceStart < $1.sourceStart }
            return $0.scores.composite > $1.scores.composite
        }
    }

    private func roleScore(_ candidate: Candidate, role: StoryRole, constraints: StoryConstraints) -> Double {
        let insight = candidate.insights?.roleScores[role] ?? 0.5
        let preferred: Set<String>?
        switch role {
        case .intro: preferred = constraints.preferredIntroTags
        case .climax: preferred = constraints.preferredClimaxTags
        case .outro: preferred = constraints.preferredOutroTags
        default: preferred = nil
        }
        let requested = preferred?.isDisjoint(with: candidate.tags) == false ? 0.55 : 0
        switch role {
        case .intro:
            let atmosphere = candidate.tags.contains("atmosphere") || candidate.tags.contains("nature") || candidate.tags.contains("landscape") ? 0.18 : 0
            return candidate.scores.interest * 0.32 + candidate.scores.quality * 0.25 + candidate.scores.stability * 0.23 + insight * 0.20 + atmosphere + requested
        case .climax:
            let telemetry = candidate.tags.contains("telemetry-event") || candidate.tags.contains("g-force") || candidate.tags.contains("high-speed") ? 0.16 : 0
            return candidate.scores.action * 0.42 + candidate.scores.interest * 0.25 + candidate.scores.quality * 0.13 + candidate.scores.uniqueness * 0.08 + insight * 0.12 + telemetry + requested
        case .outro:
            let closure = candidate.tags.contains("sunset") || candidate.tags.contains("nature") || candidate.tags.contains("people") || candidate.tags.contains("atmosphere") ? 0.20 : 0
            return candidate.scores.quality * 0.30 + candidate.scores.interest * 0.27 + candidate.scores.stability * 0.23 + insight * 0.20 + closure + requested
        case .reaction:
            let humanReaction = candidate.tags.contains("people") || candidate.insights?.emotion?.isEmpty == false ? 0.22 : 0
            let naturalSound = (candidate.insights?.originalAudioUsefulness ?? 0) * 0.16
            return candidate.scores.interest * 0.25 + candidate.scores.stability * 0.18
                + (1 - candidate.scores.action) * 0.18 + insight * 0.19 + humanReaction + naturalSound
        default:
            return candidate.scores.composite + insight * 0.15
        }
    }

    private func makeChapters(selected: [Candidate], constraints: StoryConstraints, story: AutonomousStoryDecision? = nil) -> [StoryChapter] {
        guard !selected.isEmpty else { return [] }
        let roles = story?.roles(count: selected.count) ?? selected.indices.map { role(at: $0, count: selected.count) }
        var chapters: [StoryChapter] = []
        var currentRole = roles[0]
        var ids: [UUID] = []
        for (index, candidate) in selected.enumerated() {
            let role = roles[index]
            if role != currentRole, !ids.isEmpty {
                chapters.append(chapter(role: currentRole, ids: ids))
                ids = []
                currentRole = role
            }
            ids.append(candidate.id)
        }
        if !ids.isEmpty { chapters.append(chapter(role: currentRole, ids: ids)) }
        return chapters
    }

    private func role(at index: Int, count: Int) -> StoryRole {
        switch count {
        case 1: return .climax
        case 2: return index == 0 ? .intro : .outro
        case 3: return [.intro, .climax, .outro][index]
        case 4: return [.intro, .setup, .climax, .outro][index]
        case 5: return [.intro, .setup, .action, .climax, .outro][index]
        default:
            let position = Double(index) / Double(max(1, count - 1))
            if position < 0.12 { return .intro }
            if position < 0.28 { return .setup }
            if position < 0.50 { return .buildup }
            if position < 0.76 { return .action }
            if position < 0.88 { return .climax }
            if position < 0.96 { return .reaction }
            return .outro
        }
    }

    private func chapter(role: StoryRole, ids: [UUID]) -> StoryChapter {
        let purpose: String
        switch role {
        case .intro: purpose = "Сразу обозначить мир фильма и заинтересовать зрителя"
        case .setup: purpose = "Дать контекст, героев и направление движения"
        case .buildup: purpose = "Постепенно увеличить энергию и ожидание"
        case .action: purpose = "Развить действие без потери визуального разнообразия"
        case .climax: purpose = "Отдать самый сильный подтверждённый момент истории"
        case .reaction: purpose = "Дать зрителю увидеть и услышать последствия кульминации"
        case .outro: purpose = "Снять напряжение и завершить фильм осмысленным образом"
        case .bRoll: purpose = "Поддержать основную сцену смысловой перебивкой"
        }
        return StoryChapter(title: role.localizedTitle, candidateIDs: ids, role: role, purpose: purpose)
    }
}

public struct FeedbackEngine: Sendable {
    public init() {}

    public func apply(feedback: String, to plan: StoryPlan, candidates: inout [Candidate], selectedCandidateID: UUID? = nil) -> StoryPlan {
        var updated = plan
        updated.id = UUID()
        updated.version += 1
        updated.prompt += "\nОбратная связь: \(feedback)"
        updated.constraints = PromptInterpreter().interpret(prompt: feedback, preset: plan.preset, base: plan.constraints)
        let lower = feedback.lowercased()
        if let selectedCandidateID, let index = candidates.firstIndex(where: { $0.id == selectedCandidateID }) {
            if lower.contains("обязательно остав") || lower.contains("закреп") { candidates[index].locked = true; candidates[index].excluded = false }
            if lower.contains("убери") || lower.contains("исключ") { candidates[index].excluded = true; candidates[index].locked = false }
        }
        return updated
    }
}
