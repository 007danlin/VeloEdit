import Foundation

/// Tempo and energy describe movement, not emotional tone. A lively travel
/// film must not acquire horror/aggressive music merely to avoid a repeat.
enum AutomaticSoundtrackSuitability {
    private static let harsh: Set<String> = ["aggressive", "abrasive", "harsh", "distorted", "metal", "dubstep", "industrial", "intense"]
    private static let dark: Set<String> = ["horror", "funeral", "funereal", "mournful", "tragic", "tragical", "somber", "sombre", "ominous", "sinister", "eerie", "creepy", "dark", "dread", "depressing"]
    private static let sad: Set<String> = ["sad", "sadness", "sorrow", "sorrowful", "melancholic", "melancholy", "grief", "grieving", "lament", "bleak", "despair", "hopeless"]
    private static let tense: Set<String> = ["suspense", "suspenseful", "tense", "tension", "anxious", "unsettling", "haunting", "disturbing"]
    private static let bright: Set<String> = ["bright", "happy", "joyful", "upbeat", "uplifting", "cheerful", "fun", "groove", "disco", "funk", "playful", "summer", "warm"]

    static func accepts(genres: [String], moods: [String], tags: [String], request: MusicSearchRequest?) -> Bool {
        if request?.exactTrack == true { return true }
        // Only an actual music request can ask for these tones. Automatically
        // inferred high energy / cinematic mood is not permission for them.
        let wanted = request.map { MusicSearchRequest.positiveDescriptorWords($0.query) } ?? []
        let declared = MusicSearchRequest.words((genres + moods).joined(separator: " "))
        let all = declared.union(MusicSearchRequest.words(tags.joined(separator: " ")))
        for unwanted in [dark, sad, tense] {
            // An explicit warning in the description (e.g. "depict grief")
            // outweighs a generic "relaxed/uplifting" catalogue label.
            if wanted.isDisjoint(with: unwanted), !all.isDisjoint(with: unwanted) { return false }
        }
        if wanted.isDisjoint(with: harsh),
           !declared.isDisjoint(with: harsh) || all.intersection(harsh).count >= 2 { return false }
        return true
    }

    static func accepts(_ track: LocalMusicTrack, directive: MusicDirective) -> Bool {
        track.id == directive.trackID || accepts(genres: track.genres, moods: track.moods,
            tags: track.tags ?? [], request: directive.searchRequests?.first)
    }

    static func accepts(_ track: MusicProviderTrack, intent: MusicIntent) -> Bool {
        accepts(genres: track.metadata.genres, moods: track.metadata.moods,
            tags: track.metadata.tags, request: intent.request)
    }

    static func characterAdjustment(genres: [String], moods: [String], tags: [String], desired: Set<String>, request: MusicSearchRequest? = nil) -> Double {
        let explicit = request.map { MusicSearchRequest.positiveDescriptorWords($0.query) } ?? []
        guard request?.exactTrack != true,
              explicit.isDisjoint(with: dark.union(sad).union(tense).union(harsh)) else { return 0 }
        let preferred: Set<String>
        let mismatched: Set<String>
        let cinematic: Bool
        if !desired.isDisjoint(with: ["energetic", "electronic", "upbeat", "happy", "joyful", "summer"]) {
            preferred = bright
            mismatched = []
            cinematic = false
        } else if !desired.isDisjoint(with: ["calm", "ambient", "soft", "peaceful", "acoustic"]) {
            preferred = ["warm", "peaceful", "gentle", "serene", "soothing", "relaxed", "relaxing", "calming", "tender", "light", "hopeful"]
            mismatched = ["bouncy", "grooving", "driving", "humorous", "comedic", "comedy"]
            cinematic = false
        } else if !desired.isDisjoint(with: ["cinematic", "orchestral", "inspiring", "hopeful"]) {
            preferred = ["inspiring", "inspirational", "uplifting", "hopeful", "majestic", "soaring", "heroic", "adventurous", "expansive", "warm", "bright"]
            mismatched = ["humorous", "comedic", "comedy", "quirky", "holiday", "christmas", "rap", "disco", "funk", "reggae"]
            cinematic = true
        } else if desired.contains("bright") {
            preferred = bright
            mismatched = []
            cinematic = false
        } else { return 0 }
        let declared = MusicSearchRequest.words((genres + moods).joined(separator: " "))
        let supporting = MusicSearchRequest.words(tags.joined(separator: " "))
        // Instrument/description aliases are weak evidence. In particular,
        // "guitar" must not make an otherwise neutral track emotionally warm.
        let penalty = explicit.isDisjoint(with: mismatched)
            ? min(0.24, Double(declared.intersection(mismatched).count) * 0.12) : 0
        let cinemaEvidence: Set<String> = ["cinematic", "orchestral", "orchestra", "soundtrack", "score", "epic", "majestic", "soaring", "heroic", "classical"]
        let genreWeight = cinematic && declared.isDisjoint(with: cinemaEvidence) ? 0.20 : 1.0
        return (min(0.24, Double(declared.intersection(preferred).count) * 0.10)
            + min(0.02, Double(supporting.intersection(preferred).count) * 0.005)) * genreWeight - penalty
    }

    static func semanticMatch(genres: [String], moods: [String], tags: [String], desired: Set<String>) -> Double {
        let declared = descriptiveTokens(genres + moods)
        let supporting = MusicSearchRequest.words(tags.joined(separator: " "))
        let wanted = MusicSearchRequest.words(desired.sorted().joined(separator: " "))
        guard !wanted.isEmpty else { return 0 }
        let strong = declared.intersection(wanted).count
        let weak = supporting.subtracting(declared).intersection(wanted).count
        return (Double(strong) + Double(weak) * 0.20) / Double(wanted.count)
    }

    /// Expand only actual genre/mood declarations, never instrumentation.
    static func descriptiveTokens(_ values: [String]) -> Set<String> {
        let original = MusicSearchRequest.words(values.joined(separator: " "))
        var result = original
        let aliases: [(Set<String>, Set<String>)] = [
            (["driving", "bouncy", "grooving", "groovy"], ["energetic", "upbeat"]),
            (["bright", "uplifting", "cheerful", "happy", "joyful"], ["bright", "happy", "joyful", "upbeat"]),
            (["disco", "funk", "funky"], ["groove", "upbeat", "energetic"]),
            (["electronica", "electronic", "disco"], ["electronic"]),
            (["calming", "relaxed", "relaxing", "peaceful", "gentle", "serene", "soothing"], ["calm", "soft", "ambient"]),
            (["inspirational", "uplifting", "hopeful"], ["inspiring", "hopeful"]),
            (["orchestra", "orchestral", "epic"], ["cinematic"])
        ]
        for (from, to) in aliases where !original.isDisjoint(with: from) { result.formUnion(to) }
        return result
    }
}
