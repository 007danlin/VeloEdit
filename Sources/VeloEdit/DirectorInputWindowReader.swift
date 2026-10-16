import AppKit
import SwiftUI

/// The composer may live in a background window or an independent preview host.
/// Keep a weak reference to its own window instead of relying on NSApp.keyWindow.
final class DirectorInputWindowReference {
    weak var window: NSWindow?
}

struct DirectorInputWindowReader: NSViewRepresentable {
    let reference: DirectorInputWindowReference

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.reference = reference
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) {
        view.reference = reference
        reference.window = view.window
    }

    final class WindowView: NSView {
        var reference: DirectorInputWindowReference?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.window = window
        }
    }
}
