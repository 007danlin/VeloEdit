import Foundation
import Testing
@testable import VeloEditCore
@testable import VeloEdit

@Suite(.serialized) @MainActor
struct StorageSettingsTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VeloEditStorage-\(UUID())")
        let suite = "StorageSettingsTests.\(UUID())"
        let defaults: UserDefaults
        init() throws { defaults = try #require(UserDefaults(suiteName: suite)) }
        func project(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name + ".veloedit")
            _ = try ProjectStore(createAt: url, name: name, recoveryDirectory: root.appendingPathComponent("Recovery"))
            return url
        }
        @MainActor func model(_ urls: [URL]) -> AppModel {
            defaults.set(urls.map(\.path), forKey: "projectLibraryPaths.v1")
            defaults.set(urls.map(\.path), forKey: "recentProjectPaths.v1")
            return AppModel(defaults: defaults, startBackgroundServices: false)
        }
        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func waitForRefresh(_ model: AppModel) async throws {
        for _ in 0..<250 where model.storageIsLoading { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.storageIsLoading)
    }

    private nonisolated static func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 10) == .success)
            }
        }
    }

    @Test func storagePublishesRowsAndAvailabilityBeforeSlowSizeScanAndDoesNotRestoreForgottenRows() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let first = try fixture.project("First")
        let slow = try fixture.project("Slow")
        // Simulate a disconnected disk without touching actual mounted volumes.
        let missing = fixture.root.appendingPathComponent("Offline.veloedit")
        let model = fixture.model([first, slow, missing])
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        model.storageModelsIsLoading = true
        model.refreshStorageUsage(recalculating: nil) { url in
            if url.path == slow.path { started.signal(); _ = release.wait(timeout: .now() + 10) }
            return StorageMaintenance.usage(of: url)
        }
        #expect(model.storageProjects.map { $0.url.path } == [first, slow, missing].map(\.path))
        #expect(model.storageProjects.allSatisfy { $0.isCalculating })
        let didStart = await Self.waitForSignal(started)
        #expect(didStart)
        #expect(model.storageIsLoading)
        #expect(model.storageProjects.first?.isCalculating == false)
        #expect(model.storageProjects.last?.unavailable == true)
        #expect(model.storageProjects.allSatisfy { $0.availabilityIsKnown })
        model.forgetStoredProjects([slow, missing])
        #expect(model.storageProjects.map { $0.url.path } == [first.path])
        release.signal()
        try await waitForRefresh(model)
        #expect(model.storageProjects.map { $0.url.path } == [first.path])
        #expect(model.storageModelsIsLoading) // Model discovery does not block project readiness.
        #expect(fixture.defaults.stringArray(forKey: "recentProjectPaths.v1") == [first.path])
    }

    @Test func cancelledStorageRefreshCannotOverwriteNewResults() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let url = try fixture.project("Project")
        let model = fixture.model([url])
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        defer { release.signal() }
        model.refreshStorageUsage(recalculating: nil) { url in
            started.signal()
            _ = release.wait(timeout: .now() + 10)
            finished.signal()
            return .pending(url)
        }
        #expect(await Self.waitForSignal(started))
        model.refreshStorageUsage(recalculating: nil)
        try await waitForRefresh(model)
        release.signal()
        #expect(await Self.waitForSignal(finished))
        await Task.yield()
        #expect(model.storageProjects.first?.isCalculating == false)
        #expect((model.storageProjects.first?.totalBytes ?? 0) > 0)
    }

    @Test func bulkRemovalOfUnavailableProjectsPreservesFilesAndDoesNotRescanStorage() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let kept = try fixture.project("Keep")
        let orphan = fixture.root.appendingPathComponent("Orphan.veloedit")
        let missing = fixture.root.appendingPathComponent("Offline.veloedit")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        let media = orphan.appendingPathComponent("original.mov")
        try Data([1, 2, 3]).write(to: media)
        let model = fixture.model([kept, orphan, missing])
        model.storageProjects = [kept, orphan, missing].map(StorageMaintenance.usage(of:))
        let result = await model.trashStoredProjects([], forgetting: [orphan, missing])
        #expect(result?.contains("Убрано из списка недоступных проектов: 2") == true)
        #expect(!model.storageIsLoading)
        #expect(!model.storageIsCleaning)
        #expect(model.storageProjects.map(\.url) == [kept])
        #expect(fixture.defaults.stringArray(forKey: "projectLibraryPaths.v1") == [kept.path])
        #expect(try Data(contentsOf: media) == Data([1, 2, 3]))
    }

    @Test func partialStorageRefreshMeasuresOnlyChangedProjects() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let first = try fixture.project("First")
        let second = try fixture.project("Second")
        let model = fixture.model([first, second])
        model.storageProjects = [first, second].map(StorageMaintenance.usage(of:))
        let originalSize = model.storageProjects[1].totalBytes
        model.refreshStorageUsage(recalculating: [first]) { url in
            #expect(url == first)
            return StorageMaintenance.usage(of: url)
        }
        try await waitForRefresh(model)
        #expect(model.storageProjects[1].totalBytes == originalSize)
    }
}
