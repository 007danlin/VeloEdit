import Foundation
import VeloEditCore

enum TimelineGroupMove {
    static func apply(to timeline: inout Timeline, selection: Set<TimelineSelectionKey>,
                      anchor: TimelineSelectionKey, delta requested: Double,
                      moveSoundtrack: (inout Timeline, Double) -> Bool = { _, _ in false }) -> Bool {
        guard requested.isFinite, requested != 0 else { return false }
        let original = timeline
        let connected = original.items.filter { $0.overlay != nil && selection.contains(.item($0.id)) }
        let titles = original.effectiveTitleItems.filter { selection.contains(.title($0.id)) }
        let effects = original.effectiveEffects.filter { selection.contains(.effect($0.id)) }
        let audio = original.effectiveAudioClips.filter { selection.contains(.audio($0.id)) }
        let telemetry = original.effectiveTelemetryItems.filter { selection.contains(.telemetry($0.id)) }
        var lower = -Double.infinity
        var upper = Double.infinity
        func constrain(_ start: Double, _ duration: Double) {
            lower = max(lower, -start)
            upper = min(upper, max(0, original.duration - duration - start))
        }
        for item in connected { constrain(item.timelineStart, item.timelineDuration) }
        for item in titles { constrain(item.startTime, item.duration) }
        for item in effects { constrain(item.startTime, item.duration) }
        for item in audio { constrain(item.timelineStart, item.timelineDuration) }
        for item in telemetry { constrain(item.timelineStart, item.timelineDuration) }
        if selection.contains(.soundtrack) { constrain(0, 0.05) }
        var delta = min(upper, max(lower, requested))
        let primary = original.items.filter { $0.overlay == nil }
        let incoming = Set(original.effectiveTransitionItems.filter { selection.contains(.transition($0.id)) }.map(\.incomingClipID))
        let indices = primary.indices.filter { selection.contains(.item(primary[$0].id)) || incoming.contains(primary[$0].id) }
        if let first = indices.first, let last = indices.last {
            let reference = indices.first { anchor == .item(primary[$0].id) } ?? first
            let remaining = primary.indices.filter { !indices.contains($0) }
            let before = indices.prefix { $0 < reference }.count
            // A magnetic track has discrete destinations. Keep the spacing in clip
            // slots and choose the legal destination closest to the pointer.
            var prefix = [0.0]
            for index in remaining { prefix.append(prefix.last! + primary[index].timelineDuration) }
            let base = reference - before
            var shift = 0
            var distance = abs(delta)
            for offset in (-first)...(primary.count - 1 - last) {
                let movement = prefix[base + offset] - prefix[base]
                let error = abs(movement - delta)
                if movement >= lower, movement <= upper, error < distance {
                    shift = offset
                    distance = error
                }
            }
            guard shift != 0 else { return false }
            delta = prefix[base + shift] - prefix[base]
            var order = remaining.map { primary[$0].id }
            for index in indices { order.insert(primary[index].id, at: index + shift) }
            guard TimelineMutationEngine.reorderPrimaryItems(in: &timeline, order: order) else { return false }
        }
        guard delta != 0 else { return false }
        // Read the original positions because magnetic reordering also retimes attachments.
        for item in connected {
            TimelineMutationEngine.moveConnectedItem(in: &timeline, id: item.id, toTimelineStart: item.timelineStart + delta)
        }
        for item in titles {
            TimelineMutationEngine.updateTitle(in: &timeline, id: item.id) { $0.startTime = item.startTime + delta }
        }
        for item in effects {
            TimelineMutationEngine.updateEffect(in: &timeline, id: item.id) { $0.startTime = item.startTime + delta }
        }
        for item in audio {
            TimelineMutationEngine.updateAudioClip(in: &timeline, id: item.id) { $0.timelineStart = item.timelineStart + delta }
        }
        for item in telemetry {
            TimelineMutationEngine.updateTelemetry(in: &timeline, id: item.id) { $0.timelineStart = item.timelineStart + delta }
        }
        if selection.contains(.soundtrack), !moveSoundtrack(&timeline, delta) {
            timeline = original
            return false
        }
        return timeline != original
    }
}
