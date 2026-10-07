import SwiftUI
import AppKit
import AVKit
import VeloEditCore

@MainActor
private final class TimelineHoverState: ObservableObject {
    @Published var time: Double?
    @Published var x: CGFloat?

    func update(time: Double, x: CGFloat) {
        self.time = time
        self.x = x
    }

    func clear() {
        time = nil
        x = nil
    }
}

/// The iMovie-like editing surface: one magnetic primary storyline, optional
/// connected media, a compact music lane, and a local AI brush.
struct MagneticTimelineView: View {
    @EnvironmentObject private var model: AppModel
    let timeline: Timeline
    let playbackClock: TimelinePlaybackClock
    private let layout: TimelineLayoutSnapshot

    init(timeline: Timeline, playbackClock: TimelinePlaybackClock) {
        self.timeline = timeline
        self.playbackClock = playbackClock
        self.layout = TimelineLayoutSnapshot(timeline: timeline)
    }

    @State private var zoom: Double = 18
    @State private var brushEnabled = false
    @State private var brushAnchor: Double?
    @State private var brushCurrent: Double?
    @State private var renderWindow = TimelineRenderWindow(visibleRect: CGRect(x: 0, y: 0, width: 1_200, height: 500))
    @State private var isDraggingSoundtrack = false
    @State private var draggedItemID: UUID?
    @State private var dragTranslation: CGFloat = 0
    @State private var dropPrimaryIndex: Int?
    @State private var libraryInsertion: TimelineInsertionPreview?
    @State private var canvasOrigin = CGPoint.zero
    @StateObject private var libraryDropSession = LibraryTimelineDropSession()
    @State private var draggedConnectedID: UUID?
    @State private var connectedDragTranslation: CGFloat = 0
    @State private var draggedAudioID: UUID?
    @State private var audioDragTranslation: CGFloat = 0
    @State private var draggedTelemetryID: UUID?
    @State private var telemetryDragTranslation: CGFloat = 0
    @State private var draggedEffectID: UUID?
    @State private var effectDragTranslation: CGFloat = 0
    @State private var draggedTitleID: UUID?
    @State private var titleDragTranslation: CGFloat = 0
    @State private var soundtrackDragTranslation: CGFloat = 0
    @State private var trimPreview: TrimPreview?
    @State private var rangeTrimPreview: RangeTrimPreview?
    // This reference is observed only by the tiny hover overlay. Pointer motion
    // must not rebuild the full timeline hierarchy on every mouse event.
    @StateObject private var hoverState = TimelineHoverState()
    @GestureState private var magnification: CGFloat = 1

    private let clipSpacing: CGFloat = 8

    private typealias TrimEdge = TimelineTrimEdge

    private struct TrimPreview {
        let itemID: UUID
        let edge: TrimEdge
        let sourceStart: Double
        let timelineStart: Double
        let timelineDuration: Double

        var range: TimelineTrimRange { .init(start: timelineStart, duration: timelineDuration) }
    }

    private enum RangeTrimTarget: Equatable {
        case title(UUID), effect(UUID), audio(UUID), telemetry(UUID), soundtrack
    }

    private struct RangeTrimPreview {
        let target: RangeTrimTarget
        let range: TimelineTrimRange
    }

    private var pointsPerSecond: Double { min(64, max(6, zoom * Double(magnification))) }

    private func previewDuration(for item: TimelineItem) -> Double {
        trimPreview?.itemID == item.id ? trimPreview?.timelineDuration ?? item.timelineDuration : item.timelineDuration
    }

    private var primaryItems: [TimelineItem] { layout.primaryItems }
    private var connectedItems: [TimelineItem] { layout.connectedItems }
    private var audioClips: [TimelineAudioClip] { layout.audioClips }
    private var telemetryItems: [TimelineTelemetryItem] { layout.telemetryItems }
    private var effectItems: [EffectTimelineItem] { layout.effectItems }
    private var titleItems: [TitleTimelineItem] { layout.titleItems }
    private var effectBlocks: [EffectTimelineBlock] { layout.effectBlocks }
    private var connectedLaneAssignments: [UUID: Int] { layout.connectedLaneAssignments }
    private var audioLaneAssignments: [UUID: Int] { layout.audioLaneAssignments }
    private var telemetryLaneAssignments: [UUID: Int] { layout.telemetryLaneAssignments }
    private var effectLaneAssignments: [UUID: Int] { layout.effectLaneAssignments }
    private var titleLaneAssignments: [UUID: Int] { layout.titleLaneAssignments }
    private var connectedLaneCount: Int { layout.connectedLaneCount }
    private var audioLaneCount: Int { previewLaneCount(.audio, existing: layout.audioLaneCount) }
    private var telemetryLaneCount: Int { previewLaneCount(.telemetry, existing: layout.telemetryLaneCount) }
    private var effectLaneCount: Int { previewLaneCount(.effect, existing: layout.effectLaneCount) }
    private var titleLaneCount: Int { previewLaneCount(.title, existing: layout.titleLaneCount) }

    private func previewLaneCount(_ lane: TimelineInsertionPreview.Lane, existing: Int) -> Int {
        max(existing, libraryInsertion?.lane == lane ? (libraryInsertion?.laneIndex ?? 0) + 1 : 0)
    }

    private func primaryFrame(at index: Int, includingTrim: Bool = false) -> CGRect {
        let item = primaryItems[index]
        var x = CGFloat(item.timelineStart * pointsPerSecond) + CGFloat(index) * clipSpacing
        if includingTrim, let trimPreview, let trimmedIndex = layout.primaryIndices[trimPreview.itemID] {
            if index == trimmedIndex {
                return trimPreview.range.previewFrame(
                    from: .init(start: item.timelineStart, duration: item.timelineDuration),
                    frame: CGRect(x: x, y: 0, width: clipWidth(item), height: 76),
                    pointsPerSecond: pointsPerSecond
                )
            }
            if index > trimmedIndex, trimPreview.edge == .trailing {
                x += CGFloat(trimPreview.timelineDuration - primaryItems[trimmedIndex].timelineDuration) * pointsPerSecond
            }
        }
        return CGRect(x: x, y: 0, width: clipWidth(item, duration: includingTrim ? previewDuration(for: item) : nil), height: 76)
    }

    private var visiblePrimaryIndices: [Int] {
        primaryItems.indices.filter { index in
            let item = primaryItems[index]
            let frame = primaryFrame(at: index, includingTrim: true).offsetBy(dx: libraryOffset(at: index), dy: 0)
            return item.id == draggedItemID || item.id == trimPreview?.itemID || renderWindow.intersects(x: frame.minX, width: frame.width)
        }
    }
    private var visibleTitleItems: [TitleTimelineItem] {
        titleItems.filter { $0.id == draggedTitleID || rangeTrimPreview?.target == .title($0.id) || isRangeVisible(start: $0.startTime, duration: $0.duration) }
    }
    private var visibleEffectBlocks: [EffectTimelineBlock] {
        effectBlocks.filter { $0.id == draggedEffectID || rangeTrimPreview?.target == .effect($0.id) || isRangeVisible(start: $0.startTime, duration: $0.duration) }
    }
    private var visibleConnectedItems: [TimelineItem] {
        connectedItems.filter { $0.id == draggedConnectedID || trimPreview?.itemID == $0.id || isRangeVisible(start: $0.timelineStart, duration: $0.timelineDuration) }
    }
    private var visibleAudioClips: [TimelineAudioClip] {
        audioClips.filter { $0.id == draggedAudioID || rangeTrimPreview?.target == .audio($0.id) || isRangeVisible(start: $0.timelineStart, duration: $0.timelineDuration) }
    }
    private var visibleTelemetryItems: [TimelineTelemetryItem] {
        telemetryItems.filter { $0.id == draggedTelemetryID || rangeTrimPreview?.target == .telemetry($0.id) || isRangeVisible(start: $0.timelineStart, duration: $0.timelineDuration) }
    }
    private var visibleRulerTicks: ClosedRange<Int> {
        let lowerTime = timelineTime(at: max(0, renderWindow.range.lowerBound - 60)) ?? 0
        let upperTime = timelineTime(at: renderWindow.range.upperBound) ?? layout.geometry.duration
        let lower = max(0, min(rulerTickCount, Int(floor(lowerTime / rulerInterval))))
        let upper = max(lower, min(rulerTickCount, Int(ceil(upperTime / rulerInterval))))
        return lower...upper
    }

    private var brushedRange: ClosedRange<Double>? {
        guard let anchor = brushAnchor, let current = brushCurrent else { return nil }
        let lower = min(anchor, current)
        let upper = max(anchor, current)
        return lower...max(lower + 0.05, upper)
    }

    var body: some View {
        VStack(spacing: 0) {
            aiCommandBar
            Divider()
            editingToolbar
            Divider()
            timelineScroller
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: timeline.items.map(\.id)) { _, _ in
            brushAnchor = nil
            brushCurrent = nil
            trimPreview = nil
            rangeTrimPreview = nil
        }
        .onChange(of: brushEnabled) { _, enabled in
            trimPreview = nil
            rangeTrimPreview = nil
            if !enabled {
                brushAnchor = nil
                brushCurrent = nil
            }
        }
    }

    private var aiCommandBar: some View {
        VStack(spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: brushEnabled ? "paintbrush.pointed.fill" : "sparkles")
                    .foregroundStyle(brushEnabled ? Color.purple : Color.accentColor)
                    .frame(width: 20)
                TextField(
                    brushEnabled ? "Что изменить в выделенном моменте?" : "Что изменить?",
                    text: $model.feedback
                )
                .textFieldStyle(.plain)
                .font(.body)
                .onSubmit(applyAICommand)

                if let range = brushedRange, brushEnabled {
                    Text("\(clock(range.lowerBound))–\(clock(range.upperBound))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.purple.opacity(0.12), in: Capsule())
                }

                Button(action: applyAICommand) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 27, height: 27)
                        .background(canApplyAICommand ? Color.accentColor : Color.secondary.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canApplyAICommand)
                .help(brushEnabled && brushedRange != nil
                    ? "Изменить только выделенный диапазон"
                    : "Применить изменение ко всему монтажу")
            }
            .padding(.horizontal, 12)

