import Foundation

public actor MusicStructureCache {
    public static let shared = MusicStructureCache()
    private struct CacheKey: Codable, Hashable, Sendable {
        var id: UUID
        var path: String
        var bpmMillis: Int
        var durationMillis: Int
        var fileSize: UInt64
        var modifiedAtMillis: Int64
    }
    private var values: [CacheKey: MusicStructure] = [:]
    private var valueOrder: [CacheKey] = []
    private var inFlight: [CacheKey: Task<MusicStructure, Never>] = [:]
    private let maximumMemoryEntries = 64
    private struct PersistedStructure: Codable {
        var key: CacheKey
        var structure: MusicStructure
    }

    public init() {}

    public func structure(for track: LocalMusicTrack) async -> MusicStructure {
        let key = cacheKey(for: track)
        if let cached = values[key] {
            touch(key)
            return cached
        }
        if let data = try? Data(contentsOf: persistedURL(for: track)),
           let persisted = try? JSONDecoder().decode(PersistedStructure.self, from: data),
           persisted.key == key {
            values[key] = persisted.structure
            touch(key)
            return persisted.structure
        }
        if let pending = inFlight[key] { return await pending.value }
        let task = Task { await MusicSyncEngine().analyze(track: track) }
        inFlight[key] = task
        let analyzed = await task.value
        values[key] = analyzed
        touch(key)
        inFlight[key] = nil
        let persisted = PersistedStructure(key: key, structure: analyzed)
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: persistedURL(for: track), options: .atomic)
        }
        return analyzed
    }

    public func invalidate(trackID: UUID) {
        values = values.filter { $0.key.id != trackID }
        valueOrder.removeAll { $0.id == trackID }
        let pending = inFlight.filter { $0.key.id == trackID }.map(\.value)
        inFlight = inFlight.filter { $0.key.id != trackID }
        pending.forEach { $0.cancel() }
    }

    public func memoryEntryCount() -> Int { values.count }

    private func touch(_ key: CacheKey) {
        valueOrder.removeAll { $0 == key }
        valueOrder.append(key)
        while valueOrder.count > maximumMemoryEntries {
            values.removeValue(forKey: valueOrder.removeFirst())
        }
    }

    private func cacheKey(for track: LocalMusicTrack) -> CacheKey {
        let attributes = try? FileManager.default.attributesOfItem(atPath: track.localFileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return CacheKey(
            id: track.id,
            path: track.localFileURL.standardizedFileURL.path,
            bpmMillis: Int((track.bpm * 1_000).rounded()),
            durationMillis: Int((track.duration * 1_000).rounded()),
            fileSize: size,
            modifiedAtMillis: Int64((modified * 1_000).rounded())
        )
    }

    private func persistedURL(for track: LocalMusicTrack) -> URL {
        if track.sourceProvider == .bundled,
           let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let directory = caches
                .appendingPathComponent("VeloEdit", isDirectory: true)
                .appendingPathComponent("MusicStructures", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent(".\(track.id.uuidString).music-structure-v2.json")
        }
        return track.localFileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(track.id.uuidString).music-structure-v2.json")
    }
}

/// Deterministic music analysis shared by AI planning, manual beat sync and
/// export. A decoded loudness envelope can be supplied by the caller; when it
/// is absent the engine still creates a conservative structural grid from BPM.
public struct MusicSyncEngine: Sendable {
    public init() {}

    /// Reads a local track through VeloEdit's bounded audio analyzer and turns
    /// its loudness envelope into peaks, quiet ranges and drop candidates.
    public func analyze(track: LocalMusicTrack) async -> MusicStructure {
        let summary = try? await LocalAudioAnalyzer().analyze(url: track.localFileURL, level: .deep)
        return analyze(
            bpm: track.bpm,
            duration: max(0.1, track.duration),
            energy: track.energy,
            energyEnvelope: summary?.waveform ?? [],
            onsetEnvelope: summary?.onsetEnvelope ?? [],
            measuredBPM: summary?.estimatedBPM,
            tempoConfidence: summary?.tempoConfidence
        )
    }

