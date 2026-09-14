# Архитектура VeloEdit

## Поток данных

`Original → metadata/GPMF → adaptive key frames → candidate detection → P2 deep evidence → enriched directorCandidates → P4 Event Intelligence (Project → Event → Scene → Moment → Asset) → P3 ProjectStyle → P7 contextual PersonalTaste blend → event-first duration/story/grammar/music → style-space strategy search → diversity gate → parallel full production variants → music DSP/sync → P6 perceptual review → P7 personalized global score → event safety/weak gates → Pareto front → pairwise global tournament → Preview → Final Render/FCPXML`

P2 не создаёт отдельную модель selection: embeddings, semantic event, best take, subject tracks, speech, audio events и quality остаются optional-полями `CandidateInsights`, а temporal phases — `Candidate.momentBoundary`. `DeepAnalysisCache` сохраняет дорогие evidence по content hash, `FrameCache` переиспользует один decode между Vision/VLM/scoring, `MusicStructureCache` — один DSP decode трека. Перед P4 `SourceTimelineAnalyzer` через универсальный `SourceSequenceDetector` восстанавливает порядок исходников и соседние activity groups, сохраняя explainable `SourceMap` с confidence; реальные embedded timestamps остаются выше sequence ID, а file/import dates могут быть исправлены последовательностью камеры. P4 агрегирует эту карту вместе с capture date/timezone/GPS/GPMF/device/visual/audio evidence в persisted `Event`/`EventScene`; идентификаторы hierarchy детерминированы. P3 и P4 проходят через существующие Story/Composer/Director/scoring stages, а не создают параллельную монтажную систему. Подробности: `P2_DEEP_MEDIA_UNDERSTANDING.md`, `P3_AUTONOMOUS_TASTE_STYLE.md` и `P4_EVENT_INTELLIGENCE.md`.

Ветка совместимости: `Timeline -> editable FCPXML`; если intent нельзя выразить штатным FCPXML без выдуманного plug-in UID, параллельно выполняется `Timeline -> RenderEngine -> rendered-reference.mp4 -> второй FCPXML project`.

## Модули

- **FilmEndingFade / PhotoPresentationPolicy** — новые автоматические Timeline сохраняют `endingFadeDuration = 1`; старые проекты без поля не меняются. Затемнение работает на фактическом времени композиции после перекрытий и применяется после всех визуальных слоёв. Последний кадр чёрный без увеличения длительности, намеренное затемнение учитывается при проверке кадров. Фото получают 6 секунд и медленный zoom-in на 5%; ручные панорамы остаются отдельными эффектами.
- **VeloEditCore/Models** — versioned Codable-типы, не зависящие от UI и AI runtime.
- **VeloEditCore/Storage** — пакет проекта, атомарные manifest writes, derived-media cache.
- **VeloEditCore/Media** — импорт, metadata, thumbnails, proxy и AVFoundation render.
- **VeloEditCore/Analysis** — локальные эвристики, расширяемые протоколами моделей.
- **VeloEditCore/Event Intelligence** — cross-device time normalization, multimodal event clustering, scenes, titles и EventQuality.
- **VeloEditCore/Story** — prompt constraints, presets, diversity selection, feedback.
- **VeloEditCore/AI Director** — автономные монтажные решения, bounded self-review и re-edit.
- **VeloEditCore/Editing Tools** — закрытый типизированный API структурных, визуальных и звуковых операций.
- **VeloEditCore/Timeline** — композиция и timecode.
- **VeloEditCore/Editor commands** — детерминированный parser/executor команд естественного языка поверх versioned Timeline.
- **VeloEditCore/Playback** — transform-aware `AVComposition` для мгновенного просмотра без экспорта.
- **VeloEditCore/FCPXML** — capability-aware exporter и validation.
- **VeloEdit** — только SwiftUI presentation/orchestration.
- **veloedit-cli** — headless smoke/integration workflow и диагностика.

Главное окно после получения статуса key window занимает `visibleFrame` текущего экрана: так восстановление сцены SwiftUI не перезаписывает стартовый размер, меню и Dock остаются доступны, системный fullscreen не включается, а последующее изменение размера не ограничивается.

## Границы

Core не импортирует SwiftUI/AppKit. Анализ возвращает данные, а не меняет timeline. Story Engine потребляет только модели. Renderer и FCPXML получают один и тот же `Timeline`, поэтому preview и монтаж для Final Cut остаются согласованы.

