import Foundation

public struct MusicPromptInterpreter: Sendable {
    public init() {}

    public func interpret(
        prompt: String,
        preset: FilmPreset,
        automaticDefault: Bool = false
    ) -> MusicDirective? {
        let value = prompt.lowercased()
        if value.contains("без музы") || value.contains("убери музыку") || value.contains("no music") {
            return nil
        }

        let changesOnlyVolume = [
            "приглуши музыку", "сделай музыку тише", "музыку потише",
            "убавь музыку", "громкость музыки", "music quieter", "lower the music"
        ].contains(where: value.contains)
        let alsoSelectsTrack = [
            "подбери", "выбери", "добавь", "поставь", "замени", "смени", "другой трек", "другую музыку"
        ].contains(where: value.contains)
        if changesOnlyVolume && !alsoSelectsTrack { return nil }

        let asksForMusic = [
            "музык", "саундтр", "трек", "песн", "мелоди",
            "подбери другой", "выбери другой", "хочу поживее", "сделай поживее"
        ].contains { value.contains($0) }
        guard asksForMusic || automaticDefault else { return nil }

        // Music and beat-synchronised cutting are the automatic film-making
        // default. The user may still opt out explicitly with "без музыки";
        // otherwise the preset supplies a suitable soundtrack even when the
        // prompt talks only about the story or footage.
        let style: MusicStyle
        if ["энерг", "драйв", "быстр", "динами", "поживее"].contains(where: value.contains) { style = .energetic }
        else if ["кино", "эпич", "драмат"].contains(where: value.contains) { style = .cinematic }
        else if ["спокой", "медлен", "нежн", "эмбиент"].contains(where: value.contains) { style = .calm }
        else if ["весел", "светл", "радост"].contains(where: value.contains) { style = .joyful }
        else if ["электрон", "синт", "техно"].contains(where: value.contains) { style = .electronic }
        else if ["акуст", "гитар", "живую"].contains(where: value.contains) { style = .acoustic }
        else if ["экшен", "action", "fast-motion", "high-speed", "гонка", "спринт"].contains(where: value.contains) { style = .energetic }
        else {
            switch preset {
            case .highlight: style = .energetic
            case .adventure: style = .cinematic
            case .cinematic: style = .cinematic
            case .memories: style = .calm
            case .summerFilm: style = .joyful
            case .story: style = .acoustic
            }
        }
        let bpm: Double
        switch style {
        case .energetic: bpm = 118
        case .cinematic: bpm = 82
        case .calm: bpm = 68
        case .joyful: bpm = 112
        case .electronic: bpm = 116
        case .acoustic: bpm = 94
        }
        let wantsReplacement = [
            "другой", "другую", "поживее",
            "смени трек", "замени трек", "смени музыку", "замени музыку",
            "change music", "replace music", "another track"
        ].contains(where: value.contains)
        return MusicDirective(style: style, bpm: bpm, preferDifferentTrack: wantsReplacement ? true : nil)
    }
}

public struct OriginalAudioPromptInterpreter: Sendable {
    public init() {}

    /// Returns `nil` when a prompt does not mention source sound, `0` for mute,
    /// a restrained documentary level for "quieter", and `1` when the latest
    /// instruction explicitly restores it.
    public func volume(prompt: String) -> Double? {
        let text = prompt.lowercased()
        let mute = lastPosition(of: [
            "убери звук исход", "убрать звук исход", "без исходного звук",
            "без звука исход", "отключи звук исход", "выключи звук исход",
            "заглуши оригинал", "убери оригинальный звук", "убери звук у видео",
            "mute original", "no original audio"
        ], in: text)
        let restore = lastPosition(of: [
            "верни звук исход", "оставь звук исход", "включи звук исход",
            "верни оригинальный звук", "не убирай звук", "original audio on"
        ], in: text)
        let quieter = lastPosition(of: [
            "приглуши звук исход", "приглушить звук исход", "приглушить. сколько титров",
            "звук исходников? приглуш", "звук исходников: приглуш", "звук исходников приглуш",
            "звуком исходников? приглуш", "звуком исходников: приглуш", "звуком исходников приглуш",
            "сделай звук исходников тише", "исходный звук тише", "оригинальный звук тише",
            "убавь звук исходников", "lower original audio", "original audio quieter"
        ], in: text)
        let decisions: [(position: Int, volume: Double)] = [
            mute.map { ($0, 0) },
            quieter.map { ($0, 0.30) },
            restore.map { ($0, 1) }
        ].compactMap { $0 }
        return decisions.max(by: { $0.position < $1.position })?.volume
    }

    private func lastPosition(of needles: [String], in text: String) -> Int? {
        needles.compactMap { needle in
            text.range(of: needle, options: .backwards)
                .map { text.distance(from: text.startIndex, to: $0.lowerBound) }
        }.max()
    }
}
