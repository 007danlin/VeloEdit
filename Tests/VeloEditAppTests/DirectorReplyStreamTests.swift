import Foundation
import Testing
@testable import VeloEdit

private func chunk(_ text: String, done: Bool = false) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: ["message": ["content": text], "done": done]), as: UTF8.self)
}

@Test func streamedReplyNeverPublishesAnIncompletePlan() throws {
    var stream = DirectorReplyStream()
    #expect(try stream.append(chunk(#"{"reply":"Применю \"У"#)) == nil)
    #expect(try stream.append(chunk(#"тро\"","commands":["#)) == "Применю \"Утро\"")
    #expect(throws: (any Error).self) { try stream.completedContent() }
    #expect(try stream.append(chunk(#"],"normalizedBrief":""}"#, done: true)) == nil)
    let data = Data(try stream.completedContent().utf8)
    #expect(try JSONSerialization.jsonObject(with: data) is [String: Any])
}

@Test func truncatedOrFailedModelStreamsCannotBecomeCommands() throws {
    var stream = DirectorReplyStream()
    #expect(throws: (any Error).self) { try stream.append(#"{"done":true,"done_reason":"length","message":{"content":"{}"}}"#) }
    #expect(throws: (any Error).self) { try stream.completedContent() }
    #expect(throws: (any Error).self) { try stream.append(#"{"error":"model unloaded"}"#) }
}

@MainActor @Test func invalidActionRejectsEntireCompoundPlan() throws {
    let valid = #"{"action":"set_music_volume","target":"all","value":"0.2","secondaryTarget":""}"#
    let invalid = #"{"action":"unknown","target":"selected","value":"","secondaryTarget":""}"#
    let plan = "{\"reply\":\"Применю\",\"normalizedBrief\":\"\",\"commands\":[\(valid),\(invalid)]}"
    #expect(throws: (any Error).self) {
        try LocalDirectorAgent.decodeReply(plan, userMessage: "Составная команда", runtimeLabel: "test", allowsFootageReplacement: false)
    }
    #expect(throws: (any Error).self) {
        try LocalDirectorAgent.decodeReply(#"{"reply":"Применю","commands":"invalid"}"#, userMessage: "Команда", runtimeLabel: "test", allowsFootageReplacement: false)
    }
}
