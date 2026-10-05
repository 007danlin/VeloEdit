import Foundation
import Testing
@testable import VeloEditCore

struct DirectorCommentCombinationTests {
    @Test(arguments: ["Музыку повеселее", "Повеселей музыку", "Сделай музыку весёлой"])
    func cheerfulMusic(_ request: String) throws {
        let commands = EditorCommandParser().parse(request)
        let music = try #require(commands.compactMap { if case .setMusic(let value) = $0 { return value }; return nil }.first)
        #expect(music.style == .joyful)
    }

    @Test func compoundRequestKeepsTitleContentAndAllActions() {
        let commands = EditorCommandParser().parse("Музыку повеселее и переименуй титр на «Поехали, друзья; музыка и эффекты» и добавь крутые эффекты")
        #expect(commands.count == 3)
        #expect(commands.contains(.setTitleText("Поехали, друзья; музыка и эффекты", .selected)))
        #expect(commands.contains(.setEffect(.pushIn, .all)))
        #expect(!TitleEditInterpreter.targetsSelectedTitle("Переименуй титр на «Старт» и добавь крутые эффекты"))
        #expect(EditorCommandParser().parse("Переименуй титр на «Музыка, замедли и добавь эффекты»") == [.setTitleText("Музыка, замедли и добавь эффекты", .selected)])
        #expect(EditorCommandParser().parse("громкость музыки 20,5%") == [.setMusicVolume(0.205)])
        #expect(EditorCommandParser().parse("Переименуй выбранный титр на «Старт» и добавь крутые эффекты").contains(.setEffect(.pushIn, .all)))
    }

    @Test func compoundStructuralCommandsKeepOrderAndModelCompletesTitleStyle() {
        let parser = EditorCommandParser()
        #expect(parser.parse("Убери замедление") == [.removeSlowMotion(.all)])
        #expect(parser.parse("Убери все эффекты") == [.setEffect(nil, .all)])
        #expect(parser.parse("Разрежь клип и ускорь в 2 раза") == [.split(.all), .setSpeed(2, .all)])
        #expect(parser.parse("Плавно замедли и ускорь") == [.setSpeedRamp(.action, .all)])
        let exact: [EditorCommand] = [.setTitleStyle(80, nil, nil, nil, .selected)]
        #expect(EditorCommand.supplemental([.setTitleStyle(120, "#FF0000", nil, .left, .selected)], to: exact)
            == [.setTitleStyle(nil, "#FF0000", nil, .left, .selected)])
    }

    @Test func renameIsPreciseAndPartialFailureIsVisible() throws {
        let clip = TimelineItem(kind: .video, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)
        let a = TitleTimelineItem(kind: .title, text: "A", startTime: 0, duration: 2)
        let b = TitleTimelineItem(kind: .title, text: "B", startTime: 3, duration: 2)
        let timeline = Timeline(storyPlanID: UUID(), items: [clip], titleItems: [a, b])
        let request = "Переименуй титр на «Новое имя» и добавь крутые эффекты"
        let director = NaturalLanguageDirector()
        let input = NaturalLanguageDirectorInput(userRequest: request, currentProject: ProjectManifest(name: "test", timelines: [timeline]), timeline: timeline, selectedItemID: b.id)
        let result = director.execute(plan: director.plan(input: input), input: input)
        #expect(result.committed)
        #expect(result.timeline.effectiveTitleItems.map(\.text) == ["A", "Новое имя"])
        #expect(result.timeline.effectiveTitleItems[1].userEdited == true)
        #expect(result.timeline.items.first?.effect == ClipEffect.pushIn.rawValue)
        var ambiguous = input
        ambiguous.selectedItemID = nil
        let partial = director.execute(plan: director.plan(input: ambiguous), input: ambiguous)
        #expect(partial.timeline.effectiveTitleItems == timeline.effectiveTitleItems)
        #expect(partial.userSummary.contains("Не выполнено"))
        #expect(partial.userSummary.contains("выберите титр"))
    }
}
