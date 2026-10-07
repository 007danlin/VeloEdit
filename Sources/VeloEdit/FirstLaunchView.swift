import AppKit
import SwiftUI
import ImageIO
import QuartzCore
import OSLog

struct FirstLaunchRoot<Content: View>: View {
    @ObservedObject var intro: FirstLaunchCoordinator
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            content()
                .disabled(intro.isPresented)
                .allowsHitTesting(!intro.isPresented)
                .accessibilityHidden(intro.isPresented)
            if intro.isPresented {
                FirstLaunchView(intro: intro)
                    .id(intro.presentationID)
                    .zIndex(10)
            }
        }
        .environmentObject(intro)
    }
}

struct FirstLaunchView: View {
    @ObservedObject var intro: FirstLaunchCoordinator
    var artworkBundle: Bundle = .main
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale
    @State private var artwork: NSImage?
    @State private var artworkFraction: CGFloat = 0.90
    @State private var attemptedLoad = false
    private let background = Color(red: 8 / 255, green: 11 / 255, blue: 16 / 255)
    private let blue = Color(red: 0.32, green: 0.73, blue: 1)

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !intro.isAnimating)) { _ in
                let now = CACurrentMediaTime()
                let elapsed = intro.phase == .exiting ? intro.exitEntryElapsed : intro.elapsed(at: now)
                let frame = FirstLaunchFrame(elapsed: elapsed, settled: intro.phase == .waiting || reduceMotion,
                                             exitElapsed: intro.exitAt.map { max(0, now - $0) },
                                             lightReveal: intro.usesLightReveal, exitDuration: intro.exitDuration)
                scene(size: geometry.size, frame: frame)
            }
            .task {
                intro.appear(reduceMotion: reduceMotion)
                guard !attemptedLoad else { return }
                attemptedLoad = true
                // Cover later window resizing without swapping textures mid-scene.
                let requiredPixels = FirstLaunchArtwork.requiredPixels(height: 2000, scale: displayScale)
                let bundle = artworkBundle
                let result = await Task.detached(priority: .userInitiated) {
                    FirstLaunchArtwork.load(bundle: bundle, requiredPixels: requiredPixels)
                }.value
                guard !Task.isCancelled, intro.isPresented else { return }
                if let result {
                    artworkFraction = result.fraction
                    artwork = NSImage(cgImage: result.image, size: .zero)
                } else {
                    artwork = NSImage(named: NSImage.applicationIconName)
                        ?? NSWorkspace.shared.icon(forFile: artworkBundle.bundlePath)
                    artworkFraction = 1
                    intro.settle()
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .background(FirstLaunchInputBridge(intro: intro, reduceMotion: reduceMotion))
        .onChange(of: reduceMotion) { _, reduced in if reduced { intro.applicationResignedActive() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            intro.applicationResignedActive()
        }
        .onDisappear {
            intro.viewDisappeared()
            artwork = nil
        }
    }

    private func scene(size: CGSize, frame: FirstLaunchFrame) -> some View {
        // Reserve the text/action stack first so even the 980 × 700 window fits.
        let iconHeight = FirstLaunchArtwork.visibleHeight(windowHeight: size.height, scale: displayScale)
        let canvasSide = iconHeight / artworkFraction
        let stackHeight = iconHeight + 32 + 44 + 10 + 28 + 26 + 48
        let top = max(58, (size.height - stackHeight) / 2 - 12)
        let center = CGPoint(x: size.width / 2, y: top + iconHeight / 2)
        return ZStack(alignment: .top) {
            background.opacity(frame.backdropOpacity)
            RadialGradient(colors: [blue.opacity(0.13), background.opacity(0)], center: .init(x: 0.5, y: center.y / size.height),
                           startRadius: 10, endRadius: min(size.width, size.height) * 0.65)
                .opacity(frame.backdropOpacity)
            FirstLaunchRays(strength: frame.rays, spread: frame.raySpread)
                .frame(width: size.width, height: max(1, top + iconHeight + 15))
                .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.7),
                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .clipped()
                .opacity(frame.backdropOpacity)
                .accessibilityHidden(true)
            Ellipse().fill(RadialGradient(colors: [blue.opacity(0.12 * frame.iconOpacity), blue.opacity(0.04 * frame.iconOpacity), .clear],
                                          center: .center, startRadius: 0, endRadius: iconHeight * 0.55))
                .frame(width: iconHeight * 1.5, height: iconHeight * 1.2)
                .position(center)
                .opacity(frame.backdropOpacity)
                .accessibilityHidden(true)
            if let artwork {
                Image(nsImage: artwork).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: canvasSide, height: canvasSide)
                    .scaleEffect(frame.iconScale)
                    .opacity(frame.iconOpacity)
                    .position(center)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                Text("VeloEdit").font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
                    .frame(height: 44)
                    .accessibilityAddTraits(.isHeader)
                Text("Большие идеи начинаются с первого кадра.")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white.opacity(contrast == .increased ? 1 : 0.82))
                    .padding(.top, 10)
            }
            .frame(maxWidth: 560)
            .opacity(max(0.001, frame.textOpacity))
            .offset(y: top + iconHeight + 32 + 8 * (1 - frame.textOpacity))
            Button { begin() } label: {
                HStack(spacing: 10) {
                    Text("Начнём").font(.system(size: 16, weight: .semibold))
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color(red: 0.025, green: 0.085, blue: 0.13))
                .padding(.horizontal, 30).frame(height: 48)
                .background(blue, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Начнём")
            .accessibilityHint("Открыть VeloEdit")
            .opacity(max(0.001, frame.buttonOpacity))
            .scaleEffect(intro.phase == .exiting ? 0.98 : 1)
            .offset(y: top + iconHeight + 32 + 44 + 10 + 28 + 26)
            .disabled(intro.phase == .exiting)
            if intro.phase == .exiting && intro.usesLightReveal {
                RadialGradient(colors: [blue.opacity(0.22), blue.opacity(0.06), .clear], center: .center,
                               startRadius: 0, endRadius: max(size.width, size.height) * (0.25 + frame.reveal))
                    .position(center).allowsHitTesting(false).accessibilityHidden(true)
            }
            HStack {
                Spacer()
                Button("Пропустить") { intro.accept(.skip, reduceMotion: reduceMotion) }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(contrast == .increased ? 1 : 0.82))
                    .buttonStyle(.plain)
                    .padding(12)
                    .contentShape(Rectangle())
                    .disabled(intro.phase == .exiting)
            }.padding(.top, 24).padding(.trailing, 24)
        }
        .frame(width: size.width, height: size.height)
        .opacity(frame.sceneOpacity)
        .contentShape(Rectangle())
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityRepresentation {
            VStack {
                Text("VeloEdit").accessibilityAddTraits(.isHeader)
                Text("Большие идеи начинаются с первого кадра.")
                Button("Начнём") { intro.accept(.begin, reduceMotion: reduceMotion) }
                Button("Пропустить") { intro.accept(.skip, reduceMotion: reduceMotion) }
            }
        }
    }

    private func begin() {
        let event = NSApp.currentEvent
        let pointer = event?.type == .leftMouseUp || event?.type == .leftMouseDown
        intro.accept(.begin, reduceMotion: reduceMotion, pointer: pointer)
    }
}

