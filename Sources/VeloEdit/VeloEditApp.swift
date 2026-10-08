import SwiftUI
import AppKit

@main
struct VeloEditApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var directorModelSetup = DirectorModelSetup()
    @StateObject private var updater = AppUpdater()
    @NSApplicationDelegateAdaptor(VeloEditAppDelegate.self) private var appDelegate

    init() {
        DistributionSelfCheck.exitIfRequested()
    }

    var body: some Scene {
        Window("VeloEdit", id: "main") {
            FirstLaunchRoot(intro: model.intro) {
                ContentView()
                    .safeAreaInset(edge: .top, spacing: 0) {
                        DirectorModelSetupBanner(setup: directorModelSetup).environmentObject(model)
                    }
            }
                .preferredColorScheme(.dark)
                .environmentObject(model)
                .environmentObject(directorModelSetup)
                .environmentObject(updater)
                .frame(minWidth: 980, minHeight: 700)
                .background(InitialWindowMaximizer())
                .onAppear {
                    appDelegate.updater = updater
                    appDelegate.model = model
                    appDelegate.directorModelSetup = directorModelSetup
                    directorModelSetup.startIfNeeded()
                    updater.start(model: model)
                }
                .onChange(of: directorModelSetup.isInstalled) { _, installed in
                    if installed { Task { await model.refreshDirectorRuntimeStatus() } }
                }
        }
        .windowStyle(.titleBar)
        // Preserve the full-size editor toolbar independently of the traffic lights.
        .windowToolbarStyle(.unified)
        .commands { VeloEditCommands(model: model, updater: updater) }
        Window("Лицензия и компоненты", id: "legal") {
            LegalInfoView()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 780, height: 620)
    }
}

@MainActor
final class VeloEditAppDelegate: NSObject, NSApplicationDelegate {
    weak var updater: AppUpdater?
    weak var directorModelSetup: DirectorModelSetup?
    weak var model: AppModel? {
        didSet {
            guard let model, !didRestoreInitialProject else { return }
            didRestoreInitialProject = true
            if let pendingProjectURL {
                model.clearUpdateRelaunchProject()
                model.openRecentProject(pendingProjectURL)
                self.pendingProjectURL = nil
            } else {
                model.restoreProjectAfterUpdateIfNeeded()
            }
        }
    }
    private var didRestoreInitialProject = false
    private var pendingProjectURL: URL?
    private var isFlushingAutosave = false
    private var waitForWorkTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Keep native windows and panels dark regardless of the macOS theme.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppNotifications.shared.configure()
    }

    func applicationWillTerminate(_ notification: Notification) {
        directorModelSetup?.stop()
        model?.intro.viewDisappeared()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !isFlushingAutosave else { return .terminateLater }
        if updater?.isRestartingForUpdate == true {
            isFlushingAutosave = true
            waitForWorkTask?.cancel()
            waitForWorkTask = nil
            Task {
                await model.waitForUpdateSafePoint()
                let stopped = await model.stopForApplicationTermination(preserveProgress: true)
                let saved = stopped ? await model.saveProjectForUpdateRelaunch() : false
                if !saved { updater?.restartWasCancelled() }
                isFlushingAutosave = false
                sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        }
        if model.storageIsCleaning {
            let alert = NSAlert()
            alert.messageText = "Завершаем обслуживание хранилища"
            alert.informativeText = "Дождитесь завершения операции, затем закройте приложение."
            alert.runModal()
            return .terminateCancel
        }
        waitForWorkTask?.cancel()
        waitForWorkTask = nil
        var preserveProgress = true
        if model.hasActiveWork {
            let alert = NSAlert()
            alert.messageText = "В VeloEdit ещё идёт работа"
            alert.informativeText = "При сохранении и выходе анализ и монтажные правки сохранятся. Создание фильма и экспорт продолжатся при открытии проекта; остальные операции можно запустить повторно."
            alert.addButton(withTitle: "Сохранить и выйти")
            alert.addButton(withTitle: "Дождаться завершения")
            alert.addButton(withTitle: "Остаться")
            alert.addButton(withTitle: "Отменить задачу и выйти")
            switch alert.runModal() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn:
                waitForWorkTask = Task { [weak self, weak model] in
                    guard let model else { return }
                    await model.waitForCurrentWork()
                    guard !Task.isCancelled, !model.hasActiveWork else { return }
                    self?.waitForWorkTask = nil
                    if model.errorMessage == nil { sender.terminate(nil) }
                }
                return .terminateCancel
            case .alertThirdButtonReturn: return .terminateCancel
            default: preserveProgress = false
            }
        }
        isFlushingAutosave = true
        Task {
            let stopped = await model.stopForApplicationTermination(preserveProgress: preserveProgress)
            let saved = stopped ? await model.flushAutosave() : false
            isFlushingAutosave = false
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "veloedit" }) else { return }
        if let model {
            model.clearUpdateRelaunchProject()
            model.openRecentProject(url)
        } else { pendingProjectURL = url }
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

    final class Coordinator: NSObject, NSWindowDelegate {
        private var originalDelegate: NSWindowDelegate?
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            NSApplication.shared.terminate(nil)
            return false // Keep the editor visible if saving or quitting is cancelled.
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (originalDelegate?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            originalDelegate?.responds(to: selector) == true ? originalDelegate : super.forwardingTarget(for: selector)
        }
        private weak var window: NSWindow?
        private var didBecomeKeyObserver: NSObjectProtocol?
        private var willCloseObserver: NSObjectProtocol?
        private var didScheduleMaximize = false
        private var didMaximize = false

        func attach(to window: NSWindow?) {
            guard let window else { return }
            if self.window !== window {
                if let didBecomeKeyObserver {
                    NotificationCenter.default.removeObserver(didBecomeKeyObserver)
                }
                if let willCloseObserver { NotificationCenter.default.removeObserver(willCloseObserver) }
                self.window = window
                originalDelegate = window.delegate
                window.delegate = self
                let hasSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame VeloEdit.Main") != nil
                window.setFrameAutosaveName("VeloEdit.Main")
                if hasSavedFrame { window.setFrameUsingName("VeloEdit.Main"); didMaximize = true }
                window.contentMinSize = NSSize(width: 980, height: 700)
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                didBecomeKeyObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self, weak window] _ in
                    guard let window else { return }
                    WindowTrafficLightSizing.apply(to: window)
                    self?.scheduleMaximize(window)
                }
            }

            WindowTrafficLightSizing.apply(to: window)
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
            if let willCloseObserver { NotificationCenter.default.removeObserver(willCloseObserver) }
            if let didBecomeKeyObserver {
                NotificationCenter.default.removeObserver(didBecomeKeyObserver)
            }
        }
    }
}

