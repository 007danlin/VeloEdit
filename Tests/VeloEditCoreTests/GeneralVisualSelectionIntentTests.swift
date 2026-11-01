import Foundation
import Testing
@testable import VeloEditCore

@Suite struct GeneralVisualSelectionIntentTests {
    @Test(arguments: ["Выбери красивые кадры и понятные визуальные моменты",
                      "Подбери самые интересные фрагменты", "Покажи удачные сцены, пожалуйста"])
    func genericSelectionIsTheExistingGenerationIntent(_ prompt: String) {
        #expect(IntentLedgerEngine.intents(prompt: prompt, brief: nil, pending: [], newAssetIDs: []) == [.createFilm])
    }

    @Test(arguments: ["Выбери красивые кадры без людей", "Выбери 3 красивые кадры",
                      "Выбери красивые кадры и поставь прыжок первым",
                      "Покажи только красивые сцены с Анной", "Выбери красивые кадры и добавь Москву"])
    func specificConstraintsCannotBeSwallowedAsGenericStyle(_ prompt: String) {
        #expect(!IntentLedgerEngine.isGeneralVisualSelectionRequest(prompt))
    }

    @Test func recognizingStyleDoesNotCertifyAnEmptyFilm() {
        let timeline = Timeline(storyPlanID: UUID(), items: [])
        #expect(IntentLedgerEngine.validate(.createFilm, timeline: timeline, previous: nil,
                                           analyses: [], assets: []).0 == .recoverableFailure)
    }
}
