import Foundation
import CryptoKit

public struct EditorialProjectBackup: Codable, Sendable {
    public var projectID: UUID
    public var packageURL: URL
    public var backupURL: URL
    public var manifestSHA256: String
    public var mediaReferencesSHA256: String
    public var previousTimelineID: UUID?
    public var createdAt: Date
}

public struct EditorialFullPlaybackReview: Codable, Hashable, Sendable {
    public var timelineSignature: String
    public var reviewerID: String
    public var watchedWholeFilm: Bool
    public var watchedWithoutSound: Bool
    public var checkedTitlesInMotion: Bool
    public var checkedAudioByEar: Bool
    public var criticalOrHighTimecodes: [Double]
    public var reviewedAt: Date
}

/// Operational API only, with no project names or paths embedded in the engine.
/// Preparing a backup never opens the original through ProjectStore (opening
/// legacy packages may itself migrate and write their manifests).
public enum EditorialProjectMigration {
    public static func prepare(packageURL: URL, backupRoot: URL) throws -> EditorialProjectBackup {
        let original = try Data(contentsOf: packageURL.appendingPathComponent("project.json"))
        let manifest = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: original)
        guard manifest.projectVersion == 1 else { throw ProjectStoreError.unsupportedProjectVersion(manifest.projectVersion) }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = backupRoot.appendingPathComponent(stamp + "-" + UUID().uuidString + ".veloedit")
        try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: true)
        // Generated caches/exports can be regenerated; original media is never
        // copied or transcoded. Keep every persistent resource and history.
        for entry in try FileManager.default.contentsOfDirectory(at: packageURL, includingPropertiesForKeys: nil) where !["Cache", "Exports", "Logs", ".project.lock"].contains(entry.lastPathComponent) {
            try FileManager.default.copyItem(at: entry, to: backupURL.appendingPathComponent(entry.lastPathComponent))
        }
        let backupData = try Data(contentsOf: backupURL.appendingPathComponent("project.json"))
        let decoded = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: backupData)
        guard backupData == original, decoded.id == manifest.id else {
            throw EditorialGenerationError.unsatisfiedIntent("Backup не совпадает с исходным manifest")
        }
        let record = EditorialProjectBackup(projectID: manifest.id, packageURL: packageURL, backupURL: backupURL, manifestSHA256: hash(original), mediaReferencesSHA256: try mediaSignature(manifest), previousTimelineID: manifest.timelines.last?.id, createdAt: Date())
        try JSONEncoder.veloEdit.encode(record).write(to: backupURL.appendingPathComponent("editorial-backup.json"), options: .atomic)
        return record
    }

    /// A candidate can be activated only after independent verification AND an
    /// actual complete playback record tied to that exact render signature.
    /// Contact sheets and generated model ratings cannot supply this record.
    public static func activate(candidate: Timeline, plan: StoryPlan, analyses: [AnalysisResult], backup: EditorialProjectBackup, humanReview: EditorialFullPlaybackReview) throws {
        try activate(candidate: candidate, plan: plan, analyses: analyses, backup: backup, humanReview: humanReview as EditorialFullPlaybackReview?)
    }

    /// User-authorized activation based on the complete automated production
    /// verifier. This intentionally does not fabricate a human playback record.
    public static func activateAutomatically(candidate: Timeline, plan: StoryPlan, analyses: [AnalysisResult], backup: EditorialProjectBackup) throws {
        try activate(candidate: candidate, plan: plan, analyses: analyses, backup: backup, humanReview: nil)
    }

    private static func activate(candidate: Timeline, plan: StoryPlan, analyses: [AnalysisResult], backup: EditorialProjectBackup, humanReview: EditorialFullPlaybackReview?) throws {
        guard candidate.storyPlanID == plan.id, candidate.editorialReview?.productionEligible == true,
              candidate.editorialReview?.blockingUnknowns.isEmpty == true,
              candidate.editorialReview?.editorialSignature == EditorialRenderSignature.signature(candidate) else {
            throw EditorialGenerationError.unsatisfiedIntent("Активация запрещена: автоматический production Verifier не подтвердил этот Timeline")
        }
        if let humanReview {
            guard
              humanReview.timelineSignature == EditorialRenderSignature.signature(candidate),
              !humanReview.reviewerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              humanReview.watchedWholeFilm, humanReview.watchedWithoutSound, humanReview.checkedTitlesInMotion,
              humanReview.criticalOrHighTimecodes.isEmpty else {
                throw EditorialGenerationError.unsatisfiedIntent("Активация запрещена: human review не относится к точной render signature")
            }
            let expectsAudio = candidate.music?.trackID != nil || !candidate.effectiveAudioClips.isEmpty || candidate.effectiveOriginalAudioVolume > 0
            guard !expectsAudio || humanReview.checkedAudioByEar else {
                throw EditorialGenerationError.unsatisfiedIntent("Не выполнена проверка звука на слух")
            }
        }
        let preserved = try Data(contentsOf: backup.backupURL.appendingPathComponent("project.json"))
        guard hash(preserved) == backup.manifestSHA256 else { throw EditorialGenerationError.unsatisfiedIntent("Backup повреждён или изменён") }
        let manifestURL = backup.packageURL.appendingPathComponent("project.json")
        try ProjectStore.withManifestLock(for: manifestURL) {
                let data = try Data(contentsOf: manifestURL)
                guard hash(data) == backup.manifestSHA256 else {
                    throw EditorialGenerationError.unsatisfiedIntent("Проект изменился после backup; устаревшая генерация не записана")
                }
                var project = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: data)
                guard project.id == backup.projectID, try mediaSignature(project) == backup.mediaReferencesSHA256,
                      !project.timelines.contains(where: { $0.id == candidate.id }) else {
                    throw EditorialGenerationError.unsatisfiedIntent("Изменились media references или версия уже активирована")
                }
                var timeline = candidate
                timeline.versionName = "Editorial V2 — " + ISO8601DateFormatter().string(from: Date())
                timeline.editorialRegeneration = .init(previousTimelineID: backup.previousTimelineID, evidenceVersion: EditorialEvidenceVerifier.version, reason: humanReview == nil ? "Production activation after complete automated rendered verification" : "Production calibration after independent rendered and full playback review", backupManifestSHA256: backup.manifestSHA256, humanReview: humanReview, activationMethod: humanReview == nil ? "automated-rendered-verifier" : "human-and-automated")
                if let old = project.timelines.last {
                    var checkpoints = project.timelineCheckpoints ?? []
                    checkpoints.append(.init(name: "До Editorial V2", reason: "Версия до проверенной пересборки", timeline: old))
                    project.timelineCheckpoints = checkpoints
                }
                // Revalidate the existing ledger against the actual candidate.
                if var ledger = project.intentLedger {
                    for i in ledger.entries.indices where [.pending, .running, .recoverableFailure].contains(ledger.entries[i].status) {
                        let verdict = IntentLedgerEngine.validate(ledger.entries[i].normalizedIntent, timeline: timeline, previous: project.timelines.last, analyses: analyses, assets: project.assets)
                        guard [.fulfilled, .rejected].contains(verdict.0) else { throw EditorialGenerationError.unsatisfiedIntent(verdict.2 ?? "Pending intent") }
                        ledger.entries[i].status = verdict.0
                        ledger.entries[i].evidence = verdict.1
                        ledger.entries[i].failureReason = verdict.2
                    }
                    project.intentLedger = ledger
                }
                if !project.storyPlans.contains(where: { $0.id == plan.id }) { project.storyPlans.append(plan) }
                project.analyses = analyses
                project.timelines.append(timeline)
                project.editorialDevelopmentEnabled = true
                project.updatedAt = Date()
                guard try mediaSignature(project) == backup.mediaReferencesSHA256 else { throw EditorialGenerationError.unsatisfiedIntent("Изменение media references запрещено") }
                try JSONEncoder.veloEdit.encode(project).write(to: manifestURL, options: .atomic)
        }
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func mediaSignature(_ project: ProjectManifest) throws -> String {
        struct Reference: Codable { var id: UUID; var url: URL; var contentHash: String }
        let references = project.assets.sorted { $0.id.uuidString < $1.id.uuidString }.map { Reference(id: $0.id, url: $0.originalURL, contentHash: $0.contentHash) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return hash(try encoder.encode(references))
    }
}

public struct EditorialRegenerationRecord: Codable, Hashable, Sendable {
    public var previousTimelineID: UUID?
    public var evidenceVersion: Int
    public var reason: String
    public var backupManifestSHA256: String
    public var humanReview: EditorialFullPlaybackReview?
    public var activationMethod: String? = nil
}
