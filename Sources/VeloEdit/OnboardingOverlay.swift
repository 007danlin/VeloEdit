import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum OnboardingAnchor: Hashable {
    case welcome, media, director, preview, timeline, export, navigation
    case section(WorkspaceSection)
}

struct OnboardingAnchorsKey: PreferenceKey {
    static var defaultValue: [OnboardingAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [OnboardingAnchor: Anchor<CGRect>],
                       nextValue: () -> [OnboardingAnchor: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func onboardingAnchor(_ anchor: OnboardingAnchor) -> some View {
        anchorPreference(key: OnboardingAnchorsKey.self, value: .bounds) { [anchor: $0] }
    }

    /// Apply to siblings of the live target, never to an ancestor of it.
    func inactiveDuringOnboarding() -> some View { modifier(OnboardingInactiveContent()) }
}

private struct OnboardingInactiveContent: ViewModifier {
    @EnvironmentObject var model: AppModel
    func body(content: Content) -> some View {
        content.disabled(model.onboarding.isPresented)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(model.onboarding.isPresented)
    }
}

struct OnboardingRoot<Content: View>: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: OnboardingCoordinator
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .overlayPreferenceValue(OnboardingAnchorsKey.self) { anchors in
                if coordinator.isPresented {
                    GeometryReader { geometry in
                        OnboardingOverlay(model: model, coordinator: coordinator,
                                          bounds: CGRect(origin: .zero, size: geometry.size),
                                          anchors: anchors.mapValues { geometry[$0] })
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if coordinator.showsCompletion {
                    Text(model.project == nil
                         ? "Теперь создайте проект или откройте существующий. Инструкция доступна в меню справки."
                         : "Теперь можно начать. Инструкция доступна в меню справки.")
                        .font(.callout)
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(16)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Знакомство завершено. Инструкция доступна в меню справки.")
                }
            }
            .onChange(of: model.hasActiveWork) { _, busy in
                if busy && coordinator.isPresented { coordinator.interrupt() }
            }
            .onChange(of: model.showsMissingMedia) { _, value in if value { coordinator.interrupt() } }
            .onChange(of: model.editorialComparison != nil || model.showEditorialStyle) { _, value in
                if value { coordinator.interrupt() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willBeginSheetNotification)) { _ in
                if coordinator.isPresented { coordinator.interrupt() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                if coordinator.isPresented { coordinator.interrupt() }
            }
    }
}

struct OnboardingResumeButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var coordinator: OnboardingCoordinator

    var body: some View {
        if coordinator.canResume && coordinator.unavailableReason == nil {
            Button("Продолжить знакомство", systemImage: "questionmark.circle") {
                coordinator.start(resuming: true)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(Color.accentColor)
            .padding(12)
            .accessibilityIdentifier("onboarding-resume")
        }
    }
}

/// Layout is independent of window origin, display scale and the current split sizes.
enum OnboardingLayout {
    static func cardFrame(size: CGSize, bounds: CGRect, avoiding targets: [CGRect]) -> CGRect? {
        let area = bounds.insetBy(dx: 12, dy: 12)
        guard size.width <= area.width, size.height <= area.height else { return nil }
        var origins: [CGPoint] = []
        for target in targets {
            origins += [
                CGPoint(x: target.midX - size.width / 2, y: target.maxY + 16),
                CGPoint(x: target.midX - size.width / 2, y: target.minY - size.height - 16),
                CGPoint(x: target.minX - size.width - 16, y: target.midY - size.height / 2),
                CGPoint(x: target.maxX + 16, y: target.midY - size.height / 2)
            ]
        }
        origins += [
            CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX - size.width, y: area.minY),
            CGPoint(x: area.minX, y: area.maxY - size.height),
            CGPoint(x: area.maxX - size.width, y: area.maxY - size.height)
        ]
        return origins.map {
            CGRect(x: min(max($0.x, area.minX), area.maxX - size.width),
                   y: min(max($0.y, area.minY), area.maxY - size.height),
                   width: size.width, height: size.height)
        }.first { candidate in
            !targets.contains { $0.insetBy(dx: -8, dy: -8).intersects(candidate) }
        }
    }

    static func targets(step: OnboardingStep) -> [OnboardingAnchor] {
        switch step {
        case .welcome: return [.welcome]
        case .media: return [.media]
        case .director: return [.director]
        case .montage: return [.preview, .timeline]
        case .export: return [.export]
        }
    }
}

private struct OnboardingCardSizeKey: PreferenceKey {
    static var defaultValue = CGSize(width: 320, height: 260)
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct OnboardingOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: OnboardingCoordinator
    let bounds: CGRect
    let anchors: [OnboardingAnchor: CGRect]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var cardSize = CGSize(width: 320, height: 260)
    @State private var timedOut = false
    @FocusState private var primaryFocused: Bool

    private var step: OnboardingStep { coordinator.step }
    private var hasTimeline: Bool { model.timeline != nil }
    private var required: [OnboardingAnchor] { OnboardingLayout.targets(step: step) }
    private var primaryRects: [CGRect] {
        let found = required.compactMap { visibleRect(anchors[$0]) }
        return found.count == required.count ? found : []
    }
    private var measuredSize: CGSize { CGSize(width: min(320, bounds.width - 24), height: cardSize.height) }
    private var navigationRects: [CGRect] { visibleRect(anchors[.navigation]).map { [$0] } ?? [] }
    private var useFallback: Bool {
        primaryRects.isEmpty ? timedOut
            : OnboardingLayout.cardFrame(size: measuredSize, bounds: bounds, avoiding: primaryRects + navigationRects) == nil
    }
    private var targets: [CGRect] {
        if useFallback {
            return visibleRect(anchors[.section(step.section)]).map { [$0] } ?? []
        }
        return primaryRects
    }
    private var cardFrame: CGRect? {
        guard !targets.isEmpty else { return nil }
        return OnboardingLayout.cardFrame(size: measuredSize, bounds: bounds, avoiding: targets + navigationRects)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let frame = cardFrame {
                let holes = targets.map { $0.insetBy(dx: -7, dy: -7) } + navigationRects
                Canvas { context, size in
                    context.drawLayer { layer in
                        layer.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.50)))
                        layer.blendMode = .destinationOut
                        for hole in holes {
                            layer.fill(Path(roundedRect: hole, cornerRadius: 9), with: .color(.black))
                        }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                OnboardingInputShield(coordinator: coordinator, model: model,
                                      holes: coordinator.showsProjectlessWorkspace || coordinator.showsEmptyMontagePreview
                                          ? navigationRects : holes,
                                      targetRects: targets, cardFrame: frame)
                    .accessibilityHidden(true)

                ForEach(Array(targets.enumerated()), id: \.offset) { _, rect in
                    let outline = rect.insetBy(dx: -7, dy: -7).intersection(bounds.insetBy(dx: 2, dy: 2))
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(contrast == .increased ? Color.white : Color.accentColor, lineWidth: 2)
                        .frame(width: outline.width, height: outline.height)
                        .position(x: outline.midX, y: outline.midY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                pointer(from: frame, to: targets[0])
                card(id: coordinator.presentationID)
                    .frame(width: measuredSize.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: OnboardingCardSizeKey.self, value: geometry.size)
                    })
                    .position(x: frame.midX, y: frame.minY + cardSize.height / 2)
                    .onPreferenceChange(OnboardingCardSizeKey.self) { size in
                        if abs(size.height - cardSize.height) > 1 { cardSize = size }
                    }
                    .transition(.opacity)
            }
        }
        .frame(width: bounds.width, height: bounds.height)
        .task(id: coordinator.presentationID) {
            timedOut = false
            primaryFocused = true
        }
        .task(id: primaryRects.isEmpty) {
            guard primaryRects.isEmpty else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            timedOut = true
            if visibleRect(anchors[.section(step.section)]) == nil { coordinator.interrupt() }
        }
        .onChange(of: cardFrame != nil) { _, available in
            if available { primaryFocused = true }
            else if useFallback { coordinator.interrupt() }
        }
        .task(id: useFallback && cardFrame == nil) {
            if useFallback && cardFrame == nil { coordinator.interrupt() }
        }
    }

