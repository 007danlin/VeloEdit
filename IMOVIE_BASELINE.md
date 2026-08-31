# iMovie baseline для VeloEdit

Обновлено: 2026-08-19. Базовый перечень сверяется с официальным руководством iMovie для Mac.

## Цель

Любое действие ниже должно быть доступно вручную и через русскоязычную команду AI-режиссёру. Реплика AI не считается исполнением: успешная команда обязана изменить `Timeline`, пересобрать просмотр и попасть в отчёт «что изменено».

## Функциональная матрица

| Область | Функции iMovie-класса | VeloEdit |
|---|---|---|
| Монтаж | подбор, перестановка, trim, delete, duplicate, split, точное число моментов | Работает вручную и по запросу |
| Скорость | ускорение, замедление, speed ramp, freeze/reverse, instant replay | Работает в preview/MP4; retime редактируем в FCPXML |
| Кадр | fill/fit, поворот, Ken Burns, zoom/pan, push-in/pull-out, mirror | Работает в preview/MP4 и по запросу |
| Цвет | auto enhance, brightness, exposure, contrast, saturation, temperature, highlights/shadows, vignette, grain, filters | Работает вручную и по запросу |
| Звук | громкость, mute, fade in/out, музыка, automatic ducking, basic noise reduction и EQ | Работает в общем preview/MP4 pipeline |
| Титры | title card, текст, размещение, размер, цвета и выравнивание | Работает в preview/MP4 и по запросу |
| Переходы | dissolve, fade, dip to black, blur, light, slide, wipe | 9 переходов работают в preview/MP4 |
| Фото | Ken Burns/pan/zoom, sequences, multi-photo layouts | Работает как clips и реальные split/PiP layers |
| Telemetry | speed, GPS route, altitude, G-force, distance | GPMF decode + динамический preview/MP4 overlay |
| Наложения | cutaway, picture-in-picture, split screen, green screen | Работает как отдельный видеослой и не удлиняет фильм |
| Стабилизация | стабилизация дрожания и rolling shutter | Требует отдельного analysis/render pass |
| Вывод | просмотр, MP4, проект для Final Cut Pro | Native editability + автоматический rendered reference для непереносимых эффектов |

## Инвариант AI-исполнения

`текст пользователя -> локальная LLM (понимание/ответ) + детерминированный EditorCommandParser -> EditorCommandExecutor -> сохранённый Timeline -> новый AVPlayer/MP4 -> отчёт в чате`.

Детерминированный слой обязателен: LLM помогает вести диалог, но не может подменить факт выполнения красивой фразой.
