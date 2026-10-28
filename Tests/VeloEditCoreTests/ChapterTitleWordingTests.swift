import Foundation
import Testing
@testable import VeloEditCore

struct ChapterTitleWordingTests {
    private func input() -> ChapterTitleInput {
        .init(partID: UUID(), ordinal: 1, duration: 5, language: "ru", maxCharacters: 48,
            evidence: [.init(id: "e0", assetID: UUID(), itemID: UUID(), sourceStart: 0, sourceEnd: 5,
                timelineStart: 0, timelineEnd: 5, origin: .visualSummary,
                observation: "Two people are seated with tablets.", selected: true, frameTimes: [0, 1, 2, 3, 4], actionSequence: false)],
            coverage: .init(selectedSeconds: 5, observedSeconds: 5, sampledEvidenceCount: 1,
                availableEvidenceCount: 1, beginning: true, middle: true, end: true),
            limitations: [], responseCacheIdentity: "same-source-interval-and-observations")
    }
    private var theme: ChapterThemeProposal {
        .init(theme: "двое людей с планшетами", setting: "внутреннее пространство с современным сиденьем",
            secondaryActivities: [], contradictions: [], unknowns: [], titles: [
                .init(text: "Внутреннее пространство с современным сиденьем", claims: [.init(text: "Помещение", kind: "setting", evidenceIDs: ["e0"])]),
                .init(text: "Двое людей с планшетами", claims: [.init(text: "Двое людей с планшетами", kind: "people", evidenceIDs: ["e0"])])])
    }

    @Test func wordingKeepsChosenEvidenceAndCachesItsExactOrderedRequest() async throws {
        actor Transport {
            var requests: [Data] = []
            func send(_ request: URLRequest) throws -> (Data, URLResponse) {
                requests.append(request.httpBody!)
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                #expect(body["model"] as? String == "qwen3-vl:2b-instruct")
                let bytes = try JSONSerialization.data(withJSONObject: ["model": body["model"]!, "done": true,
                    "done_reason": "stop", "message": ["content": #"{"titles":[{"text":"двое людей с планшетами","proposalIndex":1},{"text":"Двое людей с планшетами","proposalIndex":0}]}"#]])
                return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = Transport()
        var model = LocalChapterTitleModel(model: "qwen3-vl:2b-instruct", digest: "weights-a", mode: .fast, responseCacheURL: root)
        model.answerTransport = { try await transport.send($0) }
        let edited = try await model.editWording(theme, input: input())
        #expect(edited.titles.count == 1)
        #expect(edited.titles[0].text == "Двое людей с планшетами")
        #expect(edited.titles[0].claims == theme.titles[1].claims)
        #expect(edited.theme == theme.theme)
        _ = try await model.editWording(theme, input: input())
        #expect(await transport.requests.count == 1)
        let sent = String(decoding: await transport.requests[0], as: UTF8.self)
        #expect(sent.contains(#""properties":{"text":{"#))
        var different = input(); different.responseCacheIdentity = "changed-source-review"
        _ = try await model.editWording(theme, input: different)
        #expect(await transport.requests.count == 2)
    }

    @Test func invalidProposalIndexDoesNotInventEvidenceOrSilentlyUseAnotherProposal() async throws {
        var model = LocalChapterTitleModel(model: "qwen3-vl:2b-instruct", mode: .fast)
        model.answerTransport = { request in
            let bytes = try JSONSerialization.data(withJSONObject: ["done": true, "done_reason": "stop",
                "message": ["content": #"{"titles":[{"text":"Встреча","proposalIndex":99}]}"#]])
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: ChapterTitleFailure.self) { try await model.editWording(theme, input: input()) }
    }

    @Test func emptyPositiveCertificateRequiresARepairedAnswerAndDoesNotBecomeSuccessfulCache() async throws {
        actor Transport {
            var calls = 0
            func send(_ request: URLRequest) throws -> (Data, URLResponse) {
                calls += 1
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let answer: [String: Any] = ["accepted": true, "coversWholePart": true, "evidenceIDs": ["e0"],
                    "unsupportedClaims": [String](), "reasons": calls == 1 ? [] : ["Both people visibly hold tablets in the selected observations"]]
                let content = String(decoding: try JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
                let bytes = try JSONSerialization.data(withJSONObject: ["model": body["model"]!, "done": true,
                    "done_reason": "stop", "message": ["content": content]])
                return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = Transport()
        var model = LocalChapterTitleModel(model: "qwen3-vl:8b-instruct", digest: "same-8b-weights", mode: .quality, responseCacheURL: root)
        model.answerTransport = { try await transport.send($0) }
        let verdict = try await model.verify(theme.titles[1], input: input())
        #expect(verdict.accepted && !verdict.reasons.isEmpty)
        #expect(await transport.calls == 2)
        _ = try await model.verify(theme.titles[1], input: input())
        #expect(await transport.calls == 2)
    }
}