## P5: интерактивность и production consistency

Высокочастотные ручные правки проходят `TimelineMutationEngine → local @Published Timeline → debounced commit/preview`. Они не выполняют media decode или manifest serialization до первого визуального ответа. `TimelineInvalidationPlanner` отличает structural source changes от effects/title/telemetry/audio layers. Preview строится из переданного immutable Timeline snapshot в interactive resolution; сохранённая Timeline и final render остаются полноразмерными.

`ProjectStore` выдаёт revision snapshot для долгих операций. AI create/regenerate коммитится compare-and-swap; optimistic editor commit использует отдельную монотонную client revision. Эти механизмы защищают разные классы гонок и не заменяют друг друга. Photo/title preview intermediates имеют content-derived identity, атомарно публикуются и переиспользуются. Последний валидный poster живёт до готовности нового item, а реально декодированные кадры проходят luma/uniformity check. Детали и ограничения: `P5_PRODUCTION_HARDENING.md`, `PRODUCTION_AUDIT.md`.

Настройки iMovie-класса принадлежат `TimelineItem`, а не UI или ответу language model. `storyRole`, `editorialPurpose`, `videoAdjustments`, `audioAdjustments`, `titleStyle`, `overlay`, `freezeFrame`, `reversePlayback`, `speedRamp` и `telemetryOverlay` optional при декодировании; расширенные поля stabilization/sharpening/denoise/blur/exposure/noise/EQ также optional. Старые project packages получают нейтральные effective-значения без миграции и потери монтажа.

Исполнение запроса идёт двумя параллельными семантическими путями: language model формирует человеческий ответ и режиссёрский brief, а `EditorCommandParser` превращает исходную фразу в типизированные операции. `EditorCommandExecutor` применяет их к `all/selected/first/last/number(N)`, пересчитывает timeline starts и возвращает `EditorCommandReport`. Только этот отчёт используется для фразы «выполнено».

Многосоставной запрос режется по границам команд. Явная цель обновляет контекст, поэтому «ускорь второй клип, сделай его ч/б, убери у него звук» применяет три операции ко второму клипу; следующий явно названный клип меняет цель. Это не зависит от формулировки LLM.

Полная сборка идёт через `SourceTimelineAnalyzer → EventIntelligenceEngine → StoryEngine.createPlanVariantSearch → VariantDistanceCalculator → TimelineComposer → music analysis/sync → AIDirectorEngine → MontageVariantSelector`. При доступных events Story Engine сначала выбирает/упорядочивает события и распределяет их duration, затем выбирает scenes/moments на едином `directorCandidates` projection; порядок источников и границы activity groups уже зафиксированы Source Map. До восемнадцати контекстных стратегий перебираются, пока не найдено до десяти rough cuts с минимальной общей дистанцией; учитываются candidate Jaccard, source-range overlap, semantic similarity, order и rhythm. Каждый принятый rough cut независимо проходит весь production path параллельно, включая music sync, AIDirectorEngine и transactional self-review. Финальный selector повторяет diversity gate уже на directed timelines и отбрасывает явно слабые монтажи до турнира.

`MontageGlobalScoring` оценивает highlight quality, material-dependent story arc, emotional curve, ProjectStyle/PersonalTaste fit, pacing, asset/semantic/source diversity, duration, movement/shot-scale/composition/exposure continuity, rhythm, moment completeness, subject visibility/reframe safety, speech/audio-event/original-audio continuity, technical/visual-semantic quality, measured music structure, confidence-weighted drop–climax alignment, event order/diversity/coverage/chronology, scene diversity и inter-event repetition. `MontageScoringFeatures` один раз строит immutable indexes кандидатов/assets для всех вариантов. P7 затем добавляет bounded combined layer `global + technical + contextual + perceptual + taste`; taste получает не более 16% по confidence и не может обойти hard quality. После safety/quality gates `MontageParetoAnalyzer` удаляет multi-objective dominated cuts, затем `MontagePairwiseComparator` сравнивает каждую пару front-вариантов. Победитель определяется без пользовательского A/B-выбора. `DirectorRunSummary` сохраняет P1 variant diagnostics, P2 deep diagnostics, P3 autonomous/Pareto decisions, P4 event diagnostics, P6 findings и P7 taste/regression diagnostics.

## P7: adaptive personal taste

