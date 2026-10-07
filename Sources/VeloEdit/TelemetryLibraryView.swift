import SwiftUI
import VeloEditCore

/// Stable local payload used by both the OVRLEY card browser and Timeline.
struct TelemetryPresetDragPayload: Equatable {
    static let prefix = "telemetry-preset|"
    var kind: TelemetryWidgetKind
    var presentation: TelemetryWidgetPresentation
    var style: TelemetryWidgetStyle

    var stringValue: String {
        ["telemetry-preset", kind.rawValue, presentation.rawValue, style.rawValue]
            .joined(separator: "|")
    }

    init(kind: TelemetryWidgetKind, presentation: TelemetryWidgetPresentation, style: TelemetryWidgetStyle) {
        self.kind = kind
        self.presentation = presentation
        self.style = style
    }

    init?(_ rawValue: String) {
        let fields = rawValue.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard (fields.count == 4 || fields.count == 5), fields[0] == "telemetry-preset" else { return nil }
        let offset = fields.count == 5 ? 1 : 0 // Accept drags from the previous source-bound browser.
        guard let kind = TelemetryWidgetKind(rawValue: fields[1 + offset]),
              let presentation = TelemetryWidgetPresentation(rawValue: fields[2 + offset]),
              let style = TelemetryWidgetStyle(rawValue: fields[3 + offset]) else { return nil }
        self.kind = kind
        self.presentation = presentation
        self.style = style
    }
}

