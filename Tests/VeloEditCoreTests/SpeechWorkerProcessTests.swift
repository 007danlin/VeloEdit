import Darwin
import Foundation
import Testing
@testable import VeloEditCore

@Suite struct SpeechWorkerProcessTests {
    @Test func silentExitIncludesCodeSourceAndFreshStage() async throws {
        let fixture = try WorkerFixture()
        defer { fixture.remove() }
        try Data("5/10".utf8).write(to: fixture.progress)
        let error = try await fixture.failure("exit 23")
        #expect(error.contains("код выхода 23"))
        #expect(error.contains("video.mp4"))
        #expect(error.contains("warmup"))
        #expect(!error.contains("5/10"))
        #expect(error.contains("процесс не записал подробности"))
        #expect(fixture.diagnostics.report().contains("код выхода 23"))
    }

    @Test func killedWorkerRetainsSignalAndLastInitializationStage() async throws {
        let fixture = try WorkerFixture()
        defer { fixture.remove() }
        let error = try await fixture.failure("echo 'Loading AudioEncoder' >&2; kill -KILL $$")
        #expect(error.contains("сигнал 9"))
        #expect(error.contains("Loading AudioEncoder"))
        #expect(fixture.diagnostics.report().contains("Loading AudioEncoder"))
    }

    @Test func largeLogKeepsExitStatusAndTail() async throws {
        let fixture = try WorkerFixture()
        defer { fixture.remove() }
        let error = try await fixture.failure("i=0; while [ $i -lt 3000 ]; do echo 'model initialization'; i=$((i + 1)); done; echo 'last failure' >&2; exit 7")
        #expect(error.contains("код выхода 7"))
        #expect(error.contains("last failure"))
        #expect(error.count < 1500)
        #expect(fixture.diagnostics.report().contains("last failure"))
    }

    @Test func successfulWorkerDoesNotReportFailure() async throws {
        let fixture = try WorkerFixture()
        defer { fixture.remove() }
        try await fixture.run("echo ready; exit 0")
        #expect(try String(contentsOf: fixture.log, encoding: .utf8) == "ready\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.diagnostics.url.path))
    }

    @Test func cancellationReapsWorkerThatIgnoresTermination() async throws {
        let fixture = try WorkerFixture()
        defer { fixture.remove() }
        let task = Task { try await fixture.run("trap '' TERM; echo $$; exec /bin/sleep 30") }
        var pid: Int32?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: fixture.log, encoding: .utf8),
               let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                pid = value
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        do {
            try await task.value
            Issue.record("Cancelled worker returned success")
        } catch { #expect(error is CancellationError) }
        let workerPID = try #require(pid)
        #expect(kill(workerPID, 0) == -1)
        #expect(!FileManager.default.fileExists(atPath: fixture.diagnostics.url.path))
    }

    @Test func blankErrorDetailHasReadableFallback() {
        let message = SpeechComponentError.workerFailed(" \n\t").localizedDescription
        #expect(message.contains("речевой процесс завершился без подробностей"))
        #expect(!message.contains(": ."))
    }
}

private struct WorkerFixture: Sendable {
    let root: URL
    let diagnostics: SupportDiagnostics
    var log: URL { root.appendingPathComponent("worker.log") }
    var progress: URL { root.appendingPathComponent("transcript.json.progress") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("speech-worker-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        diagnostics = SupportDiagnostics(url: root.appendingPathComponent("diagnostics.log"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func run(_ script: String) async throws {
        try await SpeechWorkerProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            logURL: log, progressURL: progress, sourceURL: root.appendingPathComponent("video.mp4"), diagnostics: diagnostics)
    }

    func failure(_ script: String) async throws -> String {
        do {
            try await run(script)
            Issue.record("Expected worker failure")
            return ""
        } catch let error as SpeechComponentError {
            return error.localizedDescription
        }
    }
}
