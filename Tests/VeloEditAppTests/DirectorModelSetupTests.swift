import Foundation
import Testing
@testable import VeloEdit

@MainActor
private final class SetupBackend {
    var installed = false
    var downloadCalls = 0
    var fails = false
    var availabilityFails = false
    var registersModel = true
    var suspend = false
    var continuation: CheckedContinuation<Void, Error>?
    var progress: (@Sendable (Double) -> Void)?

    var client: DirectorModelSetupClient {
        DirectorModelSetupClient(isInstalled: {
            if await self.availabilityFails { throw URLError(.cannotConnectToHost) }
            return await self.installed
        }, download: { progress in
            try await self.download(progress)
        })
    }

    private func download(_ progress: @escaping @Sendable (Double) -> Void) async throws {
        downloadCalls += 1
        self.progress = progress
        progress(0.4)
        if suspend { try await withCheckedThrowingContinuation { continuation = $0 } }
        try Task.checkCancellation()
        if fails { throw URLError(.notConnectedToInternet) }
        installed = registersModel
    }
}

@Suite(.serialized)
@MainActor
struct DirectorModelSetupTests {
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "Setup state did not settle")
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "VeloEdit.DirectorModelSetupTests.\(UUID().uuidString)")!
    }

    @Test func firstLaunchWaitsForConsentAndRepeatedAppearDoesNotDuplicate() async throws {
        let backend = SetupBackend()
        let setup = DirectorModelSetup(defaults: defaults(), client: backend.client)
        setup.startIfNeeded()
        setup.startIfNeeded()
        try await eventually { setup.phase == .awaitingDownload }
        #expect(backend.downloadCalls == 0)
        setup.retry()
        try await eventually { setup.isInstalled }
        #expect(backend.downloadCalls == 1)
        #expect(setup.progress == 1)
        #expect(setup.showsCompletion)
        setup.dismissCompletion()
        #expect(!setup.showsCompletion)
    }

    @Test func existingModelIsReusedWithoutDownloadingOrShowingCompletion() async throws {
        let backend = SetupBackend()
        backend.installed = true
        let setup = DirectorModelSetup(defaults: defaults(), client: backend.client)
        setup.startIfNeeded()
        try await eventually { setup.isInstalled }
        #expect(backend.downloadCalls == 0)
        #expect(!setup.showsCompletion)
    }

    @Test func modelInstalledElsewhereClearsStalePrompt() async throws {
        let backend = SetupBackend()
        let setup = DirectorModelSetup(defaults: defaults(), client: backend.client)
        setup.startIfNeeded()
        try await eventually { setup.phase == .awaitingDownload }
        setup.stop() // Opening a project stops initial setup.
        backend.installed = true
        setup.refreshInstallation() // Returning home must recheck.
        try await eventually { setup.isInstalled }
        #expect(backend.downloadCalls == 0)
        #expect(!setup.showsCompletion)
    }

    @Test func refreshNeverResumesAnAuthorizedDownload() async throws {
        let backend = SetupBackend()
        let preferences = defaults()
        preferences.set(true, forKey: DirectorModelSetup.authorizedKey)
        let setup = DirectorModelSetup(defaults: preferences, client: backend.client)
        setup.refreshInstallation()
        try await eventually { setup.phase == .awaitingDownload }
        #expect(backend.downloadCalls == 0)
    }

    @Test func refreshRecognizesInstalledModelEvenWhenPaused() async throws {
        let backend = SetupBackend()
        let setup = DirectorModelSetup(defaults: defaults(), client: backend.client)
        setup.pause()
        backend.installed = true
        setup.refreshInstallation()
        try await eventually { setup.isInstalled }
        #expect(backend.downloadCalls == 0)
        #expect(!setup.showsCompletion)
    }

    @Test func refreshFailureKeepsDismissedBannerHidden() async throws {
        let backend = SetupBackend()
        backend.availabilityFails = true
        let setup = DirectorModelSetup(defaults: defaults(), client: backend.client)
        setup.pause()
        setup.refreshInstallation()
        try await Task.sleep(for: .milliseconds(50))
        #expect(setup.phase == .paused)
        #expect(backend.downloadCalls == 0)
    }

    @Test func diskCheckRequiresEveryCompleteBlob() throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let manifest = storage.appendingPathComponent("manifests/registry.ollama.ai/library/qwen3-vl/2b-instruct")
        let blobs = storage.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let digest = String(repeating: "a", count: 64)
        let configDigest = String(repeating: "b", count: 64)
        let data = try JSONSerialization.data(withJSONObject: [
            "config": ["digest": "sha256:" + configDigest, "size": 2],
            "layers": [["digest": "sha256:" + digest, "size": 4]]
        ])
        try data.write(to: manifest)
        let weight = blobs.appendingPathComponent("sha256-" + digest)
        #expect(!DirectorModelSetupClient.hasDownloadedModel("qwen3-vl:2b-instruct", storage: storage))
        try Data([1, 2]).write(to: blobs.appendingPathComponent("sha256-" + configDigest))
        try Data([1, 2]).write(to: weight)
        #expect(!DirectorModelSetupClient.hasDownloadedModel("qwen3-vl:2b-instruct", storage: storage))
        try Data([1, 2, 3, 4]).write(to: weight)
        #expect(DirectorModelSetupClient.hasDownloadedModel("qwen3-vl:2b-instruct", storage: storage))
        #expect(!DirectorModelSetupClient.hasDownloadedModel("qwen3-vl:4b-instruct", storage: storage))
        try FileManager.default.removeItem(at: weight)
        #expect(!DirectorModelSetupClient.hasDownloadedModel("qwen3-vl:2b-instruct", storage: storage))
    }

    @Test func offlineFailureCanBeRetried() async throws {
        let backend = SetupBackend()
        backend.fails = true
        let setup = DirectorModelSetup(defaults: defaults(), client: backend.client)
        setup.startIfNeeded()
        try await eventually { setup.phase == .awaitingDownload }
        setup.retry()
        try await eventually { if case .failed = setup.phase { return true }; return false }
        #expect(!setup.isInstalled)
        backend.fails = false
        setup.retry()
        try await eventually { setup.isInstalled }
        #expect(backend.downloadCalls == 2)
    }

    @Test func endedDownloadMustActuallyRegisterTheModel() async throws {
        let backend = SetupBackend()
        backend.registersModel = false
        let setup = DirectorModelSetup(defaults: defaults(), client: backend.client)
        setup.startIfNeeded()
        try await eventually { setup.phase == .awaitingDownload }
        setup.retry()
        try await eventually { if case .failed = setup.phase { return true }; return false }
        #expect(!setup.isInstalled)
        #expect(!setup.showsCompletion)
    }

    @Test func laterPersistsAcrossLaunchesAndIgnoresOldDownloadCallbacks() async throws {
        let backend = SetupBackend()
        backend.suspend = true
        backend.registersModel = false
        let preferences = defaults()
        defer { preferences.removeObject(forKey: DirectorModelSetup.pausedKey) }
        let setup = DirectorModelSetup(defaults: preferences, client: backend.client)
        setup.startIfNeeded()
        try await eventually { setup.phase == .awaitingDownload }
        setup.retry()
        try await eventually { backend.continuation != nil }
        setup.pause()
        backend.progress?(1)
        backend.continuation?.resume()
        backend.continuation = nil
        #expect(setup.phase == .paused)
        #expect(preferences.bool(forKey: DirectorModelSetup.pausedKey))

        let nextLaunch = DirectorModelSetup(defaults: preferences, client: backend.client)
        nextLaunch.startIfNeeded()
        try await eventually { nextLaunch.phase == .paused }
        #expect(backend.downloadCalls == 1)
        #expect(setup.phase == .paused)
        backend.suspend = false
        backend.registersModel = true
        nextLaunch.retry()
        try await eventually { nextLaunch.isInstalled }
        #expect(!preferences.bool(forKey: DirectorModelSetup.pausedKey))
    }

    @Test func quitDoesNotDisablePreparationOnNextLaunch() async throws {
        let backend = SetupBackend()
        backend.suspend = true
        backend.registersModel = false
        let preferences = defaults()
        defer { preferences.removeObject(forKey: DirectorModelSetup.pausedKey) }
        let setup = DirectorModelSetup(defaults: preferences, client: backend.client)
        setup.startIfNeeded()
        try await eventually { setup.phase == .awaitingDownload }
        setup.retry()
        try await eventually { backend.continuation != nil }
        setup.stop()
        backend.continuation?.resume()
        backend.continuation = nil
        #expect(!preferences.bool(forKey: DirectorModelSetup.pausedKey))
        backend.suspend = false
        backend.registersModel = true
        let nextLaunch = DirectorModelSetup(defaults: preferences, client: backend.client)
        nextLaunch.startIfNeeded()
        try await eventually { nextLaunch.isInstalled }
        #expect(backend.downloadCalls == 2)
    }
}
