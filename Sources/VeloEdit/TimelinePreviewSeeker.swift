import Foundation

/// One decoder request at a time, with only the newest pointer position queued.
/// The UI clock is independent of decoder latency. After the pointer settles,
/// an exact seek replaces the tolerant seeks used during motion.
@MainActor
final class TimelinePreviewSeeker {
    struct Request: Equatable {
        let time: Double
        let frameRate: Double
        let exact: Bool
    }

    typealias Seek = (Request, @escaping @MainActor () -> Void) -> Void
    private var pending: Request?
    private var activeID: UUID?
    private var scheduled: Task<Void, Never>?
    private var settlement: Task<Void, Never>?
    private var lastStarted: TimeInterval = 0
    private var generation = UUID()
    private let cadence: TimeInterval
    private let settleDelay: TimeInterval
    private let seek: Seek

    var isSeeking: Bool { activeID != nil || pending != nil || settlement != nil }

    init(cadence: TimeInterval = 1 / 60, settleDelay: TimeInterval = 0.08, seek: @escaping Seek) {
        self.cadence = cadence
        self.settleDelay = settleDelay
        self.seek = seek
    }

    func submit(time: Double, frameRate: Double) {
        pending = Request(time: time, frameRate: frameRate, exact: false)
        settlement?.cancel()
        let generation = generation
        settlement = Task { [weak self, settleDelay] in
            do { try await Task.sleep(for: .seconds(settleDelay)) } catch { return }
            guard let self, self.generation == generation else { return }
            self.settlement = nil
            self.pending = Request(time: time, frameRate: frameRate, exact: true)
            self.schedule()
        }
        schedule()
    }

    func reset() {
        generation = UUID()
        scheduled?.cancel()
        settlement?.cancel()
        scheduled = nil
        settlement = nil
        pending = nil
        activeID = nil
        lastStarted = 0
    }

    private func schedule() {
        guard activeID == nil, scheduled == nil, pending != nil else { return }
        let delay = max(0, cadence - (ProcessInfo.processInfo.systemUptime - lastStarted))
        let generation = generation
        // Always leave the mouse event first, even when the decoder is idle.
        scheduled = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == generation, let request = self.pending else { return }
            self.scheduled = nil
            self.pending = nil
            let id = UUID()
            self.activeID = id
            self.lastStarted = ProcessInfo.processInfo.systemUptime
            self.seek(request) { [weak self] in
                guard let self, self.activeID == id, self.generation == generation else { return }
                self.activeID = nil
                self.schedule()
            }
        }
    }
}
