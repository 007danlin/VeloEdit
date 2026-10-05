import SwiftUI
import AppKit

/// The editor mounts a bounded window of the scroll document. A small margin
/// keeps scrolling smooth without recreating the view tree on every pixel.
struct TimelineRenderWindow: Equatable {
    let range: ClosedRange<CGFloat>

    init(visibleRect: CGRect) {
        let step: CGFloat = 256
        let start = max(0, floor(visibleRect.minX / step) * step - step)
        let end = max(start + step, ceil(visibleRect.maxX / step) * step + step)
        range = start...end
    }

    func intersects(x: CGFloat, width: CGFloat) -> Bool {
        x <= range.upperBound && x + max(1, width) >= range.lowerBound
    }
}

private struct TimelineRenderRangeKey: EnvironmentKey {
    static let defaultValue: ClosedRange<CGFloat>? = nil
}

extension EnvironmentValues {
    var timelineRenderRange: ClosedRange<CGFloat>? {
        get { self[TimelineRenderRangeKey.self] }
        set { self[TimelineRenderRangeKey.self] = newValue }
    }
}

/// A long clip keeps its full hit region, but allocates/draws only a small
/// canvas at the visible part. Frame and waveform indices remain global.
struct TimelineDrawingSlice {
    let lower: CGFloat
    let upper: CGFloat
    var width: CGFloat { max(0, upper - lower) }

    init(width: CGFloat, origin: CGFloat, range: ClosedRange<CGFloat>?) {
        lower = min(width, max(0, (range?.lowerBound ?? origin) - origin))
        upper = max(lower, min(width, (range?.upperBound ?? (origin + width)) - origin))
    }

    func indices(count: Int, fullWidth: CGFloat) -> Range<Int> {
        guard width > 0, count > 0, fullWidth > 0 else { return 0..<0 }
        let unit = fullWidth / CGFloat(count)
        let start = max(0, min(count, Int(floor(lower / unit))))
        let end = max(start, min(count, Int(ceil(upper / unit))))
        return start..<end
    }
}

/// Observe AppKit's clip bounds without a SwiftUI geometry preference on every
/// clip. Publish only when the buffered render window changes.
struct TimelineViewportReader: NSViewRepresentable {
    let onChange: (TimelineRenderWindow) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
        view.scheduleUpdate()
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.detach() }

    final class ObserverView: NSView {
        var onChange: ((TimelineRenderWindow) -> Void)?
        private weak var clipView: NSClipView?
        private var observers: [NSObjectProtocol] = []
        private var previous: TimelineRenderWindow?
        private var updateScheduled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleUpdate() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleUpdate() }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            clipView = nil
            previous = nil
        }

        func scheduleUpdate() {
            guard !updateScheduled else { return }
            updateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                self.updateWindow()
            }
        }

        private func updateWindow() {
            guard window != nil, let clip = enclosingScrollView?.contentView else { return }
            if clipView !== clip {
                detach()
                clipView = clip
                clip.postsBoundsChangedNotifications = true
                clip.postsFrameChangedNotifications = true
                for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                        self?.scheduleUpdate()
                    })
                }
            }
            let rect = convert(clip.bounds, from: clip)
            guard rect.width > 0, rect.minX.isFinite, rect.maxX.isFinite else { return }
            let next = TimelineRenderWindow(visibleRect: rect)
            guard previous != next else { return }
            previous = next
            onChange?(next)
        }
    }
}
