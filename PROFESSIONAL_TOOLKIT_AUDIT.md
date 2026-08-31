# Professional Editing Toolkit — аудит и план развития

Дата проверки: 2026-08-24.

## Итог

VeloEdit уже имеет рабочее ядро профессионального монтажного набора: 11 переходов, базовые движения кадра, speed ramp, цветокоррекцию, размытия и световые эффекты, многослойный playback, титры и word-level captions, аудиообработку, object-aware reframe и развитую телеметрию. Эти возможности существуют не только как пункты интерфейса: большая часть проходит через типизированный `Timeline`, live preview и MP4 export.

Главная проблема — не нехватка десятков декоративных пресетов, а отсутствие единого расширяемого контракта. Сейчас инструменты распределены между `ClipEffect`, `VideoAdjustments`, `TimelineEffectType`, `TransitionStyle`, `TitleTimelineItem`, `OverlaySettings` и отдельными telemetry/audio моделями. Из-за этого у них разные схемы параметров, preview-политики, правила AI и границы кэширования.

Рекомендация:

1. В P0 объединить существующие возможности через versioned registry и адаптеры, не ломая сохранённые проекты и AVFoundation/Core Image pipeline.
2. В P1 добавить Metal-слой для масок, маттинга, tracked background blur и переходов, которым нужны несколько текстур.
3. Не встраивать web-renderer ради количества эффектов. OpenCut и Motion Canvas полезны как архитектурные референсы, FFmpeg — как изолированный offline/export backend, MetalPetal — как наиболее естественный кандидат для нативного GPU-расширения.
4. AI должен назначать инструмент только при наличии монтажного мотива. Иерархия `Emotion → Story → Rhythm → Eye-trace → 2D → 3D` из `PROFESSIONAL_EDITING_KNOWLEDGE_AUDIT.md` остаётся выше визуального toolkit.

На этапе настоящего ТЗ исходный код не изменялся. Документ фиксирует фактическое состояние и следующий безопасный план.

## Как выставлялся статус

- **Готово** — есть типизированный intent, редактирование, preview и MP4-результат либо честный уже задокументированный export fallback.
- **Частично** — рабочий путь есть, но не покрывает профессиональный диапазон задачи или имеет отдельные ветки без общего контракта.
- **Отсутствует** — нет самостоятельного пользовательского инструмента; внутренний рисунок UI или enum не считается.
- **Нужен новый renderer** — текущего однослойного Core Image/AVFoundation пути недостаточно либо попытка имитировать функцию даст слабый результат.

## Текущая техническая база

Основные доказательства находятся в следующих файлах:

- `Sources/VeloEditCore/Models.swift` — 11 `TransitionStyle`, 8 `ClipEffect`, `SpeedRamp`, `VideoAdjustments`, 7 `AudioEffect`, overlays и title style.
- `Sources/VeloEditCore/TimelineObjects.swift` — keyframes/easing, standalone effects, transitions, title/caption timeline items.
- `Sources/VeloEditCore/VeloVideoCompositor.swift` — Core Image effects, motion transforms, slow-motion blend, transitions и subject reframe.
- `Sources/VeloEditCore/PlaybackEngine.swift` — слои cutaway/PiP/split-screen/green-screen и единый playback путь.
- `Sources/VeloEditCore/TitleOverlayRenderer.swift` — титры, lower thirds, cards, captions и активное слово.
- `Sources/VeloEditCore/ProcessedAudioGenerator.swift` — EQ, reverb, delay и distortion через AVAudioEngine.
- `Sources/VeloEditCore/TelemetryModels.swift` и telemetry renderers — 45 видов telemetry widgets.
- `ThirdParty/OVRLEY/` — локальный OVRLEY bridge, исходники и GPL notices.
- `EDITOR_TOOLKIT_AUDIT.md` — предыдущая проверка preview/export/FCPXML для базовых инструментов.
- `OPENCUT_INTEGRATION.md` — предыдущая архитектурная сверка с OpenCut.

## Полная матрица инструментов

