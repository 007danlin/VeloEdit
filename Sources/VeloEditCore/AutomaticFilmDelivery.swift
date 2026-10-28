import Foundation

/// Delivery and fulfillment are distinct: every playable result is retained.
public struct FilmRequirementResult: Codable, Hashable, Sendable {
    public var sourcePhrase: String
    public var rule: String
    public var scope: String = "film"
    public var mandatory: Bool = true
    public var verificationMethod: String
    public var passed: Bool
    public var evidence: String
}

public struct FilmDeliveryReport: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case verified, savedWithUnmetRequirements }
    public var renderSignature: String
    public var warnings: [String]
    public var requestSignature: String? = nil
    public var requirements: [FilmRequirementResult]? = nil
    public var exportVerification: EditorialExportVerification? = nil
    public var chronology: EditorialChronologyReport? = nil
    public var timelineWidth: Int? = nil
    public var timelineHeight: Int? = nil
    public var status: Status {
        guard exportVerification?.artifactIsCurrent == true,
              let requirements, !requirements.isEmpty,
              requirements.filter(\.mandatory).allSatisfy(\.passed) else { return .savedWithUnmetRequirements }
        if requirements.contains(where: { $0.rule == "titleReadability" || $0.rule == "titleVisibility" }) {
            guard let evidence = exportVerification?.titleEvidence, !evidence.isEmpty,
                  evidence.allSatisfy({ $0.algorithmVersion == TitleReadabilityInspector.version
                      && $0.renderSignature == renderSignature && $0.source == "mp4" && $0.passed }) else {
                return .savedWithUnmetRequirements
            }
        }
        return .verified
    }
    public var completionMessage: String {
        status == .verified ? "Фильм создан и проверен" : "Фильм сохранён и доступен для просмотра"
    }
    public func isCurrent(for timeline: Timeline) -> Bool {
        AutomaticFilmDelivery.hasContent(timeline)
            && renderSignature == EditorialRenderSignature.signature(timeline)
            && (timelineWidth == nil || timelineWidth == timeline.width)
            && (timelineHeight == nil || timelineHeight == timeline.height)
    }
    public func isCurrent(for timeline: Timeline, plan: StoryPlan) -> Bool {
        isCurrent(for: timeline) && requestSignature == AutomaticFilmDelivery.requestSignature(plan)
    }
}

public enum AutomaticFilmDelivery {
    static func hasContent(_ timeline: Timeline) -> Bool {
        timeline.width > 0 && timeline.height > 0
            && timeline.frameRate.isFinite && timeline.frameRate > 0
            && timeline.duration.isFinite && timeline.duration > 0
            && timeline.items.contains {
                $0.overlay == nil && [.video, .photo].contains($0.kind)
                    && $0.assetID != nil && $0.timelineDuration.isFinite && $0.timelineDuration > 0
            }
    }

    /// Taste/semantic certainty cannot override these artifact checks.
    static func technicalFailures(timeline: Timeline) -> [String] {
        var failures: [String] = []
        let signature = EditorialRenderSignature.signature(timeline)
        guard hasContent(timeline), let review = timeline.editorialReview,
              review.editorialSignature == signature,
              let export = review.exportVerification, export.renderSignature == signature,
              export.artifactIsCurrent else { return ["нет проверенного актуального экспорта"] }
        if !export.aspectRatioMatches { failures.append("пропорции MP4 не совпадают с монтажом") }
        if export.probes.isEmpty || export.probes.contains(where: { !$0.decoded }) {
            failures.append("не удалось декодировать контрольные кадры MP4")
        } else if !export.probes.allSatisfy(\.passed) {
            failures.append("изображение MP4 отличается от превью")
        }
        if export.durationDifference > 1 / max(1, timeline.frameRate) + 0.001 {
            failures.append("длительность MP4 не совпадает с монтажом")
        }
        // A quiet artistic mix is not an invalid audio file. Keep the full
        // loudness finding as a recommendation; missing measurements/clipping
        // are technical failures.
        if review.evidenceDomains?.contains(where: { [.integratedLoudness, .truePeak].contains($0.domain) && $0.required }) == true {
            if export.encodedAudio?.measuredFrames ?? 0 <= 0 { failures.append("не проверена звуковая дорожка MP4") }
            if let peak = export.encodedAudio?.outputTruePeakDBTP {
                if !peak.isFinite || peak > 0 { failures.append("перегрузка звука в MP4") }
            } else { failures.append("нет измерения звуковых пиков MP4") }
        }
        let required: Set<EditorialEvidenceDomain> = [.renderDecode, .sourceAudioPolicy]
        for evidence in review.evidenceDomains ?? [] where required.contains(evidence.domain) && evidence.required && !evidence.isSufficient {
            failures.append(evidence.reason)
        }
        if review.evidenceDomains?.contains(where: { $0.domain == .renderDecode && $0.isSufficient }) != true {
            failures.append("нет подтверждения декодирования готового фильма")
        }
        return failures
    }

