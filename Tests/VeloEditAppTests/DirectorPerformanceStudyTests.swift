import Foundation
import Testing
import VeloEditCore
@testable import VeloEdit

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_DIRECTOR_STUDY_OUTPUT"] != nil))
func measureExactDirectorCommandLatencyAndAccuracy() async throws {
    let output = try #require(ProcessInfo.processInfo.environment["VELOEDIT_DIRECTOR_STUDY_OUTPUT"])
    let context = DirectorContext(assetCount: 3, videoCount: 3, photoCount: 0, analyzedCount: 3,
        candidateCount: 85, currentTimelineItemCount: 21, localMusicTrackCount: 12,
        targetDuration: 120, preset: .story, currentOperation: "Монтаж готов",
        selectedItemSummary: "Выбран второй клип", playheadTime: 10)
    struct Measurement: Encodable { var index: Int; var request: String; var seconds: Double; var runtime: String; var correct: Bool }
    var rows: [Measurement] = []
    let agent = LocalDirectorAgent()
    for index in 0..<30 {
        let percent = 20 + index % 2
        let prompt = "громкость музыки \(percent)%"
        let started = ProcessInfo.processInfo.systemUptime
        let reply = await agent.respond(to: prompt, context: context, mode: .edit, recordInHistory: false)
        let seconds = ProcessInfo.processInfo.systemUptime - started
        let correct = reply.commands == [.setMusicVolume(Double(percent) / 100)]
        #expect(correct)
        rows.append(Measurement(index: index + 1, request: prompt, seconds: seconds, runtime: reply.runtimeLabel, correct: correct))
        try JSONEncoder().encode(rows).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
