# Changelog

## 2026-10-08 — Экспорт и публичный репозиторий

- Из текущего дерева удалены исторические аудиты и отчёты приёмки. Действующие ТЗ и скрипты сохранены, ссылки на прежние результаты ведут в историю Git.

- `music-credits.json` создаётся только для музыки экспортируемого монтажа с обязательной атрибуцией; CC0 и история ранее выбранных треков не добавляют файл к фильму.
- Уточнены ограничения на распространение собственных компонентов VeloEdit с сохранением прав по лицензиям сторонних компонентов и условиям GitHub.
- Сырые результаты проверок, кэши, архивы и пробные экспорты исключены из Git; локальные копии, тесты, скрипты и текстовые выводы сохранены.

## 2026-09-09 — Спокойный показ фото и плавный финал

- Новые автоматические фильмы заканчиваются секундным затемнением всей композиции, включая титры и наложения; длительность не увеличивается. Настройка сохраняется в проекте, явное «без затемнения» её отключает.
- Фото по умолчанию получают 6 секунд и центрированное увеличение на 5%, без автоматического чередования боковых панорам. AI-доработка не обрезает фото по правилам динамичных видеоклипов.
- Просмотр, стабильный предпросмотр и MP4 используют одно затемнение. Проверка чёрных кадров учитывает намеренный финал; кэш фото и проверок обновлён.

## 2026-08-24 — P7 Personal Taste & Adaptive Editing Engine

- Существующий P3 `PersonalTasteProfile` расширен confidence-calibrated estimates с sample/polarity counts, decay, contextual duration, activity/project/event/camera/format contexts, private embedding centroids, discovered style, music/title detail и learned structure patterns.
- `AdaptivePreferenceSignalExtractor` читает реальные delete/restore/trim/reorder/speed-ramp/slow-mo/zoom/stabilization/transition/color/SFX/photo/title/music/telemetry изменения и anonymous semantic evidence.
- `AutonomousDirectorEngine` постепенно применяет learned film/shot duration, grammar, BPM/beat-sync и deterministic 90/10 nearby exploration без обязательных вопросов.
- `PersonalizedMontageScorer` объединяет global, technical, contextual, perceptual и taste scores до Pareto/pairwise winner selection; taste ограничен confidence и не скрывает quality failure.
- `TasteRegressionGuard` транзакционно проверяет proposed profile на локальных automatic Timeline/P1/P6 samples без человеческих оценок и manual A/B.
- `DirectorRunSummary.personalTasteDiagnostics` сохраняет variant scores, context, confidence, discovered style, explore/exploit, regression result и причины выбора.
- Добавлены локальные export/reset API и минимальные кнопки Settings; облако не используется.
- Добавлены P7 unit/persistence/production tests, включая десять независимых edit contexts и полный `StoryEngine → AIDirectorEngine/P6 → personalized pairwise selection` путь.

## 2026-08-24 — P6 Perceptual Editor / AI Visual Quality Loop

- Добавлены отдельный `PerceptualScore`, иерархические findings и `CutQualityScore` для каждой соседней пары shots.
- Review учитывает screen/motion/subject/composition continuity, полноту anticipation–peak–completion/reaction, style-aware rhythm, measured music/drop alignment, speech/audio events, effects, titles, telemetry и technical integrity.
- Repairs выполняются существующими typed tools на копиях Timeline и коммитятся только при росте combined global+perceptual score после hard safety; rejected beams и rollback сохраняются.
- Каждый production-вариант проходит analysis-backed P6, а winner — bounded render-aware проверку реальной `AVComposition` с black/frozen detection и максимум одним verification rebuild.
- `DirectorRunSummary` расширен perceptual iterations/findings/severity/repairs/rollback/before-after scores, cut scores, attempts и render status; поля backward compatible.
- Добавлены P6 unit/production/render/end-to-end tests, включая фактическое исправление намеренно плохой Timeline и 302-asset pipeline; UI и набор эффектов не изменены.

## 2026-08-24 — P5 Production Hardening