struct TelemetryLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedCategory: TelemetryWidgetCategory = .general
    @State private var selectedStyle: TelemetryWidgetStyle = .acidTitanium
    @State private var search = ""
    @State private var sourcesExpanded = true
    @State private var mappingSource: TelemetrySource?

    private var sources: [TelemetrySource] { model.project?.effectiveTelemetrySources ?? [] }
    private var targetSource: TelemetrySource? {
        guard let assetID = model.telemetryTargetClip?.assetID else { return nil }
        return TelemetrySourceSelector().bestGeneralSource(linkedAssetID: assetID, sources: sources)
    }
    private var visibleKinds: [TelemetryWidgetKind] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return TelemetryWidgetKind.catalogueKinds.filter { kind in
            guard !model.availableTelemetryPresentations(for: kind).isEmpty else { return false }
            if query.isEmpty { return kind.category == selectedCategory }
            let searchable = [
                kind.localizedTitle,
                kind.rawValue,
                kind.category.localizedTitle
            ] + kind.supportedPresentations.flatMap { [$0.localizedTitle, $0.rawValue] }
            return searchable.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 13, pinnedViews: [.sectionHeaders]) {
                sourcePanel
                styleStrip
                categoryStrip
                if visibleKinds.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? "Нет доступных данных в этой категории" : "Ничего не найдено",
                        systemImage: search.isEmpty ? "waveform.slash" : "magnifyingglass"
                    )
                        .padding(.top, 20)
                } else {
                    ForEach(visibleKinds) { kind in
                        widgetGroup(kind)
                    }
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollBounceBehavior(.always, axes: .vertical)
        .background(Color(nsColor: .controlBackgroundColor))
        .task { await model.refreshEmbeddedTelemetryIfNeeded() }
        .sheet(item: $mappingSource) { source in
            TelemetryCSVMappingView(source: source)
                .environmentObject(model)
        }
    }

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("OVRLEY WIDGETS")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.orange)
                    Text("Перетащите карточку на ролик или кадр")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("В карточках — примеры. На видео — данные выбранного ролика.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(action: model.chooseMedia) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Импортировать GPX, FIT, SRT, CSV, VBO или видео")
            }
            if targetSource?.format == .embeddedQuickTime {
                Text("В ролике сохранено только место съёмки. Для скорости и маршрута импортируйте GPS-трек.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sourceManager: some View {
        DisclosureGroup(isExpanded: $sourcesExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                if sources.isEmpty {
                    Text("Импортируйте FIT, GPX, SRT, CSV/VBO или видео с GPMF.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 5)
                } else {
                    ForEach(sources) { source in
                        sourceCard(source)
                    }
                }
            }
            .padding(.top, 7)
        } label: {
            HStack {
                Label("IMPORT TELEMETRY", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.bold))
                Spacer()
                Text("\(sources.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }

    private func sourceCard(_ source: TelemetrySource) -> some View {
        let kinds = source.summary.availableWidgetKinds
        let linkedToTarget = source.linkedAssetID == model.telemetryTargetClip?.assetID
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.displayName).font(.caption.weight(.semibold)).lineLimit(1)
                    Text("\(source.format.localizedTitle) · \(source.summary.sampleCount) отсчётов · 00:00—\(clock(source.duration))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if linkedToTarget {
                    Image(systemName: "link.circle.fill").foregroundStyle(.green)
                }
            }
            HStack(spacing: 4) {
                availabilityBadge("GPS", available: source.summary.supports(.routeMap, presentation: .routePlot))
                availabilityBadge("SPD", available: source.summary.supports(.speedValue, presentation: .text))
                availabilityBadge("ALT", available: source.summary.supports(.altitude, presentation: .text))
                Text(kinds.prefix(3).map(\.localizedTitle).joined(separator: " · "))
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 7) {
                Button(linkedToTarget ? "Привязан" : "К выбранному видео") {
                    model.attachTelemetrySourceToSelectedClip(source.id)
                }
                .disabled(linkedToTarget || model.telemetryTargetClip == nil)
                Button("Авто sync") { model.automaticallySynchronizeTelemetrySource(source.id) }
                    .disabled(source.linkedAssetID == nil && model.telemetryTargetClip == nil)
                Spacer(minLength: 0)
                Text(source.synchronization.method.localizedTitle)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            if source.format == .csv,
               source.summary.timedSamples?.contains(where: { $0.customFields?.isEmpty == false }) == true {
                Button("Сопоставить столбцы CSV", systemImage: "tablecells") {
                    mappingSource = source
                }
                .font(.caption2)
            }
            Stepper(
                "Offset \(source.synchronization.offsetSeconds, specifier: "%+.3f") с",
                value: Binding(
                    get: { source.synchronization.offsetSeconds },
                    set: { model.setTelemetrySourceOffset(source.id, offset: $0) }
                ),
                in: -3600...3600,
                step: 1.0 / max(1, source.synchronization.frameRate ?? 30)
            )
            .font(.system(size: 9, design: .monospaced))
        }
        .padding(8)
        .background(linkedToTarget ? Color.green.opacity(0.07) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    private func availabilityBadge(_ text: String, available: Bool) -> some View {
        Text(text)
            .font(.system(size: 7, weight: .bold, design: .monospaced))
            .foregroundStyle(available ? Color.green : Color.secondary.opacity(0.55))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background((available ? Color.green : Color.secondary).opacity(0.10), in: Capsule())
    }

    private func clock(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private var styleStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("ОРИГИНАЛЬНЫЕ СТИЛИ")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(TelemetryWidgetStyle.ovrleyTemplates.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 7)], alignment: .leading, spacing: 7) {
                ForEach(TelemetryWidgetStyle.ovrleyTemplates) { style in
                    Button {
                        selectedStyle = style
                    } label: {
                        let palette = TelemetryArtworkPalette(style)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 3) {
                                Circle().fill(palette.accent).frame(width: 7, height: 7)
                                Rectangle().fill(palette.foreground).frame(width: 20, height: 3)
                            }
                            Text(style.localizedTitle)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .lineLimit(1)
                        }
                        .foregroundStyle(palette.foreground)
                        .padding(7)
                        .frame(maxWidth: .infinity, minHeight: 47, alignment: .leading)
                        .background(palette.canvas, in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(selectedStyle == style ? Color.orange : Color.white.opacity(0.10), lineWidth: selectedStyle == style ? 2 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var categoryStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 5)], alignment: .leading, spacing: 5) {
            ForEach(TelemetryWidgetCategory.allCases) { category in
                Button(category.localizedTitle) { selectedCategory = category }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selectedCategory == category ? Color.white : Color.primary)
                    .background(selectedCategory == category ? Color.orange : Color.primary.opacity(0.07), in: Capsule())
            }
        }
    }

    private func widgetGroup(_ kind: TelemetryWidgetKind) -> some View {
        let presentations = model.availableTelemetryPresentations(for: kind)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: kind.symbolName)
                    .foregroundStyle(.cyan)
                Text(kind.localizedTitle)
                    .font(.caption.weight(.bold))
                Spacer()
                Text("\(presentations.count) вариантов")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                ForEach(presentations) { presentation in
                    widgetCard(kind: kind, presentation: presentation)
                }
            }
        }
    }

    private func widgetCard(kind: TelemetryWidgetKind, presentation: TelemetryWidgetPresentation) -> some View {
        let payload = TelemetryPresetDragPayload(kind: kind, presentation: presentation, style: selectedStyle)
        let canInsert = model.canInsertTelemetryPreset(kind: kind, presentation: presentation)
        return LibraryItemButton {
            model.insertTelemetryPreset(kind: kind, presentation: presentation, style: selectedStyle)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                TelemetryWidgetArtwork(kind: kind, presentation: presentation, style: selectedStyle)
                    .frame(height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: canInsert ? "plus.circle.fill" : "eye")
                            .font(.caption)
                            .foregroundStyle(.white, canInsert ? .orange : .gray)
                            .padding(5)
                    }
                Text(presentation.localizedTitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(5)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(!canInsert)
        .libraryDraggable(payload.stringValue)
        .help(canInsert ? "Добавить на выбранный фрагмент или перетащить" : "В выбранном фрагменте нет этих данных")
    }
}

