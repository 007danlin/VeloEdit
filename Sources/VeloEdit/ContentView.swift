import SwiftUI
import AVKit
import AppKit
import Combine
import UniformTypeIdentifiers
import VeloEditCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var intro: FirstLaunchCoordinator
    @State private var isSidebarVisible = true
    @State private var isRenamingProject = false
    @State private var projectName = ""

    private var sourceAssets: [MediaAsset] {
        model.mediaLibraryAssets
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if isSidebarVisible {
                    sidebar
                        .frame(width: 239)
                        .disabled(model.isCreatingProject)
                    Divider()
                }

                Group {
                    if !model.hasProjectWorkspace && model.section != .settings { WelcomeView() }
                    else { selectedWorkspace }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !model.missingMediaAssets.isEmpty && model.openingProjectURL == nil {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
                    Text("Не найдены исходники: \(model.missingMediaAssets.count). Подключите диск или укажите новое расположение.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Найти исходники…") { model.showsMissingMedia = true }
                        .disabled(model.hasActiveWork)
                }.padding(12).background(.regularMaterial)
            }
            if model.openingProjectURL == nil,
               let job = model.project?.autonomousJob, job.state == .waitingForExternalResource {
                HStack {
                    Image(systemName: "externaldrive")
                    Text(job.externalResource ?? "Ожидаю материалы")
                    Spacer()
                    Button("Отменить", action: model.cancelOperation)
                }
                .padding(12)
                .background(.regularMaterial)
            }
        }
        .background {
            if !model.hasProjectWorkspace || model.section == .home {
                HStack(spacing: 0) {
                    if isSidebarVisible { Color.clear.frame(width: 240) }
                    ZStack {
                        WelcomeAuroraBackground()
                        ActivitySymbolConstellation()
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
            }
        }
        .toolbarBackground(!model.hasProjectWorkspace || model.section == .home ? .hidden : .automatic, for: .windowToolbar)
        .toolbar {
            if !intro.isPresented {
            ToolbarItem(placement: .navigation) {
                windowHeader
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .automatic) {
                    Spacer()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if model.openingProjectURL == nil && model.isWorking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.isCreatingFilm ? "Создаю фильм" : model.activityTitle).lineLimit(1)
                        Button("Отменить", systemImage: "xmark.circle", action: model.cancelOperation)
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityElement(children: .contain)
                } else if model.openingProjectURL == nil && model.timeline != nil {
                    HStack(spacing: 10) {
                        Menu("Довести фильм", systemImage: "slider.horizontal.3") {
                            Button("Другая музыка", action: model.replaceMusicImmediately).disabled(model.timeline?.music == nil)
                            Button("Послушать варианты", action: model.listenToMusicAlternatives).disabled(model.timeline?.music == nil)
                            Button("Запомнить этот стиль") { model.showEditorialStyle = true }
                        }
                        .labelStyle(.iconOnly)
                        .help("Довести фильм")
                        .accessibilityLabel("Довести фильм")
                        if model.section != .export {
                            Button("Сохранить видео", systemImage: "square.and.arrow.down", action: model.saveVideo)
                                .labelStyle(.iconOnly)
                                .help("Сохранить видео")
                                .accessibilityLabel("Сохранить видео")
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                SystemResourceStatusView()
            }
            }
        }
        .sheet(isPresented: $model.showsMissingMedia) { MissingMediaView().environmentObject(model) }
        .sheet(item: $model.editorialComparison) { session in
            EditorialComparisonView(session: session).environmentObject(model)
        }
        .sheet(isPresented: $model.showEditorialStyle) { EditorialStyleView().environmentObject(model) }
        .toolbar(removing: windowTitleToolbarItem)
        .onExitCommand(perform: handleEscape)
        .onReceive(NotificationCenter.default.publisher(for: .veloEditToggleSidebar)) { _ in
            toggleSidebar()
        }
        .alert("VeloEdit", isPresented: Binding(get: { !intro.isPresented && model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Закрыть", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("Переименовать проект", isPresented: $isRenamingProject) {
            TextField("Название проекта", text: $projectName)
            Button("Сохранить") { model.renameProject(to: projectName) }
                .keyboardShortcut(.defaultAction)
                .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Введите новое название. Имя пакета на диске не изменится.")
        }
    }

    private var windowTitleToolbarItem: ToolbarDefaultItemKind? {
        if #available(macOS 15.0, *) {
            return .title
        }
        return nil
    }

    private var windowHeader: some View {
        HStack(spacing: 6) {
            Text("VeloEdit")
                .font(.system(size: 16, weight: .semibold))
                .fixedSize()

            WindowHeaderButton(
                systemImage: "sidebar.left",
                label: isSidebarVisible ? "Скрыть боковую панель" : "Показать боковую панель",
                action: toggleSidebar
            )
                .frame(width: 30, height: 32)
                .zIndex(1)

            WindowHeaderButton(systemImage: "gearshape", label: "Настройки") {
                model.openSection(.settings)
            }
                .frame(width: 30, height: 32)
                .zIndex(1)
        }
        .padding(.horizontal, 6)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Group {
                if model.openingProjectURL == nil && model.isTimelineInspectorPresented {
                    TimelineInspector()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                } else {
                    navigationSidebar
                }
            }

            if model.openingProjectURL == nil, !model.isWorking, let recovery = model.recoverableFilmBuild,
               model.project?.autonomousJob?.state == .failed {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Фильм пока не завершён").font(.subheadline.weight(.semibold))
                    Text(recovery.stageTitle).font(.caption).foregroundStyle(.secondary)
                    Text("Правки и предыдущий фильм сохранены").font(.caption)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
            } else if model.openingProjectURL == nil && model.shouldShowActivityPanel {
                Divider()
                ActivityPanel()
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.shouldShowActivityPanel)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 7)
    }

    private var navigationSidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(model.openingProjectName ?? model.project?.name ?? "Нет проекта", systemImage: "film.stack")
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .layoutPriority(1)

                    Spacer(minLength: 0)

                    Button(action: presentProjectRename) {
                        Label("Изменить название проекта", systemImage: "pencil")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .help("Изменить название проекта")
                    .disabled(model.project == nil || model.openingProjectURL != nil)
                }

                if model.openingProjectURL == nil || model.openingPresentation != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Материалов: \(sourceAssets.count)", systemImage: "photo.on.rectangle.angled")
                        if model.openingProjectURL == nil {
                            Label("Проанализировано: \(model.project?.analyses.count ?? 0)", systemImage: "brain.head.profile")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.16), lineWidth: 1) }
            .padding(10)

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("Разделы")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 3)
                ForEach(WorkspaceSection.allCases) { section in
                    Button {
                        model.openSection(section)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: section.icon)
                                .frame(width: 20)
                            Text(section.title)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(model.section == section ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.storageIsCleaning || (!model.hasProjectWorkspace && section != .home && section != .settings))
                }
            }
            .padding(10)

            Divider()

            Text("Исходники")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 9)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(sourceAssets) { asset in
                        Button {
                            model.selectAssetForMediaInspector(asset.id)
                            model.section = .media
                        } label: {
                            HStack(spacing: 10) {
                                MediaThumbnail(url: model.mediaLibraryThumbnailURLs[asset.id], kind: asset.kind)
                                    .frame(width: 42, height: 28)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay {
                                        if asset.missing { RoundedRectangle(cornerRadius: 4).stroke(.red, lineWidth: 2) }
                                    }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(asset.displayName)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(asset.metadata.duration.map { Self.duration($0) } ?? Self.resolution(asset.metadata))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                if asset.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                                if asset.excluded { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(model.mediaLibrarySelectedAssetID == asset.id ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: .infinity)

        }
    }

    @ViewBuilder private var selectedWorkspace: some View {
        VStack(spacing: 0) {
            Group {
                if model.openingProjectURL != nil && model.section != .home && model.section != .media && model.section != .settings {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.section.title).font(.title2.bold()).padding(20)
                        Divider()
                        Color.clear
                    }
                } else {
                    switch model.section {
                    case .home: WelcomeView()
                    case .media: MediaLibraryView()
                    case .director: DirectorPanel()
                    case .timeline: TimelineWorkspaceView(showsResetAllButton: !isSidebarVisible)
                    case .export: ExportWorkspaceView()
                    case .settings: SettingsWorkspaceView()
                    }
                }
            }
        }
        .background(model.section == .home ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .overlay {
            if model.isDropTarget {
                RoundedRectangle(cornerRadius: 18).strokeBorder(.blue, style: StrokeStyle(lineWidth: 4, dash: [10])).padding(18)
                    .background(.blue.opacity(0.08)).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $model.isDropTarget) { providers in
            guard model.openingProjectURL == nil, !model.isPresentingNewProject else { return false }
            return model.handleDrop(providers)
        }
    }

    private static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return minutes == 0 ? "\(remainingSeconds) секунд" : "\(minutes) минут \(remainingSeconds) секунд"
    }
    private static func resolution(_ metadata: MediaMetadata) -> String { if let w = metadata.width, let h = metadata.height { return "\(w)×\(h)" }; return "Фотография" }

    private func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    private func presentProjectRename() {
        guard let name = model.project?.name else { return }
        projectName = name
        isRenamingProject = true
    }

    private func handleEscape() {
        if model.isPresentingNewProject {
            DispatchQueue.main.async { model.cancelProjectCreation() }
            return
        }
        if FullScreenPreviewPresenter.shared.closeIfPresented() {
            return
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return
        }
        if let window = NSApp.keyWindow, window.firstResponder is NSTextView {
            window.makeFirstResponder(nil)
        } else {
            model.handleEscape()
        }
    }
}

private struct WindowHeaderButton: NSViewRepresentable {
    let systemImage: String
    let label: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = FirstClickButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.activate)
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.focusRingType = .none
        button.contentTintColor = .labelColor
        update(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        update(button)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        // The whole visible 38-point control must receive clicks, including
        // the padding around the symbol.
        CGSize(width: proposal.width ?? 38, height: proposal.height ?? 38)
    }

    private func update(_ button: NSButton) {
        let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: label)
        button.image = image?.withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func activate() {
            action()
        }
    }

    final class FirstClickButton: NSButton {
        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    var posterImage: NSImage? = nil
    var showsPoster = false
    var showsControls = false

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerView.player = player
        view.playerView.controlsStyle = showsControls ? .floating : .none
        view.updatePoster(image: posterImage, isVisible: showsPoster)
        return view
    }

    func updateNSView(_ view: PlayerContainerView, context: Context) {
        if view.playerView.player !== player { view.playerView.player = player }
        view.playerView.controlsStyle = showsControls ? .floating : .none
        view.updatePoster(image: posterImage, isVisible: showsPoster)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: PlayerContainerView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }

    /// `AVPlayerView` may give its private video surface the movie's natural
    /// size while SwiftUI is resizing the editor. When the player itself is
    /// the represented view, that private surface can temporarily draw beyond
    /// the SwiftUI frame and cover the media browser or timeline. A dedicated
    /// layer-backed host provides a real AppKit clipping boundary and removes
    /// the player's intrinsic size from SwiftUI layout negotiation.
    final class PlayerContainerView: NSView {
        let playerView = AVPlayerView()
        private let posterView = NSImageView()

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.masksToBounds = true

            // The editor supplies persistent transport controls below the
            // canvas. AVPlayerView's inline controls auto-hide and made a
            // paused preview look as if it had no playback controls at all.
            playerView.controlsStyle = .none
            playerView.showsFullScreenToggleButton = false
            playerView.videoGravity = .resizeAspect
            playerView.wantsLayer = true
            playerView.layer?.backgroundColor = NSColor.black.cgColor
            playerView.layer?.masksToBounds = true
            playerView.autoresizingMask = [.width, .height]
            playerView.frame = bounds
            addSubview(playerView)

            // Keep the poster out of AVPlayerView.contentOverlayView: its
            // image's intrinsic size can enlarge AVKit's private video surface
            // and leave only a cropped fragment inside our clipping boundary.
            posterView.imageScaling = .scaleProportionallyUpOrDown
            posterView.wantsLayer = true
            posterView.layer?.backgroundColor = NSColor.black.cgColor
            posterView.isHidden = true
            posterView.autoresizingMask = [.width, .height]
            posterView.frame = bounds
            addSubview(posterView)
        }

        override func layout() {
            super.layout()
            playerView.frame = bounds
            posterView.frame = bounds
        }

        func updatePoster(image: NSImage?, isVisible: Bool) {
            posterView.image = image
            posterView.isHidden = !isVisible || image == nil
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

}

/// All visual layers, including titles and telemetry, come from the same
/// composition in live playback, the paused poster and export.
private struct TimelinePreviewPlayer: View {
    @EnvironmentObject var model: AppModel
    let player: AVPlayer
    let clock: TimelinePlaybackClock

    var body: some View {
        GeometryReader { geometry in
            let timelineSize = CGSize(
                width: max(1, model.timeline?.width ?? 16),
                height: max(1, model.timeline?.height ?? 9)
            )
            let scale = min(geometry.size.width / timelineSize.width,
                            geometry.size.height / timelineSize.height)
            let canvas = CGSize(width: timelineSize.width * scale,
                                height: timelineSize.height * scale)
            PlayerView(
                player: player,
                posterImage: model.previewPosterImage,
                showsPoster: model.isPreviewPosterVisible
            )
            .frame(width: canvas.width, height: canvas.height)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .background(Color.black)
        .clipped()
    }
}

/// Only this lightweight overlay observes playback time. Keeping the AVPlayer
/// representable outside that observation prevents a full player/layout update
/// on every video frame.
private struct TimelineTitlePreviewOverlay: View {
    let timeline: Timeline
    @ObservedObject var clock: TimelinePlaybackClock
    let player: AVPlayer
    let poster: NSImage?
    @StateObject private var frames = TitlePreviewFrameSource()

    var body: some View {
        ZStack {
            if !activeTitles.isEmpty, let frame = frames.image {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .allowsHitTesting(false)
            }
        }
        .onAppear { refresh() }
        .onChange(of: clock.time) { _, _ in refresh() }
        .onChange(of: timeline.effectiveTitleItems) { _, _ in refresh() }
        .onChange(of: player.currentItem) { _, _ in refresh() }
        .onChange(of: poster) { _, _ in refresh() }
        .onDisappear { frames.detach() }
    }

    private func refresh() {
        frames.attach(to: player.currentItem)
        frames.update(timeline: timeline, time: clock.time, renderSize: previewRenderSize,
                      poster: poster?.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    private var activeTitles: [TitleTimelineItem] {
        timeline.effectiveTitleItems.filter {
            $0.enabled && clock.time >= $0.startTime && clock.time < $0.endTime
        }.sorted { $0.track < $1.track }
    }

    private var previewRenderSize: CGSize {
        let timelineWidth = CGFloat(max(1, timeline.width))
        let timelineHeight = CGFloat(max(1, timeline.height))
        let bounds = timelineWidth >= timelineHeight
            ? CGSize(width: 960, height: 540)
            : CGSize(width: 540, height: 960)
        let scale = min(bounds.width / timelineWidth, bounds.height / timelineHeight)
        return CGSize(
            width: max(2, (timelineWidth * min(1, scale)).rounded()),
            height: max(2, (timelineHeight * min(1, scale)).rounded())
        )
    }
}

private struct MoviePreviewPanel: View {
    @EnvironmentObject var model: AppModel
    let player: AVPlayer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Просмотр фильма").font(.headline)
                    if let timeline = model.timeline {
                        Text("\(timeline.items.count) фрагментов · \(duration(timeline.duration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("На весь экран", systemImage: "arrow.up.left.and.arrow.down.right") {
                    FullScreenPreviewPresenter.shared.present(model: model)
                }
                .labelStyle(.iconOnly)
                .help("Открыть просмотр на весь экран (F)")
                Button("К умному режиссёру", action: model.showDirector)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            TimelinePreviewPlayer(player: player, clock: model.playbackClock)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: 720, maxHeight: 238)
                .frame(maxWidth: .infinity)
                .background(Color.black)
        }
        .frame(minHeight: 160, idealHeight: 230, maxHeight: 286, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return minutes == 0 ? "\(remainingSeconds) секунд" : "\(minutes) минут \(remainingSeconds) секунд"
    }
}

private struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            WelcomeActivityHero()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 430)

            if !model.recentProjectURLs.isEmpty {
                RecentProjectsGallery()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WelcomeActivityHero: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(680, max(460, proxy.size.width * 0.50))
            let cardHeight = min(360, max(320, proxy.size.height * 0.58))

            ZStack {
                if model.isPresentingNewProject {
                    NewProjectView()
                        .transition(.opacity)
                } else {
                    welcomeCard
                        .transition(.opacity)
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .modifier(WelcomeCardFrame())
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.isPresentingNewProject)
        }
        .accessibilityElement(children: .contain)
    }

    private var welcomeCard: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    }
                    .shadow(color: .blue.opacity(0.20), radius: 18)

                Image(systemName: "film.stack.fill")
                    .font(.system(size: 44, weight: .medium))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(red: 0.10, green: 0.58, blue: 1.00))
            }
            .frame(width: 82, height: 82)

            Text("VeloEdit")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Дайте приложению реальные материалы и расскажите, какой фильм хотите.")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)

            HStack(spacing: 12) {
                Button("Новый проект", action: model.createProject)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Открыть проект", action: model.openProject)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 42)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Both steps share one fixed card shell; only the content inside it changes.
private struct WelcomeCardFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 38, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 38, style: .continuous)
                        .fill(Color.black.opacity(0.32))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 38, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.42),
                                Color(red: 0.12, green: 0.62, blue: 1.00).opacity(0.62),
                                Color(red: 0.72, green: 0.32, blue: 1.00).opacity(0.42),
                                .white.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.4
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .inset(by: 5)
                    .stroke(.white.opacity(0.055), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.46), radius: 34, y: 18)
            .shadow(color: Color(red: 0.12, green: 0.56, blue: 1.00).opacity(0.12), radius: 38)
    }
}

private struct WelcomeAuroraBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.055, green: 0.060, blue: 0.075),
                    Color(red: 0.075, green: 0.070, blue: 0.105),
                    Color(red: 0.045, green: 0.055, blue: 0.070)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.blue.opacity(0.14))
                .frame(width: 520, height: 520)
                .blur(radius: 110)
                .offset(x: -360, y: -170)

            Circle()
                .fill(Color.purple.opacity(0.12))
                .frame(width: 480, height: 480)
                .blur(radius: 120)
                .offset(x: 410, y: 190)

            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.035), .clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: 520
                    )
                )
        }
        .ignoresSafeArea()
    }
}

private struct ActivitySymbolConstellation: View {
    private struct ActivitySymbol: Identifiable {
        let id: String
        let symbol: String
        let color: Color
        let x: CGFloat
        let y: CGFloat
        let rotation: Double
    }

    private let tileSize: CGFloat = 66

    private let symbols: [ActivitySymbol] = [
        .init(id: "cycle", symbol: "figure.outdoor.cycle", color: Color(red: 0.20, green: 0.72, blue: 1.00), x: 0.08, y: 0.25, rotation: -5),
        .init(id: "run", symbol: "figure.run", color: Color(red: 1.00, green: 0.35, blue: 0.38), x: 0.06, y: 0.52, rotation: 6),
        .init(id: "hike", symbol: "figure.hiking", color: Color(red: 0.41, green: 0.85, blue: 0.43), x: 0.18, y: 0.36, rotation: -4),
        .init(id: "mountain", symbol: "mountain.2.fill", color: Color(red: 0.38, green: 0.78, blue: 0.92), x: 0.28, y: 0.10, rotation: 3),
        .init(id: "ski", symbol: "figure.skiing.downhill", color: Color(red: 0.35, green: 0.64, blue: 1.00), x: 0.50, y: 0.07, rotation: -2),
        .init(id: "tent", symbol: "tent.fill", color: Color(red: 1.00, green: 0.62, blue: 0.18), x: 0.72, y: 0.10, rotation: 4),
        .init(id: "kayak", symbol: "figure.water.fitness", color: Color(red: 0.10, green: 0.78, blue: 0.83), x: 0.92, y: 0.25, rotation: 4),
        .init(id: "snowboard", symbol: "figure.snowboarding", color: Color(red: 0.68, green: 0.48, blue: 1.00), x: 0.94, y: 0.52, rotation: -6),
        .init(id: "sail", symbol: "sailboat.fill", color: Color(red: 0.18, green: 0.66, blue: 1.00), x: 0.82, y: 0.36, rotation: 3),
        .init(id: "surf", symbol: "figure.surfing", color: Color(red: 0.16, green: 0.82, blue: 0.66), x: 0.90, y: 0.76, rotation: -3),
        .init(id: "camera", symbol: "camera.fill", color: Color(red: 1.00, green: 0.43, blue: 0.69), x: 0.10, y: 0.76, rotation: 4)
    ]

