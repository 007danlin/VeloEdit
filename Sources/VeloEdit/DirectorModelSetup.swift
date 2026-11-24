import Foundation
import SwiftUI
import VeloEditCore

struct DirectorModelSetupClient: Sendable {
    var isInstalled: @Sendable () async throws -> Bool
    var download: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void

    static func live(modelIDs: [String]) -> Self {
        Self(isInstalled: {
            for id in modelIDs {
                if hasDownloadedModel(id, storage: LocalAIModelManager.modelStorageURL) { continue }
                let manager = LocalAIModelManager.shared
                try await manager.ensureService()
                let availability = await manager.availability(model: id)
                guard availability.serviceAvailable else { throw LocalAIModelError.serviceUnavailable }
                if !availability.installed { return false }
            }
            return true
        }, download: { progress in
            let manager = LocalAIModelManager.shared
            for (index, id) in modelIDs.enumerated() {
                try Task.checkCancellation()
                manager.authorizeDownload(model: id)
                try await manager.ensureAuthorizedModelAvailable(model: id) { update in
                    progress((Double(index) + update.fraction) / Double(modelIDs.count))
                }
                progress(Double(index + 1) / Double(modelIDs.count))
            }
        })
    }

    /// The service's model index can lag behind files installed by another
    /// runtime. A manifest alone is insufficient after an interrupted download.
    static func hasDownloadedModel(_ model: String, storage: URL) -> Bool {
        struct Manifest: Decodable {
            struct Blob: Decodable { let digest: String; let size: Int64 }
            let config: Blob
            let layers: [Blob]
        }
        let parts = model.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." }) else { return false }
        let manifestURL = storage.appendingPathComponent("manifests/registry.ollama.ai/library/\(parts[0])/\(parts[1])")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              !manifest.layers.isEmpty else { return false }
        return ([manifest.config] + manifest.layers).allSatisfy { blob in
            let digest = blob.digest
            guard digest.hasPrefix("sha256:"), digest.count == 71,
                  digest.dropFirst(7).allSatisfy({ "0123456789abcdef".contains($0) }),
                  blob.size > 0 else { return false }
            let url = storage.appendingPathComponent("blobs/" + digest.replacingOccurrences(of: ":", with: "-"))
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber else { return false }
            return size.int64Value == blob.size
        }
    }
}

