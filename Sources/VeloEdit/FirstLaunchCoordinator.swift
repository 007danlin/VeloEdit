import AppKit
import SwiftUI
import QuartzCore

/// Owned by AppModel for the lifetime of the process, never by a transient View.
@MainActor
final class FirstLaunchCoordinator: ObservableObject {
    enum Phase: Equatable { case appearing, waiting, exiting, finished }
    enum Action { case begin, skip, projectCommand }
    static let completedKey = "VeloEdit.Intro.completed.v1"
    static let startedKey = "VeloEdit.Intro.started.v1"
    static let windowFrameKey = "NSWindow Frame VeloEdit.Main"

    @Published private(set) var phase: Phase
    @Published private(set) var presentationID = UUID()
    @Published private(set) var startedAt: CFTimeInterval?
    @Published private(set) var exitAt: CFTimeInterval?
    private(set) var exitDuration: Double = 0.70
    private(set) var usesLightReveal = true
    private(set) var exitEntryElapsed: Double = 0
    private(set) var isReplay = false
    private let defaults: UserDefaults
    private let clock: () -> CFTimeInterval
    private var task: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, clock: @escaping () -> CFTimeInterval = CACurrentMediaTime) {
        self.defaults = defaults
        self.clock = clock
        // Run before InitialWindowMaximizer registers the autosave frame.
        if defaults.bool(forKey: Self.completedKey) {
            phase = .finished
        } else if defaults.bool(forKey: Self.startedKey) {
            phase = .appearing
        } else if !(defaults.stringArray(forKey: "recentProjectPaths.v1") ?? []).isEmpty
                    || !(defaults.stringArray(forKey: "projectLibraryPaths.v1") ?? []).isEmpty
                    || defaults.object(forKey: Self.windowFrameKey) != nil {
            defaults.set(true, forKey: Self.completedKey)
            phase = .finished
        } else {
            phase = .appearing
        }
        if phase == .appearing { defaults.set(true, forKey: Self.startedKey) }
    }

    var isPresented: Bool { phase != .finished }
    var blocksEditorInput: Bool { isPresented && startedAt != nil }
    var isAnimating: Bool { phase == .appearing && startedAt != nil || phase == .exiting }

    func appear(reduceMotion: Bool) {
        guard phase == .appearing, startedAt == nil else { return }
        defaults.set(true, forKey: Self.startedKey)
        startedAt = clock()
        if reduceMotion { settle(); return }
        schedule(after: 1.90) { $0.settle() }
    }

    func settle() {
        guard phase == .appearing else { return }
        cancelTask()
        phase = .waiting
    }

    /// Persist acceptance before any animation, including an early Return key.
    @discardableResult
    func accept(_ action: Action, reduceMotion: Bool = false, pointer: Bool = false) -> Bool {
        guard isPresented else { return false }
        if action == .projectCommand {
            defaults.set(true, forKey: Self.completedKey)
            finish()
            return true
        }
        guard phase != .exiting else { return false }
        defaults.set(true, forKey: Self.completedKey)
        cancelTask()
        usesLightReveal = action == .begin && !reduceMotion
        exitDuration = usesLightReveal ? 0.70 : 0.12
        exitEntryElapsed = elapsed(at: clock())
        exitAt = clock()
        phase = .exiting
        if action == .begin && pointer {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        schedule(after: exitDuration) { $0.finish() }
        return true
    }

    func replay() {
        guard !isPresented else { return }
        cancelTask()
        isReplay = true
        startedAt = nil
        exitAt = nil
        presentationID = UUID()
        phase = .appearing
    }

    func applicationResignedActive() {
        // No replay of motion when the app becomes active again.
        if phase == .exiting { finish() } else { settle() }
    }

    func viewDisappeared() {
        if phase == .exiting { finish() } else { settle() }
        cancelTask()
    }

    func elapsed(at time: CFTimeInterval) -> Double {
        phase == .waiting ? 1.90 : max(0, time - (startedAt ?? time))
    }

    private func finish() {
        cancelTask()
        phase = .finished
    }

    private func cancelTask() { task?.cancel(); task = nil }

    private func schedule(after seconds: Double, action: @escaping @MainActor (FirstLaunchCoordinator) -> Void) {
        task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            action(self)
        }
    }

    deinit { task?.cancel() }
}

/// Pure, time-based presentation values: no frame-count dependency or springs.
struct FirstLaunchFrame {
    var iconOpacity: Double
    var iconScale: Double
    var textOpacity: Double
    var buttonOpacity: Double
    var rays: Double
    var raySpread: Double
    var sceneOpacity: Double = 1
    var backdropOpacity: Double = 1
    var reveal: Double = 0

    init(elapsed t: Double, settled: Bool = false, exitElapsed: Double? = nil,
         lightReveal: Bool = true, exitDuration: Double = 0.70) {
        let time = settled ? 1.90 : t
        iconOpacity = Self.smooth(time / 0.25)
        let approach = Self.bezier(min(1, max(0, (time - 0.20) / 0.95)))
        iconScale = time < 1.15 ? 0.86 + 0.165 * approach : 1.025 - 0.025 * Self.smooth((time - 1.15) / 0.50)
        textOpacity = Self.smooth((time - 1.25) / 0.40)
        buttonOpacity = Self.smooth((time - 1.50) / 0.40)
        raySpread = Self.smooth((time - 0.55) / 0.90)
        rays = raySpread * (1 - 0.55 * Self.smooth((time - 1.15) / 0.75))
        if let exitElapsed {
            if lightReveal {
                iconScale += (1.12 - iconScale) * Self.smooth((exitElapsed - 0.10) / 0.35)
                iconOpacity *= 1 - Self.smooth((exitElapsed - 0.10) / 0.35)
                textOpacity *= 1 - Self.smooth(exitElapsed / 0.20)
                buttonOpacity *= 1 - Self.smooth(exitElapsed / 0.20)
                backdropOpacity = 1 - Self.smooth((exitElapsed - 0.25) / 0.45)
                reveal = Self.smooth(exitElapsed / 0.45)
                sceneOpacity = 1 - Self.smooth((exitElapsed - 0.45) / 0.25)
            } else {
                sceneOpacity = 1 - Self.smooth(exitElapsed / exitDuration)
            }
        }
    }

    static func smooth(_ x: Double) -> Double { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }

    // Solve x(u) for the prescribed cubic Bézier (0.16, 1, 0.3, 1).
    private static func bezier(_ x: Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<16 {
            let u = (lo + hi) / 2, v = 1 - u
            if 3 * v * v * u * 0.16 + 3 * v * u * u * 0.3 + u * u * u < x { lo = u } else { hi = u }
        }
        return 1 - pow(1 - (lo + hi) / 2, 3)
    }
}
