import SwiftUI
import AppKit

@main
struct VeloEditApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(VeloEditAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 700)
                .background(InitialWindowMaximizer())
                .onAppear { appDelegate.model = model }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands { VeloEditCommands(model: model) }
        Settings { SettingsView().environmentObject(model) }
    }
}

@MainActor
final class VeloEditAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel? {
        didSet {
            if let pendingProjectURL, let model { model.openRecentProject(pendingProjectURL); self.pendingProjectURL = nil }
        }
    }
    private var pendingProjectURL: URL?
    private var isFlushingAutosave = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppNotifications.shared.configure()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !isFlushingAutosave else { return .terminateLater }
        isFlushingAutosave = true
        Task {
            let saved = await model.flushAutosave()
            isFlushingAutosave = false
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "veloedit" }) else { return }
        if let model { model.openRecentProject(url) } else { pendingProjectURL = url }
    }
}

/// Opens the first editor window across the screen's usable area without
/// entering macOS full-screen mode. The user can resize it normally afterwards.
private struct InitialWindowMaximizer: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var didBecomeKeyObserver: NSObjectProtocol?
        private var didScheduleMaximize = false
        private var didMaximize = false

        func attach(to window: NSWindow?) {
            guard let window else { return }
            if self.window !== window {
                if let didBecomeKeyObserver {
                    NotificationCenter.default.removeObserver(didBecomeKeyObserver)
                }
                self.window = window
                let hasSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame VeloEdit.Main") != nil
                window.setFrameAutosaveName("VeloEdit.Main")
                if hasSavedFrame { window.setFrameUsingName("VeloEdit.Main"); didMaximize = true }
                window.contentMinSize = NSSize(width: 980, height: 700)
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.standardWindowButton(.closeButton)?.isHidden = false
                window.standardWindowButton(.miniaturizeButton)?.isHidden = false
                window.standardWindowButton(.zoomButton)?.isHidden = false
                didBecomeKeyObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self, weak window] _ in
                    guard let window else { return }
                    self?.scheduleMaximize(window)
                }
            }

            if window.isKeyWindow {
                scheduleMaximize(window)
            }
        }

        private func scheduleMaximize(_ window: NSWindow) {
            guard !didScheduleMaximize, !didMaximize else { return }
            didScheduleMaximize = true
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.didScheduleMaximize = false
                self.maximize(window)
            }
        }

        private func maximize(_ window: NSWindow) {
            guard !didMaximize,
                  let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            else { return }

            didMaximize = true
            window.setFrame(visibleFrame, display: true, animate: false)
        }

        deinit {
            if let didBecomeKeyObserver {
                NotificationCenter.default.removeObserver(didBecomeKeyObserver)
            }
        }
    }
}

