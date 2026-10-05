import Foundation

/// Converts an already edited story into a small number of musically distinct
/// parts. The policy is deliberately conservative: an ordinary scene, role or
/// energy change is not enough to replace a track. A boundary needs sustained
/// semantic evidence on both sides and enough screen time to justify a change.
public struct AdaptiveSoundtrackPlanner: Sendable {
    private enum Activity: String, Sendable {
        case actionVehicle = "action-vehicle"
        case fishing
        case cycling
        case paddling
        case hiking
        case running
        case swimming
        case winterSports = "winter-sports"
        case surfing
        case climbing
        case equestrian

        var localizedTitle: String {
            switch self {
            case .actionVehicle: return "Экшен"
            case .fishing: return "Рыбалка"
            case .cycling: return "Велосипед"
            case .paddling: return "Сплав"
            case .hiking: return "Маршрут"
            case .running: return "Бег"
            case .swimming: return "Плавание"
            case .winterSports: return "Зимний спорт"
            case .surfing: return "Сёрфинг"
            case .climbing: return "Скалолазание"
            case .equestrian: return "Конная прогулка"
            }
        }
    }

    private struct Observation: Sendable {
        var item: TimelineItem
        var activity: Activity?
        var tokens: Set<String>
        var energy: Double
        var duration: Double
    }

    private struct Context: Sendable {
        var activity: Activity?
        var tokens: Set<String>
        var energy: Double
    }

    private struct Boundary: Sendable {
        var time: Double
        var confidence: Double
        var incomingItemID: UUID
        var explanation: [String]
    }

    private struct Part: Sendable {
        var start: Double
        var end: Double
        var activity: Activity?
        var tokens: Set<String>
        var energy: Double
        var cutRate: Double
        var boundary: Boundary?
        var style: MusicStyle
        var bpm: Double
        var label: String

        var duration: Double { max(0.05, end - start) }
    }

    private struct Decision: Sendable {
        var part: Part
        var track: LocalMusicTrack
        var directive: MusicDirective
    }

    private let boundaryThreshold = 0.72

    public init() {}

    /// The same semantic boundaries drive acquisition and final placement.
    /// This pass works before any track has been downloaded or selected.
    public func requests(for timeline: Timeline, plan: StoryPlan? = nil, analyses: [AnalysisResult]) -> [MusicIntent] {
        guard let master = timeline.music,
              plan?.directorBrief?.musicPolicy != DirectorMusicPolicy.none,
              plan?.directorBrief?.musicPolicy != .specificTrack else { return [] }
        if let searches = master.searchRequests, searches.count == 1, searches[0].exactTrack, searches[0].scene == nil {
            return [MusicIntent(directive: master, timelineDuration: timeline.duration)]
        }
        let observations = makeObservations(timeline: timeline, analyses: analyses)
        let boundaries = soundtrackBoundaries(observations: observations, timeline: timeline)
        let parts = makeParts(observations: observations, boundaries: boundaries, duration: timeline.duration,
                              softPolicy: plan?.directorBrief?.musicPolicy == .soft, mood: plan?.directorBrief?.mood)
        return parts.enumerated().map { index, part in
            var directive = MusicDirective(style: part.style, bpm: part.bpm, volume: master.volume)
            directive.searchRequests = request(for: part, index: index, master: master).map { [$0] }
            var intent = MusicIntent(directive: directive, timelineDuration: part.duration)
            intent.sceneType = part.activity?.rawValue ?? part.label
            intent.energy = part.energy
            return intent
        }
    }

    private func request(for part: Part, index: Int, master: MusicDirective) -> MusicSearchRequest? {
        let requests = master.searchRequests ?? []
        if let scoped = requests.first(where: { $0.applies(to: part.label + " " + (part.activity?.rawValue ?? "")) }) { return scoped }
        let unscoped = requests.filter { $0.scene == nil }
        return unscoped.isEmpty ? nil : unscoped[min(index, unscoped.count - 1)]
    }

