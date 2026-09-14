import Foundation
import Testing
import AVFoundation
@testable import VeloEditCore

@Suite(.serialized)
struct ProcessedAudioCacheTests {
    @Test func cacheSurvivesNewGeneratorsAndIgnoresLiveGainAndFades() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.render()
        let bytes = try Data(contentsOf: first)
        let date = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date
        let second = try await fixture.render(AudioAdjustments(volume: 0.25, fadeIn: 0.2, normalize: true))
        #expect(first == second)
        #expect(try Data(contentsOf: second) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: second.path)[.modificationDate] as? Date == date)
        let audio = try AVAudioFile(forReading: second)
        #expect(abs(Double(audio.length) / audio.processingFormat.sampleRate - 0.5) < 0.05)
    }

    @Test func changesToRangeDSPOrSourceInvalidateOnlyTheirOwnCacheEntry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.render()
        let eq = try await fixture.render(AudioAdjustments(eqPreset: .voice, normalize: true))
        let range = try await fixture.render(start: 0.1, duration: 0.35)
        #expect(first != eq && first != range && eq != range)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_234)], ofItemAtPath: fixture.source.path)
        let replaced = try await fixture.render()
        #expect(replaced != first)
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

    @Test func corruptCacheIsRepairedAndConcurrentWritersPublishCompleteAudio() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cached = try await fixture.render()
        try Data("broken CAF".utf8).write(to: cached)
        async let first = fixture.render()
        async let second = fixture.render()
        let urls = try await [first, second]
        #expect(urls.allSatisfy { $0 == cached })
        #expect(try AVAudioFile(forReading: cached).length > 20_000)
        let remaining = try FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: nil)
        #expect(remaining.count == 1)
        #expect(remaining.first?.resolvingSymlinksInPath() == cached.resolvingSymlinksInPath())
    }

    private struct Fixture: Sendable {
        let root: URL
        let source: URL
        let cache: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-cache-\(UUID().uuidString)")
            source = root.appendingPathComponent("tone.caf")
            cache = root.appendingPathComponent("cache")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            let channels = try #require(buffer.floatChannelData)
            for frame in 0..<48_000 {
                for channel in 0..<2 {
                    channels[channel][frame] = Float(0.1 * sin(2 * .pi * 440 * Double(frame) / 48_000))
                }
            }
            try file.write(from: buffer)
        }
        func render(_ adjustments: AudioAdjustments = AudioAdjustments(normalize: true),
                    start: Double = 0, duration: Double = 0.5) async throws -> URL {
            try await ProcessedAudioGenerator().generate(sourceURL: source, sourceStart: start, sourceDuration: duration,
                adjustments: adjustments, destination: root.appendingPathComponent("unused.caf"), cacheDirectory: cache)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