    var body: some View {
        GeometryReader { proxy in
            let scale = min(1, max(0.72, proxy.size.width / 1500))

            ForEach(symbols) { item in
                ActivitySymbolTile(symbol: item.symbol, color: item.color)
                    .frame(width: tileSize * scale, height: tileSize * scale)
                    .rotationEffect(.degrees(item.rotation))
                    .position(x: proxy.size.width * item.x, y: proxy.size.height * item.y)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct ActivitySymbolTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            ZStack {
                RoundedRectangle(cornerRadius: side * 0.30, style: .continuous)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: side * 0.30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.11), color.opacity(0.11), .black.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: symbol)
                    .font(.system(size: side * 0.48, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(color)
                    .shadow(color: color.opacity(0.24), radius: 8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: side * 0.30, style: .continuous)
                    .stroke(.white.opacity(0.13), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.30), radius: 16, y: 9)
            .shadow(color: color.opacity(0.10), radius: 16)
        }
    }
}

private struct RecentProjectsGallery: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Недавние проекты")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("Листайте по горизонтали")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(model.recentProjectURLs, id: \.path) { url in
                        RecentProjectCard(url: url)
                    }
                }
                .padding(.horizontal, 24)
                // Leave room for the cards' hover scale and shadow inside the scroll viewport.
                .padding(.vertical, 16)
            }
            .frame(height: 250, alignment: .top)
        }
        .padding(.top, 20)
        .padding(.bottom, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}

private struct RecentProjectCard: View {
    @EnvironmentObject var model: AppModel
    let url: URL
    private let info: RecentProjectInfo
    @State private var isHovered = false

    init(url: URL) {
        self.url = url
        self.info = RecentProjectInfo(url: url)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button { model.openRecentProject(url, name: info.name) } label: {
                cardContent
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityIdentifier("recent-project-\(url.lastPathComponent)")

            Menu {
                Button("Переименовать", systemImage: "pencil") { model.renameRecentProject(url) }
                Button("Поделиться", systemImage: "square.and.arrow.up") { model.openRecentProjectExport(url) }
                Divider()
                Button("Удалить", systemImage: "trash", role: .destructive) { model.deleteRecentProject(url) }
            } label: {
                ZStack {
                    Circle().fill(.black.opacity(0.58))
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(90))
                }
                .frame(width: 28, height: 28)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(8)
            .help("Действия с проектом")
        }
        .contextMenu {
            Button("Переименовать") { model.renameRecentProject(url) }
            Button("Поделиться") { model.openRecentProjectExport(url) }
            Divider()
            Button("Удалить", role: .destructive) { model.deleteRecentProject(url) }
        }
        .task(id: info.updatedAt) {
            await model.prepareProjectPresentation(at: url)
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecentProjectPreview(info: info)
                .frame(width: 224, height: 126)
                .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(info.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(info.subtitle)
                    .font(.caption)
                    .foregroundStyle(info.exists ? .secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 68, alignment: .topLeading)
            .padding(12)
        }
        .frame(width: 224)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isHovered ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.10), lineWidth: isHovered ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(isHovered ? 0.16 : 0.08), radius: isHovered ? 10 : 4, y: isHovered ? 5 : 2)
        .scaleEffect(isHovered ? 1.015 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Открыть проект \(info.name)")
    }
}

private struct RecentProjectPreview: View {
    let info: RecentProjectInfo

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.48), Color.indigo.opacity(0.34), Color.black.opacity(0.34)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let previewURL = info.previewURL {
                CachedThumbnailImage(url: previewURL, kind: info.previewKind ?? .video, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: info.exists ? "film.stack.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(info.exists ? Color.white.opacity(0.9) : Color.orange)
            }

            LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .center, endPoint: .bottom)
        }
    }
}

private struct RecentProjectInfo {
    let url: URL
    let name: String
    let exists: Bool
    let assetCount: Int
    let updatedAt: Date?
    let previewURL: URL?
    let previewKind: MediaKind?

    init(url: URL) {
        self.url = url
        let exists = FileManager.default.fileExists(atPath: url.path)
        self.exists = exists

        guard exists else {
            name = url.deletingPathExtension().lastPathComponent
            assetCount = 0
            updatedAt = nil
            previewURL = nil
            previewKind = nil
            return
        }

        // Never decode the full project manifest on the main actor. The store
        // maintains this tiny summary whenever it saves the project.
        guard let summary = ProjectSummary.load(from: url) else {
            name = url.deletingPathExtension().lastPathComponent
            assetCount = 0
            updatedAt = nil
            previewURL = nil
            previewKind = nil
            return
        }
        name = summary.name
        assetCount = summary.assetCount
        updatedAt = summary.updatedAt
        previewKind = summary.previewKind
        let packagePath = url.standardizedFileURL.path + "/"
        previewURL = summary.previewRelativePaths.lazy.compactMap { relativePath in
            let candidate = url.appendingPathComponent(relativePath).standardizedFileURL
            guard candidate.path.hasPrefix(packagePath), FileManager.default.fileExists(atPath: candidate.path) else { return nil }
            return candidate
        }.first
    }

    var subtitle: String {
        guard exists else { return "Файл перемещён или удалён" }
        let assets = assetCount == 1 ? "1 материал" : "\(assetCount) материалов"
        guard let updatedAt else { return assets }
        return "\(assets) · \(updatedAt.formatted(date: .complete, time: .omitted))"
    }
}

