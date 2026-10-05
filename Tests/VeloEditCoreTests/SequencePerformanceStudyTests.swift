import Foundation
import Testing
@testable import VeloEditCore

@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_SEQUENCE_STUDY"] != nil))
func measureRealSequenceSearchAgainstOriginalAlgorithm() throws {
    let environment = ProcessInfo.processInfo.environment
    let source = try #require(environment["VELOEDIT_SEQUENCE_STUDY"])
    let destination = try #require(environment["VELOEDIT_SEQUENCE_STUDY_OUTPUT"])
    let manifest = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: URL(fileURLWithPath: source)))
    let context = EditorialAnalysisContext(analyses: manifest.analyses)
    let hypothesis = NarrativeHypothesis(pattern: .minimalMontage, evidenceCoverage: 1, reasons: ["fixed real-input comparison"])
    struct Measurement: Encodable { var pair: Int; var implementation: String; var seconds: Double; var candidateIDs: [UUID]; var durations: [Double] }
    var measurements: [Measurement] = []
    let expected = BaselineEditorialSequenceSearch().sequence(hypothesis: hypothesis, units: context.units,
        families: context.families, target: 120, pacing: 0.5)
    for pair in 1...5 {
        for before in pair % 2 == 1 ? [true, false] : [false, true] {
            let started = ProcessInfo.processInfo.systemUptime
            let result = before
                ? BaselineEditorialSequenceSearch().sequence(hypothesis: hypothesis, units: context.units, families: context.families, target: 120, pacing: 0.5)
                : EditorialSequenceSearch().sequence(hypothesis: hypothesis, units: context.units, families: context.families, target: 120, pacing: 0.5)
            let seconds = ProcessInfo.processInfo.systemUptime - started
            #expect(result.units == expected.units)
            #expect(result.beatPlan == expected.beatPlan)
            #expect(result.discarded == expected.discarded)
            measurements.append(Measurement(pair: pair, implementation: before ? "before" : "after", seconds: seconds,
                candidateIDs: result.units.map(\.id), durations: result.beatPlan.beats.map(\.allocatedDuration)))
        }
    }
    try JSONEncoder().encode(measurements).write(to: URL(fileURLWithPath: destination), options: .atomic)
}
