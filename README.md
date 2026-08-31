# VeloEdit

Нативный offline-first AI-режиссёр для macOS Apple Silicon. VeloEdit импортирует фото/видео ссылками, сохраняет анализ, строит монтаж по русскоязычному запросу, создаёт preview/MP4 и экспортирует редактируемый FCPXML с оригинальными source ranges.

Текущая версия включает P7 Adaptive Editing Engine поверх P2–P6. P2 Deep Media Understanding создаёт embeddings, semantic events/best takes, subject tracking/reframe, on-device ASR, audio events и точные `anticipation → peak → completion/reaction`. P4 объединяет metadata/GPS/GPMF/visual/semantic/people/activity/audio/device evidence в иерархию `Project → Event → Scene → Moment → Asset`, а Story Engine сначала выбирает и упорядочивает события. P3 поверх тех же evidence автономно выводит continuous ProjectStyle, оптимальную длительность, story pattern, clean-cut grammar и structural music intent; затем до десяти существенно разных вариантов проходят полный production pipeline, Pareto gate и автоматический pairwise tournament. P5 добавляет optimistic Timeline edits, revision-safe commits, interactive preview quality, persistent derived-media cache, bounded memory и black-frame recovery. P6 отдельно оценивает готовую последовательность shots/cuts, continuity, complete moments, rhythm, music/audio, overlays и technical integrity. P7 учится по delete/restore/trim/reorder/effects/music/title/telemetry, разделяет контексты, применяет decay и automatic regression gate, а `PersonalizedMontageScorer` реально участвует в global/pairwise выборе winner. Все scores, findings, repairs, rollback, taste/regression, Pareto/pairwise decisions и причины сохраняются в `DirectorRunSummary`; ручной A/B-выбор не требуется. Схемы: [P2_DEEP_MEDIA_UNDERSTANDING.md](P2_DEEP_MEDIA_UNDERSTANDING.md), [P3_AUTONOMOUS_TASTE_STYLE.md](P3_AUTONOMOUS_TASTE_STYLE.md), [P4_EVENT_INTELLIGENCE.md](P4_EVENT_INTELLIGENCE.md), [P5_PRODUCTION_HARDENING.md](P5_PRODUCTION_HARDENING.md), [PERCEPTUAL_REVIEW.md](PERCEPTUAL_REVIEW.md) и [P7_ADAPTIVE_TASTE.md](P7_ADAPTIVE_TASTE.md).

SwiftUI-интерфейс по-прежнему остаётся компактным: пользователь может запустить `Import → AI Edit` без обязательного выбора style/duration/pacing/music. Последующие естественные delete/trim/reorder/speed/transition/music/crop/telemetry/undo/regenerate действия локально и постепенно обновляют anonymized Personal Taste без оценок и нового UI. «Волшебная кисть» применяет локальный AI-план только внутри выделенного диапазона. Preview и MP4 используют один builder; cloud не обязателен.

Редактор также поддерживает самостоятельные timeline-объекты эффектов, keyframes, переходов и титров. Эффекты можно перемещать, обрезать, включать, дублировать, копировать и вставлять; титры включают cinematic/dynamic/captions/cards и word-level timing. `MusicSyncEngine` анализирует loudness envelope выбранного локального файла, определяет beat phase/downbeats/bars/phrases/drops/акценты и привязывает монтажные границы к соответствующим музыкальным опорам. AI Director редактирует те же объекты типизированными командами, поэтому автоматический результат остаётся ручным монтажом, а не запечённым шаблоном.

Правки из чата не остаются текстом: кнопка «Применить правки» пересобирает StoryPlan/Timeline и заменяет композицию в проигрывателе. До этого старый просмотр помечен как неактуальный и не даёт 100% готовности.

## Требования

- macOS 14+
- Apple Silicon рекомендуется
- Swift 5.10+ toolchain
- Xcode нужен только для подписанного GUI release; Command Line Tools достаточно для package build/tests.

Для полноценного AI-диалога нужен бесплатный локальный Ollama с instruction-моделью; без неё приложение явно показывает, что отвечает базовый алгоритм. Vision-модель выбранного режима загружается отдельной кнопкой прямо в AI-карточке:

```bash
brew install ollama
brew services start ollama
ollama pull qwen3:4b-instruct
```

## Сборка и тесты

```bash
./Scripts/dev-build.sh
./Scripts/dev-test.sh
.build/arm64-apple-macosx/debug/veloedit-cli help
```

Скрипты обходят известную рассинхронизацию Swift frontend/SDK в некоторых версиях macOS 26 Command Line Tools. При установленном актуальном Xcode также можно использовать обычные `swift build` и `swift test`.

Сборка `.app` без подписи:

```bash
./Scripts/build-app.sh
```

## Принципы

- Оригиналы никогда не изменяются и не копируются без необходимости.
- По умолчанию нет облака и генеративного изменения кадров.
- Анализ кэшируется; regenerate перестраивает только story/timeline.
- Timeline можно продолжить в Final Cut Pro через FCPXML.

Статус функций и внешние validation gates находятся в [TODO.md](TODO.md), устройство системы — в [ARCHITECTURE.md](ARCHITECTURE.md), последовательность работ — в [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md), P7 — в [P7_ADAPTIVE_TASTE.md](P7_ADAPTIVE_TASTE.md), P6 — в [PERCEPTUAL_REVIEW.md](PERCEPTUAL_REVIEW.md), P5 и production-аудит — в [P5_PRODUCTION_HARDENING.md](P5_PRODUCTION_HARDENING.md) и [PRODUCTION_AUDIT.md](PRODUCTION_AUDIT.md), матрица AI Director 2.0 — в [AI_DIRECTOR_2.md](AI_DIRECTOR_2.md), аудит OpenCut — в [OPENCUT_INTEGRATION.md](OPENCUT_INTEGRATION.md).
