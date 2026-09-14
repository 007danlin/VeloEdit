import Foundation

extension VeloEditPipeline {
    func recordExternalDependencyIfNeeded(_ error: Error) async -> Bool {
        let project = await store.manifest
        let missing = project.assets.filter { !FileManager.default.isReadableFile(atPath: $0.originalURL.path) }
        var cause = AutonomousFailureCause.classify(error)
        let message: String
        if !missing.isEmpty {
            cause = .missingSource
            message = "Подключите диск или предоставьте доступ к материалам: " + missing.prefix(3).map(\.displayName).joined(separator: ", ")
        } else if cause == .storage {
            message = "Освободите место или подключите диск для сохранения. Правки сохранены."
        } else if cause == .transientNetwork, project.autonomousJob?.stage == .environment {
            message = "Ожидаю подключения к интернету для завершения загрузки модели"
        } else if case LocalAIModelError.downloadApprovalRequired = error {
            cause = .localService
            message = "Разрешите первоначальную загрузку локальной модели"
        } else if let error = error as? DirectorBriefFulfillmentError,
                  case .unavailableMusicTrack = error {
            cause = .missingMusic
            message = "Нужен выбранный музыкальный файл. Выбор трека сохранён."
        } else if let request = project.filmBuildRecovery?.request,
                  let target = FilmDurationRequirement.parse(prompt: request.prompt, explicitSeconds: request.targetDuration ?? request.directorBrief?.explicitRequestedDuration).target,
                  target > project.assets.reduce(0, { $0 + ($1.kind == .photo ? PhotoPresentationPolicy.duration : ($1.metadata.duration ?? 0)) }) + 0.05 {
            cause = .insufficientContent
            message = "Черновик сохранён. Для фильма заданной длительности добавьте ещё материалы."
        } else { return false }
        do {
            try await store.updateAutonomousJob {
                $0.state = .waitingForExternalResource
                $0.externalFailureCause = cause
                $0.externalResource = message
            }
            return true
        } catch { return false }
    }

    public func externalDependenciesAvailable() async -> Bool {
        let project = await store.manifest
        guard project.autonomousJob?.state == .waitingForExternalResource else { return false }
        switch project.autonomousJob?.externalFailureCause {
        case .missingSource:
            _ = try? await recoverMissingSources()
            return await store.manifest.assets.allSatisfy { FileManager.default.isReadableFile(atPath: $0.originalURL.path) }
        case .missingMusic:
            guard let id = project.filmBuildRecovery?.request.preferredMusicTrackID ?? project.workspaceState?.directorBrief?.musicTrackID else { return false }
            return (try? await musicTracks().contains { $0.id == id && FileManager.default.isReadableFile(atPath: $0.localFileURL.path) }) == true
        case .insufficientContent:
            guard var recovery = project.filmBuildRecovery,
                  recovery.contentSignature != FilmBuildRecovery.signature(project),
                  let target = FilmDurationRequirement.parse(prompt: recovery.request.prompt, explicitSeconds: recovery.request.targetDuration ?? recovery.request.directorBrief?.explicitRequestedDuration).target,
                  project.assets.reduce(0, { $0 + ($1.kind == .photo ? PhotoPresentationPolicy.duration : ($1.metadata.duration ?? 0)) }) >= target else { return false }
            // Additional material makes the old assembly obsolete. Preserve the
            // exact request and start from the reusable analysis instead.
            recovery.draft = nil
            recovery.contentSignature = FilmBuildRecovery.signature(project)
            return (try? await store.persistFilmBuildRecovery(recovery)) != nil
        case .storage:
            let output = project.renderJobs.last?.outputURL ?? store.packageURL.appendingPathComponent("project.json")
            guard FileManager.default.isWritableFile(atPath: output.deletingLastPathComponent().path),
                  let timeline = project.timelines.last else { return false }
            return (ExportPreflight.availableCapacity(near: output) ?? 0) > ExportPreflight.estimatedOutputBytes(timeline: timeline, quality: project.renderJobs.last?.quality ?? .maximum, profile: .rec709)
        case .transientNetwork:
            var request = URLRequest(url: URL(string: "https://registry.ollama.ai/v2/")!)
            request.httpMethod = "HEAD"; request.timeoutInterval = 4
            guard let (_, response) = try? await URLSession.shared.data(for: request), let response = response as? HTTPURLResponse else { return false }
            return (200..<500).contains(response.statusCode)
        case .localService:
            let preferences = project.preferences
            let profile = AIAnalysisProfile.resolve(mode: preferences.effectiveAIPowerMode, advanced: preferences.effectiveAdvancedAISettings, thermalState: .nominal)
            return await LocalAIModelManager.shared.availability(model: profile.ollamaModelID).installed
        default: return false
        }
    }
}