private struct MediaLibraryView: View {
    @EnvironmentObject var model: AppModel
    private let mediaCardWidth: CGFloat = 220
    private let mediaCardHeight: CGFloat = 184
    private let previewHeight: CGFloat = 114
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 220), spacing: 14, alignment: .top)]

    private var mediaAssets: [MediaAsset] {
        model.mediaLibraryAssets
    }

    private var selectedMediaAsset: MediaAsset? {
        if model.openingProjectURL != nil {
            return mediaAssets.first { $0.id == model.openingSelectedAssetID }
        }
        return model.selectedAsset.flatMap { asset in
            BackgroundPreset.preset(for: asset) == nil ? asset : nil
        }
    }

    private var selectedMusicTrack: LocalMusicTrack? {
        model.mediaLibraryMusicTracks.first { $0.id == model.mediaLibrarySelectedMusicTrackID }
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 760 {
                HSplitView {
                    mediaBrowser
                        .frame(minWidth: 420)
                        .layoutPriority(1)
                    if selectedMediaAsset != nil || selectedMusicTrack != nil {
                        mediaInspector
                            .frame(
                                minWidth: 230,
                                idealWidth: 320,
                                maxWidth: max(230, geometry.size.width * 0.5)
                            )
                    }
                }
            } else {
                VStack(spacing: 0) {
                    mediaBrowser
                    if selectedMediaAsset != nil || selectedMusicTrack != nil {
                        Divider()
                        mediaInspector
                            .frame(minHeight: 180, idealHeight: 260, maxHeight: max(180, geometry.size.height * 0.45))
                    }
                }
            }
        }
    }

    private var mediaBrowser: some View {
        VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        mediaHeaderTitle
                        Spacer(minLength: 24)
                        mediaHeaderActions
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        mediaHeaderTitle
                        mediaHeaderActions
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                if model.openingProjectURL == nil && model.newMaterialCount > 0 {
                    HStack {
                        Text("Добавлено материалов: \(model.newMaterialCount). Использовать в фильме?")
                        Spacer()
                        Button("Использовать", action: model.useNewMaterialsInFilm)
                            .disabled(model.isWorking || model.isDirectorResponding)
                        Button("Позже", action: model.dismissNewMaterials)
                    }
                    .padding(12)
                    .background(Color.accentColor.opacity(0.08))
                }
                if model.openingProjectURL == nil && !model.importWarnings.isEmpty {
                    DisclosureGroup("Не удалось создать миниатюры: \(model.importWarnings.count)") {
                        ForEach(Array(model.importWarnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).font(.caption).textSelection(.enabled)
                        }
                    }
                    .padding(12)
                }
                if model.openingProjectURL != nil && model.openingPresentation == nil {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(0..<12, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.secondary.opacity(0.08))
                                    .frame(width: mediaCardWidth, height: mediaCardHeight)
                            }
                        }
                        .padding(18)
                        .padding(.leading, 6)
                    }
                    .accessibilityLabel("Загрузка материалов")
                } else if mediaAssets.isEmpty && model.mediaLibraryMusicTracks.isEmpty {
                    ContentUnavailableView("Добавьте фото, видео или музыку", systemImage: "square.and.arrow.down", description: Text("Перетащите файлы или папки либо выберите их на Mac, флэшке или внешнем диске через «Добавить материалы»."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                        if !mediaAssets.isEmpty {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(mediaAssets) { asset in
                                Button {
                                    model.selectAssetForMediaInspector(asset.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ZStack(alignment: .topTrailing) {
                                            MediaThumbnail(url: model.mediaLibraryThumbnailURLs[asset.id], kind: asset.kind)
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                .background(Color.black.opacity(0.18))
                                                .frame(height: previewHeight)
                                                .clipShape(RoundedRectangle(cornerRadius: 9))
                                            if asset.kind == .video {
                                                Image(systemName: "play.circle.fill")
                                                    .font(.system(size: 30))
                                                    .foregroundStyle(.white)
                                                    .shadow(radius: 3)
                                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                            }
                                            HStack(spacing: 5) {
                                                if asset.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                                                if asset.excluded { Image(systemName: "eye.slash.fill").foregroundStyle(.white) }
                                            }
                                            .padding(7)
                                            .shadow(radius: 2)
                                        }
                                        Text(asset.displayName)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        HStack(spacing: 6) {
                                            Text(asset.kind == .video ? "Видео" : "Фото")
                                                .lineLimit(1)
                                                .layoutPriority(1)
                                            Spacer(minLength: 4)
                                            Text(asset.metadata.duration.map { duration($0) } ?? resolution(asset.metadata))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.72)
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    .padding(9)
                                    .frame(width: mediaCardWidth, height: mediaCardHeight, alignment: .topLeading)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .background(model.mediaLibrarySelectedAssetID == asset.id ? Color.accentColor.opacity(0.17) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.mediaLibrarySelectedAssetID == asset.id ? Color.accentColor : .clear, lineWidth: 2))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        }
                        if !model.mediaLibraryMusicTracks.isEmpty {
                            Text("Музыка")
                                .font(.headline)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                                ForEach(model.mediaLibraryMusicTracks) { track in
                                    Button {
                                        model.selectMusicTrackForInspector(track.id)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Image(systemName: "waveform")
                                                .font(.system(size: 30))
                                                .foregroundStyle(.green)
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                .frame(height: previewHeight)
                                                .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                                            Text(track.title)
                                                .font(.callout.weight(.medium))
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Text("Музыка · \(duration(track.duration))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.72)
                                        }
                                        .padding(9)
                                        .frame(width: mediaCardWidth, height: mediaCardHeight, alignment: .topLeading)
                                        .background(model.mediaLibrarySelectedMusicTrackID == track.id ? Color.accentColor.opacity(0.17) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.mediaLibrarySelectedMusicTrackID == track.id ? Color.accentColor : .clear, lineWidth: 2))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        }
                        .padding(.top, 18)
                        .padding(.leading, 24)
                        .padding(.trailing, 18)
                        .padding(.bottom, 18)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var mediaInspector: some View {
        if model.openingProjectURL != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Инспектор").font(.headline)
                        Spacer()
                        Button(action: model.closeMediaInspector) {
                            Label("Закрыть инспектор", systemImage: "xmark").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.plain)
                    }
                    if let asset = selectedMediaAsset {
                        MediaThumbnail(url: model.mediaLibraryThumbnailURLs[asset.id], kind: asset.kind)
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Text(asset.displayName).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text(asset.kind == .video ? "Видео" : "Фотография")
                        Text(asset.metadata.duration.map(duration) ?? resolution(asset.metadata))
                            .foregroundStyle(.secondary)
                    } else if let track = selectedMusicTrack {
                        Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(.green)
                        Text(track.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text("Музыка · \(duration(track.duration))").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            .background(Color(nsColor: .controlBackgroundColor))
        } else if let asset = selectedMediaAsset {
            AssetInspector(asset: asset)
        } else if let track = selectedMusicTrack {
            MusicInspector(track: track)
        }
    }

    private var mediaHeaderTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text("Медиатека").font(.title2.bold())
                if model.openingProjectURL != nil {
                    ProgressView().controlSize(.small)
                        .help("Проект загружается в фоне")
                }
            }
            Text("Исходники остаются на своих местах и никогда не изменяются")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var mediaHeaderActions: some View {
        HStack(spacing: 10) {
            Button("Добавить материалы", systemImage: "plus", action: model.chooseMedia)
                .help("Выбрать файлы или папки на Mac, флэшке либо внешнем диске")
                .disabled(model.isWorking)
            Button("Ручной монтаж", systemImage: "timeline.selection", action: model.startManualEditing)
                .disabled(model.isWorking)
        }
        .fixedSize(horizontal: true, vertical: true)
        .disabled(model.openingProjectURL != nil)
    }

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return minutes == 0 ? "\(remainingSeconds) секунд" : "\(minutes) минут \(remainingSeconds) секунд"
    }
    private func resolution(_ metadata: MediaMetadata) -> String {
        guard let width = metadata.width, let height = metadata.height else { return "—" }
        return "\(width)×\(height)"
    }
}

private struct AssetInspector: View {
    @EnvironmentObject var model: AppModel
    let asset: MediaAsset

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text("Инспектор").font(.headline)
                    Spacer(minLength: 8)
                    Button {
                        model.closeMediaInspector()
                    } label: {
                        Label("Закрыть инспектор", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .help("Закрыть инспектор")
                }
                if asset.kind == .video, !asset.missing {
                    SourcePreview(
                        url: asset.originalURL,
                        duration: asset.metadata.duration
                    )
                        .id(asset.id)
                        .frame(height: 190)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    MediaThumbnail(url: model.thumbnailURLs[asset.id], kind: asset.kind)
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text(asset.displayName).font(.title3.weight(.semibold)).textSelection(.enabled)
                if asset.missing {
                    Label("Оригинал не найден", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                VStack(alignment: .leading, spacing: 8) {
                    detail("Тип", asset.kind == .video ? "Видео" : "Фотография")
                    if let duration = asset.metadata.duration { detail("Длительность", String(format: "%.1f секунды", duration)) }
                    if let width = asset.metadata.width, let height = asset.metadata.height { detail("Размер", "\(width)×\(height)") }
                    if let codec = asset.metadata.codec { detail("Кодек", codec) }
                    detail("Анализ", model.project?.analyses.contains(where: { $0.assetID == asset.id }) == true ? "Готов" : "Не выполнен")
                    detail("Целостность", asset.fullContentHash == nil ? "Не проверена" : "Проверена")
                }
                Divider()
                Button(asset.favorite ? "Убрать из избранного" : "В избранное", systemImage: asset.favorite ? "star.slash" : "star") {
                    model.toggleFavorite(asset.id)
                }
                Button(asset.excluded ? "Вернуть в подбор" : "Не использовать в фильме", systemImage: asset.excluded ? "eye" : "eye.slash") {
                    model.toggleExcluded(asset.id)
                }
                Button("Показать оригинал", systemImage: "folder") { model.revealAsset(asset.id) }
                Divider()
                Button("Удалить из проекта", systemImage: "trash", role: .destructive) { model.removeAsset(asset.id) }
            }
            .padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MusicInspector: View {
    @EnvironmentObject var model: AppModel
    let track: LocalMusicTrack

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text("Инспектор").font(.headline)
                    Spacer(minLength: 8)
                    Button {
                        model.closeMediaInspector()
                    } label: {
                        Label("Закрыть инспектор", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .help("Закрыть инспектор")
                }

                AudioPreview(track: track)
                    .id(track.id)

                Text(track.title)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)

                VStack(alignment: .leading, spacing: 8) {
                    detail("Автор", track.author.isEmpty ? "—" : track.author)
                    detail("Длительность", duration(track.duration))
                    detail("Темп", "\(Int(track.bpm.rounded())) BPM")
                    detail("Источник", track.sourceProvider.localizedTitle)
                    if !track.genres.isEmpty { detail("Жанры", track.genres.joined(separator: ", ")) }
                    if !track.moods.isEmpty { detail("Настроение", track.moods.joined(separator: ", ")) }
                    if let tags = track.tags, !tags.isEmpty { detail("Теги", tags.joined(separator: ", ")) }
                    detail("Лицензия", track.license.name)
                    detail("Атрибуция", track.license.requiresAttribution == true ? "Обязательна" : "Не требуется")
                    if let checkedAt = track.license.licenseCheckedAt {
                        detail("Лицензия проверена", checkedAt.formatted(date: .numeric, time: .omitted))
                    }
                }
            }
            .padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct AudioPreview: View {
    let track: LocalMusicTrack
    @State private var player: AVPlayer
    @State private var currentTime = 0.0
    @State private var isPlaying = false
    @State private var timeObserver: Any?

    init(track: LocalMusicTrack) {
        self.track = track
        _player = State(initialValue: AVPlayer(url: track.localFileURL))
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 34))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                Button {
                    togglePlayback()
                } label: {
                    Label(isPlaying ? "Пауза" : "Воспроизвести", systemImage: isPlaying ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)

                Slider(
                    value: Binding(
                        get: { min(currentTime, effectiveDuration) },
                        set: { seek(to: $0) }
                    ),
                    in: 0...effectiveDuration
                )
                .help("Перемотать трек")

                Text("\(time(currentTime)) / \(time(track.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .onAppear(perform: installTimeObserver)
        .onDisappear(perform: stopAndRemoveObserver)
    }

    private var effectiveDuration: Double { max(track.duration, 0.1) }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= track.duration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    private func seek(to seconds: Double) {
        currentTime = min(max(0, seconds), effectiveDuration)
        player.seek(
            to: CMTime(seconds: currentTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func installTimeObserver() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { time in
            currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
            isPlaying = player.timeControlStatus == .playing
        }
    }

    private func stopAndRemoveObserver() {
        player.pause()
        isPlaying = false
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct SourcePreview: View {
    @State private var player: AVPlayer
    @State private var currentTime = 0.0
    @State private var isPlaying = false
    @State private var timeObserver: Any?
    private let duration: Double

    init(url: URL, duration: Double?) {
        self.duration = max(duration ?? 0, 0)
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: 10) {
            PlayerView(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipped()

            HStack(spacing: 8) {
                Button(action: togglePlayback) {
                    Label(
                        isPlaying ? "Пауза" : "Воспроизвести",
                        systemImage: isPlaying ? "pause.fill" : "play.fill"
                    )
                    .labelStyle(.iconOnly)
                    .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "Пауза" : "Воспроизвести")

                Slider(
                    value: Binding(
                        get: { min(currentTime, effectiveDuration) },
                        set: seek
                    ),
                    in: 0...effectiveDuration
                )
                .help("Перемотать исходное видео")

                Text("\(time(currentTime)) / \(time(duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
        }
        .background(Color.black.opacity(0.92))
        .onAppear(perform: installTimeObserver)
        .onDisappear(perform: stopAndRemoveObserver)
    }

    private var effectiveDuration: Double { max(duration, 0.1) }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    private func seek(to seconds: Double) {
        currentTime = min(max(0, seconds), effectiveDuration)
        player.seek(
            to: CMTime(seconds: currentTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func installTimeObserver() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { time in
            currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
            isPlaying = player.timeControlStatus == .playing
        }
    }

    private func stopAndRemoveObserver() {
        player.pause()
        isPlaying = false
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct TimelineWorkspaceView: View {
    @EnvironmentObject var model: AppModel
    let showsResetAllButton: Bool

    var body: some View {
        GeometryReader { geometry in
            if let timeline = model.timeline {
                let columnWidth = max(0, (geometry.size.width - 1) / 2)

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        MontageMediaBrowser()
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .frame(width: columnWidth)
                            .clipped()
                            .frame(maxHeight: .infinity)
                        Divider()
                        MontagePlayerWorkspace(showsResetAllButton: showsResetAllButton)
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .frame(width: columnWidth)
                            .clipped()
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: geometry.size.height / 2)

                    Divider()
                    MagneticTimelineView(timeline: timeline, playbackClock: model.playbackClock)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .background(TimelineKeyboardMonitor(model: model).frame(width: 0, height: 0))
            } else {
                ContentUnavailableView {
                    Label("Начните монтаж", systemImage: "timeline.selection")
                } description: {
                    Text("Добавляйте и редактируйте клипы самостоятельно или поручите сборку режиссёру.")
                } actions: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { editingActions }
                        VStack(spacing: 12) { editingActions }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    model.handleTimelineFileDrop(providers, at: 0, audioStart: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var editingActions: some View {
        Button("Ручной монтаж", action: model.startManualEditing)
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking)
            .fixedSize()
        Button("Умный режиссёр", action: model.showDirector)
            .fixedSize()
    }

}

private enum MontageBrowserTab: String, CaseIterable, Identifiable {
    case media = "Медиа"
    case audio = "Аудио"
    case backgrounds = "Фон"
    case telemetry = "Телеметрия"
    case titles = "Титры"
    case transitions = "Переходы"
    case effects = "Эффекты"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .media: return "photo.on.rectangle.angled"
        case .audio: return "music.note"
        case .backgrounds: return "rectangle.fill.on.rectangle.fill"
        case .telemetry: return "gauge.with.dots.needle.67percent"
        case .titles: return "textformat"
        case .transitions: return "rectangle.2.swap"
        case .effects: return "wand.and.rays"
        }
    }
}

private struct MontageMediaBrowser: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab: MontageBrowserTab = .media
    @State private var search = ""
    @State private var titleText = ""
    @State private var backgroundCategory: BackgroundCategory = .nature
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]
    private let backgroundColumns = [
        GridItem(.flexible(minimum: 96), spacing: 9, alignment: .top),
        GridItem(.flexible(minimum: 96), spacing: 9, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text("Материалы")
                        .font(.headline)
                    Spacer()
                    Button(action: model.chooseMedia) {
                        Label("Добавить материалы", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Добавить видео, фотографии или музыку")
                }
                browserTabPicker
                if tab == .media {
                    TextField("Поиск", text: $search)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(12)

            Divider()
            Group {
                switch tab {
                case .media: mediaGrid
                case .audio: audioList
                case .backgrounds: backgroundsBrowser
                case .telemetry: telemetryList
                case .titles: titleBrowser
                case .transitions: transitionBrowser
                case .effects: effectsBrowser
                }
            }
            .id(tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .scrollBounceBehavior(.always, axes: .vertical)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var browserTabPicker: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 5)], spacing: 5) {
            ForEach(MontageBrowserTab.allCases) { item in
                browserTabButton(item)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private func browserTabButton(_ item: MontageBrowserTab) -> some View {
        Button {
            tab = item
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.icon)
                    .font(.caption)
                Text(item.rawValue)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .foregroundStyle(tab == item ? Color.white : Color.primary)
            .background(
                tab == item ? Color.accentColor : Color.primary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel(item.rawValue)
        .accessibilityValue(tab == item ? "Выбрано" : "")
        .accessibilityIdentifier("materials-tab-\(item.rawValue)")
    }

    private var filteredAssets: [MediaAsset] {
        let assets = (model.project?.assets ?? []).filter { BackgroundPreset.preset(for: $0) == nil }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? assets : assets.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    private var mediaGrid: some View {
        ScrollView {
            if filteredAssets.isEmpty {
                ContentUnavailableView("Нет материалов", systemImage: "photo.on.rectangle.angled")
                    .padding(.top, 24)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(filteredAssets) { asset in
                        VStack(alignment: .leading, spacing: 5) {
                            ZStack {
                                MediaThumbnail(url: model.thumbnailURLs[asset.id], kind: asset.kind)
                                    .frame(height: 64)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                if let duration = asset.metadata.duration {
                                    Text(shortTime(duration))
                                        .font(.caption2.monospacedDigit().weight(.medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 3))
                                        .padding(4)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                                }
                                Button {
                                    model.insertAssetIntoTimeline(asset.id)
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.caption.bold())
                                        .frame(width: 20, height: 20)
                                        .background(.black.opacity(0.68), in: Circle())
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                                .padding(4)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                .help("Добавить в конец фильма")
                            }
                            Text(asset.displayName)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .padding(5)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedAssetID = asset.id }
                        .libraryDraggable(asset.id.uuidString)
                    }
                }
                .padding(10)
            }
        }
    }

    private var audioList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Музыка")
                                .font(.headline)
                            Label(
                                model.musicLibraryStatus.localizedSummary,
                                systemImage: model.musicLibraryStatus.offlineReady ? "checkmark.circle.fill" : "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(model.musicLibraryStatus.offlineReady ? .green : .secondary)
                        }
                        Spacer()
                    }
                    HStack(spacing: 6) {
                        musicSourceBadge("VeloEdit Library", count: model.bundledMusicTracks.count, icon: "shippingbox.fill")
                        musicSourceBadge("Моя музыка", count: model.userMusicTracks.count, icon: "folder.fill")
                        musicSourceBadge("Online", count: model.cachedOnlineMusicTracks.count, icon: "network")
                    }
                    HStack(spacing: 8) {
                        Button("Добавить папку", systemImage: "folder.badge.plus", action: model.chooseMusicFolder)
                        Button("Обновить Online", systemImage: "arrow.triangle.2.circlepath", action: model.prepareOnlineMusicLibrary)
                    }
                    .buttonStyle(.bordered)
                    Text("Интернет дополняет каталог, но для создания фильма не требуется.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))

                if model.musicTracks.isEmpty {
                    Label("Встроенная музыка не найдена", systemImage: "music.note")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    ForEach(model.musicTracks) { track in
                        HStack(spacing: 9) {
                            Image(systemName: "waveform")
                                .foregroundStyle(.green)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(.callout).lineLimit(1)
                                Text("\(track.sourceProvider.localizedTitle) · \(Int(track.bpm)) BPM · \(track.author)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Button { model.insertMusicClip(track.id) } label: { Image(systemName: "plus.circle.fill") }
                                .buttonStyle(.borderless)
                                .help("Добавить отдельным аудиоклипом в позицию playhead")
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                        .libraryDraggable("music:\(track.id.uuidString)")
                    }
                }
            }
            .padding(10)
        }
    }

    private func musicSourceBadge(_ title: String, count: Int, icon: String) -> some View {
        Label("\(title) \(count)", systemImage: icon)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.07), in: Capsule())
    }

    private var backgroundsBrowser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(BackgroundCategory.allCases) { category in
                        Button(category.localizedTitle) {
                            backgroundCategory = category
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(backgroundCategory == category ? Color.white : Color.primary)
                        .padding(.horizontal, 9)
                        .frame(maxWidth: .infinity, minHeight: 27)
                        .background(
                            backgroundCategory == category ? Color.accentColor : Color.primary.opacity(0.07),
                            in: Capsule()
                        )
                    }
                }

                LazyVGrid(columns: backgroundColumns, alignment: .leading, spacing: 12) {
                    ForEach(BackgroundPreset.catalogPresets.filter { $0.category == backgroundCategory }) { preset in
                        LibraryItemButton {
                            model.insertBackgroundIntoTimeline(preset)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                BackgroundPresetPreview(preset: preset)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .overlay(alignment: .topLeading) {
                                        if !preset.isSolid {
                                            Image(systemName: "play.fill")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(5)
                                                .background(.black.opacity(0.58), in: Circle())
                                                .padding(5)
                                                .help("Анимированный фон")
                                        }
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.white, .blue)
                                            .padding(5)
                                    }
                                Text(preset.localizedTitle)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, minHeight: 31, maxHeight: 31, alignment: .topLeading)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .libraryDraggable("background:\(preset.rawValue)")
                        .help("Перетащите фон на Timeline или нажмите, чтобы добавить в конец")
                    }
                }
            }
            .padding(10)
        }
    }

    private var telemetryList: some View {
        TelemetryLibraryView()
    }

    private var titleBrowser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Текст титра", text: $titleText)
                    .textFieldStyle(.roundedBorder)
                Text("Введите текст и выберите оформление. Наведите указатель на карточку, чтобы увидеть анимацию.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(TitleTemplateCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(category.localizedTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(TitleTemplateRegistry.all.filter { $0.category == category }) { template in
                                LibraryItemButton {
                                    let value = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    model.addModernTitle(value.isEmpty ? template.preview.primaryText : value, templateID: template.id)
                                    titleText = ""
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        TitlePreviewArtwork(template: template, text: titleText)
                                            .aspectRatio(16 / 9, contentMode: .fit)
                                            .overlay(alignment: .bottomTrailing) {
                                                Image(systemName: "plus.circle.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(.white, .purple)
                                                    .padding(5)
                                            }
                                        Text(template.name)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .libraryDraggable(titleDragPayload(template))
                                .help("Перетащите титр на нужный момент Timeline")
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var effectsBrowser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Живые карточки используют тот же native renderer, что Timeline, Preview и Export. Эффект добавится в позицию playhead.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Пресеты")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(EffectStackPresetRegistry.all) { preset in
                            LibraryItemButton {
                                model.applyEffectStackPreset(preset.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "square.stack.3d.up.fill")
                                            .foregroundStyle(effectPresetAccentColor(preset.id))
                                        Text(preset.name)
                                            .foregroundStyle(.primary)
                                    }
                                    .font(.caption.weight(.semibold))
                                    Text(preset.summary)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(
                                    effectPresetPastelColor(preset.id),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(effectPresetAccentColor(preset.id).opacity(0.22))
                                }
                            }
                            .buttonStyle(.plain)
                            .libraryDraggable("effect-preset:\(preset.id)")
                            .disabled(model.isWorking)
                        }
                    }
                }

                ForEach(TimelineEffectCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(category.localizedTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(TimelineEffectType.allCases.filter { $0.category == category }) { effect in
                                LibraryItemButton {
                                    model.addTimelineEffect(effect)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        EffectPreviewArtwork(effect: effect)
                                            .aspectRatio(16 / 9, contentMode: .fit)
                                            .overlay(alignment: .bottomTrailing) {
                                                Image(systemName: "plus.circle.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(.white, .green)
                                                    .padding(5)
                                            }
                                        Text(effect.localizedTitle)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, minHeight: 31, maxHeight: 31, alignment: .topLeading)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .libraryDraggable("effect:\(effect.rawValue)")
                                .disabled(model.isWorking)
                                .help("Перетащите эффект на нужный момент Timeline")
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func effectPresetPastelColor(_ presetID: String) -> Color {
        switch presetID {
        case "cinematic": return Color(red: 0.91, green: 0.86, blue: 0.98).opacity(0.72)
        case "action": return Color(red: 1.00, green: 0.86, blue: 0.80).opacity(0.72)
        case "vintage": return Color(red: 0.98, green: 0.92, blue: 0.72).opacity(0.72)
        case "travel": return Color(red: 0.80, green: 0.94, blue: 0.86).opacity(0.72)
        case "social": return Color(red: 0.82, green: 0.91, blue: 0.99).opacity(0.72)
        default: return Color(red: 0.90, green: 0.90, blue: 0.94).opacity(0.72)
        }
    }

    private func effectPresetAccentColor(_ presetID: String) -> Color {
        switch presetID {
        case "cinematic": return Color(red: 0.48, green: 0.32, blue: 0.70)
        case "action": return Color(red: 0.78, green: 0.32, blue: 0.20)
        case "vintage": return Color(red: 0.62, green: 0.46, blue: 0.08)
        case "travel": return Color(red: 0.18, green: 0.55, blue: 0.36)
        case "social": return Color(red: 0.18, green: 0.45, blue: 0.72)
        default: return .secondary
        }
    }

    private var transitionBrowser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Выберите входящий клип или поставьте playhead рядом со склейкой. Cut удаляет переход и возвращает чистую склейку.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(TransitionPresetCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(category.localizedTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(TransitionPresetRegistry.presets(in: category)) { preset in
                                LibraryItemButton {
                                    model.addTimelineTransition(preset.style)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        TransitionPreviewArtwork(style: preset.style)
                                            .aspectRatio(16 / 9, contentMode: .fit)
                                            .overlay(alignment: .bottomTrailing) {
                                                Image(systemName: preset.style == .cut ? "scissors" : "plus.circle.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(.white, .blue)
                                                    .padding(5)
                                            }
                                        Text(preset.name)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(preset.subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .libraryDraggable("transition:\(preset.style.rawValue)")
                                .disabled(model.isWorking)
                                .help("Добавить \(preset.name) как редактируемый объект Timeline")
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func titleDragPayload(_ template: TitleTemplateDefinition) -> String {
        let value = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = value.isEmpty ? template.preview.primaryText : value
        return "title-template:\(template.id):\(Data(text.utf8).base64EncodedString())"
    }

    private func shortTime(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private final class BackgroundPreviewImageCache: @unchecked Sendable {
    static let shared = BackgroundPreviewImageCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for preset: BackgroundPreset) -> NSImage? {
        let key = preset.rawValue as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let cgImage = try? BackgroundPresetRenderer.makeImage(
            preset,
            width: 640,
            height: 360,
            sourceImageURL: preset.bundledImageURL()
        ) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: 640, height: 360))
        cache.setObject(image, forKey: key)
        return image
    }
}

struct BackgroundPresetArtwork: View {
    let preset: BackgroundPreset

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image = BackgroundPreviewImageCache.shared.image(for: preset) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: preset.colors.map { Color(red: $0.red, green: $0.green, blue: $0.blue) },
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }
}

struct BackgroundPresetPreview: View {
    let preset: BackgroundPreset

    var body: some View {
        BackgroundPresetArtwork(preset: preset)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
    }
}

private struct BackgroundPatternArtwork: View {
    let decoration: BackgroundDecoration

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height)
            switch decoration {
            case .none:
                break
            case .curtain, .stripes, .silk:
                let count = decoration == .curtain ? 10 : 22
                for index in 0..<count where index.isMultiple(of: 2) {
                    let width = size.width / CGFloat(count)
                    context.fill(Path(CGRect(x: CGFloat(index) * width, y: 0, width: width, height: size.height)), with: .color(.black.opacity(decoration == .curtain ? 0.22 : 0.08)))
                }
            case .parchment, .paper:
                for index in 0..<42 {
                    let x = pseudo(index * 17) * size.width
                    let y = pseudo(index * 31 + 7) * size.height
                    let dot = CGRect(x: x, y: y, width: 1.5, height: 1.5)
                    context.fill(Path(ellipseIn: dot), with: .color(.black.opacity(0.13)))
                }
            case .bubbles:
                for index in 0..<10 {
                    let diameter = unit * (0.12 + pseudo(index * 13) * 0.20)
                    let rect = CGRect(x: pseudo(index * 29) * size.width - diameter / 2, y: pseudo(index * 43) * size.height - diameter / 2, width: diameter, height: diameter)
                    context.fill(Path(ellipseIn: rect), with: .color(.yellow.opacity(0.15)))
                }
            case .underwater:
                for index in 0..<6 {
                    var beam = Path()
                    let x = size.width * (CGFloat(index) + 0.35) / 6
                    beam.move(to: CGPoint(x: x, y: 0)); beam.addLine(to: CGPoint(x: x + size.width * 0.14, y: size.height)); beam.addLine(to: CGPoint(x: x + size.width * 0.03, y: size.height)); beam.closeSubpath()
                    context.fill(beam, with: .color(.white.opacity(0.10)))
                }
            case .technical:
                let step = max(9, unit * 0.12)
                for x in stride(from: CGFloat(0), through: size.width, by: step) {
                    var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height)); context.stroke(line, with: .color(.cyan.opacity(0.13)), lineWidth: 0.5)
                }
                for y in stride(from: CGFloat(0), through: size.height, by: step) {
                    var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y)); context.stroke(line, with: .color(.cyan.opacity(0.13)), lineWidth: 0.5)
                }
            case .stars:
                for index in 0..<55 {
                    let d = 0.8 + pseudo(index * 23) * 1.8
                    context.fill(Path(ellipseIn: CGRect(x: pseudo(index * 17) * size.width, y: pseudo(index * 37) * size.height, width: d, height: d)), with: .color(.white.opacity(0.70)))
                }
            case .retro:
                let inset = unit * 0.08
                context.fill(Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset), cornerRadius: unit * 0.04), with: .color(.yellow.opacity(0.26)))
            case .checkerboard:
                let step = unit * 0.24
                for row in 0...Int(size.height / step) {
                    for column in 0...Int(size.width / step) where (row + column).isMultiple(of: 2) {
                        context.fill(Path(CGRect(x: CGFloat(column) * step, y: CGFloat(row) * step, width: step, height: step)), with: .color(.pink.opacity(0.75)))
                    }
                }
            case .rings:
                for radius in stride(from: unit * 0.06, through: unit * 0.70, by: unit * 0.07) {
                    let rect = CGRect(x: size.width / 2 - radius, y: size.height / 2 - radius, width: radius * 2, height: radius * 2)
                    context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.48)), lineWidth: 1)
                }
            case .cubes, .triangles, .mosaic:
                let step = unit * 0.25
                for row in 0...Int(size.height / step) {
                    for column in 0...Int(size.width / step) where (row + column).isMultiple(of: 2) {
                        var shape = Path()
                        let x = CGFloat(column) * step, y = CGFloat(row) * step
                        shape.move(to: CGPoint(x: x, y: y)); shape.addLine(to: CGPoint(x: x + step, y: y)); shape.addLine(to: CGPoint(x: x + step * 0.5, y: y + step)); shape.closeSubpath()
                        context.fill(shape, with: .color(.blue.opacity(0.48)))
                    }
                }
            case .diagonals:
                let step = unit * 0.17
                for offset in stride(from: -size.height, through: size.width, by: step) {
                    var line = Path(); line.move(to: CGPoint(x: offset, y: 0)); line.addLine(to: CGPoint(x: offset + size.height, y: size.height)); context.stroke(line, with: .color(.black.opacity(0.34)), lineWidth: max(2, unit * 0.04))
                }
            case .dots:
                let step = unit * 0.12
                for y in stride(from: step / 2, through: size.height, by: step) {
                    for x in stride(from: step / 2, through: size.width, by: step) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.yellow.opacity(0.75)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func pseudo(_ value: Int) -> CGFloat {
        let x = sin(Double(value) * 12.9898) * 43_758.5453
        return CGFloat(x - floor(x))
    }
}

private actor TitlePreviewRenderer {
    static let shared = TitlePreviewRenderer()

    func image(template: TitleTemplateDefinition, text: String, time: Double) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        var copy = template
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { copy.preview.primaryText = clean }
        return TitleOverlayRenderer.previewCGImage(template: copy, time: time, renderSize: CGSize(width: 480, height: 270))
    }
}

private struct TitlePreviewArtwork: View {
    let template: TitleTemplateDefinition
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var preview: CGImage?

    private struct Request: Hashable {
        let template: TitleTemplateDefinition
        let text: String
        let animated: Bool
    }

    var body: some View {
        let request = Request(template: template, text: text, animated: isHovered && !reduceMotion)
        ZStack {
            LinearGradient(
                colors: [.black, Color(red: 0.055, green: 0.055, blue: 0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let preview {
                Image(decorative: preview, scale: 1).resizable().scaledToFit()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
        }
        .onHover { isHovered = $0 }
        .task(id: request) {
            // Debounce typing and render off the UI executor. Only the hovered
            // card animates; scrolling away or editing cancels its old request.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let start = ContinuousClock.now
            repeat {
                let elapsed = start.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let time = request.animated
                    ? seconds.truncatingRemainder(dividingBy: max(0.25, template.duration))
                    : template.duration * 0.5
                let image = await TitlePreviewRenderer.shared.image(template: request.template, text: request.text, time: time)
                guard !Task.isCancelled else { return }
                preview = image
                guard request.animated else { return }
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            } while !Task.isCancelled
        }
    }
}

private struct EffectPreviewArtwork: View {
    let effect: TimelineEffectType

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { timeline in
            let progress = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            rendererImage(TransitionEffectRenderer.previewEffectCGImage(type: effect, progress: progress))
        }
    }
}

private struct TransitionPreviewArtwork: View {
    let style: TransitionStyle

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { timeline in
            let duration = max(2.8, TransitionPresetRegistry.preset(for: style).defaultDuration * 6)
            let progress = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration) / duration
            rendererImage(TransitionEffectRenderer.previewTransitionCGImage(style: style, progress: progress))
        }
    }
}

@ViewBuilder
private func rendererImage(_ image: CGImage?) -> some View {
    ZStack {
        Color.black
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "film.stack")
                .foregroundStyle(.secondary)
        }
    }
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
    }
}

private struct ViewerPanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ViewerHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 64
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MontagePlayerWorkspace: View {
    @EnvironmentObject private var model: AppModel
    let showsResetAllButton: Bool
    @State var selectedTool: ViewerAdjustmentTool?
    @State private var toolPanelHeight: CGFloat = 0
    @State private var viewerHeaderHeight: CGFloat = 64

    init(showsResetAllButton: Bool, selectedTool: ViewerAdjustmentTool? = nil) {
        self.showsResetAllButton = showsResetAllButton
        _selectedTool = State(initialValue: selectedTool)
    }

    var body: some View {
        GeometryReader { workspace in
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text("Превью").font(.headline)
                        Spacer(minLength: 4)
                        viewerTools
                        previewWindowActions
                    }
                    VStack(spacing: 4) {
                        HStack {
                            Text("Превью").font(.headline)
                            Spacer(minLength: 4)
                            previewWindowActions
                        }
                        WrappingRowLayout(horizontalSpacing: 1, verticalSpacing: 2) {
                            viewerToolButtons
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.regular)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.regularMaterial)
                .background(GeometryReader { header in
                    Color.clear.preference(key: ViewerHeaderHeightKey.self, value: header.size.height)
                })
                .onPreferenceChange(ViewerHeaderHeightKey.self) { viewerHeaderHeight = $0 }

                if let selectedTool, let item = model.selectedTimelineItem {
                    ScrollView(.vertical) {
                        viewerToolPanel(selectedTool, item: item)
                            .background(GeometryReader { panel in
                                Color.clear.preference(key: ViewerPanelHeightKey.self, value: panel.size.height)
                            })
                    }
                        .scrollIndicators(.visible)
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: min(toolPanelHeight > 0 ? toolPanelHeight : 220,
                                           max(64, workspace.size.height - viewerHeaderHeight - 120), 220))
                        .onPreferenceChange(ViewerPanelHeightKey.self) { toolPanelHeight = $0 }
                        .layoutPriority(1)
                        .background(Color(nsColor: .underPageBackgroundColor))
                        .overlay(alignment: .bottom) { Divider() }
                }

                ZStack {
                    Color(nsColor: .black)
                    VStack(spacing: 0) {
                        GeometryReader { geometry in
                            let canvas = aspectFitSize(in: geometry.size, aspectRatio: viewerAspectRatio)
                            ZStack {
                                Color.black
                                ZStack {
                                    if let player = model.previewPlayer {
                                        TimelinePreviewPlayer(player: player, clock: model.playbackClock)
                                    } else {
                                        VStack(spacing: 10) {
                                            Image(systemName: "play.rectangle")
                                                .font(.system(size: 38, weight: .light))
                                                .foregroundStyle(.white.opacity(0.7))
                                            Button("Подготовить просмотр", action: model.renderPreview)
                                                .buttonStyle(.borderedProminent)
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .background(Color.black)
                                    }
                                    if let telemetry = model.selectedTelemetryItem {
                                        TelemetryCanvasEditor(item: telemetry)
                                            .environmentObject(model)
                                    }
                                }
                                .frame(width: canvas.width, height: canvas.height)
                                .clipped()
                                .dropDestination(for: String.self) { values, point in
                                    guard let value = values.first,
                                          let payload = TelemetryPresetDragPayload(value) else { return false }
                                    model.insertTelemetryPreset(
                                        kind: payload.kind,
                                        presentation: payload.presentation,
                                        style: payload.style,
                                        at: model.timelinePlayheadTime,
                                        normalizedPosition: CGPoint(
                                            x: min(max(0, point.x / max(1, canvas.width)), 1),
                                            y: min(max(0, 1 - point.y / max(1, canvas.height)), 1)
                                        )
                                    )
                                    return true
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .clipped()
                        }
                        .padding(4)

                        if let player = model.previewPlayer {
                            Divider()
                            MontagePlaybackControls(player: player, clock: model.playbackClock)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .background(Color.black)
            .clipped()
        }
    }

    private var previewWindowActions: some View {
        HStack(spacing: 6) {
            Button("На весь экран", systemImage: "arrow.up.left.and.arrow.down.right") {
                FullScreenPreviewPresenter.shared.present(model: model)
            }
            .labelStyle(.iconOnly)
            .help("Открыть просмотр на весь экран (F)")
            .disabled(model.previewPlayer == nil)
            Button("Экспорт", systemImage: "square.and.arrow.up") { model.openSection(.export) }
        }
        .controlSize(.small)
        .fixedSize()
    }

    private var viewerAspectRatio: CGFloat {
        guard let timeline = model.timeline, timeline.height > 0 else { return 16 / 9 }
        return CGFloat(timeline.width) / CGFloat(timeline.height)
    }

    private func aspectFitSize(in available: CGSize, aspectRatio: CGFloat) -> CGSize {
        guard available.width > 0, available.height > 0, aspectRatio > 0 else { return available }
        if available.width / available.height > aspectRatio {
            return CGSize(width: available.height * aspectRatio, height: available.height)
        }
        return CGSize(width: available.width, height: available.width / aspectRatio)
    }

    private var viewerTools: some View {
        HStack(spacing: 1) {
            viewerToolButtons
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }

    private var viewerToolButtons: some View {
        Group {
            Button(action: model.autoEnhanceSelected) {
                Label("Автоцвет", systemImage: "wand.and.rays")
                    .labelStyle(.iconOnly)
            }
            .help("Автоматически улучшить цвет")
            .disabled(model.selectedTimelineItem?.kind == .title)

            ForEach(ViewerAdjustmentTool.allCases) { tool in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selectedTool = selectedTool == tool ? nil : tool
                    }
                } label: {
                    Image(systemName: tool.icon)
                        .frame(width: 27, height: 27)
                        .background(selectedTool == tool ? Color.primary.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 4))
                }
                .accessibilityLabel(tool.title)
                .accessibilityIdentifier("viewer-tool-\(tool.rawValue)")
                .help(tool.title)
            }

            if showsResetAllButton {
                Button("Сбросить все") { model.resetAllSelectedViewerAdjustments() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .padding(.leading, 5)
            }
        }
        .disabled(model.selectedTimelineItem == nil || model.isTimelineInteractionBlocked)
    }

    @ViewBuilder
    private func viewerToolPanel(_ tool: ViewerAdjustmentTool, item: TimelineItem) -> some View {
        let video = item.effectiveVideoAdjustments
        let audio = item.effectiveAudioAdjustments
        WrappingRowLayout(horizontalSpacing: 14, verticalSpacing: 8) {
            switch tool {
                case .colorBalance:
                    Button("Авто", action: model.autoEnhanceSelected)
                    ViewerValueSlider(title: "Яркость", value: video.brightness, range: -1...1, style: .signedPercent, onCommit: model.setSelectedBrightness)
                    ViewerValueSlider(title: "Температура", value: video.warmth, range: -1...1, style: .signedPercent, onCommit: model.setSelectedWarmth)
                    ViewerValueSlider(title: "Оттенок", value: video.tint ?? 0, range: -1...1, style: .signedPercent, onCommit: model.setSelectedTint)
                    resetButton(model.resetSelectedColorBalance)

                case .colorCorrection:
                    ViewerValueSlider(title: "Экспозиция", value: video.exposure ?? 0, range: -4...4, style: .decimal(" EV")) { value in
                        model.changeSelectedExposure(by: value - (video.exposure ?? 0))
                    }
                    ViewerValueSlider(title: "Контраст", value: video.contrast, range: 0.25...2, style: .percent, onCommit: model.setSelectedContrast)
                    ViewerValueSlider(title: "Насыщенность", value: video.saturation, range: 0...2, style: .percent, onCommit: model.setSelectedSaturation)
                    ViewerValueSlider(title: "Света", value: video.highlights ?? 0, range: -1...1, style: .signedPercent) { value in
                        model.changeSelectedHighlights(by: value - (video.highlights ?? 0))
                    }
                    ViewerValueSlider(title: "Тени", value: video.shadows ?? 0, range: -1...1, style: .signedPercent) { value in
                        model.changeSelectedShadows(by: value - (video.shadows ?? 0))
                    }
                    resetButton(model.resetSelectedColorCorrection)

                case .crop:
                    CropStyleControl(selection: Binding(
                        get: { item.effect == ClipEffect.kenBurns.rawValue ? "ken-burns" : video.crop.rawValue },
                        set: model.setSelectedCropMode
                    ))
                    Button("Влево", systemImage: "rotate.left") { model.rotateSelected(-1) }
                    Button("Вправо", systemImage: "rotate.right") { model.rotateSelected(1) }
                    resetButton(model.resetSelectedCropAndRotation)

                case .stabilization:
                    if item.kind == .video && !item.isFreezeFrame {
                        Toggle("Снизить дрожание", isOn: Binding(
                            get: { (video.stabilization ?? 0) > 0.001 },
                            set: { model.setSelectedStabilization($0 ? max(0.33, video.stabilization ?? 0) : 0) }
                        ))
                        ViewerValueSlider(title: "Сила", value: video.stabilization ?? 0, range: 0...1, style: .percent, onCommit: model.setSelectedStabilization)
                            .disabled((video.stabilization ?? 0) <= 0.001)
                        Toggle("Rolling shutter", isOn: Binding(
                            get: { video.rollingShutterCorrection ?? false },
                            set: model.setSelectedRollingShutterCorrection
                        ))
                        resetButton(model.resetSelectedStabilization)
                    } else {
                        Text("Стабилизация доступна для видео.")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                case .volume:
                    if hasSourceAudio(item) {
                        Toggle("Авто", isOn: Binding(get: { audio.normalize ?? false }, set: model.setSelectedAudioNormalize))
                            .toggleStyle(.button)
                        Button {
                            model.setSelectedClipMuted(!audio.muted)
                        } label: {
                            Image(systemName: audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        }
                        .accessibilityLabel(audio.muted ? "Включить звук клипа" : "Выключить звук клипа")
                        ViewerValueSlider(title: "Громкость", value: audio.volume, range: 0...2, style: .percent, onCommit: model.setSelectedClipVolume)
                        Toggle("Снизить громкость др. клипов", isOn: Binding(get: { audio.duckOthers ?? false }, set: model.setSelectedDuckOthers))
                        ViewerValueSlider(title: "Снижение", value: audio.duckingAmount ?? 0.5, range: 0...1, style: .percent, onCommit: model.setSelectedDuckingAmount)
                            .disabled(!(audio.duckOthers ?? false))
                        resetButton(model.resetSelectedVolume)
                    } else {
                        Text("В выбранном фрагменте нет звука.")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                case .noiseReduction:
                    if hasSourceAudio(item) {
                        Toggle("Уменьшить фоновый шум", isOn: Binding(
                            get: { (audio.noiseReduction ?? 0) > 0.001 },
                            set: { model.setSelectedNoiseReduction($0 ? max(0.5, audio.noiseReduction ?? 0) : 0) }
                        ))
                        ViewerValueSlider(title: "Очистка", value: audio.noiseReduction ?? 0, range: 0...1, style: .percent, onCommit: model.setSelectedNoiseReduction)
                        ViewerMenuControl(title: "Эквалайзер", selection: Binding(get: { audio.eqPreset ?? .flat }, set: model.setSelectedEQ)) {
                            ForEach(AudioEQPreset.allCases) { preset in Text(preset.localizedTitle).tag(preset) }
                        }
                        resetButton(model.resetSelectedNoiseProcessing)
                    } else {
                        Text("В выбранном фрагменте нет звука.")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                case .speed:
                    ViewerValueSlider(title: "Скорость", value: item.speed, range: 0.1...20, style: .percent, onCommit: model.setSelectedSpeed)
                    Toggle("Сгладить", isOn: Binding(get: { video.smoothSlowMotion ?? false }, set: model.setSelectedSmoothSlowMotion))
                        .disabled(item.speed >= 1 || item.kind != .video || item.isFreezeFrame)
                    Toggle("Перевернуть", isOn: Binding(get: { item.isReversed }, set: { _ in model.toggleSelectedReverse() }))
                        .disabled(item.kind != .video || item.isFreezeFrame)
                    Toggle("Сохр. высоту тона", isOn: Binding(get: { audio.preservePitch ?? true }, set: model.setSelectedPreservePitch))
                        .disabled(!hasSourceAudio(item))
                    resetButton(model.resetSelectedSpeed)

                case .filters:
                    ViewerMenuControl(title: "Фильтр клипа", selection: Binding(get: { video.filter }, set: model.setSelectedFilter)) {
                            ForEach(VideoFilter.allCases) { filter in Text(filter.localizedTitle).tag(filter) }
                    }
                    ViewerValueSlider(title: "Интенсивность", value: video.filterIntensity ?? 1, range: 0...1, style: .percent, onCommit: model.setSelectedFilterIntensity)
                        .disabled(video.filter == .none)
                    ViewerMenuControl(title: "Аудиоэффект", selection: Binding(get: { audio.effect ?? AudioEffect.none }, set: model.setSelectedAudioEffect)) {
                            ForEach(AudioEffect.allCases) { effect in Text(effect.localizedTitle).tag(effect) }
                    }
                    .disabled(!hasSourceAudio(item))
                    .help(hasSourceAudio(item) ? "Обработка звука клипа" : "В выбранном фрагменте нет звука")
                    resetButton(model.resetSelectedFilters)

            case .information:
                informationPanel(item)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .disabled(model.isTimelineInteractionBlocked)
    }

    private func hasSourceAudio(_ item: TimelineItem) -> Bool {
        item.kind == .video && !item.isFreezeFrame &&
        model.project?.assets.first(where: { $0.id == item.assetID })?.metadata.hasAudio == true
    }

    private func resetButton(_ action: @escaping () -> Void) -> some View {
        Button("Сбросить", action: action)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
    }

    @ViewBuilder
    private func informationPanel(_ item: TimelineItem) -> some View {
        if let assetID = item.assetID, let asset = model.project?.assets.first(where: { $0.id == assetID }) {
            Label(asset.displayName, systemImage: asset.kind == .video ? "film" : "photo")
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            infoValue("Тип", asset.kind == .video ? "Видео" : "Фото")
            infoValue("Исходник", String(format: "%.1f–%.1f с", item.sourceStart, item.sourceStart + item.sourceDuration))
            infoValue("В фильме", String(format: "%.1f с", item.timelineDuration))
            if let width = asset.metadata.width, let height = asset.metadata.height { infoValue("Размер", "\(width)×\(height)") }
            if let rate = asset.metadata.frameRate { infoValue("Частота", String(format: "%.2f fps", rate)) }
            if let codec = asset.metadata.codec { infoValue("Кодек", codec) }
            infoValue("Звук", asset.metadata.hasAudio ? "Есть" : "Нет")
        } else {
            infoValue("Фрагмент", item.title ?? "Титр")
            infoValue("Длительность", String(format: "%.1f с", item.timelineDuration))
        }
    }

    private func infoValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption)
        }
    }
}

private struct FullScreenTimelinePreview: View {
    @EnvironmentObject private var model: AppModel
    let closeButtonInsets: EdgeInsets
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player = model.previewPlayer {
                VStack(spacing: 0) {
                    TimelinePreviewPlayer(player: player, clock: model.playbackClock)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    MontagePlaybackControls(player: player, clock: model.playbackClock)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }
            }
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(closeButtonInsets)
            .help("Закрыть полноэкранный просмотр (Esc)")
        }
        .onExitCommand(perform: onClose)
    }
}

@MainActor
final class FullScreenPreviewPresenter: NSObject, NSWindowDelegate {
    static let shared = FullScreenPreviewPresenter()
    private var window: NSWindow?
    private var keyboardMonitor: Any?

    var isPresented: Bool { window != nil }

    func present(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let window = FullScreenPreviewWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        let screenInsets = screen.safeAreaInsets
        let topOcclusion = max(screenInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        let trailingOcclusion = max(screenInsets.right, screen.frame.maxX - screen.visibleFrame.maxX)
        let closeButtonInsets = EdgeInsets(
            top: max(20, topOcclusion + 12),
            leading: 20,
            bottom: 20,
            trailing: max(20, trailingOcclusion + 12)
        )
        let content = FullScreenTimelinePreview(closeButtonInsets: closeButtonInsets) { [weak self] in self?.close() }
            .environmentObject(model)
        window.contentView = NSHostingView(rootView: content)
        window.backgroundColor = .black
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        self.window = window
        installKeyboardMonitor(for: window, model: model)
        window.makeKeyAndOrderFront(nil)
    }

    func toggle(model: AppModel) {
        if !closeIfPresented() {
            present(model: model)
        }
    }

    @discardableResult
    func closeIfPresented() -> Bool {
        guard window != nil else { return false }
        close()
        return true
    }

    func close() {
        let activeWindow = window
        window = nil
        removeKeyboardMonitor()
        activeWindow?.delegate = nil
        activeWindow?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else { return }
        window = nil
        removeKeyboardMonitor()
    }

    private func installKeyboardMonitor(for window: NSWindow, model: AppModel) {
        removeKeyboardMonitor()
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window, weak model] event in
            guard let window, let model, event.window === window else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let isPlainF = modifiers.isEmpty && event.charactersIgnoringModifiers?.lowercased() == "f"
            if event.keyCode == 53 || isPlainF {
                self?.close()
                return nil
            }
            guard modifiers.isEmpty || modifiers == .shift else { return event }
            switch event.keyCode {
            case 49:
                model.toggleTimelinePlayback()
            case 123:
                model.moveTimelinePlayhead(direction: -1, largeStep: modifiers.contains(.shift))
            case 124:
                model.moveTimelinePlayhead(direction: 1, largeStep: modifiers.contains(.shift))
            case 115:
                model.seekTimeline(to: 0)
            case 119:
                model.seekTimeline(to: model.timeline?.duration ?? 0)
            default:
                return event
            }
            return nil
        }
    }

    private func removeKeyboardMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
        }
        keyboardMonitor = nil
    }
}

private final class FullScreenPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct MontagePlaybackControls: View {
    @EnvironmentObject private var model: AppModel
    let player: AVPlayer
    @ObservedObject var clock: TimelinePlaybackClock

    @State private var isPlaying = false
    @State private var volume: Double
    @State private var isMuted: Bool

    init(player: AVPlayer, clock: TimelinePlaybackClock) {
        self.player = player
        self.clock = clock
        _isPlaying = State(initialValue: player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        _volume = State(initialValue: Double(player.volume))
        _isMuted = State(initialValue: player.isMuted)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                transportButtons
                seekSlider.frame(minWidth: 60)
                timeLabel
                volumeControls
            }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    transportButtons
                    Spacer(minLength: 0)
                    timeLabel
                }
                HStack(spacing: 8) {
                    seekSlider
                    volumeControls
                }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .onReceive(player.publisher(for: \.timeControlStatus, options: [.initial, .new])) { status in
            isPlaying = status == .playing || status == .waitingToPlayAtSpecifiedRate
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 8) {
            Button {
                model.seekTimeline(to: clock.time - 5)
            } label: {
                Label("Назад на 5 секунд", systemImage: "gobackward.5")
                    .labelStyle(.iconOnly)
            }
            .help("Назад на 5 секунд")

            Button {
                model.toggleTimelinePlayback()
            } label: {
                Label(isPlaying ? "Пауза" : "Воспроизвести", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 18)
            }
            .help(isPlaying ? "Пауза (Пробел)" : "Воспроизвести (Пробел)")

            Button {
                model.seekTimeline(to: clock.time + 5)
            } label: {
                Label("Вперёд на 5 секунд", systemImage: "goforward.5")
                    .labelStyle(.iconOnly)
            }
            .help("Вперёд на 5 секунд")

        }
        .fixedSize()
    }

    private var seekSlider: some View {
        Slider(
            value: Binding(
                get: { min(clock.time, effectiveDuration) },
                set: model.seekTimeline
            ),
            in: 0...effectiveDuration
        )
        .help("Перемотать фильм")

    }

    private var timeLabel: some View {
        Text("\(time(clock.time)) / \(time(model.timeline?.duration ?? 0))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()

    }

    private var volumeControls: some View {
        HStack(spacing: 8) {
            Button {
                isMuted.toggle()
                player.isMuted = isMuted
            } label: {
                Label(isMuted ? "Включить звук" : "Выключить звук", systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .labelStyle(.iconOnly)
            }
            .help(isMuted ? "Включить звук" : "Выключить звук")

            Slider(value: Binding(
                get: { volume },
                set: { value in
                    volume = value
                    player.volume = Float(value)
                    if value > 0, isMuted {
                        isMuted = false
                        player.isMuted = false
                    }
                }
            ), in: 0...1)
            .frame(width: 58)
            .help("Громкость просмотра")
        }
        .fixedSize()
    }

    private var effectiveDuration: Double {
        max(0.1, model.timeline?.duration ?? 0)
    }

    private func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

enum ViewerAdjustmentTool: String, CaseIterable, Identifiable {
    case colorBalance
    case colorCorrection
    case crop
    case stabilization
    case volume
    case noiseReduction
    case speed
    case filters
    case information

    var id: String { rawValue }
    var title: String {
        switch self {
        case .colorBalance: return "Цветовой баланс"
        case .colorCorrection: return "Цветокоррекция"
        case .crop: return "Кадрирование"
        case .stabilization: return "Стабилизация"
        case .volume: return "Громкость"
        case .noiseReduction: return "Шумоподавление и эквалайзер"
        case .speed: return "Скорость"
        case .filters: return "Фильтры"
        case .information: return "Информация о клипе"
        }
    }
    var icon: String {
        switch self {
        case .colorBalance: return "circle.lefthalf.filled"
        case .colorCorrection: return "paintpalette.fill"
        case .crop: return "crop"
        case .stabilization: return "video.fill"
        case .volume: return "speaker.wave.2.fill"
        case .noiseReduction: return "waveform"
        case .speed: return "speedometer"
        case .filters: return "camera.filters"
        case .information: return "info.circle"
        }
    }
}

private enum ViewerSliderStyle {
    case percent
    case signedPercent
    case multiplier
    case decimal(String)

    func text(_ value: Double) -> String {
        switch self {
        case .percent: return "\(Int((value * 100).rounded()))%"
        case .signedPercent: return String(format: "%+.0f%%", value * 100)
        case .multiplier: return String(format: "%.2f×", value)
        case .decimal(let suffix): return String(format: "%.1f%@", value, suffix)
        }
    }
}

/// Keeps controls together and wraps them when their column becomes narrower.
struct CropStyleControl: View {
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Стиль:").font(.callout.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                picker.pickerStyle(.segmented).fixedSize()
                picker.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var picker: some View {
        Picker("Стиль кадрирования", selection: $selection) {
            Text("Уместить").tag("fit")
            Text("Обрезать до заполнения").tag("fill")
            Text("Ken Burns").tag("ken-burns")
        }
        .labelsHidden()
    }
}

private struct WrappingRowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width ?? .infinity
        let rows = makeRows(subviews: subviews, availableWidth: availableWidth)
        let contentWidth = rows.map(\.width).max() ?? 0
        let contentHeight = rows.reduce(0) { $0 + $1.height }
            + verticalSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(
            width: proposal.width ?? contentWidth,
            height: contentHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = makeRows(subviews: subviews, availableWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX + (alignment == .center ? (bounds.width - row.width) / 2 : 0)
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func makeRows(subviews: Subviews, availableWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var currentItems: [Item] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if availableWidth.isFinite, size.width > availableWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
                size.width = min(size.width, availableWidth)
            }

            let requiredWidth = currentItems.isEmpty ? size.width : currentWidth + horizontalSpacing + size.width
            if !currentItems.isEmpty, availableWidth.isFinite, requiredWidth > availableWidth {
                rows.append(Row(items: currentItems, width: currentWidth, height: currentHeight))
                currentItems = []
                currentWidth = 0
                currentHeight = 0
            }

            currentWidth += currentItems.isEmpty ? size.width : horizontalSpacing + size.width
            currentHeight = max(currentHeight, size.height)
            currentItems.append(Item(subview: subview, size: size))
        }

        if !currentItems.isEmpty {
            rows.append(Row(items: currentItems, width: currentWidth, height: currentHeight))
        }
        return rows
    }

    private struct Item {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        let items: [Item]
        let width: CGFloat
        let height: CGFloat
    }
}

private struct ViewerMenuControl<Selection: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Selection
    @ViewBuilder let options: () -> Options

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(title).font(.callout.weight(.semibold)).fixedSize()
                picker.frame(width: 170)
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.weight(.semibold))
                picker.frame(maxWidth: .infinity)
            }
        }
    }

    private var picker: some View {
        Picker(title, selection: $selection, content: options).labelsHidden()
    }
}

private struct ViewerValueSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let style: ViewerSliderStyle
    let onCommit: (Double) -> Void
    @State private var draft: Double
    @State private var isEditing = false

    init(title: String, value: Double, range: ClosedRange<Double>, style: ViewerSliderStyle, onCommit: @escaping (Double) -> Void) {
        self.title = title
        self.value = value
        self.range = range
        self.style = style
        self.onCommit = onCommit
        _draft = State(initialValue: value)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                Text(title).font(.caption).fixedSize()
                slider.frame(width: 118)
                valueLabel
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption)
                HStack(spacing: 7) {
                    slider.frame(minWidth: 48)
                    valueLabel
                }
            }
        }
        .onChange(of: value) { _, newValue in
            if !isEditing { draft = newValue }
        }
    }

    private var slider: some View {
        Slider(value: $draft, in: range) { editing in
            isEditing = editing
            if !editing { onCommit(draft) }
        }
        .accessibilityLabel(title)
        .accessibilityValue(style.text(draft))
    }

    private var valueLabel: some View {
        Text(style.text(draft))
            .font(.caption.monospacedDigit())
            .fixedSize()
            .frame(minWidth: 42, alignment: .trailing)
    }
}

private struct TimelineInspector: View {
    @EnvironmentObject var model: AppModel
    // The navigation column is intentionally fixed at 225 pt. A single
    // flexible column keeps controls readable instead of clipping adaptive
    // cards against both edges.
    private let columns = [GridItem(.flexible(minimum: 0), spacing: 10, alignment: .topLeading)]
    @State private var titleText = ""
    @State private var titleAtEnd = false
    @State private var editingTitleText = ""
    @State private var aiTitleInstruction = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Label("Настройки", systemImage: "gearshape.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button(action: model.closeTimelineInspector) {
                        Image(systemName: "xmark")
                            .font(.headline)
                    }
                    .buttonStyle(.borderless)
                    .help("Закрыть настройки")
                    .controlSize(.small)
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24, alignment: .center)
                    .contentShape(Rectangle())
                }
                if let title = model.selectedTitleTimelineItem {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        inspectorGroup("Текст") { modernTitleTextControls(title) }
                        inspectorGroup("Шаблон и стиль") { modernTitleStyleControls(title) }
                        inspectorGroup("✨ Изменить с помощью AI") { modernTitleAIControls(title) }
                    }
                    .disabled(model.isTimelineInteractionBlocked)
                } else if let title = model.selectedTimelineItem, title.kind == .title {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        inspectorGroup("Текст") { titleStyleControls(title) }
                        inspectorGroup("Действия") { itemActions(title) }
                    }
                    .disabled(model.isTimelineInteractionBlocked)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            editingTitleText = model.selectedTimelineItem?.title ?? ""
        }
        .onChange(of: model.selectedTimelineItemID) { _, _ in
            editingTitleText = model.selectedTimelineItem?.title ?? ""
        }
        .onChange(of: model.selectedTitleTimelineItemID) { _, _ in
            aiTitleInstruction = ""
        }
        .onChange(of: editingTitleText) { _, value in
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, value != model.selectedTimelineItem?.title else { return }
            model.setSelectedTitleText(value)
        }
    }

    private func effectIdentity(_ item: EffectTimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(item.effectType.localizedTitle, systemImage: "wand.and.rays")
                .font(.subheadline.weight(.semibold))
            Text("\(item.effectType.category.localizedTitle) · \(item.startTime, specifier: "%.2f")–\(item.endTime, specifier: "%.2f") с")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Эффект включён", isOn: Binding(get: { item.enabled }, set: model.setSelectedEffectEnabled))
        }
    }

    private func effectControls(_ item: EffectTimelineItem) -> some View {
        let preset = EffectPresetRegistry.preset(for: item.effectType)
        let regular = preset.parameters.filter { $0.key != "intensity" && !$0.isAdvanced }
        let advanced = preset.parameters.filter(\.isAdvanced)
        return VStack(alignment: .leading, spacing: 9) {
            ViewerValueSlider(title: "Интенсивность", value: item.intensity, range: 0...1, style: .percent, onCommit: model.setSelectedEffectIntensity)
            ForEach(regular) { parameter in
                effectParameterControl(item: item, parameter: parameter)
            }
            if !advanced.isEmpty {
                DisclosureGroup("Transform, Crop и Opacity") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(advanced) { parameter in
                            effectParameterControl(item: item, parameter: parameter)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            Stepper("Длительность: \(item.duration, specifier: "%.2f") с", value: Binding(
                get: { item.duration }, set: model.setSelectedEffectDuration
            ), in: 0.05...max(0.05, model.timeline?.duration ?? item.duration), step: 0.1)
            Text("Перетащите блок эффекта на Timeline, чтобы изменить начало.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func effectParameterControl(item: EffectTimelineItem, parameter: RenderParameterDescriptor) -> some View {
        let value = item.parameters.first(where: { $0.name == parameter.key })?.effectiveNumericValue ?? parameter.defaultValue
        switch parameter.valueType {
        case .bool:
            Toggle(parameter.title, isOn: Binding(
                get: { value >= 0.5 },
                set: { model.setSelectedEffectParameter(parameter.key, value: $0 ? 1 : 0) }
            ))
        case .enumeration:
            Picker(parameter.title, selection: Binding(
                get: { min(max(0, Int(value.rounded())), max(0, parameter.enumOptions.count - 1)) },
                set: { model.setSelectedEffectParameter(parameter.key, value: Double($0)) }
            )) {
                ForEach(Array(parameter.enumOptions.enumerated()), id: \.offset) { index, option in
                    Text(option).tag(index)
                }
            }
        default:
            ViewerValueSlider(
                title: parameter.title,
                value: value,
                range: parameter.range,
                style: .decimal(parameter.unit.map { " \($0)" } ?? "")
            ) { model.setSelectedEffectParameter(parameter.key, value: $0) }
        }
    }

    private func effectKeyframeControls(_ item: EffectTimelineItem) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            Menu("Добавить в позиции playhead", systemImage: "diamond") {
                ForEach(EffectPresetRegistry.preset(for: item.effectType).parameters.filter(\.supportsKeyframes)) { parameter in
                    Button(parameter.title) { model.addSelectedEffectKeyframe(parameter: parameter.key) }
                }
            }
            Button("Вставить keyframe в playhead", systemImage: "doc.on.clipboard") {
                model.pasteSelectedEffectKeyframe()
            }
            .disabled(!model.canPasteEffectKeyframe)
            ForEach(item.keyframes) { keyframe in
                if let descriptor = EffectPresetRegistry.preset(for: item.effectType).parameter(named: keyframe.parameter) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                            Text(descriptor.title).font(.caption.weight(.medium))
                            Spacer()
                            Button { model.copySelectedEffectKeyframe(keyframe.id) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("Копировать keyframe")
                            Button(role: .destructive) { model.removeSelectedEffectKeyframe(keyframe.id) } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                        ViewerValueSlider(title: "Время", value: keyframe.time, range: 0...item.duration, style: .decimal(" с")) {
                            model.setSelectedEffectKeyframe(keyframe.id, time: $0)
                        }
                        ViewerValueSlider(title: "Значение", value: keyframe.effectiveNumericValue, range: descriptor.range, style: .decimal(descriptor.unit.map { " \($0)" } ?? "")) {
                            model.setSelectedEffectKeyframe(keyframe.id, value: $0)
                        }
                        Picker("Easing", selection: Binding(
                            get: { keyframe.easing },
                            set: { model.setSelectedEffectKeyframeEasing(keyframe.id, easing: $0) }
                        )) {
                            ForEach(KeyframeEasing.allCases) { Text($0.localizedTitle).tag($0) }
                        }
                    }
                    .padding(7)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if item.keyframes.isEmpty {
                Text("Keyframes поддерживают linear/ease и дополнительные cubic/back/elastic/bounce кривые.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func effectActions(_ item: EffectTimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button("Копировать", systemImage: "doc.on.doc", action: model.copySelectedEffectTimelineItem)
                Button("Вставить", systemImage: "doc.on.clipboard") { model.pasteEffectTimelineItem() }
                    .disabled(!model.canPasteEffectTimelineItem)
            }
            HStack {
                Button("Выше", systemImage: "arrow.up") { model.moveSelectedEffectInStack(-1) }
                Button("Ниже", systemImage: "arrow.down") { model.moveSelectedEffectInStack(1) }
            }
            HStack {
            Button("Дублировать", systemImage: "plus.square.on.square", action: model.duplicateSelectedEffectTimelineItem)
            Button("Удалить", systemImage: "trash", role: .destructive, action: model.deleteSelectedTimelineObject)
            }
        }
    }

    private func modernTitleTextControls(_ item: TitleTimelineItem) -> some View {
        let template = TitleTemplateRegistry.template(for: item)
        let supportsSecondary = template?.layout.elements.contains(where: { $0.content == .secondaryText }) == true
        let supportsCTA = template?.layout.elements.contains(where: { $0.content == .callToAction }) == true
        return VStack(alignment: .leading, spacing: 8) {
            Label(template?.name ?? item.kind.localizedTitle, systemImage: item.kind.category == .captions ? "captions.bubble" : "textformat")
                .font(.subheadline.weight(.semibold))
            titleTextEditor("Текст", text: Binding(
                get: { model.selectedTitleTimelineItem?.text ?? "" },
                set: model.setSelectedModernTitleText
            ))
            Text("Enter — новая строка. Длинные строки переносятся автоматически.")
                .font(.caption2).foregroundStyle(.secondary)
            if template?.layout.elements.contains(where: { $0.content == .chapterNumber }) == true {
                LabeledContent("Номер главы") {
                    TextField("Номер главы", value: Binding(
                        get: { model.selectedTitleTimelineItem?.effectiveChapterNumber ?? 1 },
                        set: model.setSelectedModernTitleChapterNumber
                    ), format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 55)
                }
            }
            if supportsSecondary {
                titleTextEditor("Подзаголовок", text: Binding(
                    get: { model.selectedTitleTimelineItem?.additionalText ?? "" },
                    set: model.setSelectedModernTitleAdditionalText
                ), height: 42)
            }
            if supportsCTA {
                titleTextEditor("Финальная подпись", text: Binding(
                    get: { model.selectedTitleTimelineItem?.callToAction ?? "" },
                    set: model.setSelectedModernTitleCallToAction
                ), height: 42)
            }
            if !item.words.isEmpty {
                Text("\(item.words.count) слов с word-level timestamps")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func modernTitleStyleControls(_ item: TitleTimelineItem) -> some View {
        let style = item.style
        let sizing = TitleOverlayRenderer.textSizing(item: item, renderSize: CGSize(
            width: model.timeline?.width ?? 1920, height: model.timeline?.height ?? 1080))
        let fontSize = Binding(
            get: { model.selectedTitleTimelineItem?.style.fontSize ?? style.fontSize },
            set: { (value: Double) in
                guard value.isFinite else { return }
                var copy = model.selectedTitleTimelineItem?.style ?? style
                copy.fontSize = min(220, max(18, value))
                model.setSelectedModernTitleStyle(copy)
            }
        )
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Шаблон", selection: Binding(
                get: { item.effectiveTemplateID ?? "" },
                set: model.setSelectedModernTitleTemplate
            )) {
                ForEach(TitleTemplateRegistry.all) { template in
                    Text(template.name).tag(template.id)
                }
            }
            HStack {
                Text("Размер текста")
                Spacer()
                TextField("Размер текста", value: fontSize, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .accessibilityIdentifier("title.font-size")
                Stepper("Размер текста", value: fontSize, in: 18...220, step: 2)
                    .labelsHidden()
            }
            if let sizing, sizing.isReduced {
                Text("В кадре: \(Int(sizing.fontSize.rounded())). Размер ограничен местом в шаблоне — перенесите текст или сократите его.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if sizing?.isTruncated == true {
                Label("Часть текста не помещается. Уменьшите размер или сократите текст.", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
            ColorPicker("Цвет текста", selection: Binding(
                get: { titleColor(style.textColorHex) },
                set: { value in var copy = style; copy.textColorHex = titleHex(value); model.setSelectedModernTitleStyle(copy) }
            ), supportsOpacity: false)
            ViewerValueSlider(title: "Прозрачность", value: style.effectiveOpacity, range: 0...1, style: .percent) { value in
                var copy = style; copy.opacity = value; model.setSelectedModernTitleStyle(copy)
            }
            Text("Текст переносится внутри шаблона. Если места не хватает, размер автоматически уменьшается.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func titleTextEditor(_ label: String, text: Binding<String>, height: CGFloat = 76) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(5)
                .frame(height: height)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.25)) }
                .accessibilityLabel(label)
        }
    }

    private func titleColor(_ hex: String) -> Color {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let number = Int(value, radix: 16) else { return .white }
        return Color(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }

    private func titleHex(_ color: Color) -> String {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", Int(converted.redComponent * 255), Int(converted.greenComponent * 255), Int(converted.blueComponent * 255))
    }

    private func modernTitleAnimationControls(_ item: TitleTimelineItem) -> some View {
        let animation = item.animation
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Появление", selection: Binding(
                get: { animation.entrance },
                set: { value in var copy = animation; copy.entrance = value; model.setSelectedModernTitleAnimation(copy) }
            )) { ForEach(TitleAnimationKind.allCases) { Text($0.rawValue.capitalized).tag($0) } }
            Picker("Исчезновение", selection: Binding(
                get: { animation.exit },
                set: { value in var copy = animation; copy.exit = value; model.setSelectedModernTitleAnimation(copy) }
            )) { ForEach(TitleAnimationKind.allCases) { Text($0.rawValue.capitalized).tag($0) } }
            Picker("Easing", selection: Binding(
                get: { animation.easing },
                set: { value in var copy = animation; copy.easing = value; model.setSelectedModernTitleAnimation(copy) }
            )) { ForEach(KeyframeEasing.allCases) { Text($0.localizedTitle).tag($0) } }
        }
    }

    private func modernTitleAIControls(_ item: TitleTimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.kind == .chapter {
                Button("Обновить названия частей", systemImage: "text.magnifyingglass", action: model.refreshChapterTitles)
                    .disabled(model.isTimelineInteractionBlocked)
            }
            TextField("Например: сделай кинематографичным", text: $aiTitleInstruction)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if model.editSelectedTitleWithAI(aiTitleInstruction) { aiTitleInstruction = "" }
                }
            Button("Изменить существующий титр", systemImage: "sparkles") {
                if model.editSelectedTitleWithAI(aiTitleInstruction) { aiTitleInstruction = "" }
            }
            .disabled(aiTitleInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let message = model.titleEditStatus {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Удалить титр", systemImage: "trash", role: .destructive, action: model.deleteSelectedTimelineObject)
        }
    }

    private func transitionControls(_ item: TimelineTransitionItem) -> some View {
        let preset = TransitionPresetRegistry.preset(for: item.style)
        return VStack(alignment: .leading, spacing: 8) {
            Label(item.style.localizedTitle, systemImage: "rectangle.2.swap")
                .font(.subheadline.weight(.semibold))
            TransitionPreviewArtwork(style: item.style)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: 260)
            Toggle("Переход включён", isOn: Binding(get: { item.enabled }, set: model.setSelectedTransitionEnabled))
            Picker("Тип", selection: Binding(get: { item.style }, set: model.setSelectedTransitionStyle)) {
                ForEach(TransitionStyle.allCases) { Text($0.localizedTitle).tag($0) }
            }
            Picker("Направление", selection: Binding(get: { item.effectiveDirection }, set: model.setSelectedTransitionDirection)) {
                ForEach(TransitionDirection.allCases) { Text($0.localizedTitle).tag($0) }
            }
            Picker("Easing", selection: Binding(get: { item.effectiveEasing }, set: model.setSelectedTransitionEasing)) {
                ForEach(KeyframeEasing.allCases) { Text($0.localizedTitle).tag($0) }
            }
            Stepper("Длительность: \(item.duration, specifier: "%.2f") с", value: Binding(
                get: { item.duration }, set: model.setSelectedTransitionDuration
            ), in: 0.08...4, step: 0.05)
            ViewerValueSlider(
                title: "Интенсивность",
                value: item.effectiveIntensity,
                range: 0...1,
                style: .percent,
                onCommit: model.setSelectedTransitionIntensity
            )
            ForEach(preset.parameters) { parameter in
                ViewerValueSlider(
                    title: parameter.title,
                    value: item.parameterValue(parameter.key),
                    range: parameter.range,
                    style: .decimal(parameter.unit.map { " \($0)" } ?? "")
                ) { model.setSelectedTransitionParameter(parameter.key, value: $0) }
            }
            if !item.explanation.isEmpty {
                Text(item.explanation.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label("Одинаково при просмотре и экспорте", systemImage: "checkmark.seal")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.green)
            Button("Удалить переход", systemImage: "trash", role: .destructive, action: model.deleteSelectedTimelineObject)
        }
    }

    private func telemetryIdentity(_ item: TimelineTelemetryItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.settings.resolvedWidgets.first?.kind.localizedTitle ?? "Телеметрия").font(.subheadline.weight(.semibold))
            Text("Начало: \(item.timelineStart, specifier: "%.2f") с · источник: \(item.sourceStart, specifier: "%.2f") с")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Длительность: \(item.timelineDuration, specifier: "%.2f") с", value: Binding(
                get: { item.timelineDuration }, set: model.setSelectedTelemetryDuration
            ), in: 0.05...max(0.05, model.timeline?.duration ?? item.timelineDuration), step: 0.1)
            Stepper("Синхронизация: \(item.syncOffset, specifier: "%+.2f") с", value: Binding(
                get: { item.syncOffset }, set: model.setSelectedTelemetryOffset
            ), in: -3600...3600, step: 0.033333)
        }
    }

    private func telemetryStyleControls(_ item: TimelineTelemetryItem) -> some View {
        let layout = item.settings.resolvedWidgets.first ?? TelemetryWidgetLayout.defaultLayout(for: .speedValue)
        return VStack(alignment: .leading, spacing: 8) {
            TelemetryWidgetArtwork(kind: layout.kind, presentation: layout.effectivePresentation, style: item.settings.effectiveStyle)
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.12)) }
            Picker("Виджет", selection: Binding(
                get: { layout.kind },
                set: model.setSelectedTelemetryWidget
            )) {
                ForEach(TelemetryWidgetKind.catalogueKinds.filter { !model.availableTelemetryPresentations(for: $0).isEmpty }) {
                    Text($0.localizedTitle).tag($0)
                }
            }
            Picker("Вариант", selection: Binding(
                get: { layout.effectivePresentation },
                set: model.setSelectedTelemetryPresentation
            )) {
                ForEach(model.availableTelemetryPresentations(for: layout.kind)) { Text($0.localizedTitle).tag($0) }
            }
            Picker("OVRLEY стиль", selection: Binding(get: { item.settings.effectiveStyle }, set: model.setSelectedTelemetryStyle)) {
                ForEach(TelemetryWidgetStyle.ovrleyTemplates) { Text($0.localizedTitle).tag($0) }
            }
            ViewerValueSlider(title: "Прозрачность", value: item.settings.effectiveOpacity, range: 0...1, style: .percent, onCommit: model.setSelectedTelemetryOpacity)
        }
    }

    private func telemetryLayoutControls(_ item: TimelineTelemetryItem) -> some View {
        let layout = item.settings.resolvedWidgets.first ?? TelemetryWidgetLayout.defaultLayout(for: .speedometer)
        return VStack(alignment: .leading, spacing: 7) {
            Stepper("X: \(Int(layout.x * 100))%", onIncrement: { model.changeSelectedTelemetryLayout(x: 0.01) }, onDecrement: { model.changeSelectedTelemetryLayout(x: -0.01) })
            Stepper("Y: \(Int(layout.y * 100))%", onIncrement: { model.changeSelectedTelemetryLayout(y: 0.01) }, onDecrement: { model.changeSelectedTelemetryLayout(y: -0.01) })
            Stepper("Ширина: \(Int(layout.width * 100))%", onIncrement: { model.changeSelectedTelemetryLayout(width: 0.01) }, onDecrement: { model.changeSelectedTelemetryLayout(width: -0.01) })
            Stepper("Высота: \(Int(layout.height * 100))%", onIncrement: { model.changeSelectedTelemetryLayout(height: 0.01) }, onDecrement: { model.changeSelectedTelemetryLayout(height: -0.01) })
        }
    }

    private var telemetryActions: some View {
        HStack {
            Button("Копировать", systemImage: "doc.on.doc", action: model.copySelectedTelemetrySettings)
            Button("Вставить", systemImage: "doc.on.clipboard", action: model.pasteSelectedTelemetrySettings).disabled(!model.canPasteTelemetrySettings)
            Button("Дубль", systemImage: "plus.square.on.square", action: model.duplicateSelectedTelemetryItem)
            Button("Удалить", systemImage: "trash", role: .destructive, action: model.deleteSelectedTimelineItem)
        }
    }

    private var inspectorTitle: some View {
        Label("Переходы, эффекты и музыка", systemImage: "sparkles.rectangle.stack")
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var musicControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                originalAudioToggle
                musicPicker
                musicVolumeControl
                musicLibraryButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                originalAudioToggle
                musicPicker
                musicVolumeControl
                musicLibraryButtons
            }
        }
    }

    private var titleControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                TextField("Текст нового титра", text: $titleText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                Toggle("В конце", isOn: $titleAtEnd)
                    .toggleStyle(.checkbox)
                addTitleButton
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("Текст нового титра", text: $titleText)
                    .textFieldStyle(.roundedBorder)
                Toggle("Добавить в конец фильма", isOn: $titleAtEnd)
                addTitleButton
            }
        }
    }

    private var addTitleButton: some View {
        Button("Добавить титр") {
            model.addTitle(titleText, atEnd: titleAtEnd)
            titleText = ""
        }
        .disabled(titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isTimelineInteractionBlocked)
    }

    private var originalAudioToggle: some View {
        Toggle(
            "Звук исходников",
            isOn: Binding(
                get: { (model.timeline?.effectiveOriginalAudioVolume ?? 1) > 0.001 },
                set: model.setOriginalAudioEnabled
            )
        )
        .fixedSize()
    }

    private var musicPicker: some View {
        Picker("Музыка", selection: Binding(
            get: { model.timeline?.music?.trackID?.uuidString ?? (model.timeline?.music == nil ? "none" : "requested") },
            set: { model.setMusicTrack(UUID(uuidString: $0)) }
        )) {
            Text("Без музыки").tag("none")
            if let music = model.timeline?.music, music.trackID == nil {
                Text("Нужен трек: \(music.style.localizedTitle.lowercased())").tag("requested")
            }
            if !model.musicTracks.isEmpty { Divider() }
            ForEach(model.musicTracks) { track in
                Text("\(track.title) — \(track.author)").tag(track.id.uuidString)
            }
        }
        .frame(minWidth: 190, idealWidth: 230, maxWidth: 280)
    }

    private var musicLibraryButtons: some View {
        HStack(spacing: 8) {
            Button("Моя музыка", systemImage: "folder.badge.plus", action: model.chooseMusicFolder)
                .help("Добавить папку с MP3, AAC/M4A, WAV, AIFF или FLAC")
            Button("Online", systemImage: "network", action: model.prepareOnlineMusicLibrary)
                .help("Необязательно: проверить Free To Use и Openverse; ошибки сети не мешают монтажу")
            if model.timeline?.music?.trackID != nil {
                Menu("Другая музыка") {
                    Button("Заменить сейчас", action: model.replaceMusicImmediately)
                    Button("Послушать варианты", action: model.listenToMusicAlternatives)
                    Divider()
                    Button("Не подходит этому настроению") { model.rememberMusicDislike(excludeTrack: false) }
                    Button("Больше не предлагать этот трек") { model.rememberMusicDislike(excludeTrack: true) }
                    Button("Запомнить этот стиль") { model.showEditorialStyle = true }
                }
                Button("Лицензия", systemImage: "doc.on.doc", action: model.copyMusicAttribution)
                    .help("Скопировать лицензию и атрибуцию выбранного трека")
            }
        }
        .fixedSize()
    }

    @ViewBuilder private var musicVolumeControl: some View {
        if let music = model.timeline?.music {
            Stepper(
                "Громкость музыки: \(Int((music.volume * 100).rounded())) процентов",
                value: Binding(get: { music.volume }, set: model.setMusicVolume),
                in: 0.05...0.6,
                step: 0.05
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func clipIdentity(_ item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title ?? "Фрагмент без названия")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(item.kind == .video ? "Видео" : item.kind == .photo ? "Фотография" : "Титр")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var moveButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { model.moveSelectedTimelineItem(-1) }) { Label("Переместить фрагмент левее", systemImage: "arrow.left") }
            Button(action: { model.moveSelectedTimelineItem(1) }) { Label("Переместить фрагмент правее", systemImage: "arrow.right") }
        }
    }

    @ViewBuilder private func trimControls(_ item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.kind == .video {
                Stepper("Начало: \(item.sourceStart, specifier: "%.1f") секунды", onIncrement: { model.changeSelectedSourceStart(by: 0.5) }, onDecrement: { model.changeSelectedSourceStart(by: -0.5) })
                Stepper("Конец: \(item.sourceStart + item.sourceDuration, specifier: "%.1f") секунды", onIncrement: { model.changeSelectedSourceEnd(by: 0.5) }, onDecrement: { model.changeSelectedSourceEnd(by: -0.5) })
            } else {
                Stepper("Длительность: \(item.timelineDuration, specifier: "%.1f") секунды", onIncrement: { model.changeSelectedTimelineDuration(by: 0.5) }, onDecrement: { model.changeSelectedTimelineDuration(by: -0.5) })
            }
            Text("На шкале границы можно тянуть мышью.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func editorPickers(_ item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Переход к фрагменту", selection: Binding(
                get: { item.transition ?? "none" },
                set: { model.setSelectedTransition($0 == "none" ? nil : $0) }
            )) {
                Text("Без перехода").tag("none")
                Divider()
                ForEach(TransitionStyle.allCases.filter { $0 != .cut }) { style in Text(style.localizedTitle).tag(style.rawValue) }
            }
            Picker("Эффект фрагмента", selection: Binding(
                get: { item.effect ?? "none" },
                set: { model.setSelectedEffect($0 == "none" ? nil : $0) }
            )) {
                Text("Без эффекта").tag("none")
                Divider()
                ForEach(ClipEffect.allCases) { effect in Text(effect.localizedTitle).tag(effect.rawValue) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func speedAndFrameControls(_ item: TimelineItem) -> some View {
        let video = item.effectiveVideoAdjustments
        let speedPercentage = Binding<Double>(
            get: { item.speed * 100 },
            set: { model.setSelectedSpeed($0 / 100) }
        )
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text("Скорость")
                Spacer()
                TextField(
                    "100",
                    value: speedPercentage,
                    format: .number.precision(.fractionLength(0...1))
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                Text("%")
                    .foregroundStyle(.secondary)
                Stepper("Скорость в процентах", value: speedPercentage, in: 10...2000, step: 5)
                    .labelsHidden()
            }
            Picker("Рамп скорости", selection: Binding(
                get: {
                    item.speedRamp == .easeIn ? "ease-in" : item.speedRamp == .easeOut ? "ease-out" : item.speedRamp == .action ? "action" : "none"
                },
                set: model.setSelectedSpeedRamp
            )) {
                Text("Без рампа").tag("none")
                Text("Плавный разгон").tag("ease-in")
                Text("Плавное замедление").tag("ease-out")
                Text("Акцент действия").tag("action")
            }
            Picker("Кадр", selection: Binding(get: { video.crop }, set: model.setSelectedCrop)) {
                ForEach(CropStyle.allCases) { Text($0.localizedTitle).tag($0) }
            }
            Picker("Наложение", selection: Binding(
                get: { item.overlay?.style.rawValue ?? "none" },
                set: { model.setSelectedOverlay($0 == "none" ? nil : OverlayStyle(rawValue: $0)) }
            )) {
                Text("Обычный клип").tag("none")
                Divider()
                ForEach(OverlayStyle.allCases) { Text($0.localizedTitle).tag($0.rawValue) }
            }
            HStack {
                Button("Влево", systemImage: "rotate.left") { model.rotateSelected(-1) }
                Button("Вправо", systemImage: "rotate.right") { model.rotateSelected(1) }
            }
            if item.kind == .video {
                Toggle("Телеметрия GoPro", isOn: Binding(
                    get: { item.telemetryOverlay != nil },
                    set: model.setSelectedTelemetryEnabled
                ))
            }
        }
    }

    private func colorControls(_ item: TimelineItem) -> some View {
        let video = item.effectiveVideoAdjustments
        return VStack(alignment: .leading, spacing: 8) {
            Button("Автоулучшение", systemImage: "wand.and.stars") { model.autoEnhanceSelected() }
            Picker("Фильтр", selection: Binding(get: { video.filter }, set: model.setSelectedFilter)) {
                ForEach(VideoFilter.allCases) { Text($0.localizedTitle).tag($0) }
            }
            Stepper("Яркость: \(Int((video.brightness * 100).rounded()))%", onIncrement: { model.changeSelectedBrightness(by: 0.1) }, onDecrement: { model.changeSelectedBrightness(by: -0.1) })
            Stepper("Контраст: \(Int((video.contrast * 100).rounded()))%", onIncrement: { model.changeSelectedContrast(by: 0.1) }, onDecrement: { model.changeSelectedContrast(by: -0.1) })
            Stepper("Насыщенность: \(Int((video.saturation * 100).rounded()))%", onIncrement: { model.changeSelectedSaturation(by: 0.1) }, onDecrement: { model.changeSelectedSaturation(by: -0.1) })
            Stepper("Температура: \(Int((video.warmth * 100).rounded()))%", onIncrement: { model.changeSelectedWarmth(by: 0.1) }, onDecrement: { model.changeSelectedWarmth(by: -0.1) })
            Stepper("Экспозиция: \(video.exposure ?? 0, specifier: "%.1f") EV", onIncrement: { model.changeSelectedExposure(by: 0.2) }, onDecrement: { model.changeSelectedExposure(by: -0.2) })
            Stepper("Света: \(Int(((video.highlights ?? 0) * 100).rounded()))%", onIncrement: { model.changeSelectedHighlights(by: 0.1) }, onDecrement: { model.changeSelectedHighlights(by: -0.1) })
            Stepper("Тени: \(Int(((video.shadows ?? 0) * 100).rounded()))%", onIncrement: { model.changeSelectedShadows(by: 0.1) }, onDecrement: { model.changeSelectedShadows(by: -0.1) })
            Stepper("Виньетка: \(Int(((video.vignette ?? 0) * 100).rounded()))%", onIncrement: { model.changeSelectedVignette(by: 0.1) }, onDecrement: { model.changeSelectedVignette(by: -0.1) })
            Stepper("Зерно: \(Int(((video.grain ?? 0) * 100).rounded()))%", onIncrement: { model.changeSelectedGrain(by: 0.1) }, onDecrement: { model.changeSelectedGrain(by: -0.1) })
            Stepper("Непрозрачность: \(Int((video.opacity * 100).rounded()))%", onIncrement: { model.changeSelectedOpacity(by: 0.1) }, onDecrement: { model.changeSelectedOpacity(by: -0.1) })
        }
    }

    private func clipAudioControls(_ item: TimelineItem) -> some View {
        let audio = item.effectiveAudioAdjustments
        return VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Звук клипа",
                isOn: Binding(get: { !audio.muted }, set: { model.setSelectedClipMuted(!$0) })
            )
            Stepper(
                "Громкость: \(Int((audio.volume * 100).rounded()))%",
                value: Binding(get: { audio.volume }, set: model.setSelectedClipVolume),
                in: 0...2,
                step: 0.1
            )
            Stepper("Появление: \(audio.fadeIn, specifier: "%.1f") с", onIncrement: { model.changeSelectedAudioFadeIn(by: 0.5) }, onDecrement: { model.changeSelectedAudioFadeIn(by: -0.5) })
            Stepper("Затухание: \(audio.fadeOut, specifier: "%.1f") с", onIncrement: { model.changeSelectedAudioFadeOut(by: 0.5) }, onDecrement: { model.changeSelectedAudioFadeOut(by: -0.5) })
            Stepper(
                "Шумоподавление: \(Int(((audio.noiseReduction ?? 0) * 100).rounded()))%",
                value: Binding(get: { audio.noiseReduction ?? 0 }, set: model.setSelectedNoiseReduction),
                in: 0...1,
                step: 0.1
            )
            Picker("Эквалайзер", selection: Binding(get: { audio.eqPreset ?? .flat }, set: model.setSelectedEQ)) {
                Text("Без EQ").tag(AudioEQPreset.flat)
                Text("Голос").tag(AudioEQPreset.voice)
                Text("Музыка").tag(AudioEQPreset.music)
                Text("Меньше баса").tag(AudioEQPreset.bassReduction)
                Text("Присутствие").tag(AudioEQPreset.presence)
            }
        }
    }

    private func titleStyleControls(_ item: TimelineItem) -> some View {
        let style = item.effectiveTitleStyle
        let colors = [
            ("Белый", "#FFFFFF"), ("Чёрный", "#111111"), ("Красный", "#FF3B30"),
            ("Жёлтый", "#FFCC00"), ("Зелёный", "#34C759"), ("Синий", "#007AFF"),
            ("Бирюзовый", "#40E0D0"), ("Фиолетовый", "#AF52DE")
        ]
        return VStack(alignment: .leading, spacing: 8) {
            titleTextEditor("Текст титра", text: $editingTitleText)
            Text("Enter — новая строка.").font(.caption2).foregroundStyle(.secondary)
            Stepper(
                "Размер: \(Int(style.fontSize.rounded()))",
                value: Binding(get: { style.fontSize }, set: model.setSelectedTitleFontSize),
                in: 18...220,
                step: 6
            )
            Picker("Выравнивание", selection: Binding(get: { style.alignment }, set: model.setSelectedTitleAlignment)) {
                Text("Слева").tag(TitleAlignment.left)
                Text("По центру").tag(TitleAlignment.center)
                Text("Справа").tag(TitleAlignment.right)
            }
            Picker("Цвет текста", selection: Binding(get: { style.textColorHex }, set: model.setSelectedTitleTextColor)) {
                ForEach(colors, id: \.1) { Text($0.0).tag($0.1) }
            }
            Picker("Цвет фона", selection: Binding(get: { style.backgroundColorHex }, set: model.setSelectedTitleBackgroundColor)) {
                ForEach(colors, id: \.1) { Text($0.0).tag($0.1) }
            }
        }
    }

    private func itemActions(_ item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: model.toggleSelectedTimelineLock) {
                Label(item.locked ? "Открепить фрагмент" : "Закрепить фрагмент", systemImage: item.locked ? "lock.open" : "lock")
            }
            if item.kind != .title {
                Button(action: model.splitSelectedTimelineItem) { Label("Разделить пополам", systemImage: "scissors") }
            }
            if item.kind == .video {
                Button(action: { model.insertFreezeFrameForSelected() }) {
                    Label("Добавить стоп-кадр", systemImage: "pause.rectangle")
                }
                Button(action: model.toggleSelectedReverse) {
                    Label(item.isReversed ? "Выключить реверс" : "Воспроизвести в обратную сторону", systemImage: "backward.end")
                }
                Button(action: model.insertInstantReplayForSelected) {
                    Label("Добавить мгновенный повтор", systemImage: "arrow.counterclockwise")
                }
            }
            Button(action: model.duplicateSelectedTimelineItem) { Label("Дублировать", systemImage: "plus.square.on.square") }
            Button(role: .destructive, action: model.deleteSelectedTimelineItem) { Label("Удалить фрагмент", systemImage: "trash") }
        }
    }

    private func timelineAudioControls(_ clip: TimelineAudioClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper(
                "Длительность: \(clip.timelineDuration, specifier: "%.1f") с",
                onIncrement: { model.changeSelectedTimelineAudioDuration(by: 0.5) },
                onDecrement: { model.changeSelectedTimelineAudioDuration(by: -0.5) }
            )
            Stepper(
                "Громкость: \(Int((clip.adjustments.volume * 100).rounded()))%",
                value: Binding(get: { clip.adjustments.volume }, set: model.setSelectedTimelineAudioVolume),
                in: 0...2,
                step: 0.1
            )
            Stepper(
                "Скорость: \(Int((clip.effectiveSpeed * 100).rounded()))%",
                value: Binding(get: { clip.effectiveSpeed }, set: model.setSelectedTimelineAudioSpeed),
                in: 0.1...4,
                step: 0.05
            )
            HStack {
                Button("Fade 0,5 с") { model.setSelectedTimelineAudioFades(in: 0.5, out: 0.5) }
                Button("Fade 1,5 с") { model.setSelectedTimelineAudioFades(in: 1.5, out: 1.5) }
            }
            Picker("Эквалайзер", selection: Binding(
                get: { clip.adjustments.eqPreset ?? .flat },
                set: model.setSelectedTimelineAudioEQ
            )) {
                ForEach(AudioEQPreset.allCases) { Text($0.localizedTitle).tag($0) }
            }
            HStack {
                Button("Разделить", action: model.splitSelectedTimelineItem)
                    .disabled(!model.canSplitTimelineSelectionAtPlayhead)
                Button("Удалить", role: .destructive, action: model.deleteSelectedTimelineItem)
            }
        }
    }

    private func inspectorGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct DirectorPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            DirectorChatColumn()
                .frame(minWidth: 450, idealWidth: 610, maxWidth: .infinity)
                .layoutPriority(1)
            DirectorPlayerColumn()
                .frame(minWidth: 300, idealWidth: 480, maxWidth: .infinity)
        }
        .task { await model.refreshAIModelAvailability() }
    }
}