            if brushEnabled {
                Text(brushedRange == nil
                     ? "Выделите диапазон кистью или отправьте запрос без выделения для всего монтажа"
                     : "AI изменит только подсвеченный диапазон; остальная часть фильма останется прежней")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 41)
            }

            if model.isWorking || model.queuedTimelineAIEditCount > 0 {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(model.queuedTimelineAIEditCount > 0
                         ? "ИИ выполняет правки по порядку · в очереди: \(model.queuedTimelineAIEditCount)"
                         : "ИИ применяет правку к монтажу…")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 41)
            }
        }
        .padding(.vertical, brushEnabled ? 7 : 10)
        .background(.regularMaterial)
    }

    private var canApplyAICommand: Bool {
        !model.feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func applyAICommand() {
        guard canApplyAICommand else { return }
        let instruction = model.feedback
        if brushEnabled, let range = brushedRange {
            model.submitTimelineAIEdit(instruction, range: range)
        } else {
            model.submitTimelineAIEdit(instruction)
        }
    }

    private var editingToolbar: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { brushEnabled.toggle() }
            } label: {
                Label("Волшебная кисть", systemImage: "paintbrush.pointed")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(brushEnabled ? .white : .primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(brushEnabled ? Color.purple : Color.clear, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Выделить локальный диапазон для AI")

            Divider().frame(height: 18)

            Button(action: model.undoTimelineEdit) { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndoTimelineEdit || model.isTimelineInteractionBlocked)
                .help("Отменить правку (⌘Z)")
            Button(action: model.redoTimelineEdit) { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedoTimelineEdit || model.isTimelineInteractionBlocked)
                .help("Повторить правку (⇧⌘Z)")

            Divider().frame(height: 18)

            Button(action: model.splitSelectedTimelineItem) { Image(systemName: "scissors") }
                .disabled(!model.canSplitTimelineSelectionAtPlayhead || model.isTimelineInteractionBlocked)
                .help("Разделить выбранный объект в позиции playhead")
            Button(action: model.deleteSelectedTimelineItem) { Image(systemName: "trash") }
                .disabled(!model.hasTimelineSelection || model.isTimelineInteractionBlocked)
                .help("Удалить выбранный объект")
            transitionMenu
            effectMenu

            Spacer(minLength: 10)

            if let item = model.selectedTimelineItem {
                Text(item.title ?? clock(item.timelineDuration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let clip = model.selectedTimelineAudioClip {
                Text(clip.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let effect = model.selectedEffectTimelineItem {
                Text(effect.effectType.localizedTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let title = model.selectedTitleTimelineItem {
                Text(title.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Label("Магнитная Timeline", systemImage: "magnet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
            Slider(value: $zoom, in: 6...64)
                .frame(width: 108)
                .help("Масштаб Timeline")
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private var transitionMenu: some View {
        Menu {
            Button("Без перехода") { model.setSelectedTransition(nil) }
            Divider()
            ForEach(TransitionStyle.allCases.filter { $0 != .cut }) { transition in
                Button(transition.localizedTitle) { model.setSelectedTransition(transition.rawValue) }
            }
        } label: {
            Image(systemName: "rectangle.2.swap")
        }
        .menuIndicator(.hidden)
        .disabled(model.selectedTimelineItem == nil || model.isTimelineInteractionBlocked)
        .help("Переход между клипами")
    }

    private var effectMenu: some View {
        Menu {
            ForEach(TimelineEffectCategory.allCases) { category in
                Menu(category.localizedTitle) {
                    ForEach(TimelineEffectType.allCases.filter { $0.category == category }) { effect in
                        Button(effect.localizedTitle) { model.addTimelineEffect(effect) }
                    }
                }
            }
        } label: {
            Image(systemName: "wand.and.rays")
        }
        .menuIndicator(.hidden)
        .disabled(timeline.items.isEmpty || model.isTimelineInteractionBlocked)
        .help("Добавить отдельный редактируемый эффект")
    }

    private var timelineScroller: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    ruler
                    if showsTitleTrack { titleTrack }
                    if !connectedItems.isEmpty { connectedTrack }
                    primaryTrack
                    if showsEffectTrack { effectsTrack }
                    if showsTelemetryTrack { telemetryTrack }
                    if showsAudioTrack { audioClipsTrack }
                    if timeline.music != nil { musicTrack }
                }

                if brushEnabled, let range = brushedRange {
                    Rectangle()
                        .fill(Color.purple.opacity(0.20))
                        .overlay(alignment: .leading) { Rectangle().fill(Color.purple).frame(width: 2) }
                        .overlay(alignment: .trailing) { Rectangle().fill(Color.purple).frame(width: 2) }
                        .frame(
                            width: max(2, xPosition(for: range.upperBound) - xPosition(for: range.lowerBound)),
                            height: canvasHeight
                        )
                        .offset(x: xPosition(for: range.lowerBound))
                        .allowsHitTesting(false)
                        .zIndex(18)
                }

                TimelinePlayheadOverlay(
                    clock: playbackClock,
                    geometry: layout.geometry,
                    pointsPerSecond: pointsPerSecond,
                    clipSpacing: clipSpacing,
                    canvasHeight: canvasHeight
                )
                TimelineHoverOverlay(state: hoverState, timeline: timeline, canvasHeight: canvasHeight)
                libraryInsertionOverlay
            }
            .frame(width: totalTimelineWidth, height: canvasHeight, alignment: .topLeading)
            .coordinateSpace(name: "timelineCanvas")
            .environment(\.timelineRenderRange, renderWindow.range)
            .background(TimelineViewportReader(onOriginChange: { canvasOrigin = $0 }) { next in
                if renderWindow != next { renderWindow = next }
            })
            .contentShape(Rectangle())
            // Disable only the brush recognizer when it is off. `.none` also
            // suppresses the child gestures used to select and drag objects.
            .highPriorityGesture(canvasBrushGesture, including: brushEnabled ? .all : .subviews)
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named("timelineCanvas"))
                    .onEnded { value in
                        guard !brushEnabled, let time = timelineTime(at: value.location.x) else { return }
                        model.seekTimeline(to: snapped(time, includePlayhead: false))
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard libraryInsertion == nil, draggedItemID == nil, draggedConnectedID == nil, draggedAudioID == nil, draggedTelemetryID == nil,
                          draggedEffectID == nil, draggedTitleID == nil,
                          trimPreview == nil, rangeTrimPreview == nil,
                          let time = timelineTime(at: location.x) else { return }
                    hoverState.update(time: time, x: location.x)
                case .ended:
                    hoverState.clear()
                }
            }
            .simultaneousGesture(
                MagnificationGesture()
                    .updating($magnification) { value, state, _ in state = value }
                    .onEnded { value in zoom = min(64, max(6, zoom * Double(value))) }
            )
            .padding(.horizontal, 16)
            .padding(.top, 7)
            .padding(.bottom, 12)
        }
        .contentShape(Rectangle())
        // Keep the destination stable when preview lanes appear, and accept
        // drops in the unused viewport below/after a short timeline too.
        .onDrop(of: [LibraryDragSession.type], delegate: LibraryTimelineDropDelegate(
            isEnabled: !model.isTimelineInteractionBlocked,
            session: libraryDropSession,
            update: { raw, point in
                updateLibraryInsertion(raw, at: TimelineDropCoordinates(canvasOrigin: canvasOrigin).canvasPoint(from: point))
            },
            clear: { libraryInsertion = nil },
            perform: { raw, point in
                handleLibraryDrop([raw], at: TimelineDropCoordinates(canvasOrigin: canvasOrigin).canvasPoint(from: point))
            }
        ))
        .onDisappear { libraryInsertion = nil; libraryDropSession.reset() }
        .scrollIndicators(.visible)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.32))
    }

    private var showsTitleTrack: Bool { !titleItems.isEmpty || libraryInsertion?.lane == .title }
    private var showsEffectTrack: Bool { !effectItems.isEmpty || libraryInsertion?.lane == .effect }
    private var showsTelemetryTrack: Bool { !telemetryItems.isEmpty || libraryInsertion?.lane == .telemetry }
    private var showsAudioTrack: Bool { !audioClips.isEmpty || libraryInsertion?.lane == .audio }
    private var primaryTrackY: CGFloat {
        19 + (showsTitleTrack ? CGFloat(max(1, titleLaneCount) * 31 + 5) : 0) +
        (connectedItems.isEmpty ? 0 : CGFloat(connectedLaneCount * 31 + 5))
    }
    private var effectTrackY: CGFloat { primaryTrackY + 85 }
    private var telemetryTrackY: CGFloat { effectTrackY + (showsEffectTrack ? CGFloat(max(1, effectLaneCount) * 31 + 5) : 0) }
    private var audioTrackY: CGFloat { telemetryTrackY + (showsTelemetryTrack ? CGFloat(max(1, telemetryLaneCount) * 31 + 5) : 0) }
    private var canvasHeight: CGFloat {
        audioTrackY + (showsAudioTrack ? CGFloat(max(1, audioLaneCount) * 31 + 5) : 0) +
        (timeline.music == nil ? 0 : 32)
    }

    private var titleTrack: some View {
        ZStack(alignment: .leading) {
            ForEach(visibleTitleItems) { item in
                let selected = model.isTitleTimelineItemSelected(item.id)
                let frame = rangeTrimFrame(for: .title(item.id), start: item.startTime,
                    duration: item.duration)
                HStack(spacing: 6) {
                    Image(systemName: item.kind == .wordLevelCaptions ? "captions.bubble" : "textformat")
                    Text(item.text).lineLimit(1)
                }
                .font(.caption2.weight(.semibold))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.text)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(width: frame.width, height: 28, alignment: .leading)
                .background(Color.purple.opacity(item.enabled ? 0.84 : 0.38), in: RoundedRectangle(cornerRadius: 6))
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectTitleTimelineItem(item.id, modifiers: timelineSelectionModifiers)
                    model.openTimelineInspector()
                }
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named("timelineCanvas"))
                        .onChanged { value in
                            if draggedTitleID == nil {
                                draggedTitleID = item.id
                                model.selectTitleTimelineItem(item.id)
                            }
                            titleDragTranslation = value.translation.width
                        }
                        .onEnded { value in
                            let target = movedTime(from: item.startTime, translation: value.translation.width)
                            draggedTitleID = nil
                            titleDragTranslation = 0
                            model.moveTitleTimelineItem(item.id, to: target)
                        }
                )
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.yellow : .white.opacity(0.14), lineWidth: selected ? 2 : 1).allowsHitTesting(false) }
                .overlay(alignment: .leading) {
                    edgeTrimRegion(.leading, target: .title(item.id), start: item.startTime, duration: item.duration,
                        width: min(14, frame.width / 2)) { translation in trimTitle(item, edge: .leading, translation: translation) }
                }
                .overlay(alignment: .trailing) {
                    edgeTrimRegion(.trailing, target: .title(item.id), start: item.startTime, duration: item.duration,
                        width: min(14, frame.width / 2)) { translation in trimTitle(item, edge: .trailing, translation: translation) }
                }
                .offset(
                    x: frame.minX + (draggedTitleID == item.id ? titleDragTranslation : 0),
                    y: CGFloat(titleLaneAssignments[item.id] ?? 0) * 31
                )
                .contextMenu {
                    Button("Удалить", systemImage: "trash", role: .destructive) {
                        model.selectTitleTimelineItem(item.id)
                        model.deleteSelectedTimelineObject()
                    }
                }
            }
        }
        .frame(width: totalTimelineWidth, height: CGFloat(titleLaneCount * 31), alignment: .topLeading)
    }

    private var effectsTrack: some View {
        ZStack(alignment: .leading) {
            ForEach(visibleEffectBlocks) { block in
                let item = block.primary
                let selected = block.itemIDs.allSatisfy(model.isEffectTimelineItemSelected)
                let frame = rangeTrimFrame(for: .effect(block.id), start: block.startTime,
                    duration: block.duration)
                HStack(spacing: 6) {
                    Image(systemName: block.presetID == nil ? "wand.and.rays" : "square.stack.3d.up.fill")
                    Text(block.title).lineLimit(1)
                    if block.hasKeyframes { Image(systemName: "diamond.fill").font(.system(size: 7)) }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(width: frame.width, height: 28, alignment: .leading)
                .background(effectColor(block.category).opacity(block.isEnabled ? 0.84 : 0.36), in: RoundedRectangle(cornerRadius: 6))
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectEffectTimelineItems(block.itemIDs, primaryID: item.id, modifiers: timelineSelectionModifiers)
                }
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named("timelineCanvas"))
                        .onChanged { value in
                            if draggedEffectID == nil {
                                draggedEffectID = block.id
                                model.selectEffectTimelineItems(block.itemIDs, primaryID: item.id)
                            }
                            effectDragTranslation = value.translation.width
                        }
                        .onEnded { value in
                            let target = movedTime(from: block.startTime, translation: value.translation.width)
                            draggedEffectID = nil
                            effectDragTranslation = 0
                            model.moveEffectTimelineItems(block.itemIDs, primaryID: item.id, to: target)
                        }
                )
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.yellow : .white.opacity(0.14), lineWidth: selected ? 2 : 1).allowsHitTesting(false) }
                .overlay(alignment: .leading) {
                    edgeTrimRegion(.leading, target: .effect(block.id), start: block.startTime, duration: block.duration,
                        width: min(14, frame.width / 2)) { translation in trimEffect(block, edge: .leading, translation: translation) }
                }
                .overlay(alignment: .trailing) {
                    edgeTrimRegion(.trailing, target: .effect(block.id), start: block.startTime, duration: block.duration,
                        width: min(14, frame.width / 2)) { translation in trimEffect(block, edge: .trailing, translation: translation) }
                }
                .offset(
                    x: frame.minX + (draggedEffectID == block.id ? effectDragTranslation : 0),
                    y: CGFloat(effectLaneAssignments[block.id] ?? 0) * 31
                )
                .contextMenu {
                    Button(block.isEnabled ? "Выключить" : "Включить", systemImage: block.isEnabled ? "eye.slash" : "eye") {
                        model.selectEffectTimelineItems(block.itemIDs, primaryID: item.id)
                        model.setEffectTimelineItemsEnabled(block.itemIDs, enabled: !block.isEnabled)
                    }
                    Button("Дублировать", systemImage: "plus.square.on.square") {
                        model.selectEffectTimelineItems(block.itemIDs, primaryID: item.id)
                        model.duplicateTimelineSelection()
                    }
                    Button("Копировать", systemImage: "doc.on.doc") {
                        model.selectEffectTimelineItems(block.itemIDs, primaryID: item.id)
                        model.copyTimelineSelection()
                    }
                    Button("Вставить рядом", systemImage: "doc.on.clipboard") {
                        model.pasteTimelineSelection(at: block.endTime + 0.05)
                    }
                    .disabled(!model.canPasteTimelineElements)
                    Button("Удалить", systemImage: "trash", role: .destructive) {
                        model.selectEffectTimelineItems(block.itemIDs, primaryID: item.id)
                        model.deleteSelectedTimelineObject()
                    }
                }
            }
        }
        .frame(width: totalTimelineWidth, height: CGFloat(effectLaneCount * 31), alignment: .topLeading)
    }

    private func playheadLine(time: Double, color: Color, isHover: Bool, exactX: CGFloat? = nil) -> some View {
        let lineWidth: CGFloat = isHover ? 1.5 : 1
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(color.opacity(isHover ? 0.95 : 0.82))
                .frame(width: lineWidth, height: max(80, canvasHeight))
            Circle()
                .fill(color)
                .frame(width: isHover ? 8 : 7, height: isHover ? 8 : 7)
                .offset(x: -((isHover ? 8 : 7) - lineWidth) / 2, y: -3)
            if isHover {
                Text(frameClock(time))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(color, in: RoundedRectangle(cornerRadius: 3))
                    .fixedSize()
                    .offset(x: 7, y: 1)
            }
        }
        .frame(width: lineWidth, alignment: .leading)
        .offset(x: exactX ?? xPosition(for: time))
        .allowsHitTesting(false)
        .zIndex(isHover ? 20 : 19)
    }

    private var ruler: some View {
        ZStack(alignment: .topLeading) {
            ForEach(visibleRulerTicks, id: \.self) { index in
                let time = min(layout.geometry.duration, Double(index) * rulerInterval)
                VStack(alignment: .leading, spacing: 1) {
                    Text(clock(time))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1, height: 4)
                }
                .offset(x: xPosition(for: time))
            }
        }
        .frame(width: totalTimelineWidth, height: 14, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineCanvas"))
                .onChanged { value in
                    guard let time = timelineTime(at: value.location.x) else { return }
                    model.seekTimeline(to: snapped(time, includePlayhead: false))
                }
        )
    }

    private var connectedTrack: some View {
        ZStack(alignment: .leading) {
            ForEach(visibleConnectedItems) { item in
                let selected = model.isTimelineItemSelected(item.id)
                let preview = trimPreview?.itemID == item.id ? trimPreview : nil
                let originalFrame = regionFrame(start: item.timelineStart, duration: item.timelineDuration)
                let frame = preview?.range.previewFrame(
                    from: .init(start: item.timelineStart, duration: item.timelineDuration),
                    frame: originalFrame, pointsPerSecond: pointsPerSecond) ?? originalFrame
                let width = frame.width
                let controlsInset = min(16, width / 3)
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle")
                    Text(item.overlay?.style.localizedTitle ?? "B-roll")
                        .lineLimit(1)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(width: width, height: 28, alignment: .leading)
                .background(Color.indigo.opacity(0.88), in: RoundedRectangle(cornerRadius: 6))
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { model.selectTimelineItem(item.id, modifiers: timelineSelectionModifiers) }
                .gesture(connectedDragGesture(for: item))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? Color.yellow : .clear, lineWidth: 2)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .trailing) {
                    if hasModifiedSpeed(item) {
                        TimelineInlineControls(availableWidth: max(1, width - controlsInset * 2)) {
                            speedBadge(for: item, compact: true)
                        } compactContent: {
                            Section("Скорость") { clipSpeedOptions(item) }
                        }
                        .padding(.trailing, controlsInset)
                        .help("Скорость клипа: \(speedTitle(item.speed))")
                    }
                }
                .overlay(alignment: .leading) {
                    trimHandle(.leading, item: item, preview: preview, hitWidth: min(14, width / 4))
                }
                .overlay(alignment: .trailing) {
                    trimHandle(.trailing, item: item, preview: preview, hitWidth: min(14, width / 4))
                }
                .offset(
                    x: frame.minX +
                    (draggedConnectedID == item.id ? connectedDragTranslation : 0),
                    y: CGFloat(connectedLaneAssignments[item.id] ?? 0) * 31
                )
                .scaleEffect(draggedConnectedID == item.id ? 1.025 : 1)
                .shadow(color: .black.opacity(draggedConnectedID == item.id ? 0.25 : 0), radius: 6, y: 2)
                .contextMenu { clipContextMenu(item) }
            }
        }
        .frame(width: totalTimelineWidth, height: CGFloat(connectedLaneCount * 31), alignment: .topLeading)
    }

    private var primaryTrack: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(visiblePrimaryIndices.map { (index: $0, item: primaryItems[$0]) }, id: \.item.id) { entry in
                    timelineClip(entry.item, primaryIndex: entry.index)
                        .offset(x: primaryFrame(at: entry.index, includingTrim: true).minX + libraryOffset(at: entry.index))
                        .animation(.easeOut(duration: 0.14), value: libraryInsertion?.index)
                        .animation(.easeOut(duration: 0.14), value: libraryInsertion?.gap)
                        .zIndex(trimPreview?.itemID == entry.item.id ? 1 : 0)
                }
            }
            .frame(width: totalTimelineWidth, height: 80, alignment: .topLeading)
            .coordinateSpace(name: "primaryTimeline")

            if let dropPrimaryIndex, draggedItemID != nil {
                Rectangle()
                    .fill(Color.yellow)
                    .frame(width: 3, height: 80)
                    .shadow(color: .yellow.opacity(0.45), radius: 4)
                    .offset(x: insertionIndicatorX(for: dropPrimaryIndex))
                    .allowsHitTesting(false)
                    .zIndex(12)
            }

            transitionMarkers
        }
        .frame(width: totalTimelineWidth, height: 80, alignment: .leading)
    }

    private var transitionMarkers: some View {
        ForEach(Array(primaryItems.dropFirst().filter {
            $0.transition != nil && renderWindow.intersects(x: xPosition(for: $0.timelineStart) - 9, width: 18)
        })) { item in
            Menu {
                if let transition = timeline.effectiveTransitionItems.first(where: { $0.incomingClipID == item.id }) {
                    Button("Настроить длительность", systemImage: "slider.horizontal.3") {
                        model.selectTransitionTimelineItem(transition.id)
                    }
                    Divider()
                }
                Button("Без перехода") {
                    model.selectTimelineItem(item.id)
                    model.setSelectedTransition(nil)
                }
                Divider()
                ForEach(TransitionStyle.allCases.filter { $0 != .cut }) { transition in
                    Button(transition.localizedTitle) {
                        model.selectTimelineItem(item.id)
                        model.setSelectedTransition(transition.rawValue)
                    }
                }
            } label: {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.blue)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Image(systemName: "rectangle.2.swap")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.8), lineWidth: 1)
                    }
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .offset(x: xPosition(for: item.timelineStart) - 9 + libraryOffset(at: layout.primaryIndices[item.id] ?? 0), y: 29)
            .zIndex(20)
            .help("Переход: \(TransitionStyle(rawValue: item.transition ?? "")?.localizedTitle ?? "Редактировать")")
        }
    }

    private var musicTrack: some View {
        let frame = rangeTrimFrame(for: .soundtrack, start: 0,
            duration: layout.geometry.duration)
        return Group {
            if let plan = timeline.effectiveAdaptiveSoundtrack {
                ZStack(alignment: .leading) {
                    ForEach(plan.segments) { segment in
                        HStack(spacing: 4) {
                            Image(systemName: segment.directive.volume <= 0.001 ? "speaker.slash" : "music.note")
                            Text(segment.directive.volume <= 0.001 ? "Без музыки" : (segment.directive.trackTitle ?? segment.semanticLabel))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(Int(segment.directive.volume * 100))%")
                        }
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .frame(width: max(1, CGFloat(segment.timelineDuration) * pointsPerSecond - 1), height: 27)
                        .background(segment.directive.volume <= 0.001 ? Color.gray : Color.green, in: RoundedRectangle(cornerRadius: 4))
                        .clipped()
                        .offset(x: CGFloat(segment.timelineStart) * pointsPerSecond)
                        .help("\(segment.semanticLabel) · \(Int(segment.directive.volume * 100))%")
                    }
                }
                .frame(width: frame.width, height: 27, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                    Text(timeline.music?.trackTitle ?? timeline.music?.style.localizedTitle ?? "Музыка")
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                    MontageWaveform(seed: timeline.id.uuidString, color: .white.opacity(0.72), barCount: min(160, max(24, Int(totalTimelineWidth / 6))))
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 9)
            }
        }
        .foregroundStyle(.white)
        .frame(width: frame.width, height: 27, alignment: .leading)
        .background(Color.green.opacity(0.76), in: RoundedRectangle(cornerRadius: 6))
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { model.selectSoundtrack() }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("timelineCanvas"))
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    if !isDraggingSoundtrack {
                        isDraggingSoundtrack = true
                        model.selectSoundtrack()
                    }
                    soundtrackDragTranslation = value.translation.width
                }
                .onEnded { value in
                    let start = movedTime(from: 0, translation: value.translation.width)
                    soundtrackDragTranslation = 0
                    isDraggingSoundtrack = false
                    model.moveSoundtrack(toTimelineStart: snapped(start))
                }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(model.selectedSoundtrack ? Color.yellow : Color.white.opacity(0.12), lineWidth: model.selectedSoundtrack ? 2 : 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            edgeTrimRegion(.leading, target: .soundtrack, start: 0, duration: layout.geometry.duration,
                width: min(14, frame.width / 2)) { translation in trimSoundtrack(edge: .leading, translation: translation) }
        }
        .overlay(alignment: .trailing) {
            edgeTrimRegion(.trailing, target: .soundtrack, start: 0, duration: layout.geometry.duration,
                width: min(14, frame.width / 2)) { translation in trimSoundtrack(edge: .trailing, translation: translation) }
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 3) {
                Menu {
                    ForEach([0.0, 0.1, 0.22, 0.35, 0.5, 0.75, 1.0], id: \.self) { volume in
                        Button("\(Int(volume * 100))%") { model.setMusicVolume(volume) }
                    }
                } label: {
                    Image(systemName: "speaker.wave.2.fill").frame(width: 19, height: 19).background(.black.opacity(0.55), in: Circle())
                }
                Menu {
                    ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                        Button(speedTitle(speed)) { model.setMusicSpeed(speed) }
                    }
                } label: {
                    Image(systemName: "speedometer").frame(width: 19, height: 19).background(.black.opacity(0.55), in: Circle())
                }
            }
            .font(.system(size: 9, weight: .bold))
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .padding(.trailing, 16)
        }
        .offset(x: frame.minX + soundtrackDragTranslation)
        .contextMenu {
            Button("Другая музыка", action: model.replaceMusicImmediately)
            Button("Послушать варианты", action: model.listenToMusicAlternatives)
            Button("Запомнить этот стиль") { model.showEditorialStyle = true }
            Divider()
            Menu("Громкость", systemImage: "speaker.wave.2") {
                ForEach([0.0, 0.1, 0.22, 0.35, 0.5, 0.75, 1.0], id: \.self) { volume in
                    Button("\(Int(volume * 100))%") { model.setMusicVolume(volume) }
                }
            }
            Menu("Скорость", systemImage: "speedometer") {
                ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                    Button(speedTitle(speed)) { model.setMusicSpeed(speed) }
                }
            }
            Button("Удалить", systemImage: "trash", role: .destructive) {
                model.selectSoundtrack()
                model.deleteSelectedTimelineItem()
            }
        }
    }

    private var audioClipsTrack: some View {
        ZStack(alignment: .leading) {
            ForEach(visibleAudioClips) { clip in
                let selected = model.isTimelineAudioClipSelected(clip.id)
                let frame = rangeTrimFrame(for: .audio(clip.id), start: clip.timelineStart,
                    duration: clip.timelineDuration)
                let trimWidth = min(14, frame.width / 4)
                let controlsInset = min(16, frame.width / 3)
                HStack(spacing: 7) {
                    Image(systemName: clip.role == .music ? "music.note" : "waveform")
                    Text(clip.title)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                    MontageWaveform(
                        seed: clip.id.uuidString,
                        color: .white.opacity(0.72),
                        barCount: min(90, max(10, Int(frame.width / 5)))
                    )
                    .frame(maxWidth: .infinity)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(width: frame.width, height: 28, alignment: .leading)
                .background(audioColor(clip).opacity(0.82), in: RoundedRectangle(cornerRadius: 6))
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectTimelineAudioClip(clip.id, modifiers: timelineSelectionModifiers)
                }
                .gesture(audioDragGesture(for: clip))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? Color.yellow : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .leading) {
                    edgeTrimRegion(.leading, target: .audio(clip.id), start: clip.timelineStart, duration: clip.timelineDuration,
                        minimumStart: max(0, clip.timelineStart - clip.sourceStart / clip.effectiveSpeed),
                        maximumEnd: audioTrimMaximumEnd(clip), width: trimWidth) { translation in trimAudio(clip, edge: .leading, translation: translation) }
                }
                .overlay(alignment: .trailing) {
                    edgeTrimRegion(.trailing, target: .audio(clip.id), start: clip.timelineStart, duration: clip.timelineDuration,
                        minimumStart: max(0, clip.timelineStart - clip.sourceStart / clip.effectiveSpeed),
                        maximumEnd: audioTrimMaximumEnd(clip), width: trimWidth) { translation in trimAudio(clip, edge: .trailing, translation: translation) }
                }
                .overlay(alignment: .trailing) {
                    TimelineInlineControls(availableWidth: max(1, frame.width - controlsInset * 2)) {
                        audioVolumeButton(clip)
                        audioSpeedButton(clip)
                    } compactContent: {
                        Section("Громкость") { audioVolumeOptions(clip) }
                        Section("Скорость") { audioSpeedOptions(clip) }
                    }
                    .padding(.trailing, controlsInset)
                }
                .offset(
                    x: frame.minX +
                    (draggedAudioID == clip.id ? audioDragTranslation : 0),
                    y: CGFloat(audioLaneAssignments[clip.id] ?? 0) * 31
                )
                .scaleEffect(draggedAudioID == clip.id ? 1.02 : 1)
                .shadow(color: .black.opacity(draggedAudioID == clip.id ? 0.24 : 0), radius: 5, y: 2)
                .contextMenu { audioContextMenu(clip) }
            }
        }
        .frame(width: totalTimelineWidth, height: CGFloat(audioLaneCount * 31), alignment: .topLeading)
    }

    private var telemetryTrack: some View {
        ZStack(alignment: .leading) {
            ForEach(visibleTelemetryItems) { item in
                let selected = model.isTelemetryItemSelected(item.id)
                let frame = rangeTrimFrame(for: .telemetry(item.id), start: item.timelineStart,
                    duration: item.timelineDuration)
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                    Text(item.settings.resolvedWidgets.first?.kind.localizedTitle ?? "Телеметрия")
                        .font(.caption2.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(clock(item.timelineDuration)).font(.caption2.monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(width: frame.width, height: 28, alignment: .leading)
                .background(Color.cyan.opacity(0.78), in: RoundedRectangle(cornerRadius: 6))
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectTelemetryItem(item.id, modifiers: timelineSelectionModifiers)
                }
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .named("timelineCanvas"))
                        .onChanged { value in
                            if draggedTelemetryID == nil { model.selectTelemetryItem(item.id); draggedTelemetryID = item.id }
                            telemetryDragTranslation = value.translation.width
                        }
                        .onEnded { value in
                            let requested = movedTime(from: item.timelineStart, translation: value.translation.width)
                            draggedTelemetryID = nil; telemetryDragTranslation = 0
                            model.moveTelemetryItem(item.id, toTimelineStart: snapped(requested))
                        }
                )
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.yellow : Color.white.opacity(0.2), lineWidth: selected ? 2 : 1).allowsHitTesting(false) }
                .overlay(alignment: .leading) {
                    edgeTrimRegion(.leading, target: .telemetry(item.id), start: item.timelineStart, duration: item.timelineDuration,
                        minimumStart: max(0, item.timelineStart - item.sourceStart),
                        width: min(14, frame.width / 2)) { translation in trimTelemetry(item, edge: .leading, translation: translation) }
                }
                .overlay(alignment: .trailing) {
                    edgeTrimRegion(.trailing, target: .telemetry(item.id), start: item.timelineStart, duration: item.timelineDuration,
                        minimumStart: max(0, item.timelineStart - item.sourceStart),
                        width: min(14, frame.width / 2)) { translation in trimTelemetry(item, edge: .trailing, translation: translation) }
                }
                .offset(x: frame.minX + (draggedTelemetryID == item.id ? telemetryDragTranslation : 0), y: CGFloat(telemetryLaneAssignments[item.id] ?? 0) * 31)
                .contextMenu {
                    Button("Копировать стиль", systemImage: "doc.on.doc") { model.selectTelemetryItem(item.id); model.copySelectedTelemetrySettings() }
                    Button("Вставить стиль", systemImage: "doc.on.clipboard") { model.selectTelemetryItem(item.id); model.pasteSelectedTelemetrySettings() }
                        .disabled(!model.canPasteTelemetrySettings)
                    Button("Дублировать", systemImage: "plus.square.on.square") { model.selectTelemetryItem(item.id); model.duplicateSelectedTelemetryItem() }
                    Divider()
                    Button("Удалить", systemImage: "trash", role: .destructive) { model.selectTelemetryItem(item.id); model.deleteSelectedTimelineItem() }
                }
            }
        }
        .frame(width: totalTimelineWidth, height: CGFloat(telemetryLaneCount * 31), alignment: .topLeading)
    }

    private func timelineClip(_ item: TimelineItem, primaryIndex: Int) -> some View {
        let selected = model.isTimelineItemSelected(item.id)
        let preview = trimPreview?.itemID == item.id ? trimPreview : nil
        let width = clipWidth(item, duration: previewDuration(for: item))
        let shownDuration = preview?.timelineDuration ?? item.timelineDuration
        let croppedLeadingWidth = preview?.edge == .leading
            ? max(0, CGFloat((item.timelineDuration - shownDuration) * pointsPerSecond)) : 0

        let isPhoto = item.assetID.flatMap { model.timelineMediaAsset($0) }?.kind == .photo

        return ZStack(alignment: .topLeading) {
            clipFilmstrip(item, width: width + croppedLeadingWidth)
                .offset(x: -croppedLeadingWidth)
                .frame(width: width, height: isPhoto ? 76 : 58, alignment: .topLeading)
                .clipped()
            if hasSourceAudio(item) {
                MontageWaveform(
                    seed: item.id.uuidString,
                    color: .white.opacity(0.82),
                    barCount: min(140, max(8, Int(width / 5)))
                )
                .frame(width: max(0, width - 50), height: 20, alignment: .leading)
                .padding(.leading, 5)
                .background(Color.blue.opacity(0.82))
                .offset(y: 56)

                Color.blue.opacity(0.82)
                    .frame(width: 50, height: 20)
                    .offset(x: max(0, width - 50), y: 56)
            }

            Text(item.title ?? clock(shownDuration))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 4))
                .padding(5)
                .minimumScaleFactor(0.65)
                .layoutPriority(2)

        }
        .frame(width: width, height: 76, alignment: .topLeading)
        .background(clipColor(item))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? Color.yellow : Color.white.opacity(0.13), lineWidth: selected ? 3 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !brushEnabled else { return }
            model.selectTimelineItem(item.id, modifiers: timelineSelectionModifiers)
            if item.kind == .title { model.openTimelineInspector() }
        }
        .gesture(reorderGesture(for: item, primaryIndex: primaryIndex))
        .overlay(alignment: .topLeading) {
            trimHandle(.leading, item: item, preview: preview)
                .frame(height: hasSourceAudio(item) ? 56 : 76)
        }
        .overlay(alignment: .topTrailing) {
            trimHandle(.trailing, item: item, preview: preview)
                .frame(height: hasSourceAudio(item) ? 56 : 76)
        }
        .overlay(alignment: .bottomTrailing) {
            if hasSourceAudio(item) {
                TimelineInlineControls(availableWidth: max(1, width - 4)) {
                    clipVolumeButton(item)
                    speedBadge(for: item, compact: true)
                } compactContent: {
                    Section("Громкость") { clipVolumeOptions(item) }
                    Section("Скорость") { clipSpeedOptions(item) }
                }
                .padding(.trailing, 2)
            }
        }
        .offset(x: (draggedItemID == item.id ? dragTranslation : 0) + magneticNeighborOffset(for: primaryIndex))
        .scaleEffect(draggedItemID == item.id ? 1.025 : 1)
        .shadow(color: .black.opacity(draggedItemID == item.id ? 0.28 : 0), radius: 7, y: 3)
        .zIndex(draggedItemID == item.id || selected ? 3 : 0)
        .contextMenu { clipContextMenu(item) }
    }

    private func hasModifiedSpeed(_ item: TimelineItem) -> Bool {
        item.kind == .video && abs(item.speed - 1) > 0.001
    }

    private func hasSourceAudio(_ item: TimelineItem) -> Bool {
        guard item.kind == .video, let assetID = item.assetID else { return false }
        return model.timelineMediaAsset(assetID)?.metadata.hasAudio == true
    }

    private func clipVolumeOptions(_ item: TimelineItem) -> some View {
        ForEach([0.0, 0.25, 0.5, 1.0, 1.5, 2.0], id: \.self) { volume in
            Button("\(Int(volume * 100))%") {
                model.selectTimelineItem(item.id)
                model.setSelectedClipVolume(volume)
            }
        }
    }

    private func clipSpeedOptions(_ item: TimelineItem) -> some View {
        ForEach([0.25, 0.5, 1, 2, 4, 8, 10, 20], id: \.self) { speed in
            Button {
                model.selectTimelineItem(item.id)
                model.setSelectedSpeed(speed)
            } label: {
                if abs(item.speed - speed) <= 0.001 {
                    Label(speedTitle(speed), systemImage: "checkmark")
                } else {
                    Text(speedTitle(speed))
                }
            }
        }
    }

    private func clipVolumeButton(_ item: TimelineItem) -> some View {
        let audio = item.effectiveAudioAdjustments
        return Menu {
            clipVolumeOptions(item)
        } label: {
            Image(systemName: audio.muted || audio.volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.black.opacity(0.68), in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1).allowsHitTesting(false) }
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("Громкость клипа: \(Int((audio.volume * 100).rounded()))%")
    }

    private func speedBadge(for item: TimelineItem, compact: Bool = false) -> some View {
        Menu {
            clipSpeedOptions(item)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "speedometer")
                if !compact {
                    Text(speedTitle(item.speed))
                        .monospacedDigit()
                }
            }
            .font(.system(size: compact ? 9 : 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 4 : 5)
            .frame(minWidth: 20, minHeight: compact ? 20 : 22)
            .background(.black.opacity(0.68), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 1).allowsHitTesting(false) }
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("Скорость клипа: \(speedTitle(item.speed)). Нажмите, чтобы изменить")
    }

    private func speedTitle(_ speed: Double) -> String {
        "\(Int((speed * 100).rounded()))%"
    }

    @ViewBuilder
    private func clipFilmstrip(_ item: TimelineItem, width: CGFloat) -> some View {
        if item.kind == .title {
            ZStack {
                LinearGradient(colors: [.purple.opacity(0.92), .indigo.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "textformat")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.66))
            }
        } else if let assetID = item.assetID,
                  let asset = model.timelineMediaAsset(assetID) {
            if let preset = BackgroundPreset.preset(for: asset) {
                BackgroundPresetArtwork(preset: preset)
                    .frame(width: width, height: 76)
            } else if asset.kind == .photo {
                // Photo cache entries contain one complete image, not the
                // 16-frame composite used by video clips. Fill the whole card
                // with that image, including the space videos use for audio.
                CachedThumbnailImage(
                    url: model.timelineThumbnailURLs[item.id] ?? model.thumbnailURLs[assetID],
                    kind: .photo,
                    contentMode: .fill
                )
                .frame(width: width, height: 76)
                .clipped()
            } else {
                if let filmstripURL = model.timelineFilmstripURLs[item.id] {
                    CachedAdaptiveFilmstripImage(
                        url: filmstripURL,
                        kind: asset.kind,
                        sourceFrameCount: 16
                    )
                    .frame(width: width, height: 58)
                } else {
                    MontageTimelineThumbnail(
                        url: model.timelineThumbnailURLs[item.id] ?? model.thumbnailURLs[assetID],
                        kind: asset.kind
                    )
                    .frame(width: width, height: 58)
                }
            }
        } else {
            ZStack {
                clipColor(item)
                Image(systemName: item.kind == .photo ? "photo" : "video")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    @ViewBuilder
    private func brushHighlight(for item: TimelineItem, width: CGFloat) -> some View {
        if brushEnabled, let range = brushedRange {
            let itemStart = item.timelineStart
            let itemEnd = itemStart + item.timelineDuration
            let lower = max(itemStart, range.lowerBound)
            let upper = min(itemEnd, range.upperBound)
            if upper > lower {
                let leadingFraction = (lower - itemStart) / max(0.001, item.timelineDuration)
                let widthFraction = (upper - lower) / max(0.001, item.timelineDuration)
                Rectangle()
                    .fill(Color.purple.opacity(0.30))
                    .overlay(Rectangle().stroke(Color.purple.opacity(0.95), lineWidth: 2))
                    .frame(width: max(2, width * widthFraction), height: 76)
                    .offset(x: width * leadingFraction)
                    .allowsHitTesting(false)
            }
        }
    }

    private var canvasBrushGesture: some Gesture {
        // The gesture is attached to this exact canvas frame. Local coordinates
        // stay aligned after scrolling and do not inherit the ScrollView's
        // horizontal content inset through the named coordinate space.
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard brushEnabled, let time = timelineTime(at: value.location.x) else { return }
                if brushAnchor == nil { brushAnchor = snapped(time) }
                brushCurrent = snapped(time)
            }
            .onEnded { value in
                guard brushEnabled, let time = timelineTime(at: value.location.x) else { return }
                brushCurrent = snapped(time)
            }
    }

    private func reorderGesture(for item: TimelineItem, primaryIndex: Int) -> some Gesture {
        DragGesture(minimumDistance: 7, coordinateSpace: .named("primaryTimeline"))
            .onChanged { value in
                guard !brushEnabled,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                if draggedItemID == nil {
                    draggedItemID = item.id
                    model.selectTimelineItem(item.id)
                }
                guard draggedItemID == item.id else { return }
                dragTranslation = value.translation.width
                let proposedX = primaryFrame(at: primaryIndex).midX + value.translation.width
                dropPrimaryIndex = nearestPrimaryIndex(to: proposedX) ?? primaryIndex
            }
            .onEnded { value in
                guard draggedItemID == item.id else { return }
                let proposedX = primaryFrame(at: primaryIndex).midX + value.translation.width
                let destinationPrimary = nearestPrimaryIndex(to: proposedX) ?? primaryIndex
                withAnimation(.easeOut(duration: 0.15)) {
                    draggedItemID = nil
                    dragTranslation = 0
                    dropPrimaryIndex = nil
                }
                if destinationPrimary != primaryIndex {
                    model.movePrimaryTimelineItem(item.id, toPrimaryIndex: destinationPrimary)
                }
            }
    }

    private func connectedDragGesture(for item: TimelineItem) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("timelineCanvas"))
            .onChanged { value in
                guard !brushEnabled, abs(value.translation.width) > abs(value.translation.height) else { return }
                if draggedConnectedID == nil {
                    draggedConnectedID = item.id
                    model.selectTimelineItem(item.id)
                }
                guard draggedConnectedID == item.id else { return }
                connectedDragTranslation = value.translation.width
            }
            .onEnded { value in
                guard draggedConnectedID == item.id else { return }
                let requested = movedTime(from: item.timelineStart, translation: value.translation.width)
                draggedConnectedID = nil
                connectedDragTranslation = 0
                model.moveConnectedTimelineItem(item.id, toTimelineStart: snapped(requested))
            }
    }

    private func audioDragGesture(for clip: TimelineAudioClip) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("timelineCanvas"))
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if draggedAudioID == nil {
                    draggedAudioID = clip.id
                    model.selectTimelineAudioClip(clip.id)
                }
                guard draggedAudioID == clip.id else { return }
                audioDragTranslation = value.translation.width
            }
            .onEnded { value in
                guard draggedAudioID == clip.id else { return }
                let requested = movedTime(from: clip.timelineStart, translation: value.translation.width)
                draggedAudioID = nil
                audioDragTranslation = 0
                model.moveTimelineAudioClip(clip.id, toTimelineStart: snapped(requested))
            }
    }

    @ViewBuilder
    private func clipContextMenu(_ item: TimelineItem) -> some View {
        if item.kind == .video {
            Button("Другой кадр") { model.compareOtherShot(item.id) }.disabled(item.locked)
            Button("Покороче") { model.compareShotDuration(item.id, longer: false) }.disabled(item.locked)
            Button("Оставить момент подольше") { model.compareShotDuration(item.id, longer: true) }.disabled(item.locked)
            Divider()
        }
        Button("Обрезать", systemImage: "selection.pin.in.out") {
            model.selectTimelineItem(item.id)
        }
        Button("Разделить в позиции playhead", systemImage: "scissors") {
            model.selectTimelineItem(item.id)
            model.splitSelectedTimelineItem()
        }
        .disabled(!containsPlayhead(item))
        Button("Удалить", systemImage: "trash", role: .destructive) {
            model.selectTimelineItem(item.id)
            model.deleteSelectedTimelineItem()
        }

        if item.kind != .title {
            Button("Дублировать", systemImage: "plus.square.on.square") {
                model.selectTimelineItem(item.id)
                model.duplicateSelectedTimelineItem()
            }
        }

        if item.kind == .video {
            if item.assetID.flatMap({ id in model.timelineMediaAsset(id)?.metadata.hasAudio }) == true {
                Button("Отделить аудио", systemImage: "waveform.badge.minus") {
                    model.selectTimelineItem(item.id)
                    model.detachSelectedAudio()
                }
            }
            Menu("Скорость", systemImage: "speedometer") {
                ForEach([0.25, 0.5, 1, 2, 4, 8, 10, 20], id: \.self) { speed in
                    Button("\(Int((speed * 100).rounded()))%") {
                        model.selectTimelineItem(item.id)
                        model.setSelectedSpeed(speed)
                    }
                }
            }
            Menu("Стабилизация", systemImage: "video.fill") {
                Button("Выкл.") {
                    model.selectTimelineItem(item.id)
                    model.setSelectedStabilization(0)
                }
                ForEach([0.33, 0.66, 1.0], id: \.self) { amount in
                    Button("\(Int(amount * 100))%") {
                        model.selectTimelineItem(item.id)
                        model.setSelectedStabilization(amount)
                    }
                }
                Divider()
                Button("Исправить rolling shutter") {
                    model.selectTimelineItem(item.id)
                    model.setSelectedRollingShutterCorrection(true)
                }
            }
        }

        if item.kind == .video || item.kind == .photo {
            Menu("Кадрирование и движение", systemImage: "crop") {
                Button("Заполнить кадр") {
                    model.selectTimelineItem(item.id)
                    model.setSelectedCrop(.fill)
                }
                Button("Показать целиком") {
                    model.selectTimelineItem(item.id)
                    model.setSelectedCrop(.fit)
                }
                Divider()
                Button("Ken Burns") {
                    model.selectTimelineItem(item.id)
                    model.setSelectedEffect(ClipEffect.kenBurns.rawValue)
                }
                Button("Zoom") {
                    model.selectTimelineItem(item.id)
                    model.setSelectedEffect(ClipEffect.zoomIn.rawValue)
                }
                Button("Pan") {
                    model.selectTimelineItem(item.id)
                    model.setSelectedEffect(ClipEffect.panLeft.rawValue)
                }
            }
            if item.kind == .photo {
                Menu("Длительность", systemImage: "timer") {
                    ForEach([2.0, 3.0, 4.0, 5.0, 8.0, 10.0], id: \.self) { duration in
                        Button("\(Int(duration)) с") {
                            model.selectTimelineItem(item.id)
                            model.changeSelectedTimelineDuration(by: duration - item.timelineDuration)
                        }
                    }
                }
            }
            Menu("Цвет и эффекты", systemImage: "camera.filters") {
                Button("Автоулучшение") {
                    model.selectTimelineItem(item.id)
                    model.autoEnhanceSelected()
                }
                ForEach(VideoFilter.allCases) { filter in
                    Button(filter.localizedTitle) {
                        model.selectTimelineItem(item.id)
                        model.setSelectedFilter(filter)
                    }
                }
            }
            Menu("Наложение", systemImage: "rectangle.on.rectangle") {
                Button("Основной видеоряд") {
                    model.selectTimelineItem(item.id)
                    model.setSelectedOverlay(nil)
                }
                ForEach(OverlayStyle.allCases) { style in
                    Button(style.localizedTitle) {
                        model.selectTimelineItem(item.id)
                        model.setSelectedOverlay(style)
                    }
                }
            }
        }

        if item.kind != .title {
            Menu("Добавить переход", systemImage: "rectangle.2.swap") {
                Button("Без перехода") {
                    model.selectTimelineItem(item.id)
                    model.setSelectedTransition(nil)
                }
                ForEach(TransitionStyle.allCases.filter { $0 != .cut }) { transition in
                    Button(transition.localizedTitle) {
                        model.selectTimelineItem(item.id)
                        model.setSelectedTransition(transition.rawValue)
                    }
                }
            }
        }

        Divider()
        Button("Копировать настройки", systemImage: "doc.on.doc") {
            model.selectTimelineItem(item.id)
            model.copySelectedTimelineSettings()
        }
        Button("Вставить настройки", systemImage: "doc.on.clipboard") {
            model.pasteTimelineSettings(to: item.id)
        }
        .disabled(!model.canPasteTimelineSettings)
        Button("AI-редактирование", systemImage: "sparkles") {
            model.selectTimelineItem(item.id)
            brushEnabled = true
        }
    }

    @ViewBuilder
    private func audioContextMenu(_ clip: TimelineAudioClip) -> some View {
        Button("Обрезать", systemImage: "selection.pin.in.out") {
            model.selectTimelineAudioClip(clip.id)
        }
        Button("Разделить в позиции playhead", systemImage: "scissors") {
            model.selectTimelineAudioClip(clip.id)
            model.splitSelectedTimelineItem()
        }
        .disabled(!(model.timelinePlayheadTime > clip.timelineStart && model.timelinePlayheadTime < clip.timelineEnd))
        Button("Удалить", systemImage: "trash", role: .destructive) {
            model.selectTimelineAudioClip(clip.id)
            model.deleteSelectedTimelineItem()
        }
        Divider()
        Menu("Громкость", systemImage: "speaker.wave.2") {
            ForEach([0.0, 0.25, 0.5, 1.0, 1.5, 2.0], id: \.self) { volume in
                Button("\(Int(volume * 100))%") {
                    model.selectTimelineAudioClip(clip.id)
                    model.setSelectedTimelineAudioVolume(volume)
                }
            }
        }
        Menu("Скорость", systemImage: "speedometer") {
            ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 4], id: \.self) { speed in
                Button(speedTitle(speed)) {
                    model.selectTimelineAudioClip(clip.id)
                    model.setSelectedTimelineAudioSpeed(speed)
                }
            }
        }
        Menu("Fade", systemImage: "waveform.path") {
            Button("Без fade") {
                model.selectTimelineAudioClip(clip.id)
                model.setSelectedTimelineAudioFades(in: 0, out: 0)
            }
            Button("Короткий — 0,5 с") {
                model.selectTimelineAudioClip(clip.id)
                model.setSelectedTimelineAudioFades(in: 0.5, out: 0.5)
            }
            Button("Плавный — 1,5 с") {
                model.selectTimelineAudioClip(clip.id)
                model.setSelectedTimelineAudioFades(in: 1.5, out: 1.5)
            }
        }
        Menu("Noise Reduction", systemImage: "waveform.badge.minus") {
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { amount in
                Button("\(Int(amount * 100))%") {
                    model.selectTimelineAudioClip(clip.id)
                    model.setSelectedTimelineAudioNoiseReduction(amount)
                }
            }
        }
        Menu("EQ", systemImage: "slider.horizontal.3") {
            ForEach(AudioEQPreset.allCases) { preset in
                Button(preset.localizedTitle) {
                    model.selectTimelineAudioClip(clip.id)
                    model.setSelectedTimelineAudioEQ(preset)
                }
            }
        }
        Button(clip.adjustments.normalize == true ? "Убрать нормализацию" : "Нормализовать громкость", systemImage: "gauge.with.dots.needle.67percent") {
            model.selectTimelineAudioClip(clip.id)
            model.setSelectedTimelineAudioNormalize(clip.adjustments.normalize != true)
        }
        Button(clip.adjustments.duckOthers == true ? "Выключить ducking" : "Ducking других источников", systemImage: "speaker.wave.1") {
            model.selectTimelineAudioClip(clip.id)
            model.setSelectedTimelineAudioDuckOthers(clip.adjustments.duckOthers != true)
        }
        Menu("Аудиоэффект", systemImage: "wand.and.stars") {
            ForEach(AudioEffect.allCases) { effect in
                Button(effect.localizedTitle) {
                    model.selectTimelineAudioClip(clip.id)
                    model.setSelectedTimelineAudioEffect(effect)
                }
            }
        }
    }

    private func audioVolumeOptions(_ clip: TimelineAudioClip) -> some View {
        ForEach([0.0, 0.25, 0.5, 1.0, 1.5, 2.0], id: \.self) { volume in
            Button("\(Int(volume * 100))%") {
                model.selectTimelineAudioClip(clip.id)
                model.setSelectedTimelineAudioVolume(volume)
            }
        }
    }

    private func audioVolumeButton(_ clip: TimelineAudioClip) -> some View {
        Menu {
            audioVolumeOptions(clip)
        } label: {
            Image(systemName: clip.adjustments.volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 19, height: 19)
                .background(.black.opacity(0.55), in: Circle())
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("Громкость: \(Int((clip.adjustments.volume * 100).rounded()))%")
    }

    private func audioSpeedOptions(_ clip: TimelineAudioClip) -> some View {
        ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 4], id: \.self) { speed in
            Button(speedTitle(speed)) {
                model.selectTimelineAudioClip(clip.id)
                model.setSelectedTimelineAudioSpeed(speed)
            }
        }
    }

    private func audioSpeedButton(_ clip: TimelineAudioClip) -> some View {
        Menu {
            audioSpeedOptions(clip)
        } label: {
            Image(systemName: "speedometer")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 19, height: 19)
                .background(.black.opacity(0.55), in: Circle())
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("Скорость: \(speedTitle(clip.effectiveSpeed))")
    }

    private func containsPlayhead(_ item: TimelineItem) -> Bool {
        model.timelinePlayheadTime > item.timelineStart &&
        model.timelinePlayheadTime < item.timelineStart + item.timelineDuration
    }

    private func magneticNeighborOffset(for index: Int) -> CGFloat {
        guard let draggedID = draggedItemID,
              let source = layout.primaryIndices[draggedID],
              let target = dropPrimaryIndex,
              source != target else { return 0 }
        let distance = clipWidth(primaryItems[source]) + clipSpacing
        if source < target, index > source, index <= target { return -distance }
        if target < source, index >= target, index < source { return distance }
        return 0
    }

    private func insertionIndicatorX(for target: Int) -> CGFloat {
        guard primaryItems.indices.contains(target) else { return 0 }
        let frame = primaryFrame(at: target)
        guard let draggedID = draggedItemID,
              let source = layout.primaryIndices[draggedID] else { return frame.minX }
        return target > source ? frame.maxX : frame.minX
    }

    private func trimHandle(
        _ edge: TrimEdge, item: TimelineItem, preview: TrimPreview?, hitWidth: CGFloat? = nil
    ) -> some View {
        TimelineTrimHandle(
            width: hitWidth ?? min(14, clipWidth(item, duration: preview?.timelineDuration) / 2),
            isEnabled: !model.isTimelineInteractionBlocked && !brushEnabled,
            gesture: trimGesture(edge, item: item)
        )
        .help(edge == .leading ? "Обрезать начало" : "Обрезать конец")
    }

    private func edgeTrimRegion(
        _ edge: TrimEdge,
        target: RangeTrimTarget,
        start: Double,
        duration: Double,
        minimumStart: Double = 0,
        maximumEnd: Double? = nil,
        width: CGFloat = 14,
        onEnded: @escaping (CGFloat) -> Void
    ) -> some View {
        let original = TimelineTrimRange(start: start, duration: duration)
        let preview = { (translation: CGFloat) in
            original.trimming(edge, by: Double(translation) / pointsPerSecond,
                minimumStart: minimumStart, maximumEnd: maximumEnd ?? layout.geometry.duration)
        }
        return TimelineTrimHandle(
            width: width,
            isEnabled: !model.isTimelineInteractionBlocked && !brushEnabled,
            gesture: DragGesture(minimumDistance: 1, coordinateSpace: .named("timelineCanvas"))
                .onChanged { value in
                    rangeTrimPreview = RangeTrimPreview(target: target, range: preview(value.translation.width))
                }
                .onEnded { value in
                    let range = preview(value.translation.width)
                    rangeTrimPreview = nil
                    let delta = edge == .leading ? range.start - start : range.duration - duration
                    onEnded(CGFloat(delta * pointsPerSecond))
                }
        )
        .help(edge == .leading ? "Обрезать или увеличить начало" : "Обрезать или увеличить конец")
    }

    private func rangeTrimFrame(
        for target: RangeTrimTarget, start: Double, duration: Double
    ) -> CGRect {
        let frame = regionFrame(start: start, duration: duration)
        guard let preview = rangeTrimPreview, preview.target == target else { return frame }
        return preview.range.previewFrame(from: .init(start: start, duration: duration),
            frame: frame, pointsPerSecond: pointsPerSecond)
    }

    private func trimTitle(_ item: TitleTimelineItem, edge: TrimEdge, translation: CGFloat) {
        let delta = Double(translation) / pointsPerSecond
        switch edge {
        case .leading:
            let applied = min(max(delta, -item.startTime), item.duration - 0.05)
            model.trimTitleTimelineItem(item.id, startTime: item.startTime + applied, duration: item.duration - applied)
        case .trailing:
            let duration = min(max(0.05, item.duration + delta), max(0.05, layout.geometry.duration - item.startTime))
            model.trimTitleTimelineItem(item.id, startTime: item.startTime, duration: duration)
        }
    }

    private func trimEffect(_ block: EffectTimelineBlock, edge: TrimEdge, translation: CGFloat) {
        let delta = Double(translation) / pointsPerSecond
        switch edge {
        case .leading:
            let applied = min(max(delta, -block.startTime), block.duration - 0.05)
            model.trimEffectTimelineItems(
                block.itemIDs,
                startTime: block.startTime + applied,
                duration: block.duration - applied
            )
        case .trailing:
            let duration = min(max(0.05, block.duration + delta), max(0.05, layout.geometry.duration - block.startTime))
            model.trimEffectTimelineItems(block.itemIDs, startTime: block.startTime, duration: duration)
        }
    }

    private func trimTelemetry(_ item: TimelineTelemetryItem, edge: TrimEdge, translation: CGFloat) {
        let delta = Double(translation) / pointsPerSecond
        switch edge {
        case .leading:
            let applied = min(max(delta, -min(item.timelineStart, item.sourceStart)), item.timelineDuration - 0.05)
            model.trimTelemetryItem(
                item.id,
                timelineStart: item.timelineStart + applied,
                duration: item.timelineDuration - applied,
                sourceStart: item.sourceStart + applied
            )
        case .trailing:
            let duration = min(max(0.05, item.timelineDuration + delta), max(0.05, layout.geometry.duration - item.timelineStart))
            model.trimTelemetryItem(item.id, timelineStart: item.timelineStart, duration: duration, sourceStart: item.sourceStart)
        }
    }

    private func trimAudio(_ clip: TimelineAudioClip, edge: TrimEdge, translation: CGFloat) {
        let delta = Double(translation) / pointsPerSecond
        switch edge {
        case .leading:
            let applied = min(max(delta, -min(clip.timelineStart, clip.sourceStart / clip.effectiveSpeed)), clip.timelineDuration - 0.05)
            model.trimTimelineAudioClip(
                clip.id,
                timelineStart: clip.timelineStart + applied,
                sourceStart: clip.sourceStart + applied * clip.effectiveSpeed,
                duration: clip.timelineDuration - applied
            )
        case .trailing:
            let maximum = max(0.05, audioTrimMaximumEnd(clip) - clip.timelineStart)
            model.trimTimelineAudioClip(clip.id, sourceStart: clip.sourceStart, duration: min(max(0.05, clip.timelineDuration + delta), maximum))
        }
    }

    private func audioTrimMaximumEnd(_ clip: TimelineAudioClip) -> Double {
        let sourceLength = clip.assetID.flatMap { model.timelineMediaAsset($0)?.metadata.duration }
            ?? clip.trackID.flatMap { id in model.musicTracks.first(where: { $0.id == id })?.duration }
            ?? (clip.sourceStart + clip.sourceDuration)
        return min(layout.geometry.duration,
            clip.timelineStart + max(0.05, (sourceLength - clip.sourceStart) / clip.effectiveSpeed))
    }

    private func trimSoundtrack(edge: TrimEdge, translation: CGFloat) {
        guard let trackID = timeline.music?.trackID,
              let sourceDuration = model.musicTracks.first(where: { $0.id == trackID })?.duration else { return }
        let delta = Double(translation) / pointsPerSecond
        switch edge {
        case .leading:
            let start = min(max(0, delta), max(0, layout.geometry.duration - 0.05))
            model.trimSoundtrack(toTimelineStart: start, duration: min(sourceDuration, layout.geometry.duration - start))
        case .trailing:
            let duration = min(sourceDuration, max(0.05, layout.geometry.duration + delta))
            model.trimSoundtrack(toTimelineStart: 0, duration: duration)
        }
    }

    private func trimGesture(_ edge: TrimEdge, item: TimelineItem) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("timelineCanvas"))
            .onChanged { value in
                guard !brushEnabled else { return }
                if trimPreview?.itemID != item.id { model.selectTimelineItem(item.id) }
                trimPreview = makeTrimPreview(item, edge: edge, translation: value.translation.width)
            }
            .onEnded { value in
                guard trimPreview?.itemID == item.id, trimPreview?.edge == edge else { return }
                let preview = makeTrimPreview(item, edge: edge, translation: value.translation.width)
                trimPreview = nil
                if abs(preview.sourceStart - item.sourceStart) > 0.001 ||
                    abs(preview.timelineDuration - item.timelineDuration) > 0.001 {
                    model.trimTimelineItem(id: item.id, sourceStart: preview.sourceStart,
                        timelineDuration: preview.timelineDuration,
                        timelineStart: item.overlay == nil ? nil : preview.timelineStart)
                }
            }
    }

    private func makeTrimPreview(_ item: TimelineItem, edge: TrimEdge, translation: CGFloat) -> TrimPreview {
        // Keep the proposed edge at the exact pointer coordinate while the
        // gesture is active. Frame quantization here made the handle lag in
        // visible steps, and a local coordinate space became unstable because
        // the clip itself changes width during the drag.
        let sourceRate = max(0.01, item.sourceDuration / max(0.01, item.timelineDuration))
        var minimumStart = item.timelineStart - (item.kind == .video ? item.sourceStart / sourceRate : 3_600)
        var maximumEnd = Double.greatestFiniteMagnitude
        if item.kind == .video {
            let sourceEnd = item.assetID.flatMap { model.timelineMediaAsset($0)?.metadata.duration }
                ?? (item.sourceStart + item.sourceDuration)
            maximumEnd = item.timelineStart + max(0.25, (sourceEnd - item.sourceStart) / sourceRate)
        }
        if item.overlay != nil {
            minimumStart = max(0, minimumStart)
            maximumEnd = min(maximumEnd, layout.geometry.duration)
        }
        let range = TimelineTrimRange(start: item.timelineStart, duration: item.timelineDuration)
            .trimming(edge, by: Double(translation) / pointsPerSecond,
                minimumStart: minimumStart, maximumEnd: maximumEnd, minimumDuration: 0.25)
        return TrimPreview(itemID: item.id, edge: edge,
            sourceStart: item.kind == .video
                ? item.sourceStart + (range.start - item.timelineStart) * sourceRate : item.sourceStart,
            timelineStart: range.start, timelineDuration: range.duration)
    }

    private var insertionGeometry: TimelineInsertionGeometry {
        TimelineInsertionGeometry(frames: primaryItems.indices.map { primaryFrame(at: $0) })
    }

    private func libraryOffset(at index: Int) -> CGFloat {
        guard let preview = libraryInsertion, let target = preview.index else { return 0 }
        return index >= target ? preview.gap : 0
    }

    @ViewBuilder private var libraryInsertionOverlay: some View {
        if let preview = libraryInsertion {
            let y: CGFloat = switch preview.lane {
            case .primary, .transition: primaryTrackY
            case .title: 19
            case .effect: effectTrackY
            case .telemetry: telemetryTrackY
            case .audio: audioTrackY
            }
            let height: CGFloat = preview.index == nil ? 28 : 76
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.22))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
                .overlay {
                    Label(preview.label, systemImage: preview.symbol)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .padding(5)
                }
                .frame(width: preview.width, height: height)
                .offset(x: preview.x, y: y + CGFloat(preview.laneIndex * 31))
                .allowsHitTesting(false)
                .zIndex(25)
        }
    }

    private func updateLibraryInsertion(_ raw: String, at point: CGPoint) {
        let next = libraryPreview(for: raw, at: point)
        if libraryInsertion != next { libraryInsertion = next }
        if hoverState.time != nil { hoverState.clear() }
    }

    private func libraryPreview(for raw: String, at point: CGPoint) -> TimelineInsertionPreview? {
        let geometry = insertionGeometry
        let time = timelineTime(at: point.x).map { snapped($0) } ?? 0
        func primary(_ label: String, symbol: String, duration: Double) -> TimelineInsertionPreview {
            let index = geometry.insertionIndex(at: point.x)
            let start = index < primaryItems.count ? primaryItems[index].timelineStart : layout.geometry.duration
            return .init(lane: .primary, index: index, time: start,
                         x: geometry.boundaryX(at: index, spacing: clipSpacing),
                         width: min(180, max(64, duration * pointsPerSecond)), label: label, symbol: symbol)
        }
        func overlay(_ lane: TimelineInsertionPreview.Lane, label: String, symbol: String, duration: Double,
                     at requestedStart: Double? = nil) -> TimelineInsertionPreview {
            let start = TimelineTiming.editingTime(requestedStart ?? time, in: timeline,
                maximum: layout.geometry.duration - 0.05)
            let end = start + min(duration, max(0.05, layout.geometry.duration - start))
            let ranges: [(Int, Double, Double)] = switch lane {
            case .title: titleItems.map { (titleLaneAssignments[$0.id] ?? 0, $0.startTime, $0.startTime + $0.duration) }
            case .effect: effectBlocks.map { (effectLaneAssignments[$0.id] ?? 0, $0.startTime, $0.endTime) }
            case .telemetry: telemetryItems.map { (telemetryLaneAssignments[$0.id] ?? 0, $0.timelineStart, $0.timelineEnd) }
            case .audio: audioClips.map { (audioLaneAssignments[$0.id] ?? 0, $0.timelineStart, $0.timelineEnd) }
            default: []
            }
            var laneIndex = 0
            while ranges.contains(where: { $0.0 == laneIndex && $0.1 < end && $0.2 > start }) { laneIndex += 1 }
            let frame = layout.geometry.rangeFrame(start: start, duration: end - start,
                pointsPerSecond: pointsPerSecond, spacing: Double(clipSpacing))
            return .init(lane: lane, index: nil, time: start, x: frame.minX,
                         width: frame.width,
                         label: label, symbol: symbol, laneIndex: laneIndex)
        }
        if raw.hasPrefix("background:"), let preset = BackgroundPreset(rawValue: String(raw.dropFirst(11))) {
            return primary(preset.localizedTitle, symbol: "photo", duration: 4)
        }
        if let id = UUID(uuidString: raw), let asset = model.project?.assets.first(where: { $0.id == id }) {
            return primary(asset.displayName, symbol: asset.kind == .video ? "video" : "photo",
                           duration: asset.kind == .video ? max(0.25, asset.metadata.duration ?? 5) : 4)
        }
        if raw.hasPrefix("transition:"), let style = TransitionStyle(rawValue: String(raw.dropFirst(11))),
           let index = geometry.transitionIndex(at: point.x) {
            return .init(lane: .transition, index: index, time: primaryItems[index].timelineStart,
                         x: geometry.boundaryX(at: index, spacing: clipSpacing), width: 48,
                         label: style.localizedTitle, symbol: "rectangle.2.swap")
        }
        if raw.hasPrefix("music:"), let id = UUID(uuidString: String(raw.dropFirst(6))),
           let track = model.musicTracks.first(where: { $0.id == id }) {
            return overlay(.audio, label: track.title, symbol: "waveform", duration: track.duration)
        }
        if let payload = TelemetryPresetDragPayload(raw) {
            let active = timeline.items.filter {
                $0.kind == .video && $0.assetID != nil && time >= $0.timelineStart && time < $0.timelineStart + $0.timelineDuration
            }
            guard let target = active.last(where: { $0.overlay != nil }) ?? active.first else { return nil }
            return overlay(.telemetry, label: payload.kind.localizedTitle, symbol: "gauge.with.dots.needle.67percent",
                           duration: target.timelineDuration, at: target.timelineStart)
        }
        if raw.hasPrefix("effect:"), let effect = TimelineEffectType(rawValue: String(raw.dropFirst(7))) {
            return overlay(.effect, label: effect.localizedTitle, symbol: "wand.and.rays", duration: 2)
        }
        if raw.hasPrefix("effect-preset:"), let preset = EffectStackPresetRegistry.preset(id: String(raw.dropFirst(14))) {
            return overlay(.effect, label: preset.name, symbol: "square.stack.3d.up.fill", duration: 3)
        }
        if raw.hasPrefix("title-template:") {
            let fields = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let template = TitleTemplateRegistry.template(id: String(fields[1])) else { return nil }
            return overlay(.title, label: template.name, symbol: "textformat", duration: template.duration)
        }
        if raw.hasPrefix("title:") {
            return overlay(.title, label: "Титр", symbol: "textformat", duration: 3.2)
        }
        return nil
    }

    private func handleLibraryDrop(_ values: [String], at point: CGPoint) -> Bool {
        guard !model.isTimelineInteractionBlocked, let raw = values.first else { return false }
        guard let preview = libraryPreview(for: raw, at: point) else { return false }
        let time = preview.time

        if raw.hasPrefix("background:"),
           let preset = BackgroundPreset(rawValue: String(raw.dropFirst("background:".count))) {
            model.insertBackgroundIntoTimeline(preset, at: backgroundInsertionIndex(at: point.x))
            return true
        }
        if raw.hasPrefix("music:"),
           let trackID = UUID(uuidString: String(raw.dropFirst("music:".count))) {
            model.insertMusicClip(trackID, at: time)
            return true
        }
        if let payload = TelemetryPresetDragPayload(raw) {
            model.insertTelemetryPreset(
                kind: payload.kind,
                presentation: payload.presentation,
                style: payload.style,
                at: time
            )
            return true
        }
        if raw.hasPrefix("effect:"),
           let effect = TimelineEffectType(rawValue: String(raw.dropFirst("effect:".count))) {
            model.addTimelineEffect(effect, at: time)
            return true
        }
        if raw.hasPrefix("effect-preset:"),
           let preset = EffectStackPresetRegistry.preset(id: String(raw.dropFirst("effect-preset:".count))) {
            model.applyEffectStackPreset(preset.id, at: time)
            return true
        }
        if raw.hasPrefix("transition:"),
           let transition = TransitionStyle(rawValue: String(raw.dropFirst("transition:".count))) {
            model.addTimelineTransition(transition, at: time)
            return true
        }
        if raw.hasPrefix("title-template:") {
            let components = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard components.count == 3,
                  TitleTemplateRegistry.template(id: String(components[1])) != nil,
                  let data = Data(base64Encoded: String(components[2])),
                  let text = String(data: data, encoding: .utf8) else { return false }
            model.addModernTitle(text, templateID: String(components[1]), at: time)
            return true
        }
        if raw.hasPrefix("title:") {
            let components = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard components.count == 3,
                  let kind = TitleTimelineKind(rawValue: String(components[1])),
                  let data = Data(base64Encoded: String(components[2])),
                  let text = String(data: data, encoding: .utf8) else { return false }
            model.addModernTitle(text, kind: kind, at: time)
            return true
        }
        if let assetID = UUID(uuidString: raw),
           model.project?.assets.contains(where: { $0.id == assetID }) == true {
            model.insertAssetIntoTimeline(assetID, at: insertionGeometry.insertionIndex(at: point.x))
            return true
        }
        return false
    }

    private func timelineTime(at x: CGFloat) -> Double? {
        layout.geometry.time(at: Double(x), pointsPerSecond: pointsPerSecond, spacing: Double(clipSpacing))
    }

    private func movedTime(from start: Double, translation: CGFloat) -> Double {
        snapped(layout.geometry.movedTime(from: start, translation: Double(translation),
            pointsPerSecond: pointsPerSecond, spacing: Double(clipSpacing)))
    }

    private func snapped(_ time: Double, includePlayhead: Bool = true) -> Double {
        layout.geometry.snapped(time, threshold: 8 / pointsPerSecond, frameRate: timeline.frameRate,
                                playhead: includePlayhead ? model.timelinePlayheadTime : nil)
    }

    private func nearestPrimaryIndex(to x: CGFloat) -> Int? {
        primaryItems.indices.min {
            let left = primaryFrame(at: $0).midX
            let right = primaryFrame(at: $1).midX
            return abs(left - x) < abs(right - x)
        }
    }

    private func backgroundInsertionIndex(at x: CGFloat) -> Int {
        let index = insertionGeometry.insertionIndex(at: x)
        guard index < primaryItems.count else { return timeline.items.count }
        let item = primaryItems[index]
        return timeline.items.firstIndex(where: { $0.id == item.id }) ?? timeline.items.count
    }

    private func clipWidth(_ item: TimelineItem, duration: Double? = nil) -> CGFloat {
        max(1, CGFloat((duration ?? item.timelineDuration) * pointsPerSecond))
    }

    private func regionFrame(start: Double, duration: Double) -> CGRect {
        layout.geometry.rangeFrame(start: start, duration: duration,
            pointsPerSecond: pointsPerSecond, spacing: Double(clipSpacing))
    }

    private func isRangeVisible(start: Double, duration: Double) -> Bool {
        let frame = regionFrame(start: start, duration: duration)
        return renderWindow.intersects(x: frame.minX, width: frame.width)
    }

    private func effectColor(_ category: TimelineEffectCategory) -> Color {
        switch category {
        case .basic: return .gray
        case .cinematic: return .purple
        case .color: return .green
        case .blur: return .indigo
        case .motion: return .blue
        case .stylized: return .pink
        }
    }

    private var totalTimelineWidth: CGFloat {
        let gaps = CGFloat(max(0, primaryItems.count - 1)) * clipSpacing
        let previewDelta = trimPreview.flatMap { preview in
            primaryItems.first(where: { $0.id == preview.itemID }).map {
                preview.timelineDuration - $0.timelineDuration
            }
        } ?? 0
        // Do not shrink the scroll document during an active trim. Otherwise
        // AppKit clamps the horizontal offset near the end of the Timeline and
        // moves the clip underneath a stationary pointer, which feels like a
        // shaking or lagging trim handle.
        let visibleDuration = max(layout.geometry.duration, layout.geometry.duration + previewDelta)
        return max(320, CGFloat(visibleDuration * pointsPerSecond) + gaps + (libraryInsertion?.gap ?? 0))
    }

    private func xPosition(for time: Double) -> CGFloat {
        CGFloat(layout.geometry.xPosition(for: time, pointsPerSecond: pointsPerSecond, spacing: Double(clipSpacing)))
    }

    private var rulerInterval: Double {
        if pointsPerSecond >= 42 { return 1 }
        if pointsPerSecond >= 20 { return 2 }
        if pointsPerSecond >= 10 { return 5 }
        return 10
    }

    private var rulerTickCount: Int {
        max(1, Int(ceil(layout.geometry.duration / rulerInterval)))
    }

    private func intersectsBrush(_ item: TimelineItem) -> Bool {
        guard let range = brushedRange else { return false }
        return item.timelineStart < range.upperBound && item.timelineStart + item.timelineDuration > range.lowerBound
    }

    private func clipColor(_ item: TimelineItem) -> Color {
        switch item.kind {
        case .video: return .blue.opacity(0.75)
        case .photo: return .orange.opacity(0.78)
        case .title: return .purple.opacity(0.82)
        }
    }

    private func audioColor(_ clip: TimelineAudioClip) -> Color {
        switch clip.role {
        case .music: return .green
        case .detached: return .teal
        case .dialogue: return .indigo
        case .naturalSound: return .cyan
        case .soundEffect: return .orange
        case .voice: return .purple
        }
    }

    private var timelineSelectionModifiers: NSEvent.ModifierFlags {
        NSEvent.modifierFlags.intersection([.command, .shift])
    }

    private func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func frameClock(_ seconds: Double) -> String {
        let fps = max(1, Int(timeline.frameRate.rounded()))
        let totalFrames = max(0, Int((seconds * Double(fps)).rounded()))
        let wholeSeconds = totalFrames / fps
        let frame = totalFrames % fps
        return String(format: "%02d:%02d:%02d", wholeSeconds / 60, wholeSeconds % 60, frame)
    }
}

