import Foundation
import Testing
@testable import VeloEditCore

struct EverydayDirectorCommandTests {
    struct Sample: Sendable, CustomStringConvertible {
        var prompt: String
        var commands: [EditorCommand]
        var description: String { prompt }
    }

    static let examples: [Sample] = [
        .init(prompt: "еще хочу эффект камеры в первом видео", commands: [.addLibraryEffect(.videoCamera, .first)]),
        .init(prompt: "Ещё хочу добавить эффект камеры на первое видео!", commands: [.addLibraryEffect(.videoCamera, .first)]),
        .init(prompt: "Можешь добавить эффект видеокамеры во втором видео?", commands: [.addLibraryEffect(.videoCamera, .number(2))]),
        .init(prompt: "Ну и ещё, пожалуйста, наложи эффект «Видеокамера» на первый клип", commands: [.addLibraryEffect(.videoCamera, .first)]),
        .init(prompt: "В первом видео хочу эффект камеры", commands: [.addLibraryEffect(.videoCamera, .first)]),
        .init(prompt: "Добавь эффект REC для третьего ролика", commands: [.addLibraryEffect(.videoCamera, .number(3))]),
        .init(prompt: "Добавь эффект видоискателя в последний фрагмент", commands: [.addLibraryEffect(.videoCamera, .last)]),
        .init(prompt: "Поставь эффект ручной камеры на выбранное видео", commands: [.addLibraryEffect(.handheld, .selected)]),
        .init(prompt: "Примени эффект дрейфа камеры в первом клипе", commands: [.addLibraryEffect(.cameraDrift, .first)]),
        .init(prompt: "Добавь плавный наезд камеры в первом видео", commands: [.setEffect(.pushIn, .first)]),
        .init(prompt: "Добавь плавный отъезд камеры во втором видео", commands: [.setEffect(.pullOut, .number(2))]),
        .init(prompt: "Добавь эффект камеры здесь", commands: [.addLibraryEffect(.videoCamera, .selected)]),
        .init(prompt: "Добавь эффект камеры на это видео", commands: [.addLibraryEffect(.videoCamera, .selected)]),
        .init(prompt: "Хочу эффект камеры на нём", commands: [.addLibraryEffect(.videoCamera, .selected)]),
        .init(prompt: "Добавь эффект камеры на весь фильм", commands: [.addLibraryEffect(.videoCamera, .all)]),
        .init(prompt: "Добавь эффект камеры ко всем клипам", commands: [.addLibraryEffect(.videoCamera, .all)]),
        .init(prompt: "Добавь эффект камеры на 1-е видео", commands: [.addLibraryEffect(.videoCamera, .number(1))]),
        .init(prompt: "Добавь эффект камеры в 12-м клипе", commands: [.addLibraryEffect(.videoCamera, .number(12))]),
        .init(prompt: "Добавь эффект камеры на видео № 3", commands: [.addLibraryEffect(.videoCamera, .number(3))]),
        .init(prompt: "Добавь эффект камеры в клипе номер 15", commands: [.addLibraryEffect(.videoCamera, .number(15))]),
        .init(prompt: "Пожалуйста, установи громкость музыки на 12,5%", commands: [.setMusicVolume(0.125)]),
        .init(prompt: "Музыку на 0%, пожалуйста!", commands: [.setMusicVolume(0)]),
        .init(prompt: "Сделай музыку тише", commands: [.setMusicVolume(0.25)]),
        .init(prompt: "Убери музыку", commands: [.setMusic(nil)]),
        .init(prompt: "Приглуши музыку под речь", commands: [.setAudioDucking(true)]),
        .init(prompt: "Приглуши звук исходников", commands: [.setOriginalAudioVolume(0.2)]),
        .init(prompt: "Убери звук исходников", commands: [.setOriginalAudioVolume(0)]),
        .init(prompt: "Верни исходный звук", commands: [.setOriginalAudioVolume(1)]),
        .init(prompt: "Убери звук в первом видео", commands: [.setClipMuted(true, .first)]),
        .init(prompt: "Включи звук выбранного клипа", commands: [.setClipMuted(false, .selected)]),
        .init(prompt: "Установи громкость второго клипа 40%", commands: [.setClipVolume(0.4, .number(2))]),
        .init(prompt: "Отдели звук последнего видео", commands: [.detachAudio(.last)]),
        .init(prompt: "Ускорь первое видео в 2 раза", commands: [.setSpeed(2, .first)]),
        .init(prompt: "Замедли третий клип в 4 раза", commands: [.setSpeed(0.25, .number(3))]),
        .init(prompt: "Поставь скорость второго видео 1,5x", commands: [.setSpeed(1.5, .number(2))]),
        .init(prompt: "Верни нормальную скорость первого клипа", commands: [.setSpeed(1, .first)]),
        .init(prompt: "Убери замедление во всех клипах", commands: [.removeSlowMotion(.all)]),
        .init(prompt: "Сделай длительность первого видео 3,5 секунды", commands: [.setDuration(3.5, .first)]),
        .init(prompt: "Установи длительность клипа 2 4 секунды", commands: [.setDuration(4, .number(2))]),
        .init(prompt: "Сделай длительность выбранного клипа 3 секунды", commands: [.setDuration(3, .selected)]),
        .init(prompt: "Сделай первое видео чёрно-белым", commands: [.setFilter(.monochrome, .first)]),
        .init(prompt: "Добавь теплый фильтр во втором видео", commands: [.setFilter(.warm, .number(2))]),
        .init(prompt: "Примени фильтр нуар в последнем клипе", commands: [.setFilter(.noir, .last)]),
        .init(prompt: "Убери фильтр с первого клипа", commands: [.setFilter(.none, .first)]),
        .init(prompt: "Стабилизируй первое видео", commands: [.setStabilization(0.58, .first)]),
        .init(prompt: "Убери тряску в выбранном клипе", commands: [.setStabilization(0.58, .selected)]),
        .init(prompt: "Выключи стабилизацию второго видео", commands: [.setStabilization(0, .number(2))]),
        .init(prompt: "Поверни первое видео вправо на 90 градусов", commands: [.rotate(1, .first)]),
        .init(prompt: "Поверни выбранный клип влево", commands: [.rotate(-1, .selected)]),
        .init(prompt: "Отрази первое видео зеркально", commands: [.setEffect(.mirror, .first)]),
        .init(prompt: "Заполни кадр в первом видео", commands: [.setCrop(.fill, .first)]),
        .init(prompt: "Покажи второе видео целиком", commands: [.setCrop(.fit, .number(2))]),
        .init(prompt: "Убери все эффекты с последнего клипа", commands: [.setEffect(nil, .last)]),
        .init(prompt: "Удали второй клип", commands: [.delete(.number(2))]),
        .init(prompt: "Дублируй первое видео", commands: [.duplicate(.first)]),
        .init(prompt: "Разрежь выбранный клип", commands: [.split(.selected)]),
        .init(prompt: "Перемести последний клип в начало", commands: [.move(.last, .beginning)]),
        .init(prompt: "Убери все титры", commands: [.removeTitles]),
        .init(prompt: "Поставь титр «Камера, музыка и свет» в конце", commands: [.addTitle("Камера, музыка и свет", .end)]),
        .init(prompt: "Добавь эффект камеры в первом видео и убери звук", commands: [.addLibraryEffect(.videoCamera, .first), .setClipMuted(true, .first)]),
        .init(prompt: "Ускорь первый клип в 2 раза, второй клип сделай чёрно-белым, убери у него звук", commands: [.setSpeed(2, .first), .setFilter(.monochrome, .number(2)), .setClipMuted(true, .number(2))]),
        .init(prompt: "Добавь эффект камеры во втором видео и добавь на нем эффект глитч", commands: [.addLibraryEffect(.videoCamera, .number(2)), .addLibraryEffect(.glitch, .number(2))]),
        .init(prompt: "Добавь эффект камеры во втором видео и убери звук выбранного клипа", commands: [.addLibraryEffect(.videoCamera, .number(2)), .setClipMuted(true, .selected)]),
        .init(prompt: "Добавь эффект камеры в первом видео и добавь эффект глитч во втором видео", commands: [.addLibraryEffect(.videoCamera, .first), .addLibraryEffect(.glitch, .number(2))]),
        .init(prompt: "Добавь эффект камеры в первом видео; громкость музыки 20%", commands: [.addLibraryEffect(.videoCamera, .first), .setMusicVolume(0.2)]),
        .init(prompt: "Ускорь первый клип в 2 раза. Убери звук во втором видео.", commands: [.setSpeed(2, .first), .setClipMuted(true, .number(2))]),
        .init(prompt: "Добавь титр «Ещё хочу камеру!» в конце и добавь эффект камеры в первом видео", commands: [.addTitle("Ещё хочу камеру!", .end), .addLibraryEffect(.videoCamera, .first)])
    ]

