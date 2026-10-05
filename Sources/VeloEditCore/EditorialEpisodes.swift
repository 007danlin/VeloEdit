import Foundation

/// Source-backed editing hypotheses, kept separate from technical acceptance.
/// A position in a film never proves preparation, a climax or a conclusion.
public struct EditorialEpisode: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var assetID: UUID
    public var eventID: UUID?
    public var sceneID: UUID?
    public var candidateIDs: [UUID]
    public var context: Set<String>
    public var observedActions: Set<String>
    public var visiblePeople: Bool
    public var routeObservation: Bool
    public var purpose: String
    public var evidence: [String]
}

public struct EditorialEpisodePlan: Codable, Hashable, Sendable {
    public var version = 1
    public var episodes: [EditorialEpisode]
    public var limitations: [String]
    public var experiment: String?

    static func build(units: [EditorialUnit], sourceOrder: [UUID: Int]) -> Self {
        let contexts: [(String, Set<String>)] = [
            ("forest", ["forest", "trees", "woodland", "лес"]),
            ("open-land", ["field", "grassland", "meadow", "open field", "поле"]),
            ("water", ["river", "lake", "sea", "water_body", "река", "озеро"]),
            ("settlement", ["village", "city", "street", "building", "town", "деревня", "город"]),
            ("mountains", ["mountain", "mountains", "гора", "горы"])
        ]
        let routeTags: Set<String> = ["road", "path", "trail", "dirt_road", "cycling", "bicycle", "bike", "atv", "utv", "buggy"]
        let peopleTags: Set<String> = ["people", "person", "face", "adult", "cyclist"]
        var ranks = sourceOrder
        for unit in units where ranks[unit.candidate.assetID] == nil { ranks[unit.candidate.assetID] = (ranks.values.max() ?? -1) + 1 }
        let ordered = units.filter { !$0.candidate.excluded && $0.usableDuration > 0 }.sorted {
            let a = ranks[$0.candidate.assetID, default: 0], b = ranks[$1.candidate.assetID, default: 0]
            if a != b { return a < b }
            if $0.sourceRange.start != $1.sourceRange.start { return $0.sourceRange.start < $1.sourceRange.start }
            return $0.id.uuidString < $1.id.uuidString
        }
        var episodes: [EditorialEpisode] = []
        for unit in ordered {
            let tags = Set(unit.candidate.tags.map { $0.lowercased() })
            // Use the existing evidence threshold. No new aesthetic score or
            // class inferred from a file name, role score or timeline position.
            let measured = unit.evidence.confidence >= 0.55
            let setting = measured ? Set(contexts.filter { !tags.isDisjoint(with: $0.1) }.map(\.0)) : []
            let samples = unit.evidence.samples.filter { $0.confidence >= 0.65 }
            let states = Dictionary(grouping: samples.flatMap { Array($0.actionState) }, by: { $0 })
            let actions = Set(states.filter { $0.value.count >= 3 }.map(\.key))
            let people = measured && (!tags.isDisjoint(with: peopleTags) || samples.contains { !$0.subjectKinds.filter { $0 == .person || $0 == .face || $0 == .cyclist }.isEmpty })
            let route = measured && !setting.isEmpty && !tags.isDisjoint(with: routeTags)
            let outcome = !actions.isDisjoint(with: ["landing", "arriving", "catching", "waving", "hugging"])
            let purpose = outcome ? "observed-outcome" : !actions.isEmpty ? "observed-activity" : people ? "participants" : !setting.isEmpty ? "place-context" : "observation-unknown"
            if let last = episodes.last, last.assetID == unit.candidate.assetID,
               last.eventID == unit.eventID, last.sceneID == unit.sceneID,
               last.context == setting, last.observedActions == actions,
               last.visiblePeople == people, last.routeObservation == route {
                episodes[episodes.count - 1].candidateIDs.append(unit.id)
            } else {
                episodes.append(.init(id: EditorialIdentity.uuid("episode-v1-\(unit.id)"), assetID: unit.candidate.assetID,
                    eventID: unit.eventID, sceneID: unit.sceneID, candidateIDs: [unit.id], context: setting,
                    observedActions: actions, visiblePeople: people, routeObservation: route, purpose: purpose,
                    evidence: ["Source candidate tags and saved temporal observations; model evidence, not human labels",
                        measured ? "Temporal evidence available" : "Temporal evidence insufficient; no semantic shortening",
                        "No result or climax inferred from film position"]))
            }
        }
        return Self(episodes: episodes, limitations: [
            "Scene tags remain fallible model observations; inspect the exported film",
            "Missing ASR is unknown speech, not silence; emotion is not inferred",
            "File boundaries retain route anchors; episode order follows source order"
        ], experiment: EditorialCoherenceExperiment.current?.rawValue)
    }
}