private struct MontageWaveform: View {
    let seed: String
    let color: Color
    let barCount: Int

    @Environment(\.timelineRenderRange) private var renderRange

    var body: some View {
        GeometryReader { proxy in
            let fullWidth = proxy.size.width
            let slice = TimelineDrawingSlice(width: fullWidth,
                origin: proxy.frame(in: .named("timelineCanvas")).minX, range: renderRange)
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                let count = max(1, barCount, Int(ceil(fullWidth / 4)))
                let slotWidth = fullWidth / CGFloat(count)
                let barWidth = min(2, max(1, slotWidth * 0.68))
                let base = seed.utf8.reduce(0) { ($0 + Int($1)) % 997 }
                var bars = Path()
                for index in slice.indices(count: count, fullWidth: fullWidth) {
                    let height = min(size.height, amplitude(index, base: base))
                    let rect = CGRect(
                        x: CGFloat(index) * slotWidth + (slotWidth - barWidth) / 2 - slice.lower,
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height
                    )
                    bars.addRoundedRect(in: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
                }
                context.fill(bars, with: .color(color))
            }
            .frame(width: slice.width, height: proxy.size.height)
            .offset(x: slice.lower)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
    }

    private func amplitude(_ index: Int, base: Int) -> CGFloat {
        let value = (base + index * 37 + index * index * 11) % 100
        return 3 + CGFloat(value) / 100 * 13
    }
}

private struct MontageTimelineThumbnail: View {
    let url: URL?
    let kind: MediaKind