- Простые Timeline drag/trim/inspector и undo/redo переведены на synchronous optimistic mutation; manifest persistence и preview coalesced и отменяемы.
- ProjectStore получил revision snapshots/CAS, а editor commits — monotonic client revision; устаревшие AI/analysis/editor results не перезаписывают новый state.
- Interactive preview ограничен long edge 1280, photo/title intermediates кэшируются между сборками и публикуются атомарно.
- Frame/deep/music memory caches получили LRU bounds; preview disk cache ограничен по числу файлов и объёму.
- Старый poster сохраняется при замене AVPlayerItem; uniform-black frame автоматически перепроверяется на соседних временах.
- Добавлены production hardening tests и [архив: PRODUCTION_AUDIT.md](https://github.com/007danlin/VeloEdit/blob/8646d9df96b31e13cb411fcb6da8ad9be73ade22/PRODUCTION_AUDIT.md) с открытыми release gates.

## 2026-08-24 — P4 Event Intelligence / AI Memory Timeline

- Добавлен production `EventIntelligenceEngine`, который объединяет capture dates, timezone/GPS/GPMF, visual/semantic embeddings, activity, people, audio и camera identity в иерархию `Project → Event → Scene → Moment → Asset`.
- Реализованы confidence-aware date fallbacks, cross-device clock offsets, camera filename evidence (GoPro/DJI/Insta360 chapters, iPhone Live Photo, phone timestamp names), hard split/merge gates, стабильные Event/EventScene IDs, human titles, date/location evidence и EventQuality.
- Story Engine теперь выбирает/упорядочивает события до scenes/candidates, распределяет duration по силе материала, сохраняет chronology и поддерживает осознанный bounded cold open.
- TimelineComposer создаёт project/event chapter cards существующими title items и сохраняет event/scene context на клипах; UI не изменён.
- Global/pairwise scorer и transactional repair safety учитывают event order/diversity/coverage/chronology, scene diversity и inter-event repetition.
- `DirectorRunSummary.eventDiagnostics` сохраняет counts, confidence, titles, date ranges, order, scene count, camera matches/offsets и clustering reasons.
- Добавлены P4 unit/performance/production tests, включая четыре события одного дня, multi-day trip, cross-camera sync, 320 assets и persisted end-to-end montage.

## 2026-08-24 — P3 AI Director 3.0 / Autonomous Taste & Style

- Добавлены continuous ProjectStyle, confidence-aware PersonalTaste blend, optimal duration и material-dependent story patterns.
- Timeline delete/restore/trim/reorder/speed/transition/music/title/crop/telemetry/undo/regenerate превращаются в локальные anonymized Bayesian signals с decay; ручных оценок и A/B UI нет.
- Каждый вариант получает собственные duration/grammar/story/music decisions и проходит существующий production pipeline целиком.
- Music selection учитывает measured editability, phrases/sections/drops и сходство energy curve трека с narrative arc.
- Global/pairwise score расширен emotional curve, pacing, ProjectStyle fit и PersonalTaste fit; перед турниром применяется Pareto multi-objective gate.
- Autonomous decisions, confidence, Pareto front и explainable reasons сохраняются в StoryPlan/DirectorRunSummary.
- Добавлены 11 P3 tests, включая production `raw project → autonomous decision → multiple variants → Pareto/pairwise winner → persisted Timeline → implicit learning`.

## 2026-08-24 — P2 Deep Media Understanding

- Adaptive/key frames получают cached local visual embeddings; `SemanticSceneIndex` выполняет similarity, event clustering, near-duplicate detection и best-take selection без обязательной модели.
- Apple Vision faces/saliency/classification связываются selective subject tracker-ом; AI Director использует visibility/composition/motion для selection, 9:16 reframe и subject-aware Ken Burns.
- Добавлен Apple on-device ASR с word/sentence/phrase/silence timestamps и DSP fallback; фактический Timeline trim теперь определяет speech continuity score.
- Audio analysis классифицирует speech/laughter/applause/scream/impact/water/engine/wind/crowd/ambient/music/silence и передаёт events в boundary/ranker/audio/scorer.
- Moment boundary объединяет visual, motion, audio onset/events, telemetry, subject, ASR и VLM evidence; low confidence запрещает агрессивный trim.
- Music DSP оценивает tempo, beat phase, meter, downbeats, bars, phrases, sections, quiet/breakdown/transition/drop/peaks с confidence; climax синхронизируется с музыкальным drop/section peak.
- Global/pairwise scorer вырос до 20 нормализованных components и учитывает subject, speech, audio events, visual semantics и measured music structure.
- `DeepAnalysisCache` сохраняет embeddings/tracking/ASR/audio analysis/events, а `DirectorRunSummary` — deep-stage counts/confidence/cache/discarded/timings.
- Добавлены 13 P2 tests, включая production media/reframe paths и bounded fixture 300 × 8 candidates; старый score JSON декодируется с neutral P2 components.

## 2026-08-24 — Automatic 10-variant pairwise tournament

- Story Engine теперь перебирает 18 контекстных стратегий и собирает до 10 существенно разных rough cuts.
- Каждый принятый вариант проходит полный production pipeline параллельно: TimelineComposer, music sync, AIDirectorEngine и transactional self-review.
- Global scorer расширен continuity, rhythm и technical quality; вместе с P1 evidence это даёт 15 независимых quality components.
- Near-duplicate directed variants и явно слабые монтажи отклоняются до pairwise-турнира.
- `MontagePairwiseComparator` проводит round-robin сравнение; победитель выбирается по pairwise utility и absolute global score без ручного A/B.
- `DirectorRunSummary.variantDiagnostics` сохраняет full score каждого production-варианта, pairwise results, wins/losses/ties, distances и причины выбора/отклонения.
- Production-path tests проверяют полноту persisted diagnostics и способность pairwise comparator предпочесть сбалансированный монтаж варианту с одним сильным absolute spike.

## 2026-08-24 — AI Director P1 quality-grounded search

- Добавлены candidate Jaccard, source-range, semantic, order и rhythm distance metrics с общим minimum-distance gate.
- Story Engine проверяет расширенный набор контекстных стратегий на едином enriched candidate evidence и не выдаёт near-duplicates как отдельные решения.
- Global scorer учитывает semantic/source diversity, полноту anticipation–peak–reaction, energy curve, original-audio continuity и drop–climax alignment.
- Self-review использует combined global score, hard safety constraints и bounded beam из одиночных/парных repairs.
- Composer и Director используют общий phase-aware trim вокруг peak.
- Независимые directed variants выполняются параллельно; scoring indexes и in-flight music analysis безопасно переиспользуются.
- `DirectorRunSummary` сохраняет число попыток/вариантов, pairwise distances, порог, победившую стратегию и причины выбора.
- Добавлены production-path и pairwise quality tests, проверяющие `VeloEditPipeline.createFilm`, а не только изолированные helpers.

## 2026-08-24 — AI Director P0 quality pass

- Self-review стал транзакционным: repair выполняется на копии и не может ухудшить сохранённый Timeline.
- Adaptive analysis сохраняет границы anticipation/peak/completion-reaction, объединяя visual, audio-onset и telemetry evidence.
- Единый composite selection заменён контекстным ranker-ом для разных типов фильма.
- Story Engine строит несколько полных вариантов; каждый проходит режиссуру и music sync, победителя выбирает global scorer.
- Music analysis определяет beat phase, downbeats, bars, phrases, drops и реальные accents по локальному файлу; структура кэшируется.
- Добавлены injectable `HighlightRanking` и `MontageGlobalScoring` для независимой автоматической калибровки.

## Unreleased

### Changed

- Исправлена телеметрия OVRLEY: каталог использует канонические display types,
  поиск работает по метрикам и видам во всех категориях, Viewer больше не
  перекрывает живые значения статичным preview, а каждый слой автоматически
  следует source clock конкретного видеофрагмента без выбора отдельного ролика.
- Реализован AI Director 2.0: semantic Story Plan, 45+ валидируемых editing tools, автономные решения по длительности/B-roll/retime/stabilization/color/audio/telemetry и bounded self-review/re-edit.
- Глубокий proxy-first анализ сохраняет `CandidateInsights`: сюжетную роль, визуальную/техническую оценку, пригодность для slow motion/speed ramp и полезность оригинального звука.
- Timeline хранит story role/editorial purpose, музыкальную структуру и фактический отчёт режиссёрского запуска; крупные AI-правки создают persistent `AI Edit NN` checkpoint с восстановлением.
- «Волшебная кисть» передаёт локальному AI выбранный диапазон и контекст фильма, но валидатор не позволяет typed-командам затронуть остальную Timeline.
- Музыкальная BPM/section синхронизация теперь повторяется после автономного retime и сохраняет уже выбранный трек.
- Прогресс анализа теперь показывает текущий файл и его процент (`Файл 2 из 3, 71%`) вместо внутренних единиц вроде `171/300`.
- Завершён аудит compact editing toolkit: motion/transition/image/speed/photo/audio/telemetry intents теперь имеют исполняемый preview/MP4 path, а не только catalog/UI state.
- FCPXML export сохраняет редактируемые originals/time maps/transforms/volume и при непереносимых эффектах автоматически создаёт точный rendered-reference MP4 со вторым project в том же event.
- Automatic ducking исправлен: теперь приглушается музыка вокруг активных source-audio ranges; исходный звук больше не ослабляется постоянным коэффициентом.

- Анализ видео переведён на proxy-first pipeline: GPMF читается из metadata track оригинала, кадры декодируются из автоматически создаваемого 720p proxy, а оригиналы остаются для просмотра/финального рендера/FCPXML.
- Разреженная выборка теперь измеряет реальное движение, экспозицию и детализацию, после чего уплотняется только вокруг интересных участков; лучшие группы кадров могут проходить глубокую локальную оценку Qwen3-VL.
- Analysis cache учитывает AI profile/model/quantization, поэтому смена мощности реально запускает другой анализ, но временный нагрев не вызывает повторный цикл после охлаждения.

- AI-режиссёр теперь отделяет разговор от исполнения: после «Применить правки» детерминированный command layer изменяет Timeline, пересобирает AVPlayer и пишет отдельный фактический отчёт.
- Многосоставные запросы разбиваются на команды с независимыми целями; местоимения наследуют последний явно указанный клип.
- Ручной инспектор расширен скоростью, fill/fit, поворотом, 8 фильтрами, brightness/contrast/saturation/temperature/opacity, клиповым mute/volume/fade, split/duplicate и добавлением титра.
- Color pipeline использует Core Image compositor во время просмотра/экспорта и не ждёт обязательного предварительного транскода каждого изменённого клипа.
- Regenerate переносит ручные настройки у сохранившихся candidates, титры, музыку и общий звук в новую версию монтажа.
- Начат iMovie-class command layer: `TimelineItem` теперь обратно совместимо хранит настройки скорости, fill/fit, поворота, фильтра/цвета, прозрачности, клипового звука/fade и стиля титра.
- Qwen теперь ограничена строгой JSON-схемой из двух строк; ошибочный вложенный `normalizedBrief` больше не отбрасывает нейроответ целиком. Нормализация заменяет исходную фразу только когда даёт больше распознанных команд, исключая двойные rotate/freeze/duplicate.
- Timeline различает основные и overlay-клипы: PiP, split screen, cutaway и green screen делят диапазон основного клипа и не увеличивают длительность фильма.

- Новый запрос режиссёру теперь инвалидирует готовность старого montage/playback: карточка падает с 100% до фактических 65% при готовых материалах/анализе, а этапы «Монтаж» и «Просмотр» помечаются «обновить».
- Кнопка режиссёра меняется на «Применить правки». После сборки чат сообщает количество/длительность до и после, а timeline и AVPlayer заменяются новой версией.
- При диалоге с несколькими числами, длительностями и конфликтующим темпом Story Engine применяет последнюю правку, а не первое сообщение.
- AI-режиссёр теперь сначала использует независимую локальную Qwen3 4B Instruct через Ollama; Apple Intelligence больше не является обязательным.
- Фразы вроде «сделай фильм из 3 моментов» создают жёсткое ограничение `targetClipCount`; монтаж действительно содержит три фрагмента.
- Шаблонный fallback больше не выдумывает «динамичный темп» и «2 минуты», а UI явно помечает его как «не нейросеть».
- При запуске главное окно надёжно разворачивается после восстановления SwiftUI на всю доступную область экрана, оставаясь обычным изменяемым окном без перехода в системный fullscreen.
- Поле AI-режиссёра заменено рабочим диалогом: сообщения можно отправлять и получать во время импорта или анализа, а введённые пожелания накапливаются в режиссёрском брифе.
- Создание фильма показывает непрерывный взвешенный процент по стадиям понимания задачи, анализа, сборки истории и подготовки просмотра; вложенные progress callbacks больше не сбрасывают общую шкалу.
- Импорт и генерация thumbnails теперь занимают диапазоны `0–70%` и `70–100%`, поэтому шкала не прыгает обратно к нулю; карточка фильма отражает импорт и ручной анализ в реальном времени.
- Длительность, указанная естественным языком в чате, синхронизируется с контролом длительности, а parser распознаёт больше русских форм слов «динамичный/энергичный/спокойный/медленный».
- Кнопка анализа сохраняет явное состояние во время работы и после завершения; успешный анализ и повторное использование актуального кэша подтверждаются заметным сообщением.
- Импорт больше не запускает полное чтение файла и создание 720p-прокси до появления медиа в проекте.
- Для быстрой идентификации используются метаданные и не более 128 KiB содержимого (начало и конец файла).
- Метаданные импортируемых файлов читаются параллельно ограниченными группами по четыре задачи.
- Прокси создаётся лениво по запросу, а полный SHA-256 вынесен в явную команду `veloedit-cli verify`.
- В рабочей области добавлена живая панель операции: текущий файл, счётчик, прогресс и стадия обработки; режиссёрский запрос остаётся редактируемым в фоне.
- Новый проект предлагается сохранить как «Мой фильм»; служебное расширение пакета скрывается в Finder.
- Пустое состояние импорта отцентрировано в рабочей области и согласовано по отступам с Timeline.
- Исправлен diversity-фильтр: общие технические теги `4K/horizontal` больше не схлопывают монтаж до одного фрагмента.
- Создание фильма теперь последовательно показывает анализ, подбор, сборку композиции и готовность просмотра.
- Preview MP4 для однородных камер использует быстрый passthrough выбранных диапазонов без повторного кодирования.
- Исправлен чёрный экран live preview для однородных GoPro HEVC: проигрыватель использует нативную геометрию composition track вместо лишнего custom compositor.
- Safe native-track режим для однородных 4K/5K камер используется только для визуально нетронутых clips; transition/motion/color/telemetry включают compositor и не исчезают из preview.
- Добавлены недавние проекты на стартовом экране и в меню «Открыть недавний», с устойчивым порядком и обработкой перемещённых файлов.

### Added

- Добавлены Ken Burns/push-in/pull-out, fade/blur/light transitions, exposure/highlights/shadows/vignette/grain и multi-point speed ramps.
- Добавлен offline AVAudioEngine processor для basic noise cleanup/EQ presets и disposable CAF intermediates без записи в оригиналы.
- GPMF GPS5/ACCL декодируется со SCAL в route/speed/altitude/distance/G-force; новый Core Graphics telemetry HUD работает в preview/MP4.

- Добавлены режимы `⚡ Быстро / ⚖️ Баланс / 🧠 Качество / 🎬 Максимум`; Баланс рекомендован и выбран по умолчанию для MacBook Air M4.
- В Director UI показываются AI runtime, thermal status, число выбранных кадров и глубоко проверенных моментов; Advanced Settings разрешает ручной runtime/model/quantization.
- Добавлены `AIAnalysisProfile`, `AdaptiveFrameSampler`, GPMF sample-track extractor и локальный Ollama/Qwen3-VL vision client.
- Thermal/Low Power policy снижает sampling при нагреве, сериализует VLM и пропускает тяжёлый deep pass в critical state.
- Приложение проверяет и при необходимости запускает локальный Ollama; выбранную профилем Qwen3-VL можно загрузить из AI-карточки с живым процентом.

- Добавлены typed-команды для speed/duration/filter/crop/rotate/color/opacity/clip audio/transitions/effects/title/delete/duplicate/split/move/music.
- Добавлены typed-команды и ручные controls для overlay/PiP/split/green screen, stop frame, reverse, instant replay, auto enhance и оформления титров.
- Титры рендерятся в live preview и MP4 как timed Core Animation title cards, а не пропускаются PlaybackEngine.
- FCPXML теперь переносит constant speed через `timeMap`, fill/fit, rotation/mirror, opacity, clip volume и сохраняет остальные VeloEdit-настройки в metadata.
- CLI получил `edit` для headless-проверки AI-команд и `playback-frame` для диагностики compositor.
- Добавлена проверяемая матрица `IMOVIE_BASELINE.md` и правило: ответ AI считается исполненным только после изменения Timeline, пересборки просмотра и отчёта в чате.

- Добавлен JSON-контракт локальной language model: отдельно реплика для чата и однозначный `normalizedBrief` для Story Engine.
- Подключён вторичный локальный AI-provider через Apple Foundation Models на macOS 26 с weak linking и без отправки медиа в сеть.
- Добавлен гарантированный контекстный fallback-ответ, если ни Ollama/Qwen3, ни Foundation Models недоступны.
- Добавлена постоянная карточка готовности фильма с процентом и этапами «Медиа / Анализ / Монтаж / Просмотр», typing-state и финальным сообщением режиссёра о готовом результате.
- Создан Swift package с независимыми Core, macOS App и CLI targets.
- Создан поэтапный `IMPLEMENTATION_PLAN.md` по ТЗ 1.0.
- Зафиксированы архитектурные инварианты offline-first, non-destructive и no-generative-slop.
- Реализованы versioned модели `MediaAsset -> AnalysisResult -> Candidate -> Event -> StoryPlan -> Timeline -> RenderJob`.
- Реализован package-based project store с атомарной записью, URL/bookmarks, content hashes и derived-media cache.
- Добавлены metadata import, thumbnails, 720p proxies, offline Vision/photo и multi-candidate video analysis fallback.
- Добавлены русскоязычный prompt/feedback parser, presets, diversity constraints, locked clips и smart regenerate.
- Добавлены AVFoundation video render и Ken Burns photo-to-video intermediate без генеративного заполнения.
- Добавлены GPMF KLV parser, telemetry summary, timecode и thermal-aware scheduler.
- Добавлены FCPXML 1.11 Edit/Selects exports и 10 fixture-сценариев.
- Добавлены нативный SwiftUI интерфейс, drag-and-drop, preview/timeline/export, CLI и diagnostics.
- Добавлены реальные thumbnails исходников, inline-проигрыватель выбранного видео и iMovie-подобный просмотр готовой композиции.
- Добавлены reproducible build/test/app packaging scripts и 24 unit/integration tests.

### Verified

- 92 Swift Testing checks проходят, включая autonomous semantic arc, реальные tool mutations, self-review ripple-delete, persistent rollback, Magic Brush isolation, music sections и FCPXML.
- 53 Swift Testing check проходят, включая default Balance, RAM-aware Maximum, thermal throttling, cache identity, adaptive sampling plan и ручные overrides.
- Реальный 43,6-секундный camera MOV прошёл host smoke: создан cached 720p proxy, декодировано 15 adaptive frames, получено 8 временно разнесённых candidates, original URL сохранён.

- 48 Swift Testing check проходят, включая разговорные формулировки, overlay timing, freeze/reverse/instant replay, auto enhance, title style и FCPXML time maps.
- Живой Qwen3 4B smoke через Ollama подтвердил ответ по строгой schema `{reply: string, normalizedBrief: string}` вместо произвольного вложенного JSON.
- Overlay E2E на копии реального проекта создал PiP третьего клипа поверх первого; playback собрал 12/12 элементов без пропусков и не удлинил фильм.
- Комбинированный media E2E добавил stop frame, PiP и auto enhance в копию «Велопокатушки»; итоговый playback собрал 13/13 элементов, 46,7 секунды, без пропусков.
- 40 Swift Testing check покрывают multi-clause command parsing, реальную мутацию Timeline, title playback, color intermediate и FCPXML mappings.
- На копии реального проекта «Велопокатушки» одна фраза добавила титр и изменила только второй клип: speed 2×, monochrome, fit и muted; playback собрал 13/13 элементов без пропусков.
- 33 Swift Testing check проходят после расширения модели; отдельный тест открывает старый TimelineItem без новых полей с нейтральными значениями.

- 31 Swift Testing check проходит, включая инвалидацию 100% при новом брифе и замену раннего ограничения «3 момента» на позднее «5 моментов».
- Реальный E2E пересобрал timeline с 3 фрагментов/15,1 с в 5 фрагментов/25,1 с без повторного анализа; новый playback собран без пропусков.
- 31 Swift Testing check проходит, включая точное число моментов и честный fallback-ответ.
- На реальной копии проекта запрос «Сделай связный фильм из 3 моментов» собрал 3 фрагмента/15,1 секунды; playback готов без пропусков в `native-track` режиме.
- Локальная Qwen3 4B Instruct на фразу из регрессии вернула «Создам связный фильм из 3 моментов» и техническую команду с тем же точным числом.
- Debug Core/CLI/SwiftUI build проходит на arm64.
- 31 Swift Testing check проходит, включая project persistence/editing, AI fallback, natural-language constraints, fingerprinting, multi-clip story, short targets, timecode, GPMF и FCPXML.
- CLI smoke создаёт проект, diagnostics и все 10 FCPXML fixtures.
- На копии реального проекта из 3 GoPro-файлов и 55 candidates собран playback из 30 фрагментов/120 секунд без пропусков.
- Passthrough MP4 smoke из трёх разных исходников экспортирован и повторно прочитан: 9,998 секунды, HEVC, со звуком.
- Release `VeloEdit.app` собран, ad-hoc подписан и проходит `codesign --verify --deep --strict`.
- Runtime smoke подтвердил работу loopback API Ollama и Qwen3 4B Instruct без Apple Intelligence.
