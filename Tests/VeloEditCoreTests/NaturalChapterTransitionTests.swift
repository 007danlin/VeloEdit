import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import VeloEditCore

@Suite(.serialized) struct NaturalChapterTransitionTests {
    static func frame(time: Double, shift: Int = 0, cover: Double = 0, alternate: Bool = false, coverValue: Double = 0.08) -> NaturalTransitionFrame {
        var rgb: [Double] = []
        for y in 0..<36 { for x in 0..<64 {
            let px = (x - shift + 256) % 64
            let seed = alternate ? (px * 71 + y * 29 + px * y * 11) % 97 : (px * 17 + y * 37 + px * y * 3) % 97
            let v = x < Int(64 * cover) ? coverValue : 0.18 + Double(seed) / 140
            rgb.append(contentsOf: [v, v * 0.85, v * 0.72])
        } }
        return .init(time: time, rgb: rgb, aspectRatio: 16.0 / 9)
    }
    static func motionPair(step: Int, opposing: Bool = false) -> ([NaturalTransitionFrame], [NaturalTransitionFrame]) {
        let tail = (0..<4).map { frame(time: Double($0) * 0.1, shift: ($0 - 3) * step) }
        let head = (0..<4).map { frame(time: Double($0) * 0.1 + 1, shift: $0 * (opposing ? -step : step)) }
        return (tail, head)
    }

    @Test func detectsRealCoverAndRevealButNotDarknessOrFlash() {
        let tail = [0.2, 0.45, 0.7, 1].enumerated().map { Self.frame(time: Double($0.offset) * 0.1, cover: $0.element) }
        let head = [1.0, 0.7, 0.45, 0.2].enumerated().map { Self.frame(time: 1 + Double($0.offset) * 0.1, cover: $0.element, alternate: true) }
        #expect(NaturalTransitionVision.match(tail: tail, head: head)?.kind == .occlusion)
        for level in [0.02, 0.5, 0.99] {
            let flat = (0..<4).map { NaturalTransitionFrame(time: Double($0) * 0.1, rgb: Array(repeating: level, count: 6912), aspectRatio: 16.0 / 9) }
            #expect(NaturalTransitionVision.match(tail: flat, head: flat) == nil)
        }
        var flashTail = tail, flashHead = head
        flashTail[3].rgb = Array(repeating: 1, count: 6912)
        flashHead[0].rgb = Array(repeating: 1, count: 6912)
        #expect(NaturalTransitionVision.match(tail: flashTail, head: flashHead) == nil)
        let instantTail = [0.0, 0, 0, 1].enumerated().map { Self.frame(time: Double($0.offset) * 0.1, cover: $0.element) }
        #expect(NaturalTransitionVision.match(tail: instantTail, head: head) == nil)
    }

    @Test func verifiesDirectionSpeedAndTemporalMotionInsteadOfActionTags() {
        for (step, kind) in [(1, NaturalChapterTransitionKind.motion), (2, .dynamicMotion)] {
            let (tail, head) = Self.motionPair(step: step)
            #expect(NaturalTransitionVision.match(tail: tail, head: head)?.kind == kind)
            let (_, reverse) = Self.motionPair(step: step, opposing: true)
            #expect(NaturalTransitionVision.match(tail: tail, head: reverse) == nil)
        }
        let (tail, _) = Self.motionPair(step: 1)
        let shake = [0, 2, -2, 1].enumerated().map { Self.frame(time: 1 + Double($0.offset) * 0.1, shift: $0.element) }
        #expect(NaturalTransitionVision.match(tail: tail, head: shake) == nil)
        let (_, tooFast) = Self.motionPair(step: 4)
        #expect(NaturalTransitionVision.match(tail: tail, head: tooFast) == nil)
    }