private struct DirectorChatColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ИИ-режиссёр")
                        .font(.title3.weight(.semibold))
                    Text(model.directorStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !model.userMusicTracks.isEmpty {
                    Menu {
                        Button {
                            model.selectDirectorMusicTrack(nil)
                        } label: {
                            Label(
                                "Автоподбор",
                                systemImage: model.directorMusicTrackID == nil && model.directorBrief.musicPolicy == .matchVideo
                                    ? "checkmark"
                                    : "wand.and.stars"
                            )
                        }
                        Divider()
                        ForEach(model.userMusicTracks) { track in
                            Button {
                                model.selectDirectorMusicTrack(track.id)
                            } label: {
                                Label(track.title, systemImage: model.directorMusicTrackID == track.id ? "checkmark" : "music.note")
                            }
                        }
                    } label: {
                        Label(model.directorMusicSelectionTitle, systemImage: "music.note.list")
                            .lineLimit(1)
                    }
                    .help("Выбрать свой трек из медиатеки для создания фильма")
                    .disabled(model.isWorking)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            DirectorConversationView()
                .id(model.project?.id)

            DirectorComposer()
                .padding(14)
        }
    }
}

private struct DirectorConversationView: View {
    @EnvironmentObject var model: AppModel
    @State private var setupQuestionIndex = 0
    @State private var isEnteringCustomDuration = false
    @State private var setupTelemetry: Bool?
    @State private var customDurationText = ""
    @State private var customDurationError: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(model.directorMessages) { message in
                        DirectorMessageBubble(message: message)
                            .id(message.id)
                    }
                    if model.timeline == nil {
                        if isShowingSetupQuestion {
                            directorSetupQuestion(setupQuestions[setupQuestionIndex])
                                .disabled(model.isWorking || model.isDirectorResponding)
                        } else {
                            Button {
                                model.createFilm()
                            } label: {
                                Label("Создать фильм", systemImage: "sparkles")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(model.project?.assets.isEmpty != false || model.isWorking || model.isDirectorResponding)
                            .accessibilityIdentifier("create-film")
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: model.directorMessages.count) {
                scrollToLatest(using: proxy)
            }
            .onChange(of: model.directorMessages.last?.text) {
                scrollToLatest(using: proxy)
            }
        }
    }

