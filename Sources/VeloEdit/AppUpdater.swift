import AppKit
import Combine
import Sparkle

/// Sparkle owns downloading, signature validation, installation and relaunch.
/// Its normal quit request goes through VeloEditAppDelegate's autosave/cancel flow.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var status = "Обновления загружаются из GitHub Releases"
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var lastCheckDate: Date?
    private var controller: SPUStandardUpdaterController?
    private weak var model: AppModel?

    func start(model: AppModel) {
        guard controller == nil,
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        self.model = model
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
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
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        status = "Проверяем обновления…"
        controller?.checkForUpdates(nil)
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
        status = "Доступна версия \(item.displayVersionString). Обновление можно установить в открывшемся окне."
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status = "Новых совместимых обновлений пока нет"
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if (error as NSError).domain == SUSparkleErrorDomain,
           (error as NSError).code == SUError.noUpdateError.rawValue { return }
        status = "Обновление не завершено: \(error.localizedDescription)"
    }
}
