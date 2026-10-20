import AppKit
import SwiftUI
import Testing
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized)
@MainActor
struct OnboardingTests {
    private func withModel(existing: Bool = false, _ body: (AppModel, UserDefaults) async throws -> Void) async rethrows {
        let name = "VeloEdit.OnboardingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        if existing { defaults.set(true, forKey: FirstLaunchCoordinator.completedKey) }
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(defaults: defaults, startBackgroundServices: false)
        try await body(model, defaults)
    }

    private func finishIntro(_ model: AppModel, action: FirstLaunchCoordinator.Action = .begin) {
        model.intro.accept(action, reduceMotion: true)
        model.intro.viewDisappeared()
    }

    @Test func freshLaunchWaitsForRevealAndPreservesEligibilityAcrossIntroPersistence() async {
        await withModel { model, defaults in
            #expect(model.onboarding.record.status == .eligible)
            model.intro.accept(.begin, reduceMotion: true)
            #expect(defaults.bool(forKey: FirstLaunchCoordinator.completedKey))
            #expect(!model.onboarding.isPresented)
            #expect(model.onboarding.record.status == .started)
            model.intro.viewDisappeared()
            #expect(model.onboarding.isPresented)
            #expect(model.onboarding.step == .welcome)
            #expect(model.project == nil)
        }
    }

    @Test(arguments: [FirstLaunchCoordinator.completedKey, FirstLaunchCoordinator.windowFrameKey,
                      "recentProjectPaths.v1", "projectLibraryPaths.v1"])
    func existingInstallDoesNotBecomeNewUserWhenKeyIsMissing(key: String) {
        let name = "VeloEdit.OnboardingMigration.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        if key == FirstLaunchCoordinator.completedKey { defaults.set(true, forKey: key) }
        else if key == FirstLaunchCoordinator.windowFrameKey { defaults.set("0 0 980 700", forKey: key) }
        else { defaults.set(["/tmp/offline.veloedit"], forKey: key) }
        let model = AppModel(defaults: defaults, startBackgroundServices: false)
        #expect(model.onboarding.record.status == .notRequired)
        #expect(!model.onboarding.isPresented)
    }

    @Test func skippingIntroAndFinderCommandNeverStartTour() async {
        await withModel { model, defaults in
            finishIntro(model, action: .skip)
            #expect(model.onboarding.record.status == .dismissed)
            #expect(!model.onboarding.isPresented)
            #expect(!AppModel(defaults: defaults, startBackgroundServices: false).onboarding.isPresented)
        }
        await withModel { model, _ in
            model.intro.accept(.begin)
            model.intro.accept(.projectCommand)
            #expect(model.onboarding.record.status == .notRequired)
            #expect(!model.onboarding.isPresented)
        }
    }

    @Test(arguments: [false, true])
    func replayingIntroContinuesAfterBeginAndRestoresProjectContext(hasProject: Bool) async {
        await withModel(existing: true) { model, _ in
            let project = hasProject ? ProjectManifest(name: "Существующий проект") : nil
            model.project = project
            model.section = .settings
            model.isSidebarVisible = false
            model.intro.replay()
            model.intro.accept(.begin, reduceMotion: true)
            #expect(!model.onboarding.isPresented)
            model.intro.viewDisappeared()
            #expect(model.onboarding.isPresented)
            #expect(model.onboarding.step == (hasProject ? .media : .welcome))
            #expect(model.project?.id == project?.id)
            #expect(!model.isPresentingNewProject)
            let identity = model.onboarding.presentationID
            model.intro.viewDisappeared()
            #expect(model.onboarding.presentationID == identity)
            model.onboarding.dismiss()
            if hasProject {
                #expect(model.section == .settings)
                #expect(!model.isSidebarVisible)
            }
            // An explicit replay also works after the tour was skipped.
            model.intro.replay()
            finishIntro(model)
            #expect(model.onboarding.isPresented)
        }
    }

