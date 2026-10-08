# VeloEdit — план реализации

## P5 — Production Hardening (реализовано в коде)

- [x] Revision-safe background transactions и stale analysis guard.
- [x] Optimistic Timeline mutation/persist/preview path без изменения UI.
- [x] Interactive preview resolution и persistent photo/title derived cache.
- [x] Bounded frame/deep/music caches и disk pruning.
- [x] Poster preservation, black-frame inspection и nearby-frame recovery.
- [x] Production-path, stress и cache reuse tests.
- [x] [архив: PRODUCTION_AUDIT.md](https://github.com/007danlin/VeloEdit/blob/8646d9df96b31e13cb411fcb6da8ad9be73ade22/PRODUCTION_AUDIT.md) с root cause → fix → verification.
- [ ] Release gate: XCUITest/Instruments на подписанном app и physical 300-video/500-photo corpus.
- [ ] Release gate: многочасовой soak и cross-version visual regression.

Обновлено: 2026-08-24. Источники требований: ТЗ 1.0, дополнение «AI-мощность», `2weew.docx` (AI Director 2.0), `ТЗ2.docx` (OpenCut-inspired timeline effects/titles/music sync) и `Тз3.docx` (P4 Event Intelligence / AI Memory Timeline).

## Цель

Создать нативное offline-first приложение для Apple Silicon, которое не меняет оригиналы, индексирует фото/видео, повторно использует анализ, строит редактируемый монтаж по свободному запросу, создаёт preview/MP4 и экспортирует исходные диапазоны в FCPXML.

## Инварианты

- Оригиналы только читаются; производные данные находятся внутри пакета проекта.
- UI, анализ, режиссура, timeline, renderer и FCPXML связаны только через versioned Codable-модели.
- Генеративное изменение содержания отсутствует и не может включиться неявно.
- Повторная режиссура не запускает повторный анализ неизменившихся файлов.
- Locked-фрагменты сохраняются при regenerate.
- Тяжёлые операции выполняются последовательно или с ограниченной конкуренцией, чтобы не перегревать MacBook Air.

## Этапы и критерии выхода

### 0. Foundation

- Swift Package с отдельными Core, macOS App и CLI targets.
- Документы: README, TODO, CHANGELOG, ARCHITECTURE и тематические руководства.
- Критерий: package graph успешно разбирается.

Статус: выполнено.

### 1. Media foundation

- `MediaAsset`, versioned project manifest, атомарное локальное хранилище.
- Импорт URL без копирования оригинала, security-scoped bookmark, SHA-256, AVFoundation/ImageIO metadata.
- Thumbnail/proxy cache с устойчивыми ключами.
- Критерий: unit/integration tests и `swift build` проходят.

Статус: выполнено.

Оптимизация импорта: выполнено. Блокирующие полное хеширование и генерация прокси исключены из fast path; добавлены bounded fingerprint, ограниченный параллелизм и отдельная проверка целостности.

UX фоновой работы: выполнено. Пользователь видит текущую фазу/файл/счётчик и может параллельно формулировать запрос AI-режиссёру.

Диалог AI-режиссёра: выполнено. Основной runtime — локальная Qwen3 4B Instruct через Ollama, поэтому Apple Intelligence не требуется. Модель отвечает по-русски и получает только сводный контекст проекта, без кадров и путей. Foundation Models остаётся вторичным provider-ом, а детерминированный fallback явно помечен в UI как «не нейросеть».

Именование проекта: выполнено. Диалог и Finder показывают простое имя без служебного расширения пакета.

Недавние проекты: выполнено. Welcome screen и File menu используют единый persistent MRU-список с максимумом 12 элементов.

Выравнивание empty state: выполнено. Блок импорта центрирован относительно detail-области и Timeline.

### 2. Local intelligence and direction

- Многофрагментные кандидаты, quality/interest/action scoring, события.
- Presets, prompt constraints, content diversity, locked/excluded clips.
- Smart rebuild: `StoryPlan -> Timeline`, без повторного анализа.
- Критерий: детерминированные тесты режиссуры и feedback проходят.

Статус: выполнено. Реальный on-device language runtime подключён через Ollama/Qwen3, provider contracts сохранены, а точные ограничения вроде «ровно 3 момента» дублируются типизированными Story Constraints.

Регрессия multi-clip устранена: технические теги камеры не участвуют в отсечении повторов, введён мягкий лимит доли одного исходника и покрыты короткие target durations.

AI Director 2.0 выполнен: `CandidateInsights` хранит семантические/технические оценки, Story Plan имеет явные роли и цели, единый `DirectorEditingTools` предоставляет структурные/визуальные/звуковые операции, а `AIDirectorEngine` принимает контекстные решения и делает bounded self-review/re-edit. Переменная длительность, повторное использование исходника, B-roll, slow motion/speed ramp, стабилизация, telemetry, original audio/ducking и музыкальные секции проверяются тестами.

### 3. Media output and interoperability

- AVFoundation proxy/preview/final export.
- GPMF KLV parser и telemetry summary.
- Валидируемый FCPXML с оригинальными URL/source ranges, edit/selects variants.
- 10 FCPXML fixtures из ТЗ.
- Критерий: XML parse/semantic tests, timecode/GPMF/render-plan tests проходят.

Статус: выполнен. AVFoundation читает `gpmd` sample buffers, GPMF parser применяет `SCAL` к GPS5/ACCL и сохраняет route/speed/altitude/distance/G-force time-series summary. Реальный import в установленный Final Cut остаётся external release gate.

Живой playback и video-only passthrough MP4 проверены на реальных GoPro HEVC исходниках; просмотр не требует предварительного рендера.

Black-preview regression: выполнено. Однородные camera sources идут через проверенный `native-track` playback, смешанные ориентации сохраняют per-clip transform path.

### 4. Native macOS workflow

- SwiftUI NavigationSplitView, drag-and-drop, импорт, прогресс, prompt/presets.
- Preview player, простой iMovie-style timeline, lock/exclude/favorite, regenerate.
- MP4/FCPXML export, diagnostics, missing-media reporting.
- Критерий: app target собирается, CLI smoke workflow проходит.

Статус: выполнено; ad-hoc signed `.app` собран.

Медиатека показывает реальные кадры и позволяет проигрывать выбранный исходник; готовый монтаж автоматически открывается в отдельной области просмотра с системными controls и fullscreen.

Режиссёрская область стала рабочим чатом: пользователь получает ответ и может продолжать переписку во время импорта/анализа. Постоянная карточка показывает общий процент и четыре стадии `Медиа → Анализ → Монтаж → Просмотр`; создание фильма использует взвешенный сквозной прогресс без сброса на каждой внутренней операции.

Применение правок режиссёра: выполнено. Новый бриф помечает старую сборку как неактуальную; «Применить правки» пересобирает StoryPlan/Timeline без повторного анализа, заменяет playback и возвращает 100% только после готовности нового просмотра.

### 5. Hardening and delivery

- Thermal-aware scheduler, resumable jobs, cache reuse, bounded memory.
- `.app` packaging script; signing/notarization/DMG hooks без фиктивных credentials.
- Полный прогон tests/build и сверка документации с фактическими возможностями.

Статус: текущая итерация выполнена. Оставшиеся production-hardening задачи перечислены в `Docs/Planning/roadmap.md`.

## После текущей итерации

### 6. iMovie-class editor by request

- Зафиксировать `Docs/Planning/imovie-baseline.md` и единый инвариант AI-исполнения.
- Расширить Timeline без поломки старых проектов: кадр, цвет, скорость, клиповый звук и титры.
- Преобразовывать русские команды в typed operations и применять их к выбранному/первому/последнему/номерному/всем клипам.
- Обеспечить одинаковый результат в live preview, MP4 и переносимое намерение в FCPXML.
- Добавить ручной инспектор тех же параметров, тесты parser/executor и media E2E.

Статус: этапы 6.1–6.6 выполнены: model, multi-clause command executor, live/MP4 execution, inspector, FCPXML intent mapping, многослойный compositor, freeze/reverse, instant replay, auto enhance и расширенное оформление титров. Qwen использует строгую JSON-схему; её нормализация подменяет исходную фразу только если распознаёт больше исполняемых действий, поэтому модель расширяет понимание, но не дублирует команды.

Offline audio-processing для базового noise reduction/EQ выполнен через производный PCM intermediate; preview и MP4 используют один `PlaybackEngine`. Стабилизация, rolling-shutter safety crop и сглаживание slow motion исполняются общим compositor. Следующий тяжёлый этап — spectral/ML denoise и расширенная валидация motion transforms на реальном корпусе камер.

Пункты, зависящие от внешних лицензированных моделей, реального большого архива, сертификата Apple Developer и установленного Final Cut Pro, остаются проверяемыми integration gates. Каркас обязан давать рабочий локальный fallback без облака и без модели.

### 7. AI power + proxy-first adaptive intelligence

- [x] Добавить четыре понятных режима без ручного выбора размера модели; `Баланс` — default.
- [x] Сохранить режим и optional Advanced runtime/model/quantization в project manifest с backward-compatible decoding.
- [x] Привязать режим к разрешению кадров, sparse/dense интервалам, числу кандидатов, кадров на кандидат и модели Qwen3-VL.
- [x] Реализовать `Original metadata/GPMF -> cached 720p proxy -> adaptive samples` до любого тяжёлого vision inference.
- [x] Вычислять движение/экспозицию/детализацию на coarse pass, плотнее декодировать только временные пики и классифицировать их Apple Vision.
- [x] Передавать локальной Qwen3-VL через Ollama только несколько кадров лучших кандидатов и смешивать её JSON-оценки с измеренными признаками.
- [x] Использовать original URL только для metadata/GPMF, playback, final render и FCPXML.
- [x] При смене профиля инвалидировать analysis cache, не уничтожая Timeline и производные данные.
- [x] Ограничить VLM одним job на пассивно охлаждаемом Mac; на serious уменьшать выборку, на critical пропускать deep pass, учитывать Low Power Mode.
- [x] Показывать в Director UI выбранную мощность, runtime, thermal status, число sampled frames и deep candidates.
- [x] Добавить Advanced Settings для runtime/model/quantization и честный локальный fallback.
- [x] Сравнить Qwen3-VL с FastVLM, Gemma 3 и SmolVLM; зафиксировать Qwen3-VL как основной video VLM.
- [ ] Подключить `mlx-swift-lm/MLXVLM` непосредственно в release target после стабилизации его SwiftPM packaging; контракт и model catalog готовы, рабочий runtime сейчас Ollama.
- [x] Добавить встроенный Ollama model downloader с потоковым прогрессом и автоматическим запуском локального daemon.
- [ ] Добавить предварительную проверку свободного места, checksum manifest и resume UI для оборванной загрузки MLX-весов.

Критерий текущего выхода: 53 tests, Core/CLI/App build, profile persistence, proxy-first adaptive analysis и реальный локальный Qwen3-VL request path проходят. Отсутствующая vision-модель не блокирует фильм, явно отражается как Apple Vision fallback и может быть загружена одной кнопкой.

Статус: рабочий этап выполнен; native MLX packaging и встроенная доставка весов остаются отдельными release gates, а не скрытыми фиктивными возможностями.

### 8. Compact editing toolkit + Final Cut fidelity

- [x] Движение: Ken Burns, zoom/pan, push-in/pull-out — typed `TimelineItem.effect`, AVFoundation/Core Image ramps, одинаковые preview/MP4; фото автоматически получают аккуратный вариант движения.
- [x] Переходы: dissolve, fade, dip to black, blur dissolve, light flash, slide и wipe. Наличие transition отключает native-camera fast path, поэтому эффект больше не теряется в live preview.
- [x] Изображение: brightness, contrast, saturation, warmth, exposure, highlights/shadows, vignette, grain и фильтры выполняются `VeloVideoCompositor`/`AdjustedClipGenerator`, а не только хранятся в UI.
- [x] Скорость: constant slow/fast, editable multi-point speed ramp, freeze, reverse и instant replay. Speed ramp разбивается на реальные source ranges и `scaleTimeRange`; FCPXML получает multi-point `timeMap`.
- [x] Фото: последовательности используют обычные timeline items; Ken Burns/pan/zoom работают; запрос коллажа создаёт реальные split-screen пары без удлинения фильма.
- [x] Audio: clip/movie gain, fade in/out, музыка, automatic music ducking по активным source-audio ranges, offline high/low-frequency noise cleanup и EQ presets. Обработка создаёт временный derived CAF и не меняет оригинал.
- [x] Telemetry: GPS route, speed, altitude, distance и G-force декодируются из GPMF и рисуются динамическим Core Graphics/Core Text overlay в общем compositor.
- [x] Final Cut: source ranges, transforms, volume и constant/variable retime остаются редактируемыми. Для motion/color/audio-processing/telemetry/transition intent автоматически создаётся соседний rendered-reference MP4 и второй FCPXML project; editable project с оригиналами сохраняется параллельно.
- [x] AI execution: новые функции доступны typed-командами; Story Engine автоматически назначает ненавязчивое движение фото, telemetry только по явному запросу и multi-photo layout только по запросу.

Критерий выхода: Core/CLI/App build, 58+ tests, media smoke для photo/color/title, numeric GPMF fixtures, FCPXML editable+rendered assertions. Остаются release gates: реальный импорт fixtures в установленный Final Cut, спектральный/ML denoise и стабилизация движения; они не заявляются готовыми.

### 9. Standalone effects, titles and music sync (`ТЗ2.docx`)

- [x] Провести аудит текущего OpenCut и opencut-classic; зафиксировать изученные модули, решения и лицензионный статус в `Docs/Integrations/opencut.md`.
- [x] Добавить отдельные `EffectTimelineItem`, `TimelineTransitionItem`, `TitleTimelineItem` без разрушения старых project manifests.
- [x] Реализовать категории motion/blur/image/light/cinematic, enabled/target/parameters/intensity и keyframes с четырьмя easing modes.
- [x] Дать ручному Timeline перемещение, trim через Inspector, delete/duplicate/copy/paste, enable и общий undo/redo.
- [x] Добавить basic/cinematic/dynamic/captions/cards, word-level captions, keyword overlays, title/end cards и AI restyle существующего титра.
- [x] Исполнять отдельные эффекты и титры в общем preview/MP4 compositor; расширить переходы push/zoom.
- [x] Добавить `MusicSyncEngine` для beat/bar/section/peak/quiet/drop grid, snapping и ducking.
- [x] Расширить AI Director типизированными эффектами, keyframes, титрами, переходами и sync-to-beat.
- [x] Сохранять редактируемый intent и JSON metadata в FCPXML, автоматически требуя rendered-reference для непереносимых слоёв.
- [x] Покрыть persistence, interpolation, music sync, AI tools и FCPXML тестами; собрать полный `VeloEdit.app`.

Статус: выполнено. P2 добавил реальную опциональную Apple on-device транскрипцию с word/sentence timestamps и DSP fallback; импорт результата в установленный Final Cut остаётся внешним integration gate. Captions принимают и сохраняют word-level timestamps, а FCPXML содержит редактируемый текст и timing metadata.

### 10. AI Director P0 quality architecture

- [x] Transactional self-review через speculative Timeline copy и commit только при строгом росте review score.
- [x] Phase-aware moment boundaries: anticipation, peak, completion/reaction с visual/audio/telemetry evidence.
- [x] Заменяемый `HighlightRanking` и контекстная реализация для разных FilmPreset.
- [x] Несколько полных StoryPlan/Timeline вариантов на один brief и выбор через заменяемый `MontageGlobalScoring`.
- [x] Анализ локального музыкального файла: beat phase, downbeats, bars, phrases, drops, peaks и accents; один кэшированный decode на track ID.
- [x] Backward-compatible Codable-поля для новых Candidate/MusicStructure/DirectorRun evidence без изменений UI.

### 11. AI Director P1 quality-grounded search

- [x] Единый enriched `directorCandidates` path для Story, Composer, Director и scorer.
- [x] Candidate/source/semantic/order/rhythm distances и minimum-distance strategy search.
- [x] Расширенный complete-montage global score и pairwise quality checks.
- [x] Phase-aware trim вокруг peak с anticipation/reaction handles.
- [x] Combined-score transactional repair с hard safety и bounded beam search.
- [x] Параллельная режиссура вариантов, prepared scoring features и in-flight music cache.
- [x] Persisted variant diagnostics и production `VeloEditPipeline.createFilm` test.

### 12. AI Director automatic variant tournament

- [x] До 18 контекстных стратегий и до 10 существенно разных rough cuts.
- [x] Полный TimelineComposer/music/AIDirector/self-review path для каждого принятого варианта.
- [x] Global score с continuity, rhythm и technical quality в дополнение к P1 quality evidence.
- [x] Directed diversity/weak gates и round-robin `MontagePairwiseComparator` с automatic winner.
- [x] `DirectorRunSummary` сохраняет all scores, pairwise outcomes, tournament statistics, selection и rejection reasons.
- [x] Ручной A/B и человеческие оценки не входят в production flow; UI не изменён.

### 13. P2 Deep Media Understanding

- [x] `EmbeddingModelProtocol`, 64-D local visual embeddings по adaptive key frames, persistent cache, similarity search и bounded large-library clustering.
- [x] Cross-video semantic event grouping, near-duplicate suppression и best-take ranking; Story Engine не повторяет одно событие.
- [x] Selective face/object/subject tracking для shortlist, composition/visibility/motion features и subject-aware video/photo reframe.
- [x] Динамический reframe в compositor и переносимый FCPXML transform + trajectory metadata.
- [x] Apple on-device ASR с word/sentence/phrase/silence boundaries, confidence и DSP fallback без обязательного cloud.
- [x] DSP-классификация speech/laughter/applause/scream/impact/water/engine/wind/crowd/ambient/music/silence.
- [x] Multimodal MomentBoundary: visual/motion/audio onset+events/telemetry/subject/ASR/VLM, low-confidence conservative handles.
- [x] Measured music tempo/phase/meter/downbeat/bar/phrase/section/drop/breakdown/transition analysis с confidence и persistent cache.
- [x] Global/pairwise score расширен subject composition, speech continuity, audio-event coherence, visual semantics и measured music structure.
- [x] `DirectorRunSummary.deepMediaDiagnostics` сохраняет stage runs/cache hits/confidence/counts/discarded IDs/timings.
- [x] Unit, cache, backward-compatibility, performance и production-path fixtures; UI/taste engine не изменены.

Статус: выполнено. Архитектура и фактические fallback-границы описаны в `Docs/Architecture/media-understanding.md`.

### 14. P3 Autonomous Taste & Style Engine

- [x] Continuous `ProjectStyleProfile` вместо жёстких style categories; confidence-aware neutral fallback.
- [x] Optimal duration из сильных semantic moments без padding до UI-дефолта.
- [x] Device-local Bayesian Personal Taste с decay, contextual estimates и anonymized natural Timeline signals.
- [x] Автономные story patterns, clean-cut editing grammar и structural music intent.
- [x] Style-space probes меняют реальный full production path каждого варианта.
- [x] Global/pairwise scoring расширен emotional/pacing/project-style/personal-taste fit.
- [x] Pareto-aware selection перед pairwise tournament.
- [x] Explainable decisions в `DirectorContext`/`DirectorRunSummary`, без нового UI и ручных ratings.
- [x] Unit + end-to-end autonomous production tests и backward-compatible optional manifest fields.

Статус: выполнено. Архитектура, learning policy, performance и fallback-контракты описаны в `Docs/Architecture/autonomous-editing.md`.

### 15. P4 Event Intelligence & AI Memory Timeline

- [x] Capture-date priority, timezone/EXIF offset, modification/import fallback и confidence-aware temporal evidence.
- [x] Camera filename evidence: GoPro/DJI/Insta360 recording groups, iPhone Live Photo и timestamp-имена телефонов без склейки по соседнему номеру alone.
- [x] Cross-camera identity, clock-offset estimation и нормализованная архивная шкала.
- [x] Multimodal event clustering по time/GPS/visual/semantic/activity/people/audio/device evidence с hard split gates.
- [x] Иерархия `Project → Event → EventScene → Candidate/Moment → MediaAsset`, stable deterministic IDs и backward-compatible optional fields.
- [x] Event scenes с фазами setup/preparation/action/peak/reaction/conclusion, human titles и EventQuality.
- [x] Event-first Story Engine: selection/order/duration до выбора сцен и моментов, chronology default и bounded cold open.
- [x] Автоматические project/event chapter cards через существующие title items; UI не изменён.
- [x] Event-aware global/pairwise score, weak gates и transactional repair safety.
- [x] `DirectorRunSummary.eventDiagnostics`: counts, confidence, titles, date ranges, order, scenes, camera matches/offsets и evidence reasons.
- [x] Unit/performance/end-to-end fixtures, включая 320 assets и persisted production path.

Статус: выполнено. Архитектура, алгоритмы, thresholds, diagnostics и fallback-контракты описаны в `Docs/Architecture/event-intelligence.md`.

### 16. P5 Production Hardening

- [x] Synchronous optimistic Timeline mutations и coalesced persistence/preview.
- [x] Revision-safe AI/background commits и monotonic editor revision.
- [x] Interactive-resolution preview, persistent photo/title cache и bounded memory.
- [x] Real-frame black detection/recovery и production consistency audit.

Статус: выполнено. Детали и внешние gates описаны в `Docs/Architecture/production-hardening.md` и [архив: PRODUCTION_AUDIT.md](https://github.com/007danlin/VeloEdit/blob/8646d9df96b31e13cb411fcb6da8ad9be73ade22/PRODUCTION_AUDIT.md).

### 17. P6 Perceptual Editor / AI Visual Quality Loop

- [x] Отдельный `PerceptualScore` с 11 воспринимаемыми quality components, не заменяющий GlobalScore.
- [x] Иерархический Film/Event/Scene/Shot/Cut review и `CutQualityScore` для каждой склейки.
- [x] Continuity, subject/composition, complete moment, style-aware rhythm, music/drop, speech/audio-event, effect/title/telemetry checks.
- [x] Структурированные severity/range/type/confidence/explanation/repair findings.
- [x] Automatic repairs только через существующие typed tools, safety layer и bounded single/pair beam.
- [x] Transactional commit по combined global+perceptual score с technical/moment/critical/treatment hard constraints.
- [x] Confidence threshold, iteration/repair/improvement budget и остановка без полезного улучшения.
- [x] Selective render-aware review реальной `AVComposition` только для winner и один post-repair verification pass.
- [x] Расширенный `DirectorRunSummary` с scores/findings/repair attempts/rollback/render status.
- [x] Unit, production-path, actual composition и persisted 302-asset end-to-end tests.
- [x] UI и набор эффектов не изменены.

Статус: выполнено. Архитектура, safety, performance, tests и ограничения описаны в `Docs/Architecture/perceptual-review.md`.

### 18. P7 Personal Taste & Adaptive Editing Engine

- [x] Backward-compatible `PersonalTasteProfile` с value/confidence/sample/polarity/lastUpdated для pacing, duration, density, action/calm, transitions/effects/slow-mo/music/title/telemetry/color/photo/ending.
- [x] Natural Timeline signal extraction для delete/restore/trim/reorder/effect/music/title/color/SFX/telemetry и anonymous visual/semantic preference evidence.
- [x] Activity/project/event/camera/format/duration contexts, discovered style, duration/music/title/structure subprofiles и 180-day decay.
- [x] Material-bounded personal duration, grammar/BPM/beat-sync adaptation и deterministic 90/10 nearby exploration.
- [x] `PersonalizedMontageScorer` до Pareto/pairwise winner: global + technical + contextual + perceptual + confidence-bounded taste.
- [x] Transactional local `TasteRegressionGuard` на automatic Timeline/P1/P6 samples без human rating или manual A/B.
- [x] Offline atomic persistence, privacy contract, JSON export и confirmed reset.
- [x] `DirectorRunSummary.personalTasteDiagnostics` с variant scores, context, confidence, discovered style, explore/exploit и regression reasons.
- [x] Unit/persistence/production tests, включая 10 edit contexts → следующий полный director variant selection.

Статус: выполнено. Архитектура, confidence/decay, privacy, scoring и regression policy описаны в `Docs/Architecture/adaptive-taste.md`.
