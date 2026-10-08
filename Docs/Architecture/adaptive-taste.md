# P7 — Personal Taste & Adaptive Editing Engine

## Цель

P7 постепенно учит VeloEdit монтажному вкусу пользователя по естественным правкам и автоматически применяет выученное в следующем фильме. Ручные оценки, A/B-экран, обязательный выбор стиля и облачная синхронизация не используются.

Система расширяет существующий P3-путь, а не создаёт отдельный режиссёр:

`Timeline edit → AdaptivePreferenceSignalExtractor → LocalPersonalTasteStore → AutonomousDirectorEngine → StoryEngine → AIDirectorEngine/P6 → PersonalizedMontageScorer → pairwise winner`

## Модель профиля

`PersonalTasteProfile` сохраняет прежние Bayesian `preferences` и добавляет backward-compatible optional P7-поля:

- pacing, clip duration и story density;
- action/calm balance;
- transitions, effects, slow motion и photo motion;
- music sync, titles, telemetry и color;
- ending preference;
- contextual duration для film/action/calm/intro/climax/outro;
- context models, anonymous visual embedding centroids, discovered style;
- music/title detail models, learned story-role patterns;
- bounded automatic regression samples.

Каждый `AdaptiveTasteEstimate` содержит `value`, `confidence`, `sampleCount`, positive/negative/neutral counts и `lastUpdated`. Confidence растёт плавно: примерно 0.16 после одного сильного сигнала, 0.43 после пяти, 0.78 после двадцати и 0.95 после пятидесяти. Evidence экспоненциально устаревает с half-life 180 дней, поэтому старые привычки не становятся вечными.

## Сигналы

`AdaptivePreferenceSignalExtractor` сначала вызывает существующий P3 `PreferenceSignalExtractor`, затем добавляет контекстные evidence:

- delete/restore с различением action и calm по роли и measured dynamics;
- trim direction и нормализованную фактическую длительность film/action/calm/intro/climax/outro;
- reorder и learned role sequence;
- transition, speed ramp, slow motion, zoom, stabilization, telemetry, title, color, sound effect и photo motion;
- BPM, music structure/beat sync и замены трека;
- семантические tokens и normalized visual embedding удалённого/возвращённого момента.

На диск не попадают media path, asset/candidate ID, thumbnail, frame, transcript или текст пользовательского запроса. Embedding-память хранит только нормализованные positive/negative centroids и веса широких visual tokens.

## Контексты

`TasteContextResolver` строит context key из доступных evidence: activity, continuous project type, event type, camera type, social format, duration bucket и самостоятельно найденные broad tokens (`water`, `sunset`, `pov`, `people` и подобные). Global preference всегда остаётся prior; context получает не более 72% локального веса. Поэтому вкус для cycling/action не перезаписывает family/travel edit после одной правки.

## Автоматическая длительность и explore/exploit

`AutonomousDirectorEngine` использует learned film duration только при отсутствии явной длительности в запросе. Значение смешивается с material-dependent `AutonomousDurationOptimizer` и обязательно остаётся внутри его safe range: слабым материалом фильм не дополняется. Learned clip duration корректирует grammar постепенно; BPM и beat-sync preference — structural music intent.

`TasteExplorationPolicy` детерминированно использует fingerprint проекта. 90% запусков эксплуатируют strongest learned profile, 10% при достаточном evidence исследуют одну ближайшую under-observed style dimension. Изменение ограничено малой дистанцией в continuous style space. Принятый последующей правкой результат становится обычным positive evidence; отдельного UI нет.

## Personalized global scoring

`MontageVariantSelector` по-прежнему получает полные production-варианты P1/P6. При наличии профиля `PersonalizedMontageScorer` пересчитывает каждый вариант через один combined слой:

- GlobalScore — 60% core;
- technical quality — 12%;
- contextual/project/story/pacing fit — 10%;
- PerceptualScore — 18%;
- Personal Taste получает динамический вес внутри результата, от 0 до 16% по confidence.

Таким образом taste работает как уверенный tie-breaker между технически допустимыми решениями, но не может скрыть black frame, broken moment, низкое technical quality или perceptual regression. Персонализированный score участвует и в absolute gates, и в существующем Pareto/pairwise tournament — это реальное влияние на winner, а не диагностическое поле после выбора.

`DirectorRunSummary.personalTasteDiagnostics` сохраняет context, confidence, signal count, discovered style, explore/exploit mode, полный `PersonalTasteScore` каждого production-варианта, причины выбора и последний regression report.

## Transactional learning и regression protection

Сильный signal — сравнение AI-proposed Timeline и фактически принятого Timeline. `TimelineTasteFeatureExtractor` сохраняет только агрегаты, а P1/P6 дают automatic quality before/after. `TasteRegressionGuard` проверяет proposed profile на bounded локальных `TasteRegressionSample`:

- новый профиль не должен заметно хуже ранжировать ранее принятые edits;
- accepted Timeline не должен проваливать automatic quality floor относительно AI proposal;
- при нарушении профиль не коммитится атомарно.

Это не Golden Corpus с человеческими оценками и не human-in-the-loop. Samples формируются автоматически из production Timeline, GlobalScore и PerceptualScore; максимум 48 хранится локально.

## Хранение, экспорт и сброс

`LocalPersonalTasteStore` пишет JSON атомарно в Application Support, поддерживает `recordValidated`, `export(to:)` и полный `reset()`. `VeloEditPipeline` синхронизирует device-local profile с project manifest. В Settings доступны экспорт JSON и подтверждаемый сброс; сеть не вызывается.

## Production path и тесты

`AdaptiveTasteEngineTests` проверяет:

- confidence milestones, polarity counts и decay;
- separation контекстов;
- delete/restore/trim/reorder/effect/color/music/structure signals;
- реальное изменение autonomous duration, shot duration и BPM;
- personalized scoring и technical safety floor;
- deterministic 90/10 exploration;
- automatic regression rejection без human ratings;
- persistence/export/reset и offline behavior;
- десять независимых edit contexts, после которых одиннадцатый проект проходит `StoryEngine → TimelineComposer → AIDirectorEngine/P6 → MontageVariantSelector` и сохраняет P7 diagnostics.