`AdaptivePreferenceSignalExtractor` расширяет существующий P3 extractor и получает anonymous evidence из реальной разницы AI Timeline и принятой Timeline. `PreferenceLearningEngine` одним проходом обновляет legacy estimates и `AdaptiveTasteEstimate`, поэтому старые проекты и новые scoring paths используют одну память. `TasteContextResolver` разделяет activity/project/event/camera/format/duration contexts; `TasteEmbeddingProfile` хранит только positive/negative centroids и broad tokens.

`LocalPersonalTasteStore.recordValidated` строит proposed profile на копии и пропускает его через `TasteRegressionGuard`. Regression samples автоматически состоят из aggregate Timeline features и P1/P6 scores — human rating/Golden Corpus отсутствуют. После commit профиль атомарно записывается локально. `AutonomousDirectorEngine` применяет contextual style, duration, grammar, BPM и deterministic 90/10 explore; `MontageVariantSelector` применяет `PersonalizedMontageScorer` до Pareto/pairwise selection. Полная схема, privacy contract и confidence calibration описаны в `P7_ADAPTIVE_TASTE.md`.

Режиссёр видит semantic role каждого клипа, результаты анализа, музыку и телеметрию, но изменяет монтаж только через `DirectorToolCall`. `DirectorEditingTools` валидирует ID, source ranges, locks и безопасные пределы; произвольный код от модели не исполняется. `TimelineSelfReviewer` проверяет открытие, кульминацию, повторы, технически слабые кадры, длину, плотность, баланс action и переходы. Repair calls проверяются одиночно и bounded-парами; лучший beam коммитится только при росте combined global/review score. `TimelineSafetyValidator` запрещает пустой/gapped Timeline, выход за source ranges, потерю story arc, чрезмерное сокращение и удаление/изменение locked clips. Цикл ограничен двумя успешными re-edit итерациями.

`MomentPhaseTrimmer` используется и rough composer, и Director repair: короткий range строится вокруг `MomentBoundary.peakTime` и сохраняет минимальные anticipation/reaction handles, если исходник их содержит.

## P6: Perceptual Editor

После legacy `TimelineSelfReviewer` каждый направленный вариант проходит отдельный `PerceptualMontageReviewer`. Он не подменяет `MontageGlobalScore`: создаёт `PerceptualScore`, `CutQualityScore` для каждой соседней пары и структурированные `PerceptualFinding` на уровнях Film/Event/Scene/Shot/Cut. Review потребляет тот же enriched `directorCandidates` projection, P2 subject/speech/audio/moment evidence, P3 grammar/style, P4 event context и music structure.

Уверенные findings превращаются в существующие `DirectorToolCall`. `PerceptualReviewEngine` проверяет single и bounded pair beams на копиях Timeline. `PerceptualReviewTransaction` требует роста combined `GlobalScore + PerceptualScore`, пустого результата `TimelineSafetyValidator`, отсутствия новых critical defects и регрессии moment/technical quality. Replacement не может молча удалить уже мотивированный stabilization/reframe/audio/retime/telemetry treatment. Только лучший beam коммитится; остальные учитываются как rollback.

После automatic global/pairwise tournament только winner получает render-aware pass: `PlaybackEngine` строит реальную `AVComposition` с compositor, а `PerceptualRenderInspector` декодирует bounded cut/effect/title/telemetry/film samples, используя P5 derived-media cache. Black/uniform кадры проверяются `FrameQualityInspector`, frozen repetition — perceptual hash; фото и намеренный freeze исключены. Принятый render-grounded repair допускает одну повторную сборку для verification. Это сохраняет стоимость `O(variants × metadata review + one final selective preview)`, а не превращает P6 в несколько полных экспортов.

`DirectorRunSummary` сохраняет отдельные perceptual iterations/findings/high severity/repair accepted-rejected/rollback/before-after score и полный `PerceptualReviewSummary`. Все поля optional и backward compatible. Детали: `PERCEPTUAL_REVIEW.md`.

Перед полной пересборкой, AI-командой и локальной «Волшебной кистью» `VeloEditPipeline` сохраняет полный `TimelineCheckpoint`. Версии получают имена `AI Edit 01`, `AI Edit 02` и могут быть восстановлены; существующий Undo/Redo использует те же полные снимки Timeline.

Длительные операции публикуют `ImportProgress`, который UI отображает как стадию, текущий файл и долю выполнения. При создании фильма локальные callback-прогрессы отображаются в выделенные диапазоны общей шкалы: понимание брифа `0–10%`, анализ `10–60%`, Story Engine `60–78%`, playback `78–100%`. Поэтому процент монотонен и не сбрасывается между внутренними операциями.

