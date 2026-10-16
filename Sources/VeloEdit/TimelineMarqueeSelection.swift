import AppKit
import SwiftUI

struct TimelineSelectionRegion {
    let frame: CGRect
    let keys: Set<TimelineSelectionKey>
}

/// Freeze the initial selection and geometry for the entire mouse sequence.
/// Recompute from that baseline so shrinking a Shift-marquee leaves no trail.
struct TimelineMarqueeSession {
    let anchor: CGPoint
    let baseline: Set<TimelineSelectionKey>
    let regions: [TimelineSelectionRegion]
    private(set) var rectangle: CGRect?

    mutating func update(to point: CGPoint) -> Set<TimelineSelectionKey> {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        guard rectangle != nil || hypot(dx, dy) >= 3 else { return baseline }
        let rect = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
            width: max(1, abs(dx)), height: max(1, abs(dy)))
        rectangle = rect
        return regions.reduce(into: baseline) { selection, region in
            if region.frame.intersects(rect) { selection.formUnion(region.keys) }
        }
    }
}

/// Observe only mouse sequences that begin on empty timeline space. Returning
/// every other event unchanged keeps SwiftUI's clip/trim/ruler gestures intact.
/// The transparent native overlay never participates in hit testing or scrolling.
struct TimelineMarqueeSelection: NSViewRepresentable {
    let isEnabled: Bool
    let regions: [TimelineSelectionRegion]
    let rulerFrame: CGRect
    let selection: () -> Set<TimelineSelectionKey>
    let onSelection: (Set<TimelineSelectionKey>) -> Void
    let onActiveChange: (Bool) -> Void
    let onEmptyClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: InteractionView, context: Context) {
        view.isEnabled = isEnabled
        view.regions = regions
        view.rulerFrame = rulerFrame
        view.selection = selection
        view.onSelection = onSelection
        view.onActiveChange = onActiveChange
        view.onEmptyClick = onEmptyClick
        if !isEnabled { view.finish() }
    }

    static func dismantleNSView(_ view: InteractionView, coordinator: ()) { view.detach() }

    final class InteractionView: NSView {
        var isEnabled = true
        var regions: [TimelineSelectionRegion] = []
        var rulerFrame = CGRect.zero
        var selection: () -> Set<TimelineSelectionKey> = { [] }
        var onSelection: (Set<TimelineSelectionKey>) -> Void = { _ in }
        var onActiveChange: (Bool) -> Void = { _ in }
        var onEmptyClick: (CGPoint) -> Void = { _ in }
        private(set) var session: TimelineMarqueeSession?
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.finish() }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            monitor = nil
            resignObserver = nil
            finish()
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        }

        @discardableResult
        func handle(_ event: NSEvent) -> Bool {
            guard isEnabled, let window, !isHiddenOrHasHiddenAncestor else { return false }
            let point = convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDown:
                guard event.window === window, !event.modifierFlags.contains(.control),
                      let clip = enclosingScrollView?.contentView,
                      clip.bounds.contains(clip.convert(event.locationInWindow, from: nil)),
                      !rulerFrame.contains(point),
                      !regions.contains(where: { $0.frame.contains(point) }) else { return false }
                let baseline = event.modifierFlags.contains(.shift) ? selection() : []
                session = TimelineMarqueeSession(anchor: point, baseline: baseline, regions: regions)
                // End text editing so existing timeline keyboard actions work
                // immediately after selecting with the mouse.
                window.makeFirstResponder(nil)
                onActiveChange(true)
                onSelection(baseline)
                return true
            case .leftMouseDragged, .leftMouseUp:
                guard var session else { return false }
                let selected = session.update(to: point)
                self.session = session
                needsDisplay = true
                if session.rectangle != nil { onSelection(selected) }
                if event.type == .leftMouseUp {
                    if session.rectangle == nil {
                        onSelection([])
                        onEmptyClick(point)
                    }
                    finish()
                }
                return true
            default:
                return false
            }
        }

        func finish() {
            guard session != nil else { return }
            session = nil
            needsDisplay = true
            onActiveChange(false)
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let rectangle = session?.rectangle else { return }
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            rectangle.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(rect: rectangle.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
    }
}
