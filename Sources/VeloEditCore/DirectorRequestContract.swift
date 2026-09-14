import Foundation

/// Shared by the chat router, compositor and delivery checks. The original
/// user request remains authoritative even when a model also paraphrases it.
public enum DirectorRequestContract {
    public static func requestsChapterTitles(_ prompt: String) -> Bool {
        guard EditorialIntentEnforcer.titleRequest(prompt) != false else { return false }
        return prompt.lowercased().components(separatedBy: CharacterSet(charactersIn: ".!?;\n")).contains { clause in
            let title = ["титр", "названи", "title", "caption"].contains(where: clause.contains)
            let part = ["част", "глав", "эпизод", "chapter", "part", "section"].contains(where: clause.contains)
            let every = ["кажд", "всех", "все части", "every", "each", "all "].contains(where: clause.contains)
            return title && part && every
        }
    }

    public static func requiresStoryRebuild(_ prompt: String) -> Bool {
        let text = prompt.lowercased()
        return requestsChapterTitles(prompt) || ["раздели", "разбей", "по частям", "не смешивай", "не перемешивай", "по порядку", "хронолог", "split into", "chapters", "don't mix", "chronolog"].contains(where: text.contains)
    }

    /// A full generation has already resolved these commands, including online
    /// acquisition and per-part music. Replaying them would select music again.
    public static func commandsAfterGeneration(_ commands: [EditorCommand]) -> [EditorCommand] {
        commands.filter { !["music", "telemetry"].contains($0.semanticCategory) }
    }

    public static func requestsCutaways(_ prompt: String) -> Bool {
        explicitlyRequests(prompt, subjects: ["перебив", "b-roll", "b roll", "cutaway"])
    }

    public static func requestsColorCorrection(_ prompt: String) -> Bool {
        explicitlyRequests(prompt, subjects: ["цветокор", "цветокорр", "грейд", "color grad", "color correct", "контраст", "насыщен", "экспозиц", "яркость", "фильтр", "filter"])
    }

    public static func requestsEffects(_ prompt: String) -> Bool {
        explicitlyRequests(prompt, subjects: ["эффект", "effect", "глитч", "glitch", "rgb"])
    }

    public static func authorizedCommands(_ commands: [EditorCommand], prompt: String, preset: FilmPreset) -> [EditorCommand] {
        let parsed = Set(EditorCommandParser().parse(prompt, preset: preset).map(\.semanticCategory))
        let requestedSourceVolume = OriginalAudioPromptInterpreter().volume(prompt: prompt)
        let color: Set<String> = ["filter", "brightness", "contrast", "saturation", "warmth", "exposure", "highlights", "shadows", "vignette", "grain", "auto-enhance"]
        let processing: Set<String> = ["effect", "sharpening", "video-denoise", "blur", "stabilization", "rolling-shutter", "noise-reduction", "eq"]
        return commands.filter { command in
            let category = command.semanticCategory
            if color.contains(category) { return parsed.contains(category) || requestsColorCorrection(prompt) }
            if processing.contains(category) { return parsed.contains(category) || requestsEffects(prompt) }
            return true
        }.map { command in
            // Model suggestions cannot replace the user's source-audio level.
            if case .setOriginalAudioVolume = command, let requestedSourceVolume {
                return .setOriginalAudioVolume(requestedSourceVolume)
            }
            return command
        }
    }

    private static func explicitlyRequests(_ prompt: String, subjects: [String]) -> Bool {
        var result = false
        for clause in prompt.lowercased().components(separatedBy: CharacterSet(charactersIn: ".!?;\n")) where subjects.contains(where: clause.contains) {
            if ["без ", "не добав", "не примен", "не использ", "убери", "убрать", "no ", "without", "don't", "do not", "remove"].contains(where: clause.contains) { result = false }
            else if ["добав", "сделай", "примен", "использ", "поправ", "исправ", "улучши", "настрой", "add ", "apply ", "use ", "correct ", "adjust "].contains(where: clause.contains) { result = true }
        }
        return result
    }
}

public enum EditorialCutawayPolicy {
    public static func allows(_ candidate: Candidate, over base: TimelineItem, plan: StoryPlan?, analyses: [AnalysisResult]) -> Bool {
        let baseCandidate = analyses.lazy.flatMap(\.directorCandidates).first { $0.id == base.candidateID }
        if let baseCandidate,
           !ActivityCompatibilityContract.canMergeClusterFamilies(
            ActivityCompatibilityContract.evidence(in: candidate.tags).clusterFamilies,
            ActivityCompatibilityContract.evidence(in: baseCandidate.tags).clusterFamilies) { return false }
        let chapter = plan?.chapters.first { $0.candidateIDs.contains(candidate.id) }
        let baseChapter = base.candidateID.flatMap { id in plan?.chapters.first { $0.candidateIDs.contains(id) } }
        let event = chapter?.eventID
        let baseEvent = base.eventID ?? baseChapter?.eventID
        if let event, let baseEvent, event != baseEvent { return false }
        let scene = chapter?.eventSceneID
        let baseScene = base.eventSceneID ?? baseChapter?.eventSceneID
        if let scene, let baseScene { return scene == baseScene }
        // Shared generic tags (people, sky, outdoors) do not establish that a
        // different recording belongs inside this scene.
        return candidate.assetID == base.assetID
    }

    public static func invalidOverlayIDs(in timeline: Timeline, plan: StoryPlan, analyses: [AnalysisResult]) -> Set<UUID> {
        let candidates = Dictionary(analyses.flatMap(\.directorCandidates).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(timeline.items.compactMap { item in
            guard let overlay = item.overlay, overlay.style == .cutaway,
                  let base = timeline.items.first(where: { $0.id == overlay.baseItemID }),
                  let id = item.candidateID, let candidate = candidates[id] else { return nil }
            return allows(candidate, over: base, plan: plan, analyses: analyses) ? nil : item.id
        })
    }
}