| Область | Статус | Что уже работает | Чего не хватает / честная граница |
| --- | --- | --- | --- |
| Переходы | **Готово** | Cross dissolve, fade, fade through black, blur dissolve, light flash, slide L/R, push, zoom, wipe L/R; overlap реально рендерится | Нет общей parameter schema; нет luma/matte и motion-matched переходов |
| Базовые эффекты | **Готово** | Transform, blur, image, light и cinematic timeline effects с intensity, target и keyframes | Два параллельных словаря (`ClipEffect` и `TimelineEffectType`) должны стать одним registry |
| Speed ramp | **Готово** | Точки position/rate, ease-in/ease-out/action, вычисление output duration, editable time map | Нужны bezier handles и наглядный график скорости; это UI/contract, не новый renderer |
| Slow motion | **Частично** | Constant slow motion, speed ramp и temporal frame blend | Нет полноценной motion-compensated optical flow интерполяции; экстремальное замедление будет слабее Resolve/FCP |
| Zoom / pan / Ken Burns | **Готово** | Zoom in/out, push/pull, pan L/R, Ken Burns, keyframed transform | Нужны единые anchor/overscan/edge policies и motion-safe bounds |
| Camera movement | **Частично** | 2D virtual camera: scale/translate/shake/motion blur | Нет 2.5D/3D camera, depth layers, parallax scene и focus plane |
| Blur | **Готово** | Gaussian, directional, motion и whole-frame/background-labelled blur | Настоящий background-only blur требует маски субъекта; текущее название не должно обещать segmentation |
| Маски | **Нужен новый renderer** | Ограниченный chroma key существует внутри green-screen overlay | Нет rectangle/ellipse/pen/gradient masks, feather, invert, combine, matte track и rotoscoping |
| Compositing | **Частично** | Cutaway, PiP, split-screen, chroma key, opacity и custom compositor | Нет blend modes, arbitrary layer graph, alpha/luma mattes и масочных операций |
| Overlays / B-roll | **Готово** | Многослойная timeline-модель, привязка к base clip, scale/corner/offset; AI выбирает B-roll по конкретной функции | Нужны blend/mask controls и более общий transform для любого overlay |
| Titles | **Готово** | Basic, cinematic, location/date/chapter, title/end cards, animated title, keyword/kinetic text | Нужен versioned preset catalog, safe-area и responsive layout contracts |
| Lower thirds | **Готово** | Отдельный title kind, редактируемый текст и стиль, preview/export | Нужны несколько дизайн-семейств и optional logo/avatar slots |
| Captions / subtitles | **Готово** | Automatic subtitles, word-level timing, active-word highlight, editable style | Нужны line-breaking rules, speaker styles, reading-speed QA и импорт/экспорт SRT/VTT как единый workflow |
| Text animations | **Частично** | None/fade/slide/scale/kinetic, duration и easing | Нет per-character animator, path text, reveal/mask, blur-in и motion-safe typography engine |
| Shapes | **Нужен новый renderer** | Core Graphics рисует служебные/telemetry элементы | Нет пользовательского vector shape layer, path, fill/stroke, trim-path, repeaters и keyframes |
| Particles | **Нужен новый renderer** | В каталоге есть статические particle-themed backgrounds и старые внутренние заготовки | Нет общего emitter/simulation layer; нельзя считать статическую текстуру системой частиц |
| Light effects | **Частично** | Light, flash, glow, light-flash transition | Нет halation, bloom threshold, lens dirt, controllable flare source и light leaks как параметризованных ресурсов |
| Color effects | **Готово** | Exposure, contrast, saturation, temperature/warmth/tint, highlights/shadows, vignette, grain, denoise, sharpen, presets и LUT/color-cube path | Нужны scopes, curves, wheels, selective/HSL corrections и color-management policy |
| Audio transitions | **Готово** | Fade in/out, ducking, music ramps и editable J/L sound bridges | Нужен явный equal-power crossfade preset и room-tone continuity helper |
| Audio effects | **Готово** | Voice enhance, telephone, muffled, echo, room, robot; EQ/reverb/delay/distortion offline processing | Нужна единая параметризация и loudness/true-peak QA |
| SFX | **Частично** | Есть роль SFX и аудиоклипы на timeline | Нет встроенного каталога, tagging, waveform audition, лицензий ресурсов и автоматического выбора по событию |
| Telemetry | **Готово** | 22 стиля, 17 presentation types, 45 widgets, route/speed/altitude/G-force и прочие метрики; OVRLEY bridge | GPL release gate обязателен; нужна единая `TelemetryPreset` schema поверх legacy и OVRLEY стилей |
| Tracking | **Частично** | Subject tracking и траектория для reframe | Нет stable identity, occlusion handling, user correction points, mask tracking и object attach |
| Object-aware reframing | **Готово** | `SubjectReframePlan` меняет transform в compositor и сохраняется в проекте | Confidence/fallback есть, но нет multi-subject priority и ручной коррекции траектории |
| Motion graphics | **Частично** | Titles, captions, telemetry и backgrounds уже создают motion-graphics результат | Нет общего scene graph, vector shapes, reusable nested compositions и expression system |
| Animated backgrounds | **Частично** | 63 preset IDs, 25 bundled PNG и спокойное cinematic движение для non-solid presets | Большинство фонов двигаются одинаковым transform; нет style-specific liquid/ink/particle animation |
| Intro / outro | **Готово** | Title card/end card и background/title timeline elements | Нужны бренд-пакеты, audio sting slots и duration-responsive layout |

