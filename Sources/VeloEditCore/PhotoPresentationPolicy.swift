import Foundation

enum PhotoPresentationPolicy {
    static let duration = 6.0
    static let zoomAmount = 0.05

    /// Only new automatic assemblies opt into this presentation. Exporting an
    /// existing edit must not replace a user's saved Fit or camera move.
    static func applying(to source: Timeline, plan: StoryPlan, assets: [MediaAsset], analyses: [AnalysisResult]) -> Timeline {
        guard DirectorEffectsPolicyEngine.policy(for: plan) != DirectorEffectsPolicy.none else { return source }
        var result = source
        let byAsset = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = Dictionary(analyses.flatMap(\.directorCandidates).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let targetAspect = Double(max(1, source.width)) / Double(max(1, source.height))
        for index in result.items.indices {
            let item = result.items[index]
            guard item.kind == .photo, item.overlay == nil, !item.locked, item.timelineDuration >= 2,
                  item.effect == nil || item.effect == ClipEffect.zoomIn.rawValue,
                  let asset = item.assetID.flatMap({ byAsset[$0] }),
                  let aspect = asset.displayAspectRatio, aspect > 0,
                  abs(log(aspect / targetAspect)) > 0.015 else { continue }
            var adjustments = item.effectiveVideoAdjustments
            // An existing evidenced framing path is already a deliberate
            // presentation choice. In particular, a static safe crop must not
            // be relabelled Ken Burns without actually moving the viewport.
            guard adjustments.subjectReframe == nil else { continue }
            let tracking = item.candidateID.flatMap({ candidates[$0]?.insights?.subjectTracking })
            if let tracking,
               let primary = tracking.tracks.first(where: { $0.id == tracking.mainSubjectID }) {
                let maximumZoom = 1 + zoomAmount * min(1, item.timelineDuration / 4)
                let viewportWidth = min(1, targetAspect / aspect) / maximumZoom
                let viewportHeight = min(1, aspect / targetAspect) / maximumZoom
                let fits = primary.observations.allSatisfy({
                    $0.region.width <= viewportWidth && $0.region.height <= viewportHeight
                })
                if !fits {
                    // A broad saliency box is not a detected person/group. A
                    // large generic sweep can cut an unrecognised person near
                    // its upper edge. Use a restrained zoom at its centre,
                    // with no pan and no moving Fit/blur seam. This is a crop
                    // hypothesis, not a claim that every object was detected.
                    let hasProtectedSubjects = tracking.tracks.contains {
                        [.face, .person, .cyclist, .animal].contains($0.kind)
                    }
                    guard primary.kind == .salientObject, !hasProtectedSubjects,
                          let framing = anchoredZoom(tracking: tracking, sourceAspect: aspect,
                            targetAspect: targetAspect, duration: item.timelineDuration) else { continue }
                    adjustments.subjectReframe = framing
                }
            }
            if let tracking,
               tracking.tracks.contains(where: { [.face, .person, .cyclist, .animal].contains($0.kind) }) {
                // A broad group that cannot fit the moving viewport retains
                // safe Fit. Do not use motion to hide an unsafe crop.
                guard let framing = SubjectAwareReframeEngine().plan(tracking: tracking,
                    sourceAspectRatio: aspect, targetAspectRatio: targetAspect, isPhoto: true),
                    framing.confidence >= 0.42 else { continue }
                let start = framing.interpolated(progress: 0)
                let end = framing.interpolated(progress: 1)
                guard abs(start.centerX - end.centerX) + abs(start.centerY - end.centerY)
                    + abs(start.scale - end.scale) > 0.001 else { continue }
                adjustments.subjectReframe = framing
            }
            adjustments.crop = .fill
            result.items[index].videoAdjustments = adjustments
            result.items[index].effect = ClipEffect.kenBurns.rawValue
            result.items[index].explanation.append("Фото другого формата: плавный Ken Burns по доступной области; значимые объекты проверяются при просмотре")
        }
        return result
    }

    static func anchoredZoom(tracking: SubjectTrackingSummary, sourceAspect: Double,
                             targetAspect: Double, duration: Double) -> SubjectReframePlan? {
        guard sourceAspect > 0, targetAspect > 0, duration >= 2,
              let primary = tracking.tracks.first(where: { $0.id == tracking.mainSubjectID }),
              !primary.observations.isEmpty, primary.meanConfidence >= 0.45 else { return nil }
        let regions = primary.observations.map(\.region)
        let halfWidth = min(1, targetAspect / sourceAspect) / 2
        let halfHeight = min(1, sourceAspect / targetAspect) / 2
        let x = min(1 - halfWidth, max(halfWidth, regions.map(\.centerX).reduce(0, +) / Double(regions.count)))
        let y = min(1 - halfHeight, max(halfHeight, regions.map(\.centerY).reduce(0, +) / Double(regions.count)))
        let scale = 1 + zoomAmount * min(1, duration / 4)
        var result = SubjectReframePlan(startCenterX: x, startCenterY: y,
            endCenterX: x, endCenterY: y, startScale: 1, endScale: scale,
            targetAspectRatio: targetAspect, confidence: primary.meanConfidence,
            reasons: ["Плавное приближение к центру области интереса без боковых полос; семантический объект не распознан, кадрирование требует просмотра"])
        result.keyframes = [.init(sourceTime: 0, centerX: x, centerY: y, scale: 1),
                           .init(sourceTime: duration, centerX: x, centerY: y, scale: scale)]
        return result
    }
}