    @Test(arguments: [FirstLaunchCoordinator.Action.skip, .projectCommand])
    func skippingReplayedIntroOrOpeningProjectDoesNotStartTour(action: FirstLaunchCoordinator.Action) async {
        await withModel(existing: true) { model, _ in
            model.intro.replay()
            finishIntro(model, action: action)
            #expect(!model.onboarding.isPresented)
            #expect(model.onboarding.record.status == .notRequired)
        }
    }

    @Test func projectCommandDuringReplayRevealCancelsTour() async {
        await withModel(existing: true) { model, _ in
            model.intro.replay()
            model.intro.accept(.begin, reduceMotion: true)
            model.intro.accept(.projectCommand)
            model.intro.viewDisappeared()
            #expect(!model.onboarding.isPresented)
            #expect(model.onboarding.record.status == .notRequired)
        }
    }

    @Test func interruptedProcessOffersResumeWithoutOverlay() async {
        await withModel { model, defaults in
            finishIntro(model)
            let reopened = AppModel(defaults: defaults, startBackgroundServices: false)
            #expect(!reopened.onboarding.isPresented)
            #expect(reopened.onboarding.canResume)
            reopened.onboarding.start(resuming: true)
            #expect(reopened.onboarding.step == .welcome)
            #expect(reopened.onboarding.isPresented)
            reopened.onboarding.dismiss()
            let third = AppModel(defaults: defaults, startBackgroundServices: false)
            #expect(third.onboarding.record.status == .dismissed)
            #expect(!third.onboarding.canResume)
            third.onboarding.start()
            #expect(third.onboarding.isPresented)
        }
    }

    @Test func allStepsWorkWithoutMediaAndRestoreManualContextWithoutChangingProject() async {
        await withModel(existing: true) { model, defaults in
            let project = ProjectManifest(name: "Пустой проект")
            model.project = project
            model.section = .settings
            model.isSidebarVisible = false
            model.directorInput = "Мой несохранённый замысел"
            model.exportWorkspaceOptions.prepare(projectID: project.id, maximumFrameRate: 60)
            model.exportWorkspaceOptions.preset = .custom
            model.exportWorkspaceOptions.customQuality = .final1080p
            model.exportWorkspaceOptions.customFrameRate = 24
            let selection = UUID()
            model.selectedTimelineItemID = selection
            model.onboarding.start()
            #expect(model.onboarding.step == .media)
            #expect(model.isSidebarVisible)
            let first = model.onboarding.presentationID
            model.onboarding.advance(expectedID: first)
            model.onboarding.advance(expectedID: first) // A queued double click from the old card.
            #expect(model.onboarding.step == .director)
            model.onboarding.advance(expectedID: model.onboarding.presentationID)
            #expect(model.section == .timeline)
            #expect(model.timeline == nil)
            #expect(!model.shouldHandleTimelineShortcuts)
            model.onboarding.back(expectedID: model.onboarding.presentationID)
            #expect(model.section == .director)
            model.onboarding.advance(expectedID: model.onboarding.presentationID)
            model.onboarding.advance(expectedID: model.onboarding.presentationID)
            #expect(model.section == .export)
            model.onboarding.advance(expectedID: model.onboarding.presentationID)
            #expect(!model.onboarding.isPresented)
            #expect(model.onboarding.record.status == .completed)
            #expect(model.section == .settings)
            #expect(!model.isSidebarVisible)
            #expect(model.project?.id == project.id)
            #expect(model.project?.assets.isEmpty == true)
            #expect(model.project?.timelines.isEmpty == true)
            #expect(model.selectedTimelineItemID == selection)
            #expect(model.directorInput == "Мой несохранённый замысел")
            model.exportWorkspaceOptions.prepare(projectID: project.id, maximumFrameRate: 60)
            #expect(model.exportWorkspaceOptions.preset == .custom)
            #expect(model.exportWorkspaceOptions.customQuality == .final1080p)
            #expect(model.exportWorkspaceOptions.customFrameRate == 24)
            model.exportWorkspaceOptions.prepare(projectID: UUID(), maximumFrameRate: 30)
            #expect(model.exportWorkspaceOptions.preset == .maximum)
            #expect(model.exportWorkspaceOptions.customFrameRate == 30)
            #expect(!AppModel(defaults: defaults, startBackgroundServices: false).onboarding.canResume)
        }
    }

