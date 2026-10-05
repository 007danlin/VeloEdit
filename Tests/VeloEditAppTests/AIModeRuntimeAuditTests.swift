import Foundation
import Testing
import VeloEditCore
@testable import VeloEdit

/// Opt-in integration audit: exercises the actual director client with an
/// already installed local model. No project is edited and no model is pulled.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_AI_AUDIT_OUTPUT"] != nil))
func actualDirectorModelAndExactCommandHaveDistinctExecutionPaths() async throws {
    let output = try #require(ProcessInfo.processInfo.environment["VELOEDIT_AI_AUDIT_OUTPUT"])
    let availability = await LocalAIModelManager.shared.availability(model: "qwen3:4b-instruct")
    #expect(availability.installed)
    guard availability.installed else { return }
    let context = DirectorContext(assetCount: 3, videoCount: 3, photoCount: 0, analyzedCount: 3,
        candidateCount: 12, currentTimelineItemCount: 21, localMusicTrackCount: 12,
        targetDuration: 120, preset: .story, currentOperation: "Монтаж готов",
        selectedItemSummary: "Выбран второй клип", playheadTime: 10)
    struct Result: Encodable {
        var request: String
        var runtime: String
        var response: String
        var commandCount: Int
        var seconds: Double
        var elapsedIncludingSleepSeconds: Double
        var firstReplySeconds: Double?
        var installedModelDigest: String?
    }
    var results: [Result] = []
    let agent = LocalDirectorAgent()
    let requests: [(String, DirectorRequestMode)] = [
        ("громкость музыки 20%", .edit),
        ("Предложи короткое название для фильма о велопрогулке по лесу. Ничего не меняй.", .advisory)
    ]
    for (prompt, mode) in requests {
        let start = ProcessInfo.processInfo.systemUptime
        let startedAt = Date()
        var firstReply: Double?
        let reply = await PerformanceTrace.measure(name: "director-ai-audit") {
            await agent.respond(to: prompt, context: context, mode: mode, recordInHistory: false) { _ in
                if firstReply == nil { firstReply = ProcessInfo.processInfo.systemUptime - start }
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let elapsedIncludingSleep = Date().timeIntervalSince(startedAt)
        let digest = await LocalAIModelManager.shared.installedModelDigest(model: "qwen3:4b-instruct")
        results.append(Result(request: prompt, runtime: reply.runtimeLabel, response: reply.text,
            commandCount: reply.commands.count, seconds: elapsed,
            elapsedIncludingSleepSeconds: elapsedIncludingSleep,
            firstReplySeconds: firstReply, installedModelDigest: digest))
        try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: output), options: .atomic)
        if mode == .edit {
            #expect(reply.commands == [.setMusicVolume(0.2)])
            #expect(reply.runtimeLabel == "Точная монтажная команда")
        } else {
            #expect(reply.runtimeLabel == "Qwen3 4B Instruct · локальная нейросеть")
            #expect(!reply.text.isEmpty)
            #expect(reply.text.range(of: #"«[^«»]{2,60}»"#, options: .regularExpression) != nil,
                    "Совет должен содержать запрошенное название, а не только подтверждение отсутствия изменений")
            #expect(reply.commands.isEmpty)
            #expect(firstReply != nil)
        }
    }
}