    public func analyze(
        bpm: Double,
        duration: Double,
        energy: Double = 0.6,
        energyEnvelope: [Double] = [],
        onsetEnvelope: [Double] = [],
        measuredBPM: Double? = nil,
        tempoConfidence: Double? = nil
    ) -> MusicStructure {
        let suppliedBPM = min(max(40, bpm.isFinite ? bpm : 90), 240)
        let tempoConfidence = tempoConfidence?.clamped01 ?? 0
        let safeBPM = tempoConfidence >= 0.18
            ? min(max(40, measuredBPM ?? suppliedBPM), 240)
            : suppliedBPM
        let safeDuration = max(0.1, duration.isFinite ? duration : 0.1)
        let beat = 60 / safeBPM
        let envelope = normalizedEnvelope(energyEnvelope, fallbackEnergy: energy)
        let hasMeasuredEnvelope = !energyEnvelope.filter(\.isFinite).isEmpty
        let onset = normalizedEnvelope(onsetEnvelope, fallbackEnergy: 0)
        let hasMeasuredOnsets = !onsetEnvelope.filter(\.isFinite).isEmpty
        let rawAccents = detectedAccents(envelope: hasMeasuredOnsets ? onset : envelope, duration: safeDuration)
        let phase = (hasMeasuredEnvelope || hasMeasuredOnsets) ? bestBeatPhase(accents: rawAccents, beat: beat) : 0
        let beats = timestamps(interval: beat, duration: safeDuration, phase: phase)
        let meter = hasMeasuredOnsets ? estimatedMeter(beats: beats, accents: rawAccents, beat: beat) : 4
        let downbeats = timestamps(interval: beat * Double(meter), duration: safeDuration, phase: phase)
        let phrases = phraseBoundaries(duration: safeDuration, barBoundaries: downbeats, accents: rawAccents)
        let eventConfidence = hasMeasuredEnvelope ? min(1, 0.32 + Double(rawAccents.count) / Double(max(8, Int(safeDuration / 4)))) : 0.18
        let phraseConfidence = hasMeasuredOnsets ? min(1, eventConfidence * 0.78 + tempoConfidence * 0.22) : 0.18
        let sectionConfidence = hasMeasuredEnvelope ? min(1, 0.38 + Double(envelope.count) / 320) : 0.16
        let sections = structuralSections(duration: safeDuration, energy: energy, envelope: envelope, phraseBoundaries: phrases, measured: hasMeasuredEnvelope, confidence: sectionConfidence)
        let peaks = peakTimes(envelope: envelope, duration: safeDuration)
        let quiet = quietRanges(envelope: envelope, duration: safeDuration)
        let drops = dropTimes(envelope: envelope, duration: safeDuration, sections: sections)
        let dropConfidence = hasMeasuredEnvelope && !drops.isEmpty ? min(1, sectionConfidence * 0.56 + eventConfidence * 0.44) : 0.12
        let accents = mergedAccents(
            rawAccents,
            beats: beats,
            downbeats: downbeats,
            phrases: phrases,
            drops: drops,
            sections: sections,
            tempoConfidence: tempoConfidence,
            phraseConfidence: phraseConfidence,
            dropConfidence: dropConfidence
        )
        return MusicStructure(
            bpm: safeBPM,
            beatInterval: beat,
            sections: sections,
            beatTimestamps: beats,
            barBoundaries: downbeats,
            peaks: peaks,
            quietRanges: quiet,
            drops: drops,
            downbeatTimestamps: downbeats,
            phraseBoundaries: phrases,
            accents: accents,
            beatsPerBar: meter,
            tempoConfidence: max(tempoConfidence, hasMeasuredOnsets ? eventConfidence * 0.52 : 0.16),
            downbeatConfidence: hasMeasuredOnsets ? min(1, eventConfidence * 0.64 + tempoConfidence * 0.36) : 0.16,
            phraseConfidence: phraseConfidence,
            sectionConfidence: sectionConfidence,
            dropConfidence: dropConfidence,
            analysisIsMeasured: hasMeasuredEnvelope || hasMeasuredOnsets
        )
    }

    public func snappedTime(_ time: Double, structure: MusicStructure, subdivision: Int = 1) -> Double {
        let interval = structure.beatInterval / Double(max(1, subdivision))
        guard interval.isFinite, interval > 0 else { return max(0, time) }
        return max(0, (time / interval).rounded() * interval)
    }

    public func synchronize(_ timeline: Timeline, bpm: Double, energy: Double = 0.6) -> Timeline {
        let structure = analyze(bpm: bpm, duration: max(0.1, timeline.duration), energy: energy)
        return synchronize(timeline, structure: structure)
    }

