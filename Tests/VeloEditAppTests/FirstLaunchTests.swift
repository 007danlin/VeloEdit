import AppKit
import Foundation
import Testing
import SwiftUI
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized)
@MainActor
struct FirstLaunchTests {
    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let name = "VeloEdit.FirstLaunchTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }

    @Test func freshProfileStartsOnlyOnceAndWaitsWithoutAnimating() async {
        await withDefaults { defaults in
            var time = 10.0
            let intro = FirstLaunchCoordinator(defaults: defaults, clock: { time })
            #expect(intro.phase == .appearing)
            intro.appear(reduceMotion: false)
            #expect(defaults.bool(forKey: FirstLaunchCoordinator.startedKey))
            #expect(!defaults.bool(forKey: FirstLaunchCoordinator.completedKey))
            time = 10.8
            intro.appear(reduceMotion: false)
            #expect(intro.startedAt == 10)
            intro.settle()
            #expect(intro.phase == .waiting)
            #expect(!intro.isAnimating)
            intro.appear(reduceMotion: false)
            #expect(intro.phase == .waiting)
        }
    }

    @Test(arguments: ["recentProjectPaths.v1", "projectLibraryPaths.v1", FirstLaunchCoordinator.windowFrameKey])
    func existingInstallSkipsBeforeWindowAutosave(key: String) async {
        await withDefaults { defaults in
            if key == FirstLaunchCoordinator.windowFrameKey { defaults.set("0 0 980 700", forKey: key) }
            else { defaults.set(["/offline/project.veloedit"], forKey: key) }
            let intro = FirstLaunchCoordinator(defaults: defaults)
            #expect(!intro.isPresented)
            #expect(defaults.bool(forKey: FirstLaunchCoordinator.completedKey))
        }
    }

    @Test func interruptedLaunchTakesPriorityOverAutosavedFrame() async {
        await withDefaults { defaults in
            let first = FirstLaunchCoordinator(defaults: defaults)
            first.appear(reduceMotion: false)
            first.viewDisappeared()
            defaults.set("0 0 980 700", forKey: FirstLaunchCoordinator.windowFrameKey)
            let second = FirstLaunchCoordinator(defaults: defaults)
            #expect(second.isPresented)
            #expect(!defaults.bool(forKey: FirstLaunchCoordinator.completedKey))
            second.accept(.projectCommand)
            #expect(!FirstLaunchCoordinator(defaults: defaults).isPresented)
        }
    }

    @Test func earlyReturnPersistsImmediatelyAndDuplicateActionsAreIgnored() async throws {
        try await withDefaults { defaults in
            let intro = FirstLaunchCoordinator(defaults: defaults)
            #expect(intro.accept(.begin))
            #expect(intro.phase == .exiting)
            #expect(defaults.bool(forKey: FirstLaunchCoordinator.completedKey))
            #expect(!intro.accept(.begin))
            #expect(!intro.accept(.skip))
            #expect(!FirstLaunchCoordinator(defaults: defaults).isPresented)
            try await Task.sleep(for: .milliseconds(800))
            #expect(!intro.isPresented)
            #expect(!intro.isAnimating)
        }
    }

    @Test func projectCommandPreemptsExitAndCancelsOldCallback() async throws {
        try await withDefaults { defaults in
            let intro = FirstLaunchCoordinator(defaults: defaults)
            intro.appear(reduceMotion: false)
            intro.accept(.begin)
            intro.accept(.projectCommand)
            #expect(!intro.isPresented)
            intro.replay()
            let identity = intro.presentationID
            intro.appear(reduceMotion: false)
            intro.replay()
            #expect(intro.presentationID == identity)
            try await Task.sleep(for: .milliseconds(800))
            #expect(intro.phase == .appearing)
            intro.viewDisappeared()
        }
    }

    @Test func reduceMotionAndSkipUseShortDissolve() async throws {
        try await withDefaults { defaults in
            let intro = FirstLaunchCoordinator(defaults: defaults)
            intro.appear(reduceMotion: true)
            #expect(intro.phase == .waiting)
            #expect(!intro.isAnimating)
            intro.accept(.begin, reduceMotion: true)
            #expect(!intro.usesLightReveal)
            #expect(intro.exitDuration <= 0.15)
            try await Task.sleep(for: .milliseconds(170))
            #expect(!intro.isPresented)
            intro.replay()
            intro.appear(reduceMotion: false)
            intro.accept(.skip)
            #expect(!intro.usesLightReveal)
            #expect(intro.exitDuration <= 0.15)
            intro.viewDisappeared()
        }
    }

    @Test func backgroundAndViewReappearanceNeverRestartMotion() async {
        await withDefaults { defaults in
            let intro = FirstLaunchCoordinator(defaults: defaults)
            intro.appear(reduceMotion: false)
            let started = intro.startedAt
            intro.applicationResignedActive()
            #expect(intro.phase == .waiting)
            intro.appear(reduceMotion: false)
            #expect(intro.startedAt == started)
            #expect(!intro.isAnimating)
            intro.accept(.begin)
            intro.applicationResignedActive()
            #expect(!intro.isPresented)
        }
    }

