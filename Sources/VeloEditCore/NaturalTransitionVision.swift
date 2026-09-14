import AVFoundation
import CoreGraphics
import Foundation

/// Small, oriented source frames, sampled at the actual edit, not a scene's
/// average embedding. Keeping pixels makes shape and motion independently
/// measurable; labels, filenames and a shared colour never prove a match.
struct NaturalTransitionFrame: Sendable {
    static let width = 64
    static let height = 36
    var time: Double
    var rgb: [Double]
    var aspectRatio: Double

    var valid: Bool {
        time.isFinite && aspectRatio.isFinite && aspectRatio > 0
            && rgb.count == Self.width * Self.height * 3
            && rgb.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    var luma: [Double] {
        var result: [Double] = []
        for i in stride(from: 0, to: rgb.count, by: 3) {
            let red = rgb[i] * 0.2126
            let green = rgb[i + 1] * 0.7152
            let blue = rgb[i + 2] * 0.0722
            result.append(red + green + blue)
        }
        return result
    }
    var meanColor: [Double] {
        var sums = [Double](repeating: 0, count: 3)
        for i in rgb.indices { sums[i % 3] += rgb[i] }
        return sums.map { $0 / Double(Self.width * Self.height) }
    }
    static func make(_ image: CGImage, time: Double) -> Self? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var rgb: [Double] = []
        rgb.reserveCapacity(width * height * 3)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            rgb.append(contentsOf: [Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255])
        }
        return Self(time: time, rgb: rgb, aspectRatio: Double(image.width) / Double(image.height))
    }
}

protocol NaturalTransitionFrameProbing: Sendable {
    func frames(asset: MediaAsset, times: [Double], frameRate: Double) async throws -> [NaturalTransitionFrame]
}

struct LocalNaturalTransitionFrameProber: NaturalTransitionFrameProbing {
    func frames(asset: MediaAsset, times: [Double], frameRate: Double) async throws -> [NaturalTransitionFrame] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: asset.originalURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        let tolerance = 0.5 / max(1, frameRate)
        generator.requestedTimeToleranceBefore = CMTime(seconds: tolerance, preferredTimescale: 60000)
        generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
        defer { generator.cancelAllCGImageGeneration() }
        var frames: [NaturalTransitionFrame] = []
        var pacer = ResourceWorkPacer()
        for time in times.sorted() {
            try Task.checkCancellation()
            try await pacer.checkpoint()
            // The async decoder releases the cooperative executor while seeking.
            let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000))
            guard abs(result.actualTime.seconds - time) <= tolerance + 0.001,
                  let frame = NaturalTransitionFrame.make(result.image, time: time) else { continue }
            frames.append(frame)
        }
        return frames
    }
}

struct NaturalTransitionMatch: Sendable {
    var kind: NaturalChapterTransitionKind
    var confidence: Double
    var reason: String
}

enum NaturalTransitionVision {
    struct Motion {
        var x: Double = 0
        var y: Double = 0
        var reliability: Double = 0
        var speed: Double { hypot(x, y) }
    }

