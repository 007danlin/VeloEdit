# Производительность

- Оригиналы не копируются; при импорте читаются метаданные и максимум 128 KiB содержимого.
- Полный файловый SHA-256 считается потоково только при явном `veloedit-cli verify`.
- Manifest и анализ versioned/cached по content hash.
- Видео получает coarse samples и dense samples только вокруг измеренных temporal peaks вместо frame-level анализа всего архива.
- 720p proxy автоматически создаётся при первом AI-анализе и переиспользуется; full resolution зарезервирован для playback/final render.
- Probe нескольких выбранных файлов выполняется параллельно с лимитом четыре задачи.
- На MacBook Air VLM jobs сериализованы. `serious` уменьшает число/разрешение кадров, `critical` пропускает deep VLM pass, Low Power Mode использует сокращённый профиль.
- Project store не требует держать media payloads в RAM.
- Embeddings строятся только для candidate shortlist из уже декодированных adaptive frames; отдельного full-frame прохода нет.
- Face/object tracking углубляется только для 2 кандидатов в Fast, до 6 в Balanced и shortlist в Quality/Maximum.
- `DeepAnalysisCache` по content hash переиспользует audio summary/events, ASR transcript, embeddings и subject tracks между запусками.
- Music DSP имеет memory/in-flight/persistent cache по fingerprint локального трека.
- `SemanticSceneIndex` использует exhaustive comparison только до 384 кандидатов; далее — locality buckets, bounded representatives и within-asset edges вместо полного O(N²).
- Все варианты используют один `MontageScoringFeatures`/semantic index; production directing независимых вариантов выполняется task group параллельно.

Автоматический performance guard `semanticIndexStaysBoundedForThreeHundredCameraFiles` моделирует 300 камер × 8 кандидатов. Порог debug-теста — 5 секунд; контрольный прогон 2026-08-24 занял около 1.2 секунды. Это измеряет только semantic clustering, а не decode/Vision/ASR всего архива.

Для production нужны Instruments measurements на M4 Air: import 300 clips, proxy throughput, sustained thermal state, peak RSS, 30-minute timeline export и cache rebuild latency.