    private var isShowingSetupQuestion: Bool {
        !model.directorMessages.contains(where: { $0.role == .user })
            && setupQuestionIndex < setupQuestions.count
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        guard let id = model.directorMessages.last?.id else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
    }

    private enum SetupQuestionKind {
        case canvas
        case duration
        case mood
        case subtitleStyle
        case effects
        case music
        case sourceAudio
        case telemetry
        case titles
    }

    private enum SetupAnswer {
        case automaticCanvas
        case canvas(DirectorCanvasFormat)
        case duration(Double)
        case automaticDuration
        case customDuration
        case mood(DirectorNarrativeMood)
        case vlog
        case subtitleStyle(SpeechCaptionStyle)
        case effects(DirectorEffectsPolicy)
        case music(DirectorMusicPolicy)
        case sourceAudio(DirectorSourceAudioPolicy)
        case telemetry(Bool)
        case titles(DirectorTitlePolicy)
    }

    private struct SetupOption: Identifiable {
        let title: String
        let answer: SetupAnswer

        var id: String { title }
    }

    private struct SetupQuestion {
        let kind: SetupQuestionKind
        let title: String
        let options: [SetupOption]
    }

    private var setupQuestions: [SetupQuestion] {
        var questions = [
            SetupQuestion(
                kind: .mood,
                title: "Какой стиль монтажа выбрать?",
                options: [
                    SetupOption(title: "Спокойный", answer: .mood(.calm)),
                    SetupOption(title: "Киношный", answer: .mood(.cinematic)),
                    SetupOption(title: "Динамичный", answer: .mood(.dynamic)),
                    SetupOption(title: "Влог", answer: .vlog)
                ]
            ),
            SetupQuestion(
                kind: .canvas,
                title: "Какой формат кадра нужен?",
                options: [
                    SetupOption(title: "Как в исходнике", answer: .automaticCanvas),
                    SetupOption(title: "Горизонтальный 16:9", answer: .canvas(.landscape16x9)),
                    SetupOption(title: "Вертикальный 9:16", answer: .canvas(.portrait9x16))
                ]
            ),
            SetupQuestion(
                kind: .duration,
                title: "Какой должна быть длительность?",
                options: [
                    SetupOption(title: "По материалам", answer: .automaticDuration),
                    SetupOption(title: "2 мин", answer: .duration(2)),
                    SetupOption(title: "5 мин", answer: .duration(5)),
                    SetupOption(title: "Другая", answer: .customDuration)
                ]
            ),
            SetupQuestion(
                kind: .effects,
                title: "Сколько эффектов и переходов использовать?",
                options: DirectorEffectsPolicy.allCases.map {
                    SetupOption(title: $0.localizedTitle, answer: .effects($0))
                }
            ),
            SetupQuestion(
                kind: .music,
                title: "Как поступить с музыкой?",
                options: [
                    SetupOption(title: "Подобрать под видео", answer: .music(.matchVideo)),
                    SetupOption(title: "Мягкая и ненавязчивая", answer: .music(.soft)),
                    SetupOption(title: "Без музыки", answer: .music(.none))
                ]
            ),
            SetupQuestion(
                kind: .sourceAudio,
                title: "Что делать со звуком исходников?",
                options: [
                    SetupOption(title: "Оставить", answer: .sourceAudio(.preserve)),
                    SetupOption(title: "Приглушить", answer: .sourceAudio(.duck)),
                    SetupOption(title: "Убрать", answer: .sourceAudio(.mute))
                ]
            ),
            SetupQuestion(
                kind: .titles,
                title: "Сколько титров использовать?",
                options: [
                    SetupOption(title: "Минимально", answer: .titles(.minimal)),
                    SetupOption(title: "Только ключевые", answer: .titles(.keyOnly)),
                    SetupOption(title: "Без титров", answer: .titles(.none))
                ]
            )
        ]
        if model.preset == .vlog || model.directorBrief.subtitlePolicy == .on {
            questions.insert(SetupQuestion(
                kind: .subtitleStyle,
                title: "Как оформить субтитры?",
                options: SpeechCaptionStyle.allCases.map {
                    SetupOption(title: $0.localizedTitle, answer: .subtitleStyle($0))
                }
            ), at: 1)
        }
        if !model.usefulDirectorTelemetry.isEmpty {
            let metrics = model.usefulDirectorTelemetry.prefix(3).map(\.localizedTitle).joined(separator: ", ")
            questions.append(SetupQuestion(kind: .telemetry,
                title: "В исходниках есть \(metrics). Показать в подходящих моментах?",
                options: [SetupOption(title: "Да, короткими акцентами", answer: .telemetry(true)),
                          SetupOption(title: "Без телеметрии", answer: .telemetry(false))]))
        }
        return questions
    }

