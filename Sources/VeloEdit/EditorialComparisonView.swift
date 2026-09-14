import SwiftUI
import AVKit
import VeloEditCore

@MainActor final class EditorialComparisonSession: ObservableObject, Identifiable {
    struct Option: Identifiable {
        let id = UUID()
        let title: String
        let timeline: Timeline
        let playback: TimelinePlayback
        let playerItem: AVPlayerItem
        let thumbnail: NSImage?
    }
    let id = UUID()
    let before: Timeline
    let title: String
    let detail: String
    let focusTime: Double
    @Published var options: [Option] = []
    @Published var selectedIndex = 0
    @Published var preparing = true
    @Published var message: String?
    let player = AVPlayer()
    var task: Task<Void, Never>?
    private var selectionGeneration = 0

    init(before: Timeline, title: String, detail: String, focusTime: Double) {
        self.before = before; self.title = title; self.detail = detail; self.focusTime = focusTime
    }

    func append(title: String, timeline: Timeline, playback: TimelinePlayback) {
        let item = AVPlayerItem(asset: playback.composition)
        item.videoComposition = playback.videoComposition; item.audioMix = playback.audioMix
        item.preferredForwardBufferDuration = 2
        let generator = AVAssetImageGenerator(asset: playback.composition)
        generator.videoComposition = playback.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 220, height: 124)
        let frame = try? generator.copyCGImage(at: CMTime(seconds: min(focusTime, max(0, playback.duration - 0.1)), preferredTimescale: 600), actualTime: nil)
        options.append(.init(title: title, timeline: timeline, playback: playback, playerItem: item,
            thumbnail: frame.map { NSImage(cgImage: $0, size: .zero) }))
        if options.count == 1 { select(0, at: focusTime, play: false) }
    }

    func select(_ index: Int, at requested: Double? = nil, play: Bool = true) {
        guard options.indices.contains(index) else { return }
        let time = requested ?? player.currentTime().seconds
        selectionGeneration += 1
        let generation = selectionGeneration
        selectedIndex = index
        player.pause()
        let option = options[index]
        player.replaceCurrentItem(with: option.playerItem)
        let position = min(max(0, time.isFinite ? time : focusTime), max(0, option.playback.duration - 0.05))
        option.playerItem.forwardPlaybackEndTime = CMTime(seconds: min(option.playback.duration, position + 16), preferredTimescale: 600)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] ready in
            Task { @MainActor in
                guard let self, self.selectionGeneration == generation, ready, play else { return }
                self.player.play()
            }
        }
    }

    func close() { task?.cancel(); task = nil; selectionGeneration += 1; player.pause(); player.replaceCurrentItem(with: nil) }
}

struct EditorialComparisonView: View {
    @ObservedObject var session: EditorialComparisonSession
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(session.title).font(.title2.bold())
            Text(session.detail).foregroundStyle(.secondary)
            VideoPlayer(player: session.player).frame(height: 300)
            HStack {
                Button("Начало") { session.select(session.selectedIndex, at: 0) }
                Button("Выразительный момент") { session.select(session.selectedIndex, at: session.focusTime) }
                Button("Финал") { session.select(session.selectedIndex, at: max(0, (session.options.first?.playback.duration ?? 0) - 16)) }
                Spacer()
                if session.preparing { ProgressView().controlSize(.small); Text("Готовлю варианты…") }
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(session.options.enumerated()), id: \.element.id) { index, option in
                    Button { session.select(index) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let image = option.thumbnail { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: 74) }
                            Label(option.title, systemImage: session.selectedIndex == index ? "checkmark.circle.fill" : "play.circle")
                                .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(8)
                    }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                }
            }
            if let message = session.message { Text(message).foregroundStyle(.secondary) }
            HStack {
                Text("Просмотр не меняет проект").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Закрыть", role: .cancel) { model.closeEditorialComparison() }.keyboardShortcut(.cancelAction)
                Button("Применить") { model.applyEditorialComparison() }
                    .keyboardShortcut(.defaultAction).disabled(session.selectedIndex == 0 || session.preparing)
            }
        }.padding(24).frame(width: 780)
        .onDisappear { session.close() }
    }
}

struct EditorialStyleView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: Set<EditorialPreferenceAspect> = [.music]
    @State private var signals: [ExplicitEditorialPreference] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Запомнить этот стиль").font(.title2.bold())
            Text("Выберите, что учитывать в следующих фильмах с похожим настроением.").foregroundStyle(.secondary)
            ForEach(EditorialPreferenceAspect.allCases, id: \.self) { aspect in
                Toggle(aspect.title, isOn: Binding(get: { selected.contains(aspect) }, set: { enabled in
                    if enabled { selected.insert(aspect) } else { selected.remove(aspect) }
                }))
            }
            Button("Запомнить выбранное") {
                Task { await model.rememberEditorialStyle(selected); signals = await ExplicitEditorialPreferenceStore.shared.snapshot().signals }
            }.disabled(selected.isEmpty)
            Divider()
            Text("Сохранённые предпочтения").font(.headline)
            if signals.isEmpty { Text("Пока нет явных предпочтений").foregroundStyle(.secondary) }
            ScrollView {
                ForEach(signals) { signal in
                    HStack {
                        Text("\(signal.excluded ? "Исключён: " : "")\(signal.label) · \(signal.aspect.title)")
                        Spacer()
                        Button("Убрать") { Task {
                            do { try await ExplicitEditorialPreferenceStore.shared.remove(ids: [signal.id]); signals = await ExplicitEditorialPreferenceStore.shared.snapshot().signals }
                            catch { model.errorMessage = error.localizedDescription }
                        } }
                    }.padding(.vertical, 4)
                }
            }.frame(maxHeight: 190)
            HStack { Spacer(); Button("Готово") { model.showEditorialStyle = false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 520)
        .task { signals = await ExplicitEditorialPreferenceStore.shared.snapshot().signals }
    }
}
