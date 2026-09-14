import CoreGraphics
import Foundation
import Testing
@testable import VeloEditCore

@Suite struct TitleEditingTests {
    @Test func chapterNumberMigratesPersistsAndChangesRenderedDigits() throws {
        let template = try #require(TitleTemplateRegistry.template(id: "title.chapter.v1"))
        var item = template.previewItem()
        item.additionalText = "ГЛАВА 03"
        #expect(item.effectiveChapterNumber == 3)
        let original = try #require(TitleOverlayRenderer.cgImage(item: item, timelineTime: 1.5, renderSize: CGSize(width: 640, height: 360)))
        item.setChapterNumber(12)
        item = try JSONDecoder().decode(TitleTimelineItem.self, from: JSONEncoder().encode(item))
        #expect(item.chapterNumber == 12)
        #expect(item.additionalText == "ГЛАВА 12")
        let edited = try #require(TitleOverlayRenderer.cgImage(item: item, timelineTime: 1.5, renderSize: CGSize(width: 640, height: 360)))
        #expect(original.dataProvider?.data as Data? != edited.dataProvider?.data as Data?)
        #expect(template.previewItem().formattedChapterNumber == "01")
    }

    @Test func titleCommandsEditRequestedFieldsAndPreserveTheRest() throws {
        var original = try #require(TitleTemplateRegistry.template(id: "title.chapter.v1")).previewItem()
        original.style.fontSize = 100
        original.additionalText = "Путешествие"
        let result = try #require(TitleEditInterpreter.applying("Сделай титр красным и крупнее, номер главы 7", to: original))
        #expect(result.item.id == original.id)
        #expect(result.item.templateID == original.templateID)
        #expect(result.item.style.fontSize == 120)
        #expect(result.item.style.textColorHex == "#FF453A")
        #expect(result.item.chapterNumber == 7)
        #expect(result.item.additionalText == original.additionalText)
        let renamed = try #require(TitleEditInterpreter.applying("Замени текст на «Красный закат»", to: original))
        #expect(renamed.item.text == "Красный закат")
        #expect(renamed.item.style == original.style)
        #expect(TitleEditInterpreter.applying("Сделай как в том примере", to: original) == nil)
        #expect(!TitleEditInterpreter.targetsSelectedTitle("Сделай фильм динамичным"))
        #expect(!TitleEditInterpreter.targetsSelectedTitle("Не меняй титр, только предложи варианты"))
    }

    @Test func redesignedTitlesKeepTextRegionsSeparateAcrossFormats() throws {
        for id in ["title.chapter.v1", "title.dynamic.v1", "title.end-card.v1"] {
            let template = try #require(TitleTemplateRegistry.template(id: id))
            for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1080), CGSize(width: 1080, height: 1350), CGSize(width: 1080, height: 1920)] {
                let layout = AdaptiveTitleLayout.resolve(template: template, renderSize: size)
                let text = layout.elements.filter { $0.kind == .text }
                for i in text.indices {
                    for j in text.indices where j > i {
                        #expect(!text[i].frame.intersects(text[j].frame), "\(id): \(text[i].id) overlaps \(text[j].id) at \(size)")
                    }
                }
            }
        }
    }
}