    private func directorSetupQuestion(_ question: SetupQuestion) -> some View {
        VStack(spacing: 14) {
            Label("Вопрос \(setupQuestionIndex + 1) из \(setupQuestions.count)", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(question.title)
                .font(.body.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            WrappingRowLayout(horizontalSpacing: 8, verticalSpacing: 8, alignment: .center) {
                ForEach(question.options) { option in
                    Button { applySetupAnswer(option) } label: {
                        Text(option.title)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
            if question.kind == .duration, isEnteringCustomDuration {
                HStack(spacing: 8) {
                    TextField("Например, 3,5", text: $customDurationText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                        .onSubmit { commitCustomDuration() }
                    Text("минут")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Продолжить", action: commitCustomDuration)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                if let customDurationError {
                    Text(customDurationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 560)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private func applySetupAnswer(_ option: SetupOption) {
        switch option.answer {
        case .automaticCanvas:
            model.setDirectorCanvasFormatAutomatic()
        case .canvas(let format):
            model.setDirectorCanvasFormat(format)
        case .automaticDuration:
            model.setDurationMode(.automatic)
        case .duration(let minutes):
            model.setTargetMinutes(minutes)
        case .customDuration:
            customDurationText = formattedMinutes(model.targetMinutes)
            customDurationError = nil
            isEnteringCustomDuration = true
            return
        case .subtitleStyle(let style):
            model.setDirectorSubtitleStyle(style)
        case .vlog:
            model.selectPreset(.vlog)
        case .mood(let mood):
            model.selectStandardDirectorMood(mood)
        case .effects(let policy):
            model.setDirectorEffectsPolicy(policy)
        case .music(let policy):
            model.setDirectorMusicPolicy(policy)
        case .sourceAudio(let policy):
            model.setDirectorSourceAudioPolicy(policy)
        case .titles(let policy):
            model.setDirectorTitlePolicy(policy)
        case .telemetry(let enabled):
            setupTelemetry = enabled
        }
        isEnteringCustomDuration = false
        customDurationError = nil
        finishSetupQuestion()
    }

    private func commitCustomDuration() {
        let normalized = customDurationText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let minutes = Double(normalized), minutes.isFinite, (0.5...60).contains(minutes) else {
            customDurationError = "Введите длительность от 0,5 до 60 минут"
            return
        }
        model.setTargetMinutes(minutes)
        isEnteringCustomDuration = false
        customDurationError = nil
        finishSetupQuestion()
    }

    private func finishSetupQuestion() {
        setupQuestionIndex += 1
        if setupQuestionIndex == setupQuestions.count {
            model.directorInput = [directorBriefSummary, model.directorInput]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    private var directorBriefSummary: String {
        let brief = model.directorBrief
        let mood = switch brief.mood {
        case .calm: "спокойное"
        case .cinematic: "киношное"
        case .dynamic: "динамичное"
        }
        let music = switch brief.musicPolicy {
        case .matchVideo: "подобрать под видео"
        case .soft: "мягкая и ненавязчивая"
        case .none: "без музыки"
        case .specificTrack: "использовать выбранный трек"
        }
        let sourceAudio = switch brief.sourceAudioPolicy {
        case .preserve: "оставить звук исходников"
        case .duck: "приглушить звук исходников"
        case .mute: "убрать звук исходников"
        }
        let titles = switch brief.titlePolicy {
        case .minimal: "минимум титров"
        case .keyOnly: "названия каждой части и ключевых событий"
        case .none: "без титров"
        }
        return [
            "Формат: \(brief.canvasFormat.localizedTitle).",
            brief.explicitRequestedDuration.map { "Длительность: \(durationDescription($0))." } ?? "Длительность — по материалам.",
            model.preset == .vlog ? "Стиль: Влог. Субтитры: \(brief.subtitlesEnabled(preset: .vlog) ? "включены" : "выключены")." : "Настроение: \(mood).",
            brief.effectsPolicy.map { "Эффекты: \($0.localizedTitle.lowercased())." } ?? "",
            "Музыка: \(music).",
            "Звук: \(sourceAudio).",
            "Титры: \(titles).",
            setupTelemetry.map { $0 ? "Покажи полезную телеметрию только там, где есть данные." : "Без телеметрии." } ?? ""
        ].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func formattedMinutes(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.001 { return String(Int(rounded)) }
        return String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    private func durationDescription(_ seconds: Double) -> String {
        let roundedSeconds = Int(seconds.rounded())
        let minutes = roundedSeconds / 60
        let remainder = roundedSeconds % 60
        if remainder == 0 { return "\(minutes) мин" }
        if minutes == 0 { return "\(remainder) с" }
        return "\(minutes) мин \(remainder) с"
    }
}

private struct DirectorComposer: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                model.timeline == nil ? "Ответьте на вопросы или напишите своё описание…" : "Опишите, что изменить в фильме…",
                text: $model.directorInput,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...7)
            .onKeyPress(phases: .down) { press in
                guard press.key == .return else { return .ignored }
                if !press.modifiers.isEmpty { return .ignored }
                sendMessage()
                return .handled
            }

            Divider()

            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    AIPowerSelector()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                if model.isDirectorResponding {
                    Button("Остановить ответ", systemImage: "stop.fill", action: model.cancelOperation)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .help("Остановить текущую операцию и продолжить переписку")
                }
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(model.canSendDirectorMessage ? Color.blue : Color.secondary.opacity(0.45), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canSendDirectorMessage)
                .accessibilityLabel("Отправить")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7))
        }
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    private var trimmedInput: String {
        model.directorInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendMessage() {
        guard model.canSendDirectorMessage else { return }
        model.sendDirectorMessage()
    }
}

private struct AIPowerSelector: View {
    @EnvironmentObject var model: AppModel
    @State private var pendingDownloadMode: AIPowerMode?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AIPowerMode.allCases) { mode in
                HStack(spacing: 3) {
                    Button(modeTitle(mode)) {
                        if model.isAIModelInstalled(for: mode) || !model.canDownloadAIModel(for: mode) {
                            model.setAIPowerMode(mode)
                        } else {
                            requestDownload(for: mode)
                        }
                    }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                    .accessibilityLabel(plainModeTitle(mode))
                    .accessibilityValue(mode == model.aiPowerMode ? "Выбрано" : "Не выбрано")
                    .accessibilityHint(modeDescription(mode))
                    .accessibilityIdentifier("ai-power-\(mode.rawValue)")

                    if model.downloadingAIPowerMode == mode {
                        ProgressView(value: model.aiModelDownloadProgress)
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                            .frame(width: 13, height: 13)
                            .help("Загрузка: \(Int(model.aiModelDownloadProgress * 100))%")
                    } else if !model.isAIModelInstalled(for: mode), model.canDownloadAIModel(for: mode) {
                        Button("Загрузить модель для режима \(plainModeTitle(mode))", systemImage: "icloud.and.arrow.down") {
                            requestDownload(for: mode)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("Загрузить локальную модель · \(downloadSize(for: mode))")
                        .disabled(model.downloadingAIPowerMode != nil)
                    }
                }
                .font(.caption2.weight(mode == model.aiPowerMode ? .semibold : .regular))
                .foregroundStyle(mode == model.aiPowerMode ? Color.white : Color.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    mode == model.aiPowerMode ? Color.accentColor : Color.clear,
                    in: Capsule()
                )
                .animation(.easeInOut(duration: 0.16), value: model.aiPowerMode)
            }
        }
        .padding(3)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.45)))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Глубина анализа видео")
        .help("Режим меняет анализ видео. Чат во всех режимах использует Qwen3 4B; точные команды применяются без ожидания нейросети. Сравнение роликов работает во всех режимах.")
        .alert(downloadAlertTitle, isPresented: downloadConfirmationPresented) {
            Button("Отмена", role: .cancel) { pendingDownloadMode = nil }
            Button("Загрузить") {
                guard let mode = pendingDownloadMode else { return }
                pendingDownloadMode = nil
                model.setAIPowerMode(mode)
                model.downloadAIModel(for: mode)
            }
        } message: {
            if let mode = pendingDownloadMode {
                Text("Локальная модель займёт \(downloadSize(for: mode)) на диске. Загрузка начнётся только после подтверждения и может занять некоторое время.")
            }
        }
    }

    private var downloadConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDownloadMode != nil },
            set: { if !$0 { pendingDownloadMode = nil } }
        )
    }

    private func requestDownload(for mode: AIPowerMode) {
        guard model.downloadingAIPowerMode == nil,
              !model.isAIModelInstalled(for: mode),
              model.canDownloadAIModel(for: mode) else { return }
        pendingDownloadMode = mode
    }

    private var downloadAlertTitle: String {
        guard let mode = pendingDownloadMode else { return "Загрузить локальную модель?" }
        return "Загрузить режим «\(plainModeTitle(mode))»?"
    }

    private func downloadSize(for mode: AIPowerMode) -> String {
        AIAnalysisProfile.resolve(
            mode: mode,
            advanced: model.advancedAISettings,
            thermalState: .nominal
        ).estimatedDownloadSize
    }

    private func modeDescription(_ mode: AIPowerMode) -> String {
        switch mode {
        case .fast: return "Быстрый анализ видео"
        case .balanced: return "Баланс скорости и подробности анализа"
        case .quality: return "Подробный анализ видео"
        case .maximum: return "Максимальная глубина анализа видео"
        }
    }

    private func modeTitle(_ mode: AIPowerMode) -> String {
        switch mode {
        case .fast: return "⚡ Быстрый"
        case .balanced: return "⚖️ Баланс"
        case .quality: return "🧠 Качество"
        case .maximum: return "🎬 Максимально"
        }
    }

    private func plainModeTitle(_ mode: AIPowerMode) -> String {
        switch mode {
        case .fast: return "Быстрый"
        case .balanced: return "Баланс"
        case .quality: return "Качество"
        case .maximum: return "Максимально"
        }
    }
}

private struct DirectorMessageBubble: View {
    let message: DirectorMessage

    var body: some View {
        HStack(alignment: .bottom) {
            if message.role == .user { Spacer(minLength: 72) }
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            Group {
                if message.text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Обдумываю ваш замысел")
                    }
                    .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if let response = message.response {
                            Text((response.advisory ? (response.fallback ? "Совет · ограниченные данные" : "Совет") : response.saved ? "Сохранено" : "Результат")
                                + (response.range.map { String(format: " · %.1f–%.1f с", $0.lowerBound, $0.upperBound) } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(message.text).textSelection(.enabled)
                        if let response = message.response, !response.details.isEmpty {
                            DisclosureGroup("Подробности") {
                                Text(response.details.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                message.role == .user ? Color.accentColor : Color(nsColor: .controlBackgroundColor).opacity(0.9),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .foregroundStyle(message.role == .user ? Color.white : Color.primary)
            .frame(maxWidth: 520, alignment: message.role == .user ? .trailing : .leading)
            if message.role == .assistant { Spacer(minLength: 72) }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DirectorFilmSettingsPopover: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Параметры фильма")
                .font(.headline)
            Picker("Стиль", selection: Binding(get: { model.preset }, set: model.selectPreset)) {
                ForEach(FilmPreset.allCases) { Text($0.localizedTitle).tag($0) }
            }
            Picker("Субтитры", selection: Binding(get: { model.directorBrief.subtitlePolicy ?? .automatic }, set: model.setDirectorSubtitlePolicy)) {
                ForEach(DirectorSubtitlePolicy.allCases) { Text($0.localizedTitle).tag($0) }
            }
            Picker("Оформление субтитров", selection: Binding(get: { model.directorBrief.subtitleStyle }, set: model.setDirectorSubtitleStyle)) {
                Text("Не выбрано").tag(SpeechCaptionStyle?.none)
                ForEach(SpeechCaptionStyle.allCases) { Text($0.localizedTitle).tag(Optional($0)) }
            }
            if model.preset == .vlog {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.speechPackageStatus).font(.caption).foregroundStyle(.secondary)
                    if !model.speechPackageInstalled {
                        HStack {
                            Button("Установить речь") { model.installSpeechPackage() }
                            Button("Перенести с диска") { model.installSpeechPackage(fromDisk: true) }
                        }.disabled(model.isWorking)
                        if model.speechPackageProgress > 0 { ProgressView(value: model.speechPackageProgress) }
                    }
                    Text("Записи и расшифровки остаются на этом Mac").font(.caption2).foregroundStyle(.secondary)
                }.task { await model.refreshSpeechPackageStatus() }
            }
            Picker("Эффекты", selection: Binding(
                get: { model.directorBrief.effectsPolicy },
                set: { if let policy = $0 { model.setDirectorEffectsPolicy(policy) } }
            )) {
                if model.directorBrief.effectsPolicy == nil {
                    Text("Не выбрано").tag(Optional<DirectorEffectsPolicy>.none)
                }
                ForEach(DirectorEffectsPolicy.allCases) { Text($0.localizedTitle).tag(Optional($0)) }
            }
            Picker("Режим длительности", selection: Binding(get: { model.directorBrief.durationMode ?? .exact }, set: model.setDurationMode)) {
                Text("Автоматически").tag(FilmDurationMode.automatic)
                Text("Примерно").tag(FilmDurationMode.approximate)
                Text("Точно").tag(FilmDurationMode.exact)
                if model.directorBrief.durationMode == .range { Text("Диапазон из задания").tag(FilmDurationMode.range) }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Длительность")
                    Spacer()
                    Text(durationText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(get: { model.targetMinutes }, set: model.setTargetMinutes),
                    in: (AutomaticFilmDurationPolicy.minimumDuration / 60.0)...60,
                    step: 5.0 / 60.0
                )
                .disabled(model.directorBrief.durationMode == .automatic || model.directorBrief.durationMode == .range)
            }
            Text(model.aiPowerMode.shortDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(model.aiThermalStatus, systemImage: "thermometer.medium")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 310)
    }

    private var durationText: String {
        if model.directorBrief.durationMode == .automatic { return "По материалам" }
        if model.directorBrief.durationMode == .range { return "Из задания" }
        if model.targetMinutes < 1 {
            return "\(max(Int(AutomaticFilmDurationPolicy.minimumDuration), Int((model.targetMinutes * 60).rounded()))) секунд"
        }
        let minutes = Int(model.targetMinutes)
        let seconds = Int((model.targetMinutes - Double(minutes)) * 60)
        return seconds == 0 ? "\(minutes) мин" : "\(minutes) мин \(seconds) с"
    }
}

private struct DirectorPlayerColumn: View {
    @EnvironmentObject var model: AppModel
    @State private var isConfirmingFullRemake = false
    private let playbackControlsHeight: CGFloat = 38

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Проигрыватель")
                        .font(.title3.weight(.semibold))
                    if let timeline = model.timeline {
                        Text(duration(timeline.duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Результат монтажа")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if model.timeline != nil {
                    Button("На весь экран", systemImage: "arrow.up.left.and.arrow.down.right") {
                        FullScreenPreviewPresenter.shared.present(model: model)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.previewPlayer == nil)
                    .help("Открыть просмотр на весь экран (F)")
                    Button("Переделать заново", systemImage: "arrow.trianglehead.2.counterclockwise") {
                        isConfirmingFullRemake = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isWorking || model.isDirectorResponding)
                    .help("Построить новую историю из уже проанализированных исходников")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            GeometryReader { geometry in
                if let player = model.previewPlayer {
                    let canvas = playerCanvasSize(in: geometry.size)
                    VStack(spacing: 0) {
                        TimelinePreviewPlayer(player: player, clock: model.playbackClock)
                            .frame(width: canvas.width, height: canvas.height)
                        MontagePlaybackControls(player: player, clock: model.playbackClock)
                            .frame(width: canvas.width, height: playbackControlsHeight)
                    }
                    .frame(width: canvas.width, height: canvas.height + playbackControlsHeight)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.08))
                    }
                    .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    let canvas = playerCanvasSize(in: geometry.size, includesControls: false)
                    ZStack {
                        Color.black
                        VStack(spacing: 10) {
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 34, weight: .light))
                            Text("Здесь появится фильм")
                                .font(.callout.weight(.medium))
                            Text("Ответьте на вопросы режиссёра — он составит описание и соберёт монтаж")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 260)
                        }
                        .foregroundStyle(.white.opacity(0.88))
                    }
                    .frame(width: canvas.width, height: canvas.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))

        }
        .animation(.easeInOut(duration: 0.2), value: model.playbackReady)
        .confirmationDialog(
            "Переделать фильм с нуля?",
            isPresented: $isConfirmingFullRemake
        ) {
            Button("Переделать заново") { model.remakeFilmFromScratch() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Умный режиссёр сохранит анализ исходников, но заново построит историю и постарается выбрать заметно отличающийся монтаж. Текущая версия останется в истории изменений.")
        }
    }

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return minutes == 0 ? "\(remainingSeconds) с" : "\(minutes) мин \(remainingSeconds) с"
    }

    private var playerAspectRatio: CGFloat {
        guard let timeline = model.timeline, timeline.height > 0 else { return 16 / 9 }
        return CGFloat(timeline.width) / CGFloat(timeline.height)
    }

    private func playerCanvasSize(in available: CGSize, includesControls: Bool = true) -> CGSize {
        let controlsHeight = includesControls ? playbackControlsHeight : 0
        let canvasSpace = CGSize(
            width: max(0, available.width),
            height: max(0, available.height - controlsHeight)
        )
        guard canvasSpace.width > 0, canvasSpace.height > 0, playerAspectRatio > 0 else { return .zero }
        if canvasSpace.width / canvasSpace.height > playerAspectRatio {
            return CGSize(width: canvasSpace.height * playerAspectRatio, height: canvasSpace.height)
        }
        return CGSize(width: canvasSpace.width, height: canvasSpace.width / playerAspectRatio)
    }
}

private struct ActivityPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var displayedTitle = ""
    @State private var displayedStatus = ""
    @State private var displayedProgressLabel = ""
    @State private var delayedUpdate: Task<Void, Never>?

    var body: some View {
        if model.isAnalyzing, !model.activityFileName.isEmpty {
            analysisBody
        } else {
            standardBody
        }
    }

    private var analysisBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.activityFileName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(alignment: .firstTextBaseline) {
                Text("\(Int((model.progress * 100).rounded()))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }

            ProgressView(value: model.progress)
                .controlSize(.small)

            HStack {
                activityRemainingTime
                Spacer()
                Button("Отменить", action: model.cancelOperation)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                if model.isActivityComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 27))
                        .foregroundStyle(.green)
                        .frame(width: 32, height: 32)
                } else if model.activityUnmeasuredStartedAt != nil {
                    ProgressView()
                        .controlSize(.regular)
                        .frame(width: 32, height: 32)
                } else {
                    ZStack {
                        ProgressView(value: model.progress)
                            .progressViewStyle(.circular)
                            .controlSize(.regular)
                        Text("\(Int((model.progress * 100).rounded()))")
                            .font(.system(size: 7, weight: .semibold, design: .rounded))
                    }
                    .frame(width: 32, height: 32)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isActivityComplete ? "Готово" : (displayedTitle.isEmpty ? model.activityTitle : displayedTitle))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if !displayedProgressLabel.isEmpty, !model.isActivityComplete {
                        Text(displayedProgressLabel)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }

            if !model.isActivityComplete, let fraction = model.activityStageProgress {
                ProgressView(value: fraction)
                    .controlSize(.small)
                Text("Этап: \(Int((fraction * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if !model.isActivityComplete, model.activityUnmeasuredStartedAt == nil {
                ProgressView(value: model.progress)
                    .controlSize(.small)
            }

            Text(displayedStatus.isEmpty ? model.status : displayedStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if model.isWorking {
                HStack {
                    activityRemainingTime
                    Spacer()
                    Button("Отменить", action: model.cancelOperation)
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.25)))
        .accessibilityElement(children: .combine)
        .onAppear(perform: updateDisplayedActivity)
        .onChange(of: "\(model.activityTitle)|\(model.status)|\(model.activityProgressLabel)") { _, _ in
            delayedUpdate?.cancel()
            if model.activityUnmeasuredStartedAt != nil {
                updateDisplayedActivity()
                return
            }
            delayedUpdate = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                updateDisplayedActivity()
            }
        }
        .onChange(of: model.isActivityComplete) { _, complete in
            if complete { updateDisplayedActivity() }
        }
        .onDisappear { delayedUpdate?.cancel() }
    }

    private func updateDisplayedActivity() {
        displayedTitle = model.activityTitle
        displayedStatus = model.status
        displayedProgressLabel = model.activityProgressLabel
    }

    @ViewBuilder private var activityRemainingTime: some View {
        if model.isWorking {
            VStack(alignment: .leading, spacing: 3) {
                Label(model.activityTimeRemaining.isEmpty ? "Уточняю время…" : model.activityTimeRemaining, systemImage: "clock")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(model.isCreatingFilm
                          ? "Примерное время до готовности фильма, включая проверку и подготовку просмотра. Прогноз уточняется по скорости обработки."
                          : "Примерное время до конца текущего этапа. Прогноз уточняется по скорости обработки.")
                if let start = model.activityStartedUptime {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let elapsed = max(0, Int(ProcessInfo.processInfo.systemUptime - start))
                        Text(String(format: "Прошло %d:%02d", elapsed / 60, elapsed % 60))
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }

}

private struct AssetSummaryGrid: View {
    @EnvironmentObject var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]
    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(model.project?.assets.prefix(12) ?? []) { asset in
                VStack(alignment: .leading, spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                        MediaThumbnail(url: model.thumbnailURLs[asset.id], kind: asset.kind)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        if asset.kind == .video {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white)
                                .shadow(radius: 3)
                        }
                    }.frame(height: 84)
                    Text(asset.displayName)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(model.selectedAssetID == asset.id ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .onTapGesture { model.selectedAssetID = asset.id }
            }
        }
    }
}

private struct TimelineStrip: View {
    @EnvironmentObject var model: AppModel
    let timeline: Timeline
    @State private var draggedItemID: UUID?
    @State private var dragTranslation: CGFloat = 0
    @State private var trimPreview: TrimPreview?

