import Foundation
import Testing
@testable import VeloEditCore

private let response = #"{"scenes":[{"index":3,"interest":0.7,"action":0.6,"quality":0.8,"stability":0.9,"storyValue":0.7,"scene":"A cyclist","tags":["bicycle"],"reason":"Clear action"}]}"#

/// Intentionally ignores cancellation until released, like a stuck external service.
private actor VisionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var started = false
    private(set) var ended = false
    private(set) var wasCancelled = false

    func produce() async -> String {
        started = true
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { self.continuation = continuation }
        }
        wasCancelled = Task.isCancelled
        ended = true
        return response
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite struct VisionCancellationTests {
    @Test func cancellationReleasesCallerAndAbandonsTheLastProducer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = DeepAnalysisCache(rootURL: root)
        let gate = VisionGate()
        let consumer = Task { try await cache.visionResponse(identity: "request", indices: [3]) { await gate.produce() } }
        while !(await gate.started) { await Task.yield() }
        // Ensure a broken implementation fails an assertion instead of hanging the suite.
        let rescue = Task {
            do { try await Task.sleep(for: .seconds(2)); await gate.release() } catch {}
        }
        defer { rescue.cancel() }
        let start = ContinuousClock.now
        consumer.cancel()
        do { _ = try await consumer.value; Issue.record("Cancelled consumer succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(await cache.visionConsumerCount(identity: "request") == 0)
        // A retry must start immediately, not join the abandoned producer.
        let retry = try await cache.visionResponse(identity: "request", indices: [3]) { response }
        #expect(!retry.reused)
        await gate.release()
        while !(await gate.ended) { await Task.yield() }
        #expect(await gate.wasCancelled)
        let stored = try await cache.visionResponse(identity: "request", indices: [3]) { throw URLError(.unknown) }
        #expect(stored.reused)
        #expect(stored.content == response)
    }

    @Test func cancellingOneConsumerKeepsAnotherConsumersRequestAlive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = DeepAnalysisCache(rootURL: root)
        let gate = VisionGate()
        let first = Task { try await cache.visionResponse(identity: "shared", indices: [3]) { await gate.produce() } }
        while !(await gate.started) { await Task.yield() }
        let second = Task { try await cache.visionResponse(identity: "shared", indices: [3]) { throw URLError(.unknown) } }
        while await cache.visionConsumerCount(identity: "shared") < 2 { await Task.yield() }
        let rescue = Task {
            do { try await Task.sleep(for: .seconds(2)); await gate.release() } catch {}
        }
        defer { rescue.cancel() }
        let start = ContinuousClock.now
        first.cancel()
        do { _ = try await first.value; Issue.record("Cancelled consumer succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(await cache.visionConsumerCount(identity: "shared") == 1)
        await gate.release()
        let surviving = try await second.value
        #expect(surviving.content == response)
        #expect(surviving.reused)
        #expect(!(await gate.wasCancelled))
    }
}