    @Test func userNavigationWinsOverRestorationAndResumeUsesCurrentProject() async {
        await withModel(existing: true) { model, _ in
            model.project = ProjectManifest(name: "Проект")
            model.section = .settings
            model.onboarding.start()
            model.onboarding.advance(expectedID: model.onboarding.presentationID)
            model.openSection(.export)
            #expect(model.section == .export)
            #expect(!model.onboarding.isPresented)
            #expect(model.onboarding.canResume)
            model.onboarding.start(resuming: true)
            #expect(model.section == .director)
            model.onboarding.dismiss()
            #expect(model.section == .export)
            model.onboarding.start()
            model.project = nil
            #expect(!model.onboarding.isPresented)
            model.onboarding.start(resuming: true)
            #expect(model.onboarding.step == .media)
            #expect(model.onboarding.showsProjectlessWorkspace)
        }
    }

    @Test func firstLaunchAutomaticallyCompletesWithoutCreatingAnyProject() async throws {
        try await withModel { model, defaults in
            model.intro.appear(reduceMotion: true)
            model.intro.accept(.begin)
            #expect(!model.onboarding.isPresented)
            // Use the real reveal timer/callback, with no manual start() or finish().
            for _ in 0..<100 {
                if !model.intro.isPresented { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!model.intro.isPresented)
            try #require(model.onboarding.isPresented)
            #expect(model.onboarding.step == .welcome)
            model.onboarding.advance(expectedID: model.onboarding.presentationID)
            #expect(!model.isPresentingNewProject)
            model.onboarding.back(expectedID: model.onboarding.presentationID)
            #expect(model.onboarding.step == .welcome)
            model.onboarding.advance(expectedID: model.onboarding.presentationID)
            for step in [OnboardingStep.media, .director, .montage, .export] {
                #expect(model.onboarding.isPresented)
                #expect(model.onboarding.step == step)
                #expect(model.onboarding.showsProjectlessWorkspace)
                #expect(model.project == nil)
                #expect(model.timeline == nil)
                #expect(model.onboarding.showsEmptyMontagePreview == (step == .montage))
                #expect(!model.isPresentingNewProject)
                #expect(!model.onboarding.awaitsProject)
                model.onboarding.advance(expectedID: model.onboarding.presentationID)
            }
            #expect(!model.onboarding.isPresented)
            #expect(model.onboarding.record.status == .completed)
            #expect(model.onboarding.showsCompletion)
            #expect(model.section == .home)
            #expect(model.project == nil)
            #expect(model.projectURL == nil)
            #expect(model.recentProjectURLs.isEmpty)
            #expect(model.timeline == nil)
            #expect(!model.hasActiveWork)
            let relaunched = AppModel(defaults: defaults, startBackgroundServices: false)
            #expect(!relaunched.intro.isPresented)
            #expect(!relaunched.onboarding.isPresented)
            #expect(!relaunched.onboarding.canResume)
            #expect(relaunched.onboarding.record.status == .completed)
        }
    }

    @Test func optionalProjectCreationFromWelcomeContinuesTourAfterSuccess() async throws {
        try await withModel { model, _ in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VeloEdit-Onboarding-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            finishIntro(model)
            model.createProject() // The real highlighted button, not the tour's “Далее”.
            for _ in 0..<30 {
                if model.isPresentingNewProject { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.isPresentingNewProject)
            #expect(model.onboarding.awaitsProject)
            model.newProjectDraft = NewProjectDraft(name: "Первый фильм", directoryURL: directory)
            await model.confirmProjectCreation()
            #expect(model.newProjectError == nil)
            #expect(model.onboarding.isPresented)
            #expect(model.onboarding.step == .media)
            #expect(!model.onboarding.showsProjectlessWorkspace)
            #expect(model.project?.assets.isEmpty == true)
            #expect(model.timeline == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
            await model.flushAutosave()
        }
    }

    @Test func cancellationDoesNotReopenFormOrOverlay() async throws {
        try await withModel { model, _ in
            finishIntro(model)
            model.createProject()
            for _ in 0..<30 {
                if model.isPresentingNewProject { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            model.cancelProjectCreation()
            #expect(!model.isPresentingNewProject)
            #expect(model.project == nil)
            #expect(!model.onboarding.isPresented)
            #expect(model.onboarding.canResume)
        }
    }

    @Test func errorsAndActualEditingInterruptWithoutMutatingTourData() async {
        await withModel(existing: true) { model, _ in
            model.project = ProjectManifest(name: "Проект")
            model.onboarding.start()
            model.errorMessage = "Диск недоступен"
            #expect(!model.onboarding.isPresented)
            #expect(model.onboarding.unavailableReason != nil)
            model.errorMessage = nil
            model.onboarding.start(resuming: true)
            #expect(model.onboarding.isPresented)
            model.startManualEditing() // No pipeline: even an unavailable action must release the overlay.
            #expect(!model.onboarding.isPresented)
            #expect(model.timeline == nil)
        }
    }

    @Test(arguments: [CGSize(width: 980, height: 700), CGSize(width: 1440, height: 900)])
    func layoutKeepsCardInsideWindowAndAwayFromTargets(size: CGSize) throws {
        let bounds = CGRect(origin: .zero, size: size)
        let targets = [
            CGRect(x: size.width - 220, y: 24, width: 180, height: 32),
            CGRect(x: 300, y: size.height - 120, width: 360, height: 90),
            CGRect(x: 12, y: 120, width: 215, height: 270) // Live sidebar navigation.
        ]
        let card = try #require(OnboardingLayout.cardFrame(size: CGSize(width: 320, height: 260),
                                                         bounds: bounds, avoiding: targets))
        #expect(bounds.insetBy(dx: 12, dy: 12).contains(card))
        #expect(targets.allSatisfy { !$0.intersects(card) })
        #expect(OnboardingLayout.cardFrame(size: CGSize(width: 320, height: 260),
                                          bounds: bounds, avoiding: [bounds]) == nil)
        #expect(OnboardingLayout.targets(step: .montage) == [.preview, .timeline])
    }

