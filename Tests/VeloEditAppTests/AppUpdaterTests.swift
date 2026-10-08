import Foundation
import Sparkle
import Testing
@testable import VeloEdit

@MainActor
struct AppUpdaterTests {
    @Test func acceptedDownloadProceedsToInstallAndRelaunch() {
        let driver = AppUpdateUserDriver(hostBundle: .main, delegate: nil)
        var choices: [SPUUserUpdateChoice] = []
        (driver as SPUUserDriver).showReady(toInstallAndRelaunch: { choices.append($0) })
        #expect(choices == [.install])
    }
}