    /// A quality repair must not destroy the deliverable it is improving.
    static func preservesDelivery(_ repaired: Timeline, original: Timeline, plan: StoryPlan) -> Bool {
        guard hasContent(repaired) else { return false }
        let requirement = FilmDurationRequirement.parse(prompt: plan.prompt,
            explicitSeconds: plan.directorBrief?.explicitRequestedDuration,
            mode: plan.directorBrief?.durationMode)
        let before = AutomaticFilmDurationPolicy.renderedDuration(of: original)
        let after = AutomaticFilmDurationPolicy.renderedDuration(of: repaired)
        if requirement.accepts(duration: before, frameRate: original.frameRate),
           !requirement.accepts(duration: after, frameRate: repaired.frameRate) { return false }
        return !AutomaticFilmDurationPolicy.meetsMinimum(original) || AutomaticFilmDurationPolicy.meetsMinimum(repaired)
    }

    /// Call only after building and decoding the actual final playback.
    static func report(for timeline: Timeline, additionalWarnings: [String] = []) -> FilmDeliveryReport {
        var warnings = additionalWarnings
        for finding in timeline.editorialReview?.findings ?? [] where finding.severity >= 2 {
            warnings.append(warning(for: finding.kind))
        }
        if timeline.editorialReview?.candidateEligible == false && warnings.isEmpty {
            warnings.append("Часть проверок качества не завершена; ролик сохранён и доступен для редактирования.")
        }
        var seen = Set<String>()
        return FilmDeliveryReport(renderSignature: EditorialRenderSignature.signature(timeline),
            warnings: warnings.filter { seen.insert($0).inserted })
    }

