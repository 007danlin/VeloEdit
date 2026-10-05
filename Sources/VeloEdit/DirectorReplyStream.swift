import Foundation
import VeloEditCore

/// Presentation-only text from the reply field. Commands are inaccessible until
/// the complete envelope has finished and the regular plan decoder accepts it.
struct DirectorReplyStream {
    private(set) var content = ""
    private(set) var finished = false
    private(set) var lastReply = ""

    mutating func append(_ line: String) throws -> String? {
        struct Chunk: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let done: Bool?
            let done_reason: String?
            let error: String?
            let load_duration: Double?
            let prompt_eval_duration: Double?
            let eval_duration: Double?
            let prompt_eval_count: Double?
            let eval_count: Double?
        }
        guard !finished else { throw URLError(.cannotParseResponse) }
        let chunk = try JSONDecoder().decode(Chunk.self, from: Data(line.utf8))
        if chunk.error != nil { throw URLError(.badServerResponse) }
        if chunk.done_reason == "length" { throw URLError(.cannotParseResponse) }
        content += chunk.message?.content ?? ""
        finished = chunk.done == true
        if finished {
            var values: [String: Double] = [:]
            if let value = chunk.load_duration { values["loadSeconds"] = value / 1_000_000_000 }
            if let value = chunk.prompt_eval_duration { values["promptSeconds"] = value / 1_000_000_000 }
            if let value = chunk.eval_duration { values["generationSeconds"] = value / 1_000_000_000 }
            if let value = chunk.prompt_eval_count { values["promptTokens"] = value }
            if let value = chunk.eval_count { values["generatedTokens"] = value }
            PerformanceTrace.current?.event("director.runtime", values: values)
        }
        // Parse just a complete JSON string value, with correct escape handling.
        // An unfinished string remains invisible; unfinished commands never run.
        guard let range = content.range(of: #""reply"\s*:\s*("(?:[^"\\]|\\.)*")"#, options: .regularExpression),
              let colon = content[range].firstIndex(of: ":") else { return nil }
        let raw = String(content[content.index(after: colon)..<range.upperBound]).trimmingCharacters(in: .whitespaces)
        guard let reply = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)), reply != lastReply else { return nil }
        lastReply = reply
        return reply
    }

    func completedContent() throws -> String {
        guard finished else { throw URLError(.networkConnectionLost) }
        return content
    }
}
