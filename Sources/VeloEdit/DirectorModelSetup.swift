import Foundation
import SwiftUI
import VeloEditCore

struct DirectorModelSetupClient: Sendable {
    var isInstalled: @Sendable () async throws -> Bool
    var download: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void

    @MainActor static var live: Self {
        let modelID = LocalDirectorAgent.ollamaModel
        return Self(isInstalled: {
            let manager = LocalAIModelManager.shared
            try await manager.ensureService()
            let availability = await manager.availability(model: modelID)
            guard availability.serviceAvailable else { throw LocalAIModelError.serviceUnavailable }
            return availability.installed
        }, download: { progress in
            let manager = LocalAIModelManager.shared
            manager.authorizeDownload(model: modelID)
            try await manager.pull(model: modelID) { progress($0.fraction) }
        })
    }
}

/// App-level setup, independent of any project or video-analysis model.
@MainActor
final class DirectorModelSetup: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, awaitingDownload, downloading, verifying, installed, paused
        case failed(String)
    }

    static let authorizedKey = "VeloEdit.DirectorModelSetup.DownloadAuthorized"
    static let pausedKey = "VeloEdit.DirectorModelSetup.Paused"
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var showsCompletion = false
    private let defaults: UserDefaults
    private let client: DirectorModelSetupClient
    private var task: Task<Void, Never>?
    private var attemptID: UUID?
    private var startedThisLaunch = false

    init(defaults: UserDefaults = .standard, client: DirectorModelSetupClient? = nil) {
        self.defaults = defaults
        self.client = client ?? .live
    }

    var isInstalled: Bool { phase == .installed }

    func startIfNeeded() {
        guard !startedThisLaunch else { return }
        startedThisLaunch = true
        begin()
    }

    func retry() {
        guard task == nil else { return }
        defaults.set(false, forKey: Self.pausedKey)
        defaults.set(true, forKey: Self.authorizedKey)
        begin()
    }

    func pause() {
        defaults.set(true, forKey: Self.pausedKey)
        stop()
        phase = .paused
    }

    func modelWasRemoved() {
        stop()
        defaults.set(false, forKey: Self.authorizedKey)
        defaults.set(false, forKey: Self.pausedKey)
        showsCompletion = false
        phase = .awaitingDownload
    }

    func dismissCompletion() { showsCompletion = false }

    func stop() {
        attemptID = nil
        task?.cancel()
        task = nil
    }

    private func begin() {
        guard task == nil else { return }
        let id = UUID()
        attemptID = id
        phase = .checking
        progress = 0
        showsCompletion = false
        task = Task { [weak self, client] in
            guard let self else { return }
            defer { if self.attemptID == id { self.task = nil } }
            do {
                let installed = try await client.isInstalled()
                try Task.checkCancellation()
                guard self.attemptID == id else { return }
                if installed {
                    self.defaults.set(false, forKey: Self.pausedKey)
                    self.phase = .installed
                    return
                }
                guard !self.defaults.bool(forKey: Self.pausedKey) else {
                    self.phase = .paused
                    return
                }
                guard self.defaults.bool(forKey: Self.authorizedKey) else {
                    self.phase = .awaitingDownload
                    return
                }
                self.phase = .downloading
                try await client.download { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.attemptID == id, self.phase == .downloading,
                              fraction.isFinite else { return }
                        self.progress = min(1, max(0, fraction))
                    }
                }
                try Task.checkCancellation()
                // An ended stream alone must not be presented as installation.
                self.phase = .verifying
                let verified = try await client.isInstalled()
                try Task.checkCancellation()
                guard self.attemptID == id else { return }
                guard verified else {
                    throw LocalAIModelError.downloadFailed("Модель ещё не готова. Повторите загрузку.")
                }
                self.progress = 1
                self.showsCompletion = true
                self.phase = .installed
            } catch {
                guard self.attemptID == id, !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }
}

struct DirectorModelSetupBanner: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var setup: DirectorModelSetup

    var body: some View {
        if setup.phase != .idle && setup.phase != .paused && (setup.phase != .installed || setup.showsCompletion) {
            HStack(spacing: 12) {
                Image(systemName: setup.isInstalled ? "checkmark.circle.fill" : "sparkles")
                    .foregroundStyle(setup.isInstalled ? Color.green : Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if setup.phase == .downloading {
                        ProgressView(value: setup.progress)
                            .accessibilityLabel("Загрузка ИИ-режиссёра")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                switch setup.phase {
                case .checking, .downloading, .verifying:
                    Button("Позже", action: setup.pause)
                case .awaitingDownload:
                    Button("Загрузить · 2,5 ГБ", action: setup.retry)
                    Button("Ручной монтаж", action: model.beginManualOnboarding)
                    Button("Позже", action: setup.pause)
                case .paused:
                    Button("Продолжить", action: setup.retry)
                case .failed:
                    Button("Повторить", action: setup.retry)
                    Button("Позже", action: setup.pause)
                case .installed:
                    Button("Готово", action: setup.dismissCompletion)
                case .idle:
                    EmptyView()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var title: String {
        switch setup.phase {
        case .idle, .checking: return "Подготавливаем ИИ-режиссёра"
        case .awaitingDownload: return "Подготовьте локального ИИ-режиссёра"
        case .verifying: return "Проверяем загруженную модель"
        case .downloading: return "Загружаем ИИ-режиссёра · \(Int(setup.progress * 100))%"
        case .installed: return "ИИ-режиссёр готов"
        case .paused: return "Подготовка ИИ-режиссёра отложена"
        case .failed: return "Не удалось подготовить ИИ-режиссёра"
        }
    }

    private var detail: String {
        switch setup.phase {
        case .idle, .checking: return "Проверяем, установлена ли локальная модель."
        case .awaitingDownload: return "Для чата нужно один раз скачать около 2,5 ГБ. Загрузка начнётся по вашей команде; ручной монтаж доступен сразу. Модели анализа видео загружаются отдельно."
        case .verifying: return "Проверяем готовность ИИ. Это может занять несколько секунд."
        case .downloading: return "Один раз загрузим около 2,5 ГБ. Затем ИИ работает на этом Mac без интернета. Можно продолжать монтаж."
        case .installed: return "Локальная модель установлена. Можно общаться с режиссёром."
        case .paused: return "Для чата с локальной нейросетью нужно загрузить около 2,5 ГБ."
        case .failed(let message): return message
        }
    }
}
