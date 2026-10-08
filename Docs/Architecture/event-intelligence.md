# P4 / Event Intelligence & AI Memory Timeline

P4 добавляет архивный уровень понимания поверх P2 Deep Media Understanding и P3 Autonomous Taste & Style. Система сначала восстанавливает реальные события и сцены, а уже затем выбирает отдельные моменты для монтажа. Отдельного UI, второго Story Engine, ручной разметки и human A/B workflow нет.

## Production flow

`Media metadata + GPMF/GPS + P2 enriched directorCandidates → EventIntelligenceEngine → Project → Event → EventScene → Moment/Candidate → P3 style/taste → event-first StoryEngine → TimelineComposer → AIDirectorEngine → event-aware global/Pareto/pairwise scoring → final Timeline`

Event discovery запускается один раз после cross-video refinement в `analyzeMissing`, а также перед `createFilm` и `regenerate`, чтобы учитывать актуальные excluded/changed assets. Дорогой frame/VLM/ASR/DSP-анализ при этом не повторяется.

## Data model

| Уровень | Тип | Ответственность |
|---|---|---|
| Project | `ProjectManifest` | Полный архив, persisted events, story plans и timelines |
| Event | `Event` | Реальное событие, диапазон дат, место, confidence/evidence, quality и camera clock offsets |
| Scene | `EventScene` | Сцена внутри события, её assets/candidates и фаза истории |
| Moment | `Candidate` + `MomentBoundary` | Редактируемый source range с anticipation, peak и completion/reaction |
| Asset | `MediaAsset` | Оригинальный файл, metadata, bookmark и content identity |

Новые поля optional и декодируются нейтрально в старых project packages. Идентификаторы событий и сцен детерминированы составом кластеров: повторный discovery того же архива сохраняет ссылки между Event, StoryPlan, Timeline и diagnostics.

## Temporal and device evidence

`MediaImporter` применяет порядок доверия:

1. embedded QuickTime/EXIF capture date;
2. filesystem creation date;
3. filesystem modification date;
4. camera filename timestamp (`VID_YYYYMMDD_HHMMSS`, `PXL_…`) как medium-confidence относительный fallback;
5. import time как low-confidence fallback.

Для EXIF учитывается `OffsetTimeOriginal`, если он присутствует. Источник даты и confidence сохраняются в `MediaMetadata`. Low-confidence import/modification timestamps не могут сами по себе объединить два файла.

`EventDeviceIdentity` строит camera key по make/model и безопасным filename fallbacks для GoPro/DJI/iPhone. Filename parser распознаёт главы одной GoPro-записи (`GOPR0123` ↔ `GP010123`/`GP020123`), DJI/Insta360 recording groups, iPhone Live Photo пары с одинаковым `IMG_1234` stem и timestamp-имена Android/Pixel/Samsung. Точное recording-group совпадение — сильное evidence; просто соседние номера — слабый sequence hint и не могут сами склеить Camera Roll. `EventIntelligenceEngine` ищет семантически, пространственно или визуально подтверждённые cross-camera совпадения в десятиминутном окне, оценивает median clock offset и нормализует временную шкалу. Смещение ограничено ±300 секунд и не вычисляется по слабым датам.

## Event clustering

Pairwise fusion использует только доступные evidence и перенормирует веса:

- time proximity;
- GPS distance/route;
- visual similarity из P2 embeddings/evidence;
- semantic overlap;
- activity;
- people/main subjects;
- audio context;
- device timeline relation.
- camera filename recording group/sequence.

Временная близость сама по себе разрешена только для соседних chunks одной камеры до 90 секунд и надёжной даты. Совпадение календарного дня никогда не является достаточным основанием. Hard split применяется к слишком большим временным разрывам и к пространственно далёким материалам без смысловой связи; сильные GPS + semantic/activity evidence могут сохранить одно многодневное путешествие.

Результат содержит confidence и до семи объяснимых `EventClusteringEvidence`. Диагностика отдельно считает detected/merged/split events, cross-device matches и camera offsets.

## Scenes and event quality

Внутри кластера кандидаты упорядочиваются по нормализованному capture time и группируются по времени, semantic overlap и cross-camera coverage. Energy peak определяет фазовую структуру:

`setup → preparation/action → peak → reaction → conclusion`

