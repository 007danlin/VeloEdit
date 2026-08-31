# VeloEdit Production Audit — P5

Дата аудита: 2026-08-24. Область: import → analysis → Story/AI Director → Timeline editing → playback → export/FCPXML.

## Результат

Критические гонки commit и наиболее заметные задержки простых Timeline-правок устранены без изменения UI. Простые drag/trim/inspector/undo операции больше не ждут записи всего `project.json` и полной подготовки player до изменения состояния SwiftUI. Preview остаётся eventual-consistent: после короткого debounce выполняется корректная полная сборка композиции из последней revision.

## Реестр находок

| Severity | Наблюдение / root cause | Исправление | Production-проверка |
|---|---|---|---|
| Critical | Длительный `createFilm`/`regenerate` мог записать Timeline поверх более новой ручной правки | `ProjectStoreSnapshot` + CAS `update(ifRevision:)` | `projectStoreRejectsStaleBackgroundCommit` |
| Critical | Optimistic background commits могли завершиться не по порядку | Монотонный `clientRevision` в `commitLatestTimeline` | `pipelineDiscardsOutOfOrderOptimisticCommits` |
| High | Любая простая правка ждала manifest write, `refresh()` и новый player | Синхронный `TimelineMutationEngine`, локальный publish, debounced persist/preview | 300-item mutation test; полный app target компилируется |
| High | Undo/redo шли через blocking activity path | Undo/redo переведены на тот же optimistic snapshot path | Общий revision/Timeline mutation path |
| High | Photo и title перекодировались при каждой preview-сборке | Persistent content-addressed derived-media cache с atomic publish | `productionPlaybackActuallyReusesDerivedPhotoMedia` |
| High | Старый poster очищался до готовности нового item | Старый poster сохраняется; failed item возвращает предыдущий item/playback | App production path + status-observation guards |
| High | Uniform-black frame мог без объяснения стать poster | Реальная luma-проверка `CGImage`, поиск соседнего кадра, сохранение прошлого poster | `frameQualityRejectsTrueBlackButKeepsDarkTexture` |
| High | Результат анализа удалённого/заменённого файла мог вернуться в manifest | Commit сверяет id/hash/missing | Guard в production persistence path |
| Medium | Memory dictionaries кадров/deep analysis/music structure росли без границы | LRU limits 384/48/64 | `productionCachesHaveHardMemoryBounds` |
| Medium | Preview всегда использовал final dimensions | `interactiveLongEdge: 1280`; final Timeline не меняется | Production API и app call site |
| Medium | Timeline layer invalidation не имела единого контракта | `TimelineInvalidationPlanner` и диапазоны invalidation | `previewInvalidationDistinguishesOverlayOnlyAndStructuralEdits` |
| Medium | Force unwrap в subject/audio/self-review и nearest-primary paths | Заменены guard/optional comparisons | Полная компиляция и suite |

## Измеренные данные

- 300-item magnetic reorder в тестовом процессе: менее 50 ms; типичный прогон текущей машины около 2 ms.
- Production-hardening suite: 9 тестов, включая реальное создание и повторное использование photo preview.
- Полный Swift Testing suite после добавления cache end-to-end: 189/189 за 4.426 s.
- Существующие stress fixtures отдельно покрывают 300+ assets для SemanticSceneIndex/Event Intelligence. Они используют детерминированные media models, а не 300 физических 4K-файлов.

## Проверенные инварианты

- Оригиналы не модифицируются.
- Final render/FCPXML получают исходную Timeline resolution, source URLs и source ranges.
- UI и набор эффектов не изменены.
- Устаревшая background revision не коммитится.
- Устаревший preview не заменяет новый благодаря `timelineEditRevision` и identity guards.
- Derived media публикуется через partial file → validation → move.
- Отмена preview/analysis проверяется между дорогостоящими шагами.

## Оставшиеся риски и следующие gates

Эти пункты не маскируются unit-тестами и требуют отдельного release-validation окружения:

1. `TimelineInvalidationPlanner` уже отделяет layer-only edits, но `PlaybackEngine` пока пересобирает итоговую `AVComposition`; segment-level reuse decoded tracks остаётся следующей оптимизацией.
2. Нужен XCUITest target для измерения 60 FPS реального drag на SwiftUI Timeline и p95 end-to-end от gesture до первого нового AVPlayer frame. Текущий recorder измеряет мгновенный state/visual response, а не decoder-ready latency.
3. Нужен Instruments Time Profiler/Allocations/Leaks run на подписанном `.app` с реальными H.264/HEVC/ProRes, фото и длинными audio tracks. Headless package tests не заменяют этот gate.
4. Нужен физический stress corpus: 300 видео + 500 фото разных камер/кодеков. Текущие 300-asset fixtures проверяют алгоритмическую масштабируемость без сотен гигабайт media I/O.
5. Нужен многочасовой soak с repeated import → analysis → edit → preview → export → reopen и контролем RSS/file descriptors.
6. Нужны visual regression snapshots для telemetry/title/effect compositions на Intel/Apple Silicon и поддерживаемых версиях macOS.
7. В кодовой базе остаются допустимые `try?` для fallback/recovery. Их следует постепенно связать со structured diagnostics; пользовательские critical errors уже передаются через `errorMessage`/status/warnings.

Release нельзя объявлять прошедшим внешние gates 2–6 только на основании Swift unit/integration suite.