private struct TelemetryCSVMappingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let source: TelemetrySource
    @State private var mapping: [String: TelemetryCSVField]

    init(source: TelemetrySource) {
        self.source = source
        let keys = Set(source.summary.timedSamples?.flatMap { $0.customFields?.keys.map { $0 } ?? [] } ?? [])
        _mapping = State(initialValue: Dictionary(uniqueKeysWithValues: keys.map { ($0, .ignore) }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Сопоставление CSV").font(.title3.weight(.semibold))
            Text("Выберите значение для нестандартных столбцов. Исходные числа останутся в custom fields без потерь.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(mapping.keys.sorted(), id: \.self) { column in
                        HStack {
                            Text(column).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { mapping[column] ?? .ignore },
                                set: { mapping[column] = $0 }
                            )) {
                                ForEach(TelemetryCSVField.allCases) { field in
                                    Text(field.localizedTitle).tag(field)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 210)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Применить") {
                    model.applyCSVTelemetryMapping(source.id, mapping: mapping)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!mapping.values.contains { $0 != .ignore })
            }
        }
        .padding(18)
        .frame(width: 520, height: 420)
    }
}

struct TelemetryCanvasEditor: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineTelemetryItem
    @State private var drag: CGSize = .zero
    @State private var resize: CGSize = .zero

    private var layout: TelemetryWidgetLayout {
        item.settings.resolvedWidgets.first ?? .defaultLayout(for: .speedValue)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let baseWidth = max(52, CGFloat(layout.width) * width)
            let baseHeight = max(38, CGFloat(layout.height) * height)
            let shownWidth = max(52, baseWidth + resize.width)
            let shownHeight = max(38, baseHeight + resize.height)
            let left = CGFloat(layout.x) * width + drag.width
            let top = (1 - CGFloat(layout.y) - CGFloat(layout.height)) * height + drag.height

            Color.clear
                .frame(width: shownWidth, height: shownHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
                .overlay(alignment: .topLeading) {
                    Text("OVRLEY · \(layout.effectivePresentation.localizedTitle)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(.orange, in: Capsule())
                        .offset(y: -16)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.white)
                        .background(.orange, in: Circle())
                        .offset(x: 7, y: 7)
                        .gesture(resizeGesture(canvas: geometry.size))
                }
                .contentShape(Rectangle())
                .gesture(moveGesture(canvas: geometry.size))
                .offset(x: left, y: top)
        }
    }

    private func moveGesture(canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { drag = $0.translation }
            .onEnded { value in
                let x = min(max(0, layout.x + Double(value.translation.width / max(1, canvas.width))), 1 - layout.width)
                let y = min(max(0, layout.y - Double(value.translation.height / max(1, canvas.height))), 1 - layout.height)
                drag = .zero
                model.setSelectedTelemetryLayoutFrame(x: x, y: y, width: layout.width, height: layout.height)
            }
    }

    private func resizeGesture(canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { resize = $0.translation }
            .onEnded { value in
                let deltaWidth = Double(value.translation.width / max(1, canvas.width))
                let deltaHeight = Double(value.translation.height / max(1, canvas.height))
                let width = min(max(0.08, layout.width + deltaWidth), 1 - layout.x)
                let height = min(max(0.06, layout.height + deltaHeight), 1)
                let y = min(max(0, layout.y - (height - layout.height)), 1 - height)
                resize = .zero
                model.setSelectedTelemetryLayoutFrame(x: layout.x, y: y, width: width, height: height)
            }
    }
}