    @Test func shapeMatchNeedsStructureAndCompletePreciselyTimedWindows() {
        let frames = (0..<4).map { Self.frame(time: Double($0) * 0.1) }
        #expect(NaturalTransitionVision.match(tail: frames, head: frames)?.kind == .composition)
        let unrelated = (0..<4).map { Self.frame(time: Double($0) * 0.1, alternate: true) }
        #expect(NaturalTransitionVision.match(tail: frames, head: unrelated) == nil)
        #expect(NaturalTransitionVision.match(tail: Array(frames.dropLast()), head: frames) == nil)
        #expect(NaturalTransitionVision.match(tail: Array(repeating: frames[0], count: 4), head: frames) == nil)
        var portrait = frames; portrait[0].aspectRatio = 9.0 / 16
        #expect(NaturalTransitionVision.match(tail: frames, head: portrait) == nil)
        var invalid = frames; invalid[1].rgb[0] = .nan
        #expect(NaturalTransitionVision.match(tail: invalid, head: frames) == nil)
    }

    private struct Fixture {
        var timeline: Timeline
        var plan: StoryPlan
        var assets: [MediaAsset]
        var analyses: [AnalysisResult]
    }
    private func fixture() -> Fixture {
        let assets = (0..<2).map { i in MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/natural-source-\(i).mov"), kind: .video, byteSize: 1, contentHash: "source-\(i)", metadata: .init(duration: 8, width: 320, height: 180, frameRate: 30)) }
        let candidates = assets.map { asset in
            var insight = CandidateInsights()
            insight.editorialEvidence = .init(usableRange: .init(start: 0, end: 8), confidence: 0.9)
            return Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 8, scores: .init(quality: 0.9, interest: 0.9, action: 0.5, stability: 0.9, uniqueness: 0.9), insights: insight)
        }
        let chapters = candidates.enumerated().map { i, c in StoryChapter(title: i == 0 ? "Рыбалка" : "Багги", candidateIDs: [c.id], eventID: UUID(), eventSceneID: UUID()) }
        let plan = StoryPlan(prompt: "Собери фильм", preset: .cinematic, constraints: .init(targetDuration: 8), chapters: chapters)
        let items = candidates.enumerated().map { i, c in TimelineItem(candidateID: c.id, assetID: c.assetID, kind: .video, sourceStart: 1, sourceDuration: 4, timelineStart: Double(i * 4), timelineDuration: 4, videoAdjustments: VideoAdjustments(crop: .fit), eventID: chapters[i].eventID, eventSceneID: chapters[i].eventSceneID) }
        let timeline = Timeline(storyPlanID: plan.id, width: 320, height: 180, frameRate: 30, items: items,
            titleItems: [TitleTimelineItem(kind: .chapter, templateID: "title.minimal-clean.v1", text: "Багги", startTime: 4, duration: 3)])
        return Fixture(timeline: timeline, plan: plan, assets: assets, analyses: candidates.map { .init(assetID: $0.assetID, analyzedContentHash: "fixture", sceneTags: [], candidates: [$0]) })
    }
    private struct Stub: NaturalTransitionFrameProbing {
        var incoming: UUID?
        var requiredStart: Double = 0
        var empty = false
        func frames(asset: MediaAsset, times: [Double], frameRate: Double) async throws -> [NaturalTransitionFrame] {
            empty ? [] : times.map { NaturalChapterTransitionTests.frame(time: $0, alternate: asset.id == incoming && $0 < requiredStart - 0.001) }
        }
    }

