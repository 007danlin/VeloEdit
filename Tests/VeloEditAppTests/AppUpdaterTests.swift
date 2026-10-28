import Foundation
import Sparkle
import Testing
import SwiftUI
import AppKit
@testable import VeloEdit

@MainActor
struct AppUpdaterTests {
    @Test func backgroundNoticeSurvivesOpeningSettingsUntilInstallOrDismissal() {
        let updater = AppUpdater()
        updater.announceUpdate(version: "2.0")
        #expect(updater.showsUpdateDot && updater.highlightsUpdate)
        updater.markUpdateSeen()
        #expect(!updater.showsUpdateDot && updater.highlightsUpdate)
        updater.announceUpdate(version: "2.0")
        #expect(!updater.showsUpdateDot)
        updater.markInstallationRequested()
        #expect(!updater.highlightsUpdate && !updater.showsUpdateDot)
        updater.standardUserDriverWillFinishUpdateSession()
        #expect(!updater.highlightsUpdate && updater.availableVersion == nil)
        updater.announceUpdate(version: "2.1")
        #expect(updater.showsUpdateDot && updater.highlightsUpdate)
        #expect(updater.supportsGentleScheduledUpdateReminders)
        #expect(updater.responds(to: NSSelectorFromString("standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:")))
    }

    @Test func renderUpdateNoticeForVisualReview() throws {
        guard let path = ProcessInfo.processInfo.environment["VELOEDIT_UPDATE_REVIEW_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let updater = AppUpdater()
        updater.announceUpdate(version: "2.0")
        for installing in [false, true] {
            if installing { updater.markInstallationRequested() }
            let view = AppUpdateSettingsCard().environmentObject(updater)
                .padding(24).frame(width: 800).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(installing ? "update-installing.png" : "update-available.png"))
        }
    }

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