    private let itemSpacing: CGFloat = 3
    private let trimPointsPerSecond = 20.0

    private enum TrimEdge: Equatable {
        case leading
        case trailing
    }

    private struct TrimPreview {
        let itemID: UUID
        let edge: TrimEdge
        let sourceStart: Double
        let timelineDuration: Double
        let handleOffset: CGFloat
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            timelineHeader
            timelineItems
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(minHeight: 126)
    }

    private var timelineHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Монтажная шкала").font(.headline)
                Text("\(timeline.items.count) фрагментов · \(durationText(timeline.duration))")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                TextField("Опишите необходимые изменения", text: $model.feedback)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        guard !model.feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              !model.isWorking
                        else { return }
                        model.regenerate()
                    }
                Button("Применить правки", systemImage: "wand.and.stars", action: model.regenerate)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.feedback.isEmpty || model.isWorking)
            }
            Label("Тяните фрагмент за середину, чтобы переместить. Выберите его и тяните боковые ручки, чтобы изменить начало или конец.", systemImage: "hand.draw")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
    }

    private var timelineItems: some View {
        ScrollView(.horizontal) {
            HStack(spacing: itemSpacing) {
                ForEach(timeline.items) { item in
                    timelineCard(item)
                }
            }
            .padding(.top, trimPreview == nil ? 0 : 28)
            .padding(.horizontal, 16)
            .animation(.easeInOut(duration: 0.16), value: timeline.items.map(\.id))
        }
    }

    private func timelineCard(_ item: TimelineItem) -> some View {
        let selected = model.isTimelineItemSelected(item.id)
        let preview = trimPreview?.itemID == item.id ? trimPreview : nil
        let shownDuration = preview?.timelineDuration ?? item.timelineDuration
        let shownStart = preview?.sourceStart ?? item.sourceStart

        return VStack(alignment: .leading, spacing: 4) {
            timelineThumbnail(item)
            Text(item.title ?? String(format: "%.1f секунды", shownDuration))
                .font(.caption)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
            if item.kind == .video {
                Text("\(timeText(shownStart)) – \(timeText(shownStart + shownDuration * item.speed))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            timelineBadges(item)
        }
        .padding(6)
        .frame(width: cardWidth(item), alignment: .leading)
        .frame(minHeight: 88, alignment: .leading)
        .background(cardColor(for: item), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .overlay {
            Color.clear
                .contentShape(Rectangle())
                .padding(.horizontal, selected ? 16 : 0)
                .onTapGesture { model.selectTimelineItem(item.id, modifiers: NSEvent.modifierFlags) }
                .gesture(reorderGesture(for: item))
                .allowsHitTesting(!model.isTimelineInteractionBlocked)
        }
        .overlay(alignment: .leading) {
            if selected, item.kind == .video {
                trimHandle(edge: .leading, item: item, preview: preview)
            }
        }
        .overlay(alignment: .trailing) {
            if selected {
                trimHandle(edge: .trailing, item: item, preview: preview)
            }
        }
        .overlay(alignment: .top) {
            if let preview {
                Text(trimDescription(preview, item: item))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(Color.white)
                    .background(Color.accentColor, in: Capsule())
                    .offset(y: -27)
            }
        }
        .offset(x: draggedItemID == item.id ? dragTranslation : 0)
        .scaleEffect(draggedItemID == item.id ? 1.025 : 1)
        .shadow(color: .black.opacity(draggedItemID == item.id ? 0.25 : 0), radius: 7, y: 3)
        .zIndex(draggedItemID == item.id || preview != nil ? 2 : 0)
    }

    private func reorderGesture(for item: TimelineItem) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if draggedItemID == nil {
                    draggedItemID = item.id
                    model.selectTimelineItem(item.id)
                }
                guard draggedItemID == item.id else { return }
                let translation = value.translation.width
                dragTranslation = translation
            }
            .onEnded { value in
                guard draggedItemID == item.id else { return }
                let translation = value.translation.width
                let destination = destinationIndex(for: item, translation: translation)
                let source = timeline.items.firstIndex(where: { $0.id == item.id })
                withAnimation(.easeOut(duration: 0.15)) {
                    draggedItemID = nil
                    dragTranslation = 0
                }
                if let source, source != destination {
                    model.moveTimelineItem(item.id, toIndex: destination)
                }
            }
    }

    private func trimHandle(edge: TrimEdge, item: TimelineItem, preview: TrimPreview?) -> some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 7)
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.85), lineWidth: 1)
            }
            .padding(.vertical, 7)
            .frame(width: 22)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .offset(x: preview?.edge == edge ? preview?.handleOffset ?? 0 : 0)
            .gesture(trimGesture(edge: edge, item: item))
            .allowsHitTesting(!model.isTimelineInteractionBlocked)
            .help(edge == .leading ? "Потяните, чтобы изменить начало фрагмента" : "Потяните, чтобы изменить конец фрагмента")
            .accessibilityLabel(edge == .leading ? "Изменить начало фрагмента" : "Изменить конец фрагмента")
    }

    private func trimGesture(edge: TrimEdge, item: TimelineItem) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                model.selectTimelineItem(item.id)
                trimPreview = makeTrimPreview(for: item, edge: edge, translation: value.translation.width)
            }
            .onEnded { _ in
                guard let preview = trimPreview,
                      preview.itemID == item.id,
                      preview.edge == edge
                else { return }
                trimPreview = nil
                let startChanged = abs(preview.sourceStart - item.sourceStart) > 0.001
                let durationChanged = abs(preview.timelineDuration - item.timelineDuration) > 0.001
                if startChanged || durationChanged {
                    model.trimTimelineItem(
                        id: item.id,
                        sourceStart: preview.sourceStart,
                        timelineDuration: preview.timelineDuration
                    )
                }
            }
    }

    private func makeTrimPreview(for item: TimelineItem, edge: TrimEdge, translation: CGFloat) -> TrimPreview {
        let requestedDelta = Double(translation) / trimPointsPerSecond
        switch edge {
        case .leading:
            let minimumDelta = -item.sourceStart / item.speed
            let maximumDelta = item.timelineDuration - 0.25
            let delta = min(max(requestedDelta, minimumDelta), maximumDelta)
            return TrimPreview(
                itemID: item.id,
                edge: edge,
                sourceStart: item.sourceStart + delta * item.speed,
                timelineDuration: item.timelineDuration - delta,
                handleOffset: CGFloat(delta * trimPointsPerSecond)
            )
        case .trailing:
            let maximumDuration: Double
            if item.kind == .video {
                maximumDuration = item.assetID.flatMap { assetID in
                    model.project?.assets.first(where: { $0.id == assetID })?.metadata.duration
                }.map { max(0.25, ($0 - item.sourceStart) / item.speed) } ?? item.timelineDuration
            } else {
                maximumDuration = 60 * 60
            }
            let duration = min(max(0.25, item.timelineDuration + requestedDelta), maximumDuration)
            let appliedDelta = duration - item.timelineDuration
            return TrimPreview(
                itemID: item.id,
                edge: edge,
                sourceStart: item.sourceStart,
                timelineDuration: duration,
                handleOffset: CGFloat(appliedDelta * trimPointsPerSecond)
            )
        }
    }

    private func destinationIndex(for item: TimelineItem, translation: CGFloat) -> Int {
        guard let sourceIndex = timeline.items.firstIndex(where: { $0.id == item.id }) else { return 0 }
        var centers: [CGFloat] = []
        var cursor: CGFloat = 0
        for timelineItem in timeline.items {
            let width = cardWidth(timelineItem)
            centers.append(cursor + width / 2)
            cursor += width + itemSpacing
        }
        let proposedCenter = centers[sourceIndex] + translation
        return centers.indices.min { abs(centers[$0] - proposedCenter) < abs(centers[$1] - proposedCenter) } ?? sourceIndex
    }

    private func cardWidth(_ item: TimelineItem) -> CGFloat {
        max(120, min(220, CGFloat(item.timelineDuration * 16)))
    }

    private func trimDescription(_ preview: TrimPreview, item: TimelineItem) -> String {
        if item.kind == .video {
            let sourcePerTimelineSecond = 1 / max(0.01, item.speedRamp?.outputDuration(sourceDuration: 1) ?? (1 / item.speed))
            let value = preview.edge == .leading
                ? preview.sourceStart
                : preview.sourceStart + preview.timelineDuration * sourcePerTimelineSecond
            return preview.edge == .leading ? "Начало \(timeText(value))" : "Конец \(timeText(value))"
        }
        return "Длительность \(timeText(preview.timelineDuration))"
    }

    private func timeText(_ seconds: Double) -> String {
        String(format: "%.1f с", max(0, seconds))
    }

    @ViewBuilder private func timelineThumbnail(_ item: TimelineItem) -> some View {
        if let assetID = item.assetID,
           let asset = model.project?.assets.first(where: { $0.id == assetID }) {
            MediaThumbnail(url: model.timelineThumbnailURLs[item.id] ?? model.thumbnailURLs[assetID], kind: asset.kind)
                .frame(height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: icon(item)).font(.title3)
        }
    }

    private func timelineBadges(_ item: TimelineItem) -> some View {
        HStack(spacing: 5) {
            if let transition = item.transition {
                Image(systemName: "rectangle.2.swap")
                    .help("Переход: \(TransitionStyle(rawValue: transition)?.localizedTitle ?? "")")
            }
            if let effect = item.effect {
                Image(systemName: "wand.and.rays")
                    .help("Эффект: \(ClipEffect(rawValue: effect)?.localizedTitle ?? "")")
            }
            if item.locked { Image(systemName: "lock.fill") }
        }
        .font(.caption2)
    }

    private func cardColor(for item: TimelineItem) -> Color {
        switch item.kind {
        case .photo: return .orange.opacity(0.22)
        case .title: return .purple.opacity(0.22)
        case .video: return .blue.opacity(0.22)
        }
    }

    private func durationText(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        if minutes == 0 { return "\(remainingSeconds) секунд" }
        return "\(minutes) минут \(remainingSeconds) секунд"
    }
    private func icon(_ item: TimelineItem) -> String { switch item.kind { case .video: return "video"; case .photo: return "photo"; case .title: return "textformat" } }
}

