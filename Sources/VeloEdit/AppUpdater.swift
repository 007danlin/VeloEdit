import AppKit
import Combine
import Sparkle

/// Sparkle owns downloading, signature validation, installation and relaunch.
/// Its normal quit request goes through VeloEditAppDelegate's autosave/cancel flow.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var status = "Проверка, загрузка и установка обновлений — внутри VeloEdit"
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var availableVersion: String?
    @Published private(set) var updateWasSeen = false
    @Published private(set) var installationRequested = false
    var showsUpdateDot: Bool { availableVersion != nil && !updateWasSeen && !installationRequested }
    var highlightsUpdate: Bool { availableVersion != nil && !installationRequested }
    private var sparkleUpdater: SPUUpdater?
    private weak var model: AppModel?
    private var isCheckingForUpdates = false
    private(set) var isRestartingForUpdate = false

    func start(model: AppModel) {
        guard sparkleUpdater == nil,
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        self.model = model
        let driver = AppUpdateUserDriver(hostBundle: .main, delegate: self)
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

    func markUpdateSeen() { updateWasSeen = true }

    func installAvailableUpdate() {
        guard canCheckForUpdates else { return }
        markInstallationRequested()
        checkForUpdates()
    }

    func markInstallationRequested() {
        updateWasSeen = true
        installationRequested = true
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                             andInImmediateFocus immediateFocus: Bool) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        announceUpdate(version: update.displayVersionString)
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
        installationRequested = false
    }

    func announceUpdate(version: String) {
        if availableVersion != version {
            updateWasSeen = false
            installationRequested = false
        }
        availableVersion = version
        status = "Доступна версия \(version). После установки VeloEdit сохранит и снова откроет ваш проект."
    }

    func checkForUpdates() {
        guard canCheckForUpdates, let sparkleUpdater else { return }
        // While downloading, this action brings Sparkle's existing window forward.
        // It must not replace download/install progress with a new check status.
        if !sparkleUpdater.sessionInProgress {
            isCheckingForUpdates = true
            status = "Проверяем обновления…"
        }
        sparkleUpdater.checkForUpdates()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        isCheckingForUpdates = false
        announceUpdate(version: item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        // An informational feed must not turn Install into a website link.
        guard !item.isInformationOnlyUpdate, item.fileURL != nil else {
            throw NSError(domain: "app.veloedit.updates", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Для этой версии пока нет встроенного установщика. Попробуйте проверить обновления позже."])
        }
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        markInstallationRequested()
        status = "Загружаем версию \(item.displayVersionString)… Прогресс — в окне обновления."
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        status = "Подготавливаем загруженное обновление…"
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        isCheckingForUpdates = false
        installationRequested = false
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
        isCheckingForUpdates = false
        availableVersion = nil
        installationRequested = false
        status = "Новых совместимых обновлений пока нет"
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        isCheckingForUpdates = false
        installationRequested = false
        if isRestartingForUpdate { model?.clearUpdateRelaunchProject() }
        isRestartingForUpdate = false
        if (error as NSError).domain == "app.veloedit.updates", (error as NSError).code == 1 {
            status = error.localizedDescription
            return
        }
        if (error as NSError).domain == SUSparkleErrorDomain {
            switch (error as NSError).code {
            case Int(SUError.noUpdateError.rawValue):
                updaterDidNotFindUpdate(updater)
                return
            case Int(SUError.installationCanceledError.rawValue):
                status = "Установка обновления отменена"
                return
            case Int(SUError.installationAuthorizeLaterError.rawValue):
                status = "Установка обновления отложена"
                return
            default: break
            }
        }
        status = "Обновление не завершено: \(error.localizedDescription)"
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        // Authorization deferred by the user does not trigger didAbortWithError.
        if let error {
            self.updater(updater, didAbortWithError: error)
        } else if isCheckingForUpdates {
            status = "Проверка обновлений отменена"
        }
        isCheckingForUpdates = false
        // A successful cycle can leave an installer waiting for termination.
        // Keep isRestartingForUpdate until an actual abort, including save retries.
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
