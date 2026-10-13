import Foundation
import CryptoKit

public enum ManagedMediaImport {
    public static func requiresCopy(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsLocalKey])
        if values?.volumeIsInternal == false || values?.volumeIsRemovable == true || values?.volumeIsLocal == false { return true }
        // Disconnected volumes cannot supply resource values. Keep them in the
        // managed-import path so reconnecting and retrying finishes the copy.
        return values?.volumeIsInternal == nil && resolved.path.hasPrefix("/Volumes/")
    }

    static func copy(_ source: URL, to destination: URL, progress: (@Sendable (ImportProgress) -> Void)?) async throws -> String {
        let worker = Task.detached(priority: .userInitiated) {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default
            let before = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
            let size = before.fileSize ?? 0
            guard size > 0 else { throw MediaImportError.empty(source) }
            try Task.checkCancellation()
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let capacity = try? destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let available = capacity?.volumeAvailableCapacityForImportantUsage, available < Int64(size) {
                throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue,
                    userInfo: [NSFilePathErrorKey: destination.path, NSLocalizedDescriptionKey: "Недостаточно места для копирования \(source.lastPathComponent) в проект."])
            }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".import-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temporary) }
            guard fm.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission) }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            var digest = SHA256()
            var copied = 0
            var lastPercent = -1
            while true {
                try Task.checkCancellation()
                let data = try input.read(upToCount: 4 * 1024 * 1024) ?? Data()
                if data.isEmpty { break }
                try output.write(contentsOf: data)
                digest.update(data: data)
                copied += data.count
                let percent = min(99, Int(Double(copied) / Double(size) * 100))
                if percent != lastPercent {
                    progress?(ImportProgress(completed: percent, total: 100,
                        currentName: "Копирую в проект: \(source.lastPathComponent) · \(percent)%", currentFileName: source.lastPathComponent))
                    lastPercent = percent
                }
            }
            try output.synchronize()
            try output.close()
            let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard copied == size, before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
                throw MediaImportError.damaged(source)
            }
            progress?(ImportProgress(completed: 99, total: 100, currentName: "Проверяю копию: \(source.lastPathComponent)"))
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard try MediaImporter.sha256(url: temporary) == hash else { throw MediaImportError.damaged(temporary) }
            var attributes: [FileAttributeKey: Any] = [:]
            if let date = before.contentModificationDate { attributes[.modificationDate] = date }
            if let date = before.creationDate { attributes[.creationDate] = date }
            try fm.setAttributes(attributes, ofItemAtPath: temporary.path)
            try Task.checkCancellation()
            if fm.fileExists(atPath: destination.path) {
                guard try MediaImporter.sha256(url: destination) == hash else { throw CocoaError(.fileWriteFileExists) }
            } else { try fm.moveItem(at: temporary, to: destination) }
            progress?(ImportProgress(completed: 100, total: 100, currentName: "Скопировано: \(source.lastPathComponent)"))
            return hash
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

extension VeloEditPipeline {
    /// Also upgrades projects imported by older releases. IDs and timeline
    /// bindings stay stable; only verified, complete copies become originals.
    public func secureExternalMedia(progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws {
        if await store.manifest.assets.contains(where: { !FileManager.default.isReadableFile(atPath: $0.originalURL.path) }) {
            _ = try await recoverMissingSources()
        }
        let current = await store.manifest
        let package = store.packageURL
        let prefix = package.standardizedFileURL.path + "/"
        let hadRecoverableBuild = await store.recoverableFilmBuild() != nil
        var copiedAny = false
        // An unrelated, already-offline source must not prevent importing new
        // files. Existing analysis/export checks decide which missing sources
        // are actually required; a disconnection during this copy still fails.
        for asset in current.assets where !asset.originalURL.standardizedFileURL.path.hasPrefix(prefix)
            && shouldCopyImportedMedia(asset.originalURL)
            && FileManager.default.isReadableFile(atPath: asset.originalURL.path) {
            try Task.checkCancellation()
            guard store.packageIsAvailable else { throw ProjectStoreError.invalidProjectPackage(package) }
            let relative = "Media/Originals/\(asset.id.uuidString)/\(asset.originalURL.lastPathComponent)"
            let destination = package.appendingPathComponent(relative)
            let hash = try await ManagedMediaImport.copy(asset.originalURL, to: destination, progress: progress)
            // Quick identity also catches source replacement between metadata
            // import and copying, before rebinding an existing timeline.
            guard try MediaSourceRecovery.matches(destination, asset: asset) else { throw MediaImportError.damaged(asset.originalURL) }
            try Task.checkCancellation()
            guard store.packageIsAvailable, store.packageURL == package else { throw ProjectStoreError.invalidProjectPackage(package) }
            try await store.updateAnalysisProgress { manifest in
                guard let index = manifest.assets.firstIndex(where: { $0.id == asset.id }),
                      manifest.assets[index].originalURL == asset.originalURL else { return }
                manifest.assets[index].importSourceURL = asset.importSourceURL ?? asset.originalURL
                manifest.assets[index].originalURL = destination
                manifest.assets[index].bookmarkData = nil
                manifest.assets[index].fullContentHash = hash
                manifest.assets[index].missing = false
                var mediaPaths = manifest.packagedMediaPaths ?? [:]
                mediaPaths[asset.id] = relative
                manifest.packagedMediaPaths = mediaPaths
                var filePaths = manifest.packagedFilePaths ?? [:]
                filePaths[destination.absoluteString] = relative
                manifest.packagedFilePaths = filePaths
                let identity = FrameCacheKey.sourceIdentity(url: destination, contentHash: asset.contentHash)
                for i in manifest.analyses.indices where manifest.analyses[i].assetID == asset.id
                    && manifest.analyses[i].analyzedContentHash == asset.contentHash {
                    if manifest.analyses[i].analyzedSourceIdentity != nil { manifest.analyses[i].analyzedSourceIdentity = identity }
                }
            }
            SupportDiagnostics.shared.record("Исходник скопирован и проверен: \(asset.originalURL.path) → \(destination.path)")
            copiedAny = true
        }
        if copiedAny && hadRecoverableBuild { try await store.rebindRecoveredMediaInputs() }
    }
}
