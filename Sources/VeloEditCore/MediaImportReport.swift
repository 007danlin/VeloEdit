import Foundation

public struct MediaImportReport: Codable, Sendable {
    public enum Outcome: String, Codable, Sendable { case added, duplicate, failed }
    public struct Entry: Codable, Sendable {
        public var url: URL
        public var outcome: Outcome
        public var message: String
        public init(url: URL, outcome: Outcome, message: String) {
            self.url = url; self.outcome = outcome; self.message = message
        }
    }
    public var date = Date()
    public var entries: [Entry] = []
    public init() {}
    public var failures: [Entry] { entries.filter { $0.outcome == .failed } }
    public var summary: String {
        "Добавлено: \(entries.filter { $0.outcome == .added }.count) · Уже в проекте: \(entries.filter { $0.outcome == .duplicate }.count) · Не добавлено: \(failures.count)"
    }
    public var text: String {
        ([summary] + entries.map { "\($0.url.path): \($0.message)" }).joined(separator: "\n")
    }
}

extension MediaImporter {
    /// Preserve rejected files from folder selection as well as explicit URLs.
    /// Packages and hidden files are not treated as media collections.
    func scanInputs(_ urls: [URL]) -> (files: [URL], failures: [MediaImportReport.Entry]) {
        let fm = FileManager.default
        var files: Set<URL> = []
        var failures: [MediaImportReport.Entry] = []
        for url in urls {
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &directory), fm.isReadableFile(atPath: url.path) else {
                failures.append(.init(url: url, outcome: .failed, message: "Файл или папка недоступны. Проверьте носитель и права доступа."))
                continue
            }
            if directory.boolValue {
                let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { failedURL, error in
                        failures.append(.init(url: failedURL, outcome: .failed, message: error.localizedDescription))
                        return true
                    })
                while let file = enumerator?.nextObject() as? URL {
                    if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        files.insert(file.standardizedFileURL)
                    }
                }
            } else { files.insert(url.standardizedFileURL) }
        }
        return (files.sorted { $0.path < $1.path }, failures)
    }
}