    private func soundtrackBoundaries(observations: [Observation], timeline: Timeline) -> [Boundary] {
        let semantic = confidentBoundaries(in: observations, timeline: timeline)
        let explicitCount = timeline.music?.searchRequests?.filter { $0.exactTrack && $0.scene == nil }.count ?? 0
        guard explicitCount > 1, semantic.count + 1 < explicitCount else { return semantic }
        // Several named songs also work in a single-activity film. Use real
        // edit boundaries nearest the musical regions, never arbitrary cuts.
        var boundaries: [Boundary] = []
        for index in 1..<min(explicitCount, max(1, observations.count)) {
            let target = timeline.duration * Double(index) / Double(explicitCount)
            let candidates = observations.filter {
                $0.item.timelineStart >= (boundaries.last?.time ?? 0) + 6 && timeline.duration - $0.item.timelineStart >= 6
            }
            if let closest = candidates.min(by: { abs($0.item.timelineStart - target) < abs($1.item.timelineStart - target) }) {
                boundaries.append(Boundary(time: closest.item.timelineStart, confidence: 1, incomingItemID: closest.item.id,
                    explanation: ["Следующий трек из запроса пользователя"]))
            }
        }
        return boundaries
    }

    public func applying(
        to source: Timeline,
        plan: StoryPlan? = nil,
        tracks: [LocalMusicTrack],
        analyses: [AnalysisResult],
        structures: [UUID: MusicStructure] = [:]
    ) -> Timeline {
        var result = source
        result.adaptiveSoundtrack = nil
        guard let master = source.music,
              master.trackID != nil,
              source.duration >= 18,
              plan?.directorBrief?.musicPolicy != DirectorMusicPolicy.none,
              plan?.directorBrief?.musicPolicy != .specificTrack else { return result }

        if let searches = master.searchRequests, searches.count == 1, searches[0].exactTrack, searches[0].scene == nil { return result }
        let playableTracks = uniquePlayableTracks(tracks)
        guard playableTracks.count >= 2 else { return result }
        let observations = makeObservations(timeline: source, analyses: analyses)
        guard observations.count >= 3 else { return result }

        let boundaries = soundtrackBoundaries(observations: observations, timeline: source)
        guard !boundaries.isEmpty else { return result }
        let softPolicy = plan?.directorBrief?.musicPolicy == .soft
        let parts = makeParts(
            observations: observations,
            boundaries: boundaries,
            duration: source.duration,
            softPolicy: softPolicy, mood: plan?.directorBrief?.mood
        )
        guard parts.count >= 2 else { return result }

        var decisions: [Decision] = []
        for (partIndex, part) in parts.enumerated() {
            var directive = MusicDirective(
                style: part.style,
                bpm: part.bpm,
                volume: master.volume
            )
            directive.searchRequests = request(for: part, index: partIndex, master: master).map { [$0] }
            let previous = decisions.last
            let preferredID = decisions.isEmpty ? master.trackID : nil
            let chosen = chooseTrack(
                for: part,
                directive: directive,
                tracks: playableTracks,
                previous: previous,
                preferredID: preferredID
            )
            guard let chosen else { return result }
            directive.trackID = chosen.id
            directive.trackTitle = chosen.title
            directive.bpm = chosen.bpm
            directive.structure = structures[chosen.id]
            decisions.append(Decision(part: part, track: chosen, directive: directive))
        }

        decisions = mergingUnchangedTracks(decisions)
        guard decisions.count >= 2,
              Set(decisions.map(\.track.id)).count >= 2 else { return result }

        let explicitChanges = master.searchRequests?.contains { $0.scene != nil } == true || (master.searchRequests?.filter { $0.exactTrack }.count ?? 0) > 1
        // Unknown key/vocal compatibility is not a successful audio check.
        // For automatic changes keep a suitable single song if the transition
        // would need unverified overlap to disguise incompatible recordings.
        for (outgoing, incoming) in zip(decisions, decisions.dropFirst()) {
            let tempoRatio = max(outgoing.track.bpm, incoming.track.bpm) / max(1, min(outgoing.track.bpm, incoming.track.bpm))
            let bothInstrumental = [outgoing.track, incoming.track].allSatisfy {
                MusicSearchRequest.words(($0.tags ?? []) .joined(separator: " ")).contains("instrumental")
            }
            let keyKnown = outgoing.track.musicalKey != nil && incoming.track.musicalKey != nil
            let compatible = tempoRatio <= 1.08 && keyKnown && Self.keyCompatibility(outgoing.track.musicalKey, incoming.track.musicalKey) >= 0.8 && bothInstrumental
            if !explicitChanges && !compatible { return result }
        }
        var segments: [AdaptiveMusicSegment] = []
        for index in decisions.indices {
            let decision = decisions[index]
            let transitionDuration = index == decisions.startIndex
                ? 0
                : 0.12 // Brief envelope at the boundary avoids unverified harmonic/vocal overlap.
            var partTimeline = source
            partTimeline.music = decision.directive
            let window = SoundtrackEditorialPolicy.window(track: decision.track, structure: structures[decision.track.id],
                timeline: partTimeline, analyses: analyses, timelineStart: decision.part.start,
                duration: decision.part.duration + transitionDuration)
            let sourceStart = window.sourceStart
            let boundaryConfidence = decision.part.boundary?.confidence ?? 1
            var explanation = decision.part.boundary?.explanation ?? ["Начало фильма"]
            explanation.append("Музыка: \(decision.directive.style.localizedTitle), \(Int(decision.directive.bpm.rounded())) BPM")
            if transitionDuration > 0 {
                explanation.append("Короткий переход \(String(format: "%.2f", transitionDuration)) с; совместимость звучания требует прослушивания")
            }
            if sourceStart > 0.01 {
                explanation.append("Выбрано начало музыкального участка: \(String(format: "%.2f", sourceStart)) с; основание — карта энергии, пауз и доступных границ")
            }
            segments.append(AdaptiveMusicSegment(
                timelineStart: decision.part.start,
                timelineDuration: decision.part.duration,
                directive: decision.directive,
                sourceStart: sourceStart,
                transitionDuration: transitionDuration,
                semanticLabel: decision.part.label,
                activityKey: decision.part.activity?.rawValue,
                energy: decision.part.energy,
                confidence: boundaryConfidence,
                boundaryItemID: decision.part.boundary?.incomingItemID,
                explanation: explanation
            ))
        }

        var visibleMaster = decisions[0].directive
        visibleMaster.volume = master.volume
        visibleMaster.autonomousIntent = master.autonomousIntent
        visibleMaster.searchRequests = master.searchRequests
        result.music = visibleMaster
        result.adaptiveSoundtrack = AdaptiveSoundtrackPlan(
            primaryTrackID: decisions[0].track.id,
            timelineDuration: source.duration,
            timelineFingerprint: source.adaptiveSoundtrackFingerprint,
            segments: segments,
            confidence: boundaries.map(\.confidence).reduce(0, +) / Double(boundaries.count),
            explanation: [
                "AI Director выделил только уверенные крупные части фильма",
                "Неуверенные и слишком короткие изменения оставлены на предыдущем треке",
                "Музыкальные смены совпадают с существующими монтажными границами"
            ]
        )
        return result
    }