struct VeloEditCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Новый проект") { model.createProject() }.keyboardShortcut("n")
            Button("Открыть проект") { model.openProject() }.keyboardShortcut("o")
            Menu("Открыть недавний") {
                if model.recentProjectURLs.isEmpty {
                    Button("Нет недавних проектов") {}
                        .disabled(true)
                } else {
                    ForEach(model.recentProjectURLs.prefix(10), id: \.path) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            model.openRecentProject(url)
                        }
                    }
                }
            }
            Divider()
            Button("Импортировать материалы") { model.chooseMedia() }.keyboardShortcut("i")
                .disabled(model.pipeline == nil)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Вырезать") {
                if model.shouldHandleTimelineShortcuts { model.cutTimelineSelection() }
                else { sendTextCommand(#selector(NSText.cut(_:))) }
            }
                .keyboardShortcut("x")
            Button("Копировать") {
                if model.shouldHandleTimelineShortcuts { model.copyTimelineSelection() }
                else { sendTextCommand(#selector(NSText.copy(_:))) }
            }
                .keyboardShortcut("c")
            Button("Вставить") {
                if model.shouldHandleTimelineShortcuts { model.pasteTimelineSelection() }
                else { sendTextCommand(#selector(NSText.paste(_:))) }
            }
                .keyboardShortcut("v")
            Button("Дублировать") { model.duplicateTimelineSelection() }
                .keyboardShortcut("d")
                .disabled(!model.shouldHandleTimelineShortcuts || !model.hasTimelineSelection || model.isWorking)
            Button("Выбрать всё") {
                if model.shouldHandleTimelineShortcuts { model.selectAllTimelineElements() }
                else { sendTextCommand(#selector(NSText.selectAll(_:))) }
            }
                .keyboardShortcut("a")
        }

        CommandGroup(replacing: .undoRedo) {
            Button(model.shouldHandleTimelineShortcuts ? "Отменить правку монтажа" : "Отменить") {
                if model.shouldHandleTimelineShortcuts { model.undoTimelineEdit() }
                else { sendTextCommand(NSSelectorFromString("undo:")) }
            }
                .keyboardShortcut("z")
                .disabled(model.shouldHandleTimelineShortcuts && (!model.canUndoTimelineEdit || model.isWorking))
            Button(model.shouldHandleTimelineShortcuts ? "Повторить правку монтажа" : "Повторить") {
                if model.shouldHandleTimelineShortcuts { model.redoTimelineEdit() }
                else { sendTextCommand(NSSelectorFromString("redo:")) }
            }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(model.shouldHandleTimelineShortcuts && (!model.canRedoTimelineEdit || model.isWorking))
        }

        CommandGroup(after: .sidebar) {
            Button("Показать/скрыть боковую панель") {
                NotificationCenter.default.post(name: .veloEditToggleSidebar, object: nil)
            }
            .keyboardShortcut("0")
        }

        CommandMenu("Переход") {
            ForEach(Array(WorkspaceSection.allCases.enumerated()), id: \.element.id) { index, section in
                Button(section.title) { model.openSection(section) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(model.project == nil && section != .home)
            }
        }

        CommandMenu("Фильм") {
            Button("Анализировать материалы") { model.analyze() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!model.mediaReady || model.isWorking)
            Button("Создать фильм") { model.createFilm() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!model.mediaReady || model.isWorking || model.isDirectorResponding)
            Button("Открыть просмотр") { model.showMovie() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.hasPlayablePreview)
            Divider()
            Button("Отменить текущую операцию") { model.cancelOperation() }
                .keyboardShortcut(.cancelAction)
                .disabled(!model.isWorking)
        }

        CommandMenu("Воспроизведение") {
            Button("Полноэкранный просмотр") {
                FullScreenPreviewPresenter.shared.toggle(model: model)
            }
            .keyboardShortcut("f", modifiers: [])
            .disabled(!model.shouldHandleTimelineShortcuts || !model.hasPlayablePreview)

            Divider()

            Button("Воспроизвести / пауза") { model.toggleTimelinePlayback() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!model.shouldHandleTimelineShortcuts || !model.hasPlayablePreview)
            Button("Предыдущий кадр") { model.moveTimelinePlayhead(direction: -1, largeStep: false) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!model.shouldHandleTimelineShortcuts || !model.hasPlayablePreview)
            Button("Следующий кадр") { model.moveTimelinePlayhead(direction: 1, largeStep: false) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!model.shouldHandleTimelineShortcuts || !model.hasPlayablePreview)
            Button("Назад на секунду") { model.moveTimelinePlayhead(direction: -1, largeStep: true) }
                .keyboardShortcut(.leftArrow, modifiers: [.shift])
                .disabled(!model.shouldHandleTimelineShortcuts || !model.hasPlayablePreview)
            Button("Вперёд на секунду") { model.moveTimelinePlayhead(direction: 1, largeStep: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.shift])
                .disabled(!model.shouldHandleTimelineShortcuts || !model.hasPlayablePreview)

            Divider()

            Button("В начало фильма") { model.seekTimeline(to: 0) }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(!model.shouldHandleTimelineShortcuts || !model.hasPlayablePreview)
            Button("В конец фильма") { model.seekTimeline(to: model.timeline?.duration ?? 0) }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!model.shouldHandleTimelineShortcuts || !model.hasPlayablePreview)
        }
    }

    private func sendTextCommand(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}

extension Notification.Name {
    static let veloEditToggleSidebar = Notification.Name("VeloEdit.toggleSidebar")
}
