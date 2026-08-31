# AI Director 2.0 — матрица приёмки

Реализация построена по цепочке `CandidateInsights → StoryPlan → AIDirectorEngine → DirectorEditingTools → TimelineSelfReviewer → Timeline`. Модель не исполняет произвольный код: каждое изменение является типизированной, валидируемой и обратимой операцией над Timeline.

| Сценарий ТЗ | Реализация и автоматическая проверка |
|---|---|
| Удаляет слабые клипы | `lowQualityShot → rippleDelete`; `selfReviewRemovesAnUnjustifiedTechnicallyWeakShot` |
| Добавляет клипы из исходников | `DirectorToolCall.insert`; `directorEditingToolsValidateAndExecuteStructuralTimelineChanges` |
| Берёт разные фрагменты одного исходника | multi-candidate source ranges; `originalURLAndSourceRangeArePreserved`, story tests |
| Меняет порядок | `reorder`; structural tools test |
| Меняет длительность | role/interest-aware trim и variable duration; autonomous director test |
| Меняет скорость | `setSpeed`; autonomous director и editor-command tests |
| Делает speed ramp | `setSpeedRamp`; autonomous director и FCPXML ramp tests |
| Использует slow motion | high-FPS climax decision; autonomous director test |
| Меняет переходы | semantic transition decisions и self-review cleanup; editor/playback tests |
| Редактирует музыку | BPM/beat/section structure, повторная синхронизация после re-edit; music tests |
| Меняет audio | volume/fades/noise/EQ/detach/ducking; editor-command и playback tests |
| Использует B-roll | contextual cutaway overlay; autonomous director test |
| Применяет визуальные настройки | crop/motion/color/stabilization/sharpen/denoise/blur; render tests |
| Использует telemetry | только при подтверждённом GPMF; autonomous director и telemetry tests |
| Перестраивает весь фильм | regenerate повторно запускает Story Plan и Director по всем кандидатам; pipeline tests |
| Сам исправляет слабый монтаж | bounded review/re-edit, score не ухудшается; self-review tests |
| Не коммитит ухудшающий re-edit | `TimelineReviewTransaction` выполняет repair на копии и отклоняет её без роста score; transaction test |
| Уточняет границы действия | `MomentBoundaryRefiner`: anticipation/peak/completion-reaction по visual/motion/audio onset+events/telemetry/subject/ASR/VLM evidence; multimodal test |
| Меняет критерии лучших моментов по жанру | injectable `HighlightRanking` + `ContextualHighlightRanker`; story tests |
| Создаёт действительно разные варианты | общий `VariantDistanceCalculator`, 18 контекстных стратегий, minimum-distance gate и до 10 production-вариантов; production-path test |
| Сравнивает готовые монтажи по качеству | `MontagePairwiseComparator` проводит round-robin по 20 quality components, включая subject/speech/audio events/visual semantics/music structure, и объединяет pairwise utility с absolute score; pairwise quality test |
| Автоматически отбрасывает слабые/похожие варианты | rough и directed diversity gates, absolute lag и hard component floors; причины попадают в diagnostics |
| Не принимает формально лучший, но небезопасный repair | combined global score, `TimelineSafetyValidator`, bounded single/pair beam; safety test |
| Сохраняет фазу момента после trim | `MomentPhaseTrimmer` в Composer и Director с anticipation/reaction handles; phase test |
| Объясняет выбор победителя | persisted `VariantSelectionDiagnostics` с full scores, pairwise results, wins/losses/ties, distances, selection и rejection reasons; production-path persistence test |
| Сравнивает несколько готовых монтажей | каждый принятый StoryPlan проходит TimelineComposer, music sync, AIDirectorEngine и self-review до scoring; variant test |
| Выбирает без участия человека | pairwise tournament автоматически коммитит один winner; UI и user flow не изменены |
| Использует музыкальные фразы и акценты | measured downbeats/bars/phrases/drops/accent grid с кэшем структуры; music tests |
| Находит семантические дубли и лучший дубль | cached `EmbeddingModelProtocol` + `SemanticSceneIndex`; cross-video semantic event и large-library tests |
| Удерживает героя при смене формата | selective `LocalSubjectTracker` + `SubjectAwareReframeEngine`; compositor/FCPXML intent и reframe tests |
| Не обрывает речь | on-device ASR + phrase/silence boundaries + Timeline-aware speech score; ASR boundary/global scoring tests |
| Понимает события исходного звука | DSP audio event classifier влияет на highlight rank, boundaries, audio decisions и global score; audio-event tests |
| Объясняет deep-analysis | `DirectorRunSummary.deepMediaDiagnostics` хранит stages/cache/confidence/counts/discarded/timings; production-path test |
| Работает через «Волшебную кисть» | range slicing + локальные typed AI-команды; два Magic Brush tests |
| Сохраняет Undo/Redo | полные Timeline snapshots и persistent checkpoints; checkpoint/production tests |
| Не меняет оригинальные файлы | read-only original URL + derived cache; structural/original-range tests |
| Экспортирует MP4/FCPXML | единый playback/render builder и capability-aware FCPXML; ExportTests |

Полный прогон: `./Scripts/dev-test.sh --no-parallel`. Готовый bundle собирается только через `./Scripts/build-app.sh`.
