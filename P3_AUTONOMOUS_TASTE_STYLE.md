# P3 / AI Director 3.0: Autonomous Taste & Style Engine

P3 реализован поверх единого P0/P1/P2 production pipeline и принимает P4 Event Intelligence как дополнительный архивный контекст. Он не создаёт второй Story Engine, отдельный набор candidates, ручной A/B workflow или новый UI. Пользователь может запустить `Import → AI Edit`; preset и числовая длительность UI используются только как слабый fallback/soft purpose hint. Если длительность явно написана в естественном языке, она становится реальной целью, но не заставляет заполнять фильм повторами.

## Production flow

`P2 enriched directorCandidates → P4 Event/EventScene hierarchy → ProjectStyleProfile → PersonalTasteProfile blend → optimal event-aware duration → autonomous story/grammar/music intent → up to 10 style-space variants → full TimelineComposer/music/AIDirector/self-review → absolute safety gates → Pareto front → pairwise tournament → final Timeline`

Дорогой media analysis не повторяется. P3 работает поверх embeddings, semantic-event IDs, subject tracking, ASR, audio events, DSP, telemetry, MomentBoundary и cached MusicStructure.

## Continuous style space

`DirectorStyleVector` хранит непрерывные координаты:

- energy, cinematic, emotional, action, intimacy и atmosphere;
- pacing, visual density и shot duration;
- transition intensity и music intensity.

`AutonomousProjectStyleEngine` выводит `ProjectStyleProfile` из usable moments, people/action/speech/telemetry share, P2 composition/dynamics/audio evidence, P4 event/scene diversity и cross-device context. `internalLabel` (`ACTION_TRAVEL`, `EMOTIONAL_PEOPLE`, `FAMILY_MEMORY_ARCHIVE` и т. п.) нужен только для диагностики и contextual taste; это не preset и не пользовательский переключатель. При недостатке данных профиль смешивается с neutral/fallback style, а confidence ограничивает эффекты, transitions и агрессивный beat-sync.

## Autonomous duration

`AutonomousDurationOptimizer`:

1. устраняет semantic duplicates/best-take repetitions;
2. считает длительность только сильных уникальных моментов;
3. добавляет ограниченный structural allowance для связности;
4. не превышает content ceiling;
5. при low confidence выбирает короткую безопасную сторону range;
6. учитывает явно написанную пользователем длину как objective, но не как приказ растягивать слабый материал.

Результат `OptimalDurationDecision` содержит seconds, confidence, safe range, число strong moments и explainable reasons. Решение сохраняется в `StoryPlan.autonomousDecision` и `DirectorRunSummary.autonomousDecision`.

## Project Taste и Personal Taste

Project Taste — стиль, подходящий текущему материалу. Personal Taste — локальная статистика естественных действий пользователя. Итоговый style смешивает их пропорционально confidence; при малом числе сигналов проект всегда доминирует.

`PreferenceSignalExtractor` анализирует реальные Timeline before/after и извлекает сигналы из delete/restore, trim, reorder, speed/slow motion, transition, music, title, crop/reframe, telemetry, undo и regenerate. Сигнал не содержит file path, transcript, prompt, thumbnail, media ID или candidate ID — только feature, signed direction, confidence, broad context и timestamp.

`PreferenceLearningEngine` использует neutral prior, Bayesian evidence update, 180-day decay, global и contextual estimates. Один edit имеет низкую confidence и не может резко изменить стиль. `LocalPersonalTasteStore` хранит device-local профиль в Application Support; project package содержит ограниченную копию профиля и последние 240 anonymized signals для переносимости/аудита.

Ручные оценки и экран «A или B?» отсутствуют. Правки AppModel передаются в `VeloEditPipeline.recordPreferenceSignals` последовательно после успешной Timeline mutation; Undo/Redo и regenerate имеют отдельные source labels.

## Autonomous grammar and story

`AutonomousEditingGrammar` определяет mean/variation shot duration, cut density, transition/effect density, speed ramps, slow motion, B-roll/reaction/photo motion, telemetry и titles. Clean cut остаётся default. Даже высокая transition intensity разрешает только меньшинство мотивированных переходов; effects получают ещё меньший budget.

`AutonomousStoryDecision` выбирает материал-зависимую структуру:

- cold open;
- journey/discovery;
- emotional journey;
- rapid peak/reaction;
- atmospheric observation;
- minimal montage;
- adaptive arc.

Story Engine применяет pattern к реальному ordering/role assignment. Atmospheric/minimal variants не штрафуются за отсутствие обязательной классической `INTRO → ... → CLIMAX → OUTRO` дуги: global scorer сравнивает их с выбранным pattern.

## Music selection

`AutonomousMusicIntent` хранит desired energy/BPM/duration, mood tokens, narrative energy curve, build/drop requirement, beat-sync intensity и confidence. Все доступные локальные tracks анализируются один раз параллельно через общий `MusicStructureCache`. `AutonomousMusicTrackScorer` учитывает mood/genre, tempo, energy, duration coverage, measured editability (downbeats/phrases/sections/drop confidence) и сходство track energy curve с narrative arc. При low confidence aggressive beat-sync отключается. Явный запрос музыки или `без музыки` имеет приоритет.

## Variant search and multi-objective selection

Один base decision порождает style-space probes: action/telemetry, quiet/cinematic, emotional/original-audio, novelty/contrast и balanced strategies. Для каждого меняются не только ranks, но и duration, shot length, story pattern, music intent и production tool decisions.

После существующих rough/directed distance и weak/safety gates `MontageParetoAnalyzer` оставляет non-dominated варианты по story, continuity, emotion, pacing, music/audio, technical quality, project style, personal taste, duration и moment completeness. Pairwise tournament работает только по Pareto front. Weighted global total остаётся calibrated signal, но один spike больше не компенсирует доминирование по нескольким независимым целям.

`MontageGlobalScore` и pairwise comparator дополнительно сохраняют:

- emotional curve;
- pacing quality;
- ProjectStyle fit;
- PersonalTaste fit.

`DirectorRunSummary` содержит autonomous decision, all variant scores, distances, pairwise results, Pareto-front strategies, winner/rejection reasons и P2 diagnostics.

## Explainability

Decision reasons передаются в `DirectorContext`. По запросам «почему/объясни» language director получает фактические ProjectStyle/duration/selection reasons; deterministic fallback также отвечает ими, не выдумывая причин.

## Compatibility and fallbacks

- Все P3 manifest fields optional; старые project packages декодируются без миграции.
- Нет P2 evidence: используется legacy summary/tags и neutral confidence policy.
- Нет preference history: Personal Taste weight равен нулю.
- Нет подходящего/доступного track: фильм остаётся работоспособным с original audio и существующим non-fatal music warning.
- Low style/duration/music confidence: короткая безопасная версия, neutral grammar, мало transitions/effects и слабый beat-sync.
- Явные natural-language constraints, excluded/locked clips и hard Timeline safety остаются выше автономных решений.

## Tests

`AutonomousDirectorTests.swift` проверяет style inference, duration without padding, Bayesian/contextual/decayed preference learning, project-vs-personal blend, structural music matching, confidence-safe grammar, genuinely different style probes, implicit signals, Pareto domination, explainability и полный production path:

`raw analyzed project → autonomous style → duration → story/music/grammar → multiple variants → full directing → global/Pareto/pairwise selection → persisted final timeline → natural edit signal`

Полная проверка: `./Scripts/dev-test.sh --no-parallel`. Полная app-сборка: `./Scripts/build-app.sh`.