    var body: some View {
        CachedAdaptiveFilmstripImage(url: url, kind: kind, sourceFrameCount: 1)
        .clipped()
    }
}

/// Keep cursor ownership in SwiftUI, which also owns the timeline's scroll and
/// gesture hit regions. A separate AppKit background does not receive those hits.
private struct TimelineTrimHandle<TrimGesture: Gesture>: View {
    let width: CGFloat
    let isEnabled: Bool
    let gesture: TrimGesture
    @State private var ownsLegacyCursor = false

    var body: some View {
        if #available(macOS 15.0, *) {
            hitRegion.pointerStyle(isEnabled ? .frameResize(position: .trailing) : nil)
        } else {
            hitRegion
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        guard isEnabled else { return }
                        if !ownsLegacyCursor {
                            NSCursor.resizeLeftRight.push()
                            ownsLegacyCursor = true
                        }
                    case .ended:
                        releaseLegacyCursor()
                    }
                }
                .onChange(of: isEnabled) { _, enabled in
                    if !enabled { releaseLegacyCursor() }
                }
                .onDisappear { releaseLegacyCursor() }
        }
    }

    private var hitRegion: some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            .gesture(gesture)
            .allowsHitTesting(isEnabled)
    }

    private func releaseLegacyCursor() {
        guard ownsLegacyCursor else { return }
        NSCursor.pop()
        ownsLegacyCursor = false
    }
}