Импорт аналогично отображает metadata/indexing в `0–70%` и thumbnails в `70–100%`. Карточка готовности переводит импорт в первые 15% готовности фильма, а отдельный анализ — в следующие 50%, так что пользователь видит изменение одного и того же показателя ещё до запуска монтажа.

Диалог режиссёра имеет отдельные task/status state и не использует блокировку media pipeline. Пользователь может получать ответы, пока импорт, анализ или thumbnail generation продолжаются. Конфликтующие операции монтажа по-прежнему сериализуются.

Каждая правка увеличивает `directorRevision`. Сборка фиксирует снимок ревизии и очищает pending-state только после успешного `StoryPlan -> Timeline -> TimelinePlayback`. Если во время сборки приходит новое сообщение, оно остаётся неприменённым и не теряется.

`FilmReadinessCalculator` считает готовность из фактов: материалы 15%, актуальный анализ 50%, текущий монтаж 25%, текущий playback 10%. При pending-правках старые montage/playback не учитываются; во время сборки карточка показывает реальный монотонный progress pipeline.

Завершение анализа сохраняется как отдельное presentation-состояние: UI показывает постоянное подтверждение до явного закрытия или следующего изменения медиатеки. Доступность анализа вычисляется по `assetID`, content hash и версии схемы, поэтому кнопка отличает актуальный кэш от материалов, требующих обработки.

Пустые состояния занимают всю доступную ширину detail-области и используют те же горизонтальные поля, что и Timeline, чтобы layout не смещался к sidebar.

После режиссуры один `Timeline` питает три выхода: живой `AVPlayerItem`, passthrough/encoded MP4 и FCPXML. Просмотр собирает ссылки на исходные диапазоны и не ждёт перекодирования. Thumbnails создаются отдельно с AVFoundation и Quick Look fallback и используются в sidebar, медиатеке и timeline.

Для однородных camera sources 4K+ без motion/color/transition/overlay/telemetry playback использует нативный transform общей composition track. Любой визуальный intent отключает fast path и включает `AVVideoComposition`, поэтому transition не может молча исчезнуть из просмотра. Это сохраняет обход чёрного кадра MediaToolbox для нетронутых больших GoPro HEVC файлов и корректность для отредактированных.

При цветовой коррекции включается `VeloVideoCompositor`: Core Image обрабатывает только текущие кадры в памяти, применяет filter/brightness/contrast/saturation/temperature/exposure/highlight-shadow/vignette/grain, затем geometry, opacity, motion и transition. Blur/light transitions и telemetry overlay исполняются в том же compositor. Предварительный видеотранскод не блокирует просмотр.

Основные клипы ретаймятся последовательно, а overlay-клип получает диапазон `baseItemID`. Playback использует до четырёх video/audio tracks и compositor смешивает cutaway, PiP, split screen или chroma-key слой в тот же временной диапазон; overlay не увеличивает длительность фильма. Stop frame растягивает один исходный кадр, reverse собирает диапазон в обратном порядке, а instant replay создаёт отдельную замедленную копию — поэтому эти операции видны на Timeline и воспроизводятся тем же AVComposition, что идёт в MP4.

Variable speed хранится как нормализованные `SpeedRampPoint`. Builder режет source range на соседние сегменты, масштабирует каждый по средней скорости и нормализует к duration клипа. Та же модель экспортируется в FCPXML как multi-point `timeMap`, поэтому ramp остаётся редактируемым.

Gain/fade/crossfade выполняет `AVAudioMix`. Automatic ducking меняет громкость музыки, а не исходника: attack/release ramps строятся вокруг активных source-audio ranges. Noise reduction и EQ требуют реальных samples, поэтому `ProcessedAudioGenerator` извлекает только диапазон клипа, выполняет offline AVAudioEngine EQ/high-pass/low-pass pass в disposable CAF и передаёт его тому же playback/render builder. Оригинал не открывается на запись.

Музыка поступает через документированный `FreeToUseMusicProvider` и сохраняется в `LocalMusicLibrary`: файл и `tracks.json` лежат в Application Support, а `MusicDirective` хранит конкретный `trackID`. Провайдер ищет только через официальный API v3, исключает premium assets и принимает MP3 только с `data.freetouse.com`. Legacy `LocalMusicSelector` ранжирует по genre/mood, BPM и energy; P3 `AutonomousMusicTrackScorer` дополнительно использует measured editability, duration coverage, section/drop structure и сходство energy curve с narrative arc. `MusicBeatSynchronizer` привязывает границы к confidence-aware musical anchors. Playback и RenderEngine читают только уже проверенный локальный файл и не зависят от сети.

