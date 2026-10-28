import Foundation

enum LocalVisionMessageEncoding {
    /// Older mtmd runtimes fuse adjacent same-size Qwen images into a video
    /// pair. Text between explicit Ollama placeholders keeps each image
    /// independent, without resizing pixels or changing the model. Use the
    /// same prefix for a single image so a later sequence starting with those
    /// exact pixels can retain its already processed prefix.
    static func separatingImages(in body: [String: Any], firstIndex: Int = 0) -> [String: Any] {
        guard var messages = body["messages"] as? [[String: Any]] else { return body }
        for index in messages.indices {
            guard let images = messages[index]["images"] as? [String], !images.isEmpty,
                  let content = messages[index]["content"] as? String,
                  !content.contains("[img]"), !content.contains("[img-") else { continue }
            let attachments = images.indices.map { "Image \($0 + firstIndex): [img]" }.joined(separator: "\n")
            messages[index]["content"] = attachments + "\n" + content
        }
        var result = body
        result["messages"] = messages
        return result
    }
}

/// Shares only byte-identical images. Every occurrence remains in its scene's
/// ordered sequence, including repeated/still frames and their timestamps.
struct VisionEvidenceLayout {
    let images: [String]
    let references: [[Int]]

    static func isStandaloneDescription(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A syntactically valid string such as "1", ":{" or "scene index=1"
        // is not an observation. These occurred in real 2B scene batches and
        // previously entered both ranking and the reusable analysis cache.
        let words = clean.split(whereSeparator: { !$0.isLetter })
        guard words.count >= 3, clean.unicodeScalars.count >= 12,
              !clean.hasPrefix("{"), !clean.hasPrefix("}"), !clean.hasPrefix("[") else { return false }
        return clean.range(of: #"(?i)(same as|as in|see|identical to|sequence from)\s+scene\s*\d|(?:как в|см\.?|аналогично)\s+сцен[а-я]*\s*\d|^scene\s+index\s*[=:]|^image\s+\d+\s*$"#,
                   options: .regularExpression) == nil
    }

    init(frames: [[VisualFrameSample]]) {
        var images: [String] = []
        var identifiers: [String: Int] = [:]
        var references: [[Int]] = []
        for scene in frames {
            var sequence: [Int] = []
            for frame in scene {
                let identifier: Int
                if let existing = identifiers[frame.jpegBase64] { identifier = existing }
                else {
                    identifier = images.count + 1
                    images.append(frame.jpegBase64)
                    identifiers[frame.jpegBase64] = identifier
                }
                sequence.append(identifier)
            }
            references.append(sequence)
        }
        self.images = images
        self.references = references
    }

    static func sharedPrefix(_ lhs: [String], _ rhs: [String]) -> Int {
        zip(lhs, rhs).prefix(while: { $0.0 == $0.1 }).count
    }

    /// Batch membership is fixed. Only move a whole scene to the front when
    /// that reuses more of the preceding image prefix. Frames never reorder.
    static func order(frames: [[VisualFrameSample]], after previousImages: [String]) -> [Int] {
        let original = Array(frames.indices)
        var best = original
        var bestPrefix = sharedPrefix(previousImages, VisionEvidenceLayout(frames: frames).images)
        for first in frames.indices.dropFirst() {
            let order = [first] + original.filter { $0 != first }
            let prefix = sharedPrefix(previousImages, VisionEvidenceLayout(frames: order.map { frames[$0] }).images)
            if prefix > bestPrefix { best = order; bestPrefix = prefix }
        }
        return best
    }
}
