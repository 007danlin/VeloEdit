import Foundation
import Darwin
import AVFoundation

public enum AutonomousJobState: String, Codable, Sendable {
    case queued, running, recovering, waitingForExternalResource, paused, cancelled, completed, failed
    public var resumesAutomatically: Bool { [.queued, .running, .recovering, .waitingForExternalResource].contains(self) }
}

public enum AutonomousJobStage: String, Codable, Sendable {
    case environment, importing, analysis, planning, assembly, verification, playback, committing, export
    public var title: String {
        switch self {
        case .environment, .importing, .analysis: return "Готовлю материалы"
        case .planning, .assembly: return "Собираю фильм"
        case .verification, .playback, .committing: return "Проверяю результат"
        case .export: return "Сохраняю видео"
        }
    }
}

public enum AutonomousFailureCause: String, Codable, Sendable {
    case transientNetwork, localService, mediaDecode, encoder, verification, revisionConflict
    case missingSource, missingMusic, insufficientContent, storage, cancelled, internalFailure

    public static func classify(_ error: Error) -> Self {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed: return .transientNetwork
            default: return .internalFailure
            }
        }
        if let error = error as? LocalAIModelError {
            switch error { case .serviceUnavailable: return .localService; default: return .internalFailure }
        }
        if let error = error as? ProjectStoreError {
            switch error {
            case .staleRevision, .externalModification: return .revisionConflict
            case .persistenceFailure: return .storage
            default: return .internalFailure
            }
        }
        if let error = error as? DerivedMediaError {
            switch error {
            case .soundtrackUnavailable: return .missingMusic
            case .noVideoTrack: return .mediaDecode
            case .cannotCreateDestination: return .storage
            case .exportFailed, .exportUnavailable: return .encoder
            }
        }
        if error is MediaImportError { return .missingSource }
        if error is EditorialGenerationError || error is DirectorBriefFulfillmentError { return .verification }
        let ns = error as NSError
        if ns.domain == AVFoundationErrorDomain { return .mediaDecode }
        if ns.domain == NSCocoaErrorDomain && [NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError, NSFileNoSuchFileError].contains(ns.code) { return .storage }
        return .internalFailure
    }
}

public struct AutonomousRecoveryAttempt: Codable, Sendable {
    public var cause: AutonomousFailureCause
    public var stage: AutonomousJobStage
    public var inputSignature: String
    public var strategy: String
    public var algorithmVersion: Int = 1
    public var date: Date = Date()
    public var diagnostic: String
}

/// The operational record belongs to ProjectStore. FilmBuildRecovery holds its
/// existing expensive draft; RenderJob holds the exported artifact and contract.
public struct AutonomousJob: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case film, export }
    public var id = UUID()
    public var schemaVersion = 1
    public var projectID: UUID
    public var kind: Kind
    public var baseRevision: UInt64
    public var inputSignature: String
    public var state: AutonomousJobState = .queued
    public var stage: AutonomousJobStage = .environment
    public var attempts: [AutonomousRecoveryAttempt] = []
    public var maximumRecoveries = 8
    public var maximumCompositionRepairs = 6
    public var compositionRepairSignatures: [String]?
    public var externalResource: String?
    public var externalFailureCause: AutonomousFailureCause?
    public var explicitCancellation = false
    public var updatedAt = Date()
    public var resultTimelineID: UUID?
    public var executor: String = "VeloEdit/\(ProcessInfo.processInfo.processIdentifier)"
}

public enum AutonomousOperationError: LocalizedError {
    case projectBusy, cancelled, verificationFailed(String)
    public var errorDescription: String? {
        switch self {
        case .projectBusy: return "В этом проекте уже выполняется задание."
        case .cancelled: return "Задание отменено."
        case .verificationFailed(let message): return message
        }
    }
}

