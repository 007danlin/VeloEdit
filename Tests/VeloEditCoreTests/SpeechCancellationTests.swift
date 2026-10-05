import Foundation
import Speech
import Testing
@testable import VeloEditCore

@Suite struct SpeechCancellationTests {
    @Test func cancellationBeforeCallbackInstallationResumesExactlyOnce() async {
        let state = SpeechContinuationState()
        state.complete(.failure(CancellationError()))
        state.complete(.failure(URLError(.timedOut)))
        do {
            let _: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { continuation in
                #expect(!state.install(continuation))
            }
            Issue.record("Cancelled speech completed successfully")
        } catch { #expect(error is CancellationError) }
    }

    @Test func cancellationAfterCallbackInstallationDoesNotWaitForSpeechServer() async {
        let state = SpeechContinuationState()
        do {
            let _: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { continuation in
                #expect(state.install(continuation))
                state.complete(.failure(CancellationError()))
                state.complete(.failure(URLError(.timedOut)))
            }
            Issue.record("Cancelled speech completed successfully")
        } catch { #expect(error is CancellationError) }
    }
}
