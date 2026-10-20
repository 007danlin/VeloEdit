import AppKit
import SwiftUI

enum OnboardingStep: String, Codable, CaseIterable {
    case welcome, media, director, montage, export

    var section: WorkspaceSection {
        switch self {
        case .welcome: return .home
        case .media: return .media
        case .director: return .director
        case .montage: return .timeline
        case .export: return .export
        }
    }

    var progress: String {
        guard let index = Self.allCases.firstIndex(of: self), index > 0 else { return "Знакомство с VeloEdit" }
        return "\(index) из 4"
    }

    var title: String {
        switch self {
        case .welcome: return "Здесь начинается ваш фильм"
        case .media: return "Добавьте материалы"
        case .director: return "Расскажите, какой фильм хотите"
        case .montage: return "Здесь вы монтируете фильм"
        case .export: return "Сохраните готовое видео"
        }
    }

    func message(fallback: Bool = false) -> String {
        if fallback {
            return "Раздел «\(section.title)» находится здесь. " + message()
        }
        switch self {
        case .welcome:
            return "Здесь можно создать проект или открыть существующий. Сначала покажем основные разделы — создавать проект и добавлять файлы пока не нужно."
        case .media:
            return "Здесь хранятся видео, фото и музыка вашего проекта. Нажмите «Добавить материалы» или перетащите файлы в медиатеку."
        case .director:
            return "Ответьте на вопросы режиссёра или опишите задумку своими словами. Например: «Собери минутный ролик о поездке со спокойной музыкой»."
        case .montage:
            return "Справа вверху — просмотр, внизу — монтажная шкала. Здесь можно менять порядок сцен, подрезать клипы и добавлять титры."
        case .export:
            return "Когда фильм будет готов, выберите качество и папку, затем нажмите «Сохранить видео». Вернуться сюда можно через раздел «Экспорт»."
        }
    }
}

/// Process-owned state; presenting a View never decides whether this is a new user.
@MainActor
final class OnboardingCoordinator: ObservableObject {
    enum Status: String, Codable { case eligible, started, interrupted, completed, dismissed, notRequired }
    struct Record: Codable, Equatable {
        var status: Status
        var step: OnboardingStep
    }
    static let stateKey = "VeloEdit.Onboarding.state.v1"

    @Published private(set) var record: Record
    @Published private(set) var isPresented = false
    @Published private(set) var presentationID = UUID()
    @Published private(set) var showsCompletion = false
    private(set) var isNavigating = false
    private(set) var awaitsProject = false
    private var pendingIntro = false
    private let defaults: UserDefaults
    private weak var model: AppModel?
    private weak var originalResponder: NSResponder?
    private weak var originalWindow: NSWindow?
    private var returnContext: (section: WorkspaceSection, sidebar: Bool)?
    private var completionTask: Task<Void, Never>?

    var step: OnboardingStep { record.step }
    var canResume: Bool { record.status == .interrupted && !isPresented && !awaitsProject }
    var showsProjectlessWorkspace: Bool { isPresented && step != .welcome && model?.project == nil }
    var showsEmptyMontagePreview: Bool { isPresented && step == .montage && model?.timeline == nil }