private struct MediaThumbnail: View {
    let url: URL?
    let kind: MediaKind

    var body: some View {
        CachedThumbnailImage(url: url, kind: kind, contentMode: .fit)
    }
}

private struct EmptyTimelineView: View {
    var body: some View { ContentUnavailableView("Монтажная шкала пока пуста", systemImage: "timeline.selection", description: Text("Запустите анализ и нажмите «Создать фильм»." )).frame(minHeight: 145) }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionCard("Знакомство с VeloEdit") {
                    HStack(spacing: 12) {
                        SettingsActionDescription(icon: "play.rectangle", title: "Первый кадр",
                                                  description: "Посмотрите вступление ещё раз и вернитесь к текущему экрану.")
                        Spacer(minLength: 12)
                        Button("Посмотреть вступление") { model.intro.replay() }
                            .buttonStyle(.bordered)
                    }
                }
                SettingsSectionCard("Статистика всех проектов") {
                    HStack(spacing: 12) {
                        SettingsStatistic(
                            value: durationText(model.usageStatistics.sourceContentDuration),
                            title: "исходного видео",
                            icon: "clock.fill",
                            color: .blue
                        )
                        .help("Полная длительность уникальных исходных видео во всех проектах. Повторное использование и длительность монтажа не влияют на сумму.")
                        SettingsStatistic(
                            value: "\(model.usageStatistics.projectCount)",
                            title: projectWord(model.usageStatistics.projectCount),
                            icon: "film.stack.fill",
                            color: .purple
                        )
                        SettingsStatistic(
                            value: "\(model.usageStatistics.sourceAssetCount)",
                            title: materialWord(model.usageStatistics.sourceAssetCount),
                            icon: "sparkles.rectangle.stack.fill",
                            color: .orange
                        )
                        .help("Уникальные импортированные видео и фотографии во всех проектах, включая ещё не проанализированные. Встроенные фоны не учитываются.")
                    }
                }

                SettingsSectionCard("Профиль предпочтений") {
                    SettingsActionDescription(
                        icon: "sparkles",
                        title: "Базовый стиль",
                        description: "Встроенный стиль монтажа доступен сразу во всех режимах ИИ. Ваши последующие правки уточняют его для вас."
                    )
                    SettingsActionDescription(
                        icon: "wand.and.stars",
                        title: "Личные предпочтения",
                        description: "Профиль учится на изменениях монтажа и одобренных примерах: темпе, сценах, музыке и эффектах. Импорт, экспорт и сброс относятся к вашим предпочтениям; встроенная база сохраняется."
                    )
                    HStack(spacing: 10) {
                        Button(action: model.importPersonalTasteProfile) {
                            Label("Импортировать", systemImage: "square.and.arrow.down")
                        }
                        Button(action: model.exportPersonalTasteProfile) {
                            Label("Экспортировать", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(.bordered)
                }

                SettingsSectionCard("Обслуживание") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            SettingsActionDescription(icon: "arrow.down.circle", title: "Обновления VeloEdit",
                                                      description: updater.status)
                            Spacer(minLength: 12)
                            Button("Проверить обновления…", action: updater.checkForUpdates)
                                .buttonStyle(.borderedProminent)
                                .disabled(!updater.canCheckForUpdates)
                        }
                        Toggle("Проверять обновления автоматически", isOn: Binding(
                            get: { updater.automaticallyChecksForUpdates },
                            set: { updater.setAutomaticChecks($0) }
                        ))
                        if let date = updater.lastCheckDate {
                            Text("Последняя проверка: \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    HStack(spacing: 12) {
                        SettingsActionDescription(
                            icon: "stethoscope",
                            title: "Диагностика",
                            description: "Сохранить технический отчёт для поиска неполадок."
                        )
                        Spacer(minLength: 12)
                        Button("Экспортировать…", action: model.exportDiagnostics)
                            .buttonStyle(.bordered)
                    }
                }

                Label("Материалы и профиль предпочтений хранятся локально на этом Mac.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: model.refreshUsageStatistics)
    }

    private func durationText(_ seconds: Double) -> String {
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours) ч \(minutes) мин" }
        return "\(totalMinutes) мин"
    }

    private func projectWord(_ count: Int) -> String {
        russianCountWord(count, one: "проект всего", few: "проекта всего", many: "проектов всего")
    }

    private func materialWord(_ count: Int) -> String {
        russianCountWord(count, one: "уникальный материал", few: "уникальных материала", many: "уникальных материалов")
    }

    private func russianCountWord(_ count: Int, one: String, few: String, many: String) -> String {
        let lastTwo = count % 100
        if (11...14).contains(lastTwo) { return many }
        switch count % 10 {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
    }
}

private struct SettingsStatistic: View {
    let value: String
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 105, alignment: .topLeading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsActionDescription: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
