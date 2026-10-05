import Foundation
import AVFoundation
import Testing
@testable import VeloEditCore

@Suite(.serialized) struct SourceAudioMixPolicyTests {
    @Test func sourceRequestRepairsOldMixToTwentyPercentWithoutBlocking() {
        let plan = StoryPlan(prompt: "Звук: приглушить звук исходников.", preset: .story,
            constraints: StoryConstraints(targetDuration: 8), chapters: [],
            directorBrief: DirectorBrief(requestedDuration: 8, sourceAudioPolicy: .duck))
        let assetID = UUID()
        let clip = TimelineItem(assetID: assetID, kind: .video, sourceDuration: 8, timelineStart: 0, timelineDuration: 8)
        let old = Timeline(storyPlanID: plan.id, items: [clip], audioClips: [
            TimelineAudioClip(assetID: assetID, title: "Detached camera", role: .detached,
                sourceDuration: 8, timelineStart: 0, timelineDuration: 8)
        ], music: MusicDirective(style: .calm, bpm: 90), originalAudioVolume: 0.28,
            audioDucking: .init(enabled: true, attenuation: 0.34))
        let repaired = TimelineDeliveryContract().validateAndRepair(timeline: old, plan: plan, assets: []).timeline
        #expect(repaired.effectiveOriginalAudioVolume == 0.20)
        #expect(repaired.audioClips?.first?.adjustments.volume == 0.20)
        #expect(!SourceAudioMixPolicy.musicDucking(in: repaired).enabled)
        #expect(IntentLedgerEngine.validate(.sourceAudio(.duck), timeline: repaired, previous: nil, analyses: [], assets: []).0 == .fulfilled)
        #expect(!EditorialQualityGate().review(timeline: repaired, plan: plan, analyses: []).findings.contains { $0.kind == .audioPolicyViolation })
        var noSettings = repaired
        noSettings.audioDucking = nil
        #expect(!SourceAudioMixPolicy.musicDucking(in: noSettings).enabled)
        let edited = EditorCommandExecutor().apply(EditorCommandParser().parse(plan.prompt), to: old).timeline
        #expect(edited.effectiveOriginalAudioVolume == 0.20)
        #expect(edited.audioClips?.first?.adjustments.volume == 0.20)
        #expect(edited.audioDucking?.enabled == false)
        let intents = IntentLedgerEngine.intents(prompt: plan.prompt, brief: nil, pending: [plan.prompt], newAssetIDs: [])
        #expect(intents.contains(.sourceAudio(.duck)))
        #expect(!intents.contains { if case .unverifiedInstruction = $0 { return true }; return false })
        let parser = EditorCommandParser()
        #expect(parser.parse(plan.prompt).contains(.setOriginalAudioVolume(DirectorSourceAudioPolicy.duck.volume)))
        #expect(parser.parse("Приглуши музыку под речь").contains(.setAudioDucking(true)))
        let suggested: [EditorCommand] = [.setOriginalAudioVolume(0.30)]
        let authorized = DirectorRequestContract.authorizedCommands(suggested, prompt: plan.prompt, preset: .story)
        #expect(authorized == [.setOriginalAudioVolume(0.20)])
        #expect(EditorCommandExecutor().apply(authorized, to: old).timeline.effectiveOriginalAudioVolume == 0.20)
        #expect(DirectorRequestContract.authorizedCommands(suggested, prompt: "Верни звук исходников", preset: .story) == [.setOriginalAudioVolume(1)])
        #expect(DirectorRequestContract.authorizedCommands(suggested, prompt: "Убери звук исходников", preset: .story) == [.setOriginalAudioVolume(0)])
    }

