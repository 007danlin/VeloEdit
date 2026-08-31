import AppKit
import SwiftUI

/// A local event monitor is used instead of global key equivalents so Timeline
/// shortcuts follow the actual first responder. Text fields and field editors
/// therefore keep the standard macOS editing shortcuts.
struct TimelineKeyboardMonitor: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.start(model: model)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.start(model: model)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private var monitor: Any?
        private weak var model: AppModel?

        func start(model: AppModel) {
            self.model = model
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let model = self.model else { return event }
                return model.handleTimelineKeyDown(event) ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            model = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
