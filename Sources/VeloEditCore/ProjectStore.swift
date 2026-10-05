import Foundation
import Darwin

/// Small, stable metadata used by the home screen without decoding a project
/// manifest that may contain tens of megabytes of analysis and telemetry.
public struct ProjectSummary: Codable, Equatable, Sendable {
    public static let fileName = "project-summary.json"
    public static let currentStatisticsVersion = 1

    public var projectID: UUID
    public var name: String
    public var assetCount: Int
    public var updatedAt: Date
    public var previewKind: MediaKind?
    public var previewRelativePaths: [String]
    /// Optional fields keep summaries written by older VeloEdit builds decodable.
    public var analyzedContentDuration: Double?
    public var analyzedAssetCount: Int?
    public var statisticsVersion: Int?
    public var hasPlayableTimeline: Bool?
    public var generationStatus: IntentStatus?

    public static func load(from packageURL: URL) -> ProjectSummary? {
        let url = packageURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return try? JSONDecoder.veloEdit.decode(ProjectSummary.self, from: data)
    }
}

public enum ProjectStoreError: LocalizedError {
    case invalidProjectPackage(URL)
    case unsupportedProjectVersion(Int)
    case staleRevision(expected: UInt64, actual: UInt64)
    case externalModification
    case persistenceFailure(stage: String, path: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .invalidProjectPackage(let url): return "Некорректный проект: \(url.path)"
        case .unsupportedProjectVersion(let version): return "Версия проекта \(version) пока не поддерживается"
        case .staleRevision(let expected, let actual):
            return "Фоновый результат устарел: проект уже изменён (ожидалась ревизия \(expected), текущая \(actual))"
        case .externalModification:
            return "Проект изменён другим процессом. Повторно откройте его; устаревший результат не записан."
        case .persistenceFailure(let stage, let path, let underlying):
            return "Не удалось сохранить проект (\(stage)) по пути \(path): \(underlying)"
        }
    }
}

/// An immutable manifest and the in-process revision that produced it. Long
/// background operations must commit against this token instead of replacing
/// newer user edits with results computed from an old snapshot.
public struct ProjectStoreSnapshot: Sendable {
    public let manifest: ProjectManifest
    public let revision: UInt64

    public init(manifest: ProjectManifest, revision: UInt64) {
        self.manifest = manifest
        self.revision = revision
    }
}

