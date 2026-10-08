# Локальные AI-модели VeloEdit

Актуализировано: 2026-08-20.

## Решение

Основной vision-language кандидат — Qwen3-VL. У семейства есть 2B/4B/8B и более крупные варианты, video/timestamp reasoning и поддержка в Ollama и `mlx-swift-lm/MLXVLM`. Это позволяет сохранить один тип prompt/JSON-контракта во всех четырёх режимах.

- **⚡ Быстро:** Qwen3-VL 2B 4-bit, 4 лучших участка по 3 кадра.
- **⚖️ Баланс:** Qwen3-VL 4B 4-bit, 8 участков по 5 кадров; default для M4 Air.
- **🧠 Качество:** Qwen3-VL 8B 4-bit, 12 участков по 8 кадров.
- **🎬 Максимум:** Qwen3-VL 30B-A3B 4-bit на Mac с 32 GB+; на меньшей памяти 8B 8-bit, но более плотная выборка и thinking.

Размеры относятся только к deep pass. Быстрый проход всегда выполняет дешёвые реальные измерения кадров и Apple Vision labels, поэтому даже «Максимум» не декодирует весь оригинал через VLM.

## Runtime

Текущий рабочий backend — Ollama loopback API. Медиа не покидает Mac; приложение умеет само запустить установленный Ollama и загрузить выбранную профилем модель одной кнопкой. После загрузки режим работает без интернета. Если модель или runtime недоступны, приложение продолжает adaptive Apple Vision-анализ и явно записывает fallback в `AnalysisResult`/UI.

Целевой нативный backend — Apple `mlx-swift-lm` + `MLXVLM`. Он использует Metal/unified memory, поддерживает `model_type: qwen3_vl` и локальные directories. Профили уже содержат MLX IDs, runtime abstraction и Advanced выбор. Прямая зависимость откладывается до release packaging gate: текущий `mlx-swift-lm` требует дополнительного downloader/tokenizer stack и имеет меняющийся SwiftPM surface; приложение не должно выдавать неподключённый adapter за рабочий runtime.

## Сравнение

| Семейство | Сильная сторона | Решение для VeloEdit |
|---|---|---|
| Qwen3-VL | video, temporal/timestamp reasoning, линейка размеров | основной deep analyzer |
| Apple FastVLM | очень низкая vision latency на Apple Silicon | кандидат для будущей замены Apple Vision first pass |
| Gemma 3 | сильное понимание отдельных изображений, MLX support | Advanced alternative, слабее соответствует длинному видео |
| SmolVLM | очень малый memory footprint, есть video variants | fallback для устройств с малой памятью |
| llama.cpp | зрелый GGUF/Metal runtime | резервный runtime; Qwen3-VL integration менее прямой, чем MLXVLM/Ollama |

Production P2 уже имеет `EmbeddingModelProtocol`, 64-D offline `LocalVisualEmbeddingModel`, persistent cache и `SemanticSceneIndex` после candidate detection. Qwen3-VL Embedding 2B/8B остаётся возможной заменой backend через тот же протокол, но не является обязательной зависимостью приложения.

## Первичные источники

- [Qwen3-VL: модели и video capabilities](https://github.com/QwenLM/Qwen3-VL/blob/main/README.md)
- [Qwen3-VL в Ollama и размеры пакетов](https://ollama.com/library/qwen3-vl)
- [Apple MLX](https://github.com/ml-explore/mlx)
- [MLX Swift LM: поддерживаемые VLM, включая qwen3_vl](https://github.com/ml-explore/mlx-swift-lm/blob/main/skills/mlx-swift-lm/references/supported-models.md)
- [Apple FastVLM](https://machinelearning.apple.com/research/fast-vision-language-models)
- [Apple thermal-state guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html)

## Offline и лицензии

VeloEdit не вызывает cloud API. Интернет может понадобиться только для явной загрузки весов. После этого inference, proxy, cache, Story Engine, preview и render локальны. Qwen3-VL 2B Instruct опубликован под Apache-2.0; перед дистрибуцией каждого конкретного веса model downloader должен показывать его license/checksum и требуемое место.