    @Test func searchesSafeHandlesAndPreservesFilmClockTitlesAndChronology() async throws {
        let f = fixture()
        let result = await NaturalChapterTransitionPlanner(prober: Stub(incoming: f.assets[1].id, requiredStart: 1.2)).applying(to: f.timeline, plan: f.plan, assets: f.assets, analyses: f.analyses)
        let evidence = try #require(result.items[1].incomingEditDecision?.naturalTransition)
        #expect(evidence.kind == .composition)
        #expect(abs(result.items[1].sourceStart - 1.2) < 0.001)
        #expect(result.items[0].sourceStart == 1)
        #expect(result.duration == 8)
        #expect(TimelineTiming.playbackTime(forTimelineTime: 8, timeline: result) == 8)
        #expect(result.items.map(\.assetID) == f.timeline.items.map(\.assetID))
        #expect(result.items.map(\.timelineStart) == [0, 4])
        #expect(result.effectiveTitleItems == f.timeline.effectiveTitleItems)
        #expect(result.effectiveTransitionItems.isEmpty)
        #expect(result.items.allSatisfy { $0.transition == nil && $0.effect == nil })
        let decoded = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
        // A valid persisted match does not decode source frames again.
        let again = await NaturalChapterTransitionPlanner(prober: Stub(empty: true)).applying(to: result, plan: f.plan, assets: f.assets, analyses: f.analyses)
        #expect(again == result)
        var trimmed = result; trimmed.items[1].sourceStart += 0.1
        let stale = await NaturalChapterTransitionPlanner(prober: Stub(empty: true)).applying(to: trimmed, plan: f.plan, assets: f.assets, analyses: f.analyses)
        #expect(stale.items[1].incomingEditDecision?.naturalTransition?.kind == .ordinary)
    }

    @Test func missingEvidenceAndUserRestrictionsKeepOrdinaryEdits() async {
        let f = fixture()
        let empty = await NaturalChapterTransitionPlanner(prober: Stub(empty: true)).applying(to: f.timeline, plan: f.plan, assets: f.assets, analyses: f.analyses)
        #expect(empty.items.map(\.sourceStart) == [1, 1])
        #expect(empty.items[1].incomingEditDecision?.naturalTransition?.kind == .ordinary)
        for variant in 0..<5 {
            var copy = f
            if variant == 0 { copy.plan.prompt = "без переходов" }
            if variant == 1 { copy.timeline.items[1].locked = true }
            if variant == 2 { copy.plan.chapters[1].eventID = copy.plan.chapters[0].eventID; copy.plan.chapters[1].title = "Рыбалка" }
            if variant == 3 { copy.timeline.items[1].reversePlayback = true }
            if variant == 4 { copy.timeline.items[1].videoAdjustments?.rotationQuarterTurns = 1 }
            let result = await NaturalChapterTransitionPlanner(prober: Stub()).applying(to: copy.timeline, plan: copy.plan, assets: copy.assets, analyses: copy.analyses)
            #expect(result == copy.timeline)
        }
    }

    @Test func protectsSpeechActionsTelemetryAndRepeatedSourceRanges() {
        let f = fixture(), planner = NaturalChapterTransitionPlanner()
        for variant in 0..<4 {
            var c = f.analyses[0].candidates[0], timeline = f.timeline
            if variant == 0 { c.insights?.speech = .init(text: "Реплика", phraseStart: 1, phraseEnd: 5, confidence: 0.9, startsAtPhraseBoundary: true, endsAtPhraseBoundary: true) }
            if variant == 1 { c.momentBoundary = .init(anticipationStart: 1, peakTime: 3, completionEnd: 5, confidence: 0.9) }
            if variant == 2 { timeline.telemetryItems = [.init(linkedAssetID: f.assets[0].id, timelineStart: 0, timelineDuration: 4)] }
            if variant == 3 { c.insights?.editorialEvidence = nil }
            #expect(planner.starts(for: timeline.items[0], candidate: c, asset: f.assets[0], in: timeline, fps: 30) == [1])
        }
        var repeated = f.timeline
        repeated.items.append(.init(assetID: f.assets[0].id, kind: .video, sourceStart: 5, sourceDuration: 3, timelineStart: 8, timelineDuration: 3))
        #expect(planner.starts(for: repeated.items[0], candidate: f.analyses[0].candidates[0], asset: f.assets[0], in: repeated, fps: 30).allSatisfy { $0 <= 1 })
    }