/// The same installation and verification path serves a chosen starter mode
/// and replacements for the built-in models of an existing installation.
@MainActor
final class DirectorModelSetup: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, awaitingDownload, downloading, verifying, installed, paused
        case failed(String)
    }

    static let authorizedKey = "VeloEdit.DirectorModelSetup.Qwen35Mode2B.DownloadAuthorized"
    static let pausedKey = "VeloEdit.DirectorModelSetup.Paused"
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var showsCompletion = false
    private let defaults: UserDefaults
    static let selectionKey = "VeloEdit.Qwen35.FirstMode"
    private static let migrationKey = "VeloEdit.Qwen35.Migration.0200"
    static let legacyModes: [(String, AIPowerMode)] = [
        ("qwen3-vl:2b-instruct", .fast), ("qwen3-vl:4b-instruct", .balanced),
        ("qwen3-vl:8b-instruct", .quality), ("qwen3-vl:30b-a3b-instruct", .quality)
    ]
    @Published private(set) var selectedMode: AIPowerMode
    @Published private(set) var legacyNames: [String] = []
    @Published private(set) var offersCleanup = false
    private(set) var migrationModes: [AIPowerMode] = []
    var isMigration: Bool { !migrationModes.isEmpty }
    private let injectedClient: DirectorModelSetupClient?
    private var client: DirectorModelSetupClient {
        injectedClient ?? .live(modelIDs: targetModes.map { AIAnalysisProfile.resolve(mode: $0).modelID })
    }
    var targetModes: [AIPowerMode] {
        isMigration ? migrationModes : Self.requiredModes(for: selectedMode)
    }
    static func requiredModes(for mode: AIPowerMode) -> [AIPowerMode] {
        mode == .fast ? [.fast] : [mode, .fast]
    }
    static func replacements(for names: [String]) -> [AIPowerMode] {
        let modes = Set(legacyModes.filter { names.contains($0.0) }.map(\.1))
        return modes.isEmpty ? [] : AIPowerMode.allCases.filter { $0 == .fast || modes.contains($0) }
    }
    private var currentPausedKey: String {
        isMigration ? Self.migrationKey + ".Paused" : Self.pausedKey
    }
    private var consentKey: String {
        selectedMode == .fast ? Self.authorizedKey : Self.authorizedKey + "." + selectedMode.rawValue
    }
    private var task: Task<Void, Never>?
    private var attemptID: UUID?
    private var startedThisLaunch = false

    init(defaults: UserDefaults = .standard, client: DirectorModelSetupClient? = nil) {
        self.defaults = defaults
        self.injectedClient = client
        let saved = defaults.string(forKey: Self.selectionKey).flatMap(AIPowerMode.init(rawValue:))
        self.selectedMode = saved.flatMap { AIPowerMode.allCases.contains($0) ? $0 : nil } ?? .fast
        guard client == nil else { return }
        let eligibleKey = Self.migrationKey + ".ExistingInstallation"
        if defaults.object(forKey: eligibleKey) == nil {
            let existing = defaults.bool(forKey: FirstLaunchCoordinator.completedKey)
                || !(defaults.stringArray(forKey: "recentProjectPaths.v1") ?? []).isEmpty
                || !(defaults.stringArray(forKey: "projectLibraryPaths.v1") ?? []).isEmpty
            defaults.set(existing, forKey: eligibleKey)
        }
        guard defaults.bool(forKey: eligibleKey) else { return }
        legacyNames = Self.legacyModes.map(\.0).filter {
            DirectorModelSetupClient.hasDownloadedModel($0, storage: LocalAIModelManager.modelStorageURL)
        }
        if !defaults.bool(forKey: Self.migrationKey + ".Installed") {
            migrationModes = Self.replacements(for: legacyNames)
        } else {
            offersCleanup = !legacyNames.isEmpty && !defaults.bool(forKey: Self.migrationKey + ".CleanupSeen")
        }
    }

    var isInstalled: Bool { phase == .installed }

    func chooseMode(_ mode: AIPowerMode) {
        guard !isMigration, AIPowerMode.allCases.contains(mode), mode != selectedMode else { return }
        stop()
        selectedMode = mode
        defaults.set(mode.rawValue, forKey: Self.selectionKey)
        defaults.set(false, forKey: currentPausedKey)
        phase = .checking
        begin(allowDownload: false)
    }

    func dismissCleanup() {
        offersCleanup = false
        defaults.set(true, forKey: Self.migrationKey + ".CleanupSeen")
    }

    func removedLegacyModel(_ name: String) {
        legacyNames.removeAll { $0 == name }
        if legacyNames.isEmpty { dismissCleanup() }
    }

    private func finishInstallation() {
        if isMigration {
            defaults.set(true, forKey: Self.migrationKey + ".Installed")
            offersCleanup = !legacyNames.isEmpty && !defaults.bool(forKey: Self.migrationKey + ".CleanupSeen")
        }
        phase = .installed
    }

    func startIfNeeded() {
        guard !startedThisLaunch else { return }
        startedThisLaunch = true
        begin()
    }

    func retry() {
        guard task == nil else { return }
        defaults.set(false, forKey: currentPausedKey)
        defaults.set(true, forKey: consentKey)
        begin()
    }

    /// Downloads can finish in a project or another Ollama client after the
    /// initial check. Refresh without granting or reusing download consent.
    func refreshInstallation() {
        guard task == nil, phase != .installed else { return }
        begin(allowDownload: false)
    }

    func pause() {
        defaults.set(true, forKey: currentPausedKey)
        stop()
        phase = .paused
    }

    func modelWasRemoved() {
        stop()
        defaults.set(false, forKey: consentKey)
        defaults.set(false, forKey: currentPausedKey)
        showsCompletion = false
        phase = .awaitingDownload
    }

    func dismissCompletion() { showsCompletion = false }

    func stop() {
        attemptID = nil
        task?.cancel()
        task = nil
    }

    private func begin(allowDownload: Bool = true) {
        guard task == nil else { return }
        let id = UUID()
        attemptID = id
        if allowDownload || phase == .idle { phase = .checking }
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
                    self.defaults.set(false, forKey: self.currentPausedKey)
                    self.finishInstallation()
                    return
                }
                guard !self.defaults.bool(forKey: self.currentPausedKey) else {
                    self.phase = .paused
                    return
                }
                guard allowDownload, self.isMigration || self.defaults.bool(forKey: self.consentKey) else {
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
                self.finishInstallation()
            } catch {
                guard self.attemptID == id, !Task.isCancelled else { return }
                self.phase = self.defaults.bool(forKey: self.currentPausedKey) ? .paused : .failed(error.localizedDescription)
            }
        }
    }
}

