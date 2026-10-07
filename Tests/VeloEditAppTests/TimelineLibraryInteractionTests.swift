import Foundation
import CoreGraphics
import Testing
import VeloEditCore
@testable import VeloEdit

struct TimelineLibraryInteractionTests {
    @Test func insertionPreviewChoosesBeforeBetweenAndAfterWithoutMovingItsHitTargets() {
        let geometry = TimelineInsertionGeometry(frames: [
            CGRect(x: 0, y: 0, width: 100, height: 76),
            CGRect(x: 108, y: 0, width: 200, height: 76),
            CGRect(x: 316, y: 0, width: 50, height: 76)
        ])
        #expect(geometry.insertionIndex(at: -10) == 0)
        #expect(geometry.insertionIndex(at: 105) == 1)
        #expect(geometry.insertionIndex(at: 220) == 2)
        #expect(geometry.insertionIndex(at: 500) == 3)
        #expect(geometry.boundaryX(at: 3, spacing: 8) == 374)
        #expect(geometry.offset(for: 0, insertingAt: 1, gap: 80) == 0)
        #expect(geometry.offset(for: 1, insertingAt: 1, gap: 80) == 80)
        #expect(geometry.offset(for: 2, insertingAt: 1, gap: 80) == 80)
        // Repeated hover in the open gap must keep choosing the same cut.
        for _ in 0..<20 { #expect(geometry.insertionIndex(at: 105) == 1) }
        #expect(geometry.transitionIndex(at: 1) == 1)
        #expect(geometry.transitionIndex(at: 310) == 2)
        #expect(TimelineInsertionGeometry(frames: []).insertionIndex(at: 0) == 0)
        #expect(TimelineInsertionGeometry(frames: []).transitionIndex(at: 0) == nil)
    }

    @Test func filmstripCellsPreserveAspectRatioAtEveryClipWidth() {
        for sourceCount in [1, 16] {
            for source in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)] {
                for width: CGFloat in [1, 24, 104, 140] {
                    let tile = CGRect(x: 100, y: 0, width: width, height: 58)
                    let imageSize = CGSize(width: source.width * CGFloat(sourceCount), height: source.height)
                    let drawn = FilmstripTileGeometry.imageRect(imageSize: imageSize,
                        sourceCount: sourceCount, sourceIndex: sourceCount - 1, tile: tile)
                    #expect(abs(drawn.width / imageSize.width - drawn.height / imageSize.height) < 0.00001)
                    let cellWidth = drawn.width / CGFloat(sourceCount)
                    let cell = CGRect(x: drawn.minX + CGFloat(sourceCount - 1) * cellWidth,
                                      y: drawn.minY, width: cellWidth, height: drawn.height)
                    #expect(cell.insetBy(dx: -0.001, dy: -0.001).contains(tile))
                }
            }
        }
    }

    @MainActor @Test func telemetryRenderingLeavesMainThreadAndCachesRepeatedCards() async throws {
        let cache = TelemetryPreviewCache { _ in
            #expect(!Thread.isMainThread)
            return CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        let request = TelemetryPreviewCache.Request(kind: .speedValue, presentation: .text,
            style: .acidTitanium, size: CGSize(width: 160, height: 76))
        let first = try #require(await cache.image(for: request))
        let second = try #require(await cache.image(for: request))
        #expect(first === second)
        let invalid = TelemetryPreviewCache.Request(kind: .speedValue, presentation: .text,
            style: .acidTitanium, size: CGSize(width: CGFloat.infinity, height: 1e12))
        #expect(invalid.width <= 512 && invalid.height <= 512)
        for size in [CGSize(width: 480, height: 152), CGSize(width: 900, height: 160), CGSize(width: 160, height: 900)] {
            let scaled = TelemetryPreviewCache.Request(kind: .verticalSpeed, presentation: .arc,
                style: .acidTitanium, size: size)
            #expect(abs(Double(scaled.width) / Double(scaled.height) - size.width / size.height) < 0.025)
            #expect(max(scaled.width, scaled.height) <= 512)
        }
    }
}
