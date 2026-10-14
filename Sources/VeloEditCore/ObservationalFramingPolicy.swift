import Foundation

/// A moving background or changing labels does not create another camera
/// setup when a face and its person remain in the same measured framing.
/// This is a soft selection limit, never a hard duplicate/action certificate.
enum ObservationalFramingPolicy {
    private struct Anchors {
        var face: NormalizedRegion
        var person: NormalizedRegion
    }

    static func sameFraming(_ a: EditorialUnit, _ b: EditorialUnit) -> Bool {
        guard a.candidate.assetID == b.candidate.assetID,
              min(a.evidence.confidence, b.evidence.confidence) >= 0.55,
              !a.evidence.hasProgression, !b.evidence.hasProgression,
              let left = anchors(a), let right = anchors(b) else { return false }
        return near(left.face, right.face, center: 0.08, ratio: 0.65)
            && near(left.person, right.person, center: 0.10, ratio: 0.65)
    }

    static func pruning(_ slots: [AutomaticEditorialAssembly.Slot]) -> [AutomaticEditorialAssembly.Slot] {
        var result: [AutomaticEditorialAssembly.Slot] = []
        var run: [AutomaticEditorialAssembly.Slot] = []
        var families: [[AutomaticEditorialAssembly.Slot]] = []
        func flush() {
            var keep = Set<UUID>()
            for family in families {
                let protected = family.filter { AutomaticEditorialAssembly.protected($0.unit) }
                let optional = family.filter { !AutomaticEditorialAssembly.protected($0.unit) }.sorted {
                    let a = ExpressiveMomentPolicy.selectionValue($0.unit), b = ExpressiveMomentPolicy.selectionValue($1.unit)
                    return a == b ? $0.unit.id.uuidString < $1.unit.id.uuidString : a > b
                }
                keep.formUnion((protected + optional.prefix(max(0, 2 - protected.count))).map { $0.unit.id })
            }
            result += run.filter { keep.contains($0.unit.id) }
            run.removeAll(keepingCapacity: true)
            families.removeAll(keepingCapacity: true)
        }
        for slot in slots {
            if run.last?.unit.candidate.assetID != slot.unit.candidate.assetID { flush() }
            // A confirmed action is an event boundary. Repeated observations
            // on either side may have different narrative purposes.
            if slot.unit.evidence.hasProgression {
                flush()
                result.append(slot)
                continue
            }
            // Complete-link prevents a gradual change of framing from merging
            // genuinely different views. Unknown anchors preserve their own
            // shot, but cannot reset the budget for an already measured view
            // within this continuous recording and action-free episode.
            if let index = families.firstIndex(where: { family in
                family.allSatisfy { sameFraming($0.unit, slot.unit) }
            }) {
                families[index].append(slot)
            } else {
                families.append([slot])
            }
            run.append(slot)
        }
        flush()
        return result
    }

    private static func valid(_ r: NormalizedRegion) -> Bool {
        [r.x, r.y, r.width, r.height].allSatisfy { $0.isFinite }
            && r.x >= 0 && r.y >= 0 && r.width > 0 && r.height > 0
            && r.x + r.width <= 1.01 && r.y + r.height <= 1.01
    }

    private static func near(_ a: NormalizedRegion, _ b: NormalizedRegion, center: Double, ratio: Double) -> Bool {
        abs(a.x + a.width / 2 - b.x - b.width / 2) < center
            && abs(a.y + a.height / 2 - b.y - b.height / 2) < center
            && min(a.width, b.width) / max(a.width, b.width) >= ratio
            && min(a.height, b.height) / max(a.height, b.height) >= ratio
    }

    private static func anchors(_ unit: EditorialUnit) -> Anchors? {
        let samples = unit.evidence.samples.filter { $0.confidence >= 0.55 }
        let pairs = samples.compactMap { sample -> Anchors? in
            let subjects = Array(zip(sample.subjectKinds, sample.subjectRegions)).filter { valid($0.1) }
            guard let face = subjects.filter({ $0.0 == .face }).map(\.1).max(by: { $0.area < $1.area }) else { return nil }
            // The largest detected body may belong to another passenger or
            // change when their arm moves. Associate the face with the most
            // specific measured person region which actually contains it.
            let people = subjects.filter { $0.0 == .person }.map(\.1).filter {
                $0.x <= face.x && $0.y <= face.y
                    && $0.x + $0.width >= face.x + face.width
                    && $0.y + $0.height >= face.y + face.height
            }
            guard let person = people.min(by: { $0.area < $1.area }) else { return nil }
            return Anchors(face: face, person: person)
        }
        let minimum = max(3, Int((Double(samples.count) * 0.6).rounded(.up)))
        guard pairs.count >= minimum else { return nil }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        func region(_ values: [NormalizedRegion]) -> NormalizedRegion {
            .init(x: median(values.map(\.x)), y: median(values.map(\.y)),
                  width: median(values.map(\.width)), height: median(values.map(\.height)))
        }
        let result = Anchors(face: region(pairs.map(\.face)), person: region(pairs.map(\.person)))
        guard pairs.filter({ near($0.face, result.face, center: 0.08, ratio: 0.65)
            && near($0.person, result.person, center: 0.10, ratio: 0.65) }).count >= minimum else { return nil }
        return result
    }
}
