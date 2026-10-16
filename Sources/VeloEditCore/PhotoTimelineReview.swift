import Foundation
import CoreGraphics

/// Presentation-only checks reuse source labels/subjects. No action boundary,
/// gesture, camera-tail, or per-frame semantic model requests apply to a still.
enum PhotoTimelineReview {
    static func review(_ source: Timeline, assets: [MediaAsset], repairFraming: Bool,
                       progress: FilmBuildProgressHandler?) async throws -> (timeline: Timeline, warnings: [String]) {
        var timeline = source
        var warnings: [String] = []
        let indices = timeline.items.indices.filter { timeline.items[$0].overlay == nil && OriginalMediaType.isPhoto(timeline.items[$0], assets: assets) }
        for (number, index) in indices.enumerated() {
            try Task.checkCancellation()
            let item = timeline.items[index]
            guard let asset = assets.first(where: { $0.id == item.assetID }) else { continue }
            await progress?(FilmBuildProgress(.verifying, completed: number, total: indices.count,
                detail: "Проверяю кадрирование фото \(number + 1) из \(indices.count)"))
            let photo: PhotoSourceAnalysis
            do { photo = try await PhotoSourceAnalysis.inspect(asset) }
            catch { throw AutonomousOperationError.verificationFailed("Не удалось прочитать фото «\(asset.displayName)»: \(error.localizedDescription)") }
            let assessment = inspect(item: item, photo: photo, canvas: CGSize(width: source.width, height: source.height))
            if assessment.cropsSubject {
                if repairFraming && !item.locked {
                    var adjustments = item.effectiveVideoAdjustments
                    adjustments.crop = .fit
                    adjustments.subjectReframe = nil
                    timeline.items[index].videoAdjustments = adjustments
                    timeline.items[index].effect = nil
                    timeline.items[index].explanation.append("Сохранён полный кадр: движение обрезало значимый объект фото")
                } else { warnings.append("\(asset.displayName): проверьте сохранность объекта при кадрировании") }
            }
            if assessment.upscales { warnings.append("\(asset.displayName): разрешение после кадрирования ниже размера фильма") }
            if photo.sample.detail < 0.15 || photo.sample.exposure < 0.2 {
                warnings.append("\(asset.displayName): мягкий или тёмный снимок сохранён; оцените художественный замысел")
            }
            if item.timelineDuration < PhotoPresentationPolicy.duration - 0.05 {
                warnings.append("\(asset.displayName): показ короче рекомендуемых 6 секунд")
            }
            for title in timeline.effectiveTitleItems where title.enabled && title.startTime < item.timelineStart + item.timelineDuration && title.startTime + title.duration > item.timelineStart {
                if title.duration < max(2, Double(title.text.count) / 15) {
                    warnings.append("Титр «\(title.text)»: мало времени для чтения; дополнительно выполняется проверка готового видео")
                }
            }
        }
        if !indices.isEmpty { await progress?(FilmBuildProgress(.verifying, completed: indices.count, total: indices.count, detail: "Кадрирование и длительность показа фото проверены")) }
        return (timeline, Array(Set(warnings)).sorted())
    }

    static func inspect(item: TimelineItem, photo: PhotoSourceAnalysis, canvas: CGSize) -> (cropsSubject: Bool, upscales: Bool) {
        let adjustments = item.effectiveVideoAdjustments
        let source = CGSize(width: photo.width, height: photo.height)
        let subjects = (photo.sample.subjects ?? []).filter { $0.confidence >= 0.5 }
        let full = adjustments.crop == .fit && adjustments.subjectReframe == nil
        var fractions = Set([0.0, 1.0])
        if item.effect != nil || adjustments.subjectReframe != nil { fractions.insert(0.5) }
        if let keys = adjustments.subjectReframe?.keyframes, let first = keys.first, let last = keys.last, last.sourceTime > first.sourceTime {
            for key in keys { fractions.insert((key.sourceTime - first.sourceTime) / (last.sourceTime - first.sourceTime)) }
            for (a, b) in zip(keys, keys.dropFirst()) { fractions.insert(((a.sourceTime + b.sourceTime) / 2 - first.sourceTime) / (last.sourceTime - first.sourceTime)) }
        }
        var cropped = false, upscales = false
        for fraction in fractions.sorted() {
            let move = StillImageRenderGeometry.motion(item.effect.flatMap(ClipEffect.init(rawValue:)) ?? .zoomIn, source: source,
                target: canvas, progress: fraction, duration: item.timelineDuration, subjectReframe: adjustments.subjectReframe)
            let placement = StillImageRenderGeometry.placement(sourceExtent: CGRect(origin: .zero, size: source), targetSize: canvas,
                motionScale: full ? 1 : move.scale, horizontalTravel: full ? 0 : move.x, verticalTravel: full ? 0 : move.y,
                subjectReframe: adjustments.subjectReframe, progress: fraction, fill: !full)
            upscales = upscales || placement.scale > 1.01
            for subject in subjects {
                let r = subject.region
                let rect = CGRect(x: r.x * source.width * placement.scale + placement.x,
                    y: r.y * source.height * placement.scale + placement.y,
                    width: r.width * source.width * placement.scale, height: r.height * source.height * placement.scale)
                let visible = rect.intersection(CGRect(origin: .zero, size: canvas))
                let coverage = visible.isNull ? 0 : visible.width * visible.height / max(1, rect.width * rect.height)
                cropped = cropped || coverage < 0.95
            }
        }
        return (cropped, upscales)
    }
}
