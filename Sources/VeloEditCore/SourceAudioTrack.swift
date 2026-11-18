import AVFoundation

extension AVAsset {
    /// Camera movies can list a disabled spatial alternate before the enabled
    /// stereo program. Use the same program for editing, processing and export.
    func sourceAudioTrack() async throws -> AVAssetTrack? {
        let tracks = try await loadTracks(withMediaType: .audio)
        if tracks.count > 1 {
            for track in tracks where try await track.load(.isEnabled) {
                return track
            }
        }
        return tracks.first
    }
}
