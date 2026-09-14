import Foundation
import Testing
@testable import VeloEditCore

@Suite struct AutomaticSoundtrackSuitabilityTests {
    private func tracks(at root: URL) throws -> [LocalMusicTrack] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("fixture.audio")
        try Data([0]).write(to: file)
        // Real catalogue descriptors of the approved and rejected recordings.
        return [("Bright groove", ["disco"], ["bright", "driving"], ["energetic", "upbeat", "warm", "bass"]),
                ("Acid atmosphere", ["unclassifiable"], ["aggressive", "intense", "mysterious", "mystical"], ["electronic", "energetic", "cinematic", "upbeat"]),
                ("Funeral", ["soundtrack"], ["somber", "mournful"], ["melodic", "cinematic"])].map { title, genres, moods, tags in
            LocalMusicTrack(title: title, author: "Fixture", bpm: 110, genres: genres, moods: moods,
                energy: 0.78, duration: 300, license: .userFile(), sourceProvider: .user,
                sourcePageURL: URL(string: "about:blank")!, localFileURL: file, originalFileName: file.lastPathComponent, tags: tags)
        }
    }

    @Test func highEnergyAndMatchingTempoDoNotAdmitHarshOrFunerealMusic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try tracks(at: root)
        for style in [MusicStyle.energetic, .electronic, .cinematic, .calm] {
            let directive = MusicDirective(style: style, bpm: 110)
            #expect(LocalMusicSelector().select(for: directive, from: catalog)?.id == catalog[0].id)
            #expect(LocalMusicSelector().select(for: directive, from: Array(catalog.dropFirst())) == nil)
            #expect(MusicLibrary.suitableLocalTrack(for: MusicIntent(directive: directive), tracks: Array(catalog.dropFirst())) == nil)
        }
        let explicit = MusicDirective(style: .energetic, bpm: 110, searchRequests: [.init(query: "aggressive electronic")])
        #expect(AutomaticSoundtrackSuitability.accepts(catalog[1], directive: explicit))
        let named = MusicDirective(style: .calm, bpm: 110, searchRequests: [.init(query: "Funeral", exactTrack: true)])
        #expect(LocalMusicSelector().select(for: named, from: catalog)?.id == catalog[2].id)
    }

    @Test func exhaustedNoveltyPrefersASuitableRepeatAndNeverUsesAnUnsafeFirstTrack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try tracks(at: root)
        let library = LocalMusicLibrary(rootURL: root)
        try JSONEncoder.veloEdit.encode(Array(catalog.reversed())).write(to: root.appendingPathComponent("tracks.json"))
        let system = MusicLibrary(localLibrary: library, providers: [])
        let intent = MusicIntent(directive: MusicDirective(style: .electronic, bpm: 110))
        let result = await system.resolve(intent, excludingIdentities: catalog[0].noveltyIdentities, preferFreshOnline: true)
        #expect(result.track?.id == catalog[0].id)
        try JSONEncoder.veloEdit.encode(Array(catalog.dropFirst())).write(to: root.appendingPathComponent("tracks.json"))
        let reopened = MusicLibrary(localLibrary: LocalMusicLibrary(rootURL: root), providers: [])
        let unavailable = await reopened.resolve(intent, preferFreshOnline: true)
        #expect(unavailable.track == nil)
    }

    @Test func genuineMoodOutranksTempoAndDescriptionTagStuffingOnlineAndOffline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var bright = try tracks(at: root)[0]
        bright.title = "Another sunny groove"
        bright.genres = ["funk"]
        bright.bpm = 116
        bright.energy = 0.70
        var neutral = bright
        neutral.id = UUID()
        neutral.title = "Neutral synth pulse"
        neutral.genres = ["electronic"]
        neutral.moods = ["energetic"]
        neutral.tags = ["travel", "adventure", "cinematic", "emotional", "warm", "bright", "happy", "joyful", "upbeat", "melodic"]
        neutral.bpm = 110
        neutral.energy = 0.78
        let directive = MusicDirective(style: .energetic, bpm: 110)
        let intent = MusicIntent(directive: directive, timelineDuration: 300)
        #expect(LocalMusicSelector().select(for: directive, from: [bright, neutral])?.id == bright.id)
        #expect(MusicLibrary.candidateScore(MusicProviderTrack(local: bright), intent: intent) > MusicLibrary.candidateScore(MusicProviderTrack(local: neutral), intent: intent))
        #expect(intent.request == nil)
        #expect(intent.searchQuery.contains("groove"))

        // The same preference must not turn a quiet film into a dance video.
        var calm = neutral
        calm.id = UUID()
        calm.genres = ["ambient", "acoustic"]
        calm.moods = ["calm", "soft"]
        calm.tags = []
        calm.energy = 0.28
        calm.bpm = 75
        let quiet = MusicDirective(style: .calm, bpm: 75)
        #expect(LocalMusicSelector().select(for: quiet, from: [bright, calm])?.id == calm.id)
        let quietIntent = MusicIntent(directive: quiet)
        #expect(MusicLibrary.candidateScore(MusicProviderTrack(local: calm), intent: quietIntent) > MusicLibrary.candidateScore(MusicProviderTrack(local: bright), intent: quietIntent))
        #expect(!quietIntent.searchQuery.contains("groove"))
    }

    @Test func instrumentsDoNotInventEmotionalToneInTheOfficialCatalogue() throws {
        let row: [String: Any] = ["isrc": "fixture", "title": "Neutral", "filename": "Neutral.mp3", "length": "03:00", "bpm": "110", "genre": "1", "feel": "Neutral", "instruments": "Guitar, strings, synths", "description": ""]
        let tracks = try IncompetechMusicProvider.candidates(data: JSONSerialization.data(withJSONObject: [row]), genreData: Data(#"[{"id":1,"genre":"Unclassifiable"}]"#.utf8))
        let track = try #require(tracks.first)
        #expect(Set(track.metadata.tags).isDisjoint(with: ["warm", "emotional", "orchestral", "folk"]))
        #expect(track.metadata.energy == 0.44)
        let words = AutomaticSoundtrackSuitability.descriptiveTokens(["Disco", "Bright, Driving"])
        #expect(Set(["energetic", "upbeat", "bright", "groove", "electronic"]).isSubset(of: words))
    }

    @Test func calmAndCinematicPreferPositiveCharacterAndExcludeSadnessAndSuspense() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = try tracks(at: root)[0]
        for style in [MusicStyle.calm, .cinematic] {
            let directive = MusicDirective(style: style, bpm: style == .calm ? 72 : 88)
            let intent = MusicIntent(directive: directive)
            var positive = seed
            positive.id = UUID()
            positive.genres = style == .calm ? ["ambient", "acoustic"] : ["cinematic", "orchestral"]
            positive.moods = style == .calm ? ["calm", "peaceful", "warm", "gentle"] : ["inspiring", "hopeful", "majestic"]
            positive.tags = []
            positive.energy = intent.energy
            positive.bpm = directive.bpm
            var neutral = positive
            neutral.id = UUID()
            neutral.moods = style == .calm ? ["calm"] : ["dramatic", "emotional"]
            #expect(LocalMusicSelector().select(for: directive, from: [positive, neutral])?.id == positive.id)
            #expect(MusicLibrary.candidateScore(MusicProviderTrack(local: positive), intent: intent) > MusicLibrary.candidateScore(MusicProviderTrack(local: neutral), intent: intent))
            for mood in ["sad", "melancholic", "sorrowful", "somber", "mournful", "suspenseful", "haunting"] {
                var rejected = positive
                rejected.id = UUID()
                rejected.moods.append(mood)
                #expect(!AutomaticSoundtrackSuitability.accepts(rejected, directive: directive))
                #expect(!AutomaticSoundtrackSuitability.accepts(MusicProviderTrack(local: rejected), intent: intent))
                #expect(LocalMusicSelector().select(for: directive, from: [rejected]) == nil)
            }
            #expect(!intent.searchQuery.contains("dramatic"))
            #expect(intent.searchQuery.contains(style == .calm ? "peaceful" : "hopeful"))
        }
    }

    @Test func explicitSadRequestIsHonoredButNegationNeverEnablesSadness() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var sad = try tracks(at: root)[0]
        sad.moods = ["sad", "melancholic"]
        sad.genres = ["piano"]
        for prompt in ["Добавь грустную музыку", "Добавь музыку sad piano"] {
            let requests = MusicSearchRequest.parse(prompt)
            #expect(requests.first?.query.contains("sad") == true)
            #expect(AutomaticSoundtrackSuitability.accepts(sad, directive: .init(style: .calm, bpm: 72, searchRequests: requests)))
        }
        for prompt in ["Добавь спокойную музыку без грусти", "Добавь спокойную, не грустную музыку", "Добавь музыку not sad piano"] {
            let requests = MusicSearchRequest.parse(prompt)
            #expect(requests.first?.query.contains("sad") != true)
            #expect(!AutomaticSoundtrackSuitability.accepts(sad, directive: .init(style: .calm, bpm: 72, searchRequests: requests)))
        }
        #expect(!AutomaticSoundtrackSuitability.accepts(sad, directive: .init(style: .calm, bpm: 72, searchRequests: [.init(query: "not sad piano")])))
        #expect(MusicSearchRequest.parse("Добавь спокойную музыку без вокала").first?.query.contains("instrumental") == true)
    }

    @Test func descriptionWarningsOverrideOptimisticLabelsAndCinemaRequiresGenreEvidence() throws {
        let base: [String: Any] = ["isrc": "fixture", "title": "Piano", "filename": "Piano.mp3", "length": "03:00", "bpm": "72", "genre": "1", "feel": "Calming, Relaxed, Uplifting", "instruments": "Piano"]
        for description in ["Elegant and slightly dark piano.", "This piece could depict grief.", "A sad, melancholic melody."] {
            var row = base
            row["description"] = description
            let track = try #require(IncompetechMusicProvider.candidates(data: JSONSerialization.data(withJSONObject: [row])).first)
            for style in [MusicStyle.calm, .cinematic] {
                #expect(!AutomaticSoundtrackSuitability.accepts(track, intent: .init(directive: .init(style: style, bpm: 72))))
            }
        }
        var row = base
        row["description"] = "Warm piano, not sad, not dark."
        let warm = try #require(IncompetechMusicProvider.candidates(data: JSONSerialization.data(withJSONObject: [row])).first)
        #expect(AutomaticSoundtrackSuitability.accepts(warm, intent: .init(directive: .init(style: .calm, bpm: 72))))
        let intent = MusicIntent(directive: .init(style: .cinematic, bpm: 88))
        var score = warm
        score.metadata.genres = ["orchestral", "soundtrack"]
        score.metadata.moods = ["uplifting", "epic"]
        score.metadata.tags = []
        var holiday = score
        holiday.metadata.genres = ["holiday"]
        holiday.metadata.moods = ["bright", "uplifting"]
        #expect(MusicLibrary.candidateScore(score, intent: intent) > MusicLibrary.candidateScore(holiday, intent: intent))
    }

    @Test func liveTravelSelectionFindsNewMusicWithoutNamingTheApprovedTrack() async throws {
        guard ProcessInfo.processInfo.environment["VELOEDIT_LIVE_TRAVEL_MUSIC_TEST"] == "1" else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VeloEdit-TravelMusic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = LocalMusicLibrary(rootURL: root)
        let provider = IncompetechMusicProvider(library: local)
        let system = MusicLibrary(localLibrary: local, providers: [provider])
        let intent = MusicIntent(directive: .init(style: .energetic, bpm: 110), timelineDuration: 300)
        let catalog = try await provider.search(intent)
        let approved = try #require(catalog.first { $0.id == "USUAN1100237" })
        let rejected = try #require(catalog.first { $0.id == "USUAN1100233" })
        #expect(!AutomaticSoundtrackSuitability.accepts(rejected, intent: intent))
        let firstResult = await system.resolve(intent, excludingIdentities: approved.noveltyIdentities, preferFreshOnline: true)
        print("Travel music diagnostics: \(firstResult.failures)")
        let first = try #require(firstResult.track)
        let exclusions = approved.noveltyIdentities.union(first.noveltyIdentities)
        let second = try #require(await system.resolve(intent, excludingIdentities: exclusions, preferFreshOnline: true).track)
        #expect(first.providerTrackID != approved.id && second.providerTrackID != approved.id)
        #expect(first.selectionIdentity != second.selectionIdentity)
        for track in [first, second] {
            #expect(track.isPlayable)
            #expect(track.duration >= 45)
            #expect(track.waveform?.isEmpty == false)
            #expect(AutomaticSoundtrackSuitability.characterAdjustment(genres: track.genres, moods: track.moods, tags: track.tags ?? [], desired: intent.mood) >= 0.10)
        }
        let ranked = catalog.filter { $0.noveltyIdentities.isDisjoint(with: approved.noveltyIdentities) && AutomaticSoundtrackSuitability.accepts($0, intent: intent) }
            .sorted { MusicLibrary.candidateScore($0, intent: intent) > MusicLibrary.candidateScore($1, intent: intent) }
        let report: [String: Any] = ["request": ["style": "energetic", "bpm": 110, "duration": 300, "namedTrack": false], "catalogCount": catalog.count,
            "excludedReference": approved.metadata.title, "rejectedUnsuitable": rejected.metadata.title,
            "selected": [first, second].map { ["title": $0.title, "providerID": $0.providerTrackID ?? "", "genres": $0.genres, "moods": $0.moods, "bpm": $0.bpm, "duration": $0.duration, "waveformSamples": $0.waveform?.count ?? 0, "source": $0.sourcePageURL.absoluteString] as [String: Any] },
            "topCandidates": ranked.prefix(8).map { ["title": $0.metadata.title, "genres": $0.metadata.genres, "moods": $0.metadata.moods, "bpm": $0.metadata.bpm, "score": MusicLibrary.candidateScore($0, intent: intent)] as [String: Any] }]
        if let path = ProcessInfo.processInfo.environment["VELOEDIT_TRAVEL_MUSIC_REPORT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("Travel music verified: \(first.title); \(second.title); catalogue \(catalog.count)")
    }

    @Test func liveCalmAndCinematicSelection() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VELOEDIT_LIVE_MOOD_MUSIC_AUDIT"] == "1" else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VeloEdit-MoodMusic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = LocalMusicLibrary(rootURL: root)
        let provider = IncompetechMusicProvider(library: local)
        let system = MusicLibrary(localLibrary: local, providers: [provider])
        var reports: [[String: Any]] = []
        var used: Set<String> = []
        for (style, bpm) in [(MusicStyle.calm, 72.0), (.cinematic, 88.0)] {
            let intent = MusicIntent(directive: .init(style: style, bpm: bpm), timelineDuration: 180)
            let catalog = try await provider.search(intent)
            let ranked = catalog.filter { AutomaticSoundtrackSuitability.accepts($0, intent: intent) }
                .sorted { MusicLibrary.candidateScore($0, intent: intent) > MusicLibrary.candidateScore($1, intent: intent) }
            var selected: [[String: Any]] = []
            if environment["VELOEDIT_MOOD_MUSIC_DOWNLOAD"] == "1" {
                for _ in 0..<2 {
                    let result = await system.resolve(intent, excludingIdentities: used, preferFreshOnline: true)
                    let track = try #require(result.track)
                    #expect(track.noveltyIdentities.isDisjoint(with: used))
                    used.formUnion(track.noveltyIdentities)
                    #expect(track.isPlayable && track.duration >= 45 && track.waveform?.isEmpty == false)
                    let actual = try #require(catalog.first { $0.id == track.providerTrackID })
                    let moods = MusicSearchRequest.words(actual.metadata.moods.joined(separator: " "))
                    let positives: Set<String> = style == .calm
                        ? ["calming", "calm", "relaxed", "relaxing", "peaceful", "gentle", "soothing", "warm", "serene"]
                        : ["uplifting", "inspiring", "inspirational", "hopeful", "majestic", "epic", "bright", "heroic"]
                    #expect(!moods.isDisjoint(with: positives))
                    if style == .cinematic {
                        let genres = MusicSearchRequest.words(actual.metadata.genres.joined(separator: " "))
                        #expect(genres.isDisjoint(with: ["holiday", "disco", "reggae", "rap"]))
                        #expect(!genres.union(moods).isDisjoint(with: ["soundtrack", "cinematic", "orchestral", "classical", "epic", "majestic"]))
                    }
                    selected.append(["title": track.title, "genres": track.genres, "moods": track.moods,
                        "catalogBPM": actual.metadata.bpm, "duration": track.duration,
                        "waveformSamples": track.waveform?.count ?? 0, "source": track.sourcePageURL.absoluteString])
                }
            }
            reports.append(["style": style.rawValue, "query": intent.searchQuery, "catalogCount": catalog.count,
                "selected": selected,
                "topCandidates": ranked.prefix(6).map { ["title": $0.metadata.title, "genres": $0.metadata.genres, "moods": $0.metadata.moods, "bpm": $0.metadata.bpm, "energy": $0.metadata.energy, "score": MusicLibrary.candidateScore($0, intent: intent)] as [String: Any] }])
        }
        if let path = environment["VELOEDIT_MOOD_MUSIC_REPORT"] {
            try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("Calm/cinematic music audit: \(reports)")
    }
}