    static func requestSignature(_ plan: StoryPlan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let brief = (try? encoder.encode(plan.directorBrief)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return EditorialIdentity.hash("request-v2-speech-intent|\(plan.preset.rawValue)|\(plan.prompt)|\(brief)|\(plan.explicitMusicTrackID?.uuidString ?? "")")
    }

    static func verifiedReport(for timeline: Timeline, plan: StoryPlan, assets: [MediaAsset], analyses: [AnalysisResult], additionalWarnings: [String] = []) -> FilmDeliveryReport {
        var report = report(for: timeline, additionalWarnings: additionalWarnings)
        report.requestSignature = requestSignature(plan)
        report.timelineWidth = timeline.width
        report.timelineHeight = timeline.height
        var checks: [FilmRequirementResult] = []
        func check(_ rule: String, _ method: String, _ passed: Bool, _ evidence: String, phrase: String? = nil, mandatory: Bool = true) {
            checks.append(.init(sourcePhrase: phrase ?? plan.prompt, rule: rule, mandatory: mandatory, verificationMethod: method, passed: passed, evidence: evidence))
        }
        let requirement = FilmDurationRequirement.parse(prompt: plan.prompt,
            explicitSeconds: plan.directorBrief?.explicitRequestedDuration ?? plan.contentBudget?.requestedDuration,
            mode: plan.directorBrief?.durationMode)
        let actual = AutomaticFilmDurationPolicy.renderedDuration(of: timeline)
        if requirement.mode != .automatic {
            check("duration", "Playback clock after transitions and retiming", requirement.accepts(duration: actual, frameRate: timeline.frameRate),
                  "Запрошено \(requirement.target ?? 0) с (\(requirement.mode.rawValue)); монтаж \(actual) с", phrase: requirement.sourcePhrase)
        }
        if let brief = plan.directorBrief, brief.canvasFormatIsAutomatic != true {
            check("format", "Timeline raster", timeline.width == brief.canvasFormat.width && timeline.height == brief.canvasFormat.height,
                  "\(timeline.width) × \(timeline.height)")
        }
        let excluded = Set(assets.filter(\.excluded).map(\.id))
        let used = Set(timeline.items.compactMap(\.assetID))
        let forbiddenCandidates = Set(analyses.flatMap(\.directorCandidates).filter { $0.excluded || !plan.constraints.excludeTags.isDisjoint(with: $0.tags) }.map(\.id))
        check("excludedMaterial", "Actual Timeline source and candidate IDs", used.isDisjoint(with: excluded) && Set(timeline.items.compactMap(\.candidateID)).isDisjoint(with: forbiddenCandidates),
              "Проверены \(used.count) исходников и \(timeline.items.count) фрагментов")
        let delivery = TimelineDeliveryContract().validateAndRepair(timeline: timeline, plan: plan, assets: assets, analyses: analyses)
        // Inspect the existing artifact; a hypothetical repair is not evidence.
        let mandatoryKinds: Set<TimelineDeliveryIssueKind> = [.canvasFormat, .musicPolicy, .titlePolicy, .forbiddenMusic, .forbiddenTitles, .originalAudioVolume, .exactDuration, .exactClipCount, .missingRequiredTag, .excludedTagPresent, .maximumTagShare, .preferredRoleTag]
        for issue in delivery.issues where mandatoryKinds.contains(issue.kind) {
            // A presentation refresh is not a failed title requirement. The
            // actual text and chapter coverage are checked independently.
            if issue.kind == .titlePolicy && issue.resolution == .repaired && EditorialPresentationPolicy.missingChapterTitles(in: timeline, plan: plan).isEmpty { continue }
            check("deliveryContract", "TimelineDeliveryContract on the delivered artifact", false, issue.message)
        }
        if let id = plan.explicitMusicTrackID ?? (plan.directorBrief?.musicPolicy == .specificTrack ? plan.directorBrief?.musicTrackID : nil) {
            let selected = Set([timeline.music?.trackID].compactMap { $0 } + (timeline.effectiveAdaptiveSoundtrack?.segments.compactMap(\.directive.trackID) ?? []))
            check("music", "Allocated soundtrack IDs", selected == [id], "Выбранный трек: \(id)")
        }
        if plan.directorBrief?.sourceAudioPolicy == .mute {
            let valid = IntentLedgerEngine.validate(.sourceAudio(.mute), timeline: timeline, previous: nil, analyses: analyses, assets: assets).0 == .fulfilled
            check("sourceAudio", "Final source audio allocation", valid, "Исходный звук отключён: \(valid)")
        }
        if DirectorRequestContract.requestsChapterTitles(plan.prompt) {
            let blocks = EditorialPresentationPolicy.chapterBlocks(in: timeline, plan: plan)
            let titled = blocks.allSatisfy { block in
                guard let start = block.items.first?.timelineStart else { return false }
                return timeline.effectiveTitleItems.contains { abs($0.startTime - start) <= 1 / timeline.frameRate && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.duration >= 1 }
            }
            check("chapterTitles", "Titles at actual chapter boundaries", !blocks.isEmpty && titled, "Проверено частей: \(blocks.count)")
            let unreadable = timeline.editorialReview?.findings.filter { $0.kind == .unreadableTitle && $0.severity >= 2 } ?? []
            let titleProof = timeline.editorialReview?.evidenceDomains?.first { $0.domain == .titleReadability }
            let titlesPassed = unreadable.isEmpty && titleProof?.isSufficient == true
                && timeline.editorialReview?.editorialSignature == EditorialRenderSignature.signature(timeline)
            check("titleVisibility", "Current per-title OCR in preview and independently decoded MP4", titlesPassed,
                  titlesPassed ? "Каждый титр проверен в предпросмотре и MP4" : "Читаемость всех обязательных точек титров не подтверждена")
        }
        let commands = EditorCommandParser().parse(plan.prompt, preset: plan.preset)
        let titleReset = commands.lastIndex { if case .removeTitles = $0 { return true }; return false }
        for command in commands.dropFirst(titleReset.map { $0 + 1 } ?? 0) {
            if case .addTitle(let text, _) = command {
                let present = timeline.effectiveTitleItems.contains { $0.enabled && $0.text == text && $0.duration > 0 && $0.startTime < timeline.duration }
                check("titleText", "Exact text on enabled Timeline titles", present, "Точный текст титра: «\(text)»")
            }
        }
        let chronology = EditorialChronologyReport.inspect(timeline: timeline, assets: assets)
        report.chronology = chronology
        check("sourceOrder", "Source-time mapping for every shot; embedded clock provenance, uncertainty retained",
              chronology.confirmedErrorCount == 0 && chronology.unresolvedCount == 0,
              "Подтверждённых нарушений: \(chronology.confirmedErrorCount); неопределённостей: \(chronology.unresolvedCount)")
        // Recheck the actual delivered ranges, independently of an earlier
        // quality report. Finishing or duration recovery must not cut bounds
        // which the existing moment policy protects during assembly. Missing
        // semantic bounds do not become invented completion evidence.
        let units = Dictionary(uniqueKeysWithValues: EditorialAnalysisContext(analyses: analyses).respectingSpeechIntent(plan).units.map { ($0.id, $0) })
        let protectedMoments = timeline.items.filter { OriginalMediaType.isVideo($0, assets: assets) }.compactMap { item -> (TimelineItem, EditorialSourceRange)? in
            guard let id = item.candidateID, let unit = units[id],
                  let range = EditorialMomentPolicy.protectedRange(unit) else { return nil }
            return (item, range)
        }
        let frameTolerance = 1 / max(1, timeline.frameRate)
        let interrupted = protectedMoments.filter { item, range in
            item.sourceStart > range.start + frameTolerance
                || item.sourceStart + item.sourceDuration < range.end - frameTolerance
        }
        check("actionCompletion", "Actual final source intervals against existing confirmed action, reaction and phrase boundaries",
              interrupted.isEmpty,
              "Подтверждённых защищённых интервалов: \(protectedMoments.count); обрезанных: \(interrupted.count). Отсутствующие семантические границы не считаются подтверждением завершения.")
        let exported = timeline.editorialReview?.exportVerification
        report.exportVerification = exported
        if let brief = plan.directorBrief, !brief.usesAutomaticCanvasFormat {
            check("exportRaster", "Encoded MP4 video track dimensions", exported?.encodedWidth == brief.canvasFormat.width && exported?.encodedHeight == brief.canvasFormat.height,
                  "Экспорт: \(exported?.encodedWidth ?? 0) × \(exported?.encodedHeight ?? 0); запрос: \(brief.canvasFormat.width) × \(brief.canvasFormat.height)")
        }
        let current = exported?.renderSignature == EditorialRenderSignature.signature(timeline)
        let videoDuration = exported?.videoDuration
        let exportPass = current && exported?.aspectRatioMatches == true && exported?.probes.isEmpty == false
            && exported?.probes.allSatisfy(\.passed) == true
            && (exported?.durationDifference ?? .infinity) <= 1 / timeline.frameRate + 0.001
            && (requirement.mode == .automatic || videoDuration.map { requirement.accepts(duration: $0, frameRate: timeline.frameRate) } == true)
        check("export", "Independent MP4 video track decode, raster, duration and preview parity", exportPass,
              videoDuration.map { "Видеоряд экспортированного файла: \($0) с" } ?? "Проверка экспортированного файла не завершена")
        if let content = timeline.selectedContentReview {
            let actions = content.source
            check("visualActionCuts", "Exact source cut with before/after visual context; continuous activity is distinguished from a finite action",
                actions.allSatisfy { $0.actionBoundary?.passes == true },
                "Визуальные границы действий: проверено \(actions.filter { $0.actionBoundary?.passes == true }.count) из \(actions.count). Это не проверка границ речи или доказательство прибытия.", mandatory: false)
            check("selectedContent", "Local vision model on five exact original samples and five final MP4 samples per shot",
                content.passes(timeline: timeline, assets: assets),
                "Проверка содержания: исходных участков \(content.source.count), итоговых \(content.rendered.count); неопределённых/непригодных \((content.source + content.rendered).filter { $0.status != .usable || $0.confidence < 0.75 }.count)")
        }
        report.requirements = checks
        report.warnings += checks.filter { !$0.passed }.map(\.evidence).filter { !report.warnings.contains($0) }
        return report
    }

    private static func warning(for kind: EditorialFindingKind) -> String {
        switch kind {
        case .sourceCoverageGap:
            return "Некоторые исходники с пригодными моментами целиком пропущены; причина требует редакционной проверки."
        case .sourceChronologyViolation:
            return "В последовательности кадров нарушена хронология исходников."
        case .unsafeReframe, .cropJump, .foregroundOcclusion, .dominantForegroundObject:
            return "В отдельных кадрах объект касается края или частично закрыт. После попытки исправления сохранён лучший доступный вариант."
        case .hardDuplicate, .shotFamilyRunTooLong, .dominantSetup:
            return "В ролике остались похожие планы."
        case .unreadableTitle, .chapterCoverageMismatch:
            return "Некоторые титры могут требовать правки."
        case .durationUnderflow, .durationPadding:
            return "Длительность отдельных планов или фильма отличается от рекомендованной."
        case .audioPolicyViolation, .audioLoudnessViolation, .audioPeakViolation, .musicNarrativeMismatch:
            return "В звуке или подборе музыки остались замечания."
        case .blankRenderedFrame, .renderedEvidenceUnavailable, .blockingEvidenceUnknown, .previewExportMismatch:
            return "Часть проверок изображения или экспорта требует внимания; готовый монтаж сохранён."
        default:
            return "В ритме или последовательности сцен остались замечания."
        }
    }
}