    @Test(arguments: examples) func everydayRequestsProduceCompletePlans(_ sample: Sample) {
        let parser = EditorCommandParser()
        #expect(parser.parseComplete(sample.prompt, hasSelection: true) == sample.commands, "\(sample.prompt)")
        #expect(parser.parse(sample.prompt) == sample.commands, "Planner must agree with routing: \(sample.prompt)")
        #expect(DirectorRequestIntentInterpreter().mode(for: sample.prompt) == .edit, "\(sample.prompt)")
    }

    @Test(arguments: TimelineEffectType.allCases) func everyLibraryEffectSupportsItsDisplayedNameAndCode(_ effect: TimelineEffectType) {
        let parser = EditorCommandParser()
        for name in [effect.localizedTitle, effect.rawValue] {
            let prompt = "Пожалуйста, добавь эффект «\(name)» в первом видео"
            #expect(parser.parseComplete(prompt, hasSelection: false) == [.addLibraryEffect(effect, .first)], "\(prompt)")
            #expect(parser.parse(prompt) == [.addLibraryEffect(effect, .first)])
        }
    }

    static let uncertainRequests = [
        "Не добавляй эффект камеры в первом видео", "Не надо эффект камеры в первом видео",
        "Стоит ли добавить эффект камеры в первом видео?", "Почему не добавился эффект камеры?",
        "Как выглядит эффект камеры?", "Какой эффект камеры лучше?", "Объясни эффект камеры",
        "Добавь эффект камеры в первом видео кроме последних двух секунд",
        "Добавь эффект камеры в первом видео на 2 секунды", "Добавь эффект камеры с 2 по 4 секунду",
        "Добавь эффект камеры в первом видео и замени неудачный дубль",
        "Добавь эффект камеры в первом видео и сделай историю интереснее",
        "Добавь эффект камеры на первом и третьем клипе", "Добавь эффект камеры в клипах 1-3",
        "Добавь эффект камеры на видео 0", "Добавь эффект камеры на видео -1",
        "Добавь эффект камеры в клипе 99999999999999999999999999999999",
        "Добавь эффект камеры на лицо", "Добавь эффект неизвестного плагина в первом видео",
        "Добавь эффект камеры если там человек", "Добавь эффект камеры как в прошлом проекте",
        "Удали", "Разрежь", "Громкость музыки 120%", "Громкость музыки -10%",
        "Ускорь первое видео в 0 раз", "Замедли первое видео в 100 раз",
        "Сделай длительность первого клипа 0 секунд", "Сделай длительность 10 секунд",
        "Поверни первое видео вправо на 45 градусов", "Убери эффект камеры в первом видео",
        "Добавь эффект камеры в первом видео без изменений", "Добавь эффект камеры во втором",
        "Добавь эффект камеры в первом видео, а во втором сделай черно-белым"
    ]