    private func visibleRect(_ rect: CGRect?) -> CGRect? {
        guard let rect else { return nil }
        let clipped = rect.intersection(bounds.insetBy(dx: 2, dy: 2))
        return clipped.isNull || clipped.width < 8 || clipped.height < 8 ? nil : clipped
    }

    private func card(id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(step.progress).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button { coordinator.dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .focusable()
                .onKeyPress(.return) { coordinator.dismiss(); return .handled }
                .accessibilityLabel("Закрыть инструкцию")
            }
            Text(step.title)
                .font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(step.message(fallback: useFallback))
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
            if step == .export && !hasTimeline {
                Text("Сохранение станет доступно после сборки фильма.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Пропустить") { coordinator.dismiss() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .focusable()
                    .onKeyPress(.return) { coordinator.dismiss(); return .handled }
                Spacer(minLength: 0)
                if step != .welcome && (step != .media || model.project == nil) {
                    Button("Назад") { coordinator.back(expectedID: id) }
                        .focusable()
                        .onKeyPress(.return) { coordinator.back(expectedID: id); return .handled }
                }
                Button(step == .export ? "Готово" : "Далее") {
                    coordinator.advance(expectedID: id)
                }
                .buttonStyle(.borderedProminent)
                .focusable()
                .focusEffectDisabled()
                .focused($primaryFocused)
                .onKeyPress(.return) { coordinator.advance(expectedID: id); return .handled }
                .accessibilityIdentifier("onboarding-next")
            }
            .font(.system(size: 13))
            .padding(.top, 4)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(contrast == .increased ? 0.8 : 0.18)))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-card-\(step.rawValue)")
        .onAppear { primaryFocused = true }
        .animation(.easeOut(duration: reduceMotion ? 0.08 : 0.16), value: step)
    }

    private func pointer(from card: CGRect, to target: CGRect) -> some View {
        Path { path in
            let center = CGPoint(x: min(max(target.midX, card.minX + 20), card.maxX - 20),
                                 y: target.midY > card.midY ? card.maxY : card.minY)
            let direction: CGFloat = target.midY > card.midY ? 1 : -1
            if card.maxY <= target.minY || card.minY >= target.maxY {
                path.move(to: CGPoint(x: center.x - 7, y: center.y))
                path.addLine(to: CGPoint(x: center.x, y: center.y + direction * 9))
                path.addLine(to: CGPoint(x: center.x + 7, y: center.y))
                path.closeSubpath()
            } else if card.maxX <= target.minX || card.minX >= target.maxX {
                let x = target.midX > card.midX ? card.maxX : card.minX
                let y = min(max(target.midY, card.minY + 20), card.maxY - 20)
                let direction: CGFloat = target.midX > card.midX ? 1 : -1
                path.move(to: CGPoint(x: x, y: y - 7))
                path.addLine(to: CGPoint(x: x + direction * 9, y: y))
                path.addLine(to: CGPoint(x: x, y: y + 7))
                path.closeSubpath()
            }
        }
        .fill(Color(nsColor: .controlBackgroundColor))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Native hit testing leaves real controls in the holes operational. It also
/// consumes Escape before Timeline's monitor can handle the same event.
private struct OnboardingInputShield: NSViewRepresentable {
    let coordinator: OnboardingCoordinator
    let model: AppModel
    let holes: [CGRect]
    let targetRects: [CGRect]
    let cardFrame: CGRect

    func makeNSView(context: Context) -> ShieldView {
        let view = ShieldView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: ShieldView, context: Context) {
        view.coordinator = coordinator
        view.model = model
        view.holes = holes
        view.targetRects = targetRects
        view.cardFrame = cardFrame
    }
    static func dismantleNSView(_ view: ShieldView, coordinator: ()) { view.stop() }

    final class ShieldView: NSView {
        weak var coordinator: OnboardingCoordinator?
        weak var model: AppModel?
        var holes: [CGRect] = []
        var targetRects: [CGRect] = []
        var cardFrame = CGRect.zero
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return holes.contains(where: { $0.contains(local) }) || cardFrame.contains(local) ? nil : super.hitTest(point)
        }
        override func mouseDown(with event: NSEvent) {}
        override func rightMouseDown(with event: NSEvent) {}
        override func scrollWheel(with event: NSEvent) {}
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, monitor == nil else { return }
            registerForDraggedTypes([.fileURL])
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let coordinator = self.coordinator, coordinator.isPresented,
                      event.window === self.window else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { coordinator.dismiss(); return nil }
                    if event.modifierFlags.contains(.command) { coordinator.interrupt() }
                    if event.isARepeat && (event.keyCode == 36 || event.keyCode == 76) { return nil }
                } else {
                    let point = self.convert(event.locationInWindow, from: nil)
                    if !self.cardFrame.contains(point) {
                        if !self.bounds.contains(point) { coordinator.interrupt() }
                        else if coordinator.step != .welcome && self.holes.contains(where: { $0.contains(point) }) {
                            coordinator.interrupt()
                        }
                    }
                }
                return event
            }
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            coordinator?.step == .media && model?.project != nil ? .copy : []
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard coordinator?.step == .media, model?.project != nil,
                  let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                      options: [.urlReadingFileURLsOnly: true]) as? [NSURL], !urls.isEmpty else { return false }
            coordinator?.interrupt()
            return model?.handleDrop(urls.map { NSItemProvider(object: $0) }) ?? false
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            unregisterDraggedTypes()
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
