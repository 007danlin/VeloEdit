import Testing
@testable import VeloEdit

@MainActor struct BrushSemanticReplyTests {
    @Test func onlyTypedReplacementInsideBrushChangesFootage() throws {
        let json = #"{"reply":"Подберу вид на реку","normalizedBrief":"","commands":[{"action":"replace_footage","target":"selected","value":"","secondaryTarget":""}]}"#
        let reply = try LocalDirectorAgent.decodeReply(json, userMessage: "Лучше вид на реку вместо текущего", runtimeLabel: "test", allowsFootageReplacement: true)
        #expect(reply.replacesSelectedFootage)
        #expect(reply.commands.isEmpty)
        #expect(try !LocalDirectorAgent.decodeReply(json, userMessage: "Совет", runtimeLabel: "test", allowsFootageReplacement: false).replacesSelectedFootage)
        let global = json.replacingOccurrences(of: "selected", with: "all")
        #expect(try !LocalDirectorAgent.decodeReply(global, userMessage: "Замена", runtimeLabel: "test", allowsFootageReplacement: true).replacesSelectedFootage)
        let prose = #"{"reply":"Заменю фрагмент","normalizedBrief":"","commands":[]}"#
        #expect(try !LocalDirectorAgent.decodeReply(prose, userMessage: "Замена", runtimeLabel: "test", allowsFootageReplacement: true).replacesSelectedFootage)
    }
}