    @Test func replayPreservesProjectAndSettingsContext() async {
        await withDefaults { defaults in
            defaults.set(true, forKey: FirstLaunchCoordinator.completedKey)
            let model = AppModel(defaults: defaults, startBackgroundServices: false)
            let project = ProjectManifest(name: "Existing")
            model.project = project
            model.section = .settings
            model.intro.replay()
            model.intro.appear(reduceMotion: true)
            model.intro.accept(.projectCommand)
            #expect(model.project?.id == project.id)
            #expect(model.section == .settings)
            #expect(!model.isPresentingNewProject)
            #expect(defaults.bool(forKey: FirstLaunchCoordinator.completedKey))
        }
    }

    @Test func menuNewProjectDismissesIntroBeforeCreatingDraft() async throws {
        try await withDefaults { defaults in
            let model = AppModel(defaults: defaults, startBackgroundServices: false)
            model.intro.appear(reduceMotion: false)
            model.createProject()
            #expect(!model.intro.isPresented)
            try await Task.sleep(for: .milliseconds(30))
            #expect(model.isPresentingNewProject)
            #expect(model.project == nil)
            model.cancelProjectCreation()
        }
    }

    @Test func openingProjectDuringIntroDoesNotCreateAnExtraProject() async throws {
        try await withDefaults { defaults in
            let model = AppModel(defaults: defaults, startBackgroundServices: false, loadProject: { _ in throw CocoaError(.fileReadNoSuchFile) })
            model.intro.appear(reduceMotion: false)
            model.openRecentProject(URL(fileURLWithPath: "/tmp/missing-intro-test.veloedit"))
            #expect(!model.intro.isPresented)
            #expect(defaults.bool(forKey: FirstLaunchCoordinator.completedKey))
            try await Task.sleep(for: .milliseconds(50))
            #expect(!model.isPresentingNewProject)
            #expect(model.project == nil)
        }
    }

    @Test func timingContractAndBoundedScale() {
        #expect(FirstLaunchFrame(elapsed: 0).iconOpacity == 0)
        #expect(FirstLaunchFrame(elapsed: 1.90).buttonOpacity > 0.999)
        #expect(abs(FirstLaunchFrame(elapsed: 2).iconScale - 1) < 0.00001)
        #expect(FirstLaunchFrame(elapsed: 1.7).buttonOpacity > 0)
        for tick in 0...200 {
            let frame = FirstLaunchFrame(elapsed: Double(tick) / 100)
            #expect(frame.iconScale >= 0.86 && frame.iconScale <= 1.02501)
        }
        let exit = FirstLaunchFrame(elapsed: 2, exitElapsed: 0.70)
        #expect(exit.sceneOpacity == 0)
        #expect(exit.backdropOpacity == 0)
        #expect(exit.iconScale <= 1.12)
    }

    @Test func rasterBudgetCoversRetinaOvershootAndMissingArtworkFallsBack() {
        for scale in [1.0, 2, 3] {
            for height in [700.0, 900, 1400] {
                #expect(FirstLaunchArtwork.requiredPixels(height: height, scale: scale) <= 1254.01)
            }
        }
        #expect(FirstLaunchArtwork.load(bundle: Bundle(for: NSObject.self)) == nil)
    }

    /// Optional review artifacts from the real SwiftUI scene and packaged PNGs.
    /// Run with VELOEDIT_INTRO_REVIEW_DIR and VELOEDIT_INTRO_APP_BUNDLE set.
    @Test func renderControlFrames() async throws {
        guard let directory = ProcessInfo.processInfo.environment["VELOEDIT_INTRO_REVIEW_DIR"],
              let bundlePath = ProcessInfo.processInfo.environment["VELOEDIT_INTRO_APP_BUNDLE"],
              let bundle = Bundle(path: bundlePath) else { return }
        try await withDefaults { defaults in
            let intro = FirstLaunchCoordinator(defaults: defaults)
            intro.appear(reduceMotion: true)
            let image = try #require(FirstLaunchArtwork.load(bundle: bundle))
            #expect(image.image.width >= 1024)
            for size in [CGSize(width: 980, height: 700), CGSize(width: 1440, height: 900)] {
                let view = FirstLaunchView(intro: intro, artworkBundle: bundle)
                    .frame(width: size.width, height: size.height)
                let host = NSHostingView(rootView: view)
                host.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                let url = URL(fileURLWithPath: directory).appendingPathComponent("scene-\(Int(size.width))x\(Int(size.height)).png")
                try data.write(to: url)
                print("INTRO_REVIEW \(url.path) pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
                window.contentView = nil
            }
        }
    }
}
