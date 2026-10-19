import AVFoundation

/// An independent composition for template thumbnails. Sharing or mutating the
/// live instruction objects would remove titles from playback and export too.
public enum TitleLibraryPreview {
    public static func videoComposition(from source: AVVideoComposition?) -> AVVideoComposition? {
        guard let copy = source?.mutableCopy() as? AVMutableVideoComposition else { return nil }
        copy.animationTool = nil
        copy.instructions = copy.instructions.map { instruction in
            guard let value = instruction as? VeloVideoInstruction else { return instruction }
            return VeloVideoInstruction(timeRange: value.timeRange,
                layers: value.layers.filter { $0.item.kind != .title },
                telemetryLayers: value.telemetryLayers, effects: value.effects, titles: [],
                transition: value.transition, transitionItem: value.transitionItem,
                renderSize: value.renderSize, colorProfile: value.colorProfile,
                endingFade: value.endingFade, timelineTimeRange: value.timelineTimeRange)
        }
        return copy
    }
}