/// Two independently reviewable A/B hypotheses. Off by default until human
/// preferences on real exports justify promotion; common to every AI mode.
enum EditorialCoherenceExperiment: String {
    case context = "context-v1"
    case conciseRoute = "concise-route-v1"
    static var current: Self? {
        ProcessInfo.processInfo.environment["VELOEDIT_COHERENCE_EXPERIMENT"].flatMap(Self.init(rawValue:))
    }

    static func protected(_ unit: EditorialUnit) -> Bool {
        if unit.candidate.locked || EditorialMomentPolicy.protectedRange(unit) != nil { return true }
        // DSP speech is not a transcript, but it is sufficient to withhold an
        // experimental deletion. Protect salient natural sounds as well.
        return unit.candidate.insights?.audioEvents?.contains {
            [.speech, .laughter, .applause, .scream, .impact, .splash].contains($0.kind) && $0.confidence >= 0.42
        } == true
    }

    static func contextCandidate(before first: EditorialUnit, plan: EditorialEpisodePlan, units: [UUID: EditorialUnit]) -> EditorialUnit? {
        guard let index = plan.episodes.firstIndex(where: { $0.candidateIDs.contains(first.id) }), index > 0,
              plan.episodes[index].visiblePeople else { return nil }
        let previous = plan.episodes[index - 1]
        guard previous.assetID == first.candidate.assetID, previous.eventID == first.eventID,
              !previous.visiblePeople, !previous.context.isEmpty else { return nil }
        return previous.candidateIDs.compactMap { units[$0] }.filter {
            !protected($0) && !$0.evidence.hasHardOcclusion && $0.quality >= 0.55 && $0.usableDuration >= 1.5 &&
                $0.evidence.usableRange.end <= first.evidence.usableRange.start
        }.sorted {
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            return $0.sourceRange.start < $1.sourceRange.start
        }.first
    }

    static func conciseRouteIDs(selected: Set<UUID>, plan: EditorialEpisodePlan, units: [UUID: EditorialUnit]) -> Set<UUID> {
        var retained = selected
        func labels(_ unit: EditorialUnit) -> Set<String> {
            // Preserve newly observed details beyond the coarse episode class
            // (an animal, bridge, obstacle, etc.). Ignore numeric diagnostics,
            // source filenames and role labels; these are not scene evidence.
            let characters = CharacterSet.letters.union(.whitespaces).union(CharacterSet(charactersIn: "_-"))
            let structural: Set<String> = ["intro", "outro", "climax", "setup", "action", "b-roll", "atmosphere", "g-force", "telemetry-event"]
            return Set(unit.candidate.tags.map { $0.lowercased() }.filter {
                !structural.contains($0) && !$0.isEmpty && $0.unicodeScalars.allSatisfy(characters.contains)
            })
        }
        for episode in plan.episodes where episode.routeObservation && !episode.visiblePeople && episode.observedActions.isEmpty {
            let present = episode.candidateIDs.filter { selected.contains($0) }
            guard present.count > 2 else { continue }
            var known = present.first.flatMap { units[$0] }.map(labels) ?? []
            // A testable anchor hypothesis, not a quality gate: preserve
            // entry/exit of the observed section, new details and useful sound.
            for id in present.dropFirst().dropLast() {
                guard let unit = units[id] else { continue }
                let observations = labels(unit)
                let addsInformation = !observations.isSubset(of: known)
                known.formUnion(observations)
                guard !protected(unit), !addsInformation else { continue }
                retained.remove(id)
            }
        }
        return retained
    }
}
