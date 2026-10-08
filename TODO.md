# TODO

## Реализовано

- [x] Экспорт без лишнего файла лицензий для CC0; обязательная атрибуция только музыки текущего монтажа.
- [x] Сырые результаты экспериментов исключены из Git, собственная лицензия уточнена без ограничения сторонних прав.

- [x] Спокойный показ фото: 6 секунд, центрированное увеличение на 5%, без автоматических панорам и сокращения до темпа видео.
- [x] Сохраняемое финальное затемнение новых фильмов, общее для просмотра и экспорта, включая титры/наложения.
- [x] Versioned media/story/timeline/project models и атомарный project package.
- [x] URL/bookmark import, быстрый bounded fingerprint, явная полная SHA-256-проверка и AVFoundation/ImageIO metadata.
- [x] Thumbnail/proxy cache, ленивое создание прокси и повторное использование анализа.
- [x] Мгновенное добавление медиа без обязательного копирования, полного хеширования и перекодирования.
- [x] Видимый live progress импорта/анализа/рендера без блокировки редактора AI-запроса.
- [x] Рабочий чат AI-режиссёра через локальную Qwen3 4B Instruct/Ollama, без зависимости от Apple Intelligence.
- [x] Точное число моментов из запроса становится жёстким `targetClipCount` и проверяется в Story Engine.
- [x] Применение нового брифа к существующему фильму: smart regenerate, замена timeline/playback и отчёт «было → стало» в чате.
- [x] Честная готовность: старые montage/playback не дают 100% при неприменённых правках.
- [x] Сквозная готовность фильма в процентах и меняющиеся статусы «понимание → анализ → монтаж → просмотр».
- [x] Переписка с режиссёром во время занятого media pipeline; сообщения сохраняются в текущем режиссёрском брифе.
- [x] Явное подтверждение успешного анализа и актуального кэша без исчезающей обратной связи.
- [x] Человекочитаемое имя проекта без видимого `.veloedit` в диалоге сохранения и Finder.
- [x] Центрированное пустое состояние медиатеки на уровне Timeline.
- [x] Настоящие thumbnails и inline-просмотр исходников в медиатеке.
- [x] Многофрагментный Story Engine без схлопывания одинаковых `4K/horizontal` материалов.
- [x] Живой просмотр готового монтажа без ожидания предварительного MP4-рендера.
- [x] Native-track playback для однородных GoPro/HEVC исходников без чёрного кадра.
- [x] Недавние проекты: persistent список, быстрый запуск, missing-state и удаление записи.
- [x] Обратно совместимая модель iMovie-class настроек клипа: скорость, кадр, цвет, прозрачность, звук/fade и титры.
- [x] Typed AI-команды реально меняют Timeline и подтверждаются отдельным отчётом после пересборки просмотра.
- [x] Speed, fill/fit, rotate/mirror, opacity, color filters и clip audio исполняются одинаково в live preview и MP4.
- [x] Рабочие title cards, split, duplicate, move, transitions/effects и soundtrack commands из диалога и инспектора.
- [x] FCPXML timeMap/conform/transform/blend/volume плюс metadata неподдерживаемых намерений.
- [x] Cutaway, picture-in-picture, split-screen и green-screen как реальный второй видеослой в preview/MP4.
- [x] Freeze frame, reverse playback, instant replay и auto enhance вручную и по запросу режиссёру.
- [x] Размер, цвет, фон и выравнивание титров вручную и по запросу.
- [x] Строгая JSON-схема Qwen и безопасная нормализация свободных фраз без двойного применения команд.
- [x] Старт главного окна на всю рабочую область экрана без системного fullscreen.
- [x] Сквозной regenerate с автоматическим обновлением композиции в проигрывателе.
- [x] Offline analysis fallback, multiple candidates, events и explainability.
- [x] Четыре режима AI-мощности с `Баланс` по умолчанию и Advanced runtime/model/quantization.
- [x] Полный proxy-first анализ: original metadata/GPMF → 720p proxy → coarse/dense adaptive sampling → peaks → deep Qwen3-VL → Story Engine.
- [x] Реальные motion/exposure/detail признаки кадров и Apple Vision labels вместо псевдослучайного выбора лучших диапазонов.
- [x] Thermal/Low Power регулирование: последовательный VLM, сокращение выборки при нагреве и остановка deep pass на critical.
- [x] Проверка/автозапуск Ollama и загрузка выбранной Qwen3-VL из UI с потоковым процентом.
- [x] Русский prompt parser, presets, diversity limits, locked/excluded и smart regenerate.
- [x] Video/photo render; фото получают non-generative Ken Burns.
- [x] GPMF KLV parser и telemetry summary model.
- [x] FCPXML 1.11 edit/selects exporter и 10 обязательных fixtures.
- [x] AI Director 2.0: semantic Story Plan, единый валидируемый editing-tools API и до двух self-review/re-edit итераций.
- [x] Transactional self-review: speculative repair коммитится только при строгом улучшении полного Timeline review.
- [x] Phase-aware границы кандидатов `anticipation → peak → completion/reaction` по visual/audio/telemetry signals.
- [x] Контекстный highlight ranker, несколько полных Story/Timeline вариантов и выбор через global scoring.
- [x] Реальный анализ музыкального envelope: beat phase, downbeats, bars, phrases, drops и accents; структура кэшируется на трек.
- [x] Переменные source ranges, повторное использование исходников, B-roll, slow motion/speed ramp, стабилизация, color/audio/ducking и telemetry назначаются автономно по анализу.
- [x] «Волшебная кисть» получает выбранный диапазон, playhead/соседей/Story Plan и применяет typed AI-команды только локально.
- [x] Persistent `AI Edit NN` checkpoints перед крупными AI-правками и восстановление полной версии Timeline.
- [x] SwiftUI workflow: project, drag/drop, import, analysis, director prompt, timeline, regenerate, preview/export.
- [x] CLI, diagnostics и ad-hoc signed `VeloEdit.app` packaging.