    public func synchronize(_ timeline: Timeline, structure: MusicStructure) -> Timeline {
        var result = timeline
        if var music = result.music {
            music.bpm = structure.bpm
            music.structure = structure
            result.music = music
        }
        result.effects = result.effectiveEffects.map { item in
            var copy = item
            copy.startTime = min(result.duration, snappedTime(copy.startTime, structure: structure, subdivision: 2))
            copy.duration = max(0.05, snappedTime(copy.duration, structure: structure, subdivision: 2))
            copy.explanation.append("Синхронизировано с сеткой \(Int(structure.bpm.rounded())) BPM")
            return copy
        }
        result.titleItems = result.effectiveTitleItems.map { item in
            var copy = item
            copy.startTime = min(result.duration, snappedTime(copy.startTime, structure: structure, subdivision: 2))
            return copy
        }
        let manuallyControlledIncomingIDs = Set(result.effectiveTransitionItems.compactMap { item in
            item.explanation.contains(where: { $0.localizedCaseInsensitiveContains("пользователь") || $0.localizedCaseInsensitiveContains("вручную") })
                ? item.incomingClipID : nil
        })
        let dropTolerance = max(0.08, structure.beatInterval * 0.42)
        let dropConfidence = structure.dropConfidence ?? 0
        let drops = structure.drops ?? []
        for index in result.items.indices where result.items[index].incomingEditDecision?.choice == .transition {
            guard !manuallyControlledIncomingIDs.contains(result.items[index].id) else { continue }
            let cutTime = result.items[index].timelineStart
            guard dropConfidence >= 0.45,
                  drops.contains(where: { abs($0 - cutTime) <= dropTolerance }) else { continue }
            result.items[index].transition = TransitionStyle.exposureFlash.rawValue
            result.items[index].incomingEditDecision = EditorialBoundaryDecision(
                choice: .transition,
                motivation: "Exposure Flash привязан к подтверждённому музыкальному drop",
                confidence: min(0.90, 0.62 + dropConfidence * 0.28),
                transitionStyle: .exposureFlash
            )
            if let transitionIndex = result.transitionItems?.firstIndex(where: { $0.incomingClipID == result.items[index].id }) {
                result.transitionItems?[transitionIndex].style = .exposureFlash
                result.transitionItems?[transitionIndex].parameters = TransitionPresetRegistry.preset(for: .exposureFlash).defaultParameters
                result.transitionItems?[transitionIndex].explanation.append("AI синхронизировал переход с музыкальным drop")
            }
        }
        return result
    }

    /// Gain applied to music while useful source audio is active.
    public func duckedMusicGain(originalAudioLevel: Double, settings: AudioDuckingSettings?) -> Double {
        guard let settings, settings.enabled else { return 1 }
        let activity = min(max(0, originalAudioLevel), 1)
        return max(0, 1 - settings.attenuation * activity)
    }

    private func timestamps(interval: Double, duration: Double, phase: Double = 0) -> [Double] {
        guard interval > 0 else { return [0] }
        var values: [Double] = []
        var time = max(0, phase)
        if time > 0.000_001 { values.append(0) }
        while time <= duration + 0.000_001 {
            values.append(min(duration, time))
            time += interval
        }
        return values
    }

    private func normalizedEnvelope(_ values: [Double], fallbackEnergy: Double) -> [Double] {
        let clean = values.filter(\.isFinite).map { min(max(0, $0), 1) }
        guard !clean.isEmpty else {
            let base = min(max(0.08, fallbackEnergy), 1)
            return [base * 0.35, base * 0.48, base * 0.72, base, base * 0.78, min(1, base * 1.08), base * 0.90, base * 0.40]
        }
        return clean
    }