/// Ownership lasts through awaits and is released by the OS after a crash.
/// A separate descriptor never interferes with ProjectStore's short CAS lock.
final class ProjectOperationLease: @unchecked Sendable {
    private let descriptor: Int32
    init(package: URL) throws {
        let path = package.appendingPathComponent(".operation.lock").path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ProjectStoreError.persistenceFailure(stage: "operation lock", path: path, underlying: String(cString: strerror(errno))) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw AutonomousOperationError.projectBusy
        }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

extension ProjectStore {
    func claimCompositionRepair(signature: String) throws -> Bool {
        guard let job = manifest.autonomousJob else { return true }
        let previous = job.compositionRepairSignatures ?? []
        guard previous.count < job.maximumCompositionRepairs, !previous.contains(signature) else { return false }
        try updateAutonomousJob { $0.compositionRepairSignatures = previous + [signature] }
        return true
    }

    public func activateAfterExternalWait() throws -> Bool {
        guard let job = manifest.autonomousJob, job.state == .waitingForExternalResource, !job.explicitCancellation else { return false }
        guard job.attempts.count < job.maximumRecoveries else {
            try updateAutonomousJob { $0.state = .failed }
            return false
        }
        try updateAutonomousJob {
            $0.attempts.append(AutonomousRecoveryAttempt(cause: $0.externalFailureCause ?? .internalFailure,
                stage: $0.stage, inputSignature: $0.inputSignature, strategy: "external-resource-returned", diagnostic: "External dependency became available"))
            $0.state = .queued
        }
        return true
    }
    func updateAutonomousJob(_ mutate: (inout AutonomousJob) -> Void) throws {
        try persistOperationalState { project in
            guard var job = project.autonomousJob else { return }
            mutate(&job)
            job.updatedAt = Date()
            project.autonomousJob = job
        }
    }

    func beginAutonomousJob(kind: AutonomousJob.Kind) throws -> AutonomousJob {
        if let existing = manifest.autonomousJob, existing.kind == kind,
           existing.state.resumesAutomatically, !existing.explicitCancellation {
            return existing
        }
        let job = AutonomousJob(projectID: manifest.id, kind: kind, baseRevision: snapshot().revision,
                                inputSignature: FilmBuildRecovery.signature(manifest))
        try persistOperationalState { $0.autonomousJob = job }
        return job
    }

    public func cancelAutonomousJob() throws {
        try updateAutonomousJob { job in
            guard job.state != .completed else { return }
            job.state = .cancelled
            job.explicitCancellation = true
        }
    }

    /// The same deterministic cause/input/strategy is never tried twice.
    /// Network recovery alone may retry twice with the specified 1s/3s delays.
    func reserveRecovery(error: Error, strategy: String) throws -> TimeInterval? {
        guard var job = manifest.autonomousJob, !job.explicitCancellation else { throw CancellationError() }
        let cause = AutonomousFailureCause.classify(error)
        if cause == .cancelled { try cancelAutonomousJob(); throw CancellationError() }
        let signature = FilmBuildRecovery.signature(manifest)
        let same = job.attempts.filter { $0.cause == cause && $0.inputSignature == signature && $0.strategy == strategy && $0.stage == job.stage }
        let transient = cause == .transientNetwork || cause == .localService
        guard job.attempts.count < job.maximumRecoveries, same.count < (transient ? 2 : 1) else { return nil }
        job.attempts.append(AutonomousRecoveryAttempt(cause: cause, stage: job.stage, inputSignature: signature,
                                                     strategy: strategy, diagnostic: error.localizedDescription))
        job.state = .recovering
        job.updatedAt = Date()
        try persistOperationalState { $0.autonomousJob = job }
        return transient ? (same.isEmpty ? 1 : 3) : 0
    }
}

enum AutonomousJobContext {
    @TaskLocal static var store: ProjectStore?
}

#if DEBUG
/// Available to tests through explicit injection, absent from release binaries.
enum AutonomyFaultInjection {
    @TaskLocal static var handler: (@Sendable (AutonomousJobStage, Int) throws -> Void)?
    static func check(_ stage: AutonomousJobStage, attempt: Int) throws { try handler?(stage, attempt) }
}
#endif