    @Test func semanticChapterNamesWorkWithoutSceneIDsAndStaleChapterClaimsDisappear() async {
        var f = fixture()
        for i in f.plan.chapters.indices { f.plan.chapters[i].eventID = f.plan.chapters[0].eventID; f.plan.chapters[i].eventSceneID = nil }
        for i in f.timeline.items.indices { f.timeline.items[i].eventID = f.plan.chapters[0].eventID; f.timeline.items[i].eventSceneID = nil }
        let planner = NaturalChapterTransitionPlanner(prober: Stub())
        let result = await planner.applying(to: f.timeline, plan: f.plan, assets: f.assets, analyses: f.analyses)
        #expect(result.items[1].incomingEditDecision?.naturalTransition?.kind == .composition)
        f.plan.chapters[1].title = f.plan.chapters[0].title
        let merged = await planner.applying(to: result, plan: f.plan, assets: f.assets, analyses: f.analyses)
        #expect(merged.items[1].incomingEditDecision?.naturalTransition == nil)
    }

    @Test func ordinaryDissolveAndDisabledTransitionRemainIntactWithoutAMatch() async {
        var f = fixture()
        f.timeline.items[1].transition = TransitionStyle.crossDissolve.rawValue
        f.timeline.transitionItems = [.init(style: .crossDissolve, outgoingClipID: f.timeline.items[0].id, incomingClipID: f.timeline.items[1].id, startTime: 4, duration: 0.5)]
        let result = await NaturalChapterTransitionPlanner(prober: Stub(empty: true)).applying(to: f.timeline, plan: f.plan, assets: f.assets, analyses: f.analyses)
        #expect(result.effectiveTransitionItems == f.timeline.effectiveTransitionItems)
        #expect(result.items[1].transition == f.timeline.items[1].transition)
        #expect(TimelineTiming.playbackTime(forTimelineTime: 8, timeline: result) == 7.5)
        f.timeline.transitionItems?[0].enabled = false
        let disabled = await NaturalChapterTransitionPlanner(prober: Stub()).applying(to: f.timeline, plan: f.plan, assets: f.assets, analyses: f.analyses)
        #expect(disabled == f.timeline)
    }

    @Test func oldDecisionsDecodeWithoutNewEvidence() throws {
        let data = Data(#"{"choice":"cut","motivation":"Обычная склейка","confidence":0.8}"#.utf8)
        #expect(try JSONDecoder().decode(EditorialBoundaryDecision.self, from: data).naturalTransition == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_NATURAL_TRANSITION_PROJECT"] != nil))
    func existingArchiveReceivesOnlyEvidenceBackedChapterEdits() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VELOEDIT_NATURAL_TRANSITION_PROJECT"])
        let project = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let timeline = try #require(project.timelines.last)
        let plan = try #require(project.storyPlans.first { $0.id == timeline.storyPlanID })
        let result = await NaturalChapterTransitionPlanner().applying(to: timeline, plan: plan, assets: project.assets, analyses: project.analyses)
        let decisions = result.items.compactMap { $0.incomingEditDecision?.naturalTransition }
        #expect(!decisions.isEmpty)
        #expect(result.duration == timeline.duration)
        #expect(result.items.map(\.assetID) == timeline.items.map(\.assetID))
        #expect(result.items.map(\.timelineDuration) == timeline.items.map(\.timelineDuration))
        #expect(result.effectiveTitleItems == timeline.effectiveTitleItems)
        #expect(decisions.filter { $0.kind != .ordinary }.allSatisfy { $0.sampledFrameCount >= 8 })
        if let output = ProcessInfo.processInfo.environment["VELOEDIT_NATURAL_TRANSITION_QA_OUTPUT"] {
            let root = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder.veloEdit.encode(result).write(to: root.appendingPathComponent("archive-timeline.json"))
            let report: [String: Any] = ["inspectedBoundaries": decisions.count, "naturalMatches": decisions.filter { $0.kind != .ordinary }.count,
                "decodedFrames": decisions.map(\.sampledFrameCount).reduce(0, +), "duration": result.duration,
                "sourceWindowsChanged": zip(timeline.items, result.items).filter { $0.sourceStart != $1.sourceStart }.count,
                "decisions": result.items.compactMap { $0.incomingEditDecision?.naturalTransition == nil ? nil : $0.incomingEditDecision?.motivation }]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("archive-report.json"))
        }
    }