/// Short clips must not clip half a button or spill it onto their neighbour.
private struct TimelineInlineControls<Controls: View, CompactContent: View>: View {
    let availableWidth: CGFloat
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let compactContent: () -> CompactContent

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 3, content: controls)
                .fixedSize()
            Menu(content: compactContent) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: min(20, availableWidth), height: 20)
                    .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help("Громкость и скорость")
        }
        .frame(width: availableWidth, height: 20, alignment: .trailing)
    }
}

/// A small independently-observed playhead prevents every playback tick from
/// invalidating all clips, waveforms, menus and lane-layout calculations.
private struct TimelinePlayheadOverlay: View {
    @ObservedObject var clock: TimelinePlaybackClock
    let geometry: TimelineHorizontalGeometry
    let pointsPerSecond: Double
    let clipSpacing: CGFloat
    let canvasHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.82))
                .frame(width: 1, height: max(80, canvasHeight))
            Circle()
                .fill(Color.white)
                .frame(width: 7, height: 7)
                .offset(x: -3, y: -3)
        }
        .frame(width: 1, alignment: .leading)
        .offset(x: xPosition(for: clock.time))
        .allowsHitTesting(false)
        .zIndex(19)
    }

    private func xPosition(for time: Double) -> CGFloat {
        CGFloat(geometry.xPosition(for: time, pointsPerSecond: pointsPerSecond, spacing: Double(clipSpacing)))
    }

}

private struct TimelineHoverOverlay: View {
    @ObservedObject var state: TimelineHoverState
    let timeline: Timeline
    let canvasHeight: CGFloat

    var body: some View {
        if let time = state.time, let x = state.x {
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.yellow.opacity(0.95))
                    .frame(width: 1.5, height: max(80, canvasHeight))
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 8, height: 8)
                    .offset(x: -3.25, y: -3)
                Text(frameClock(time))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.yellow, in: RoundedRectangle(cornerRadius: 3))
                    .fixedSize()
                    .offset(x: 7, y: 1)
            }
            .frame(width: 1.5, alignment: .leading)
            .offset(x: x)
            .allowsHitTesting(false)
            .zIndex(20)
        }
    }

    private func frameClock(_ seconds: Double) -> String {
        let fps = max(1, Int(timeline.frameRate.rounded()))
        let totalFrames = max(0, Int((seconds * Double(fps)).rounded()))
        let wholeSeconds = totalFrames / fps
        return String(format: "%02d:%02d:%02d", wholeSeconds / 60, wholeSeconds % 60, totalFrames % fps)
    }
}
