import AppKit
import AVFoundation
import SwiftUI
import Testing
import VeloEditCore
@testable import VeloEdit

@MainActor
@Suite(.serialized)
struct ViewerToolbarLayoutTests {
    @Test func allSectionsFitNarrowAndShortPreviewColumns() async throws {
        let suite = "VeloEdit.viewer-layout.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: UserDefaults(suiteName: suite)!, startBackgroundServices: false)
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/viewer-test.mov"),
            displayName: "Очень длинное название исходного видео для проверки переноса текста.mov",
            kind: .video, byteSize: 1, contentHash: "layout", metadata: .init(
                duration: 10, width: 1920, height: 1080, frameRate: 29.97, codec: "H.264", hasAudio: true))
        let item = TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 10,
            timelineStart: 0, timelineDuration: 20, speed: 0.5,
            videoAdjustments: .init(filter: .sepia, stabilization: 0.5),
            audioAdjustments: .init(duckOthers: true))
        model.project = ProjectManifest(name: "Viewer QA", assets: [asset],
            timelines: [Timeline(storyPlanID: UUID(), items: [item])])
        model.selectedTimelineItemID = item.id
        model.previewPlayer = AVPlayer()
        // 365 pt is the preview at the minimum main window width; 245 pt
        // also covers a narrow column with an additional inspector visible.
        for width in [245.0, 365.0, 600.0] {
            for tool in ViewerAdjustmentTool.allCases {
                let size = CGSize(width: width, height: 310)
                let host = NSHostingView(rootView: MontagePlayerWorkspace(showsResetAllButton: true, selectedTool: tool)
                    .environmentObject(model).environment(\.colorScheme, .dark)
                    .frame(width: size.width, height: size.height))
                host.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host
                defer { window.contentView = nil }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                func inspect(_ view: NSView) {
                    if view is NSSlider || view is NSPopUpButton {
                        let rect = view.convert(view.bounds, to: host)
                        #expect(rect.minX >= -1 && rect.maxX <= width + 1,
                                "\(tool): \(type(of: view)) clips horizontally at \(rect), width \(width)")
                    }
                    view.subviews.forEach(inspect)
                }
                inspect(host)
                if let folder = ProcessInfo.processInfo.environment["VELOEDIT_VIEWER_QA_DIR"] {
                    func capture(_ suffix: String = "") throws {
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(Int(width))-\(tool.rawValue)\(suffix).png")
                        try data.write(to: url)
                    }
                    try capture()
                    func scrollToBottom(_ view: NSView) -> Bool {
                        if let scroll = view as? NSScrollView, let document = scroll.documentView,
                           document.bounds.height > scroll.contentSize.height + 1 {
                            scroll.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.height - scroll.contentSize.height))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            #expect(scroll.contentView.bounds.minY > 0)
                            return true
                        }
                        return view.subviews.map(scrollToBottom).contains(true)
                    }
                    if scrollToBottom(host) {
                        try await Task.sleep(for: .milliseconds(20))
                        host.layoutSubtreeIfNeeded()
                        try capture("-bottom")
                    }
                }
            }
        }
        model.previewPlayer = nil
    }
}
