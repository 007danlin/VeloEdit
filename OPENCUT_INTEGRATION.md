# OpenCut architecture audit and VeloEdit integration

Дата проверки: 2026-08-25. Проверены официальный репозиторий `OpenCut-app/OpenCut`, его актуальный README и архивный репозиторий `opencut-classic` (GitHub помечает его read-only с 17 мая 2026 года). Текущий OpenCut переписывается с нуля как editor API с plugin-first архитектурой, Rust core, MCP и headless-сценариями; classic остаётся полезной стабильной архитектурной справкой.

## Изученные части

| Область | OpenCut / opencut-classic | Решение в VeloEdit |
| --- | --- | --- |
| Timeline и команды | `timeline/types.ts`, `timeline/placement/*`, `commands/timeline/element/*`, `commands/timeline/clipboard/*` | Независимые Codable-объекты с UUID, track/start/duration/target; CRUD проходит через `VeloEditPipeline`, UI использует общий undo/redo снимков Timeline. |
| Эффекты | `effects/types.ts`, `effects/registry.ts`, `effects/definitions/blur.ts` | Единый `EffectPresetRegistry` задаёт stable ID, категорию, typed параметры, render stage, preview/render/FCPXML capability и безопасные AI-метаданные. Явный `stackOrder` определяет композитинг. |
| Keyframes | `animation/types.ts`, `animation/interpolation.ts`, `animation/effect-param-channel.ts`, `docs/keyframes.md` | Keyframe хранит parameter/time/typed value/easing. Linear/ease и опциональные cubic/back/elastic/bounce интерполируются одним кодом в preview/export. |
| Rendering | `docs/effects-renderer.md`, `services/renderer/nodes/effect-layer-node.ts`, `rendering/animation-values.ts` | Не перенесён web renderer. Эффекты и титры встроены в нативный AVFoundation/Core Image compositor VeloEdit, чтобы preview и MP4 использовали один путь. |
| Title templates | Text Node, multiline/line-height/letter-spacing и keyframe animation в актуальных releases; classic text/subtitle definitions | Собственный data-driven `TitleTemplateRegistry`: нормализованная композиция, safe area, типографика, text constraints и animation in/hold/out. Карточка библиотеки, Timeline и Export вызывают один `TitleOverlayRenderer`. |
| Субтитры | `subtitles/types.ts`, `subtitles/build-subtitle-text-element.ts`, `transcription/caption.ts`, `transcription/caption-defaults.ts` | `TitleTimelineItem` и `CaptionWord` сохраняют word-level timestamps и активную подсветку слова; тот же объект остаётся редактируемым на Timeline. |
| Переходы | Timeline element/placement model и renderer layering | `TimelineTransitionItem` хранит пару клипов, style/start/duration/intensity/direction/easing/parameters/enabled; библиотека и Inspector строятся из общего registry. |
| AI editing tools | Общий command-oriented подход timeline | `DirectorToolCall` получил строгие операции add/remove/move/trim effect, `animateParameter`, preset, title, transition и sync-to-beat. AI проходит через effect budgets и не мутирует renderer напрямую. |
| Музыкальная структура | Готовой реализации beat/bar/drop sync в изученных исходниках не найдено | Реализован отдельный нативный `MusicSyncEngine`: beat/bar grid, sections, peaks, quiet ranges, drops, snapping и ducking gain. |

## Что переиспользовано и что написано заново

Из OpenCut адаптированы архитектурные идеи: самостоятельные timeline-элементы, typed effect definitions, property keyframes и command boundary. Исходный TypeScript/React-код, UI-компоненты и renderer не копировались: реализация VeloEdit написана на Swift под существующие AVFoundation/Core Image/Core Graphics пути.

Оба изученных репозитория распространяются по MIT License: copyright 2026 OpenCut для текущего репозитория и copyright 2025–2026 OpenCut для classic. В `VeloEdit.app` исходники OpenCut не включены и substantial portions не копировались, поэтому отдельный OpenCut notice в bundle не требуется. Если в дальнейшем будет перенесён исходный фрагмент, его MIT copyright и permission notice должны быть добавлены в `ThirdParty` и в ресурсы приложения.

Ссылки: <https://github.com/OpenCut-app/OpenCut>, <https://github.com/OpenCut-app/opencut-classic>.

## Проверяемый результат

- Модели и интерполяция: `Sources/VeloEditCore/TimelineObjects.swift`.
- Каталог титров: `Sources/VeloEditCore/TitleTemplates.swift`.
- Музыкальный анализ: `Sources/VeloEditCore/MusicSyncEngine.swift`.
- AI mutation boundary: `Sources/VeloEditCore/AIDirectorEngine.swift`.
- Нативный preview/export: `Sources/VeloEditCore/PlaybackEngine.swift`, `VeloVideoCompositor.swift`, `TitleOverlayRenderer.swift`.
- Ручной Timeline и Inspector: `Sources/VeloEdit/MontageTimelineView.swift`, `ContentView.swift`.
- FCPXML intent/fallback: `Sources/VeloEditCore/FCPXMLExporter.swift`.
- Автотесты: `Tests/VeloEditCoreTests/TimelineObjectsTests.swift`.
