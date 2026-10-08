import AppKit
import Combine
import Sparkle

/// Sparkle owns downloading, signature validation, installation and relaunch.
/// Its normal quit request goes through VeloEditAppDelegate's autosave/cancel flow.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var status = "Проверка, загрузка и установка обновлений — внутри VeloEdit"
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var lastCheckDate: Date?
    private var sparkleUpdater: SPUUpdater?
    private weak var model: AppModel?
    private(set) var isRestartingForUpdate = false

    func start(model: AppModel) {
        guard sparkleUpdater == nil,
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        self.model = model
        let driver = AppUpdateUserDriver(hostBundle: .main, delegate: nil)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        sparkleUpdater = updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheckDate)
        do {
            try updater.start()
        } catch {
            status = "Не удалось запустить обновления: \(error.localizedDescription)"
        }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        sparkleUpdater?.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        status = "Проверяем обновления…"
        sparkleUpdater?.checkForUpdates()
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // Avoid presenting an automatic update in the middle of an export or model install.
        // Manual checks remain available; quitting still requires a successful autosave.
        if updateCheck != .updates, let model,
           model.hasActiveWork || model.storageIsCleaning || model.downloadingAIPowerMode != nil {
            throw NSError(domain: "app.veloedit.updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Проверка отложена до завершения текущей работы."])
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "Доступна версия \(item.displayVersionString). После установки VeloEdit сохранит и снова откроет ваш проект."
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        // An informational feed must not turn Install into a website link.
        guard !item.isInformationOnlyUpdate, item.fileURL != nil else {
            throw NSError(domain: "app.veloedit.updates", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Для этой версии пока нет встроенного установщика. Попробуйте проверить обновления позже."])
        }
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        status = "Загружаем версию \(item.displayVersionString)… Прогресс — в окне обновления."
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        status = "Подготавливаем загруженное обновление…"
    }

    func updaterUserDidCancelDownload(_ updater: SPUUpdater) {
        status = "Загрузка обновления отменена"
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        isRestartingForUpdate = true
        status = "Сохраняем проект перед установкой и перезапуском…"
    }

    func restartWasCancelled() {
        // Sparkle only sends willRelaunch once, even if termination is retried.
        status = "Перезапуск отложен: не удалось сохранить проект. \(model?.errorMessage ?? "Попробуйте ещё раз.")"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status = "Новых совместимых обновлений пока нет"
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        isRestartingForUpdate = false
        if (error as NSError).domain == SUSparkleErrorDomain,
           (error as NSError).code == SUError.noUpdateError.rawValue { return }
        status = "Обновление не завершено: \(error.localizedDescription)"
    }
}

/// Keep Sparkle's native download progress, cancellation, errors and version history.
/// The initial Install choice also authorizes the relaunch after the download.
@MainActor
final class AppUpdateUserDriver: SPUStandardUserDriver {
    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.install)
    }
}
