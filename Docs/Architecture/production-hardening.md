# P5 — Production Hardening, Performance & Instant Interaction

## Цель

P5 укрепляет существующий production path без новых эффектов и без изменения UI. Ручная правка сначала меняет локальное представление Timeline, а сохранение, подготовка derived media и замена `AVPlayerItem` выполняются отменяемо в фоне. Старый корректный кадр остаётся видимым, пока новый preview не готов.

## Интерактивный путь

`AppModel.editTimelineOptimistically` применяет чистую синхронную операцию `TimelineMutationEngine` к локальной Timeline. Этот шаг не читает медиа и не пишет `project.json`. Он сразу публикует новую геометрию SwiftUI, сохраняет undo snapshot и увеличивает `timelineEditRevision`.

Далее запускаются две coalesced-задачи:

1. через 25 ms последняя Timeline передаётся в `VeloEditPipeline.commitLatestTimeline`;
2. через 16 ms для layer-only либо 35 ms для structural edit создаётся интерактивный preview с long edge не более 1280 px.

Новая правка отменяет ожидающие задачи. `clientRevision` запрещает более старому commit или preview стать текущим после более новой правки. Undo/redo использует тот же optimistic path. Длительные структурные операции — import, split, insert, delete, AI edit и export — остаются на прежнем сериализованном production path.

`TimelineInvalidationPlanner` классифицирует изменения source video/audio, структуры, effects, titles, telemetry, transitions и soundtrack, выдаёт изменённые диапазоны и выбирает debounce. Это единый интерфейс для следующего этапа segment-level AVComposition reuse; в P5 корректность сохраняется полной пересборкой композиции после coalescing.

## Preview и final render

- `VeloEditPipeline.makePlayback(timeline:interactiveLongEdge:)` принимает optimistic snapshot, не требуя предварительной записи на диск.
- Интерактивная Timeline масштабируется до 1280 px по длинной стороне. Сохранённая Timeline и final render не меняют разрешение.
- Photo/title intermediates имеют content-derived identity и сохраняются в `Cache/Preview/DerivedMedia`; повторная сборка сообщает hit/miss и не перекодирует неизменившийся материал.
- Disk cache ограничен 128 файлами и 2 GB. `FrameCache`, `DeepAnalysisCache` и `MusicStructureCache` имеют независимые LRU-границы памяти.
- При замене item старый poster не очищается. Если новый item не готов, пользователь продолжает видеть последний валидный кадр.
- `FrameQualityInspector` проверяет реально декодированный `CGImage` по средней яркости и вариации. Подозрительный uniform-black кадр вызывает поиск трёх соседних времён; если все они чёрные, существующий валидный poster сохраняется, а причина отражается в status.

## Согласованность и отмена

`ProjectStore` ведёт process-local revision и поддерживает compare-and-swap `update(ifRevision:)`. `createFilm` и `regenerate` фиксируют исходный snapshot и коммитят результат только в ту же revision. Поэтому длительный AI run не может перезаписать более новую ручную правку.

Analysis commit дополнительно сверяет `assetID`, content hash и missing state. Результат удалённого или заменённого исходника не попадает обратно в manifest. Persist остаётся атомарным через temporary file + replace.

## Метрики и проверки

`InteractionLatencyRecorder` хранит не более 1000 samples и вычисляет p95 относительно бюджетов:

- state update — менее 16 ms;
- первый визуальный ответ — менее 50 ms.

Production tests проверяют:

- 300-item synchronous mutation и непрерывный magnetic timing;
- structural/layer-only invalidation;
- stale ProjectStore transaction и out-of-order client revisions;
- bounded frame/deep caches;
- true-black против dark-textured frames;
- bounded p95 recorder;
- стабильность cache identity;
- реальный `PlaybackEngine` miss → hit на photo-derived video.

Полный список выявленных рисков, исправлений и внешних validation gates находится в [PRODUCTION_AUDIT.md](https://github.com/007danlin/VeloEdit/blob/8646d9df96b31e13cb411fcb6da8ad9be73ade22/PRODUCTION_AUDIT.md).