Title items получают реальный видеодиапазон и timed Core Animation layers с фоном и текстом. Они входят в `renderedItemCount`, длительность фильма и общий `AVVideoComposition`, поэтому live preview и MP4 видят один титр.

Story diversity ограничивает долю одного исходника, но не считает технические теги вроде `4K` и `horizontal` самостоятельными сценами. Это сохраняет разнообразие без потери десятков кандидатов одного формата камеры.

Число моментов из естественного запроса сохраняется в `StoryConstraints.targetClipCount`. Story Engine останавливает подбор на этом числе; поэтому «из 3 моментов» — исполняемый инвариант, а не декоративный текст для чата.

Фото renderer превращает изображение в короткий H.264 intermediate без генерации отсутствующих областей. Motion задаётся отдельно: Ken Burns, pan, zoom, push-in/pull-out; обычное фото получает спокойный Ken Burns default. Multi-photo sequence остаётся последовательностью clips, а layout — реальным split/PiP overlay с общей временной базой.

GPMF extractor читает metadata sample buffers, parser сохраняет границы `STRM`, применяет `SCAL` к GPS5/ACCL и вычисляет route, speed, altitude, distance и G-force. `TelemetryOverlayRenderer` интерполирует samples по progress клипа и рисует HUD/route в compositor. Если данных нет, overlay не выдумывает значения и остаётся прозрачным.

## Хранилище

Проект — directory package `<name>.veloedit` с `project.json`, `Cache/Thumbnails`, `Cache/Proxies`, `Cache/Preview`, `Exports` и `Logs`. Manifest использует номера версий схем. Запись выполняется через временный файл и replace/move. Оригинальные URL и security-scoped bookmarks хранятся отдельно от производных файлов.

Расширение `.veloedit` остаётся внутренним идентификатором типа пакета, но UI предлагает только название проекта и устанавливает `hasHiddenExtension`, поэтому пользователь видит обычное имя.

Последние 12 нормализованных URL проектов сохраняются в `UserDefaults` отдельно от project package. Создание или открытие поднимает URL в начало списка; отсутствующий путь помечается в welcome UI и удаляется после неудачной попытки открытия либо по команде пользователя.

Fast path импорта не копирует оригинал и не создаёт прокси. Идентификатор строится по размеру, времени изменения и двум блокам содержимого до 64 KiB с каждого края. Полный SHA-256 доступен как отдельная проверка целостности, а прокси автоматически создаётся при первом анализе либо по явной команде.

## Производительность

Архив не загружается целиком в память. Импорт читает ограниченный fingerprint, полные хеши считаются потоково только при явной проверке. При анализе GPMF читается только из metadata track оригинала, затем автоматически создаётся переиспользуемый 720p proxy. Кадры для AI декодируются из proxy; оригинальные video tracks снова используются только playback/final render/FCPXML.

`AdaptiveFrameSampler` сначала берёт разреженную сетку кадров, считает дешёвые признаки движения, экспозиции и детализации, выделяет разнесённые по времени пики и только вокруг них добавляет плотную выборку. Apple Vision даёт быстрые локальные scene labels. Qwen3-VL, если соответствующая модель доступна в Ollama, получает ограниченные группы JPEG лучших кандидатов, а не исходный 4K/5.3K/8K файл. Его оценки смешиваются с измеренными признаками, после чего Story Engine работает с обычными `Candidate`.

Независимые directed variants исполняются через task group с сохранением исходного порядка. Общая музыкальная структура защищена in-flight cache: параллельные варианты одного track ждут один decode, а cache key учитывает UUID, путь, BPM, duration, file size и modification date.

`MomentBoundaryRefiner` объединяет временные visual motion/interest/semantic сигналы, audio onset и telemetry, локализует peak, затем идёт назад до anticipation и вперёд до completion/reaction. Полученный `MomentBoundary` сохраняется в Candidate как backward-compatible evidence; fallback остаётся ограниченным окном, если временных сигналов мало.

