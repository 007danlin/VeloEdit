import Foundation

public struct EditorialChronologySegment: Codable, Hashable, Sendable {
    public var itemID: UUID
    public var assetID: UUID?
    public var sourceURL: URL?
    public var timelineStart: Double
    public var timelineDuration: Double
    public var sourceStart: Double
    public var sourceEnd: Double
    public var captureStart: Date?
    public var captureEnd: Date?
    public var dateSource: MediaDateSource?
    public var confidence: Double
    public var fallbackOrder: Int?
    public var isOverlay: Bool
}

public struct EditorialChronologyFinding: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case sourceTimeReversal, captureTimeReversal, inferredOrderConflict, unknownCaptureTime, cameraClockAmbiguity, reversedPlayback
    }
    public var kind: Kind
    public var itemIDs: [UUID]
    public var confirmed: Bool
    public var reason: String
}

/// A source-time audit, separate from the engine's artistic/global score.
/// No file copy/mtime is capture evidence; no camera-clock offset is guessed.
public struct EditorialChronologyReport: Codable, Hashable, Sendable {
    public var version: Int = 1
    public var segments: [EditorialChronologySegment]
    public var findings: [EditorialChronologyFinding]
    public var confirmedErrorCount: Int { findings.filter(\.confirmed).count }
    public var unresolvedCount: Int { findings.filter { !$0.confirmed }.count }

    public static func inspect(timeline: Timeline, assets: [MediaAsset], sourceMap: SourceMap? = nil) -> Self {
        let byID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let map = sourceMap ?? SourceTimelineAnalyzer().analyze(assets: assets, analyses: [])
        let ranks = Dictionary(map.entries.map { ($0.assetID, $0.order) }, uniquingKeysWith: { first, _ in first })
        let tolerance = 1 / max(1, timeline.frameRate) + 0.001
        let items = timeline.items.filter { $0.kind != .title }.sorted {
            $0.timelineStart == $1.timelineStart ? $0.id.uuidString < $1.id.uuidString : $0.timelineStart < $1.timelineStart
        }
        var segments: [EditorialChronologySegment] = []
        var findings: [EditorialChronologyFinding] = []
        var lastBySource: [UUID: EditorialChronologySegment] = [:]
        var previous: EditorialChronologySegment?
        for item in items {
            let asset = item.assetID.flatMap { byID[$0] }
            let metadata = asset.map { MediaCaptureClock.metadata(for: $0) }
            let naivePhotoClock = asset?.kind == .photo && metadata?.timeZoneIdentifier == nil
            let reliable = !naivePhotoClock && metadata?.dateSource == .embeddedMetadata && (metadata?.dateConfidence ?? 0.98) >= 0.9
            let capture = reliable ? metadata?.creationDate : nil
            let segment = EditorialChronologySegment(itemID: item.id, assetID: item.assetID,
                sourceURL: asset?.originalURL, timelineStart: item.timelineStart, timelineDuration: item.timelineDuration,
                sourceStart: item.sourceStart, sourceEnd: item.sourceStart + item.sourceDuration,
                captureStart: capture?.addingTimeInterval(item.sourceStart),
                captureEnd: capture?.addingTimeInterval(item.sourceStart + item.sourceDuration),
                dateSource: metadata?.dateSource, confidence: reliable ? metadata?.dateConfidence ?? 0.98 : 0,
                fallbackOrder: item.assetID.flatMap { ranks[$0] }, isOverlay: item.overlay != nil)
            segments.append(segment)
            guard item.overlay == nil else { continue }
            if capture == nil {
                findings.append(.init(kind: .unknownCaptureTime, itemIDs: [item.id], confirmed: false,
                    reason: "Время съёмки не подтверждено; порядок файлов — только обоснованное предположение. Даты копирования/изменения не использованы."))
            }
            if item.isReversed && item.kind == .video {
                findings.append(.init(kind: .reversedPlayback, itemIDs: [item.id], confirmed: true,
                    reason: "Видеофрагмент воспроизводится в обратном времени."))
            }
            if let id = item.assetID {
                if let prior = lastBySource[id], item.kind == .video, item.sourceStart + tolerance < prior.sourceStart {
                    findings.append(.init(kind: .sourceTimeReversal, itemIDs: [prior.itemID, item.id], confirmed: true,
                        reason: "Возврат назад внутри исходника, в том числе через промежуточный другой ракурс."))
                }
                lastBySource[id] = segment
            }
            if let prior = previous, prior.assetID != segment.assetID {
                let oldAsset = prior.assetID.flatMap { byID[$0] }
                // Known different cameras cannot be declared synchronized from
                // their clock values alone. Keep the discrepancy visible.
                let differentCamera = oldAsset?.metadata.cameraModel != asset?.metadata.cameraModel
                    || oldAsset?.metadata.cameraMake != asset?.metadata.cameraMake
                if let a = prior.captureStart, let b = segment.captureStart, b.timeIntervalSince(a) < -tolerance {
                    findings.append(.init(kind: differentCamera ? .cameraClockAmbiguity : .captureTimeReversal,
                        itemIDs: [prior.itemID, item.id], confirmed: !differentCamera,
                        reason: differentCamera ? "Часы разных камер не синхронизированы; смещение автоматически не исправлялось."
                            : "Время кадра по встроенным метаданным движется назад; источник + sourceStart."))
                } else if (prior.captureStart == nil || segment.captureStart == nil),
                          let a = prior.fallbackOrder, let b = segment.fallbackOrder, b < a {
                    findings.append(.init(kind: .inferredOrderConflict, itemIDs: [prior.itemID, item.id], confirmed: false,
                        reason: "Конфликт предполагаемого порядка файлов; точное время съёмки неизвестно."))
                }
            }
            previous = segment
        }
        return Self(segments: segments, findings: findings)
    }
}