    init(defaults: UserDefaults, intro: FirstLaunchCoordinator) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.stateKey),
           var saved = try? JSONDecoder().decode(Record.self, from: data) {
            if saved.status == .started { saved.status = .interrupted }
            record = saved
        } else {
            record = Record(status: intro.isPresented ? .eligible : .notRequired, step: .welcome)
        }
        persist()
    }

    func attach(to model: AppModel) {
        self.model = model
        model.intro.onAction = { [weak self] action, replay in self?.introAccepted(action, replay: replay) }
        model.intro.onFinish = { [weak self] action, replay in self?.introFinished(action, replay: replay) }
    }

    func introAccepted(_ action: FirstLaunchCoordinator.Action, replay: Bool) {
        guard !replay else { return }
        if action == .projectCommand {
            pendingIntro = false
            if record.status == .eligible || record.status == .started {
                update(.notRequired, step: .welcome)
            }
        } else if record.status == .eligible {
            pendingIntro = action == .begin
            update(action == .begin ? .started : .dismissed, step: .welcome)
        }
    }

    func introFinished(_ action: FirstLaunchCoordinator.Action, replay: Bool) {
        if replay {
            // The explicit replay in Settings includes the tour after “Начнём”.
            // Skip and project commands still hand control straight to the editor.
            if action == .begin { start() }
            return
        }
        guard action == .begin, pendingIntro else { return }
        pendingIntro = false
        guard let model, model.project == nil, !model.hasActiveWork, !model.isPresentingNewProject else {
            update(.interrupted)
            return
        }
        captureFocus()
        returnContext = (.home, model.isSidebarVisible)
        present(.welcome)
    }

    var unavailableReason: String? {
        guard let model else { return "Интерфейс ещё готовится" }
        if model.intro.isPresented { return "Сначала закройте вступление" }
        if model.hasActiveWork || model.isCreatingProject || model.storageIsCleaning {
            return "Дождитесь завершения текущей операции"
        }
        if model.isPresentingNewProject || model.errorMessage != nil || model.showsMissingMedia
            || model.editorialComparison != nil || model.showEditorialStyle
            || NSApp?.modalWindow != nil || NSApp?.windows.contains(where: { $0.attachedSheet != nil }) == true {
            return "Сначала закройте открытый диалог"
        }
        if let player = model.previewPlayer, player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            return "Сначала поставьте воспроизведение на паузу"
        }
        return nil
    }

    func start(resuming: Bool = false) {
        guard !isPresented, unavailableReason == nil, let model else { return }
        completionTask?.cancel()
        showsCompletion = false
        awaitsProject = false
        captureFocus()
        let originalSection: WorkspaceSection = model.hasProjectWorkspace || model.section == .settings ? model.section : .home
        returnContext = (originalSection, model.isSidebarVisible)
        let destination: OnboardingStep = resuming && step != .welcome ? step
            : (model.project == nil ? .welcome : .media)
        present(destination)
    }

    func advance(expectedID: UUID) {
        guard isPresented, presentationID == expectedID else { return }
        switch step {
        case .welcome: present(.media)
        case .media: present(.director)
        case .director: present(.montage)
        case .montage: present(.export)
        case .export: finish()
        }
    }

    func back(expectedID: UUID) {
        guard isPresented, presentationID == expectedID else { return }
        switch step {
        case .media where model?.project == nil: present(.welcome)
        case .director: present(.media)
        case .montage: present(.director)
        case .export: present(.montage)
        default: break
        }
    }

    /// Called by the actual project actions, including keyboard activation.
    func projectAction() {
        if isPresented && step == .welcome {
            awaitsProject = true
            isPresented = false
            returnContext = nil
            update(.started)
        } else if !awaitsProject {
            interrupt()
        }
    }

    func projectReady() {
        guard awaitsProject, model?.project != nil else { return }
        awaitsProject = false
        present(.media)
    }

    func projectCancelled() {
        guard awaitsProject else { return }
        awaitsProject = false
        update(.interrupted)
    }

    /// Never restores navigation/focus over the user's new action.
    func interrupt() {
        guard !isNavigating, isPresented || awaitsProject else { return }
        let wasProjectless = showsProjectlessWorkspace
        isPresented = false
        if wasProjectless { navigate(.home) }
        awaitsProject = false
        returnContext = nil
        originalResponder = nil
        update(.interrupted)
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        update(.dismissed)
        restoreContext()
    }

    private func finish() {
        isPresented = false
        update(.completed)
        if returnContext == nil { navigate(model?.project == nil ? .home : .media) }
        restoreContext()
        showsCompletion = true
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.showsCompletion = false
            self?.completionTask = nil
        }
    }

    private func present(_ step: OnboardingStep) {
        guard let model else { return }
        update(.started, step: step) // Persist before rendering or animation.
        presentationID = UUID()
        isPresented = true
        isNavigating = true
        model.isSidebarVisible = true
        model.section = step.section
        isNavigating = false
    }

    private func navigate(_ section: WorkspaceSection) {
        isNavigating = true
        model?.section = section
        isNavigating = false
    }

    private func captureFocus() {
        originalWindow = NSApp?.keyWindow
        originalResponder = originalWindow?.firstResponder
    }

    private func restoreContext() {
        if let context = returnContext {
            navigate(context.section)
            model?.isSidebarVisible = context.sidebar
        }
        returnContext = nil
        let responder = originalResponder
        let window = originalWindow
        originalResponder = nil
        DispatchQueue.main.async { [weak self, weak window, weak responder] in
            guard self?.isPresented == false, let window, window.attachedSheet == nil else { return }
            if let view = responder as? NSView, view.window === window { window.makeFirstResponder(view) }
            else { window.makeFirstResponder(window.contentView) }
        }
    }

    private func update(_ status: Status, step: OnboardingStep? = nil) {
        record = Record(status: status, step: step ?? record.step)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: Self.stateKey) }
    }

    deinit { completionTask?.cancel() }
}