    @Test func realSourceDecodeAndExportRetainMatchedBoundaryAndDuration() async throws {
        var f = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("natural-transition-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in f.assets.indices {
            let url = root.appendingPathComponent("source-\(i).mov")
            try await writeFixture(url: url, incoming: i == 1)
            f.assets[i].originalURL = url
        }
        // Source windows meet at 5 and 1 seconds; covers occupy 0.3 seconds
        // on either side. This goes through the real AVFoundation decoder.
        let result = await NaturalChapterTransitionPlanner().applying(to: f.timeline, plan: f.plan, assets: f.assets, analyses: f.analyses)
        #expect(result.items[1].incomingEditDecision?.naturalTransition?.kind == .occlusion)
        let destination = root.appendingPathComponent("natural.mp4")
        _ = try await RenderEngine().render(timeline: result, assets: f.assets, quality: .preview720p, destination: destination)
        let rendered = AVURLAsset(url: destination)
        #expect(abs(try await rendered.load(.duration).seconds - 8) < 0.04)
        let playback = try await PlaybackEngine().build(timeline: result, assets: f.assets, forceVideoComposition: true)
        #expect(abs(playback.duration - 8) < 0.001)
        let probes = await PerceptualRenderInspector().inspectAsync(playback: playback, timeline: result, maximumSamples: 24)
        #expect(probes.contains { $0.isBlack && !$0.expectedVisibleContent })
        #expect(!probes.contains { $0.isBlack && $0.expectedVisibleContent })
        #expect(!probes.contains { $0.decodeFailed == true })
        #expect(!NaturalChapterTransitionPlanner.expectsCoveredSource(at: 3.3, timeline: result, darkOnly: true))
        #expect(!NaturalChapterTransitionPlanner.expectsCoveredSource(at: 4.6, timeline: result, darkOnly: true))
        var altered = result; altered.items[1].sourceStart += 0.1
        #expect(!NaturalChapterTransitionPlanner.expectsCoveredSource(at: 4, timeline: altered, darkOnly: true))
        let preview = AVAssetImageGenerator(asset: playback.composition)
        preview.videoComposition = playback.videoComposition
        let export = AVAssetImageGenerator(asset: rendered)
        for generator in [preview, export] {
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        for t in [3.7, 3.9, 4.0, 4.1, 4.3] {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            let a = try await preview.image(at: time).image
            let b = try await export.image(at: time).image
            let af = try #require(NaturalTransitionFrame.make(a, time: t))
            let bf = try #require(NaturalTransitionFrame.make(b, time: t))
            #expect(NaturalTransitionVision.distance(af.meanColor, bf.meanColor) < 0.07, "at \(t)s")
            if t == 4 { #expect(Double(bf.luma.filter { $0 < 0.20 }.count) / Double(bf.luma.count) > 0.95) }
        }
        if let folder = ProcessInfo.processInfo.environment["VELOEDIT_NATURAL_TRANSITION_QA_OUTPUT"] {
            let target = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let output = target.appendingPathComponent("natural-occlusion.mp4")
            if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            try FileManager.default.copyItem(at: destination, to: output)
            try JSONEncoder.veloEdit.encode(result).write(to: target.appendingPathComponent("timeline.json"))
        }
    }

    private func writeFixture(url: URL, incoming: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        try #require(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        for index in 0..<240 {
            let time = Double(index) / 30
            let cover = incoming ? max(0, min(1, (1.33 - time) / 0.36)) : max(0, min(1, (time - 4.6) / 0.36))
            let frame = Self.frame(time: time, cover: cover, alternate: incoming, coverValue: 0.002)
            var buffer: CVPixelBuffer?
            let pool = try #require(adaptor.pixelBufferPool)
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<180 { for x in 0..<320 {
                let i = ((y / 5) * 64 + x / 5) * 3, p = y * stride + x * 4
                base[p] = UInt8(frame.rgb[i + 2] * 255); base[p + 1] = UInt8(frame.rgb[i + 1] * 255)
                base[p + 2] = UInt8(frame.rgb[i] * 255); base[p + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            #expect(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
