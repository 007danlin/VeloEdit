import Foundation
import Testing
import VeloEditCore
@testable import VeloEdit

@MainActor struct DirectorCommandBridgeTests {
    struct Sample: Sendable {
        var action: String
        var value: String
        var expected: EditorCommand
    }
    static let samples: [Sample] = [
        .init(action: "insert_background", value: #"{"background":"clouds","title":"Путешествие","duration":4}"#, expected: .insertBackground(.init(background: "clouds", title: "Путешествие"))),
        .init(action: "insert_source", value: "собака", expected: .insertSource("собака", .end)),
        .init(action: "add_library_effect", value: "glitch", expected: .addLibraryEffect(.glitch, .all)),
        .init(action: "apply_title_template", value: "title.minimal-clean.v1", expected: .applyTitleTemplate("title.minimal-clean.v1", .all)),
        .init(action: "set_speed", value: "2", expected: .setSpeed(2, .all)),
        .init(action: "remove_slow_motion", value: "", expected: .removeSlowMotion(.all)),
        .init(action: "set_speed_ramp", value: "ease-in", expected: .setSpeedRamp(.easeIn, .all)),
        .init(action: "set_duration", value: "2", expected: .setDuration(2, .all)),
        .init(action: "set_filter", value: "monochrome", expected: .setFilter(.monochrome, .all)),
        .init(action: "set_crop", value: "fill", expected: .setCrop(.fill, .all)),
        .init(action: "rotate", value: "right", expected: .rotate(1, .all)),
        .init(action: "set_brightness", value: "0.2", expected: .setBrightness(0.2, .all)),
        .init(action: "set_contrast", value: "1.2", expected: .setContrast(1.2, .all)),
        .init(action: "set_saturation", value: "1.2", expected: .setSaturation(1.2, .all)),
        .init(action: "set_warmth", value: "0.2", expected: .setWarmth(0.2, .all)),
        .init(action: "set_opacity", value: "0.5", expected: .setOpacity(0.5, .all)),
        .init(action: "set_exposure", value: "1.2", expected: .setExposure(1.2, .all)),
        .init(action: "set_highlights", value: "0.2", expected: .setHighlights(0.2, .all)),
        .init(action: "set_shadows", value: "0.2", expected: .setShadows(0.2, .all)),
        .init(action: "set_vignette", value: "0.2", expected: .setVignette(0.2, .all)),
        .init(action: "set_grain", value: "0.2", expected: .setGrain(0.2, .all)),
        .init(action: "set_sharpening", value: "0.2", expected: .setSharpening(0.2, .all)),
        .init(action: "set_video_denoise", value: "0.2", expected: .setVideoDenoise(0.2, .all)),
        .init(action: "set_blur", value: "0.2", expected: .setBlur(0.2, .all)),
        .init(action: "set_stabilization", value: "0.2", expected: .setStabilization(0.2, .all)),
        .init(action: "set_rolling_shutter", value: "true", expected: .setRollingShutterCorrection(true, .all)),
        .init(action: "set_smooth_slow_motion", value: "true", expected: .setSmoothSlowMotion(true, .all)),
        .init(action: "auto_enhance", value: "", expected: .autoEnhance(.all)),
        .init(action: "set_clip_volume", value: "0.3", expected: .setClipVolume(0.3, .all)),
        .init(action: "set_clip_muted", value: "true", expected: .setClipMuted(true, .all)),
        .init(action: "set_clip_fades", value: "0.2,0.4", expected: .setClipFades(0.2, 0.4, .all)),
        .init(action: "set_noise_reduction", value: "0.2", expected: .setNoiseReduction(0.2, .all)),
        .init(action: "set_eq", value: "voice", expected: .setEQ(.voice, .all)),
        .init(action: "detach_audio", value: "", expected: .detachAudio(.all)),
        .init(action: "set_audio_ducking", value: "false", expected: .setAudioDucking(false)),
        .init(action: "set_transition", value: "cross-dissolve", expected: .setTransition(.crossDissolve, .all)),
        .init(action: "set_transition_pattern", value: "cross-dissolve,light-flash", expected: .setTransitionPattern([.crossDissolve, .lightFlash], .all)),
        .init(action: "set_effect", value: "push-in", expected: .setEffect(.pushIn, .all)),
        .init(action: "set_effect_pattern", value: "push-in,pan-left", expected: .setEffectPattern([.pushIn, .panLeft], .all)),
        .init(action: "set_overlay", value: "picture-in-picture", expected: .setOverlay(.pictureInPicture, .all, .first)),
        .init(action: "set_telemetry", value: "speed", expected: .setTelemetryOverlay(TelemetryOverlaySettings(metrics: [.speed]), .all)),
        .init(action: "insert_freeze_frame", value: "1", expected: .insertFreezeFrame(1, .all)),
        .init(action: "insert_instant_replay", value: "0.5", expected: .insertInstantReplay(0.5, .all)),
        .init(action: "set_reverse", value: "true", expected: .setReverse(true, .all)),
        .init(action: "add_title", value: "Новая Глава", expected: .addTitle("Новая Глава", .beginning)),
        .init(action: "set_title_text", value: "Новая Глава", expected: .setTitleText("Новая Глава", .all)),
        .init(action: "set_title_style", value: ##"{"fontSize":80,"textColorHex":"#AABBCC","alignment":"left"}"##, expected: .setTitleStyle(80, "#AABBCC", nil, .left, .all)),
        .init(action: "remove_titles", value: "", expected: .removeTitles),
        .init(action: "delete", value: "", expected: .delete(.all)),
        .init(action: "duplicate", value: "", expected: .duplicate(.all)),
        .init(action: "split", value: "", expected: .split(.all)),
        .init(action: "move", value: "beginning", expected: .move(.all, .beginning)),
        .init(action: "set_original_audio_volume", value: "0.2", expected: .setOriginalAudioVolume(0.2)),
        .init(action: "set_music", value: "joyful", expected: .setMusic(MusicDirective(style: .joyful, bpm: 112))),
        .init(action: "set_music_volume", value: "0.2", expected: .setMusicVolume(0.2))
    ]

    @Test(arguments: samples) func everyEditorActionHasAnExecutableBridge(_ sample: Sample) throws {
        let data = try JSONSerialization.data(withJSONObject: ["reply": "Применю", "normalizedBrief": "", "commands": [[
            "action": sample.action, "target": "all", "value": sample.value, "secondaryTarget": "first"
        ]]])
        let result = try LocalDirectorAgent.decodeReply(String(decoding: data, as: UTF8.self),
            userMessage: "Добавь титр «Новая Глава» и примени монтажные правки", runtimeLabel: "test", allowsFootageReplacement: true)
        #expect(result.commands == [sample.expected])
    }

    @Test func malformedStyleDoesNotTurnCompoundRequestIntoPartialEdit() {
        let json = #"{"reply":"Применю","commands":[{"action":"set_filter","target":"all","value":"monochrome","secondaryTarget":""},{"action":"set_title_style","target":"all","value":"{\"fontSize\":-10}","secondaryTarget":""}]}"#
        #expect(throws: (any Error).self) {
            try LocalDirectorAgent.decodeReply(json, userMessage: "Измени цвет и титр", runtimeLabel: "test", allowsFootageReplacement: false)
        }
    }
}