public actor ProjectStore {
    public static let packageExtension = "veloedit"
    public let packageURL: URL
    public private(set) var manifest: ProjectManifest
    private var revision: UInt64 = 0
    private var persistedManifestFingerprint: String?
    private let recoveryDirectory: URL
    private var ownsRecoveryJournal = false
    public private(set) var persistenceLocation: ProjectPersistenceLocation = .project

    public var manifestURL: URL { packageURL.appendingPathComponent("project.json") }
    public var summaryURL: URL { packageURL.appendingPathComponent(ProjectSummary.fileName) }
    public var cacheURL: URL { packageURL.appendingPathComponent("Cache", isDirectory: true) }
    public var thumbnailsURL: URL { cacheURL.appendingPathComponent("Thumbnails", isDirectory: true) }
    public var proxiesURL: URL { cacheURL.appendingPathComponent("Proxies", isDirectory: true) }
    public var previewsURL: URL { cacheURL.appendingPathComponent("Preview", isDirectory: true) }
    public var exportsURL: URL { packageURL.appendingPathComponent("Exports", isDirectory: true) }
    public var logsURL: URL { packageURL.appendingPathComponent("Logs", isDirectory: true) }
    public nonisolated var musicLibraryURL: URL { packageURL.appendingPathComponent("MusicLibrary", isDirectory: true) }

    public init(createAt packageURL: URL, name: String, recoveryDirectory: URL? = nil) throws {
        self.packageURL = packageURL
        self.recoveryDirectory = recoveryDirectory ?? LocalProjectRecovery.defaultDirectory
        self.manifest = ProjectManifest(name: name)
        try Self.createDirectories(at: packageURL)
        self.persistedManifestFingerprint = try Self.write(self.manifest, to: packageURL.appendingPathComponent("project.json"))
        try? Self.writeSummary(for: self.manifest, at: packageURL)
    }

    public init(open packageURL: URL, recoveryDirectory: URL? = nil) throws {
        self.packageURL = packageURL
        let recoveryRoot = recoveryDirectory ?? LocalProjectRecovery.defaultDirectory
        self.recoveryDirectory = recoveryRoot
        let projectURL = packageURL.appendingPathComponent("project.json")
        let recovery = try LocalProjectRecovery.read(package: packageURL, root: recoveryRoot)
        // Read once: large archives include all analysis and telemetry. Keep
        // the original bytes for CAS even if portable paths need relocation.
        let primaryData: Data?
        if recovery != nil {
            primaryData = try? Data(contentsOf: projectURL)
        } else {
            primaryData = try Data(contentsOf: projectURL)
        }
        var data: Data
        var restoredLocally = false
        if let recovery {
            let recovered: Data
            if let primaryData {
                let remote = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: primaryData)
                guard remote.id == recovery.0.projectID else { throw ProjectStoreError.invalidProjectPackage(packageURL) }
                recovered = try LocalProjectRecovery.merge(base: recovery.1, local: recovery.2, remote: primaryData)
            } else {
                recovered = recovery.2
            }
            data = recovered
            if let primaryData {
                do {
                    let restored = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: recovered)
                    _ = try Self.write(restored, to: projectURL, expectedFingerprint: EditorialProjectMigration.hash(primaryData))
                    data = try Data(contentsOf: projectURL)
                    LocalProjectRecovery.clear(package: packageURL, root: recoveryRoot)
                } catch { restoredLocally = true }
            } else { restoredLocally = true }
        } else {
            data = primaryData!
        }
        let decoder = JSONDecoder.veloEdit
        let storedData = data
        var decoded = try decoder.decode(ProjectManifest.self, from: data)
        guard decoded.projectVersion <= 1 else { throw ProjectStoreError.unsupportedProjectVersion(decoded.projectVersion) }
        // The normal open path needs only Codable. JSONSerialization used to
        // build and discard a second object graph for every archive, including
        // projects that were never packaged or moved.
        if PortableProjectPaths.needsRelocation(decoded.packagedFilePaths, to: packageURL) {
            data = try PortableProjectPaths.relocate(data, to: packageURL)
            decoded = try decoder.decode(ProjectManifest.self, from: data)
        }
        var requiresRecoveryWrite = data != storedData
        if let paths = decoded.packagedMediaPaths {
            for index in decoded.assets.indices {
                guard let relative = paths[decoded.assets[index].id], relative.hasPrefix("Media/"),
                      !relative.split(separator: "/").contains("..") else { continue }
                let embedded = packageURL.appendingPathComponent(relative)
                if decoded.assets[index].originalURL != embedded {
                    decoded.assets[index].originalURL = embedded
                    decoded.assets[index].bookmarkData = nil
                    requiresRecoveryWrite = true
                }
            }
        }
        if var ledger = decoded.intentLedger {
            for i in ledger.entries.indices where ledger.entries[i].status == .running {
                ledger.entries[i].status = .recoverableFailure
                ledger.entries[i].failureReason = "Операция прервана закрытием проекта; анализ сохранён, доступен повтор AI Edit"
                requiresRecoveryWrite = true
            }
            if requiresRecoveryWrite {
                decoded.intentLedger = ledger
            }
        } else if decoded.timelines.isEmpty, decoded.workspaceState?.hasPendingFilmChanges == true {
            decoded.intentLedger = IntentLedger(entries: [.init(id: UUID(), projectRevision: 0, normalizedIntent: .createFilm, source: .recovery, status: .recoverableFailure, evidence: [], failureReason: "В проекте есть create intent, но отсутствует Timeline; доступен повтор AI Edit")])
            requiresRecoveryWrite = true
        }
        self.manifest = decoded
        self.persistedManifestFingerprint = restoredLocally
            ? (primaryData.map(EditorialProjectMigration.hash) ?? recovery?.0.baseFingerprint)
            : EditorialProjectMigration.hash(storedData)
        self.ownsRecoveryJournal = restoredLocally
        self.persistenceLocation = restoredLocally ? .localRecovery : .project
        if !restoredLocally {
            try Self.createDirectories(at: packageURL)
        }
        // Opening a healthy project is read-only. Previously every project
        // with an intent ledger was re-encoded here, so the home-screen summary
        // migration and an explicit open could race and falsely look like an
        // external writer even though neither changed project state.
        if requiresRecoveryWrite && !restoredLocally {
            self.persistedManifestFingerprint = try Self.write(decoded, to: packageURL.appendingPathComponent("project.json"), expectedFingerprint: persistedManifestFingerprint)
        }
        // Opening an older package also migrates it to the lightweight summary
        // used by recent-project cards.
        try? Self.writeSummary(for: decoded, at: packageURL)
    }

    public func update(_ mutation: (inout ProjectManifest) throws -> Void) throws {
        try persist(mutation, invalidatingBackgroundWork: true)
    }

    func persistFilmBuildRecovery(_ recovery: FilmBuildRecovery?) throws {
        try persist({ $0.filmBuildRecovery = recovery }, invalidatingBackgroundWork: false)
    }

    func persistOperationalState(_ mutation: (inout ProjectManifest) throws -> Void) throws {
        try persist(mutation, invalidatingBackgroundWork: false)
    }

    func updateAnalysisProgress(_ mutation: (inout ProjectManifest) throws -> Void) throws {
        try persist(mutation, invalidatingBackgroundWork: true, preservingFilmBuildRequest: true)
    }

    func updateFilmBuildAnalyses(_ analyses: [AnalysisResult], ifRevision expectedRevision: UInt64) throws {
        guard revision == expectedRevision else {
            throw ProjectStoreError.staleRevision(expected: expectedRevision, actual: revision)
        }
        try persist({ project in
            project.analyses = analyses
        }, invalidatingBackgroundWork: true, preservingFilmBuildRequest: true)
    }

    /// Persists editor UI state without invalidating results computed from the
    /// current media/timeline snapshot. The compare-and-swap revision protects
    /// project content; drafts, navigation and Director chat are auxiliary and
    /// are merged into the latest manifest when a background result commits.
    public func updateWorkspaceState(_ state: ProjectWorkspaceState) throws {
        let old = manifest.workspaceState
        // Typing autosave and project switching often flush the same state.
        // Avoid re-encoding all analysis/telemetry for an unchanged draft.
        guard old != state else { return }
        let changesIntent = old?.prompt != state.prompt || old?.directorBrief != state.directorBrief
            || old?.pendingDirectorInstructions != state.pendingDirectorInstructions
            || old?.preset != state.preset || old?.targetMinutes != state.targetMinutes
            || old?.directorMusicTrackID != state.directorMusicTrackID
        try persist({ $0.workspaceState = state }, invalidatingBackgroundWork: changesIntent)
    }

    public func beginEditorialGeneration(prompt: String, brief: DirectorBrief?) throws -> [UUID] {
        let previous = manifest.timelines.last
        let previouslyEvaluated = Set(manifest.intentLedger?.entries.filter { $0.status == .fulfilled }.flatMap { $0.evidence.compactMap(\.assetID) } ?? [])
        let oldAssets = Set(previous?.items.compactMap(\.assetID) ?? []).union(previouslyEvaluated)
        let intents = IntentLedgerEngine.intents(prompt: prompt, brief: brief, pending: manifest.workspaceState?.pendingDirectorInstructions ?? [], newAssetIDs: manifest.assets.map(\.id).filter { !oldAssets.contains($0) })
        let entries = intents.map { IntentLedgerEntry(id: UUID(), projectRevision: revision, normalizedIntent: $0, source: .prompt, status: .running, evidence: [], originalRequest: prompt) }
        try persist({ project in
            var ledger = project.intentLedger ?? IntentLedger()
            for i in ledger.entries.indices where ledger.entries[i].status == .running {
                ledger.entries[i].status = .recoverableFailure
                ledger.entries[i].failureReason = "Предыдущая операция прервана; начат безопасный повтор"
            }
            ledger.entries.append(contentsOf: entries)
            project.intentLedger = ledger
        }, invalidatingBackgroundWork: true)
        return entries.map(\.id)
    }

    public func isCurrentEditorialGeneration(ids: [UUID]) -> Bool {
        !ids.isEmpty && ids.allSatisfy { id in manifest.intentLedger?.entries.contains { $0.id == id && $0.status == .running } == true }
    }

    public func failEditorialGeneration(ids: [UUID], error: Error) throws {
        try persist({ project in
            guard var ledger = project.intentLedger else { return }
            for i in ledger.entries.indices where ids.contains(ledger.entries[i].id) && ledger.entries[i].status == .running {
                ledger.entries[i].status = error is CancellationError ? .cancelled : .recoverableFailure
                ledger.entries[i].failureReason = error.localizedDescription
            }
            project.intentLedger = ledger
        }, invalidatingBackgroundWork: false)
    }

    /// Called inside the same compare-and-swap mutation as the Timeline write.
    /// Evidence cannot become fulfilled if serialization or validation fails.
    public static func verifyAndFulfillEditorialGeneration(in project: inout ProjectManifest, ids: [UUID], timeline: Timeline, analyses: [AnalysisResult]) throws -> Timeline {
        var verified = timeline
        let delivered = timeline.filmDeliveryReport?.isCurrent(for: timeline) == true
        if timeline.editorialReview != nil {
            guard delivered || timeline.editorialReview?.candidateEligible == true else {
                throw EditorialGenerationError.noPassingVariant(timeline.editorialReview?.findings ?? [])
            }
        }
        try fulfillEditorialGeneration(in: &project, ids: ids, timeline: timeline, analyses: analyses)
        if verified.editorialReview != nil {
            guard !ids.isEmpty, let ledger = project.intentLedger,
                  ids.allSatisfy({ id in ledger.entries.contains { $0.id == id && [.fulfilled, .rejected].contains($0.status) } }) else {
                throw EditorialGenerationError.unsatisfiedIntent("Нет подтверждения всех команд в транзакции")
            }
            let intentEvidence = EditorialDomainEvidence(domain: .pendingIntentSatisfaction, status: .passed, required: true, confidence: 1, coverage: 1, itemIDs: verified.items.map(\.id), probeTimes: [], provenance: ["IntentLedgerEngine.validate within ProjectStore CAS"], reason: "Все команды текущей генерации проверены; fulfilled/rejected записываются атомарно с Timeline", finding: nil)
            if let index = verified.editorialReview?.evidenceDomains?.firstIndex(where: { $0.domain == .pendingIntentSatisfaction }) {
                verified.editorialReview?.evidenceDomains?[index] = intentEvidence
            } else if delivered {
                let domains = (verified.editorialReview?.evidenceDomains ?? []) + [intentEvidence]
                verified.editorialReview?.evidenceDomains = domains
            }
            guard delivered || verified.editorialReview?.productionEligible == true else {
                throw EditorialGenerationError.noPassingVariant(verified.editorialReview?.findings ?? [])
            }
            verified.directorRun?.editorialReview = verified.editorialReview
        }
        if delivered, let ledger = project.intentLedger {
            let unmet = ledger.entries.filter { ids.contains($0.id) && $0.status == .rejected }.compactMap(\.failureReason)
            verified.filmDeliveryReport?.warnings += unmet
            for message in unmet {
                verified.filmDeliveryReport?.requirements?.append(.init(sourcePhrase: message, rule: "intent", verificationMethod: "IntentLedgerEngine", passed: false, evidence: message))
            }
        }
        return verified
    }

    public static func fulfillEditorialGeneration(in project: inout ProjectManifest, ids: [UUID], timeline: Timeline, analyses: [AnalysisResult]) throws {
        guard var ledger = project.intentLedger else { return }
        guard ids.allSatisfy({ id in ledger.entries.contains { $0.id == id && $0.status == .running } }) else {
            throw EditorialGenerationError.unsatisfiedIntent("Операция заменена новым запросом")
        }
        for i in ledger.entries.indices where ids.contains(ledger.entries[i].id) {
            let result = IntentLedgerEngine.validate(ledger.entries[i].normalizedIntent, timeline: timeline, previous: project.timelines.last, analyses: analyses, assets: project.assets)
            if result.0 == .recoverableFailure {
                guard timeline.filmDeliveryReport?.isCurrent(for: timeline) == true,
                      ledger.entries[i].normalizedIntent != .createFilm else {
                    throw EditorialGenerationError.unsatisfiedIntent(result.2 ?? "Нет evidence")
                }
                // Deliver the movie and honestly record the unmet instruction.
                ledger.entries[i].status = .rejected
            } else {
                ledger.entries[i].status = result.0
            }
            ledger.entries[i].evidence = result.1
            ledger.entries[i].failureReason = result.2
        }
        project.intentLedger = ledger
        let messages = ledger.entries.filter { ids.contains($0.id) && $0.status == .rejected }.compactMap(\.failureReason)
        var status = messages
        if let duration = timeline.editorialReview?.duration, duration.durationConstraintStatus == .compromisedInsufficientContent { status.append(duration.reason + " Сохранено \(Int(timeline.duration.rounded())) с.") }
        if project.workspaceState != nil {
            if !status.isEmpty {
                var conversation = project.workspaceState?.directorMessages ?? []
                conversation.append(ProjectDirectorMessage(role: .assistant, text: status.joined(separator: "\n")))
                project.workspaceState?.directorMessages = conversation
            }
            project.workspaceState?.hasPendingFilmChanges = !ledger.unfulfilledInstructions.isEmpty
            project.workspaceState?.pendingDirectorInstructions = ledger.unfulfilledInstructions
        }
    }

    private func persist(
        _ mutation: (inout ProjectManifest) throws -> Void,
        invalidatingBackgroundWork: Bool,
        preservingFilmBuildRequest: Bool = false
    ) throws {
        var next = manifest
        try mutation(&next)
        if invalidatingBackgroundWork {
            for index in next.timelines.indices where next.timelines[index].automaticallySelectFrameRate == true {
                next.timelines[index] = TimelineFrameRatePolicy.applying(to: next.timelines[index], assets: next.assets)
            }
        }
        if !FilmBuildRecovery.inputsEqual(manifest, next) {
            next.filmBuildContentRevision = UUID()
        }
        if preservingFilmBuildRequest, next.filmBuildRecovery?.draft == nil {
            let signature = FilmBuildRecovery.signature(next)
            next.filmBuildRecovery?.contentSignature = signature
        }
        next.updatedAt = Date()
        let fingerprint: String
        do {
            fingerprint = try Self.write(next, to: manifestURL, expectedFingerprint: persistedManifestFingerprint)
        } catch {
            try recoverPersistenceFailure(error, next: next, invalidatingBackgroundWork: invalidatingBackgroundWork)
            return
        }
        try? Self.writeSummary(for: next, at: packageURL)
        manifest = next
        persistedManifestFingerprint = fingerprint
        persistenceLocation = .project
        if ownsRecoveryJournal {
            LocalProjectRecovery.clear(package: packageURL, root: recoveryDirectory)
            ownsRecoveryJournal = false
        }
        if invalidatingBackgroundWork {
            revision &+= 1
        }
    }

    // Keep recovery's large value snapshots off the synchronous encoding stack.
    @inline(never)
    private func recoverPersistenceFailure(_ error: Error, next: ProjectManifest, invalidatingBackgroundWork: Bool) throws {
    if case ProjectStoreError.externalModification = error,
       let remote = try? Data(contentsOf: manifestURL),
       let merged = try? LocalProjectRecovery.merge(base: ProjectManifestEncoding.encode(manifest), local: ProjectManifestEncoding.encode(next), remote: remote),
       var rebased = try? JSONDecoder.veloEdit.decode(ProjectManifest.self, from: merged) {
        guard rebased.id == manifest.id else { throw ProjectStoreError.externalModification }
        rebased.filmBuildContentRevision = UUID()
        let fingerprint = try Self.write(rebased, to: manifestURL, expectedFingerprint: EditorialProjectMigration.hash(remote))
        manifest = rebased
        persistedManifestFingerprint = fingerprint
        persistenceLocation = .project
        revision &+= 1
        try? Self.writeSummary(for: rebased, at: packageURL)
        return
    }
    // Preserve the exact optimistic edit before returning any conflict.
    // If both stores fail, leave the in-memory base untouched and throw.
    try LocalProjectRecovery.stage(next, base: manifest, package: packageURL, root: recoveryDirectory)
    ownsRecoveryJournal = true
    if case ProjectStoreError.externalModification = error { throw error }
    manifest = next
    persistenceLocation = .localRecovery
    if invalidatingBackgroundWork { revision &+= 1 }
    return
    }

    /// Compare-and-swap persistence for work that crossed an `await`. The
    /// mutation is never evaluated when the token is stale, keeping a newer
    /// manual Timeline edit authoritative over an older AI/analysis result.
    public func update(
        ifRevision expectedRevision: UInt64,
        _ mutation: (inout ProjectManifest) throws -> Void
    ) throws {
        guard revision == expectedRevision else {
            throw ProjectStoreError.staleRevision(expected: expectedRevision, actual: revision)
        }
        try update(mutation)
    }

    public func snapshot() -> ProjectStoreSnapshot {
        ProjectStoreSnapshot(manifest: manifest, revision: revision)
    }

    public func currentRevision() -> UInt64 { revision }

    public func save() throws {
        try persist({ _ in }, invalidatingBackgroundWork: false)
    }

    public func verifyDurableState() throws -> ProjectPersistenceLocation {
        if persistenceLocation == .localRecovery {
            guard let recovery = try LocalProjectRecovery.read(package: packageURL, root: recoveryDirectory),
                  recovery.0.projectID == manifest.id else { throw ProjectStoreError.invalidProjectPackage(packageURL) }
        } else {
            let data = try Data(contentsOf: manifestURL)
            guard EditorialProjectMigration.hash(data) == persistedManifestFingerprint else { throw ProjectStoreError.externalModification }
        }
        return persistenceLocation
    }

    public func reload() throws {
        let data = try Data(contentsOf: manifestURL)
        manifest = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: data)
        persistedManifestFingerprint = EditorialProjectMigration.hash(data)
        try? Self.writeSummary(for: manifest, at: packageURL)
        revision &+= 1
    }

    public func cachedAnalysis(for asset: MediaAsset) -> AnalysisResult? {
        manifest.analyses.first {
            $0.assetID == asset.id &&
            $0.analyzedContentHash == asset.contentHash &&
            $0.schemaVersion == manifest.analysisSchemaVersion &&
            $0.deepMediaVersion == DeepAnalysisCache.version
        }
    }

    public func resolveURL(for asset: MediaAsset) -> URL? {
        if FileManager.default.fileExists(atPath: asset.originalURL.path) { return asset.originalURL }
        guard let bookmark = asset.bookmarkData else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private static func createDirectories(at packageURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        for relative in ["Cache/Thumbnails", "Cache/TimelineThumbnails", "Cache/Proxies", "Cache/Frames", "Cache/Analysis", "Cache/Preview", "Cache/Backgrounds", "Exports", "Logs", "MusicLibrary/Files"] {
            try fm.createDirectory(at: packageURL.appendingPathComponent(relative, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    @discardableResult
    private static func write(_ manifest: ProjectManifest, to url: URL, expectedFingerprint: String? = nil) throws -> String {
        let trace = PerformanceTrace.current
        let span = trace?.begin("project.save", fields: ["projectID": manifest.id.uuidString, "path": url.path])
        var outcome = "failed"
        defer { trace?.end(span, stage: "project.save", status: outcome) }
        let encode = trace?.begin("project.serialize")
        let data = try ProjectManifestEncoding.encode(manifest)
        trace?.end(encode, stage: "project.serialize")
        do {
            try withManifestLock(for: url) {
                if let expectedFingerprint {
                    guard let existing = try? Data(contentsOf: url), EditorialProjectMigration.hash(existing) == expectedFingerprint else {
                        throw ProjectStoreError.externalModification
                    }
                }
                try LocalProjectRecovery.durableWrite(data, to: url)
            }
        } catch {
            if error is ProjectStoreError { throw error }
            let nsError = error as NSError
            throw ProjectStoreError.persistenceFailure(stage: "atomic write", path: url.path, underlying: "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
        }
        outcome = "success"
        return EditorialProjectMigration.hash(data)
    }

    /// Serializes manifest compare-and-swap across app and CLI processes.
    /// NSFileCoordinator can fail before invoking its accessor for large APFS
    /// package manifests; an advisory lock is deterministic for every VeloEdit
    /// writer while the actual replacement remains atomic.
    static func withManifestLock<T>(for manifestURL: URL, _ operation: () throws -> T) throws -> T {
        let lockURL = manifestURL.deletingLastPathComponent().appendingPathComponent(".project.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw ProjectStoreError.persistenceFailure(stage: "open lock", path: lockURL.path, underlying: String(cString: strerror(errno)))
        }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw ProjectStoreError.persistenceFailure(stage: "acquire lock", path: lockURL.path, underlying: String(cString: strerror(errno)))
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func writeSummary(for manifest: ProjectManifest, at packageURL: URL) throws {
        let assetsByID = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.id, $0) })
        let firstTimelinePair = manifest.timelines.last?.items
            .filter { $0.overlay == nil && $0.kind != .title && $0.assetID != nil }
            .enumerated()
            .sorted {
                if $0.element.timelineStart != $1.element.timelineStart {
                    return $0.element.timelineStart < $1.element.timelineStart
                }
                return $0.offset < $1.offset
            }
            .lazy
            .compactMap { indexed -> (TimelineItem, MediaAsset)? in
                guard let assetID = indexed.element.assetID, let asset = assetsByID[assetID] else { return nil }
                return (indexed.element, asset)
            }
            .first

        let cachePaths = CachePaths(root: packageURL.appendingPathComponent("Cache", isDirectory: true))
        let previewAsset = firstTimelinePair?.1
        var previewURLs: [URL] = []
        if let (item, asset) = firstTimelinePair {
            previewURLs.append(cachePaths.timelineThumbnail(for: item, asset: asset))
        }
        if let previewAsset {
            previewURLs.append(cachePaths.thumbnail(for: previewAsset))
        }
        let packagePrefix = packageURL.standardizedFileURL.path + "/"
        let relativePaths = previewURLs.compactMap { candidate -> String? in
            let path = candidate.standardizedFileURL.path
            guard path.hasPrefix(packagePrefix) else { return nil }
            return String(path.dropFirst(packagePrefix.count))
        }
        let analyzedAssets = manifest.assets.filter { asset in
            manifest.analyses.contains {
                $0.assetID == asset.id && $0.analyzedContentHash == asset.contentHash
            }
        }
        let analyzedContentDuration = analyzedAssets.reduce(0.0) { duration, asset in
            guard let assetDuration = asset.metadata.duration, assetDuration.isFinite else { return duration }
            return duration + max(0, assetDuration)
        }

        var summary = ProjectSummary(
            projectID: manifest.id,
            name: manifest.name,
            assetCount: manifest.assets.count,
            updatedAt: manifest.updatedAt,
            previewKind: previewAsset?.kind,
            previewRelativePaths: relativePaths,
            analyzedContentDuration: analyzedContentDuration,
            analyzedAssetCount: analyzedAssets.count,
            statisticsVersion: ProjectSummary.currentStatisticsVersion
        )
        summary.hasPlayableTimeline = firstTimelinePair != nil
        summary.generationStatus = manifest.intentLedger?.entries.last(where: { $0.normalizedIntent == .createFilm })?.status
        let url = packageURL.appendingPathComponent(ProjectSummary.fileName)
        let data = try JSONEncoder.veloEdit.encode(summary)
        try data.write(to: url, options: .atomic)
        try ProjectOpeningPreview.write(for: manifest, at: packageURL)
    }
}

public extension JSONEncoder {
    static var veloEdit: JSONEncoder {
        let encoder = JSONEncoder()
        // Project manifests can contain millions of analysis/telemetry values.
        // Pretty printing inflated real projects by roughly 60% and made every
        // autosave parse and write tens of unnecessary megabytes.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    static var veloEdit: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