struct DirectorModelSetupBanner: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var setup: DirectorModelSetup
    @State private var reviewingLegacyModels = false

    var body: some View {
        if setup.offersCleanup {
            HStack {
                Text("Qwen3.5 готова. На диске остались модели прежней версии.")
                Spacer()
                Button("Посмотреть старые модели") { reviewingLegacyModels = true }
                Button("Оставить модели", action: setup.dismissCleanup)
            }
            .padding().sheet(isPresented: $reviewingLegacyModels) {
                LegacyModelReview(setup: setup).environmentObject(model)
            }
        } else if setup.phase != .idle && setup.phase != .checking && (setup.phase != .paused || setup.isMigration) && (setup.phase != .installed || setup.showsCompletion) {
            HStack(spacing: 12) {
                Image(systemName: setup.isInstalled ? "checkmark.circle.fill" : "sparkles")
                    .foregroundStyle(setup.isInstalled ? Color.green : Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.semibold))
                    if !setup.isMigration && setup.phase == .awaitingDownload {
                        Picker("Режим ИИ", selection: Binding(get: { setup.selectedMode }, set: { mode in
                            setup.chooseMode(mode)
                            model.setAIPowerMode(mode)
                        })) {
                            ForEach(AIPowerMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }.pickerStyle(.segmented).fixedSize()
                    }
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
                    Button("Загрузить модели", action: setup.retry)
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
        if setup.isMigration {
            switch setup.phase {
            case .paused: return "Обновление моделей отложено"
            case .downloading: return "Обновляем модели до Qwen3.5 · \(Int(setup.progress * 100))%"
            case .failed: return "Не удалось обновить модели"
            default: return "Переход на Qwen3.5"
            }
        }
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
        let models = setup.targetModes.map { mode in
            let p = AIAnalysisProfile.resolve(mode: mode)
            return "\(p.modelID) (\(p.estimatedDownloadSize))"
        }.joined(separator: ", ")
        if case .failed(let message) = setup.phase { return message }
        if setup.isMigration { return "Замены установленных моделей: \(models). Монтажи и ручные титры сохранены." }
        switch setup.phase {
        case .idle, .checking: return "Проверяем, установлена ли локальная модель."
        case .awaitingDownload: return "\(models). Режиссёр и кисть используют выбранный режим. Общая 2B придумывает названия глав."
        case .verifying: return "Проверяем готовность ИИ. Это может занять несколько секунд."
        case .downloading: return "Загружаем \(models). Можно продолжать монтаж."
        case .installed: return "Локальная модель установлена. Можно общаться с режиссёром."
        case .paused: return "Можно продолжить загрузку выбранного режима."
        case .failed(let message): return message
        }
    }
}

private struct LegacyModelReview: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var setup: DirectorModelSetup
    @State private var selected: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Модели прежней версии").font(.title2.bold())
            Text("Qwen3.5 установлена. Старые веса могут использоваться другими приложениями Ollama или прерванным заданием VeloEdit.")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(setup.legacyNames, id: \.self) { name in
                HStack {
                    Text(name)
                    Spacer()
                    Button("Удалить…") { selected = name }
                        .disabled(model.storageIsCleaning || model.hasActiveWork || model.downloadingAIPowerMode != nil
                            || (model.project?.autonomousJob?.state.resumesAutomatically == true
                                && model.project?.autonomousJob?.processProfile?.analysis.modelID == name))
                }
            }
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack { Spacer(); Button("Готово") { dismiss() } }
        }
        .padding(24).frame(width: 520)
        .alert("Удалить выбранную модель Ollama?", isPresented: Binding(
            get: { selected != nil }, set: { if !$0 { selected = nil } }
        ), presenting: selected) { name in
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                Task {
                    if await model.removeStoredModel(name) {
                        setup.removedLegacyModel(name)
                        if setup.legacyNames.isEmpty { dismiss() }
                    } else { failure = model.errorMessage ?? "Дождитесь завершения текущей работы и повторите." }
                }
            }
        } message: { name in
            Text("\(name) будет удалена из общего хранилища Ollama. При необходимости её можно скачать снова.")
        }
    }
}