struct VeloEditCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Настройки…") { model.openSection(.settings) }.keyboardShortcut(",")
        }
        CommandGroup(after: .appInfo) {
            Button("Проверить обновления…", action: updater.checkForUpdates)
                .disabled(!updater.canCheckForUpdates)
            Button("Лицензия и компоненты…") { openWindow(id: "legal") }
        }
        CommandGroup(replacing: .newItem) {
            Button("Новый проект") { model.createProject() }.keyboardShortcut("n")
                .disabled(model.openingProjectURL != nil)
            Button("Открыть проект…") { model.openProject() }.keyboardShortcut("o")
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
            Button("Импортировать материалы…") { model.chooseMedia() }.keyboardShortcut("i")
                .disabled(model.pipeline == nil || model.openingProjectURL != nil)
            Divider()
            Button("Создать фильм") { model.createFilm() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.openingProjectURL != nil || !model.mediaReady || model.isWorking || model.isDirectorResponding)
            if model.isWorking {
                Button("Остановить текущую операцию") { model.cancelOperation() }
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Экспортировать видео…") { model.openSection(.export) }
                .keyboardShortcut("e")
                .disabled(model.openingProjectURL != nil || model.timeline == nil)
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
            Button(model.shouldHandleTimelineUndo ? "Отменить правку монтажа" : "Отменить") {
                if model.shouldHandleTimelineUndo { model.undoTimelineEdit() }
                else { sendTextCommand(NSSelectorFromString("undo:")) }
            }
                .keyboardShortcut("z")
                .disabled(model.shouldHandleTimelineUndo && (!model.canUndoTimelineEdit || model.isWorking))
            Button(model.shouldHandleTimelineUndo ? "Повторить правку монтажа" : "Повторить") {
                if model.shouldHandleTimelineUndo { model.redoTimelineEdit() }
                else { sendTextCommand(NSSelectorFromString("redo:")) }
            }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(model.shouldHandleTimelineUndo && (!model.canRedoTimelineEdit || model.isWorking))
        }

        CommandGroup(after: .sidebar) {
            Button("Переключить боковую панель") {
                NotificationCenter.default.post(name: .veloEditToggleSidebar, object: nil)
            }
            .keyboardShortcut("0")
            Menu("Перейти к разделу") {
                ForEach(Array(WorkspaceSection.allCases.enumerated()), id: \.element.id) { index, section in
                    Button(section.title) { model.openSection(section) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                        .disabled(!model.hasProjectWorkspace && section != .home && section != .settings)
                }
            }
            Divider()
            Button("Открыть просмотр") { model.showMovie() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.openingProjectURL != nil || !model.hasPlayablePreview)
            Button("Полноэкранный просмотр") {
                FullScreenPreviewPresenter.shared.toggle(model: model)
            }
            .keyboardShortcut("f", modifiers: [])
            .disabled(!model.shouldHandleTimelineShortcuts || !model.hasPlayablePreview)

            Button("Воспроизвести / пауза") { model.toggleTimelinePlayback() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!model.shouldHandleTimelineShortcuts || !model.hasPlayablePreview)
        }

        CommandGroup(replacing: .help) {
            Button("Горячие клавиши…") {
                model.openSection(.settings)
                model.settingsTab = .keyboardShortcuts
            }
        }
    }

    private func sendTextCommand(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}

extension Notification.Name {
    static let veloEditToggleSidebar = Notification.Name("VeloEdit.toggleSidebar")
}
