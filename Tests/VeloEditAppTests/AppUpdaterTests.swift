import Foundation
import Sparkle
import Testing
@testable import VeloEdit

@MainActor
struct AppUpdaterTests {
    private func sparkle(delegate: AppUpdater) -> SPUUpdater {
        SPUUpdater(hostBundle: .main, applicationBundle: .main,
                   userDriver: AppUpdateUserDriver(hostBundle: .main, delegate: nil), delegate: delegate)
    }

    @Test func cancellationIsDeliveredThroughSparkleDelegateProtocol() {
        let updater = AppUpdater()
        let sparkle = sparkle(delegate: updater)
        let delegate: SPUUpdaterDelegate = updater
        #expect(updater.responds(to: NSSelectorFromString("userDidCancelDownload:")))
        delegate.userDidCancelDownload?(sparkle)
        delegate.updater?(sparkle, didFinishUpdateCycleFor: .updates, error: nil)
        #expect(updater.status == "Загрузка обновления отменена")
        #expect(!updater.isRestartingForUpdate)
    }

    @Test func installationCancellationAndDeferralAreNotFailures() {
        for (code, status) in [(SUError.installationCanceledError, "Установка обновления отменена"),
                               (SUError.installationAuthorizeLaterError, "Установка обновления отложена")] {
            let updater = AppUpdater()
            let sparkle = sparkle(delegate: updater)
            updater.updaterWillRelaunchApplication(sparkle)
            let delegate: SPUUpdaterDelegate = updater
            delegate.updater?(sparkle, didFinishUpdateCycleFor: .updates,
                              error: NSError(domain: SUSparkleErrorDomain, code: Int(code.rawValue)))
            #expect(updater.status == status)
            #expect(!updater.isRestartingForUpdate)
        }
    }

    @Test func failedUpdateResetsRestartAndNextCheckClearsError() {
        let updater = AppUpdater()
        let sparkle = sparkle(delegate: updater)
        updater.updaterWillRelaunchApplication(sparkle)
        updater.updater(sparkle, didAbortWithError: URLError(.networkConnectionLost))
        #expect(!updater.isRestartingForUpdate)
        #expect(updater.status.hasPrefix("Обновление не завершено:"))
        updater.updater(sparkle, didAbortWithError: NSError(domain: SUSparkleErrorDomain,
                                                          code: Int(SUError.noUpdateError.rawValue)))
        #expect(updater.status == "Новых совместимых обновлений пока нет")
    }

    @Test func postponedBackgroundCheckDoesNotLeaveAnError() {
        let updater = AppUpdater()
        let sparkle = sparkle(delegate: updater)
        let message = "Проверка отложена до завершения текущей работы."
        updater.updater(sparkle, didFinishUpdateCycleFor: .updatesInBackground,
                        error: NSError(domain: "app.veloedit.updates", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: message]))
        #expect(updater.status == message)
        #expect(!updater.isRestartingForUpdate)
    }

    @Test func failedSaveAndSuccessfulCycleKeepRestartProtectionForRetry() {
        let updater = AppUpdater()
        let sparkle = sparkle(delegate: updater)
        updater.updaterWillRelaunchApplication(sparkle)
        updater.restartWasCancelled()
        updater.updater(sparkle, didFinishUpdateCycleFor: .updates, error: nil)
        #expect(updater.isRestartingForUpdate)
        #expect(updater.status.hasPrefix("Перезапуск отложен:"))
    }

    @Test func acceptedDownloadProceedsToInstallAndRelaunch() {
        let driver = AppUpdateUserDriver(hostBundle: .main, delegate: nil)
        var choices: [SPUUserUpdateChoice] = []
        (driver as SPUUserDriver).showReady(toInstallAndRelaunch: { choices.append($0) })
        #expect(choices == [.install])
    }
}
