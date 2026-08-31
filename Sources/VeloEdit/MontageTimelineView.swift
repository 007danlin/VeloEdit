import SwiftUI
import AVKit
import VeloEditCore

private enum EffectTimelineGroupingKey: Hashable {
    case presetInstance(UUID)
    case legacyPreset(String, UUID?, Int64, Int64)
    case standalone(UUID)
}

private struct EffectTimelineBlock: Identifiable {
    let id: UUID
    var items: [EffectTimelineItem]
    let presetID: String?

    var primary: EffectTimelineItem { items[0] }
    var itemIDs: [UUID] { items.map(\.id) }
    var startTime: Double { items.map(\.startTime).min() ?? primary.startTime }
    var endTime: Double { items.map(\.endTime).max() ?? primary.endTime }
    var duration: Double { max(0.05, endTime - startTime) }
    var isEnabled: Bool { items.allSatisfy(\.enabled) }
    var hasKeyframes: Bool { items.contains { !$0.keyframes.isEmpty } }
    var title: String {
        presetID.flatMap { EffectStackPresetRegistry.preset(id: $0)?.name }
            ?? primary.effectType.localizedTitle
    }
    var category: TimelineEffectCategory { primary.effectType.category }
}

/// The iMovie-like editing surface: one magnetic primary storyline, optional
/// connected media, a compact music lane, and a local AI brush.
struct MagneticTimelineView: View {
    @EnvironmentObject private var model: AppModel
    let timeline: Timeline

    @State private var zoom: Double = 18
    @State private var brushEnabled = false
    @State private var brushAnchor: Double?
    @State private var brushCurrent: Double?
    @State private var clipFrames: [UUID: CGRect] = [:]
    @State private var draggedItemID: UUID?
    @State private var dragTranslation: CGFloat = 0
    @State private var dropPrimaryIndex: Int?
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
    @State private var hoverTime: Double?
    @State private var hoverX: CGFloat?
    @GestureState private var magnification: CGFloat = 1

    private let clipSpacing: CGFloat = 8

    private enum TrimEdge: Equatable {
        case leading
        case trailing
    }

    private struct TrimPreview {
        let itemID: UUID
        let edge: TrimEdge
        let sourceStart: Double
        let timelineDuration: Double
    }

    private var primaryItems: [TimelineItem] { timeline.items.filter { $0.overlay == nil } }
    private var connectedItems: [TimelineItem] { timeline.items.filter { $0.overlay != nil } }
    private var audioClips: [TimelineAudioClip] { timeline.effectiveAudioClips }
    private var telemetryItems: [TimelineTelemetryItem] { timeline.effectiveTelemetryItems }
    private var effectItems: [EffectTimelineItem] { timeline.effectiveEffects }
    private var titleItems: [TitleTimelineItem] { timeline.effectiveTitleItems }
    private var pointsPerSecond: Double { min(64, max(6, zoom * Double(magnification))) }

    /// The project is only persisted when the gesture ends, but the magnetic
    /// storyline must use the proposed duration while the pointer is moving.
    /// This keeps the visible clip edge under the pointer and lets the HStack
    /// ripple every following clip immediately.
    private func previewDuration(for item: TimelineItem) -> Double {
        trimPreview?.itemID == item.id ? trimPreview?.timelineDuration ?? item.timelineDuration : item.timelineDuration
    }

    private var connectedLaneAssignments: [UUID: Int] {
        laneAssignments(
            connectedItems.map { ($0.id, $0.timelineStart, $0.timelineStart + $0.timelineDuration) }
        )
    }
    private var audioLaneAssignments: [UUID: Int] {
        laneAssignments(audioClips.map { ($0.id, $0.timelineStart, $0.timelineEnd) })
    }
    private var telemetryLaneAssignments: [UUID: Int] {
        laneAssignments(telemetryItems.map { ($0.id, $0.timelineStart, $0.timelineEnd) })
    }
    private var effectBlocks: [EffectTimelineBlock] {
        var blocks: [EffectTimelineBlock] = []
        var indices: [EffectTimelineGroupingKey: Int] = [:]
        for item in effectItems {
            let presetID = resolvedEffectStackPresetID(for: item)
            let key: EffectTimelineGroupingKey
            if let instanceID = item.effectStackPresetInstanceID {
                key = .presetInstance(instanceID)
            } else if let presetID {
                key = .legacyPreset(
                    presetID,
                    item.targetClipID,
                    Int64((item.startTime * 1_000).rounded()),
                    Int64((item.duration * 1_000).rounded())
                )
            } else {
                key = .standalone(item.id)
            }

            if let index = indices[key] {
                blocks[index].items.append(item)
            } else {
                indices[key] = blocks.count
                blocks.append(EffectTimelineBlock(
                    id: item.effectStackPresetInstanceID ?? item.id,
                    items: [item],
                    presetID: presetID
                ))
            }
        }
        return blocks
    }
    private var effectLaneAssignments: [UUID: Int] {
        laneAssignments(effectBlocks.map { ($0.id, $0.startTime, $0.endTime) })
    }
    private var titleLaneAssignments: [UUID: Int] {
        laneAssignments(titleItems.map { ($0.id, $0.startTime, $0.endTime) })
    }
    private var connectedLaneCount: Int { max(1, (connectedLaneAssignments.values.max() ?? 0) + 1) }
    private var audioLaneCount: Int { max(1, (audioLaneAssignments.values.max() ?? 0) + 1) }
    private var telemetryLaneCount: Int { max(1, (telemetryLaneAssignments.values.max() ?? 0) + 1) }
    private var effectLaneCount: Int { max(1, (effectLaneAssignments.values.max() ?? 0) + 1) }
    private var titleLaneCount: Int { max(1, (titleLaneAssignments.values.max() ?? 0) + 1) }