    @Test func mutedSourcesDoNotPreventMusicMasteringButDetachedAttenuationDoes() {
        let item = TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 8, timelineStart: 0, timelineDuration: 8)
        var timeline = Timeline(storyPlanID: UUID(), items: [item], originalAudioVolume: 1)
        #expect(!SourceAudioMixPolicy.preservesAttenuation(in: timeline))
        timeline = SourceAudioMixPolicy.applyingRequestedVolume(0.2, to: timeline)
        #expect(SourceAudioMixPolicy.preservesAttenuation(in: timeline))
        timeline.items[0].audioAdjustments?.muted = true
        #expect(!SourceAudioMixPolicy.preservesAttenuation(in: timeline))
        timeline.audioClips = [TimelineAudioClip(assetID: item.assetID, title: "Camera", role: .detached,
            sourceDuration: 8, timelineStart: 0, timelineDuration: 8, adjustments: .init(volume: 0.2))]
        #expect(SourceAudioMixPolicy.preservesAttenuation(in: timeline))
        timeline.audioClips?[0].adjustments.muted = true
        #expect(!SourceAudioMixPolicy.preservesAttenuation(in: timeline))
        timeline.audioClips?[0].adjustments.muted = false
        timeline.audioClips?[0].role = .music
        #expect(!SourceAudioMixPolicy.preservesAttenuation(in: timeline))
    }

    @Test(arguments: ["embedded", "detached", "adaptive", "manual", "no-music"])
    func decodedTwentyPercentSourceMatchesPreviewAndExport(_ mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-source-balance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceAudio = root.appendingPathComponent("camera.caf"), musicURL = root.appendingPathComponent("music.caf")
        try writeTone(440, to: sourceAudio)
        try writeTone(880, to: musicURL)
        let card = try await TitleCardVideoGenerator().generate(text: "Audio balance", style: TitleStyle(), duration: 8,
            width: 160, height: 90, frameRate: 30, destination: root.appendingPathComponent("card.mov"))
        let composition = AVMutableComposition()
        for (url, type) in [(card, AVMediaType.video), (sourceAudio, AVMediaType.audio)] {
            let media = AVURLAsset(url: url)
            let source = try #require(try await media.loadTracks(withMediaType: type).first)
            let destination = try #require(composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            try destination.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 8, preferredTimescale: 600)), of: source, at: .zero)
        }
        let movieURL = root.appendingPathComponent("camera.mov")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        session.outputURL = movieURL; session.outputFileType = .mov
        try await EditorialAudioMastering.export(session)
        let asset = MediaAsset(originalURL: movieURL, kind: .video, byteSize: 1, contentHash: "audio-balance",
            metadata: MediaMetadata(duration: 8, width: 160, height: 90, frameRate: 30, hasAudio: true))
        let track = LocalMusicTrack(title: "Tone", author: "Fixture", bpm: 90, genres: [], moods: [], energy: 0.5,
            duration: 8, license: .userFile(), sourceProvider: .user, sourcePageURL: musicURL,
            localFileURL: musicURL, originalFileName: musicURL.lastPathComponent)
        let directive = MusicDirective(style: .calm, bpm: 90, volume: 0.18, trackID: track.id)
        var secondTrack = track
        secondTrack.id = UUID()
        let tracks = [track, secondTrack]
        // Two primary clips also exercise restored levels on alternating tracks.
        let items = [0.0, 4].map { start in
            TimelineItem(assetID: asset.id, kind: .video, sourceStart: start, sourceDuration: 4,
                timelineStart: start, timelineDuration: 4, audioAdjustments: .init(muted: mode == "detached"))
        }
        var timeline = Timeline(storyPlanID: UUID(), width: 160, height: 90, items: items,
            music: directive, originalAudioVolume: 0.28, audioDucking: .init(enabled: true, attenuation: 0.34))
        if mode == "detached" {
            timeline.audioClips = [TimelineAudioClip(assetID: asset.id, title: "Camera", role: .detached,
                sourceDuration: 8, timelineStart: 0, timelineDuration: 8)]
        } else if mode == "manual" {
            timeline.music = nil
            timeline.audioClips = [TimelineAudioClip(trackID: track.id, title: "Music", role: .music,
                sourceDuration: 8, timelineStart: 0, timelineDuration: 8, adjustments: .init(volume: 0.18))]
        } else if mode == "no-music" {
            timeline.music = nil
        }
        timeline = SourceAudioMixPolicy.applyingRequestedVolume(DirectorSourceAudioPolicy.duck.volume, to: timeline)
        if mode == "adaptive" {
            timeline.adaptiveSoundtrack = .init(primaryTrackID: track.id, timelineDuration: 8,
                timelineFingerprint: timeline.adaptiveSoundtrackFingerprint, segments: [
                    .init(timelineStart: 0, timelineDuration: 4, directive: directive, transitionDuration: 0,
                        semanticLabel: "Body", energy: 0.5, confidence: 1),
                    .init(timelineStart: 4, timelineDuration: 4,
                        directive: .init(style: .calm, bpm: 90, volume: 0.18, trackID: secondTrack.id),
                        transitionDuration: 0, semanticLabel: "Ending", energy: 0.5, confidence: 1)
                ], confidence: 1)
            #expect(timeline.effectiveAdaptiveSoundtrack != nil)
        }
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [asset], musicTracks: tracks)
        let preview = try await signalBalance(asset: playback.composition, mix: playback.audioMix)
        let exportURL = root.appendingPathComponent("result.mp4")
        // Frame repetition on the delivery clock must not retime or amplify
        // the original audio, including the final mastering/mux pass.
        let exportFPS = mode == "no-music" ? 120.0 : 60.0
        let report = try await RenderEngine().render(timeline: timeline, assets: [asset], musicTracks: tracks,
            quality: .maximum, frameRate: exportFPS, destination: exportURL)
        #expect(abs(try #require(report.videoInfo).frameRate - exportFPS) < 0.005)
        #expect(abs(try #require(report.videoInfo).duration - 8) < 1 / exportFPS + 0.001)
        let exported = try await signalBalance(asset: AVURLAsset(url: exportURL), mix: nil)
        for index in preview.indices {
            // Equal input amplitudes: source at 20%, music at its unchanged 18%.
            // Measure decoded samples, including the final loudness mastering.
            if mode != "no-music" {
                let expectedDB = 20 * log10(0.20 / 0.18)
                #expect(abs(preview[index].balanceDB - expectedDB) < 0.5)
                #expect(abs(exported[index].balanceDB - expectedDB) < 0.5)
            }
            // A ratio alone misses mastering that raises BOTH buses again.
            // Camera input amplitude is 0.2, so the requested output is 0.04.
            #expect(abs(preview[index].sourceAmplitude - 0.04) < 0.002)
            #expect(abs(exported[index].sourceAmplitude - 0.04) < 0.002)
            #expect(abs(preview[index].sourceAmplitude - exported[index].sourceAmplitude) < 0.002)
            print("Source audio \(mode), window \(index): preview=\(preview[index].sourceAmplitude), export=\(exported[index].sourceAmplitude), expected=0.04")
        }
    }

    private func writeTone(_ frequency: Double, to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 384_000))
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][i] = Float(0.2 * sin(2 * .pi * frequency * Double(i) / 48_000))
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    private func signalBalance(asset: AVAsset, mix: AVAudioMix?) async throws -> [(balanceDB: Double, sourceAmplitude: Double)] {
        let reader = try AVAssetReader(asset: asset)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix; reader.add(output)
        try #require(reader.startReading())
        // Stay outside the intentional fade at the adaptive segment boundary.
        let windows = [1.0, 4.5]
        var sine = Array(repeating: [0.0, 0], count: 2), cosine = sine
        var counts = [0, 0]
        while let sample = output.copyNextSampleBuffer() {
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            try #require(status == kCMBlockBufferNoErr)
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for (index, value) in values.enumerated() {
                let time = start + Double(index) / 48_000
                for w in windows.indices where time >= windows[w] && time < windows[w] + 0.5 {
                    counts[w] += 1
                    for (f, frequency) in [440.0, 880].enumerated() {
                        let phase = 2 * Double.pi * frequency * time
                        sine[w][f] += Double(value) * sin(phase)
                        cosine[w][f] += Double(value) * cos(phase)
                    }
                }
            }
        }
        try #require(reader.status == .completed)
        try #require(counts.allSatisfy { $0 >= 23_900 })
        return windows.indices.map { w in
            let camera = hypot(sine[w][0], cosine[w][0]), music = hypot(sine[w][1], cosine[w][1])
            return (20 * log10(max(1e-12, camera) / max(1e-12, music)), 2 * camera / Double(counts[w]))
        }
    }
}
