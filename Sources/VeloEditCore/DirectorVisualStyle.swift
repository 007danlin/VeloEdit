import Foundation

/// The questionnaire's mood is shared by typography, reading time and edits.
/// It never authorizes cutaways, image grading or decorative effects.
public struct DirectorVisualStyle: Sendable {
    public var mood: DirectorNarrativeMood

    public init(mood: DirectorNarrativeMood) { self.mood = mood }

    public init(plan: StoryPlan) {
        if let brief = plan.directorBrief { mood = brief.mood }
        else if plan.preset == .cinematic { mood = .cinematic }
        else if plan.preset == .highlight || plan.preset == .adventure { mood = .dynamic }
        else { mood = .calm }
    }

    public func templateID(for purpose: SmartTitlePurpose) -> String? {
        guard [.filmOpening, .chapter, .activity].contains(purpose) else { return nil }
        return "title.minimal-clean.v1"
    }

    public func duration(text: String, secondary: String? = nil, purpose: SmartTitlePurpose) -> Double {
        let base: Double = switch mood {
        case .calm: 5
        case .cinematic: 5.5
        case .dynamic: 4.5
        }
        let opening = purpose == .filmOpening ? 0.5 : 0
        let reading = 2.2 + Double(text.count + (secondary?.count ?? 0)) / 12
        return min(9, max(base + opening, reading))
    }

    public func style(for template: TitleTemplateDefinition) -> TitleStyle {
        EditorialPresentationPolicy.compactChapterStyle
    }

    public func sceneBoundary(eventChanged: Bool, sceneChanged: Bool) -> EditorialBoundaryDecision? {
        guard eventChanged || sceneChanged else { return nil }
        switch mood {
        case .calm:
            return .init(choice: .transition, motivation: "Спокойное настроение: мягкое растворение при смене сцены",
                         confidence: 0.85, transitionStyle: .crossDissolve)
        case .cinematic:
            return .init(choice: .transition, motivation: "Киношное настроение: сдержанное разделение сцен и частей",
                         confidence: 0.85, transitionStyle: eventChanged ? .fadeThroughBlack : .crossDissolve)
        case .dynamic:
            return .init(choice: .cut, motivation: "Динамичное настроение: чёткая прямая склейка сохраняет темп", confidence: 0.85)
        }
    }

    public func transitionDuration(for style: TransitionStyle) -> Double {
        guard [.crossDissolve, .fadeThroughBlack].contains(style) else {
            return TransitionPresetRegistry.preset(for: style).defaultDuration
        }
        switch mood {
        case .calm: return 0.85
        case .cinematic: return 0.70
        case .dynamic: return 0.30
        }
    }
}