    private func resolvedEffectStackPresetID(for item: EffectTimelineItem) -> String? {
        if let presetID = item.effectStackPresetID,
           EffectStackPresetRegistry.preset(id: presetID) != nil {
            return presetID
        }
        return EffectStackPresetRegistry.all.first { preset in
            item.explanation.contains { $0.contains("Data-driven preset \(preset.name);") }
        }?.id
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
        }
        .onChange(of: brushEnabled) { _, enabled in
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
                .disabled(!model.canUndoTimelineEdit || model.isWorking)
                .help("Отменить правку (⌘Z)")
            Button(action: model.redoTimelineEdit) { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedoTimelineEdit || model.isWorking)
                .help("Повторить правку (⇧⌘Z)")

            Divider().frame(height: 18)

            Button(action: model.splitSelectedTimelineItem) { Image(systemName: "scissors") }
                .disabled(!model.canSplitTimelineSelectionAtPlayhead || model.isWorking)
                .help("Разделить выбранный объект в позиции playhead")
            Button(action: model.deleteSelectedTimelineItem) { Image(systemName: "trash") }
                .disabled(!model.hasTimelineSelection || model.isWorking)
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
        .disabled(model.selectedTimelineItem == nil || model.isWorking)
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
        .disabled(timeline.items.isEmpty || model.isWorking)
        .help("Добавить отдельный редактируемый эффект")
    }

    private var timelineScroller: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    ruler
                    if !titleItems.isEmpty { titleTrack }
                    if !connectedItems.isEmpty { connectedTrack }
                    primaryTrack
                    if !effectItems.isEmpty { effectsTrack }
                    if !telemetryItems.isEmpty { telemetryTrack }
                    if !audioClips.isEmpty { audioClipsTrack }
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

