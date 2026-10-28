import Foundation
import Testing
@testable import VeloEditCore

@Suite struct FilmBuildActivityTests {
    @Test func heartbeatDoesNotHideSlowModelAndRealProgressClearsWarning() {
        var activity = FilmBuildActivity(now: 0)
        activity.observe(.init(.sourceContent, completed: 0, total: 13, detail: "Кадр 1"), now: 0)
        for second in stride(from: 5, through: 45, by: 5) {
            activity.observe(.init(.sourceContent, completed: 0, total: 13,
                detail: "Ожидаю ответ", isHeartbeat: true), now: Double(second))
        }
        #expect(activity.stepStarted == 0)
        #expect(activity.notice(now: 45).delayed)
        #expect(activity.notice(now: 45).message.contains("Ответ модели"))
        activity.observe(.init(.sourceContent, completed: 0, total: 13, detail: "Кадр 2"), now: 46)
        #expect(!activity.notice(now: 46).delayed)
        #expect(activity.notice(now: 46).message.contains("несколько проверок"))
    }

    @Test func silentProducerIsReportedWithoutClaimingWorkIsContinuing() {
        var activity = FilmBuildActivity(now: 100)
        #expect(!activity.notice(now: 129).delayed)
        #expect(activity.notice(now: 130).delayed)
        #expect(activity.notice(now: 130).message.contains("Нет обновлений"))
        activity.observe(.init(.controlExport, completed: 1, total: 100), now: 131)
        #expect(!activity.notice(now: 131).delayed)
        #expect(activity.notice(now: 200).delayed)
    }

    @Test func modelWaitPreservesFrameAndEndsBeforeCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let updates = FilmBuildProgressRecorder()
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { request in
            try await Task.sleep(for: .milliseconds(5200))
            return (Data(#"{"model":"fixture","done":true,"done_reason":"stop","message":{"content":"{}"}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, requestProgress: { await updates.record($0) })
        _ = try await reviewer.modelAnswer(body: ["model": "fixture"], responseURL: root.appendingPathComponent("test.json"),
            progressDetail: "Содержание · кадр 3 из 5")
        let events = await updates.updates
        #expect(events.contains { $0.isHeartbeat && $0.detail?.contains("кадр 3 из 5") == true })
        #expect(events.last?.isHeartbeat == false)
        #expect(events.contains { !$0.isHeartbeat && $0.detail?.hasPrefix("Получен ответ") == true })
        #expect(events.last?.detail == "Наблюдение сохранено · Содержание · кадр 3 из 5")
    }

    @Test func retryIsVisibleAndCancellationDoesNotClaimCompletion() async throws {
        actor FailingTransport {
            var calls = 0
            func send(_ request: URLRequest) throws -> (Data, URLResponse) {
                calls += 1
                if calls == 1 { throw URLError(.timedOut) }
                throw CancellationError()
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let updates = FilmBuildProgressRecorder(), transport = FailingTransport()
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture",
            answerTransport: { try await transport.send($0) }, requestProgress: { await updates.record($0) })
        do {
            _ = try await reviewer.modelAnswer(body: ["model": "fixture"], responseURL: root.appendingPathComponent("test.json"))
            Issue.record("Cancellation should propagate")
        } catch is CancellationError { }
        let events = await updates.updates
        #expect(events.contains { $0.detail?.contains("Повторяю запрос") == true })
        #expect(!events.contains { $0.detail?.hasPrefix("Получен ответ") == true })
    }
}