/// Four broad, feathered beams, clipped above the copy. Static once settled.
private struct FirstLaunchRays: View {
    let strength: Double
    let spread: Double
    var body: some View {
        Canvas { context, size in
            let origin = CGPoint(x: size.width * 0.5, y: size.height * 0.55)
            context.addFilter(.blur(radius: 25))
            for (index, angle) in [-150.0, -103, -49, 13].enumerated() {
                let radians = (angle + (spread - 1) * 9) * .pi / 180
                let reach = size.width * 0.72
                let width = 0.10 + 0.05 * spread
                var path = Path()
                path.move(to: origin)
                path.addLine(to: CGPoint(x: origin.x + cos(radians - width) * reach, y: origin.y + sin(radians - width) * reach))
                path.addLine(to: CGPoint(x: origin.x + cos(radians + width) * reach, y: origin.y + sin(radians + width) * reach))
                path.closeSubpath()
                let color = index == 1 ? Color(red: 0.65, green: 0.88, blue: 0.35) : Color(red: 0.26, green: 0.65, blue: 1)
                context.fill(path, with: .radialGradient(Gradient(colors: [color.opacity(0.24 * strength), color.opacity(0)]),
                                                       center: origin, startRadius: 10, endRadius: reach))
            }
        }.allowsHitTesting(false)
    }
}

enum FirstLaunchArtwork {
    struct Decoded: @unchecked Sendable { let image: CGImage; let fraction: CGFloat }
    static func visibleHeight(windowHeight: CGFloat, scale: CGFloat) -> CGFloat {
        min(560, max(280, windowHeight * 0.48), 1254 * 0.90 / (max(1, scale) * 1.12))
    }
    static func requiredPixels(height: CGFloat, scale: CGFloat) -> CGFloat {
        visibleHeight(windowHeight: height, scale: scale) / 0.90 * scale * 1.12
    }
    static func load(bundle: Bundle = .main, requiredPixels: CGFloat = 1254) -> Decoded? {
        let name = requiredPixels <= 1024 ? "IntroIcon-1024" : "IntroIcon"
        guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "FirstLaunch"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else {
            Logger(subsystem: "app.veloedit", category: "FirstLaunch").error("Intro artwork unavailable; using system icon")
            return nil
        }
        return Decoded(image: image, fraction: 0.90)
    }
}

/// Owns window-scoped keyboard interception and restores the previous responder.
private struct FirstLaunchInputBridge: NSViewRepresentable {
    let intro: FirstLaunchCoordinator
    let reduceMotion: Bool
    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.intro = intro
        view.reduceMotion = reduceMotion
        return view
    }
    func updateNSView(_ view: InputView, context: Context) { view.reduceMotion = reduceMotion }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.stop() }

    final class InputView: NSView {
        weak var intro: FirstLaunchCoordinator?
        var reduceMotion = false
        private var monitor: Any?
        private weak var previousResponder: NSResponder?
        private weak var attachedWindow: NSWindow?
        private var previousAppearance: NSAppearance?
        private var previousBackground: NSColor?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, monitor == nil else { return }
            attachedWindow = window
            previousResponder = window.firstResponder
            previousAppearance = window.appearance
            previousBackground = window.backgroundColor
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(srgbRed: 8 / 255, green: 11 / 255, blue: 16 / 255, alpha: 1)
            window.makeFirstResponder(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let intro = self.intro, intro.isPresented, event.window === self.window,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                if event.keyCode == 53 { intro.accept(.skip, reduceMotion: self.reduceMotion); return nil }
                if event.keyCode == 36 || event.keyCode == 76 {
                    intro.accept(.begin, reduceMotion: self.reduceMotion)
                    return nil
                }
                return event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let window = attachedWindow {
                window.appearance = previousAppearance
                if let previousBackground { window.backgroundColor = previousBackground }
                if let view = previousResponder as? NSView, view.window === window { window.makeFirstResponder(view) }
                else { window.makeFirstResponder(window.contentView) }
            }
            attachedWindow = nil
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
