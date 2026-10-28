import Foundation
import Testing
@testable import VeloEditCore

struct LocalAIBackendProgressTests {
    private func append(_ text: String, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: Data(text.utf8))
    }

    @Test func onlyNewAdvancingWorkFromOneTaskCounts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("slot print_timing: id 0 | task 0 | prompt processing, n_tokens = 500, progress = 0.50\n".utf8).write(to: url)
        let reader = try #require(LocalAIBackendProgress(url: url))
        #expect(reader.next() == nil)
        try append("[GIN] GET /api/ps\nwaiting for llama-server to become available\n", to: url)
        #expect(reader.next() == nil)
        try append("srv    load_model: loaded multimodal model, 'fixture'\n", to: url)
        #expect(reader.next()?.phase == "loading")
        try append("srv    load_model: loaded multimodal model, 'fixture'\n", to: url)
        #expect(reader.next() == nil)
        try append("slot print_timing: id 0 | task 8 | prompt processing, n_tokens = 100, progress = 0.10\n", to: url)
        #expect(reader.next()?.tokens == 100)
        try append("slot print_timing: id 0 | task 8 | prompt processing, n_tokens = 100, progress = 0.10\nslot print_timing: id 0 | task 9 | prompt processing, n_tokens = 900, progress = 0.90\n", to: url)
        #expect(reader.next() == nil)
        try append("slot print_timing: id 0 | task 8 | prompt processing, n_tokens = 200, progress = 0.20", to: url)
        #expect(reader.next() == nil)
        try append("\n", to: url)
        #expect(reader.next()?.tokens == 200)
        try append("common_init_: warming up the model\n", to: url)
        #expect(reader.next() == nil)
    }

    @Test func rotationAndBacklogCannotReplayProgress() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 32, count: 100).write(to: url)
        let reader = try #require(LocalAIBackendProgress(url: url))
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 0); try file.close()
        #expect(reader.next() == nil)
        try append(String(repeating: "srv    load_model: loaded multimodal model\n", count: 30_000), to: url)
        #expect(reader.next() == nil)
        #expect(reader.next() == nil)
    }
}