## Следующие продуктовые итерации

- [x] Stabilization/rolling-shutter pass с Vision motion estimate, bounded affine transform и safety crop в общем compositor.
- [x] Базовый offline noise cleanup и EQ presets через derived CAF; preview/MP4 parity.
- [ ] Spectral/ML denoise, расширенные audio effects и запись voiceover.

- [x] Декодировать GPS5/ACCL со SCAL в route/speed/altitude/distance/G-force samples.
- [ ] Проверить UNIT и абсолютную синхронизацию metadata tracks на многомодельном GoPro corpus.
- [x] Добавить локальный visual embedding/semantic index для similarity, event grouping, best-take и near-duplicate detection с persistent cache и large-library locality buckets.
- [x] Добавить selective subject tracking, subject-aware reframe/Ken Burns, on-device ASR, audio events и multimodal boundary refinement в production-путь.
- [x] Расширить global/pairwise scorer P2 evidence и сохранять deep-stage diagnostics/timings в `DirectorRunSummary`.
- [ ] Автоматическое извлечение BPM из пользовательских треков и original-sound classification (BPM/mood/energy-каталог, beat-grid монтаж и audio ducking готовы; генерации музыки нет).
- [ ] Расширенные timeline gestures: кнопки split/duplicate и drag reorder готовы; добавить blade-at-playhead и drag-resize/reposition для PiP.
- [x] Рендер speed/GPS route/altitude/distance/G-force overlays в общем preview/MP4 compositor.
- [ ] HDR-preserving composition/render pipeline и color-space tests.
- [ ] Resumable persistent job queue с pause/resume после перезапуска.
- [ ] Duplicate/near-duplicate feature-print index.

## Требует внешней среды/данных

- [ ] Проверить на реальном смешанном архиве 300+ видео / 500+ фото.
- [x] P1 quality-grounded variant search: пять distance metrics, minimum-distance gate и расширенный набор стратегий.
- [x] P1 complete-montage scoring: semantic/source diversity, continuity, moment completeness, energy curve, rhythm, audio/music/drop alignment, story arc и technical quality.
- [x] P1 combined transactional beam repair с hard safety constraints для locked/source/story/timing invariants.
- [x] Automatic 10-variant search: до 18 стратегий, до 10 различных rough cuts и полный production pipeline для каждого принятого варианта.
- [x] Automatic pairwise tournament: weak/similar gates, round-robin comparison и combined tournament score без ручного A/B.
- [x] P1 production-path diagnostics и tests: `createFilm` проверяет все production-variants и persisted full scores/pairwise/rejection report.
- [ ] Проверить каждый FCPXML fixture импортом в установленный Final Cut Pro.
- [ ] Прогнать photo intermediate и 1080p/4K transcoding из подписанного app host; video-only passthrough уже проверен в CLI.
- [ ] Включить native MLXVLM runtime и model downloader в release target; рабочий Qwen3-VL/Ollama path уже локальный.
- [ ] Для MLX-весов добавить disk-space preflight, checksum manifest и возобновление оборванной загрузки.
- [ ] Подписать Developer ID, notarize и собрать release DMG с реальными credentials.