    static func match(tail: [NaturalTransitionFrame], head: [NaturalTransitionFrame]) -> NaturalTransitionMatch? {
        guard tail.count == 4, head.count == 4, (tail + head).allSatisfy(\.valid),
              increasing(tail), increasing(head), let a = tail.last, let b = head.first,
              abs(a.aspectRatio / b.aspectRatio - 1) < 0.03 else { return nil }
        let colourDistance = distance(a.meanColor, b.meanColor)
        if colourDistance < 0.075, coveredReveal(tail: tail, head: head) {
            return .init(kind: .occlusion, confidence: 0.94,
                reason: "Склейка скрыта настоящим перекрытием: кадр закрывается перед границей и открывается после неё")
        }
        let shape = shapeSimilarity(a.luma, b.luma)
        let left = motion(tail), right = motion(head)
        let direction = (left.x * right.x + left.y * right.y) / max(0.0001, left.speed * right.speed)
        let speedRatio = min(left.speed, right.speed) / max(0.0001, max(left.speed, right.speed))
        if min(left.reliability, right.reliability) >= 0.67,
           min(left.speed, right.speed) >= 0.045, direction >= 0.94, speedRatio >= 0.65,
           colourDistance < 0.14, shape >= 0.70 {
            let fast = min(left.speed, right.speed) > 0.28
            return .init(kind: fast ? .dynamicMotion : .motion, confidence: min(0.96, 0.82 + (shape - 0.7) * 0.4),
                reason: fast ? "Быстрое движение продолжается через склейку с согласованными направлением, скоростью и композицией"
                    : "Движение камеры или объекта продолжается через склейку в том же направлении и темпе")
        }
        // Require a recognisable spatial structure on both sides, stable over
        // time. Uniform sky, darkness, a shared palette and random texture fail.
        if shape >= 0.94, colourDistance < 0.10,
           min(detail(a.luma), detail(b.luma)) >= 0.025,
           max(left.speed, right.speed) < 0.045,
           tail.allSatisfy({ shapeSimilarity($0.luma, a.luma) >= 0.9 }),
           head.allSatisfy({ shapeSimilarity($0.luma, b.luma) >= 0.9 }) {
            return .init(kind: .composition, confidence: min(0.96, 0.86 + (shape - 0.94)),
                reason: "Match cut: подтверждено совпадение формы и расположения деталей в нескольких кадрах по обе стороны склейки")
        }
        return nil
    }

