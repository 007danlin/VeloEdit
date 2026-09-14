import Foundation

/// Persisted separately from a resolved track title: a fallback must never
/// silently become the requested song on the next project open.
public struct MusicSearchRequest: Codable, Hashable, Sendable {
    public var query: String
    public var exactTrack: Bool
    public var scene: String?

    public init(query: String, exactTrack: Bool = false, scene: String? = nil) {
        self.query = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        self.exactTrack = exactTrack
        self.scene = scene
    }

    public func matches(title: String, artist: String) -> Bool {
        let wanted = Self.words(query)
        let actual = Self.words(title + " " + artist)
        let versions: Set<String> = ["cover", "karaoke", "tribute", "remix", "кавер", "караоке", "ремикс"]
        return !wanted.isEmpty && wanted.isSubset(of: actual) && actual.intersection(versions).isSubset(of: wanted)
    }

    static func words(_ value: String) -> Set<String> {
        Set(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    /// A prohibition such as "not sad" / "без грусти" must not authorize
    /// the very mood the user excluded. Leave vocal instructions untouched.
    static func positiveDescriptorWords(_ value: String) -> Set<String> {
        words(removingNegatedMoods(value))
    }

    private static func removingNegatedMoods(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?i)\b(?:не|без|not|no|without)\s+(?:(?:слишком|очень|too|very)\s+)?(?:груст|меланхол|мрач|тревож|агрессив|sad|melanchol|dark|tense|aggressiv|suspense|mournful|funeral)[\p{L}-]*"#,
            with: " ", options: .regularExpression)
    }

