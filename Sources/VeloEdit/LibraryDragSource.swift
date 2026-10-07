import SwiftUI
import UniformTypeIdentifiers

/// A tap adds a preset; a drag belongs to the card, without a Button consuming
/// the mouse-down sequence before SwiftUI's drag recognizer can start.
struct LibraryItemButton<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        label()
            .contentShape(Rectangle())
            .onTapGesture { if isEnabled { action() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { if isEnabled { action() } }
    }
}

enum LibraryDragSession {
    // These are small textual commands, not files. A custom public.data
    // representation is bridged by SwiftUI to an AppKit file promise. On
    // macOS 27 that promise has no file metadata, so NSFilePromiseReceiver
    // raises an exception before the timeline can handle the drop.
    static let type = UTType.utf8PlainText

    static func provider(for payload: String) -> NSItemProvider {
        let provider = NSItemProvider()
        // Register only text: NSString also advertises public.url for commands
        // such as "title:...", which are not URLs either.
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(Data(payload.utf8), nil)
            return nil
        }
        return provider
    }

    static func load(_ provider: NSItemProvider, completion: @escaping (String?) -> Void) {
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            completion(data.flatMap { String(data: $0, encoding: .utf8) })
        }
    }
}

enum FileDropLoader {
    static func load(_ providers: [NSItemProvider]) async -> [URL] {
        // Preserve Finder's order even when providers resolve asynchronously.
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let value = item as? URL { url = value }
                    else if let text = item as? String { url = URL(string: text) }
                    else { url = nil }
                    continuation.resume(returning: url?.isFileURL == true ? url : nil)
                }
            }
            if let url { urls.append(url) }
        }
        return urls
    }
}

extension View {
    func libraryDraggable(_ payload: String) -> some View {
        modifier(LibraryDragModifier(payload: payload))
    }
}

private struct LibraryDragModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    let payload: String

    func body(content: Content) -> some View {
        content.onDrag {
            guard isEnabled else { return NSItemProvider() }
            return LibraryDragSession.provider(for: payload)
        } preview: {
            content
                .frame(width: 180)
                .fixedSize(horizontal: false, vertical: true)
                .padding(5)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }
}

/// The payload belongs to the actual drag provider, not to a process-global
/// string. Late preview loads cannot revive an exited/cancelled drag, and a
/// quick mouse-up still loads and commits its own provider exactly once.
@MainActor
final class LibraryTimelineDropSession: ObservableObject {
    private var generation = 0
    private var isActive = false
    private var payload: String?
    private var point = CGPoint.zero
    private var preview: ((String, CGPoint) -> Void)?
    typealias Loader = (NSItemProvider, @escaping (String?) -> Void) -> Void
    private let load: Loader

    init(load: @escaping Loader = LibraryDragSession.load) { self.load = load }

    func update(provider: NSItemProvider, at point: CGPoint, preview: @escaping (String, CGPoint) -> Void) {
        self.point = point
        self.preview = preview
        if let payload { preview(payload, point); return }
        guard !isActive else { return }
        isActive = true
        generation += 1
        let expectedGeneration = generation
        load(provider) { [weak self] payload in
            Task { @MainActor in
                guard let self, self.isActive, self.generation == expectedGeneration,
                      let payload else { return }
                self.payload = payload
                self.preview?(payload, self.point)
            }
        }
    }

    func reset() {
        generation += 1
        isActive = false
        payload = nil
        preview = nil
    }

    func perform(provider: NSItemProvider, at point: CGPoint, action: @escaping (String, CGPoint) -> Bool) -> Bool {
        let resolved = payload
        reset()
        if let resolved { return action(resolved, point) }
        load(provider) { payload in
            Task { @MainActor in
                if let payload { _ = action(payload, point) }
            }
        }
        return true
    }
}

struct LibraryTimelineDropDelegate: DropDelegate {
    let isEnabled: Bool
    let session: LibraryTimelineDropSession
    let update: (String, CGPoint) -> Void
    let clear: () -> Void
    let perform: (String, CGPoint) -> Bool
    var updateFiles: ((CGPoint) -> Void)? = nil
    var performFiles: (([NSItemProvider], CGPoint) -> Bool)? = nil

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && (info.hasItemsConforming(to: [LibraryDragSession.type]) ||
            (performFiles != nil && info.hasItemsConforming(to: [.fileURL])))
    }

    func dropEntered(info: DropInfo) { session.reset(); updatePreview(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { session.reset(); clear(); return DropProposal(operation: .cancel) }
        updatePreview(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { session.reset(); clear() }

    func performDrop(info: DropInfo) -> Bool {
        defer { clear() }
        if isEnabled, info.hasItemsConforming(to: [.fileURL]), let performFiles {
            session.reset()
            return performFiles(info.itemProviders(for: [.fileURL]), info.location)
        }
        guard validateDrop(info: info), let provider = info.itemProviders(for: [LibraryDragSession.type]).first else {
            session.reset()
            return false
        }
        return session.perform(provider: provider, at: info.location, action: perform)
    }

    private func updatePreview(_ info: DropInfo) {
        if isEnabled, info.hasItemsConforming(to: [.fileURL]), let updateFiles {
            session.reset()
            updateFiles(info.location)
            return
        }
        guard validateDrop(info: info), let provider = info.itemProviders(for: [LibraryDragSession.type]).first else { return }
        session.update(provider: provider, at: info.location, preview: update)
    }
}