Односценное событие получает фазу `peak`; короткие события используют доступное подмножество фаз. `EventQuality` агрегирует visual quality, semantic/temporal coherence, usable material, emotion, action, uniqueness, story potential и scene/device/tag diversity.

`EventTitleGenerator` сначала использует уверенные semantic patterns (`Сплав`, `Велопрогулка`, `Рыбалка`, `Вечер у костра`, `Поход` и другие), затем безопасные contextual/date fallbacks. Title confidence хранится отдельно от clustering confidence.

## Event-first Story Engine

При наличии P4 events Story Engine больше не выбирает глобальный список клипов напрямую:

1. ранжирует и отбрасывает слабые события;
2. строит хронологический event order;
3. распределяет длительность по EventQuality и usable material;
4. внутри каждого события резервирует сильный момент каждой сцены/фазы;
5. добавляет camera diversity и только затем заполняет остаток бюджета;
6. создаёт event/scene-aware `StoryChapter`;
7. опционально использует один осознанный cold open, после которого основная история остаётся хронологической.

`EventDurationAllocator` ограничивает слабые события и не возвращает им время при перераспределении остатка. Для больших событий selection предпочитает setup/preparation/action/peak/reaction/conclusion вместо серии похожих дублей. P3 strategy и Personal Taste корректируют event rank, chapter titles и duration, но не обходят hard chronology/safety constraints.

`TimelineComposer` использует существующие `.title` items для project title и event chapter cards. Он сохраняет `eventID`/`eventSceneID` на каждом primary clip и контролирует фактический clip budget события. UI и renderer не получают нового типа визуального объекта.

## Global selection and transactional repair

`MontageGlobalScore` дополнен шестью event-level компонентами:

- event order;
- event diversity;
- event coverage;
- chronology;
- scene diversity;
- inter-event semantic separation.

Они участвуют в absolute score, pairwise comparison и weak gate. Directed variant с плохой chronology или event coverage отбрасывается до турнира. Transactional self-review не может закоммитить repair, который ухудшает event order, chronology или coverage, даже если локальный review score вырос.

## Diagnostics

`DirectorRunSummary.eventDiagnostics` сохраняет:

- число detected/merged/split events;
- confidence и title каждого события;
- date ranges и выбранный event order;
- число сцен;
- cross-device match count и clock offsets;
- explainable clustering reasons.

Полные variant scores, pairwise outcomes, Pareto decisions и rejection reasons остаются в существующем `variantDiagnostics`. Поэтому один persisted run можно разобрать без повторного анализа и без ручной оценки.

## Performance and safety

- Archive-level clustering выполняется один раз после анализа всех изменившихся файлов, а не после каждого asset; это исключает O(n³) поведение на больших импортах.
- Временная сортировка позволяет прекратить pair scan после максимального multi-day window.
- P2 director candidates и scoring indexes переиспользуются; originals не изменяются.
- Event discovery полностью deterministic/offline и не блокирует фильм при отсутствии GPS, embeddings, ASR или точной даты.
- При отсутствии пригодных events Story Engine автоматически использует прежний candidate-first path.

## Verification matrix

`EventIntelligenceTests.swift` покрывает:

- cross-device event и clock offset;
- четыре разных события одного дня;
- одно многодневное путешествие;
- одинаковое место через несколько недель;
- одну камеру в разное время и в разных местах;
- фазовые EventScenes;
- архив из 320 assets с bounded runtime;
- human title и date fallback;
- запрет merge по low-confidence import timestamps;
- GoPro chapters, iPhone Live Photo и phone timestamp filenames;
- стабильность Event/EventScene identity;
- EventQuality duration allocation;
- production `Project → Event → Scene → Moment → full variant/director/scoring → persisted Timeline` path.

Полный прогон: `./Scripts/dev-test.sh --no-parallel`. Полная app-сборка: `./Scripts/build-app.sh`.

## Known boundaries

- P4 не выполняет face recognition между проектами: people evidence ограничено локальными P2 labels/tracks.
- Semantic location не заменяет reverse geocoding; GPS хранится численно, а human place name используется только при наличии analysis evidence.
- Очень длинные архивы с неоднозначными/исправленными вручную датами используют confidence-aware conservative split; новый UI для ручного объединения событий намеренно не добавлен.