struct TelemetryWidgetArtwork: View {
    let kind: TelemetryWidgetKind
    let presentation: TelemetryWidgetPresentation
    let style: TelemetryWidgetStyle

    @State private var previewImage: CGImage?

    private var palette: TelemetryArtworkPalette { TelemetryArtworkPalette(style) }
    private var sample: (value: String, unit: String) { kind.previewValue }

    var body: some View {
        GeometryReader { geometry in
            let request = TelemetryPreviewCache.Request(kind: kind, presentation: presentation,
                                                       style: style, size: geometry.size)
            ZStack {
                palette.canvas
                if let previewImage {
                    Image(decorative: previewImage, scale: 1)
                        .resizable()
                        .scaledToFit()
                }
            }
            .clipped()
            .task(id: request) {
                previewImage = nil
                let image = await TelemetryPreviewCache.shared.image(for: request)
                guard !Task.isCancelled else { return }
                previewImage = image
            }
        }
        .accessibilityLabel("\(kind.localizedTitle), \(presentation.localizedTitle), \(style.localizedTitle)")
    }

    @ViewBuilder
    private func presentationArtwork(in size: CGSize) -> some View {
        switch presentation {
        case .text:
            metricValue(size: size)
        case .linear, .linearSegmented:
            VStack(spacing: size.height * 0.08) {
                gaugeBar(segmented: presentation == .linearSegmented)
                    .frame(width: size.width * 0.72, height: max(7, size.height * 0.12))
                metricValue(size: CGSize(width: size.width, height: size.height * 0.64))
            }
        case .arc, .arcReverse:
            ZStack {
                ArcGaugeShape(progress: 1, reverse: presentation == .arcReverse)
                    .stroke(Color.white.opacity(0.17), style: StrokeStyle(lineWidth: max(7, size.width * 0.075), lineCap: .round))
                ArcGaugeShape(progress: 0.66, reverse: presentation == .arcReverse)
                    .stroke(palette.accent, style: StrokeStyle(lineWidth: max(7, size.width * 0.075), lineCap: .round))
                metricValue(size: CGSize(width: size.width * 0.72, height: size.height * 0.60))
                    .offset(y: size.height * 0.05)
            }
            .padding(size.width * 0.10)
        case .arcSegmented, .arcSegmentedDense:
            ZStack {
                segmentedArc(count: presentation == .arcSegmented ? 22 : 34, size: size)
                metricValue(size: CGSize(width: size.width * 0.72, height: size.height * 0.58))
                    .offset(y: size.height * 0.05)
            }
        case .corner:
            ZStack(alignment: .bottomLeading) {
                CornerGaugeShape(progress: 1).stroke(Color.white.opacity(0.17), style: StrokeStyle(lineWidth: max(7, size.width * 0.07), lineCap: .round, lineJoin: .round))
                CornerGaugeShape(progress: 0.64).stroke(palette.accent, style: StrokeStyle(lineWidth: max(7, size.width * 0.07), lineCap: .round, lineJoin: .round))
                metricValue(size: CGSize(width: size.width * 0.70, height: size.height * 0.60)).padding(.leading, size.width * 0.17).padding(.bottom, size.height * 0.06)
            }
            .padding(size.width * 0.12)
        case .headingTape:
            headingTape(size)
        case .gForce:
            gForceArtwork(size)
        case .leanAngle:
            ZStack {
                ArcGaugeShape(progress: 1, reverse: false).stroke(Color.white.opacity(0.17), lineWidth: max(8, size.width * 0.10))
                ArcGaugeShape(progress: 0.58, reverse: false).stroke(palette.accent, style: StrokeStyle(lineWidth: max(8, size.width * 0.10), lineCap: .round))
                metricValue(size: CGSize(width: size.width * 0.72, height: size.height * 0.58))
            }.padding(size.width * 0.10)
        case .lapCurrent, .lapBest, .lapDelta:
            VStack(spacing: 2) {
                Text(presentation == .lapCurrent ? "CURRENT LAP" : presentation == .lapBest ? "BEST LAP" : "DELTA")
                    .font(.system(size: max(7, size.height * 0.12), weight: .bold, design: .rounded))
                    .foregroundStyle(palette.accent)
                Text(presentation == .lapDelta ? "−0.82" : "01:42.36")
                    .font(.system(size: max(16, size.height * 0.30), weight: .black, design: .monospaced))
                    .foregroundStyle(palette.foreground)
            }
        case .lapLog:
            VStack(alignment: .leading, spacing: 3) {
                Text("LAP LOG").foregroundStyle(palette.accent)
                Text("03   01:42.36").foregroundStyle(palette.foreground)
                Text("02   01:43.18").foregroundStyle(palette.foreground.opacity(0.78))
                Text("01   01:45.02").foregroundStyle(palette.foreground.opacity(0.58))
            }
            .font(.system(size: max(7, size.height * 0.11), weight: .bold, design: .monospaced))
        case .routePlot:
            ZStack(alignment: .bottomTrailing) {
                RoutePreviewShape().stroke(palette.foreground, style: StrokeStyle(lineWidth: max(2, size.width * 0.022), lineCap: .round, lineJoin: .round)).padding(size.width * 0.10)
                if style == .whiteVAM {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("VAM").font(.system(size: max(7, size.height * 0.12), weight: .bold))
                        HStack(alignment: .lastTextBaseline, spacing: 2) {
                            Text("1008").font(.system(size: max(15, size.height * 0.28), weight: .black, design: .rounded))
                            Text("M/H").font(.system(size: max(6, size.height * 0.08), weight: .bold))
                        }
                    }.foregroundStyle(palette.foreground).padding(size.width * 0.08)
                }
            }
        case .elevationPlot:
            ZStack(alignment: .bottom) {
                ElevationPreviewShape().fill(LinearGradient(colors: [palette.accent.opacity(0.34), .clear], startPoint: .bottom, endPoint: .top)).padding(size.width * 0.08)
                ElevationPreviewShape().stroke(palette.accent, style: StrokeStyle(lineWidth: max(2, size.width * 0.018), lineCap: .round, lineJoin: .round)).padding(size.width * 0.08)
                Text("842 M").font(.system(size: max(8, size.height * 0.12), weight: .bold, design: .rounded)).foregroundStyle(palette.foreground).padding(.bottom, 4)
            }
        }
    }

    private func metricValue(size: CGSize) -> some View {
        VStack(spacing: -2) {
            Text(kind.previewLabel)
                .font(.system(size: max(6, size.height * 0.13), weight: .bold, design: .rounded))
                .foregroundStyle(palette.accent)
                .lineLimit(1)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(sample.value)
                    .font(.system(size: max(15, size.height * 0.38), weight: .black, design: style == .acidTitanium || style == .futuristicHUD ? .monospaced : .rounded))
                    .minimumScaleFactor(0.45)
                    .lineLimit(1)
                Text(sample.unit)
                    .font(.system(size: max(6, size.height * 0.11), weight: .bold, design: .rounded))
            }
            .foregroundStyle(palette.foreground)
        }
    }

    private func gaugeBar(segmented: Bool) -> some View {
        GeometryReader { geometry in
            if segmented {
                HStack(spacing: 2) {
                    ForEach(0..<18, id: \.self) { index in
                        Rectangle().fill(index < 12 ? palette.accent : Color.white.opacity(0.17))
                    }
                }
            } else {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.17))
                    Capsule().fill(palette.accent).frame(width: geometry.size.width * 0.66)
                }
            }
        }
    }

    private func segmentedArc(count: Int, size: CGSize) -> some View {
        ZStack {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index < Int(Double(count) * 0.66) ? palette.accent : Color.white.opacity(0.17))
                    .frame(width: max(2, size.width * 0.026), height: max(8, size.width * 0.11))
                    .offset(y: -size.height * 0.31)
                    .rotationEffect(.degrees(-120 + Double(index) / Double(max(1, count - 1)) * 240))
            }
        }
    }

    private func headingTape(_ size: CGSize) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(["315", "330", "NW", "000", "015", "030", "NE"], id: \.self) { value in
                    VStack(spacing: 2) {
                        Text(value)
                        Rectangle().frame(width: value == "000" ? 2 : 1, height: value == "000" ? 15 : 9)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(value == "000" ? palette.accent : palette.foreground.opacity(0.72))
                }
            }
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .black)).foregroundStyle(palette.accent)
        }
        .font(.system(size: max(6, size.height * 0.10), weight: .bold, design: .monospaced))
        .padding(.horizontal, size.width * 0.05)
    }

    private func gForceArtwork(_ size: CGSize) -> some View {
        ZStack {
            Circle().stroke(palette.foreground.opacity(0.35), lineWidth: 1.5)
            Rectangle().fill(palette.foreground.opacity(0.28)).frame(width: 1)
            Rectangle().fill(palette.foreground.opacity(0.28)).frame(height: 1)
            Circle().fill(palette.accent).frame(width: size.width * 0.12).offset(x: size.width * 0.13, y: -size.height * 0.08)
            Text("1.2 G").font(.system(size: max(8, size.height * 0.12), weight: .black, design: .monospaced)).foregroundStyle(palette.foreground).offset(y: size.height * 0.27)
        }.padding(size.width * 0.15)
    }

    @ViewBuilder
    private var decorativeBackdrop: some View {
        switch style {
        case .futuristicHUD:
            RoundedRectangle(cornerRadius: 5).stroke(palette.accent.opacity(0.22), lineWidth: 1).padding(3)
        case .lavenderGradient:
            LinearGradient(colors: [Color.purple.opacity(0.18), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .champagneBorders:
            RoundedRectangle(cornerRadius: 6).stroke(palette.accent.opacity(0.65), lineWidth: 1).padding(4)
        default:
            EmptyView()
        }
    }
}

struct TelemetryArtworkPalette {
    var foreground: Color
    var accent: Color
    var canvas: Color

    init(_ style: TelemetryWidgetStyle) {
        switch style {
        case .acidTitanium: self.init(foreground: .hex(0xDCE2E8), accent: .hex(0xD6FF40), canvas: .hex(0x081015))
        case .breezeBlue: self.init(foreground: .white, accent: .hex(0xD4E8FF), canvas: .hex(0x0B2C4A))
        case .burntOrange: self.init(foreground: .white, accent: .hex(0xE85D00), canvas: .hex(0x170A04))
        case .champagneBasic: self.init(foreground: .hex(0xFFF3C9), accent: .hex(0xFFF1D4), canvas: .hex(0x171510))
        case .champagneBorders: self.init(foreground: .hex(0xFFF7E6), accent: .hex(0xFFF7E6), canvas: .hex(0x15110A))
        case .champagneShadows: self.init(foreground: .hex(0xFFF7E6), accent: .hex(0xFFF7E6), canvas: .black)
        case .futuristicHUD: self.init(foreground: .hex(0xD1FEFF), accent: .hex(0x65EBFC), canvas: .hex(0x002735))
        case .lavenderGradient: self.init(foreground: .hex(0xE4CFFA), accent: .hex(0xD3BCF7), canvas: .hex(0x251A35))
        case .safaBrian, .whiteVAM: self.init(foreground: .white, accent: .white, canvas: .black)
        case .whiteOpacity: self.init(foreground: .white, accent: .white.opacity(0.82), canvas: .black.opacity(0.88))
        case .whiteShadows: self.init(foreground: .white, accent: .hex(0xC9FFE7), canvas: .black)
        case .racing: self.init(foreground: .white, accent: .red, canvas: .black)
        case .action, .goPro: self.init(foreground: .white, accent: .cyan, canvas: .black)
        case .cinematic: self.init(foreground: .white, accent: .orange, canvas: .black)
        case .cleanApple, .minimal: self.init(foreground: .white, accent: .white, canvas: .black)
        case .digital: self.init(foreground: .green, accent: .green, canvas: .black)
        case .circular, .horizontal, .compact: self.init(foreground: .white, accent: .cyan, canvas: .black)
        }
    }

    init(foreground: Color, accent: Color, canvas: Color) {
        self.foreground = foreground
        self.accent = accent
        self.canvas = canvas
    }
}

private extension TelemetryWidgetKind {
    var previewValue: (value: String, unit: String) {
        switch self {
        case .speedometer, .speedValue, .speedBar: return ("38", "KM/H")
        case .power, .enginePower: return ("322", "W")
        case .heartRate: return ("148", "BPM")
        case .cadence: return ("92", "RPM")
        case .altitude: return ("842", "M")
        case .gForce, .gForceXY: return ("1.2", "G")
        case .acceleration: return ("3.8", "M/S²")
        case .rpm: return ("6840", "RPM")
        case .throttle: return ("76", "%")
        case .brake: return ("34", "%")
        case .leanAngle: return ("42", "°")
        case .lapTimer: return ("01:42", "")
        case .lapCounter: return ("03", "LAP")
        case .heading, .compass: return ("NW", "318°")
        case .distance: return ("24.8", "KM")
        case .gradient: return ("8.4", "%")
        case .pace: return ("4:18", "/KM")
        case .verticalSpeed: return ("1008", "M/H")
        case .temperature: return ("18", "°C")
        case .torque: return ("94", "NM")
        case .gear: return ("4", "GEAR")
        case .coordinates: return ("55.75", "37.61")
        case .calories: return ("684", "KCAL")
        case .airPressure: return ("1012", "HPA")
        case .leftRightBalance: return ("52/48", "%")
        case .strideLength: return ("1.24", "M")
        case .verticalOscillation: return ("8.6", "CM")
        case .groundContactTime: return ("242", "MS")
        case .strokeRate: return ("32", "SPM")
        case .cameraISO: return ("400", "ISO")
        case .cameraAperture: return ("2.8", "F/")
        case .cameraShutter: return ("1/240", "S")
        case .cameraFocalLength: return ("24", "MM")
        case .cameraEV: return ("+0.7", "EV")
        case .cameraColorTemperature: return ("5600", "K")
        case .elapsedTime: return ("01:24:18", "")
        case .satelliteStatus: return ("GPS", "ACTIVE")
        case .routeMap, .routeProgress, .elevationProfile: return ("", "")
        }
    }

    var previewLabel: String {
        switch self {
        case .speedometer, .speedValue, .speedBar: return "SPEED"
        case .verticalSpeed: return "VAM"
        default: return localizedTitle.uppercased()
        }
    }

    var symbolName: String {
        switch category {
        case .general: return "gauge.with.dots.needle.67percent"
        case .cycling: return "bicycle"
        case .running: return "figure.run"
        case .motorsports: return "flag.checkered"
        case .camera: return "camera.aperture"
        case .other: return "waveform.path.ecg"
        }
    }
}

private struct ArcGaugeShape: Shape {
    var progress: Double
    var reverse = false
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.43
        let start = Angle.degrees(reverse ? 210 : 150)
        let end = Angle.degrees((reverse ? 210 : 150) + (reverse ? -240 : 240) * progress)
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: reverse)
        return path
    }
}