    /// Opt-in rendering of the real editor, using isolated defaults and no user media.
    @Test func renderEditorWalkthrough() async throws {
        guard let path = ProcessInfo.processInfo.environment["VELOEDIT_ONBOARDING_REVIEW_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for size in [CGSize(width: 980, height: 700), CGSize(width: 1440, height: 900)] {
            try await withModel(existing: true) { model, _ in
                let view = OnboardingRoot(model: model, coordinator: model.onboarding) {
                    ContentView()
                }
                .environmentObject(model)
                .environmentObject(model.intro)
                .environmentObject(DirectorModelSetup())
                .environmentObject(AppUpdater())
                .preferredColorScheme(.dark)
                .frame(width: size.width, height: size.height)
                let host = NSHostingView(rootView: view)
                host.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host
                defer { window.contentView = nil }
                model.onboarding.start()
                for step in OnboardingStep.allCases {
                    if step != .welcome {
                        model.onboarding.advance(expectedID: model.onboarding.presentationID)
                    }
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(450))
                    host.layoutSubtreeIfNeeded()
                    #expect(model.onboarding.isPresented)
                    #expect(model.onboarding.step == step)
                    #expect(model.project == nil)
                    #expect(model.timeline == nil)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let file = directory.appendingPathComponent("\(step.rawValue)-\(Int(size.width))x\(Int(size.height)).png")
                    try png.write(to: file)
                    print("ONBOARDING_REVIEW \(file.path)")
                }
                model.onboarding.dismiss()
            }
        }
    }
}
