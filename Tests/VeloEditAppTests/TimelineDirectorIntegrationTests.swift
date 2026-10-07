import AVFoundation
import Foundation
import Testing
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized) @MainActor
struct TimelineDirectorIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_DIRECTOR_UI_FIXTURE"] != nil))
    func prepareDirectorLiveUIFixture() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let destination = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_DIRECTOR_UI_FIXTURE"]))
        try FileManager.default.copyItem(at: fixture.root, to: destination)
        let files = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "json" {
            let text = try String(contentsOf: file, encoding: .utf8)
            try text.replacingOccurrences(of: fixture.root.path, with: destination.path).write(to: file, atomically: true, encoding: .utf8)
        }
    }

    @Test(arguments: [false, true]) func screenshotRequestUpdatesPreviewAndUndoesAsOneEdit(throughDirector: Bool) async throws {
        let fixture = try await Fixture(commands: [.setOverlay(.greenScreen, .first, .first), .addTitle("путешествие", .beginning)])
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        let request = "добавь в начале фон небо с титром путешествие"
        if throughDirector {
            model.directorInput = request
            model.sendDirectorMessage()
            #expect(model.directorInput.isEmpty)
        } else {
            model.submitTimelineAIEdit(request)
        }
        try await wait { !model.isWorking && model.queuedTimelineAIEditCount == 0 }
        let updated = try #require(model.timeline)
        #expect(updated.items.count == original.items.count + 1)
        #expect(updated.items.dropFirst().map(\.id) == original.items.map(\.id))
        #expect(updated.duration == original.duration + 4)
        #expect(updated.effectiveTitleItems.filter { $0.text == "путешествие" }.count == 1)
        #expect(updated.effectiveTitleItems.first { $0.text == "путешествие" }?.targetClipID == updated.items.first?.id)
        #expect(model.previewPlayer?.currentItem != nil)
        #expect(model.directorMessages.last?.text.contains("Облака") == true)
        #expect(model.directorMessages.last?.text.contains("основной клип для наложения") == false)
        #expect(model.canUndoTimelineEdit)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        #expect(await reopened.manifest.timelines.last?.items == updated.items)
        model.undoTimelineEdit()
        try await wait { !model.isWorking && model.timeline?.items.count == original.items.count }
        #expect(model.timeline?.items == original.items)
        #expect(model.timeline?.effectiveTitleItems == original.effectiveTitleItems)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REAL_COMMENT_DIRECTOR"] == "1"))
    func realLocalDirectorAppliesCompoundMontageAndBrush() async throws {
        let fixture = try await Fixture(realDirector: true)
        defer { fixture.remove() }
        let model = fixture.model
        model.selectTitleTimelineItem(fixture.secondTitleID)
        model.submitTimelineAIEdit("Музыку повеселее и переименуй титр на «Наш маршрут» и добавь крутые эффекты")
        try await wait { !model.isWorking }
        #expect(model.directorRuntimeStatus.contains("Qwen"))
        #expect(model.timeline?.music?.style == .joyful)
        #expect(model.timeline?.effectiveTitleItems.last?.text == "Наш маршрут")
        #expect(model.timeline?.items.allSatisfy { $0.effect == ClipEffect.pushIn.rawValue } == true)
        let outsideAdjustments = model.timeline?.items.last?.effectiveVideoAdjustments
        model.submitTimelineAIEdit("Переименуй титр на «Локальная сцена» и сделай выбранный фрагмент чёрно-белым", range: 0...3)
        try await wait { !model.isWorking }
        #expect(model.directorRuntimeStatus.contains("Qwen"))
        #expect(model.timeline?.effectiveTitleItems.first?.text == "Локальная сцена")
        #expect(model.timeline?.effectiveTitleItems.last?.text == "Наш маршрут")
        #expect(model.timeline?.items.first?.effectiveVideoAdjustments.filter == .monochrome)
        #expect(model.timeline?.items.last?.effectiveVideoAdjustments == outsideAdjustments)
        #expect(model.previewPlayer?.currentItem != nil)
        #expect(model.directorMessages.filter { $0.role == .user }.count == 2)
        model.submitTimelineAIEdit("Убери все титры; добавь титр «Старт»; разрежь клип; ускорь в 2 раза; громкость музыки 10%", range: 0...3)
        try await wait { !model.isWorking }
        #expect(model.timeline?.items.count == 3)
        #expect(model.timeline?.items.prefix(2).allSatisfy { $0.speed == 2 } == true)
        #expect(model.timeline?.effectiveTitleItems.filter { $0.startTime < 1.5 }.allSatisfy { $0.text == "Старт" } == true)
        #expect(model.timeline?.effectiveAdaptiveSoundtrack?.segments.first?.directive.volume == 0.1)
        #expect(model.previewPlayer?.currentItem != nil)
        print("REAL COMMENT DIRECTOR: \(model.directorRuntimeStatus); montage and brush applied; preview available")
    }

    @Test func compoundMontageReachesDirectorUpdatesPlaybackAndSurvivesReopen() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.renderPreview()
        try await wait { !model.isWorking }
        let originalPlayerItem = try #require(model.previewPlayer?.currentItem)
        let beforeFrame = try await frame(originalPlayerItem, at: 4)
        model.selectTitleTimelineItem(fixture.secondTitleID)
        let request = "Музыку повеселее и переименуй титр на «Поехали, друзья» и добавь крутые эффекты"
        model.submitTimelineAIEdit(request)
        #expect(model.directorMessages.contains { $0.role == .user && $0.text == request })
        try await wait { !model.isWorking && model.queuedTimelineAIEditCount == 0 }
        #expect(fixture.requests.values.map(\.0) == [request])
        #expect(fixture.requests.values.first?.1.selectedItemSummary?.contains("Титр") == true)
        #expect(model.timeline?.effectiveTitleItems.map(\.text) == ["Первая глава", "Поехали, друзья"])
        #expect(model.timeline?.music?.style == .joyful)
        #expect(model.timeline?.music?.trackID == fixture.joyfulTrackID)
        #expect(model.timeline?.items.allSatisfy { $0.effect == ClipEffect.pushIn.rawValue } == true)
        let updatedPlayerItem = try #require(model.previewPlayer?.currentItem)
        #expect(updatedPlayerItem !== originalPlayerItem)
        #expect(try await frame(updatedPlayerItem, at: 4) != beforeFrame)
        #expect(try await updatedPlayerItem.asset.loadTracks(withMediaType: .audio).isEmpty == false)
        #expect(model.canUndoTimelineEdit)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        let saved = await reopened.manifest
        // Project dates use the manifest's ISO precision; compare through the
        // same codec so subsecond audit timestamps do not hide content parity.
        let visible = try #require(model.timeline)
        let persistedVisible = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(visible))
        #expect(saved.timelines.last == persistedVisible)
        #expect(saved.workspaceState?.directorMessages?.filter { $0.role == .user && $0.text == request }.count == 1)
        #expect(saved.workspaceState?.directorMessages?.last?.response?.saved == true)
        #expect(saved.workspaceState?.directorMessages?.last?.response?.previewReady == true)
    }

    @Test func brushChangesMusicOnlyInsideRangeAndRecordsItInDirectorChat() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.model
        let originalMusic = model.timeline?.music
        let request = "Переименуй титр на «Здесь» и добавь крутые эффекты; музыку повеселее"
        model.submitTimelineAIEdit(request, range: 1...2)
        try await wait { !model.isWorking }
        #expect(fixture.requests.values.map(\.0) == [request])
        #expect(fixture.requests.values.first?.1.selectedItemSummary?.contains("Только выделенный диапазон") == true)
        let timeline = try #require(model.timeline)
        #expect(timeline.music == originalMusic)
        let regions = try #require(timeline.effectiveAdaptiveSoundtrack?.segments)
        #expect(regions.count == 3)
        #expect(regions.map(\.timelineStart) == [0, 1, 2])
        #expect(regions.map(\.directive.trackID) == [originalMusic?.trackID, fixture.joyfulTrackID, originalMusic?.trackID])
        for item in timeline.items {
            #expect((item.effect == ClipEffect.pushIn.rawValue) == (item.timelineStart >= 1 && item.timelineStart < 2))
        }
        #expect(timeline.effectiveTitleItems.contains { $0.text == "Здесь" && $0.startTime >= 1 && $0.endTime <= 2 })
        #expect(timeline.effectiveTitleItems.contains { $0.text == "Вторая глава" })
        #expect(model.previewPlayer?.currentItem != nil)
        #expect(model.directorMessages.last?.response?.range == 1...2)
        #expect(model.directorMessages.last?.text.contains("Только в выделенном диапазоне") == true)
        let playerItem = try #require(model.previewPlayer?.currentItem)
        let audioTracks = try await playerItem.asset.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == 3)
        let selectedSound = try await audioSignature(playerItem, start: 1.2, duration: 0.5)
        let outsideSound = try await audioSignature(playerItem, start: 3.2, duration: 0.5)
        #expect(selectedSound.frequency > 420 && selectedSound.frequency < 460)
        #expect(outsideSound.frequency > 200 && outsideSound.frequency < 240)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        #expect(await reopened.manifest.workspaceState?.directorMessages?.last?.text == model.directorMessages.last?.text)
    }

    @Test func semanticBrushUsesModelCommandsAndCancelledQueueStaysInHistory() async throws {
        let fixture = try await Fixture(commands: [.setFilter(.monochrome, .all)])
        defer { fixture.remove() }
        fixture.model.submitTimelineAIEdit("Сделай здесь как в старом кино", range: 0...3)
        try await wait { !fixture.model.isWorking }
        #expect(fixture.model.timeline?.items.first?.effectiveVideoAdjustments.filter == .monochrome)
        #expect(fixture.model.timeline?.items.last?.effectiveVideoAdjustments.filter == VideoFilter.none)
        fixture.model.isWorking = true
        fixture.model.submitTimelineAIEdit("громкость музыки 20%")
        fixture.model.cancelOperation()
        fixture.model.isWorking = false
        #expect(fixture.model.directorMessages.last?.text.contains("отменена до выполнения") == true)
        #expect(fixture.model.queuedTimelineAIEditCount == 0)
    }

    @Test func brushVolumeChangesRenderedAudioOnlyInsideSelection() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.model.submitTimelineAIEdit("громкость музыки 5%", range: 1...2)
        try await wait { !fixture.model.isWorking }
        let item = try #require(fixture.model.previewPlayer?.currentItem)
        let inside = try await audioSignature(item, start: 1.2, duration: 0.5)
        let outside = try await audioSignature(item, start: 2.2, duration: 0.5)
        print("LOCAL AUDIO MIX: inside \(inside), outside \(outside), regions \(String(describing: fixture.model.timeline?.effectiveAdaptiveSoundtrack?.segments.map { $0.directive.volume }))")
        #expect(inside.rms > 0)
        #expect(abs(inside.rms / outside.rms - 0.05 / 0.18) < 0.03)
        #expect(fixture.model.directorMessages.last?.response?.previewReady == true)
    }

    private func audioSignature(_ item: AVPlayerItem, start: Double, duration: Double) async throws -> (rms: Double, frequency: Double) {
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: item.asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVNumberOfChannelsKey: 1, AVSampleRateKey: 8_000
        ])
        output.audioMix = item.audioMix
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
        #expect(reader.startReading())
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetDataBuffer(sample) {
            let count = CMBlockBufferGetDataLength(buffer) / MemoryLayout<Float>.size
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            #expect(status == kCMBlockBufferNoErr)
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let lower = min(chunk.count, max(0, Int(ceil((start - time) * 8_000))))
            let upper = min(chunk.count, max(lower, Int(floor((start + duration - time) * 8_000))))
            samples += chunk[lower..<upper]
        }
        #expect(reader.status == .completed)
        #expect(!samples.isEmpty)
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count)))
        let crossings = zip(samples, samples.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
        return (rms, Double(crossings) * 8_000 / Double(max(1, samples.count)))
    }

    private func frame(_ item: AVPlayerItem, at seconds: Double) async throws -> Data {
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return try #require(result.image.dataProvider?.data) as Data
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(90)
        repeat {
            try await Task.sleep(for: .milliseconds(20))
            if predicate() { return }
        } while Date() < deadline
        throw WaitError.timeout
    }
    private enum WaitError: Error { case timeout }

    private final class Requests { var values: [(String, DirectorContext)] = [] }
    @MainActor private struct Fixture {
        let root: URL
        let url: URL
        let suite: String
        let model: AppModel
        let requests: Requests
        let secondTitleID: UUID
        let joyfulTrackID: UUID

        init(commands: [EditorCommand] = [], realDirector: Bool = false) async throws {
            suite = "VeloEdit.timeline-director.\(UUID())"
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            url = root.appendingPathComponent("test.veloedit")
            let store = try ProjectStore(createAt: url, name: "Director integration")
            let source = try await TitleCardVideoGenerator().generate(text: "SOURCE", style: TitleStyle(), duration: 6,
                width: 640, height: 360, frameRate: 20, destination: root.appendingPathComponent("source.mov"), codec: .jpeg)
            let asset = MediaAsset(originalURL: source, kind: .video, byteSize: 1, contentHash: UUID().uuidString,
                metadata: MediaMetadata(duration: 6, width: 640, height: 360, frameRate: 20, hasAudio: false))
            let library = LocalMusicLibrary(rootURL: root.appendingPathComponent("music"))
            let calm = try await Self.track(root: root, library: library, title: "Calm", mood: "calm", frequency: 220)
            let happy = try await Self.track(root: root, library: library, title: "Happy", mood: "joyful", frequency: 440)
            joyfulTrackID = happy.id
            let titles = [TitleTimelineItem(kind: .title, text: "Первая глава", startTime: 0, duration: 3),
                          TitleTimelineItem(kind: .title, text: "Вторая глава", startTime: 3, duration: 3)]
            secondTitleID = titles[1].id
            let items: [TimelineItem] = (0..<2).map { index in
                let start = Double(index) * 3
                return TimelineItem(assetID: asset.id, kind: .video, sourceStart: start, sourceDuration: 3, timelineStart: start, timelineDuration: 3)
            }
            var music = MusicDirective(style: .calm, bpm: 68)
            music.trackID = calm.id
            music.trackTitle = calm.title
            let timeline = Timeline(storyPlanID: UUID(), width: 640, height: 360, frameRate: 20,
                items: items, titleItems: titles, music: music)
            try await store.update { $0.assets = [asset]; $0.timelines = [timeline] }
            let recorder = Requests()
            requests = recorder
            let agent = LocalDirectorAgent { message, context, _, _ in
                recorder.values.append((message, context))
                return DirectorAIReply(text: "План", runtimeLabel: "Test director", normalizedBrief: nil, commands: commands)
            }
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(true, forKey: "freeToUseLicenseAccepted.v1")
            let taste = LocalPersonalTasteStore(url: root.appendingPathComponent("taste.json"))
            model = AppModel(defaults: defaults, startBackgroundServices: false, personalTasteStore: taste, directorAgent: realDirector ? LocalDirectorAgent() : agent)
            model.pipeline = VeloEditPipeline(store: store, musicLibrary: library,
                musicSystem: MusicLibrary(localLibrary: library, providers: [LocalMusicProvider(library: library)]),
                musicSelectionHistory: LocalMusicSelectionHistoryStore(url: root.appendingPathComponent("history.json")), personalTasteStore: taste)
            model.projectURL = url
            model.project = await store.manifest
        }

        private static func track(root: URL, library: LocalMusicLibrary, title: String, mood: String, frequency: Double) async throws -> LocalMusicTrack {
            let url = root.appendingPathComponent(title + ".wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000)!
            buffer.frameLength = buffer.frameCapacity
            for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * frequency / 8_000) * 0.15) }
            try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
            return try await library.importExistingTrack(LocalMusicTrack(title: title, author: "Test", bpm: mood == "calm" ? 68 : 112,
                genres: ["instrumental"], moods: [mood], energy: mood == "calm" ? 0.2 : 0.62, duration: 10,
                license: .userFile(), sourceProvider: .user, sourcePageURL: url, localFileURL: url, originalFileName: url.lastPathComponent))
        }

        func remove() {
            model.cancelOperation()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