    public static func parse(_ prompt: String) -> [Self] {
        // Split instructions, not hyphenated artist names. Each clause can
        // carry its own scene and track; ordinary film instructions are ignored.
        let clauses = prompt.components(separatedBy: CharacterSet(charactersIn: "\n;.!"))
        var requests: [Self] = []
        for clause in clauses {
            let lower = clause.lowercased()
            let hasMusic = ["музык", "трек", "песн", "саундтр", "music", "song", "soundtrack"].contains(where: lower.contains)
            let hasCommand = ["поставь", "включи", "найди", "добавь", "используй", "play "].contains(where: lower.contains)
            let plainNamedCommand = lower.range(of: "^\\s*(поставь|включи|play)\\s+", options: .regularExpression) != nil &&
                !["видео", "кадр", "сцен", "титр", "переход", "эффект", "музыку"].contains(where: lower.contains) && translatedDescriptors(lower).isEmpty
            let quoteRegex = try? NSRegularExpression(pattern: "[«\"]([^»\"]+)[»\"]")
            let quoteMatches = quoteRegex?.matches(in: clause, range: NSRange(clause.startIndex..., in: clause)) ?? []
            let musicAnchor = ["музык", "трек", "песн", "саундтр", "music", "song", "soundtrack"]
                .compactMap { lower.range(of: $0).map { NSRange($0, in: lower).location } }
                .min()
            // A quote elsewhere in a compound instruction can be a title,
            // caption or chapter name. It is a song name only when it follows
            // the music clause, or when the whole clause is a plain “play X”.
            let quotedNames = quoteMatches.compactMap { match -> String? in
                guard plainNamedCommand || musicAnchor.map({ match.range.location >= $0 }) == true,
                      let range = Range(match.range(at: 1), in: clause) else { return nil }
                return String(clause[range])
            }
            let hasName = plainNamedCommand || clause.contains(" — ") || clause.contains(" – ") || clause.contains(" - ") || !quotedNames.isEmpty
            let descriptors = translatedDescriptors(lower)
            guard hasMusic || (hasCommand && hasName) || (!descriptors.isEmpty && lower.contains("для ")) else { continue }
            let scene: String? = {
                guard let regex = try? NSRegularExpression(pattern: "(?i)для\\s+([\\p{L}]+)"),
                      let match = regex.firstMatch(in: clause, range: NSRange(clause.startIndex..., in: clause)),
                      let range = Range(match.range(at: 1), in: clause) else { return nil }
                return String(clause[range]).lowercased()
            }()
            let similar = ["похож", "similar", "like "].contains(where: lower.contains)
            var names = quotedNames
            if names.isEmpty && hasCommand && hasName {
                var name = clause
                if let range = name.range(of: "(?i)(?:поставь|включи|найди|добавь|используй|play)\\s+(?:(?:трек|песню|музыку)\\s+)?", options: .regularExpression) {
                    name = String(name[range.upperBound...])
                }
                names = name.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            if !names.isEmpty {
                requests += names.filter { !$0.isEmpty }.map { Self(query: $0, exactTrack: !similar, scene: scene) }
            } else if !descriptors.isEmpty {
                requests.append(Self(query: descriptors.joined(separator: " "), scene: scene))
            } else if hasCommand, let range = clause.range(of: "(?i)(?:трек|песню)\\s+", options: .regularExpression) {
                let name = String(clause[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { requests.append(Self(query: name, exactTrack: !similar, scene: scene)) }
            }
        }
        var seen: Set<Self> = []
        return requests.filter { seen.insert($0).inserted }
    }

    static func translatedDescriptors(_ text: String) -> [String] {
        let text = removingNegatedMoods(text)
        let mapping: [(String, String)] = [
            ("агрессив", "aggressive"), ("энерг", "energetic"), ("динами", "upbeat"),
            ("спокой", "calm"), ("атмосфер", "ambient"), ("летн", "summer"), ("лёгк", "bright"),
            ("легк", "bright"), ("эмоцион", "emotional"), ("эпич", "cinematic"),
            ("рок", "rock"), ("электрон", "electronic"), ("акуст", "acoustic"),
            ("джаз", "jazz"), ("пиан", "piano"), ("без вокал", "instrumental"),
            ("груст", "sad"), ("меланхол", "melancholic"), ("мрач", "dark"), ("тревож", "tense"),
            ("вдохнов", "inspiring"), ("умиротвор", "peaceful"), ("мягк", "gentle"), ("тёпл", "warm"), ("тепл", "warm")
        ]
        let english = ["aggressive", "energetic", "upbeat", "calm", "ambient", "summer", "bright", "emotional", "cinematic", "rock", "electronic", "acoustic", "jazz", "piano", "instrumental", "metal", "techno", "folk", "pop", "sad", "melancholic", "dark", "tense", "inspiring", "hopeful", "peaceful", "gentle", "warm"]
        return Set(mapping.filter { text.contains($0.0) }.map(\.1) + english.filter { words(text).contains($0) }).sorted()
    }

    func applies(to label: String) -> Bool {
        guard let scene else { return false }
        let text = label.lowercased()
        let groups = [["багг", "экшен", "buggy", "action-vehicle"], ["рыбал", "fishing"], ["вел", "cycling"], ["дорог", "road"], ["вступ", "intro"], ["финал", "final"]]
        return groups.contains { group in group.contains(where: scene.contains) && group.contains(where: text.contains) }
            || text.contains(String(scene.prefix(5)))
    }
}


extension MusicProviderTrack {
    init(local track: LocalMusicTrack) {
        self.init(id: track.providerTrackID ?? track.id.uuidString, sourceProvider: track.sourceProvider,
                  metadata: MusicTrackMetadata(title: track.title, artist: track.author, genres: track.genres,
                    moods: track.moods, tags: track.tags ?? [], energy: track.energy, bpm: track.bpm,
                    duration: track.duration, sourceName: track.sourceProvider.localizedTitle,
                    loudness: track.loudness, waveform: track.waveform, musicalKey: track.musicalKey),
                  license: track.license, sourcePageURL: track.sourcePageURL, localFileURL: track.localFileURL)
    }
}