    private func structuralSections(duration: Double, energy: Double, envelope: [Double], phraseBoundaries: [Double], measured: Bool, confidence: Double) -> [MusicSection] {
        if measured, phraseBoundaries.count >= 3 {
            let bounds = Array(Set(([0] + phraseBoundaries + [duration]).map { min(duration, max(0, $0)) })).sorted()
            var sections: [MusicSection] = []
            for index in 0..<(bounds.count - 1) where bounds[index + 1] - bounds[index] > 0.05 {
                let start = bounds[index]
                let end = bounds[index + 1]
                let sectionEnergy = averageEnergy(envelope: envelope, duration: duration, range: start...end)
                let previousEnergy = sections.last?.energy ?? sectionEnergy
                let position = start / max(duration, 0.1)
                let kind: MusicSectionKind
                if index == 0 { kind = .intro }
                else if index == bounds.count - 2 { kind = .outro }
                else if sectionEnergy - previousEnergy >= 0.20 { kind = .drop }
                else if position >= 0.62 && sectionEnergy >= 0.72 { kind = .climax }
                else if sectionEnergy >= 0.66 { kind = .chorus }
                else { kind = .buildup }
                sections.append(MusicSection(kind: kind, start: start, duration: end - start, energy: sectionEnergy, confidence: confidence))
            }
            if !sections.contains(where: { $0.kind == .climax }), let index = sections.indices.max(by: { sections[$0].energy < sections[$1].energy }), index > 0, index < sections.count - 1 {
                sections[index].kind = .climax
            }
            return sections
        }
        let layout: [(MusicSectionKind, Double, Double, Double)] = [
            (.intro, 0.00, 0.12, 0.42), (.buildup, 0.12, 0.34, 0.68),
            (.drop, 0.34, 0.48, 1), (.chorus, 0.48, 0.70, 0.86),
            (.climax, 0.70, 0.88, 1), (.outro, 0.88, 1.00, 0.38)
        ]
        let measured = envelope.reduce(0, +) / Double(max(1, envelope.count))
        let base = min(max(0.08, measured * 0.55 + min(max(0, energy), 1) * 0.45), 1)
        return layout.map { kind, start, end, multiplier in
            MusicSection(kind: kind, start: duration * start, duration: duration * (end - start), energy: min(1, base * multiplier), confidence: confidence)
        }
    }

    private func detectedAccents(envelope: [Double], duration: Double) -> [MusicAccent] {
        guard envelope.count > 1 else { return [] }
        return envelope.indices.compactMap { index in
            let current = envelope[index]
            let previous = index > 0 ? envelope[index - 1] : current
            let next = index + 1 < envelope.count ? envelope[index + 1] : current
            let rise = current - previous
            let time = duration * Double(index) / Double(max(1, envelope.count - 1))
            if rise >= 0.24 { return MusicAccent(time: time, strength: min(1, rise * 1.8 + current * 0.35), kind: .onset, confidence: min(1, 0.45 + rise)) }
            if current >= 0.64, current >= previous, current >= next { return MusicAccent(time: time, strength: current, kind: .peak, confidence: min(1, 0.42 + current * 0.58)) }
            return nil
        }
    }

    private func bestBeatPhase(accents: [MusicAccent], beat: Double) -> Double {
        guard beat > 0, !accents.isEmpty else { return 0 }
        let phases = accents.prefix(24).map { $0.time.truncatingRemainder(dividingBy: beat) } + [0]
        return phases.max { lhs, rhs in phaseScore(lhs, accents: accents, beat: beat) < phaseScore(rhs, accents: accents, beat: beat) } ?? 0
    }

    private func phaseScore(_ phase: Double, accents: [MusicAccent], beat: Double) -> Double {
        accents.reduce(0) { result, accent in
            let offset = abs((accent.time - phase).truncatingRemainder(dividingBy: beat))
            let distance = min(offset, beat - offset)
            return result + accent.strength * max(0, 1 - distance / max(0.001, beat * 0.32))
        }
    }

    private func phraseBoundaries(duration: Double, barBoundaries: [Double], accents: [MusicAccent]) -> [Double] {
        guard barBoundaries.count > 1 else { return [0, duration] }
        let nominal = stride(from: 0, to: barBoundaries.count, by: 4).map { barBoundaries[$0] }
        return nominal.map { boundary in
            accents.filter { abs($0.time - boundary) <= max(0.35, (barBoundaries.dropFirst().first ?? 1) * 0.35) }
                .max(by: { $0.strength < $1.strength })?.time ?? boundary
        } + (nominal.last.map { duration - $0 > 0.5 ? [duration] : [] } ?? [duration])
    }

    private func averageEnergy(envelope: [Double], duration: Double, range: ClosedRange<Double>) -> Double {
        guard !envelope.isEmpty else { return 0.5 }
        let values = envelope.enumerated().compactMap { index, value -> Double? in
            let time = duration * Double(index) / Double(max(1, envelope.count - 1))
            return range.contains(time) ? value : nil
        }
        return values.isEmpty ? 0.5 : values.reduce(0, +) / Double(values.count)
    }

