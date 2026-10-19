import AppKit

@MainActor
final class ProjectOpenPanelValidator: NSObject, NSOpenSavePanelDelegate {
    static let shared = ProjectOpenPanelValidator()

    func panel(_ sender: Any, validate url: URL) throws {
        var isDirectory: ObjCBool = false
        guard url.pathExtension.lowercased() == "veloedit",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInvalidFileNameError,
                userInfo: [NSLocalizedDescriptionKey: "Выберите файл проекта с расширением .veloedit."])
        }
    }
}
