import SwiftUI
import AVKit
import AppKit
import Combine
import UniformTypeIdentifiers
import VeloEditCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var isRenamingProject = false
    @State private var projectName = ""

    private var sourceAssets: [MediaAsset] {
        let assets = (model.project?.assets ?? []).filter { BackgroundPreset.preset(for: $0) == nil }
        let order = Dictionary(uniqueKeysWithValues: (model.project?.sourceMap?.entries ?? []).map { ($0.assetID, $0.order) })
        return assets.sorted {
            let lhs = order[$0.id] ?? Int.max
            let rhs = order[$1.id] ?? Int.max
            if lhs != rhs { return lhs < rhs }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
            } detail: {
                Group {
                    if model.project == nil { WelcomeView() }
                    else { selectedWorkspace }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // NavigationSplitView intentionally draws below the unified macOS
            // toolbar. Lists compensate for that automatically, while the
            // editor's fixed headers do not, so their first row was hidden.
            // This small clearance keeps every column below the toolbar without
            // restoring the former oversized empty header band.
            .padding(.top, model.section == .timeline && model.isTimelineInspectorPresented ? 0 : 30)
            .onAppear { updateColumnVisibility(for: geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in
                updateColumnVisibility(for: width)
            }
        }
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .onExitCommand(perform: handleEscape)
        .alert("VeloEdit", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Закрыть", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("Переименовать проект", isPresented: $isRenamingProject) {
            TextField("Название проекта", text: $projectName)
            Button("Сохранить") { model.renameProject(to: projectName) }
                .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Введите новое название. Имя пакета на диске не изменится.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Group {
                if model.isTimelineInspectorPresented {
                    TimelineInspector()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                } else {
                    navigationSidebar
                }
            }

            if model.shouldShowActivityPanel {
                Divider()
                ActivityPanel()
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.shouldShowActivityPanel)
        .navigationSplitViewColumnWidth(min: 225, ideal: 225, max: 225)
    }

    private var navigationSidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(model.project?.name ?? "Нет проекта", systemImage: "film.stack")
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
                    .disabled(model.project == nil)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("Материалов: \(sourceAssets.count)", systemImage: "photo.on.rectangle.angled")
                    Label("Проанализировано: \(model.project?.analyses.count ?? 0)", systemImage: "brain.head.profile")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
                        model.section = section
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
                    .disabled(model.project == nil && section != .home)
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
                                MediaThumbnail(url: model.thumbnailURLs[asset.id], kind: asset.kind)
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
                            .background(model.selectedAssetID == asset.id ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
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
                switch model.section {
                case .home: WelcomeView()
                case .media: MediaLibraryView()
                case .director: DirectorPanel()
                case .timeline: TimelineWorkspaceView()
                case .export: ExportWorkspaceView()
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if model.isDropTarget {
                RoundedRectangle(cornerRadius: 18).strokeBorder(.blue, style: StrokeStyle(lineWidth: 4, dash: [10])).padding(18)
                    .background(.blue.opacity(0.08)).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $model.isDropTarget, perform: model.handleDrop)
    }

    private static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return minutes == 0 ? "\(remainingSeconds) секунд" : "\(minutes) минут \(remainingSeconds) секунд"
    }
    private static func resolution(_ metadata: MediaMetadata) -> String { if let w = metadata.width, let h = metadata.height { return "\(w)×\(h)" }; return "Фотография" }

    private func updateColumnVisibility(for width: CGFloat) {
        let preferred: NavigationSplitViewVisibility = width < 640 ? .detailOnly : .all
        if columnVisibility != preferred { columnVisibility = preferred }
    }

    private func presentProjectRename() {
        guard let name = model.project?.name else { return }
        projectName = name
        isRenamingProject = true
    }

    private func handleEscape() {
        if let window = NSApp.keyWindow, window.firstResponder is NSTextView {
            window.makeFirstResponder(nil)
        } else {
            model.handleEscape()
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    var posterImage: NSImage? = nil
    var showsPoster = false
    var showsControls = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerView.player = player
        view.playerView.controlsStyle = showsControls ? .floating : .none
        context.coordinator.installPoster(in: view.playerView)
        context.coordinator.updatePoster(image: posterImage, isVisible: showsPoster)
        return view
    }

    func updateNSView(_ view: PlayerContainerView, context: Context) {
        if view.playerView.player !== player { view.playerView.player = player }
        view.playerView.controlsStyle = showsControls ? .floating : .none
        context.coordinator.installPoster(in: view.playerView)
        context.coordinator.updatePoster(image: posterImage, isVisible: showsPoster)
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
            playerView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(playerView)

            NSLayoutConstraint.activate([
                playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
                playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
                playerView.topAnchor.constraint(equalTo: topAnchor),
                playerView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    final class Coordinator {
        private let posterView: NSImageView = {
            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.backgroundColor = NSColor.black.cgColor
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.isHidden = true
            return imageView
        }()

        func installPoster(in playerView: AVPlayerView) {
            guard let overlay = playerView.contentOverlayView,
                  posterView.superview !== overlay else { return }
            posterView.removeFromSuperview()
            overlay.addSubview(posterView, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                posterView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                posterView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                posterView.topAnchor.constraint(equalTo: overlay.topAnchor),
                posterView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor)
            ])
        }

        func updatePoster(image: NSImage?, isVisible: Bool) {
            posterView.image = image
            posterView.isHidden = !isVisible || image == nil
        }
    }
}

/// Interactive playback keeps 5K HEVC on AVPlayer's reliable native path.
/// Modern title objects are drawn by the same renderer above that video, so a
/// title cannot force the whole camera composition through a black-frame-prone
/// custom compositor merely to preview a few seconds of text.
private struct TimelinePreviewPlayer: View {
    @EnvironmentObject var model: AppModel
    let player: AVPlayer
    let clock: TimelinePlaybackClock

    var body: some View {
        ZStack {
            PlayerView(
                player: player,
                posterImage: model.previewPosterImage,
                showsPoster: model.isPreviewPosterVisible
            )
            if let timeline = model.timeline {
                TimelineTitlePreviewOverlay(timeline: timeline, clock: clock)
            }
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

    var body: some View {
        ForEach(activeTitles) { title in
            if let frame = TitleOverlayRenderer.cgImage(
                item: title,
                timelineTime: clock.time,
                renderSize: previewRenderSize
            ) {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .allowsHitTesting(false)
            }
        }
    }

    private var activeTitles: [TitleTimelineItem] {
        timeline.effectiveTitleItems.filter {
            $0.enabled && clock.time >= $0.startTime && clock.time < $0.endTime
        }.sorted { $0.track < $1.track }
    }

    private var previewRenderSize: CGSize {
        let width: CGFloat = 960
        return CGSize(width: width, height: width * CGFloat(timeline.height) / CGFloat(max(1, timeline.width)))
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

    private let contentTopOffset: CGFloat = 200
    private let welcomeContentVerticalOffset: CGFloat = -120

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                Image(systemName: "film.stack.fill").font(.system(size: 58)).foregroundStyle(.blue)
                Text("VeloEdit").font(.largeTitle.bold())
                Text("Дайте приложению реальные материалы и расскажите, какой фильм хотите.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
                HStack {
                    Button("Новый проект", action: model.createProject).buttonStyle(.borderedProminent)
                    Button("Открыть проект", action: model.openProject)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)
            .offset(y: welcomeContentVerticalOffset)

            if !model.recentProjectURLs.isEmpty {
                RecentProjectsGallery()
            }
        }
        .padding(.top, contentTopOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(Color(nsColor: .windowBackgroundColor))
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
            }
            .frame(height: 218, alignment: .top)
            .scrollClipDisabled()
        }
        .padding(.top, 8)
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
            Button { model.openRecentProject(url) } label: {
                cardContent
            }
            .buttonStyle(.plain)

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
        let assets = (model.project?.assets ?? []).filter { BackgroundPreset.preset(for: $0) == nil }
        let order = Dictionary(uniqueKeysWithValues: (model.project?.sourceMap?.entries ?? []).map { ($0.assetID, $0.order) })
        return assets.sorted {
            let lhs = order[$0.id] ?? Int.max
            let rhs = order[$1.id] ?? Int.max
            if lhs != rhs { return lhs < rhs }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private var selectedMediaAsset: MediaAsset? {
        model.selectedAsset.flatMap { asset in
            BackgroundPreset.preset(for: asset) == nil ? asset : nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 760 {
                HSplitView {
                    mediaBrowser
                        .frame(minWidth: 420)
                        .layoutPriority(1)
                    if selectedMediaAsset != nil || model.selectedMusicTrack != nil {
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
                    if selectedMediaAsset != nil || model.selectedMusicTrack != nil {
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
                Divider()
                if mediaAssets.isEmpty && model.musicTracks.isEmpty {
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
                                            MediaThumbnail(url: model.thumbnailURLs[asset.id], kind: asset.kind)
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
                                    .background(model.selectedAssetID == asset.id ? Color.accentColor.opacity(0.17) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.selectedAssetID == asset.id ? Color.accentColor : .clear, lineWidth: 2))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        }
                        if !model.musicTracks.isEmpty {
                            Text("Музыка")
                                .font(.headline)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                                ForEach(model.musicTracks) { track in
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
                                        .background(model.selectedMusicTrackID == track.id ? Color.accentColor.opacity(0.17) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.selectedMusicTrackID == track.id ? Color.accentColor : .clear, lineWidth: 2))
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
        if let asset = selectedMediaAsset {
            AssetInspector(asset: asset)
        } else if let track = model.selectedMusicTrack {
            MusicInspector(track: track)
        }
    }

    private var mediaHeaderTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Медиатека").font(.title2.bold())
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
            Button(action: model.analyze) {
                Label(model.isAnalyzing ? "Идёт анализ" : "Анализировать материалы", systemImage: model.isAnalysisCurrent ? "checkmark.circle.fill" : "sparkles")
            }
            .disabled(mediaAssets.isEmpty || model.isWorking)
        }
        .fixedSize(horizontal: true, vertical: true)
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

    var body: some View {
        GeometryReader { geometry in
            if let timeline = model.timeline {
                let columnWidth = max(0, (geometry.size.width - 1) / 2)

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        MontageMediaBrowser()
                            .frame(width: columnWidth)
                            .frame(maxHeight: .infinity)
                        Divider()
                        MontagePlayerWorkspace()
                            .frame(width: columnWidth)
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
                ContentUnavailableView("Фильм ещё не создан", systemImage: "timeline.selection", description: Text("Перейдите к умному режиссёру и создайте первый монтаж."))
                    .overlay(alignment: .bottom) {
                        Button("К умному режиссёру", action: model.showDirector)
                            .buttonStyle(.borderedProminent)
                            .padding(24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                ForEach(Array(MontageBrowserTab.allCases.prefix(4))) { item in
                    browserTabButton(item)
                }
            }
            HStack(spacing: 5) {
                ForEach(Array(MontageBrowserTab.allCases.dropFirst(4))) { item in
                    browserTabButton(item)
                }
            }
        }
        .frame(maxWidth: .infinity)
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
                        .draggable(asset.id.uuidString)
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
                            Text("Music Source")
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
                        musicSourceBadge("My Music", count: model.userMusicTracks.count, icon: "folder.fill")
                        musicSourceBadge("Online", count: model.cachedOnlineMusicTracks.count, icon: "network")
                    }
                    HStack(spacing: 8) {
                        Button("Add Folder", systemImage: "folder.badge.plus", action: model.chooseMusicFolder)
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
                        .draggable("music:\(track.id.uuidString)")
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
                        Button {
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
                        .draggable("background:\(preset.rawValue)")
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
                Text("Карточка показывает живой Title Template тем же renderer, который используется на Timeline и в Export.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(TitleTemplateCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(category.localizedTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(TitleTemplateRegistry.all.filter { $0.category == category }) { template in
                                Button {
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
                                .draggable(titleDragPayload(template))
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
                            Button {
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
                                Button {
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
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .draggable("effect:\(effect.rawValue)")
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
                                Button {
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
                                .draggable("transition:\(preset.style.rawValue)")
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

struct BackgroundPresetPreview: View {
    let preset: BackgroundPreset

    var body: some View {
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

private struct TitlePreviewArtwork: View {
    let template: TitleTemplateDefinition
    let text: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { timeline in
            let previewTime = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: max(0.25, template.duration))
            ZStack {
                LinearGradient(
                    colors: [.black, Color(red: 0.055, green: 0.055, blue: 0.07)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                if let image = previewImage(at: previewTime) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(0.09), lineWidth: 1)
            }
        }
    }

    private func previewImage(at time: Double) -> CGImage? {
        var item = template.previewItem()
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { item.text = clean }
        return TitleOverlayRenderer.previewCGImage(template: templateWithPreview(item), time: time, renderSize: CGSize(width: 480, height: 270))
    }

    private func templateWithPreview(_ item: TitleTimelineItem) -> TitleTemplateDefinition {
        var copy = template
        copy.preview = TitleTemplatePreview(primaryText: item.text, secondaryText: item.additionalText, callToAction: item.callToAction)
        return copy
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

private struct MontagePlayerWorkspace: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTool: ViewerAdjustmentTool?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.project?.name ?? "Фильм")
                        .font(.headline)
                        .lineLimit(1)
                    if let timeline = model.timeline {
                        Text("\(timeline.width)×\(timeline.height) · \(Int(timeline.frameRate.rounded())) fps")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                viewerTools
                Spacer()
                Button("Экспорт", systemImage: "square.and.arrow.up") { model.openSection(.export) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(.regularMaterial)

            if let selectedTool, let item = model.selectedTimelineItem {
                viewerToolPanel(selectedTool, item: item)
                    .frame(minHeight: 64)
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
            Group {
                Button(action: model.autoEnhanceSelected) {
                    Label("Автоцвет", systemImage: "wand.and.rays")
                        .labelStyle(.iconOnly)
                }
                .help("Автоматически улучшить цвет")

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
                    .help(tool.title)
                }

                Button("Сбросить все") { model.resetAllSelectedViewerAdjustments() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .padding(.leading, 5)
            }
            .disabled(model.selectedTimelineItem == nil || model.isTimelineInteractionBlocked)

        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }

    @ViewBuilder
    private func viewerToolPanel(_ tool: ViewerAdjustmentTool, item: TimelineItem) -> some View {
        let video = item.effectiveVideoAdjustments
        let audio = item.effectiveAudioAdjustments
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
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
                    Text("Стиль:").font(.callout.weight(.semibold))
                    Picker("Стиль", selection: Binding(
                        get: { item.effect == ClipEffect.kenBurns.rawValue ? "ken-burns" : video.crop.rawValue },
                        set: model.setSelectedCropMode
                    )) {
                        Text("Уместить").tag("fit")
                        Text("Обрезать до заполнения").tag("fill")
                        Text("Ken Burns").tag("ken-burns")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Button("Влево", systemImage: "rotate.left") { model.rotateSelected(-1) }
                    Button("Вправо", systemImage: "rotate.right") { model.rotateSelected(1) }
                    resetButton(model.resetSelectedCropAndRotation)

                case .stabilization:
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

                case .volume:
                    Toggle("Авто", isOn: Binding(get: { audio.normalize ?? false }, set: model.setSelectedAudioNormalize))
                        .toggleStyle(.button)
                    Button {
                        model.setSelectedClipMuted(!audio.muted)
                    } label: {
                        Image(systemName: audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    ViewerValueSlider(title: "Громкость", value: audio.volume, range: 0...2, style: .percent, onCommit: model.setSelectedClipVolume)
                    Toggle("Снизить громкость др. клипов", isOn: Binding(get: { audio.duckOthers ?? false }, set: model.setSelectedDuckOthers))
                    ViewerValueSlider(title: "Снижение", value: audio.duckingAmount ?? 0.5, range: 0...1, style: .percent, onCommit: model.setSelectedDuckingAmount)
                        .disabled(!(audio.duckOthers ?? false))
                    resetButton(model.resetSelectedVolume)

                case .noiseReduction:
                    Toggle("Уменьшить фоновый шум", isOn: Binding(
                        get: { (audio.noiseReduction ?? 0) > 0.001 },
                        set: { model.setSelectedNoiseReduction($0 ? max(0.5, audio.noiseReduction ?? 0) : 0) }
                    ))
                    ViewerValueSlider(title: "Очистка", value: audio.noiseReduction ?? 0, range: 0...1, style: .percent, onCommit: model.setSelectedNoiseReduction)
                    Picker("Эквалайзер", selection: Binding(get: { audio.eqPreset ?? .flat }, set: model.setSelectedEQ)) {
                        ForEach(AudioEQPreset.allCases) { preset in Text(preset.localizedTitle).tag(preset) }
                    }
                    .frame(width: 230)
                    resetButton(model.resetSelectedNoiseProcessing)

                case .speed:
                    ViewerValueSlider(title: "Скорость", value: item.speed, range: 0.1...20, style: .percent, onCommit: model.setSelectedSpeed)
                    Toggle("Сгладить", isOn: Binding(get: { video.smoothSlowMotion ?? false }, set: model.setSelectedSmoothSlowMotion))
                        .disabled(item.speed >= 1)
                    Toggle("Перевернуть", isOn: Binding(get: { item.isReversed }, set: { _ in model.toggleSelectedReverse() }))
                    Toggle("Сохр. высоту тона", isOn: Binding(get: { audio.preservePitch ?? true }, set: model.setSelectedPreservePitch))
                    resetButton(model.resetSelectedSpeed)

                case .filters:
                    Picker("Фильтр клипа", selection: Binding(get: { video.filter }, set: model.setSelectedFilter)) {
                        ForEach(VideoFilter.allCases) { filter in Text(filter.localizedTitle).tag(filter) }
                    }
                    .frame(width: 220)
                    ViewerValueSlider(title: "Интенсивность", value: video.filterIntensity ?? 1, range: 0...1, style: .percent, onCommit: model.setSelectedFilterIntensity)
                        .disabled(video.filter == .none)
                    Picker("Аудиоэффект", selection: Binding(get: { audio.effect ?? AudioEffect.none }, set: model.setSelectedAudioEffect)) {
                        ForEach(AudioEffect.allCases) { effect in Text(effect.localizedTitle).tag(effect) }
                    }
                    .frame(width: 220)
                    resetButton(model.resetSelectedFilters)

                case .information:
                    informationPanel(item)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .disabled(model.isTimelineInteractionBlocked)
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

            Slider(
                value: Binding(
                    get: { min(clock.time, effectiveDuration) },
                    set: model.seekTimeline
                ),
                in: 0...effectiveDuration
            )
            .help("Перемотать фильм")

            Text("\(time(clock.time)) / \(time(model.timeline?.duration ?? 0))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()

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
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(.regularMaterial)
        .onReceive(player.publisher(for: \.timeControlStatus, options: [.initial, .new])) { status in
            isPlaying = status == .playing || status == .waitingToPlayAtSpecifiedRate
        }
    }

    private var effectiveDuration: Double {
        max(0.1, model.timeline?.duration ?? 0)
    }

    private func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private enum ViewerAdjustmentTool: String, CaseIterable, Identifiable {
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
        HStack(spacing: 7) {
            Text(title).font(.caption).lineLimit(1)
            Slider(value: $draft, in: range) { editing in
                isEditing = editing
                if !editing { onCommit(draft) }
            }
            .frame(width: 118)
            Text(style.text(draft))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 42, alignment: .trailing)
        }
        .onChange(of: value) { _, newValue in
            if !isEditing { draft = newValue }
        }
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
    @State private var editingModernTitleText = ""
    @State private var editingModernTitleAdditionalText = ""
    @State private var editingModernTitleCallToAction = ""
    @State private var aiTitleInstruction = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Label("Настройки монтажа", systemImage: "gearshape.fill")
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
                if let item = model.selectedTimelineItem {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        inspectorGroup("Выбранный фрагмент") { clipIdentity(item) }
                        inspectorGroup("Положение в фильме") { moveButtons }
                        inspectorGroup("Границы фрагмента") { trimControls(item) }
                        if item.kind != .title {
                            inspectorGroup("Скорость и кадр") { speedAndFrameControls(item) }
                            inspectorGroup("Цвет") { colorControls(item) }
                            inspectorGroup("Звук фрагмента") { clipAudioControls(item) }
                        } else {
                            inspectorGroup("Оформление титра") { titleStyleControls(item) }
                        }
                        inspectorGroup("Оформление фрагмента") { editorPickers(item) }
                        inspectorGroup("Действия с фрагментом") { itemActions(item) }
                    }
                    .disabled(model.isTimelineInteractionBlocked)
                } else if let effect = model.selectedEffectTimelineItem {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        inspectorGroup("Эффект") { effectIdentity(effect) }
                        inspectorGroup("Параметры") { effectControls(effect) }
                        inspectorGroup("Keyframes") { effectKeyframeControls(effect) }
                        inspectorGroup("Действия") { effectActions(effect) }
                    }
                    .disabled(model.isTimelineInteractionBlocked)
                } else if let title = model.selectedTitleTimelineItem {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        inspectorGroup("Текст") { modernTitleTextControls(title) }
                        inspectorGroup("Шаблон и стиль") { modernTitleStyleControls(title) }
                        inspectorGroup("✨ Изменить с помощью AI") { modernTitleAIControls(title) }
                    }
                    .disabled(model.isTimelineInteractionBlocked)
                } else if let transition = model.selectedTransitionTimelineItem {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        inspectorGroup("Переход") { transitionControls(transition) }
                    }
                    .disabled(model.isTimelineInteractionBlocked)
                } else if let telemetry = model.selectedTelemetryItem {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        inspectorGroup("Слой телеметрии") { telemetryIdentity(telemetry) }
                        inspectorGroup("Виджет и стиль") { telemetryStyleControls(telemetry) }
                        inspectorGroup("Положение и размер") { telemetryLayoutControls(telemetry) }
                        inspectorGroup("Действия") { telemetryActions }
                    }
                    .disabled(model.isTimelineInteractionBlocked)
                } else if let clip = model.selectedTimelineAudioClip {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        inspectorGroup("Выбранная аудиодорожка") {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(clip.title).font(.subheadline.weight(.semibold))
                                Text("Начало: \(clip.timelineStart, specifier: "%.1f") с · длительность: \(clip.timelineDuration, specifier: "%.1f") с")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        inspectorGroup("Настройки аудио") { timelineAudioControls(clip) }
                    }
                    .disabled(model.isTimelineInteractionBlocked)
                } else if model.selectedSoundtrack {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        inspectorGroup("Основная музыка") {
                            VStack(alignment: .leading, spacing: 7) {
                                Label(model.timeline?.music?.trackTitle ?? model.timeline?.music?.style.localizedTitle ?? "Музыка", systemImage: "music.note")
                                    .font(.subheadline.weight(.semibold))
                                Text("Здесь можно выбрать трек, изменить громкость или отключить музыку.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                musicControls
                            }
                        }
                    }
                } else {
                    Text("Выберите фрагмент на монтажной шкале, чтобы применить переход или эффект. Музыку можно добавить сразу ко всему фильму.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { editingTitleText = model.selectedTimelineItem?.title ?? "" }
        .onChange(of: model.selectedTimelineItemID) { _, _ in
            editingTitleText = model.selectedTimelineItem?.title ?? ""
        }
        .onChange(of: model.selectedTitleTimelineItemID) { _, _ in
            editingModernTitleText = model.selectedTitleTimelineItem?.text ?? ""
            editingModernTitleAdditionalText = model.selectedTitleTimelineItem?.additionalText ?? ""
            editingModernTitleCallToAction = model.selectedTitleTimelineItem?.callToAction ?? ""
            aiTitleInstruction = ""
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
            TextField("Текст", text: $editingModernTitleText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            Button("Применить текст") { model.setSelectedModernTitleText(editingModernTitleText) }
                .disabled(editingModernTitleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editingModernTitleText == item.text)
            if supportsSecondary {
                TextField("Подзаголовок", text: $editingModernTitleAdditionalText)
                    .textFieldStyle(.roundedBorder)
            }
            if supportsCTA {
                TextField("CTA / кнопка", text: $editingModernTitleCallToAction)
                    .textFieldStyle(.roundedBorder)
            }
            if supportsSecondary || supportsCTA {
                HStack {
                    Button("Применить дополнительный текст") {
                        model.setSelectedModernTitleCardDetails(
                            additionalText: editingModernTitleAdditionalText,
                            callToAction: editingModernTitleCallToAction
                        )
                    }
                    .disabled(editingModernTitleAdditionalText == (item.additionalText ?? "") && editingModernTitleCallToAction == (item.callToAction ?? ""))
                }
            }
            Stepper("Длительность: \(item.duration, specifier: "%.2f") с", value: Binding(
                get: { item.duration }, set: model.setSelectedModernTitleDuration
            ), in: 0.05...max(0.05, model.timeline?.duration ?? item.duration), step: 0.1)
            if !item.words.isEmpty {
                Text("\(item.words.count) слов с word-level timestamps")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func modernTitleStyleControls(_ item: TitleTimelineItem) -> some View {
        let style = item.style
        let template = TitleTemplateRegistry.template(for: item)
        let baseSize = template?.typography.fontSize ?? style.fontSize
        let minimumSize = max(18, baseSize * 0.65)
        let maximumSize = min(220, baseSize * 1.30)
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Шаблон", selection: Binding(
                get: { item.effectiveTemplateID ?? "" },
                set: model.setSelectedModernTitleTemplate
            )) {
                ForEach(TitleTemplateRegistry.all.filter { $0.kind.category == item.kind.category || item.kind.category == .basic }) { template in
                    Text(template.name).tag(template.id)
                }
            }
            Stepper("Размер: \(Int(style.fontSize))", value: Binding(
                get: { style.fontSize },
                set: { value in var copy = style; copy.fontSize = value; model.setSelectedModernTitleStyle(copy) }
            ), in: minimumSize...maximumSize, step: 2)
            ColorPicker("Цвет текста", selection: Binding(
                get: { titleColor(style.textColorHex) },
                set: { value in var copy = style; copy.textColorHex = titleHex(value); model.setSelectedModernTitleStyle(copy) }
            ), supportsOpacity: false)
            ViewerValueSlider(title: "Прозрачность", value: style.effectiveOpacity, range: 0...1, style: .percent) { value in
                var copy = style; copy.opacity = value; model.setSelectedModernTitleStyle(copy)
            }
            Text("Композиция, safe area и анимация защищены шаблоном, чтобы дизайн оставался целостным.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
            TextField("Например: сделай кинематографичным", text: $aiTitleInstruction)
                .textFieldStyle(.roundedBorder)
            Button("Изменить существующий титр", systemImage: "sparkles") {
                model.editSelectedTitleWithAI(aiTitleInstruction)
                aiTitleInstruction = ""
            }
            .disabled(aiTitleInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            Label("Timeline = Preview = Export", systemImage: "checkmark.seal")
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
            Button("My Music", systemImage: "folder.badge.plus", action: model.chooseMusicFolder)
                .help("Добавить папку с MP3, AAC/M4A, WAV, AIFF или FLAC")
            Button("Online", systemImage: "network", action: model.prepareOnlineMusicLibrary)
                .help("Необязательно: проверить Free To Use и Openverse; ошибки сети не мешают монтажу")
            if model.timeline?.music?.trackID != nil {
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
            TextField("Текст титра", text: $editingTitleText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onSubmit { model.setSelectedTitleText(editingTitleText) }
            Button("Применить текст") { model.setSelectedTitleText(editingTitleText) }
                .disabled(editingTitleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editingTitleText == item.title)
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

private struct ExportWorkspaceView: View {
    @EnvironmentObject var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Экспорт").font(.title2.bold())
                    Text("Просмотр монтажа, готовое видео или редактируемый проект для Final Cut Pro")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    exportCard("Предварительный просмотр", "Посмотреть монтаж без сохранения файла", "play.rectangle", action: model.renderPreview)
                    exportCard("Высокое качество", "Сохранить готовое видео в MP4 с разрешением Full HD 1080p", "rectangle.inset.filled", action: model.export1080p)
                    exportCard("Максимальное качество", "Сохранить MP4 с наилучшим качеством, доступным для исходных материалов", "sparkles.tv", action: model.exportMaximum)
                    exportCard("Прозрачная телеметрия", "Сохранить только виджеты с alpha-каналом в ProRes 4444 MOV", "circle.dotted.circle", action: model.exportTelemetryOverlay)
                    exportCard("Ручные настройки экспорта", "Самостоятельно выбрать разрешение готового MP4", "slider.horizontal.3", action: model.presentManualExportSettings)
                    exportCard("Экспорт для Final Cut Pro", "Создать редактируемый монтаж: каждый видеофрагмент можно двигать и изменять вручную", "timeline.selection", action: { model.exportFCPXML(mode: .edit) })
                }
                Divider()
                Text("Проект").font(.headline)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    projectAction("Проверить целостность материалов", "checkmark.shield", model.verifyMediaIntegrity)
                    projectAction("Экспортировать диагностику", "doc.text", model.exportDiagnostics)
                    projectAction("Показать проект в Finder", "folder", model.revealProject)
                }
                .disabled(model.isWorking)
            }
            .padding(24)
        }
        .sheet(isPresented: $model.isShowingManualExportSettings) {
            ManualExportSettingsView(isPresented: $model.isShowingManualExportSettings)
                .environmentObject(model)
        }
    }

    private func exportCard(_ title: String, _ subtitle: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 26)).foregroundStyle(Color.accentColor).frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(model.timeline == nil || model.isWorking)
    }

    private func projectAction(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }
}

private struct ManualExportSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var quality: RenderQuality = .final4K
    @State private var frameRate: Double = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ручные настройки экспорта")
                    .font(.title2.bold())
                Text("Выберите разрешение готового видео. Файл будет сохранён в формате MP4.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Разрешение", selection: $quality) {
                Text("720p — компактный файл").tag(RenderQuality.preview720p)
                Text("1080p — Full HD").tag(RenderQuality.final1080p)
                Text("2160p — 4K UHD").tag(RenderQuality.final4K)
                Text("Максимальное качество исходников").tag(RenderQuality.maximum)
            }
            .pickerStyle(.radioGroup)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Частота кадров")
                    .font(.headline)
                Picker("Кадров в секунду", selection: $frameRate) {
                    ForEach(model.exportFrameRateOptions, id: \.self) { value in
                        Text(frameRateTitle(value)).tag(value)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("По умолчанию выбрана максимальная частота среди исходных материалов.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Отмена") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Выбрать место и экспортировать") {
                    let selectedQuality = quality
                    isPresented = false
                    DispatchQueue.main.async {
                        model.exportWithSettings(quality: selectedQuality, frameRate: frameRate)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear { frameRate = model.maximumSourceFrameRate }
    }

    private func frameRateTitle(_ value: Double) -> String {
        let rounded = value.rounded()
        let number = abs(value - rounded) < 0.01 ? String(Int(rounded)) : String(format: "%.2f", value)
        return "\(number) кадров/с"
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

            DirectorComposer()
                .padding(14)
                .background(.bar)
        }
    }
}

private struct DirectorConversationView: View {
    @EnvironmentObject var model: AppModel
    @State private var setupQuestionIndex = 0
    @State private var isEnteringCustomDuration = false
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
                    if !model.directorMessages.contains(where: { $0.role == .user }),
                       setupQuestionIndex < setupQuestions.count {
                        directorSetupQuestion(setupQuestions[setupQuestionIndex])
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
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

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        guard let id = model.directorMessages.last?.id else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
    }

    private enum SetupQuestionKind {
        case canvas
        case duration
        case mood
        case music
        case sourceAudio
        case titles
    }

    private enum SetupAnswer {
        case canvas(DirectorCanvasFormat)
        case duration(Double)
        case customDuration
        case mood(DirectorNarrativeMood)
        case music(DirectorMusicPolicy)
        case sourceAudio(DirectorSourceAudioPolicy)
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
        [
            SetupQuestion(
                kind: .canvas,
                title: "Какой формат ролика сделать?",
                options: [
                    SetupOption(title: DirectorCanvasFormat.landscape16x9.localizedTitle, answer: .canvas(.landscape16x9)),
                    SetupOption(title: DirectorCanvasFormat.portrait9x16.localizedTitle, answer: .canvas(.portrait9x16))
                ]
            ),
            SetupQuestion(
                kind: .duration,
                title: "Какой должна быть длительность?",
                options: [
                    SetupOption(title: "2 мин", answer: .duration(2)),
                    SetupOption(title: "5 мин", answer: .duration(5)),
                    SetupOption(title: "Другая", answer: .customDuration)
                ]
            ),
            SetupQuestion(
                kind: .mood,
                title: "Какое настроение важнее?",
                options: [
                    SetupOption(title: "Спокойное", answer: .mood(.calm)),
                    SetupOption(title: "Киношное", answer: .mood(.cinematic)),
                    SetupOption(title: "Динамичное", answer: .mood(.dynamic))
                ]
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
    }

    private func directorSetupQuestion(_ question: SetupQuestion) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Вопрос \(setupQuestionIndex + 1) из \(setupQuestions.count)", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(question.title).font(.body.weight(.medium))
            HStack(spacing: 7) {
                ForEach(question.options) { option in
                    Button(option.title) { applySetupAnswer(option) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private func applySetupAnswer(_ option: SetupOption) {
        switch option.answer {
        case .canvas(let format):
            model.setDirectorCanvasFormat(format)
        case .duration(let minutes):
            model.setTargetMinutes(minutes)
        case .customDuration:
            customDurationText = formattedMinutes(model.targetMinutes)
            customDurationError = nil
            isEnteringCustomDuration = true
            return
        case .mood(let mood):
            model.setDirectorNarrativeMood(mood)
        case .music(let policy):
            model.setDirectorMusicPolicy(policy)
        case .sourceAudio(let policy):
            model.setDirectorSourceAudioPolicy(policy)
        case .titles(let policy):
            model.setDirectorTitlePolicy(policy)
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
        case .keyOnly: "титры только в ключевых моментах"
        case .none: "без титров"
        }
        return [
            "Формат: \(brief.canvasFormat.localizedTitle).",
            "Точная длительность: \(durationDescription(brief.requestedDuration)).",
            "Настроение: \(mood).",
            "Музыка: \(music).",
            "Звук: \(sourceAudio).",
            "Титры: \(titles)."
        ].joined(separator: " ")
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
                "Опишите, что изменить в фильме…",
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
                    ProgressView()
                        .controlSize(.small)
                        .help("ИИ-режиссёр формирует ответ")
                }
                Button("Отправить", systemImage: "arrow.up", action: sendMessage)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .disabled(trimmedInput.isEmpty || model.isDirectorResponding)
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
        guard !trimmedInput.isEmpty, !model.isDirectorResponding else { return }
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
        .accessibilityLabel("Мощность ИИ")
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
                    Text(message.text)
                        .textSelection(.enabled)
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
                    in: (5.0 / 60.0)...60,
                    step: 5.0 / 60.0
                )
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
        if model.targetMinutes < 1 {
            return "\(max(5, Int((model.targetMinutes * 60).rounded()))) секунд"
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
                    Text("Player")
                        .font(.title3.weight(.semibold))
                    if let timeline = model.timeline {
                        Text("\(timeline.items.count) фрагментов · \(duration(timeline.duration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Результат монтажа")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.timeline != nil {
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
                            Text("Опишите пожелание ИИ-режиссёру — он сразу соберёт или изменит монтаж")
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

            Divider()

            HStack(spacing: 8) {
                playerStatus
                Spacer(minLength: 8)
                if model.isCreatingFilm {
                    Text("\(Int((model.progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
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

    @ViewBuilder private var playerStatus: some View {
        if model.isCreatingFilm {
            ProgressView()
                .controlSize(.small)
            Text(model.activityTitle.isEmpty ? "Обновляю фильм" : model.activityTitle)
                .foregroundStyle(.secondary)
        } else if model.hasPendingFilmChanges, model.previewPlayer != nil {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.orange)
            Text("Можно смотреть текущую версию · правки ещё не применены")
                .foregroundStyle(.secondary)
        } else if model.previewPlayer != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Просмотр обновлён")
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
            Text("Ожидает первого монтажа")
                .foregroundStyle(.secondary)
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
                Spacer()
                if !model.activityTimeRemaining.isEmpty {
                    Text("осталось \(model.activityTimeRemaining)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: model.progress)
                .controlSize(.small)

            HStack {
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

            if !model.isActivityComplete {
                ProgressView(value: model.progress)
                    .controlSize(.small)
            }

            Text(displayedStatus.isEmpty ? model.status : displayedStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if model.isWorking {
                HStack {
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

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("automaticallyShowPreview") private var automaticallyShowPreview = true
    var body: some View {
        Form {
            Toggle("Автоматически открывать просмотр после создания фильма", isOn: $automaticallyShowPreview)
            Section("AI-мощность") {
                Picker("Режим", selection: Binding(get: { model.aiPowerMode }, set: model.setAIPowerMode)) {
                    ForEach(AIPowerMode.allCases) { mode in
                        Text(mode == .balanced ? "\(mode.title) ★ Рекомендуется" : mode.title).tag(mode)
                    }
                }
                Text(model.aiPowerMode.shortDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.aiProfileSummary)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            Section("Advanced Settings") {
                Toggle("Выбирать runtime и модель вручную", isOn: Binding(
                    get: { model.advancedAISettings.enabled },
                    set: { enabled in
                        var value = model.advancedAISettings
                        value.enabled = enabled
                        model.setAdvancedAISettings(value)
                    }
                ))
                if model.advancedAISettings.enabled {
                    Picker("Runtime", selection: Binding(
                        get: { model.advancedAISettings.runtime },
                        set: { runtime in
                            var value = model.advancedAISettings
                            value.runtime = runtime
                            model.setAdvancedAISettings(value)
                        }
                    )) {
                        ForEach(LocalAIRuntime.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("ID модели", text: Binding(
                        get: { model.advancedAISettings.modelID },
                        set: { modelID in
                            var value = model.advancedAISettings
                            value.modelID = modelID
                            model.setAdvancedAISettings(value)
                        }
                    ))
                    Picker("Квантизация", selection: Binding(
                        get: { model.advancedAISettings.quantization },
                        set: { quantization in
                            var value = model.advancedAISettings
                            value.quantization = quantization
                            model.setAdvancedAISettings(value)
                        }
                    )) {
                        ForEach(AIQuantization.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text("Ручной MLX ID должен указывать на локально доступную модель. При недоступности VeloEdit продолжит Apple Vision-анализ и покажет предупреждение.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("VeloEdit работает локально: материалы и данные проекта не отправляются в облако.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Section("Personal Taste") {
                Text("AI постепенно учится на монтаже, удалениях, восстановлении, тримах, порядке сцен, музыке и эффектах. Профиль хранится только на этом Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Экспортировать профиль", action: model.exportPersonalTasteProfile)
                    Button("Сбросить профиль", role: .destructive, action: model.resetPersonalTasteProfile)
                }
                .disabled(model.pipeline == nil)
            }
            Button("Экспортировать диагностику", action: model.exportDiagnostics)
                .disabled(model.pipeline == nil)
            Button("Показать проект в Finder", action: model.revealProject)
                .disabled(model.projectURL == nil)
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520)
    }
}
