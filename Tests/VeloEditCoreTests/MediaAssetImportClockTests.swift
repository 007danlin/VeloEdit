import Foundation
import Testing
@testable import VeloEditCore

@Suite struct MediaAssetImportClockTests {
    private func asset(id: String, time: Double) -> MediaAsset {
        MediaAsset(id: UUID(uuidString: id)!, originalURL: URL(fileURLWithPath: "/nonexistent/undated.mov"),
            kind: .video, byteSize: 1, contentHash: id,
            metadata: MediaMetadata(duration: 5, width: 1920, height: 1080, frameRate: 30),
            importedAt: Date(timeIntervalSinceReferenceDate: time))
    }

    @Test func savedImportClockPreservesUndatedSourceOrder() throws {
        // Import completes within one second, in the opposite order to UUIDs.
        // Losing fractional seconds used to reverse these shots on reopening,
        // invalidating titles, rendered checks and otherwise unchanged edits.
        let earlier = asset(id: "22222222-2222-2222-2222-222222222222", time: 800_000_000.125)
        let later = asset(id: "11111111-1111-1111-1111-111111111111", time: 800_000_000.875)
        let assets = [later, earlier]
        let before = SourceTimelineAnalyzer().analyze(assets: assets, analyses: [])
        #expect(before.orderedAssetIDs == [earlier.id, later.id])
        let restored = try JSONDecoder.veloEdit.decode([MediaAsset].self, from: JSONEncoder.veloEdit.encode(assets))
        #expect(restored.map(\.importedAt) == assets.map(\.importedAt))
        #expect(SourceTimelineAnalyzer().analyze(assets: restored, analyses: []).orderedAssetIDs == before.orderedAssetIDs)
    }

    @Test(arguments: [false, true]) func allAssetFieldsAndUpdatedClockRoundTrip(projectFormat: Bool) throws {
        var value = asset(id: "33333333-3333-3333-3333-333333333333", time: 800_000_000.125)
        value.importedAt = value.importedAt.addingTimeInterval(0.000_013)
        value.conversionSourceURL = URL(fileURLWithPath: "/nonexistent/original.avi")
        value.importSourceURL = URL(fileURLWithPath: "/nonexistent/import.mov")
        value.bookmarkData = Data([1, 2, 3])
        value.fullContentHash = "full-file-hash"
        value.favorite = true
        value.excluded = true
        value.missing = true
        let encoder = projectFormat ? JSONEncoder.veloEdit : JSONEncoder()
        let decoder = projectFormat ? JSONDecoder.veloEdit : JSONDecoder()
        #expect(try decoder.decode(MediaAsset.self, from: encoder.encode(value)) == value)
    }

    @Test func legacyAssetsWithoutExactClockRemainReadable() throws {
        let value = asset(id: "44444444-4444-4444-4444-444444444444", time: 800_000_000)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder.veloEdit.encode(value)) as? [String: Any])
        json.removeValue(forKey: "importedAtReferenceTime")
        let restored = try JSONDecoder.veloEdit.decode(MediaAsset.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored == value)
    }
}
