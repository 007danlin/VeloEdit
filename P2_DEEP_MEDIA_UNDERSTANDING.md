# P2: Deep Media Understanding & AI Director

P2 реализован поверх P0/P1 без нового UI, обязательного cloud AI, taste engine и второго набора кандидатов. Каноническая единица отбора остаётся `AnalysisResult.directorCandidates`; P2 добавляет в `CandidateInsights` опциональные evidence, поэтому старые project packages и fallback без deep-analysis продолжают работать.

## Production pipeline

`Import → metadata/GPMF → adaptive key frames → candidates → embeddings → selective subject tracking → audio events/ASR → multimodal MomentBoundary → Story variant search → TimelineComposer → music DSP/sync → AI Director → global/pairwise scoring → transactional review → final Timeline`

Дорогие признаки считаются до variant search и переиспользуются всеми вариантами. `VeloEditPipeline.analyzeMissing` передаёт один `FrameCache` и один `DeepAnalysisCache` на весь запуск. Аудио, embeddings, ASR и tracking сохраняются по content hash; Music structure сохраняется рядом с локальным треком. Повторная режиссура не декодирует исходники заново.

## Реализованные компоненты

### Semantic index

- `EmbeddingModelProtocol` принимает `EmbeddingInput` из уже декодированных adaptive/key frames.
- `LocalVisualEmbeddingModel` строит нормализованный 64-D локальный descriptor из luminance histogram, spatial luminance и semantic labels. Реализация заменяема learned-моделью через тот же протокол.
- `SemanticSceneIndex` предоставляет similarity search, clustering и best-take ranking.
- До 384 кандидатов сравниваются точно. Большие библиотеки используют deterministic locality buckets и bounded representatives, сохраняя within-asset comparisons и fallback по тегам.
- `CrossVideoRelationshipAnalyzer` назначает группе общий `semanticEventID`, снижает uniqueness слабых дублей и передаёт discarded IDs в диагностику. Story Engine не выбирает одно semantic event повторно.

Основные файлы: `DeepMediaUnderstanding.swift`, `AnalysisEngine.swift`, `AnalysisPipelineModels.swift`, `StoryEngine.swift`.

### Subjects and reframe

- Apple Vision извлекает faces, attention saliency и object class для adaptive frames.
- `LocalSubjectTracker` связывает observations во времени, выбирает main/secondary tracks, оценивает visibility, composition и направление движения.
- Tracking запускается только после candidate detection: 2 кандидата в Fast, до 6 в Balanced, весь shortlist в Quality/Maximum.
- `SubjectAwareReframeEngine` строит safe-area trajectory с motion lead room и face/object crop protection.
- AI Director записывает `SubjectReframePlan` в `VideoAdjustments`; custom compositor выполняет динамический reframe. FCPXML получает переносимый средний transform и полную start/end trajectory в metadata. Для фото та же траектория управляет subject-aware Ken Burns.

Основные файлы: `AdaptiveAnalysis.swift`, `DeepMediaUnderstanding.swift`, `AIDirectorEngine.swift`, `VeloVideoCompositor.swift`, `FCPXMLExporter.swift`.

### Speech and audio events

- `AppleOnDeviceSpeechRecognizer` использует только `requiresOnDeviceRecognition`, word timestamps, sentence/phrase boundaries, confidence и silence ranges. Permission запрашивается только в deep-профиле, когда DSP уже обнаружил вероятную речь.
- Если on-device Speech, locale/model или permission недоступны, монтаж не блокируется: используются DSP speech/silence boundaries.
- `SpeechEditingEvidence.editorialImportance` отличает содержательную целую реплику/реакцию от пустой или filler-only речи без обучения taste.
- `MomentPhaseTrimmer` может превысить номинальную pacing-длину ради целой фразы. Global scorer проверяет уже фактический Timeline trim, поэтому обрезанный клип не наследует устаревший флаг complete phrase.
- `DSPAudioEventClassifier` различает speech, laughter, applause, scream, impact, splash, engine, wind, crowd, nature/ambient, music и silence по bounded windows RMS/peak/ZCR/onset/spectral-flux.

Основные файлы: `LocalSpeechRecognizer.swift`, `AudioAnalysis.swift`, `DeepMediaEnricher.swift`, `VariantQuality.swift`.

### Multimodal boundaries

`MomentBoundaryRefiner` объединяет motion/visual interest, semantic evidence, audio onset, audio events, telemetry, subject visibility, ASR boundaries и VLM score. Результат всегда содержит `anticipationStart`, `peakTime`, `completionEnd`, confidence и evidence. При confidence ниже 0.42 deep enricher и trimmer сохраняют консервативный исходный range; агрессивный trim запрещён.

### Music DSP

`LocalAudioAnalyzer` строит onset/energy envelopes и оценивает tempo автокорреляцией. `MusicSyncEngine` определяет measured beat phase, meter (3/4/5/6 с выбором фундаментального периода), downbeats, bars, phrases, sections, quiet ranges, breakdowns, transitions, drops и section peaks. Каждый accent/section и тип структуры имеет confidence. Если decoded envelope недоступен, сохраняется явно низкоуверенный BPM fallback.

Music sync использует role-aware anchors: climax предпочитает drop/section peak/phrase/downbeat, action — strong beat/downbeat/onset. Global scorer отдельно оценивает music structure quality и confidence-weighted drop–climax alignment.

Основные файлы: `AudioAnalysis.swift`, `MusicSyncEngine.swift`, `MusicLibrary.swift`, `MontageVariantScoring.swift`.

## Global scoring и diagnostics

`MontageGlobalScore` теперь нормализует и сохраняет:

- highlight, story arc, beginning/end и emotional curve;
- semantic/source/asset diversity;
- moment completeness и energy/rhythm curve;
- continuity: semantic bridge/repetition, movement direction, shot scale, composition, exposure и source overlap;
- technical quality и subject composition/reframe safety;
- speech continuity, original-audio continuity и audio-event coherence;
- beat/music alignment, structure confidence и drop–climax alignment.

Новые компоненты участвуют и в absolute score, и в `MontagePairwiseComparator`. `DirectorRunSummary` сохраняет агрегированные `DeepMediaDiagnostics`: какие stages реально запускались, cache hits, confidence, counts embeddings/tracking/ASR/audio events, near-duplicates/discarded candidates и stage/total timings. P1 `variantDiagnostics` по-прежнему содержит все production scores, distances, pairwise outcomes, причины победы и отклонения вариантов.

## Fallbacks и границы P2

- Нет embeddings: semantic index использует теги/scene summary и score distance.
- Нет subject: Timeline остаётся с обычным conform/crop и существующим photo motion.
- Нет Speech permission/model: DSP speech boundaries; приложение не отправляет звук в cloud.
- Нет decoded music envelope: low-confidence BPM grid, помеченная `analysisIsMeasured = false`.
- Нет VLM/телеметрии/аудио: boundary refiner работает по доступным visual signals.
- P2 не выбирает пользовательский taste/style, не учится на предпочтениях и не меняет UI.

## Проверка

`DeepMediaUnderstandingTests.swift` покрывает similarity/near-duplicates/best take, cross-video semantic event, subject tracking/reframe, ASR-aware multimodal boundaries, audio events, non-4/4 music, phrases/drops/confidence, новые global-score компоненты, persistent cache, backward-compatible score decoding и полный production photo path.

Performance fixture строит 2 400 кандидатов для 300 camera files и требует завершить clustering менее чем за 5 секунд; текущий debug-run занимает около 1.2 секунды. Полный набор выполняется `./Scripts/dev-test.sh --no-parallel`, приложение — `./Scripts/build-app.sh`.