## Что уже можно считать профессионально пригодным

### Переходы и движение

Существующие 11 переходов покрывают основную монтажную грамматику. После TOP 20 изменений они не должны появляться по cadence: boundary хранит `CUT`, `HOLD` или мотивированный `transition`. Это важнее добавления ещё двадцати wipes.

`SpeedRamp` и transform effects уже являются параметризованными и редактируемыми. Для профессионального UI им не хватает общего графика кривых, bezier easing и единой системы anchor/overscan, но renderer переписывать не требуется.

### Титры и captions

Модель уже различает title, subtitle, lower third, cinematic title, location, date, chapter, animated title, keyword overlay, kinetic text, automatic subtitles, word-level captions, title card и end card. `TitleStyle` хранит typography, placement, scale, rotation, opacity, shadow, stroke, background, blur, tracking, line spacing и active-word color.

Это готовая основа для `TitlePreset` и `CaptionPreset`; создавать вторую title model не нужно.

### Audio

AVAudioEngine путь уже даёт настоящие EQ/reverb/delay/distortion processing, а timeline умеет fades, ducking и J/L bridges. Следующий уровень — не новый аудиодвижок, а preset contract, equal-power crossfade, loudness validation и библиотека лицензированных SFX.

### Telemetry

Telemetry — одна из самых сильных областей VeloEdit: 45 widget kinds и локальный OVRLEY bridge покрывают обычные, cycling, running, motorsport и camera metrics. OVRLEY работает как отдельный процесс, но остаётся GPL-3.0-or-later компонентом: дистрибуция требует corresponding source и сохранения notices.

## Чего действительно нет

Следующие функции нельзя объявлять готовыми через новое имя enum:

- произвольные маски с feather/combine/invert;
- alpha/luma matte compositing;
- tracked mask и rotoscoping;
- subject-only/background-only effects без segmentation mask;
- vector shape layer с анимируемым path;
- настоящая particle simulation;
- 2.5D/3D camera и depth-aware parallax;
- optical-flow slow motion высокого качества;
- identity tracking через occlusion;
- reusable nested motion-graphics compositions.

Для первых шести нужен Metal-oriented multi-input render graph. Для optical flow можно сначала использовать системные возможности там, где качество предсказуемо, либо изолированный offline backend; обещать real-time optical flow без бенчмарка нельзя.

## Исследование open-source и source-available решений

Ниже — архитектурная оценка, а не решение автоматически копировать или подключать код. Юридические выводы являются engineering assessment, не юридической консультацией.

