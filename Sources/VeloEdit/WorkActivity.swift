import Foundation

/// The display may lock or turn off while user-requested work continues.
/// Each task owns its assertion, so overlapping jobs cannot release each other.
final class WorkActivity {
    private let token: NSObjectProtocol

    init(reason: String) {
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
    }

    deinit { ProcessInfo.processInfo.endActivity(token) }
}