                playheadLine(time: model.timelinePlayheadTime, color: .white, isHover: false)
                if let hoverTime, let hoverX {
                    playheadLine(time: hoverTime, color: .yellow, isHover: true, exactX: hoverX)
                }
            }
            .frame(width: totalTimelineWidth, height: canvasHeight, alignment: .topLeading)
            .coordinateSpace(name: "timelineCanvas")
            .contentShape(Rectangle())
            .highPriorityGesture(canvasBrushGesture, including: brushEnabled ? .all : .none)
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named("timelineCanvas"))
                    .onEnded { value in
                        guard !brushEnabled, let time = timelineTime(at: value.location.x) else { return }
                        model.seekTimeline(to: snapped(time))
                    }
            )
            .dropDestination(for: String.self) { values, point in
                handleLibraryDrop(values, at: point)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard draggedItemID == nil, draggedConnectedID == nil, draggedAudioID == nil, draggedTelemetryID == nil,
                          draggedEffectID == nil, draggedTitleID == nil,
                          trimPreview == nil, let time = timelineTime(at: location.x) else { return }
                    hoverTime = time
                    hoverX = location.x
                case .ended:
                    hoverTime = nil
                    hoverX = nil
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
        .scrollIndicators(.visible)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.32))
    }

    private var canvasHeight: CGFloat {
        14 + 80 +
        (titleItems.isEmpty ? 0 : CGFloat(titleLaneCount * 31 + 3)) +
        (connectedItems.isEmpty ? 0 : CGFloat(connectedLaneCount * 31 + 5)) +
        (effectItems.isEmpty ? 0 : CGFloat(effectLaneCount * 31 + 3)) +
        (telemetryItems.isEmpty ? 0 : CGFloat(telemetryLaneCount * 31 + 3)) +
        (audioClips.isEmpty ? 0 : CGFloat(audioLaneCount * 31 + 3)) +
        (timeline.music == nil ? 0 : 32)
    }

    private var titleTrack: some View {
        ZStack(alignment: .leading) {
            ForEach(titleItems) { item in
                let selected = model.isTitleTimelineItemSelected(item.id)
                HStack(spacing: 6) {
                    Image(systemName: item.kind == .wordLevelCaptions ? "captions.bubble" : "textformat")
                    Text(item.text).lineLimit(1)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(width: regionWidth(item.duration), height: 28, alignment: .leading)
                .background(Color.purple.opacity(item.enabled ? 0.84 : 0.38), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.yellow : .white.opacity(0.14), lineWidth: selected ? 2 : 1) }
                .overlay(alignment: .leading) {
                    edgeTrimRegion(.leading) { translation in trimTitle(item, edge: .leading, translation: translation) }
                }
                .overlay(alignment: .trailing) {
                    edgeTrimRegion(.trailing) { translation in trimTitle(item, edge: .trailing, translation: translation) }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectTitleTimelineItem(item.id, modifiers: timelineSelectionModifiers)
                    model.openTimelineInspector()
                }
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named("timelineCanvas"))
                        .onChanged { value in
                            model.selectTitleTimelineItem(item.id)
                            draggedTitleID = item.id
                            titleDragTranslation = value.translation.width
                        }
                        .onEnded { value in
                            let target = snapped(item.startTime + Double(value.translation.width) / pointsPerSecond)
                            draggedTitleID = nil
                            titleDragTranslation = 0
                            model.moveTitleTimelineItem(item.id, to: target)
                        }
                )
                .offset(
                    x: xPosition(for: item.startTime) + (draggedTitleID == item.id ? titleDragTranslation : 0),
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
            ForEach(effectBlocks) { block in
                let item = block.primary
                let selected = block.itemIDs.allSatisfy(model.isEffectTimelineItemSelected)
                HStack(spacing: 6) {
                    Image(systemName: block.presetID == nil ? "wand.and.rays" : "square.stack.3d.up.fill")
                    Text(block.title).lineLimit(1)
                    if block.hasKeyframes { Image(systemName: "diamond.fill").font(.system(size: 7)) }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(width: regionWidth(block.duration), height: 28, alignment: .leading)
                .background(effectColor(block.category).opacity(block.isEnabled ? 0.84 : 0.36), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.yellow : .white.opacity(0.14), lineWidth: selected ? 2 : 1) }
                .overlay(alignment: .leading) {
                    edgeTrimRegion(.leading) { translation in trimEffect(block, edge: .leading, translation: translation) }
                }
                .overlay(alignment: .trailing) {
                    edgeTrimRegion(.trailing) { translation in trimEffect(block, edge: .trailing, translation: translation) }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectEffectTimelineItems(block.itemIDs, primaryID: item.id, modifiers: timelineSelectionModifiers)
                    model.openTimelineInspector()
                }
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named("timelineCanvas"))
                        .onChanged { value in
                            model.selectEffectTimelineItems(block.itemIDs, primaryID: item.id)
                            draggedEffectID = block.id
                            effectDragTranslation = value.translation.width
                        }
                        .onEnded { value in
                            let target = snapped(block.startTime + Double(value.translation.width) / pointsPerSecond)
                            draggedEffectID = nil
                            effectDragTranslation = 0
                            model.moveEffectTimelineItems(block.itemIDs, primaryID: item.id, to: target)
                        }
                )
                .offset(
                    x: xPosition(for: block.startTime) + (draggedEffectID == block.id ? effectDragTranslation : 0),
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
                .frame(width: lineWidth, height: max(80, canvasHeight - 2))
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
            ForEach(0...rulerTickCount, id: \.self) { index in
                let time = min(timeline.duration, Double(index) * rulerInterval)
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
                    model.seekTimeline(to: snapped(time))
                }
        )
    }

    private var connectedTrack: some View {
        ZStack(alignment: .leading) {
            ForEach(connectedItems) { item in
                let selected = model.isTimelineItemSelected(item.id)
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle")
                    Text(item.overlay?.style.localizedTitle ?? "B-roll")
                        .lineLimit(1)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(width: connectedClipWidth(item), height: 28, alignment: .leading)
                .background(Color.indigo.opacity(0.88), in: RoundedRectangle(cornerRadius: 6))
                .clipped()
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? Color.yellow : .clear, lineWidth: 2)
                }
                .overlay(alignment: .trailing) {
                    if hasModifiedSpeed(item) {
                        speedBadge(for: item, compact: true)
                            .padding(.trailing, 4)
                    }
                }
                .overlay(alignment: .leading) {
                    trimHandle(.leading, item: item, preview: nil)
                }
                .overlay(alignment: .trailing) {
                    trimHandle(.trailing, item: item, preview: nil)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.selectTimelineItem(item.id, modifiers: timelineSelectionModifiers) }
                .gesture(connectedDragGesture(for: item))
                .offset(
                    x: xPosition(for: item.timelineStart) +
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
            HStack(spacing: clipSpacing) {
                ForEach(Array(primaryItems.enumerated()), id: \.element.id) { index, item in
                    timelineClip(item, primaryIndex: index)
                }
            }
            .coordinateSpace(name: "primaryTimeline")
            .onPreferenceChange(TimelineClipFramePreferenceKey.self) { frames in
                if trimPreview == nil { clipFrames = frames }
            }

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
        ForEach(Array(primaryItems.dropFirst().filter { $0.transition != nil })) { item in
            Menu {
                if let transition = timeline.effectiveTransitionItems.first(where: { $0.incomingClipID == item.id }) {
                    Button("Настроить длительность", systemImage: "slider.horizontal.3") {
                        model.selectTransitionTimelineItem(transition.id)
                        model.openTimelineInspector()
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
            .offset(x: xPosition(for: item.timelineStart) - 9, y: 29)
            .zIndex(20)
            .help("Переход: \(TransitionStyle(rawValue: item.transition ?? "")?.localizedTitle ?? "Редактировать")")
        }
    }

    private var musicTrack: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
            Text(timeline.music?.trackTitle ?? timeline.music?.style.localizedTitle ?? "Музыка")
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            MontageWaveform(seed: timeline.id.uuidString, color: .white.opacity(0.72), barCount: min(160, max(24, Int(totalTimelineWidth / 6))))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .frame(width: totalTimelineWidth, height: 27, alignment: .leading)
        .background(Color.green.opacity(0.76), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(model.selectedSoundtrack ? Color.yellow : Color.white.opacity(0.12), lineWidth: model.selectedSoundtrack ? 2 : 1)
        }
        .overlay(alignment: .leading) {
            edgeTrimRegion(.leading) { translation in trimSoundtrack(edge: .leading, translation: translation) }
        }
        .overlay(alignment: .trailing) {
            edgeTrimRegion(.trailing) { translation in trimSoundtrack(edge: .trailing, translation: translation) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectSoundtrack(); model.openTimelineInspector() }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("timelineCanvas"))
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    model.selectSoundtrack()
                    soundtrackDragTranslation = value.translation.width
                }
                .onEnded { value in
                    let start = max(0, Double(value.translation.width) / pointsPerSecond)
                    soundtrackDragTranslation = 0
                    model.moveSoundtrack(toTimelineStart: snapped(start))
                }
        )
        .offset(x: soundtrackDragTranslation)
        .contextMenu {
            Menu("Громкость", systemImage: "speaker.wave.2") {
                ForEach([0.0, 0.1, 0.22, 0.35, 0.5, 0.75, 1.0], id: \.self) { volume in
                    Button("\(Int(volume * 100))%") { model.setMusicVolume(volume) }
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
            ForEach(audioClips) { clip in
                let selected = model.isTimelineAudioClipSelected(clip.id)
                HStack(spacing: 7) {
                    Image(systemName: clip.role == .music ? "music.note" : "waveform")
                    Text(clip.title)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                    MontageWaveform(
                        seed: clip.id.uuidString,
                        color: .white.opacity(0.72),
                        barCount: min(90, max(10, Int(audioClipWidth(clip) / 5)))
                    )
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(width: audioClipWidth(clip), height: 28, alignment: .leading)
                .background(audioColor(clip).opacity(0.82), in: RoundedRectangle(cornerRadius: 6))
                .clipped()
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? Color.yellow : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1)
                }
                .overlay(alignment: .leading) {
                    edgeTrimRegion(.leading) { translation in trimAudio(clip, edge: .leading, translation: translation) }
                }
                .overlay(alignment: .trailing) {
                    edgeTrimRegion(.trailing) { translation in trimAudio(clip, edge: .trailing, translation: translation) }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectTimelineAudioClip(clip.id, modifiers: timelineSelectionModifiers)
                    model.openTimelineInspector()
                }
                .gesture(audioDragGesture(for: clip))
                .offset(
                    x: xPosition(for: clip.timelineStart) +
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
            ForEach(telemetryItems) { item in
                let selected = model.isTelemetryItemSelected(item.id)
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                    Text(item.settings.resolvedWidgets.first?.kind.localizedTitle ?? "Телеметрия")
                        .font(.caption2.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(clock(item.timelineDuration)).font(.caption2.monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(width: max(42, CGFloat(item.timelineDuration * pointsPerSecond)), height: 28, alignment: .leading)
                .background(Color.cyan.opacity(0.78), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.yellow : Color.white.opacity(0.2), lineWidth: selected ? 2 : 1) }
                .overlay(alignment: .leading) {
                    edgeTrimRegion(.leading) { translation in trimTelemetry(item, edge: .leading, translation: translation) }
                }
                .overlay(alignment: .trailing) {
                    edgeTrimRegion(.trailing) { translation in trimTelemetry(item, edge: .trailing, translation: translation) }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectTelemetryItem(item.id, modifiers: timelineSelectionModifiers)
                    model.openTimelineInspector()
                }
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .named("timelineCanvas"))
                        .onChanged { value in
                            if draggedTelemetryID == nil { model.selectTelemetryItem(item.id); draggedTelemetryID = item.id }
                            telemetryDragTranslation = value.translation.width
                        }
                        .onEnded { value in
                            let requested = item.timelineStart + Double(value.translation.width) / pointsPerSecond
                            draggedTelemetryID = nil; telemetryDragTranslation = 0
                            model.moveTelemetryItem(item.id, toTimelineStart: snapped(requested))
                        }
                )
                .offset(x: xPosition(for: item.timelineStart) + (draggedTelemetryID == item.id ? telemetryDragTranslation : 0), y: CGFloat(telemetryLaneAssignments[item.id] ?? 0) * 31)
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

        return ZStack(alignment: .topLeading) {
            clipFilmstrip(item, width: width)
            if hasAudibleSource(item) {
                VStack {
                    Spacer()
                    HStack(spacing: 4) {
                        MontageWaveform(
                            seed: item.id.uuidString,
                            color: .white.opacity(0.82),
                            barCount: min(72, max(8, Int(width / 5)))
                        )
                        Image(systemName: "speaker.wave.1.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(.horizontal, 5)
                    .frame(height: 20)
                    .background(Color.blue.opacity(0.82))
                }
            }

            Text(item.title ?? clock(shownDuration))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 4))
                .padding(5)

            if hasModifiedSpeed(item) {
                speedBadge(for: item)
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

        }
        .frame(width: width, height: 76)
        .background(clipColor(item))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? Color.yellow : Color.white.opacity(0.13), lineWidth: selected ? 3 : 1)
        }
        .overlay(alignment: .leading) { trimHandle(.leading, item: item, preview: preview) }
        .overlay(alignment: .trailing) { trimHandle(.trailing, item: item, preview: preview) }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TimelineClipFramePreferenceKey.self,
                    value: [item.id: proxy.frame(in: .named("primaryTimeline"))]
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !brushEnabled else { return }
            model.selectTimelineItem(item.id, modifiers: timelineSelectionModifiers)
            if item.kind == .title { model.openTimelineInspector() }
        }
        .gesture(reorderGesture(for: item, primaryIndex: primaryIndex))
        .offset(x: (draggedItemID == item.id ? dragTranslation : 0) + magneticNeighborOffset(for: primaryIndex))
        .scaleEffect(draggedItemID == item.id ? 1.025 : 1)
        .shadow(color: .black.opacity(draggedItemID == item.id ? 0.28 : 0), radius: 7, y: 3)
        .zIndex(draggedItemID == item.id || selected ? 3 : 0)
        .contextMenu { clipContextMenu(item) }
    }

    private func hasModifiedSpeed(_ item: TimelineItem) -> Bool {
        item.kind == .video && abs(item.speed - 1) > 0.001
    }

    private func hasAudibleSource(_ item: TimelineItem) -> Bool {
        guard item.kind == .video,
              !item.effectiveAudioAdjustments.muted,
              let assetID = item.assetID else { return false }
        return model.project?.assets.first(where: { $0.id == assetID })?.metadata.hasAudio == true
    }

    private func speedBadge(for item: TimelineItem, compact: Bool = false) -> some View {
        Menu {
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
            .frame(height: compact ? 20 : 22)
            .background(.black.opacity(0.68), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 1) }
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
                  let asset = model.project?.assets.first(where: { $0.id == assetID }) {
            if let preset = BackgroundPreset.preset(for: asset) {
                HStack(spacing: 1) {
                    ForEach(0..<max(1, Int(ceil(width / 58))), id: \.self) { _ in
                        BackgroundPresetPreview(preset: preset)
                            .frame(width: 58, height: 58)
                    }
                }
            } else {
                HStack(spacing: 1) {
                    ForEach(0..<max(1, Int(ceil(width / 58))), id: \.self) { _ in
                        MontageTimelineThumbnail(
                            url: model.timelineThumbnailURLs[item.id] ?? model.thumbnailURLs[assetID],
                            kind: asset.kind
                        )
                        .frame(width: 58, height: 58)
                    }
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
                let proposedX = (clipFrames[item.id]?.midX ?? 0) + value.translation.width
                dropPrimaryIndex = nearestPrimaryIndex(to: proposedX) ?? primaryIndex
            }
            .onEnded { value in
                guard draggedItemID == item.id else { return }
                let proposedX = (clipFrames[item.id]?.midX ?? 0) + value.translation.width
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
                let requested = item.timelineStart + Double(value.translation.width) / pointsPerSecond
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
                let requested = clip.timelineStart + Double(value.translation.width) / pointsPerSecond
                draggedAudioID = nil
                audioDragTranslation = 0
                model.moveTimelineAudioClip(clip.id, toTimelineStart: snapped(requested))
            }
    }

    @ViewBuilder
    private func clipContextMenu(_ item: TimelineItem) -> some View {
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
            if item.assetID.flatMap({ id in model.project?.assets.first(where: { $0.id == id })?.metadata.hasAudio }) == true {
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

    private func containsPlayhead(_ item: TimelineItem) -> Bool {
        model.timelinePlayheadTime > item.timelineStart &&
        model.timelinePlayheadTime < item.timelineStart + item.timelineDuration
    }

    private func magneticNeighborOffset(for index: Int) -> CGFloat {
        guard let draggedID = draggedItemID,
              let source = primaryItems.firstIndex(where: { $0.id == draggedID }),
              let target = dropPrimaryIndex,
              source != target,
              let dragged = primaryItems.first(where: { $0.id == draggedID }) else { return 0 }
        let distance = clipWidth(dragged) + clipSpacing
        if source < target, index > source, index <= target { return -distance }
        if target < source, index >= target, index < source { return distance }
        return 0
    }

    private func insertionIndicatorX(for target: Int) -> CGFloat {
        guard primaryItems.indices.contains(target), let frame = clipFrames[primaryItems[target].id] else { return 0 }
        guard let draggedID = draggedItemID,
              let source = primaryItems.firstIndex(where: { $0.id == draggedID }) else { return frame.minX }
        return target > source ? frame.maxX : frame.minX
    }

    private func trimHandle(_ edge: TrimEdge, item: TimelineItem, preview: TrimPreview?) -> some View {
        Color.clear
            .frame(width: 14)
            .contentShape(Rectangle())
            .gesture(trimGesture(edge, item: item))
            .onContinuousHover { phase in
                if case .active = phase { NSCursor.resizeLeftRight.set() }
                else { NSCursor.arrow.set() }
            }
            .allowsHitTesting(!model.isWorking && !brushEnabled)
            .help(edge == .leading ? "Обрезать начало" : "Обрезать конец")
    }

    private func edgeTrimRegion(
        _ edge: TrimEdge,
        onEnded: @escaping (CGFloat) -> Void
    ) -> some View {
        Color.clear
            .frame(width: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("timelineCanvas"))
                    .onEnded { value in onEnded(value.translation.width) }
            )
            .onContinuousHover { phase in
                if case .active = phase { NSCursor.resizeLeftRight.set() }
                else { NSCursor.arrow.set() }
            }
            .allowsHitTesting(!model.isWorking && !brushEnabled)
            .help(edge == .leading ? "Обрезать или увеличить начало" : "Обрезать или увеличить конец")
    }

    private func trimTitle(_ item: TitleTimelineItem, edge: TrimEdge, translation: CGFloat) {
        let delta = Double(translation) / pointsPerSecond
        switch edge {
        case .leading:
            let applied = min(max(delta, -item.startTime), item.duration - 0.05)
            model.trimTitleTimelineItem(item.id, startTime: item.startTime + applied, duration: item.duration - applied)
        case .trailing:
            let duration = min(max(0.05, item.duration + delta), max(0.05, timeline.duration - item.startTime))
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
            let duration = min(max(0.05, block.duration + delta), max(0.05, timeline.duration - block.startTime))
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
            let duration = min(max(0.05, item.timelineDuration + delta), max(0.05, timeline.duration - item.timelineStart))
            model.trimTelemetryItem(item.id, timelineStart: item.timelineStart, duration: duration, sourceStart: item.sourceStart)
        }
    }

    private func trimAudio(_ clip: TimelineAudioClip, edge: TrimEdge, translation: CGFloat) {
        let delta = Double(translation) / pointsPerSecond
        let sourceLength = clip.assetID.flatMap { assetID in
            model.project?.assets.first(where: { $0.id == assetID })?.metadata.duration
        } ?? clip.trackID.flatMap { trackID in
            model.musicTracks.first(where: { $0.id == trackID })?.duration
        } ?? (clip.sourceStart + clip.sourceDuration)
        switch edge {
        case .leading:
            let applied = min(max(delta, -min(clip.timelineStart, clip.sourceStart)), clip.timelineDuration - 0.05)
            model.trimTimelineAudioClip(
                clip.id,
                timelineStart: clip.timelineStart + applied,
                sourceStart: clip.sourceStart + applied,
                duration: clip.timelineDuration - applied
            )
        case .trailing:
            let maximum = max(0.05, min(sourceLength - clip.sourceStart, timeline.duration - clip.timelineStart))
            model.trimTimelineAudioClip(clip.id, sourceStart: clip.sourceStart, duration: min(max(0.05, clip.timelineDuration + delta), maximum))
        }
    }

    private func trimSoundtrack(edge: TrimEdge, translation: CGFloat) {
        guard let trackID = timeline.music?.trackID,
              let sourceDuration = model.musicTracks.first(where: { $0.id == trackID })?.duration else { return }
        let delta = Double(translation) / pointsPerSecond
        switch edge {
        case .leading:
            let start = min(max(0, delta), max(0, timeline.duration - 0.05))
            model.trimSoundtrack(toTimelineStart: start, duration: min(sourceDuration, timeline.duration - start))
        case .trailing:
            let duration = min(sourceDuration, max(0.05, timeline.duration + delta))
            model.trimSoundtrack(toTimelineStart: 0, duration: duration)
        }
    }

    private func trimGesture(_ edge: TrimEdge, item: TimelineItem) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("timelineCanvas"))
            .onChanged { value in
                guard !brushEnabled else { return }
                model.selectTimelineItem(item.id)
                trimPreview = makeTrimPreview(item, edge: edge, translation: value.translation.width)
            }
            .onEnded { _ in
                guard let preview = trimPreview, preview.itemID == item.id, preview.edge == edge else { return }
                trimPreview = nil
                if abs(preview.sourceStart - item.sourceStart) > 0.001 ||
                    abs(preview.timelineDuration - item.timelineDuration) > 0.001 {
                    model.trimTimelineItem(id: item.id, sourceStart: preview.sourceStart, timelineDuration: preview.timelineDuration)
                }
            }
    }

    private func makeTrimPreview(_ item: TimelineItem, edge: TrimEdge, translation: CGFloat) -> TrimPreview {
        // Keep the proposed edge at the exact pointer coordinate while the
        // gesture is active. Frame quantization here made the handle lag in
        // visible steps, and a local coordinate space became unstable because
        // the clip itself changes width during the drag.
        let requestedDelta = Double(translation) / pointsPerSecond
        switch edge {
        case .leading:
            let minimumDelta = item.kind == .video ? -item.sourceStart / item.speed : -3_600
            let delta = min(max(requestedDelta, minimumDelta), item.timelineDuration - 0.25)
            return TrimPreview(
                itemID: item.id,
                edge: edge,
                sourceStart: item.kind == .video ? item.sourceStart + delta * item.speed : item.sourceStart,
                timelineDuration: item.timelineDuration - delta
            )
        case .trailing:
            let maximum: Double
            if item.kind == .video {
                maximum = item.assetID.flatMap { id in
                    model.project?.assets.first(where: { $0.id == id })?.metadata.duration
                }.map { max(0.25, ($0 - item.sourceStart) / item.speed) } ?? item.timelineDuration
            } else {
                // Photos and generated backgrounds have no source-media end.
                // Their video representation is regenerated to the requested
                // timeline duration, so the trailing edge is intentionally unlimited.
                maximum = .greatestFiniteMagnitude
            }
            let duration = min(max(0.25, item.timelineDuration + requestedDelta), maximum)
            return TrimPreview(
                itemID: item.id,
                edge: edge,
                sourceStart: item.sourceStart,
                timelineDuration: duration
            )
        }
    }

    private func handleLibraryDrop(_ values: [String], at point: CGPoint) -> Bool {
        guard !model.isWorking, let raw = values.first else { return false }
        let time = timelineTime(at: point.x).map(snapped) ?? 0

        if raw.hasPrefix("background:"),
           let preset = BackgroundPreset(rawValue: String(raw.dropFirst("background:".count))) {
            model.insertBackgroundIntoTimeline(preset, at: insertionIndex(at: point.x))
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
            model.insertAssetIntoTimeline(assetID, at: insertionIndex(at: point.x))
            return true
        }
        return false
    }

    private func timelineTime(at x: CGFloat) -> Double? {
        guard !primaryItems.isEmpty else { return nil }
        let location = max(0, x)
        for (index, item) in primaryItems.enumerated() {
            let startX = CGFloat(item.timelineStart * pointsPerSecond) + CGFloat(index) * clipSpacing
            let endX = startX + clipWidth(item)
            if location <= endX {
                return min(
                    timeline.duration,
                    item.timelineStart + Double(max(0, location - startX)) / pointsPerSecond
                )
            }
            if index < primaryItems.count - 1, location < endX + clipSpacing {
                return min(timeline.duration, item.timelineStart + item.timelineDuration)
            }
        }
        return timeline.duration
    }

    private func snapped(_ time: Double) -> Double {
        let threshold = 8 / pointsPerSecond
        var boundaries = primaryItems.flatMap { [$0.timelineStart, $0.timelineStart + $0.timelineDuration] }
        boundaries.append(contentsOf: connectedItems.flatMap { [$0.timelineStart, $0.timelineStart + $0.timelineDuration] })
        boundaries.append(contentsOf: telemetryItems.flatMap { [$0.timelineStart, $0.timelineEnd] })
        boundaries.append(contentsOf: audioClips.flatMap { [$0.timelineStart, $0.timelineEnd] })
        boundaries.append(model.timelinePlayheadTime)
        if let nearest = boundaries.min(by: { abs($0 - time) < abs($1 - time) }), abs(nearest - time) <= threshold {
            return min(max(0, nearest), timeline.duration)
        }
        return min(TimelineTiming.quantized(time, frameRate: timeline.frameRate), timeline.duration)
    }

    private func nearestPrimaryIndex(to x: CGFloat) -> Int? {
        primaryItems.indices.min {
            let left = clipFrames[primaryItems[$0].id]?.midX ?? 0
            let right = clipFrames[primaryItems[$1].id]?.midX ?? 0
            return abs(left - x) < abs(right - x)
        }
    }

    private func insertionIndex(at x: CGFloat) -> Int {
        guard let index = nearestPrimaryIndex(to: x) else { return timeline.items.count }
        let item = primaryItems[index]
        let base = timeline.items.firstIndex(where: { $0.id == item.id }) ?? timeline.items.count
        return x > (clipFrames[item.id]?.midX ?? x) ? min(timeline.items.count, base + 1) : base
    }

    private func clipWidth(_ item: TimelineItem, duration: Double? = nil) -> CGFloat {
        max(1, CGFloat((duration ?? item.timelineDuration) * pointsPerSecond))
    }

    private func audioClipWidth(_ clip: TimelineAudioClip) -> CGFloat {
        max(1, CGFloat(clip.timelineDuration * pointsPerSecond))
    }

    private func regionWidth(_ duration: Double) -> CGFloat {
        max(28, CGFloat(duration * pointsPerSecond))
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

    private func connectedClipWidth(_ item: TimelineItem) -> CGFloat {
        let visible = min(item.timelineDuration, max(0.05, timeline.duration - item.timelineStart))
        return max(1, CGFloat(visible * pointsPerSecond))
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
        let visibleDuration = max(timeline.duration, timeline.duration + previewDelta)
        return max(320, CGFloat(visibleDuration * pointsPerSecond) + gaps)
    }

    private func xPosition(for time: Double) -> CGFloat {
        let clamped = min(max(0, time), timeline.duration)
        let epsilon = 0.000_001
        var completedBoundaries = 0
        var isOnBoundary = false
        for item in primaryItems.dropLast() {
            let boundary = item.timelineStart + item.timelineDuration
            if clamped > boundary + epsilon {
                completedBoundaries += 1
            } else if abs(clamped - boundary) <= epsilon {
                isOnBoundary = true
                break
            } else {
                break
            }
        }
        let gapOffset = CGFloat(completedBoundaries) * clipSpacing + (isOnBoundary ? clipSpacing / 2 : 0)
        return CGFloat(clamped * pointsPerSecond) + gapOffset
    }

    private var rulerInterval: Double {
        if pointsPerSecond >= 42 { return 1 }
        if pointsPerSecond >= 20 { return 2 }
        if pointsPerSecond >= 10 { return 5 }
        return 10
    }

    private var rulerTickCount: Int {
        max(1, Int(ceil(timeline.duration / rulerInterval)))
    }

    private func laneAssignments(_ regions: [(id: UUID, start: Double, end: Double)]) -> [UUID: Int] {
        var laneEnds: [Double] = []
        var result: [UUID: Int] = [:]
        for region in regions.sorted(by: { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }) {
            if let lane = laneEnds.firstIndex(where: { $0 <= region.start + 0.0001 }) {
                laneEnds[lane] = region.end
                result[region.id] = lane
            } else {
                result[region.id] = laneEnds.count
                laneEnds.append(region.end)
            }
        }
        return result
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

private struct TimelineClipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct MontageWaveform: View {
    let seed: String
    let color: Color
    let barCount: Int

    var body: some View {
        HStack(alignment: .center, spacing: 1) {
            ForEach(0..<max(1, barCount), id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: amplitude(index))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
    }

    private func amplitude(_ index: Int) -> CGFloat {
        let base = seed.utf8.reduce(0) { ($0 + Int($1)) % 997 }
        let value = (base + index * 37 + index * index * 11) % 100
        return 3 + CGFloat(value) / 100 * 13
    }
}

private struct MontageTimelineThumbnail: View {
    let url: URL?
    let kind: MediaKind

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.18)
                    Image(systemName: kind == .video ? "video.fill" : "photo.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipped()
    }
}