private struct CornerGaugeShape: Shape {
    var progress: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let origin = CGPoint(x: rect.minX + rect.width * 0.15, y: rect.maxY - rect.height * 0.15)
        path.move(to: CGPoint(x: origin.x, y: origin.y - rect.height * 0.72 * progress))
        path.addLine(to: origin)
        path.addLine(to: CGPoint(x: origin.x + rect.width * 0.72 * progress, y: origin.y))
        return path
    }
}

private struct RoutePreviewShape: Shape {
    func path(in rect: CGRect) -> Path {
        let points = [CGPoint(x: 0.08, y: 0.78), CGPoint(x: 0.24, y: 0.70), CGPoint(x: 0.18, y: 0.55), CGPoint(x: 0.47, y: 0.48), CGPoint(x: 0.36, y: 0.28), CGPoint(x: 0.68, y: 0.17), CGPoint(x: 0.84, y: 0.30), CGPoint(x: 0.75, y: 0.48), CGPoint(x: 0.92, y: 0.66)]
        var path = Path()
        for (index, point) in points.enumerated() {
            let mapped = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
            index == 0 ? path.move(to: mapped) : path.addLine(to: mapped)
        }
        return path
    }
}

private struct ElevationPreviewShape: Shape {
    func path(in rect: CGRect) -> Path {
        let points = [CGPoint(x: 0, y: 0.82), CGPoint(x: 0.12, y: 0.67), CGPoint(x: 0.25, y: 0.72), CGPoint(x: 0.38, y: 0.42), CGPoint(x: 0.52, y: 0.51), CGPoint(x: 0.68, y: 0.18), CGPoint(x: 0.84, y: 0.34), CGPoint(x: 1, y: 0.12)]
        var path = Path()
        for (index, point) in points.enumerated() {
            let mapped = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
            index == 0 ? path.move(to: mapped) : path.addLine(to: mapped)
        }
        return path
    }
}

private extension Color {
    static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
