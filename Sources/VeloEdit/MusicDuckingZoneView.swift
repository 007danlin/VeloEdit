import SwiftUI
import VeloEditCore

/// A speech object beneath the music, with an independent selection
/// so Delete cannot accidentally remove the underlying soundtrack.
struct MusicDuckingZoneView: View {
    let region: MusicDuckingRegion
    let width: CGFloat
    let selected: Bool
    let select: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .center) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.teal.opacity(selected ? 0.9 : 0.65))
            if width >= 30 {
                HStack(spacing: 3) {
                    Image(systemName: "waveform.badge.mic")
                    if width >= 55 { Text("Речь").lineLimit(1) }
                    Spacer(minLength: 0)
                    if (selected || hovering) && width >= 55 {
                        Button(action: remove) { Image(systemName: "xmark").frame(width: 19, height: 20) }
                            .buttonStyle(.plain)
                            .help("Убрать это приглушение (Delete)")
                            .accessibilityLabel("Убрать приглушение под речь")
                    }
                }
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 4)
            }
        }
        .foregroundStyle(.white)
        .frame(width: max(2, width), height: 23)
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Color.yellow : .white.opacity(0.35), lineWidth: selected ? 2 : 0.5).allowsHitTesting(false) }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        // These objects follow the detected source speech; dragging selects.
        .gesture(DragGesture(minimumDistance: 4).onChanged { _ in select() })
        .onHover { hovering = $0 }
        .contextMenu { Button("Убрать это приглушение", systemImage: "speaker.wave.2", action: remove) }
        .help("Музыка тише под речь · \(clock(region.timelineRange.lowerBound))–\(clock(region.timelineRange.upperBound)). Выделите и нажмите Delete, чтобы убрать.")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Приглушение под речь, \(clock(region.timelineRange.lowerBound))–\(clock(region.timelineRange.upperBound))")
        .accessibilityIdentifier("music-ducking-\(region.id)")
        .accessibilityAction(named: Text("Выбрать"), select)
        .accessibilityAction(named: Text("Убрать приглушение"), remove)
    }

    private func clock(_ value: Double) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