| Проект | Лицензия | Что полезно перенести | Offline / macOS Apple Silicon | Совместимость с VeloEdit | Производительность и решение |
| --- | --- | --- | --- | --- | --- |
| [OpenCut](https://github.com/OpenCut-app/OpenCut) / [LICENSE](https://github.com/OpenCut-app/OpenCut/blob/main/LICENSE) | MIT | Plugin-first registry, typed timeline elements, command boundary, effect definitions | Локальная сборка возможна; новый Rust/web/desktop core ещё переписывается, classic архивирован | Идеи совместимы, прямой TypeScript/Rust renderer — нет | Использовать как reference. Не тащить web UI/runtime и не копировать код без необходимости |
| [Remotion](https://www.remotion.dev/) / [license](https://www.remotion.dev/docs/license) | Собственная двухуровневая лицензия, не обычная permissive OSS: free для individuals, non-profits и for-profit до 3 сотрудников; остальным нужна Company License | React composition model, parameterized templates, deterministic frame-based motion, caption/template ecosystem | Локальный render возможен после установки Node/Chromium; cloud необязателен | Прямое встраивание добавит JS/Chromium runtime и отдельную rendering truth | Не включать в основной bundle. Допустим только лицензированный optional/external template renderer после business/legal решения |
| [Motion Canvas](https://github.com/motion-canvas/motion-canvas) | MIT | Generator-based animation flow, vector scene hierarchy, editor/preview split, image-sequence exporter | Offline после установки Node dependencies; macOS arm64 работает через web toolchain | Низкая прямая совместимость; полезен как формат авторинга и reference для `MotionPreset` | Browser/player тяжелее native preview. Возможен внешний authoring/export tool, не основной compositor |
| [FFmpeg](https://ffmpeg.org/) / [legal](https://ffmpeg.org/legal.html) / [filters](https://ffmpeg.org/ffmpeg-filters.html) | LGPL-2.1+ по умолчанию; optional GPL parts меняют итоговый binary на GPL; `--enable-nonfree` может сделать binary нераспространяемым | `xfade`, overlay, chromakey, maskedmerge, minterpolate, zoompan, LUT, subtitles и offline filter graphs | Полностью offline; arm64 binary нужно собирать и подписывать отдельно. VideoToolbox не ускоряет все filters | Хорош как subprocess/derived-media/export backend, но не как вторая live-preview truth | Использовать точечно. Зафиксировать configure flags, exact source и notices; не активировать GPL/nonfree без release decision |
| [MetalPetal](https://github.com/MetalPetal/MetalPetal) | MIT; examples имеют отдельную лицензию | Multi-input filter graph, custom Metal kernels, masks/blends, CVPixelBuffer и Core Image bridges, texture/cache optimization | Native macOS и Apple Silicon, полностью offline | Наиболее близок к текущему Swift + AVFoundation/Core Image pipeline | Лучший кандидат для P1. Сначала benchmark против custom Metal/Core Image на реальных 4K clips |
| [Lottie for Apple platforms](https://github.com/airbnb/lottie-ios) | Apache-2.0 | Compact vector motion presets, scrub/reverse/speed, runtime-editable keyframe values | Native macOS/Apple Silicon, offline при bundled JSON/assets | Хорош для titles/stickers/intro assets; требует адаптера из animation frame в compositor | Подходит для ограниченного curated motion asset layer, но не для общего video effects graph |
| Локальный `ThirdParty/OVRLEY` | GPL-3.0-or-later | Telemetry parsers, templates и специализированный Rust renderer | Уже работает offline и собирается для приложения | Интегрирован через локальный JSON/process boundary | Сохранять изоляцию, source bundle и обязательный GPL release checklist |

### Вывод по переиспользованию

- **Можно перенести как архитектурные идеи без runtime:** OpenCut registry/commands, Motion Canvas scene/preset semantics, Remotion deterministic template inputs.
- **Можно рассмотреть как зависимость:** MetalPetal и Lottie после отдельного dependency/security/license review.
- **Можно использовать как изолированный backend:** FFmpeg с контролируемой LGPL-конфигурацией и точным воспроизводимым build recipe.
- **Уже используется с сильным copyleft:** OVRLEY; его нельзя трактовать как обычный permissive asset.
- **Нельзя делать автоматически:** копировать filters/presets/code из любого проекта без provenance, license notice, dependency lock и visual equivalence tests.

## Целевая архитектура toolkit

### 1. Один реестр, несколько render backends

`Timeline` остаётся единственным источником правды. Новый toolkit не создаёт параллельный монтажный документ, а преобразует versioned preset в существующие timeline items и renderer plans.

```swift
struct ToolkitDescriptor {
    let id: ToolID                 // стабильный namespaced ID
    let version: Int               // миграции сохранённых проектов
    let kind: ToolkitKind
    let parameters: [ParameterSchema]
    let duration: DurationPolicy
    let intensity: IntensityPolicy?
    let easing: EasingPolicy
    let input: InputContract
    let output: OutputContract
    let backend: RenderBackend
    let preview: PreviewPolicy
    let cache: CachePolicy
    let editorial: EditorialPolicy
}

protocol Effect { static var descriptor: ToolkitDescriptor { get } }
protocol Transition { static var descriptor: ToolkitDescriptor { get } }
protocol MotionPreset { static var descriptor: ToolkitDescriptor { get } }
protocol TitlePreset { static var descriptor: ToolkitDescriptor { get } }
protocol CaptionPreset { static var descriptor: ToolkitDescriptor { get } }
protocol AudioEffectPreset { static var descriptor: ToolkitDescriptor { get } }
protocol TelemetryPreset { static var descriptor: ToolkitDescriptor { get } }
```

В коде уже существует `AudioEffect`; поэтому новый protocol лучше назвать `AudioEffectPreset`, а публичный продуктовый контракт продолжать показывать как **AudioEffect**. Переименование существующего enum без decoder adapters сломает проекты и не требуется.

### 2. Parameter schema

Поддерживаемые типы:

- scalar с default/min/max/step/unit;
- boolean;
- enum/choice;
- color с color-space policy;
- point/rect/transform;
- curve и keyframed scalar;
- text и localized text;
- asset reference с license/provenance;
- mask reference;
- subject/track reference.

Каждый параметр обязан иметь безопасный default и ограниченный диапазон. Renderer не должен принимать произвольный словарь неизвестных чисел без validation.

### 3. Input/output contract

`InputContract` описывает число video/audio inputs, наличие alpha, mask, depth/subject track, допустимые pixel formats, color spaces и минимальные handles вокруг cut.

`OutputContract` описывает alpha, изменённую duration, audio latency/tail, required crop/overscan, HDR support и возможность FCPXML representation. Если Final Cut не имеет точного native mapping, сохраняются editable intent metadata и rendered reference; выдуманный plug-in UID запрещён.

### 4. Renderer adapters

Предлагаемые backend IDs:

- `avFoundationTransform` — trim, retime, opacity, basic layer transforms;
- `coreImage` — существующие single-input color/blur/light filters;
- `metalGraph` — multi-input masks, mattes, tracked blur, luma/whip transitions;
- `coreAnimationText` — titles/captions и ограниченные Lottie overlays;
- `avAudioEngine` — EQ/reverb/delay/distortion и derived audio;
- `ovrleyProcess` — telemetry;
- `ffmpegProcess` — только разрешённые offline/export задачи.

`CapabilityResolver` до применения проверяет codec, alpha/HDR, hardware, proxy/full resolution и доступность backend. При отсутствии backend инструмент не должен молча превращаться в другой эффект.

### 5. Сохранение и миграции

Timeline item хранит:

- стабильный preset ID и version;
- значения только изменённых пользователем параметров;
- time range, intensity и easing;
- input references;
- `createdBy`: user / AI / imported;
- короткий editorial motive;
- backend capability snapshot только для diagnostics, не как источник правды.

Registry имеет deterministic migrations `v1 → v2`. Неизвестный preset сохраняется disabled и отображается как missing tool, а не удаляется при save.

## Как AI Director должен выбирать инструменты

### Обязательный decision contract

AI может добавить эффект только вместе с:

1. **Evidence** — что обнаружено в материале: смена времени/места, action peak, реплика, реакция, camera defect, telemetry event, user request.
2. **Editorial motive** — reveal information, bridge time/place, preserve continuity, emphasize emotion, clarify subject, repair technical problem или explicit style request.
3. **Budget** — сколько уже занято transitions/motion/text/light/SFX в соседнем диапазоне.
4. **Confidence** — ниже порога решение остаётся предложением/audition, а не применяется автоматически.
5. **Exit rule** — когда эффект заканчивается и почему.

### Guardrails против перегруза

- обычный cut — default; transition требует конкретного мотива;
- одновременно только один доминирующий motion cue;
- decorative light/particle эффект не назначается поверх важной реплики или реакции;
- text не дублирует очевидное изображение, кроме captions/accessibility;
- speed ramp не пересекает защищённый action/reaction moment без явной причины;
- SFX не добавляется по каждому cut или beat;
- music accents назначаются по structural boundaries, а не по каждому удару;
- toolkit score никогда не компенсирует потерю story/emotion/completeness;
- явное пользовательское «без переходов/эффектов» имеет абсолютный приоритет;
- для спорного решения создаются до трёх коротких auditions на ограниченном диапазоне, не три полных фильма.

### Связь с TOP 20 CHANGES

Toolkit обслуживает уже внедрённую монтажную логику:

- `CUT/HOLD/transition` остаётся явным boundary decision;
- five-phase moment и do-not-cut ranges ограничивают retime/effects;
- coverage plan и beat graph дают AI смысл, а не повод украсить каждый clip;
- reaction, eye-trace, shot scale и J/L bridges влияют на выбор и длительность инструмента;
- P6 проверяет unnecessary cuts, jump-cut risk, missing reactions/establishing и music overcut;
- effect/preset elegance имеет меньший вес, чем emotion/story/rhythm.

## Preview, cache и Apple Silicon

### Region-of-effect invalidation

Любое изменение вычисляет затронутый временной диапазон:

- effect — собственный range плюс temporal radius;
- transition — overlap и необходимые source handles двух clips;
- audio effect — range плюс tail/release;
- title/telemetry — собственный layer range;
- mask/track — только consumers конкретного track ID.

Пересчёт всего фильма из-за одного параметра запрещён. Dependency graph инвалидирует только downstream nodes в затронутом диапазоне.

### Cache key

Минимальный ключ:

`media fingerprint + source range + tool ID/version + normalized params + input track versions + frame time + render size + color space + quality tier`.

Derived media хранится отдельно от project truth и удаляется LRU-политикой. Cache miss никогда не меняет монтажное решение.

### Preview tiers

- interactive drag: proxy resolution, bounded temporal sampling, без expensive optical flow;
- paused preview: full frame качества preview;
- export: full resolution, deterministic settings;
- thumbnails/auditions: отдельный низкоприоритетный cache namespace.

Один renderer plan должен использоваться для preview и export, различается только quality tier. Это предотвращает ситуацию «в preview один эффект, в MP4 другой».

### GPU policy

- переиспользовать один `CIContext`/Metal context и texture pools;
- минимизировать `CVPixelBuffer ↔ CIImage ↔ CGImage` round-trips;
- объединять совместимые color operations в один graph/pass;
- multi-input effects выполнять в Metal, а не читать пиксели CPU;
- заранее компилировать shaders при launch/background warm-up;
- benchmark на реальных 1080p/4K/5K H.264/HEVC, включая длинный проект и thermal throttling;
- иметь deterministic Core Image/basic fallback только там, где визуальная семантика сохраняется.

## Приоритеты

### P0 — упорядочить уже работающий toolkit

1. Ввести `ToolkitDescriptor`, registry, parameter validation и stable versioned IDs.
2. Написать adapters для существующих `ClipEffect`, `TimelineEffectType`, `TransitionStyle`, titles, captions, audio и telemetry без миграции старых JSON на месте.
3. Унифицировать duration/intensity/easing/input/output/preview contracts.
4. Добавить editorial motive, `createdBy` и AI budget policy для любого автоматически созданного инструмента.
5. Ввести region-of-effect invalidation и cache keys.
6. Добавить capability diagnostics: preview/export/HDR/FCPXML/offline/backend available.
7. Дать существующим transition/effect controls один Inspector и одинаковую работу keyframes.
8. Добавить equal-power audio crossfade и room-tone bridge preset поверх существующего audio engine.
9. Создать SFX ingest/browser с license metadata; встроенные коммерчески неясные звуки не добавлять.
10. Покрыть registry migrations, renderer equivalence и «не перегружать» AI правила тестами.

### P1 — новый Metal compositing слой

1. Rectangle, ellipse и linear-gradient masks с feather/invert.
2. Mask combine: add/subtract/intersect и alpha/luma matte.
3. Track-to-mask binding с ручными correction points.
4. Subject/background blur на реальной маске.
5. Luma reveal и whip-pan transitions.
6. Halation/bloom-threshold light effect.
7. Общий overlay transform: anchor, scale, rotation, crop, opacity и blend mode.
8. Vector shape layer: rect/ellipse/line/path, fill/stroke и базовые keyframes.
9. Curated Lottie motion assets через изолированный adapter после dependency review.
10. Real-device 4K benchmarks и memory/thermal budgets до включения AI auto-use.

### P2 — тяжёлые и специализированные функции

1. Optical-flow slow motion и motion-compensated frame interpolation.
2. Multi-subject identity tracking, occlusion recovery и rotoscoping assist.
3. Particle emitter/simulation и style-specific animated backgrounds.
4. Nested compositions, reusable motion graphics templates и data binding.
5. 2.5D/3D camera, depth layers и parallax.
6. Advanced color: curves, wheels, HSL keys и scopes.
7. SFX semantic search и restrained event-driven auto-placement.
8. Optional FFmpeg derived-media backend с reproducible LGPL build.

## Первый пакет новых эффектов и переходов

Добавлять их следует после P0 registry, иначе раздвоение моделей станет хуже.

| ID | Тип | Параметры | Backend | Почему первым |
| --- | --- | --- | --- | --- |
| `transition.luma-reveal.v1` | Transition | duration, direction, softness, threshold curve, luma asset | Metal graph | Даёт профессиональный matte transition и проверяет multi-input/mask architecture |
| `transition.whip-pan.v1` | Transition | direction, duration, blur, overscan, easing | Metal graph | Полезен для мотивированного движения между совместимыми кадрами; не просто декор |
| `transition.blur-directional.v2` | Transition upgrade | angle, radius, opacity curve, duration | Core Image/Metal | Превращает существующий blur dissolve в полностью параметризованный preset |
| `effect.mask.shape.v1` | Effect utility | rect/ellipse/gradient, position, size, feather, invert, combine | Metal graph | Базовый primitive для blur, mattes, selective color и tracking |
| `effect.blur.subject-background.v1` | Effect | subject track, radius, edge refine, temporal smoothing, fallback | Metal graph | Реализует честный background blur и использует уже существующий tracking/reframe контекст |
| `effect.light.halation.v1` | Effect | threshold, radius, warm tint, mix, highlight protect | Metal/Core Image graph | Кинематографичный, но контролируемый эффект; легко ограничить budget |
| `effect.transform.camera2d.v2` | Motion preset upgrade | anchor, start/end transform, overscan, easing, motion blur | AVFoundation + compositor | Объединяет Ken Burns/pan/zoom/push без нового дублирующего enum |
| `audio.crossfade.equal-power.v1` | Audio effect | duration, curve, handles | AVAudioMix | Устраняет громкостную яму линейного crossfade и завершает audio-transition contract |

Автоматически AI может использовать только `camera2d`, restrained directional blur и audio crossfade. Luma reveal, whip-pan и halation по умолчанию требуют сильного motion/story evidence или явного стиля пользователя.

## Acceptance criteria

Инструмент считается готовым только если:

1. Имеет stable ID, version, typed parameters и migration test.
2. Сохраняется и повторно открывается без потери пользовательских значений.
3. Имеет одинаковую визуальную семантику в live preview и MP4 export.
4. Пересчитывает только затронутый диапазон.
5. Работает offline; network-only preset не может быть незаметным default.
6. Имеет Apple Silicon performance budget и тест хотя бы на 1080p и 4K.
7. Имеет declared color/HDR/alpha behavior.
8. Имеет понятный fallback или честно помечается unavailable.
9. Сохраняет ручное редактирование после AI применения.
10. AI решение содержит evidence, motive, confidence и budget check.
11. Не нарушает do-not-cut ranges, captions readability и audio intelligibility.
12. Любая сторонняя зависимость имеет locked version, license/notice, source provenance и release checklist.

## Лицензионные release gates

- OpenCut/Motion Canvas идеи можно реализовывать независимо; при переносе исходного фрагмента сохранить MIT notice.
- Remotion не включать в продукт без проверки актуального Company/Automator license и запрета на derivative resale.
- FFmpeg binary должен иметь сохранённый configure line, список enabled libraries, exact corresponding source и notices. `--enable-gpl`/`--enable-nonfree` — отдельное продуктово-юридическое решение.
- MetalPetal: проверить лицензию core и отдельно не переносить examples как будто они покрыты тем же разрешением.
- Lottie: сохранить Apache-2.0 notice и проверять лицензию каждого animation asset отдельно; лицензия player не даёт права на чужие JSON-анимации.
- OVRLEY: при conveyance предоставить corresponding GPL source, modifications и notices; текущий process boundary не отменяет обязанности дистрибьютора.

## Финальная рекомендация

Не нужно превращать VeloEdit в каталог из сотен «эффектов ради эффектов». Ближайшая качественная версия toolkit — это единый registry вокруг уже работающих функций, строгие AI-мотивы, локальная инвалидация и 6–8 тщательно сделанных новых Metal/audio primitives. Такой путь расширяет профессиональные возможности и не разрушает уже внедрённую логику истории, реакции, ритма, eye-trace и осмысленного CUT/HOLD.
