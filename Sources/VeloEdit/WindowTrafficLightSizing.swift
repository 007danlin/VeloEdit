import AppKit

enum WindowTrafficLightSizing {
    static func apply(to window: NSWindow) {
        guard #available(macOS 26.0, *) else { return }

        // The compatibility title bar draws 12 pt circles inside 14 × 16 pt
        // buttons. Match the modern 14 pt circles by scaling only their drawing
        // coordinates. Keep the native frames, centers, actions, and toolbar layout.
        let scale: CGFloat = 14.0 / 12.0
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type),
                  button.cell?.cellSize == NSSize(width: 14, height: 16),
                  button.frame.width > 0, button.frame.height > 0
            else { continue }

            let bounds = NSRect(
                origin: .zero,
                size: NSSize(width: button.frame.width / scale, height: button.frame.height / scale)
            )
            if button.bounds != bounds {
                button.bounds = bounds
                button.needsDisplay = true
            }
        }
    }
}
