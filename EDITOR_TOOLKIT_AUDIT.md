# Аудит базовых монтажных инструментов

Обновлено: 2026-08-22.

## Критерий «реализовано»

Функция отмечается готовой только если typed intent хранится в `Timeline`, меняет live playback, тем же builder попадает в MP4 и имеет честную стратегию FCPXML. Наличие enum, пункта UI или текста AI само по себе не считается реализацией.

## Матрица

| Область | Timeline/model | Preview и MP4 | Final Cut Pro |
|---|---|---|---|
| Ken Burns, zoom, pan, push-in, pull-out | `TimelineItem.effect` | transform ramps в built-in/custom compositor; фото получают спокойный default | intent metadata + rendered reference; оригинал остаётся в Editable project |
| Dissolve, fade, dip black, blur, light, slide, wipe | `TimelineItem.transition` | реальное overlap; opacity/crop/transform/Core Image blur/flash | intent metadata + rendered reference; plug-in UID не выдумывается |
| Color/exposure/contrast/saturation/highlights/shadows/vignette/grain | optional `VideoAdjustments` | Core Image frame pipeline | conform/rotation/opacity native; остальное metadata + rendered reference |
| Stabilization, rolling shutter, smooth slow motion | optional `VideoAdjustments` | Vision translation estimate, bounded affine compensation/safety crop, temporal frame blend | metadata + rendered reference |
| Sharpening, video denoise, blur | optional `VideoAdjustments` | Core Image luminance sharpen/noise reduction/Gaussian blur | metadata + rendered reference |
| Slow/fast/speed ramp/freeze/reverse | `speed`, `SpeedRamp`, freeze/reverse flags | source-range insertion и `scaleTimeRange`; reverse frames; freeze frame stretch | constant/variable retime через editable `timeMap` |
| Photo sequence/layout | photo clips + `OverlaySettings` | H.264 still intermediate, motion; split/PiP не удлиняет фильм | originals/lanes + rendered reference для точного layout/motion |
| Fade, ducking, noise cleanup, EQ | optional `AudioAdjustments`, `AudioDuckingSettings` | `AVAudioMix`; music duck ramps; offline AVAudioEngine derived CAF | volume native; processing metadata + rendered reference |
| Speed/GPS/altitude/G-force/distance | `TelemetrySummary`, `TelemetryOverlaySettings` | GPMF SCAL decode; dynamic Core Graphics/Core Text HUD | metadata + rendered reference |

## Исправленные разрывы аудита

- Native 4K/5K fast path раньше мог сохранить transition только как intent и не показать его. Теперь любой transition отключает fast path.
- Ducking раньше постоянно ослаблял source audio при наличии музыки. Теперь музыка приглушается attack/release ramps на интервалах слышимого исходного звука.
- Фото всегда получало один зашитый zoom. Теперь motion выбирается из typed effect и может быть назначен Story Engine/AI-командой.
- FCPXML раньше оставлял неподдерживаемые эффекты только в metadata/marker. Теперь export создаёт точный rendered reference рядом с редактируемым source project.
- GPMF раньше сообщал только keys/sample count. Теперь GPS5/ACCL со SCAL дают численные samples, route, distance и G-force, доступные renderer.
- Noise reduction/EQ раньше были только будущим пунктом. Теперь они читают реальные audio samples и создают disposable processed intermediate.
- AI раньше только знал названия функций. Теперь `DirectorToolCall` и `DirectorEditingTools` валидируют и реально исполняют структурные, визуальные и звуковые решения над Timeline.

## Осознанные границы

- Noise cleanup — лёгкий offline high/low-frequency pass и EQ, не spectral/ML restoration.
- GPMF `UNIT` и абсолютная синхронизация нескольких metadata tracks требуют проверки на расширенном GoPro corpus.
- Стабилизация использует bounded translational compensation и safety crop; сложная perspective/optical-flow реконструкция намеренно не применяется, чтобы не создавать rubber-sheet артефакты.
- Семантический импорт всех fixtures в установленный Final Cut Pro остаётся release gate; XML well-formedness, source references, time maps и rendered-reference structure покрыты автоматическими тестами.
