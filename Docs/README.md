# Документация VeloEdit

Начните с [сборки и тестов](Guides/development.md),
[обзора архитектуры](Architecture/overview.md) и
[подготовки выпуска](Guides/release.md).
Команды и пути в примерах отсчитываются от корня проекта.

| Раздел | Что здесь находится |
| --- | --- |
| [Guides](Guides/) | Инструкции по разработке и выпуску |
| [Architecture](Architecture/) | Устройство ядра, AI, анализа медиа и производительности |
| [Features](Features/) | Поведение реализованных функций |
| [Integrations](Integrations/) | FCPXML, музыка, телеметрия и OpenCut |
| [Specifications](Specifications/) | Требования и критерии приёмки |
| [Planning](Planning/) | План развития, этапы реализации и ориентиры |
| [References](References/) | Согласованные примеры титров и музыки |

## Архитектура и AI

- [Общая архитектура](Architecture/overview.md)
- [Локальные модели](Architecture/ai-models.md) и [AI-режиссёр](Architecture/ai-director.md)
- [Понимание медиа](Architecture/media-understanding.md)
- [Автономный монтаж](Architecture/autonomous-editing.md) и [события](Architecture/event-intelligence.md)
- [Стабильность и отзывчивость](Architecture/production-hardening.md) — прежний `P5_PRODUCTION_HARDENING.md`
- [Визуальная оценка монтажа](Architecture/perceptual-review.md) и [адаптация к вкусу](Architecture/adaptive-taste.md)
- [Производительность](Architecture/performance.md)

## Разработка функций

- [Текущий план](Planning/roadmap.md) и [план реализации](Planning/implementation-plan.md)
- [Автоматическая сборка фильма](Features/automatic-editorial-assembly.md)
- [Восстановление сборки фильма](Features/film-build-recovery.md)
- [Титры](Specifications/smart-chapter-titles.md), [музыка](Specifications/dynamic-music.md) и [распознавание речи](Specifications/vlog-local-speech.md)
- [Первый запуск](Specifications/first-launch.md)
- [Скрипты и проверки](../Scripts/README.md), [графика](../Design/README.md), [сайт](../website/README.md)

## Локальные отчёты

Документы здесь описывают устройство приложения и требования к нему.
Результаты отдельных прогонов и исторические аудиты хранятся локально в
`Local/Reports/`; замеры — в `Local/Benchmarks/`. Вся папка `Local/`
исключена из Git. Ссылки на прежние опубликованные отчёты ведут к фиксированному
коммиту в истории и не подтверждают состояние текущей сборки.

Новые документы называйте по теме: строчные английские слова через дефис,
например `production-hardening.md`. Помещайте их в подходящий раздел;
отчёты конкретного запуска сохраняйте в `Local/Reports/`.
