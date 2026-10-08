# P6 Perceptual Editor / AI Visual Quality Loop

## Статус

P6 реализован как дополнительный quality loop поверх P0–P5. Он не заменяет `TimelineSelfReviewer`, `MontageGlobalScore`, P1 variant tournament или P5 render hardening и не меняет UI. Каждый production-вариант получает анализ воспринимаемого качества по Timeline/evidence, а автоматический победитель дополнительно проверяется по выборочно декодированным кадрам реальной `AVComposition`.

Production-путь:

```text
P4 Events → P3 Story/Style → Variant Search → TimelineComposer
    → Music Sync → AI Director → legacy self-review
    → P6 hierarchical perceptual review
    → speculative repair beams → global + perceptual + safety commit
    → global/pairwise variant tournament
    → selective rendered-preview review победителя
    → optional one-pass repair → rendered verification → final Timeline
```

## Компоненты

- `PerceptualMontageReviewer` проходит уровни Film → Event/Scene context → Shot → Cut и возвращает `PerceptualReviewResult`.
- `PerceptualScore` остаётся отдельным от `MontageGlobalScore`: continuity, composition, moment completeness, pacing, music alignment, audio continuity, visual variety, story coherence, effect quality, title quality и technical integrity.
- `CutQualityScore` создаётся для каждой соседней пары primary shots и учитывает motion/screen direction, subject continuity, composition/exposure, action completion, audio continuity и source repetition.
- `PerceptualFinding` сохраняет severity, scope, timeline range, type, confidence, объяснение, item IDs и несколько допустимых repair suggestions.
- `PerceptualReviewEngine` преобразует уверенные findings в существующие `DirectorToolCall`; отдельной системы редактирования нет.
- `PerceptualReviewTransaction` сравнивает speculative copy по `0.62 × GlobalScore + 0.38 × PerceptualScore`, проверяет `TimelineSafetyValidator` и hard perceptual constraints, после чего commit или rollback выполняется целиком.
- `PerceptualRenderInspector` декодирует только cut neighborhoods, centers титров/effects/telemetry и bounded film samples из той же `AVComposition`, которую строит `PlaybackEngine`.

## Что фактически проверяется

### Shot и moment

Source range сопоставляется с `MomentBoundary.anticipationStart`, `peakTime` и `completionEnd`. Для уверенного boundary обязательны anticipation/reaction handles; поздний вход, потерянный peak и выход до completion создают разные severity. P6 может расширить trim до полного момента или сравнить замену лучшим дублем.

### Cut и continuity

Для каждой склейки проверяются:

- направление и величина движения главного объекта из P2 tracks;
- положение, visibility и kind героя на выходе/входе;
- composition/exposure jump;
- завершённость действия до cut;
- speech/audio-event boundary;
- повтор source range и чрезмерно близкая semantic/composition пара.

Отсутствующее deep evidence приводит к нейтрально-консервативной оценке, а не к выдуманной уверенности.

### Rhythm, story и music

Pacing сравнивается не с одним универсальным порогом, а с `ProjectStyleProfile`/`AutonomousEditingGrammar`: mean shot duration, variation и наличие breathing shots. Story review проверяет role coverage, положение climax, energy peak и ending/reaction. Music review использует measured accents, downbeats, phrases, drops и фактический source peak внутри climax item.

### Audio

P2 ASR evidence защищает начало/конец фразы и естественные паузы. Laughter, applause, scream, impact и splash не должны обрываться границей. Межкадровая оценка учитывает audio quality/original-audio usefulness; полезный исходный звук не выключается только ради числовой метрики.

### Effects, titles и telemetry

Немотивированные или чрезмерные effects/transitions сравниваются с P3 grammar; P6 предлагает removal через существующие editable objects. Title bounds оцениваются по реальному style/position/scale и P2 subject region. Telemetry использует точные normalized widget layouts. Уверенное перекрытие героя может привести к transactional reposition в свободную safe area.

### Render-aware integrity

Финальный winner строится `PlaybackEngine` с `forceVideoComposition`, затем bounded sampler проверяет фактически декодированные кадры. `FrameQualityInspector` отличает чёрный кадр от тёмного текстурного, а 8×8 perceptual hash обнаруживает ненамеренное frozen repetition. Фото и явный freeze-frame не считаются ошибкой. После принятого render-grounded repair выполняется ровно одна повторная сборка и проверка.

Если media source/codec на текущем host не позволяет построить preview, валидная Timeline не отбрасывается: `renderReviewStatus` получает `render-review-unavailable` с причиной. Metadata/evidence review и уже принятые безопасные repairs сохраняются.

## Transactional safety и бюджет

По умолчанию допускаются две успешные итерации, до восьми repair calls и до двадцати single/pair beams на итерацию. Автоматически применяются только findings выше confidence threshold. Каждый beam:

1. применяется к копии `Timeline` через `DirectorEditingTools`;
2. полностью пересчитывает `PerceptualScore` и `MontageGlobalScore`;
3. проходит source/lock/story/event hard safety;
4. не может ухудшить technical integrity, moment completeness или добавить critical finding;
5. не может потерять уже мотивированный stabilization/reframe/audio/retime/telemetry treatment при замене;
6. коммитится только при минимальном улучшении combined score.

Отклонённые beams считаются rollback и остаются в диагностике. Когда улучшения закончились, loop останавливается.

## Диагностика

`DirectorRunSummary` сохраняет:

- `perceptualReviewIterations`;
- `perceptualFindings` и `highSeverityFindings`;
- `perceptualRepairsAttempted/Accepted/Rejected`;
- `perceptualRollbackCount`;
- `perceptualScoreBefore/After`;
- полный `PerceptualReviewSummary` с component scores, cut scores, каждым repair attempt, sample count и render status.

Эти поля optional, поэтому старые project manifests декодируются без миграции.

## Производительность

- Все варианты используют уже рассчитанные P2/P3/P4 evidence и один `MontageScoringFeatures` на P6 run.
- Никакого повторного Vision/ASR/embedding анализа нет.
- Metadata review линейный по shots/cuts; semantic similarity использует существующий index.
- Variants по-прежнему выполняются параллельно.
- Реальная `AVComposition` строится только для победителя; sampling ограничен 48 кадрами и повторно использует P5 derived-media cache.
- После render repair разрешена только одна проверочная сборка.

## Тесты

`PerceptualReviewTests.swift` покрывает opposite screen direction, late entry/cut climax, cut speech/laughter, measured drop–climax alignment, title/subject occlusion, black/frozen evidence, commit/rollback, реальное декодирование `AVComposition`, production `AIDirectorEngine` с фактическим изменением плохой Timeline и persisted end-to-end `VeloEditPipeline.createFilm` с 302 assets.

## Ограничения

- P6 работает с наблюдаемыми локальными evidence и не генерирует новые кадры.
- Shot scale/horizon/camera angle оцениваются через доступные composition/subject/embedding признаки; отдельной обученной эстетической модели в P6 нет.
- Bounds обычного title выводятся из editable style; telemetry layouts точные. Проверка реального rendered winner служит финальным предохранителем.
- Low-confidence finding сохраняется для диагностики, но не меняет Timeline автоматически.