    private func uniquePlayableTracks(_ tracks: [LocalMusicTrack]) -> [LocalMusicTrack] {
        var identities: Set<String> = []
        return tracks.filter { track in
            guard track.isPlayable, identities.insert(track.selectionIdentity).inserted else { return false }
            return true
        }
    }

    private func makeObservations(timeline: Timeline, analyses: [AnalysisResult]) -> [Observation] {
        let candidates = Dictionary(
            analyses.flatMap(\.directorCandidates).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return TimelineTiming.retimed(timeline.items)
            .filter { $0.overlay == nil && $0.kind != .title }
            .sorted { $0.timelineStart < $1.timelineStart }
            .map { item in
                let candidate = item.candidateID.flatMap { candidates[$0] }
                let semanticText = [
                    candidate?.tags.sorted().joined(separator: " "),
                    candidate?.insights?.sceneSummary,
                    candidate?.insights?.emotion,
                    item.editorialPurpose
                ].compactMap { $0 }.joined(separator: " ")
                let tokens = Self.tokens(in: semanticText)
                let activity = Self.activity(in: semanticText)
                let action = candidate?.scores.action ?? Self.roleEnergy(item.storyRole)
                let dynamics = candidate?.insights?.dynamics ?? action
                let role = Self.roleEnergy(item.storyRole)
                let energy = (action * 0.52 + dynamics * 0.30 + role * 0.18).clamped01
                return Observation(
                    item: item,
                    activity: activity,
                    tokens: tokens,
                    energy: energy,
                    duration: max(0.05, item.timelineDuration)
                )
            }
    }

    private func confidentBoundaries(in observations: [Observation], timeline: Timeline) -> [Boundary] {
        let minimumPartDuration = min(14, max(6, timeline.duration * 0.12))
        var candidates: [Boundary] = []
        for index in observations.indices.dropFirst() {
            if let activity = observations[index - 1].activity, activity == observations[index].activity { continue }
            let left = context(in: observations, from: index - 1, direction: -1)
            let right = context(in: observations, from: index, direction: 1)

            // The strongest continuity rule: changing angle, story role or
            // scene inside the same recognized activity never changes music.
            if let activity = left.activity, activity == right.activity { continue }

            let incoming = observations[index].item
            let outgoing = observations[index - 1].item
            let eventChanged = outgoing.eventID != nil && incoming.eventID != nil && outgoing.eventID != incoming.eventID
            let sceneChanged = outgoing.eventSceneID != nil && incoming.eventSceneID != nil && outgoing.eventSceneID != incoming.eventSceneID
            let semanticDistance = Self.semanticDistance(left.tokens, right.tokens)
            let energyDelta = abs(left.energy - right.energy)
            let activityChanged = left.activity != nil && right.activity != nil && left.activity != right.activity
            let hasVisualTransition = incoming.transition.flatMap(TransitionStyle.init(rawValue:)) != nil ||
                timeline.effectiveTransitionItems.contains { $0.enabled && $0.incomingClipID == incoming.id }
            let editConfidence = incoming.incomingEditDecision?.confidence ?? 0

            var confidence = 0.0
            var reasons: [String] = []
            if activityChanged {
                confidence += 0.62
                reasons.append("Новая активность: \(right.activity?.localizedTitle ?? "новая часть")")
            }
            if eventChanged {
                confidence += 0.42
                reasons.append("Смена крупного события")
            }
            if sceneChanged { confidence += 0.10 }
            confidence += semanticDistance * 0.16
            confidence += min(0.12, max(0, energyDelta - 0.16) * 0.28)
            if hasVisualTransition {
                confidence += 0.08
                reasons.append("Граница поддержана визуальным переходом")
            }
            confidence += min(0.06, editConfidence * 0.06)
            confidence = confidence.clamped01
            if confidence >= boundaryThreshold {
                candidates.append(Boundary(
                    time: incoming.timelineStart,
                    confidence: confidence,
                    incomingItemID: incoming.id,
                    explanation: reasons
                ))
            }
        }

        let maximumChanges = max(1, Int(floor(timeline.duration / 24)))
        var selected: [Boundary] = []
        for candidate in candidates.sorted(by: {
            $0.confidence == $1.confidence ? $0.time < $1.time : $0.confidence > $1.confidence
        }) {
            guard selected.count < maximumChanges,
                  candidate.time >= minimumPartDuration,
                  timeline.duration - candidate.time >= minimumPartDuration,
                  selected.allSatisfy({ abs($0.time - candidate.time) >= minimumPartDuration }) else { continue }
            selected.append(candidate)
        }
        return selected.sorted { $0.time < $1.time }
    }

    private func context(in values: [Observation], from start: Int, direction: Int) -> Context {
        var index = start
        var duration = 0.0
        var weightedEnergy = 0.0
        var activities: [Activity: Double] = [:]
        var tokens: Set<String> = []
        while values.indices.contains(index), duration < 14 {
            let observation = values[index]
            let weight = min(observation.duration, 6)
            duration += weight
            weightedEnergy += observation.energy * weight
            if let activity = observation.activity { activities[activity, default: 0] += weight }
            tokens.formUnion(observation.tokens)
            index += direction
        }
        let dominant = activities.max { $0.value < $1.value }
        let activity = dominant.flatMap { $0.value / max(0.001, duration) >= 0.36 ? $0.key : nil }
        return Context(activity: activity, tokens: tokens, energy: weightedEnergy / max(0.001, duration))
    }

    private func makeParts(
        observations: [Observation],
        boundaries: [Boundary],
        duration: Double,
        softPolicy: Bool, mood: DirectorNarrativeMood? = nil
    ) -> [Part] {
        let starts = [0.0] + boundaries.map(\.time)
        let ends = boundaries.map(\.time) + [duration]
        return zip(starts, ends).enumerated().map { index, range in
            let members = observations.filter {
                $0.item.timelineStart < range.1 && $0.item.timelineStart + $0.item.timelineDuration > range.0
            }
            let memberDuration = members.map(\.duration).reduce(0, +)
            var activities: [Activity: Double] = [:]
            var tokens: Set<String> = []
            var weightedEnergy = 0.0
            for member in members {
                let weight = min(member.duration, max(0.05, range.1 - range.0))
                if let activity = member.activity { activities[activity, default: 0] += weight }
                tokens.formUnion(member.tokens)
                weightedEnergy += member.energy * weight
            }
            let activity = activities.max { $0.value < $1.value }?.key
            var energy = (weightedEnergy / max(0.001, memberDuration)).clamped01
            if softPolicy { energy = min(energy, 0.38) }
            let cutRate = Double(max(0, members.count - 1)) / max(1, range.1 - range.0)
            var musical = Self.musicalIntent(activity: activity, tokens: tokens, energy: energy, cutRate: cutRate, softPolicy: softPolicy)
            if !softPolicy, let mood {
                switch mood {
                case .cinematic: musical.style = .cinematic
                case .calm: musical.style = .calm; energy = min(energy, 0.42); musical.bpm = min(musical.bpm, 92)
                case .dynamic: break
                }
            }
            return Part(
                start: range.0,
                end: range.1,
                activity: activity,
                tokens: tokens,
                energy: energy,
                cutRate: cutRate,
                boundary: index == 0 ? nil : boundaries[index - 1],
                style: musical.style,
                bpm: musical.bpm,
                label: activity?.localizedTitle ?? Self.fallbackLabel(tokens: tokens, index: index)
            )
        }
    }

    private func chooseTrack(
        for part: Part,
        directive: MusicDirective,
        tracks: [LocalMusicTrack],
        previous: Decision?,
        preferredID: UUID?
    ) -> LocalMusicTrack? {
        if let request = directive.searchRequests?.first, request.exactTrack,
           let exact = tracks.first(where: { request.matches(title: $0.title, artist: $0.author) }) { return exact }
        let tracks = tracks.filter { AutomaticSoundtrackSuitability.accepts($0, directive: directive) }
        func score(_ track: LocalMusicTrack) -> Double {
            let selectorScore = LocalMusicSelector().score(track, directive: directive)
            let durationFit = min(1, track.duration / max(1, part.duration + 2))
            let energyFit = 1 - abs(track.energy - part.energy)
            var coherence = 0.55
            if let previous {
                let tempo = max(0, 1 - abs(track.bpm - previous.track.bpm) / 90)
                let key = Self.keyCompatibility(track.musicalKey, previous.track.musicalKey)
                coherence = tempo * 0.58 + key * 0.42
            }
            let preferredBonus = track.id == preferredID ? 0.055 : 0
            return selectorScore * 0.62 + durationFit * 0.14 + energyFit * 0.14 + coherence * 0.10 + preferredBonus
        }

        guard let best = tracks.max(by: { score($0) < score($1) }) else { return nil }
        guard let previous, tracks.contains(where: { $0.id == previous.track.id }) else { return best }
        let current = previous.track
        let currentScore = score(current)
        let alternatives = tracks.filter { $0.id != current.id }
        guard let alternative = alternatives.max(by: { score($0) < score($1) }) else { return current }
        let alternativeScore = score(alternative)
        let activityChanged = previous.part.activity != nil && part.activity != nil && previous.part.activity != part.activity
        let musicalChange = previous.part.style != part.style || abs(previous.part.energy - part.energy) >= 0.22
        guard activityChanged && musicalChange else { return current }

        // Both content and musical intent must change. Activity alone cannot
        // justify replacing a suitable composition.
        let tolerance = -0.055
        guard alternativeScore >= 0.30,
              alternativeScore + tolerance >= currentScore else { return current }
        return alternative
    }

    private func mergingUnchangedTracks(_ values: [Decision]) -> [Decision] {
        var result: [Decision] = []
        for value in values {
            guard var previous = result.last, previous.track.id == value.track.id else {
                result.append(value)
                continue
            }
            result.removeLast()
            let oldDuration = previous.part.duration
            let combinedDuration = oldDuration + value.part.duration
            previous.part.end = value.part.end
            previous.part.energy = (previous.part.energy * oldDuration + value.part.energy * value.part.duration) / combinedDuration
            previous.part.cutRate = (previous.part.cutRate * oldDuration + value.part.cutRate * value.part.duration) / combinedDuration
            previous.part.tokens.formUnion(value.part.tokens)
            if previous.part.activity != value.part.activity {
                previous.part.activity = nil
                previous.part.label = "\(previous.part.label) · \(value.part.label)"
            }
            result.append(previous)
        }
        return result
    }

    private static func musicalIntent(
        activity: Activity?,
        tokens: Set<String>,
        energy: Double,
        cutRate: Double,
        softPolicy: Bool
    ) -> (style: MusicStyle, bpm: Double) {
        if softPolicy {
            return (tokens.contains("acoustic") || tokens.contains("акустика") ? .acoustic : .calm,
                    min(94, 66 + energy * 58 + min(7, cutRate * 22)))
        }
        let style: MusicStyle
        switch activity {
        case .actionVehicle:
            style = energy >= 0.48 ? .energetic : .cinematic
        case .fishing:
            style = tokens.contains("guitar") || tokens.contains("гитара") ? .acoustic : .calm
        case .cycling:
            style = energy >= 0.56 ? .energetic : .joyful
        case .paddling, .running, .swimming, .winterSports, .surfing, .climbing:
            style = energy >= 0.56 ? .energetic : .cinematic
        case .hiking, .equestrian:
            style = energy >= 0.58 ? .cinematic : .calm
        case nil:
            style = energy >= 0.68 ? .energetic : (energy <= 0.36 ? .calm : .cinematic)
        }
        let base: Double
        switch style {
        case .calm: base = 64 + energy * 58
        case .acoustic: base = 72 + energy * 52
        case .cinematic: base = 74 + energy * 60
        case .joyful: base = 82 + energy * 55
        case .energetic: base = 104 + energy * 42
        case .electronic: base = 100 + energy * 44
        }
        return (style, min(158, max(58, base + min(12, cutRate * 30))))
    }

    private static func fallbackLabel(tokens: Set<String>, index: Int) -> String {
        if let value = tokens.sorted().first { return value.capitalized }
        return "Часть \(index + 1)"
    }

    private static func roleEnergy(_ role: StoryRole?) -> Double {
        switch role {
        case .action, .climax: return 0.86
        case .buildup: return 0.66
        case .setup, .bRoll: return 0.45
        case .intro, .reaction, .outro: return 0.30
        case nil: return 0.50
        }
    }

    private static func activity(in source: String) -> Activity? {
        let text = normalized(source)
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var semanticTokens = Set(words)
        semanticTokens.insert(text)
        if words.count >= 2 {
            for index in 0..<(words.count - 1) {
                semanticTokens.insert("\(words[index]) \(words[index + 1])")
            }
        }
        switch ActivityCompatibilityContract.evidence(in: semanticTokens).family {
        case .cycling: return .cycling
        case .motorized: return .actionVehicle
        case .paddling: return .paddling
        case .fishing: return .fishing
        case .hiking: return .hiking
        case .running: return .running
        case .swimming: return .swimming
        case .winterSports: return .winterSports
        case .surfing: return .surfing
        case .climbing: return .climbing
        case .equestrian: return .equestrian
        case nil: return nil
        }
    }

    private static func tokens(in source: String) -> Set<String> {
        let stop: Set<String> = [
            "with", "from", "that", "this", "into", "scene", "shot", "video", "clip",
            "кадр", "сцена", "видео", "клип", "этот", "здесь", "через", "после", "перед"
        ]
        return Set(normalized(source)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stop.contains($0) })
    }

    private static func normalized(_ source: String) -> String {
        source.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func semanticDistance(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 0 }
        return 1 - Double(lhs.intersection(rhs).count) / Double(max(1, lhs.union(rhs).count))
    }

    private static func keyCompatibility(_ lhs: String?, _ rhs: String?) -> Double {
        guard let lhs = lhs?.lowercased(), let rhs = rhs?.lowercased(), !lhs.isEmpty, !rhs.isEmpty else { return 0.55 }
        if lhs == rhs { return 1 }
        let leftRoot = lhs.prefix { $0.isLetter || $0 == "#" || $0 == "♭" }
        let rightRoot = rhs.prefix { $0.isLetter || $0 == "#" || $0 == "♭" }
        return leftRoot == rightRoot ? 0.82 : 0.34
    }
}
