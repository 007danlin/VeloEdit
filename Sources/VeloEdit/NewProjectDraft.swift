import Foundation
import Darwin
import VeloEditCore

struct NewProjectDraft: Sendable {
    var name = "Мой фильм"
    var directoryURL: URL
    var tags = ""

    var projectName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ".\(ProjectStore.packageExtension)"
        return trimmed.lowercased().hasSuffix(suffix)
            ? String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed
    }

    var validationMessage: String? {
        let name = projectName
        if name.isEmpty { return "Введите название проекта." }
        if name == "." || name == ".." || name.contains(where: { "/:".contains($0) || $0.isNewline || $0 == "\0" }) {
            return "В названии нельзя использовать /, : и переносы строк."
        }
        if (name + ".\(ProjectStore.packageExtension)").utf8.count > 255 {
            return "Название слишком длинное. Сократите его."
        }
        return nil
    }

    var packageURL: URL {
        directoryURL.appendingPathComponent(projectName, isDirectory: true)
            .appendingPathExtension(ProjectStore.packageExtension)
    }

    var tagNames: [String] {
        var seen = Set<String>()
        return tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func makeStore() throws -> ProjectStore {
        // Reserve a new directory exclusively. ProjectStore(createAt:) alone
        // can write into an existing package, which this form must never do.
        var url = packageURL
        guard url.path.withCString({ mkdir($0, 0o755) }) == 0 else {
            let code = errno
            if code == EEXIST { throw CocoaError(.fileWriteFileExists) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
        do {
            let store = try ProjectStore(createAt: url, name: projectName)
            var values = URLResourceValues()
            values.hasHiddenExtension = true
            try? url.setResourceValues(values)
            if !tagNames.isEmpty {
                try (url as NSURL).setResourceValue(tagNames, forKey: .tagNamesKey)
            }
            return store
        } catch {
            // Only this invocation owns the newly reserved package.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