    private static func increasing(_ frames: [NaturalTransitionFrame]) -> Bool {
        zip(frames, frames.dropFirst()).allSatisfy { $1.time - $0.time >= 0.04 && $1.time - $0.time <= 0.16 }
    }
    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        return zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
    }
    static func isCovered(_ frame: NaturalTransitionFrame) -> Bool {
        guard frame.valid else { return false }
        let color = frame.meanColor
        let covered = stride(from: 0, to: frame.rgb.count, by: 3).filter { i in
            distance(Array(frame.rgb[i..<(i + 3)]), color) < 0.10
        }.count
        return Double(covered) / Double(frame.rgb.count / 3) >= 0.95
    }
    static func detail(_ pixels: [Double]) -> Double {
        let w = NaturalTransitionFrame.width
        guard pixels.count == w * NaturalTransitionFrame.height else { return 0 }
        var sum = 0.0
        for y in 1..<(NaturalTransitionFrame.height - 1) {
            for x in 1..<(w - 1) { sum += abs(pixels[y * w + x] - pixels[y * w + x - 1]) + abs(pixels[y * w + x] - pixels[(y - 1) * w + x]) }
        }
        return sum / Double(pixels.count * 2)
    }
    static func shapeSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let am = a.reduce(0, +) / Double(a.count), bm = b.reduce(0, +) / Double(b.count)
        var dot = 0.0, aa = 0.0, bb = 0.0
        for i in a.indices { let x = a[i] - am, y = b[i] - bm; dot += x * y; aa += x * x; bb += y * y }
        guard min(aa, bb) / Double(a.count) > 0.006 else { return 0 }
        return max(0, dot / max(0.00001, sqrt(aa * bb)))
    }

    private static func coveredReveal(tail: [NaturalTransitionFrame], head: [NaturalTransitionFrame]) -> Bool {
        let a = tail[3], b = head[0]
        // Overexposure/flash is not evidence of a physical lens cover.
        guard a.luma.reduce(0, +) / Double(a.luma.count) < 0.82,
              min(detail(tail[0].luma), detail(head[3].luma)) > 0.025 else { return false }
        let color = zip(a.meanColor, b.meanColor).map { ($0 + $1) / 2 }
        func coverage(_ f: NaturalTransitionFrame) -> Double {
            var count = 0
            for y in 0..<9 {
                for x in 0..<16 {
                    var pixels: [[Double]] = []
                    for dy in 0..<4 { for dx in 0..<4 {
                        let i = ((y * 4 + dy) * 64 + x * 4 + dx) * 3
                        pixels.append(Array(f.rgb[i..<(i + 3)]))
                    } }
                    let mean = (0..<3).map { c in pixels.reduce(0) { $0 + $1[c] } / 16 }
                    if distance(mean, color) < 0.10 && pixels.reduce(0, { $0 + distance($1, mean) }) / 16 < 0.035 { count += 1 }
                }
            }
            return Double(count) / 144
        }
        let left = tail.map(coverage), right = head.map(coverage)
        guard min(left[3], right[0]) >= 0.95, left[3] - left[0] >= 0.30, right[0] - right[3] >= 0.30 else { return false }
        // Expansion then reveal across multiple samples; a one-frame flash or
        // an internal hard cut cannot masquerade as an occlusion transition.
        let growth = zip(left, left.dropFirst()).map { $1 - $0 }
        let reveal = zip(right, right.dropFirst()).map { $0 - $1 }
        return growth.allSatisfy { $0 >= -0.04 } && reveal.allSatisfy { $0 >= -0.04 }
            && growth.filter { $0 > 0.06 }.count >= 2 && reveal.filter { $0 > 0.06 }.count >= 2
    }

    static func motion(_ frames: [NaturalTransitionFrame]) -> Motion {
        let pairs = zip(frames, frames.dropFirst()).map { translation($0.luma, $1.luma, dt: $1.time - $0.time) }
        guard pairs.count == 3, pairs.allSatisfy({ $0.reliability >= 0.5 }) else { return Motion() }
        let x = pairs.map(\.x).sorted()[1], y = pairs.map(\.y).sorted()[1]
        let speed = hypot(x, y)
        guard speed > 0.01 else { return Motion() }
        let coherent = pairs.allSatisfy { ($0.x * x + $0.y * y) / max(0.0001, $0.speed * speed) > 0.93 && min($0.speed, speed) / max($0.speed, speed) > 0.6 }
        return Motion(x: x, y: y, reliability: coherent ? pairs.map(\.reliability).min()! : 0)
    }

    /// Textured local blocks must agree on displacement. Pixel differences
    /// alone cannot distinguish motion from flicker, cuts or camera shake.
    private static func translation(_ a: [Double], _ b: [Double], dt: Double) -> Motion {
        guard dt > 0, a.count == 2304, b.count == 2304 else { return Motion() }
        var vectors: [(Int, Int)] = []
        for y in [10, 18, 26] { for x in [12, 24, 36, 48] {
            let patch = (-3...3).flatMap { dy in (-3...3).map { dx in a[(y + dy) * 64 + x + dx] } }
            let mean = patch.reduce(0, +) / 49
            guard patch.reduce(0, { $0 + pow($1 - mean, 2) }) / 49 > 0.004 else { continue }
            var best = Double.greatestFiniteMagnitude, second = best
            var bx = 0, by = 0, stationary = 1.0
            for dy in -6...6 { for dx in -8...8 {
                var error = 0.0, i = 0
                for py in -3...3 { for px in -3...3 {
                    error += abs(patch[i] - b[(y + py + dy) * 64 + x + px + dx]); i += 1
                } }
                error /= 49
                if dx == 0 && dy == 0 { stationary = error }
                if error < best { second = best; best = error; bx = dx; by = dy }
                else { second = min(second, error) }
            } }
            if best < 0.075, best < stationary * 0.70, second - best > 0.002 { vectors.append((bx, by)) }
        } }
        guard vectors.count >= 6 else { return Motion() }
        let dx = vectors.map(\.0).sorted()[vectors.count / 2], dy = vectors.map(\.1).sorted()[vectors.count / 2]
        let agreeing = vectors.filter { abs($0.0 - dx) <= 1 && abs($0.1 - dy) <= 1 }.count
        return Motion(x: Double(dx) / 64 / dt, y: Double(dy) / 36 / dt, reliability: Double(agreeing) / 12)
    }
}
