import AppKit
import SwiftUI
import Testing
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized) @MainActor
struct DirectorSuggestionTests {
    @Test(arguments: ["", "Мой черновик", "Черновик с пробелом ", "Первая строка\nВторая 🎬"])
    func suggestionsAppendWithoutSendingOrStartingWork(draft: String) async throws {
        let suite = "VeloEdit.suggestions.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        var modelCalls = 0
        let agent = LocalDirectorAgent { _, _, _, _ in
            modelCalls += 1
            return DirectorAIReply(text: "Unexpected", runtimeLabel: "fixture", normalizedBrief: nil)
        }
        let model = AppModel(defaults: UserDefaults(suiteName: suite)!, startBackgroundServices: false,
                             directorAgent: agent)
        model.project = ProjectManifest(name: "Suggestions")
        model.directorInput = draft
        let messages = model.directorMessages
        let focusRequest = model.directorInputFocusRequest
        model.insertDirectorSuggestion("Киношный")
        let separator = draft.isEmpty || draft.last?.isWhitespace == true ? "" : " "
        #expect(model.directorInput == draft + separator + "Киношный")
        #expect(model.directorInputFocusRequest != focusRequest)
        for answer in ["Горизонтальный 16:9", "2 мин", "Без музыки", "Без титров"] {
            model.insertDirectorSuggestion(answer)
        }
        #expect(model.directorInput.hasSuffix("Киношный Горизонтальный 16:9 2 мин Без музыки Без титров"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.directorMessages.map(\.id) == messages.map(\.id))
        #expect(model.directorMessages.map(\.text) == messages.map(\.text))
        #expect(modelCalls == 0 && !model.isWorking && !model.isDirectorResponding && !model.isCreatingFilm)
        #expect(model.timeline == nil && model.canSendDirectorMessage)
    }

    @Test func suggestionFocusesComposerAndPlacesCaretAfterUnicodeDraft() async throws {
        let suite = "VeloEdit.suggestion-focus.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: UserDefaults(suiteName: suite)!, startBackgroundServices: false)
        model.directorInput = "Мой фильм 🎬"
        let host = NSHostingView(rootView: DirectorComposer().environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func waitForCaret() async throws {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if let editor = window.firstResponder as? NSTextView,
                   editor.string == model.directorInput,
                   editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0) { return }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        model.insertDirectorSuggestion("Киношный")
        try await waitForCaret()
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.string == "Мой фильм 🎬 Киношный")
        #expect(editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0))
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        model.insertDirectorSuggestion("Без музыки")
        try await waitForCaret()
        #expect(editor.string == "Мой фильм 🎬 Киношный Без музыки")
        #expect(editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(" — дописано", replacementRange: editor.selectedRange())
        #expect(model.directorInput == "Мой фильм 🎬 Киношный Без музыки — дописано")
        #expect(!model.directorMessages.contains { $0.role == .user })
    }
}