    @Test(arguments: uncertainRequests) func unknownTailNegationAndAmbiguityCannotBypassInterpretation(_ prompt: String) {
        #expect(EditorCommandParser().parseComplete(prompt, hasSelection: true) == nil, "\(prompt)")
    }

    @Test(arguments: ["Добавь эффект камеры на выбранное видео", "Добавь эффект камеры на это видео", "Добавь эффект камеры здесь", "Убери звук выделенного клипа"])
    func selectionIsRequired(_ prompt: String) {
        #expect(EditorCommandParser().parseComplete(prompt, hasSelection: false) == nil)
    }

    @Test func firstCameraEffectTargetsOnlyFirstClipAndSurvivesRoundTrip() throws {
        let items = (0..<3).map { TimelineItem(kind: .video, sourceDuration: 4, timelineStart: Double($0 * 4), timelineDuration: 4) }
        let timeline = Timeline(storyPlanID: UUID(), items: items)
        let commands = try #require(EditorCommandParser().parseComplete("еще хочу эффект камеры в первом видео", hasSelection: false))
        let result = EditorCommandExecutor().apply(commands, to: timeline, selectedItemID: items[2].id)
        #expect(result.report.ignored.isEmpty)
        #expect(result.timeline.items == items)
        let camera = try #require(result.timeline.effectiveEffects.first)
        #expect(result.timeline.effectiveEffects.count == 1)
        #expect(camera.effectType == .videoCamera && camera.targetClipID == items[0].id)
        #expect(camera.startTime == 0 && camera.duration == 4)
        #expect(camera.parameters == EffectPresetRegistry.preset(for: .videoCamera).defaultParameters)
        let reopened = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(result.timeline))
        #expect(reopened.effectiveEffects == result.timeline.effectiveEffects)
        let repeated = EditorCommandExecutor().apply(commands, to: reopened)
        #expect(repeated.timeline.effectiveEffects.count == 1)
    }
}