    private func mergedAccents(
        _ raw: [MusicAccent],
        beats: [Double],
        downbeats: [Double],
        phrases: [Double],
        drops: [Double],
        sections: [MusicSection],
        tempoConfidence: Double,
        phraseConfidence: Double,
        dropConfidence: Double
    ) -> [MusicAccent] {
        var result = raw
        result += beats.map { beat in
            let nearby = raw.filter { abs($0.time - beat) <= 0.12 }.map(\.strength).max() ?? 0.38
            return MusicAccent(time: beat, strength: nearby, kind: nearby >= 0.68 ? .strongBeat : .beat, confidence: tempoConfidence)
        }
        result += downbeats.map { MusicAccent(time: $0, strength: 0.68, kind: .downbeat, confidence: tempoConfidence) }
        result += phrases.map { MusicAccent(time: $0, strength: 0.78, kind: .phrase, confidence: phraseConfidence) }
        result += drops.map { MusicAccent(time: $0, strength: 1, kind: .drop, confidence: dropConfidence) }
        result += sections.filter { $0.kind == .climax }.map { MusicAccent(time: $0.start + $0.duration * 0.45, strength: $0.energy, kind: .sectionPeak, confidence: $0.confidence) }
        result += sections.dropFirst().map { section in
            MusicAccent(time: section.start, strength: max(0.42, section.energy), kind: section.energy < 0.36 ? .breakdown : .transition, confidence: section.confidence)
        }
        return result.sorted { lhs, rhs in lhs.time == rhs.time ? lhs.strength > rhs.strength : lhs.time < rhs.time }
    }

    private func estimatedMeter(beats: [Double], accents: [MusicAccent], beat: Double) -> Int {
        guard beats.count >= 8, !accents.isEmpty else { return 4 }
        let candidates = [3, 4, 5, 6]
        let scored = candidates.map { ($0, meterScore($0, beats: beats, accents: accents, beat: beat)) }
        let best = scored.map(\.1).max() ?? 0
        // 3 and 6 (or 4 and an octave-like multiple) can explain the same
        // periodic accents. Prefer the fundamental smaller meter when its
        // evidence is effectively tied with the multiple.
        return scored.filter { $0.1 >= best - 0.025 }.map(\.0).min() ?? 4
    }

    private func meterScore(_ meter: Int, beats: [Double], accents: [MusicAccent], beat: Double) -> Double {
        let downbeatIndices = Array(stride(from: 0, to: beats.count, by: meter))
        return downbeatIndices.reduce(0) { total, index in
            let time = beats[index]
            let strength = accents.filter { abs($0.time - time) <= max(0.10, beat * 0.22) }.map(\.strength).max() ?? 0
            return total + strength
        } / Double(max(1, downbeatIndices.count))
    }

    private func peakTimes(envelope: [Double], duration: Double) -> [Double] {
        guard envelope.count > 2 else { return [] }
        return (1..<(envelope.count - 1)).compactMap { index in
            guard envelope[index] >= 0.68,
                  envelope[index] >= envelope[index - 1], envelope[index] >= envelope[index + 1] else { return nil }
            return duration * Double(index) / Double(envelope.count - 1)
        }
    }

    private func quietRanges(envelope: [Double], duration: Double) -> [ClosedRange<Double>] {
        let step = duration / Double(max(1, envelope.count))
        var ranges: [ClosedRange<Double>] = []
        var start: Int?
        for index in 0...envelope.count {
            let quiet = index < envelope.count && envelope[index] < 0.33
            if quiet, start == nil { start = index }
            if !quiet, let first = start {
                ranges.append(Double(first) * step...min(duration, Double(index) * step))
                start = nil
            }
        }
        return ranges
    }

    private func dropTimes(envelope: [Double], duration: Double, sections: [MusicSection]) -> [Double] {
        var result = sections.filter { $0.kind == .drop }.map(\.start)
        if envelope.count > 1 {
            for index in 1..<envelope.count where envelope[index] - envelope[index - 1] >= 0.28 {
                result.append(duration * Double(index) / Double(envelope.count - 1))
            }
        }
        return Array(Set(result.map { ($0 * 1000).rounded() / 1000 })).sorted()
    }
}
