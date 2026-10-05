import Foundation

/// Read-only presentation data. This must never become a ProjectStore manifest:
/// analysis, recovery checkpoints and editing state are deliberately omitted.
public struct ProjectOpeningPreview: Codable, Sendable {
    public static let fileName = "project-opening.json"
    public let projectID: UUID
    public let name: String
    public let assets: [MediaAsset]
    private var sourceStamp: SourceStamp?

    private struct SourceStamp: Codable, Equatable, Sendable {
        let size: Int
        let modified: Double

        init(url: URL) throws {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            size = values.fileSize ?? -1
            modified = values.contentModificationDate?.timeIntervalSince1970 ?? -1
        }
    }

    // Decode only the fields needed for the first screen of legacy packages.
    // Unknown analysis/telemetry fields are skipped without constructing their
    // millions of Swift values. New packages use the much smaller sidecar.
    private struct Header: Decodable {
        struct Order: Decodable {
            struct Entry: Decodable { let assetID: UUID; let order: Int }
            let entries: [Entry]
        }
        let id: UUID
        let name: String
        let projectVersion: Int
        let assets: [MediaAsset]
        let sourceMap: Order?
    }

    private init(id: UUID, name: String, assets: [MediaAsset], order: [UUID: Int]) {
        projectID = id
        self.name = name
        self.assets = Self.sortedMediaAssets(assets, order: order).map {
            var asset = $0
            asset.bookmarkData = nil
            return asset
        }
    }

    public static func sortedMediaAssets(_ assets: [MediaAsset], order: [UUID: Int]) -> [MediaAsset] {
        assets.filter { BackgroundPreset.preset(for: $0) == nil }.sorted {
            let lhs = order[$0.id] ?? Int.max
            let rhs = order[$1.id] ?? Int.max
            if lhs != rhs { return lhs < rhs }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    /// Called off MainActor, including when a recent-project card appears.
    /// The cache is disposable; malformed or stale sidecars fall back to the
    /// primary file, and an invalid primary never becomes an editable project.
    public static func load(from packageURL: URL) -> ProjectOpeningPreview? {
        let source = packageURL.appendingPathComponent("project.json")
        guard let stamp = try? SourceStamp(url: source) else { return nil }
        let cache = packageURL.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: cache),
           let preview = try? JSONDecoder.veloEdit.decode(Self.self, from: data),
           preview.sourceStamp == stamp { return preview }
        guard let data = try? Data(contentsOf: source, options: [.mappedIfSafe]),
              let header = try? JSONDecoder.veloEdit.decode(Header.self, from: data),
              header.projectVersion <= 1,
              (try? SourceStamp(url: source)) == stamp else { return nil }
        let order = Dictionary((header.sourceMap?.entries ?? []).map { ($0.assetID, $0.order) },
                               uniquingKeysWith: { first, _ in first })
        var preview = Self(id: header.id, name: header.name, assets: header.assets, order: order)
        preview.sourceStamp = stamp
        // No migration or project writes on the home screen. A normal save/open
        // creates the sidecar under the store's existing persistence ordering.
        return preview
    }

    static func write(for manifest: ProjectManifest, at packageURL: URL) throws {
        let order = Dictionary((manifest.sourceMap?.entries ?? []).map { ($0.assetID, $0.order) },
                               uniquingKeysWith: { first, _ in first })
        var preview = Self(id: manifest.id, name: manifest.name, assets: manifest.assets, order: order)
        preview.sourceStamp = try SourceStamp(url: packageURL.appendingPathComponent("project.json"))
        try JSONEncoder.veloEdit.encode(preview).write(
            to: packageURL.appendingPathComponent(fileName), options: .atomic)
    }
}