`ThermalAwareScheduler` и `AIAnalysisProfile.resolve` учитывают `ProcessInfo.thermalState`, Low Power Mode и unified memory. На `serious` снижаются разрешение proxy-кадра, число кадров и кандидатов; на `critical` глубокий VLM inference пропускается до охлаждения, но metadata/adaptive pass сохраняет полезный результат. На MacBook Air тяжёлые VLM-вызовы всегда сериализованы.

Cache key включает content fingerprint, analysis schema и выбранный AI profile/model/quantization. Временное thermal throttling не меняет identity кэша, поэтому остывший Mac не запускает бесконечный повтор анализа.

## Расширяемость AI

`VisionModelProtocol`, `EmbeddingModelProtocol`, `AudioModelProtocol` и `LanguageDirectorProtocol` допускают замену локального runtime. Встроенные deterministic heuristics обеспечивают рабочий offline fallback; ни один provider не получает пользовательские данные без отдельного opt-in.

`LocalDirectorAgent` сначала обращается к локальной instruction-модели `qwen3:4b-instruct` через loopback API Ollama. Ответ ограничен JSON Schema с двумя строками: естественной репликой и `normalizedBrief`. Нормализация заменяет исходное pending-пожелание только если parser извлёк из неё больше исполняемых операций; иначе применяется исходная фраза. Это позволяет модели раскрывать разговорные формулировки и одновременно исключает повторное применение rotate/freeze/duplicate. Точные числа дополнительно извлекаются детерминированным parser-ом. App target также weak-link'ит `FoundationModels` как вторичный provider на macOS 26. Последний уровень — `DirectorFallbackReply`, который UI явно маркирует как «не нейросеть».

Всем provider-ам передаётся только `DirectorContext` — количество и тип материалов, готовность анализа, число кандидатов, стиль, длительность и текущая операция — плюс текст пользователя. Файлы, URL, кадры и звук в language session не передаются.

### AI-мощность

Пользователь выбирает намерение, а не размер модели. Значение хранится в `UserPreferences`; старые проекты без поля получают `.balanced`.

| Режим | VLM по умолчанию | Выборка | Глубоких кандидатов | Политика |
|---|---|---:|---:|---|
| ⚡ Быстро | Qwen3-VL 2B, 4-bit | 12 с / 2 с | 4 × 3 кадра | минимальный нагрев |
| ⚖️ Баланс | Qwen3-VL 4B, 4-bit | 7 с / 1 с | 8 × 5 кадров | default для M4 Air |
| 🧠 Качество | Qwen3-VL 8B, 4-bit | 4 с / 0,67 с | 12 × 8 кадров | один VLM job |
| 🎬 Максимум | Qwen3-VL 30B-A3B 4-bit при ≥32 GB; иначе 8B 8-bit | 2,5 с / 0,4 с | 18 × 12 кадров | thinking, без спешки |

Операционный runtime текущей сборки — локальный Ollama loopback; он работает полностью offline после `ollama pull`. Предпочтительный нативный Apple-Silicon backend — `mlx-swift-lm/MLXVLM`: он поддерживает `qwen3_vl`, Metal и unified memory и не требует отдельного daemon. Контракт runtime и MLX model IDs уже отделены от профилей и доступны в Advanced Settings. До включения MLXVLM package в release-сборку принудительный MLX корректно деградирует в Apple Vision, а UI/analysis warnings не выдают fallback за Qwen.

Основной VLM выбран после сравнения Qwen3-VL, FastVLM, Gemma 3 и SmolVLM. Qwen3-VL лучше соответствует задаче длинного видео и temporal/timestamp reasoning. FastVLM остаётся кандидатом на сверхбыстрый first pass, Gemma 3 — сильной image alternative, SmolVLM — минимальным вариантом для устройств с малой памятью. Первый pass VeloEdit пока быстрее и предсказуемее выполняет измерениями + Apple Vision, поэтому большая VLM тратится только на короткий список моментов.

Advanced Settings разрешает выбрать runtime, точный model ID и 4/8/16-bit quantization. Ручные параметры меняют analysis cache key. Ни один режим не использует cloud API и не загружает модель без явного действия пользователя.

## Проверенные границы текущей версии

Собираются Core, CLI и SwiftUI targets; project/story/GPMF/FCPXML paths покрыты тестами. Реальный GoPro smoke подтверждает multi-source playback и video-only passthrough MP4. FCPXML проходит XML/semantic assertions, но реальный Final Cut import требует установленного Final Cut. Photo intermediate и принудительное 1080p/4K перекодирование всё ещё требуют проверки из подписанного app host.
