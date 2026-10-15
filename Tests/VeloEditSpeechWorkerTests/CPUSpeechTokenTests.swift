import Foundation
import Testing
@testable import VeloEditSpeechWorker

struct CPUSpeechTokenTests {
    func token(_ bytes: [UInt8], id: Int, start: Float, end: Float) -> CPUSpeechToken {
        CPUSpeechToken(id: id, bytes: Data(bytes), start: start, end: end, probability: 0.9, logProbability: -0.1)
    }

    @Test func joinsSplitCyrillicBytesAndKeepsMeasuredTimes() {
        let prefix = Array(" При".utf8)
        let suffix = Array("вет".utf8)
        let tokens = [
            token(Array(prefix.dropLast()), id: 1, start: 0.2, end: 0.3),
            token([prefix.last!] + suffix, id: 2, start: 0.3, end: 0.7),
            token(Array(",".utf8), id: 3, start: 0.7, end: 0.7),
            token(Array(" мир!".utf8), id: 4, start: 0.8, end: 1.2)
        ]
        let words = CPUSpeechToken.words(from: tokens)
        #expect(words.map(\.word) == ["Привет,", "мир!"])
        #expect(words.map(\.tokens) == [[1, 2, 3], [4]])
        #expect(words[0].start == 0.2 && words[0].end == 0.7)
        #expect(words[1].start == 0.8 && words[1].end == 1.2)
    }

    @Test func doesNotInventTimesForUnalignedTokens() {
        let words = CPUSpeechToken.words(from: [token(Array(" слово".utf8), id: 1, start: -0.01, end: -0.01)])
        #expect(words.count == 1)
        #expect(words[0].start == -0.01 && words[0].end == -0.01)
        // The worker's existing acceptance filter will reject this word and
        // preserve the timed phrase/source audio instead of publishing it.
        #expect(CPUSpeechToken.words(from: []).isEmpty)
    }

    @Test func separatesNewlineAndIgnoresWhitespaceOnlyTokens() {
        let words = CPUSpeechToken.words(from: [
            token([32], id: 1, start: 0, end: 0),
            token(Array("\nHello".utf8), id: 2, start: 1, end: 2),
            token(Array(" world".utf8), id: 3, start: 2.1, end: 3)
        ])
        #expect(words.map(\.word) == ["Hello", "world"])
    }

    @Test func prefersDTWTransitionsToLeadingSilenceHeuristic() {
        var first = token(Array(" Hello".utf8), id: 1, start: 0, end: 0.6)
        first.alignmentTime = 1.1
        var second = token(Array(" world".utf8), id: 2, start: 0.6, end: 2.2)
        second.alignmentTime = 1.5
        var punctuation = token(Array("!".utf8), id: 3, start: 2.2, end: 2.2)
        punctuation.alignmentTime = 2.0
        let words = CPUSpeechToken.words(from: [first, second, punctuation])
        #expect(words[0].start == 1.1 && words[0].end == 1.5)
        #expect(words[1].start == 1.5 && words[1].end == 2.0)
        #expect(words.map(\.word) == ["Hello", "world!"])
    }
}
