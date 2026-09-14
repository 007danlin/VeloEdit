import Foundation

public struct FilmBuildRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case create, regenerate }
    public var kind: Kind
    public var prompt: String
    public var preset: FilmPreset?
    public var targetDuration: Double?
    public var preferredMusicTrackID: UUID?
    public var directorBrief: DirectorBrief?
    public var avoidingTimeline: Timeline?
    public var selectedCandidateID: UUID?
    public var ignoredFeedbackConstraints: Int = 0
}

public struct FilmBuildDraft: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case finishing, verifying }
    public var phase: Phase
    public var timeline: Timeline
    public var plan: StoryPlan
    public var analyses: [AnalysisResult]
    public var tracks: [LocalMusicTrack]
    public var sourceMap: SourceMap
    public var events: [Event]
    public var personalTaste: PersonalTasteProfile
    public var resolvedMusicTrackID: UUID?
    public var directorBrief: DirectorBrief?
    public var checkpointReason: String
}

public struct FilmBuildRecovery: Codable, Sendable {
    public static let currentAlgorithmVersion = 2
    public var algorithmVersion: Int? = Self.currentAlgorithmVersion
    public var request: FilmBuildRequest
    public var contentSignature: String
    public var draft: FilmBuildDraft?
    public var savedAt: Date = Date()

    public var stageTitle: String {
        switch draft?.phase {
        case .finishing: return "Доработка выбранного монтажа"
        case .verifying: return "Проверка готового фильма и звука"
        case nil: return "Сборка фильма с сохранённым анализом"
        }
    }

    /// A durable content revision avoids hashing encoded Sets/dictionaries,
    /// whose JSON iteration order can change across application launches.
    static func signature(_ project: ProjectManifest) -> String {
        "film-build-v1:" + (project.filmBuildContentRevision ?? project.id).uuidString
    }

    static func inputsEqual(_ lhs: ProjectManifest, _ rhs: ProjectManifest) -> Bool {
        lhs.id == rhs.id && lhs.assets == rhs.assets && lhs.analyses == rhs.analyses
            && lhs.timelines == rhs.timelines && lhs.storyPlans == rhs.storyPlans
            && lhs.effectiveTelemetrySources == rhs.effectiveTelemetrySources
            && lhs.preferences == rhs.preferences
            && lhs.sourceMap == rhs.sourceMap && lhs.events == rhs.events
            && lhs.workspaceState?.prompt == rhs.workspaceState?.prompt
            && lhs.workspaceState?.preset == rhs.workspaceState?.preset
            && lhs.workspaceState?.targetMinutes == rhs.workspaceState?.targetMinutes
            && lhs.workspaceState?.directorMusicTrackID == rhs.workspaceState?.directorMusicTrackID
            && lhs.workspaceState?.directorBrief == rhs.workspaceState?.directorBrief
            && lhs.workspaceState?.pendingDirectorInstructions == rhs.workspaceState?.pendingDirectorInstructions
    }
}

extension ProjectStore {
    func rebindRecoveredMediaInputs() throws {
        guard var recovery = manifest.filmBuildRecovery else { return }
        recovery.contentSignature = FilmBuildRecovery.signature(manifest)
        try persistFilmBuildRecovery(recovery)
    }
    public func recoverableFilmBuild() -> FilmBuildRecovery? {
        guard let recovery = manifest.filmBuildRecovery,
              recovery.contentSignature == FilmBuildRecovery.signature(manifest) else { return nil }
        return recovery
    }

    /// Checkpoint updates do not invalidate the work whose inputs they preserve.
    func beginFilmBuildRecovery(_ request: FilmBuildRequest) throws -> FilmBuildDraft? {
        if let saved = recoverableFilmBuild(), saved.request == request,
           saved.algorithmVersion == FilmBuildRecovery.currentAlgorithmVersion { return saved.draft }
        let recovery = FilmBuildRecovery(request: request, contentSignature: FilmBuildRecovery.signature(manifest))
        try persistFilmBuildRecovery(recovery)
        return nil
    }

    func checkpointFilmBuild(_ draft: FilmBuildDraft, ifRevision expectedRevision: UInt64) throws {
        let current = snapshot()
        guard current.revision == expectedRevision else {
            throw ProjectStoreError.staleRevision(expected: expectedRevision, actual: current.revision)
        }
        guard var recovery = manifest.filmBuildRecovery else { return }
        recovery.contentSignature = FilmBuildRecovery.signature(manifest)
        recovery.draft = draft
        recovery.savedAt = Date()
        try persistFilmBuildRecovery(recovery)
    }
}
