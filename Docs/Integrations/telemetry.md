# Telemetry Engine

## Локальная архитектура

VeloEdit встраивает исходный Rust core проекта OVRLEY на revision
`0db9be5f775c6e3716407f4a37175c916b8065f1`. Полная сборка создаёт бинарник
`VeloEditOVRLEY`, помещает его рядом с основным executable и общается с ним
локально через JSON/stdout. Сеть и облачные API для разбора телеметрии не
используются. В bundle также входят лицензия и соответствующий исходный код в
`Contents/Resources/OVRLEY-Source`.

OVRLEY первым обрабатывает CSV, VBO и встроенные потоки MP4/MOV/M4V (GoPro,
DJI, Insta360 — в пределах поддержки закреплённой версии
`telemetry-parser`). Если встроенный поток не распознан, GoPro GPMF читается
существующим AVFoundation/KLV fallback. GPX, FIT и SRT разбираются нативными
офлайн-парсерами VeloEdit, потому что эти импортеры в upstream OVRLEY находятся
в browser/JavaScript-слое, а не в Rust core.

## Единая модель

Все источники преобразуются в `TelemetrySource` и последовательность
`TelemetrySample` с монотонным временем. Модель покрывает GPS, скорость,
дистанцию, высоту, acceleration/G-force/gyro, heading, пульс, cadence, power,
lean angle, RPM, throttle/brake, laps, температуру, gradient, vertical speed,
torque, gear, running/rowing metrics и параметры камеры. Отсутствующее значение
остаётся `nil`: интерфейс и renderer не подставляют выдуманный ноль.

Общий normalizer вычисляет только математически выводимые значения: расстояние
по haversine, скорость по расстоянию и времени, ускорение, heading, vertical
speed и gradient. Между соседними отсчётами используется линейная интерполяция;
дискретные lap/gear/camera-поля сохраняют ближайшее известное значение.

## Синхронизация и Timeline

Embedded telemetry получает нулевой offset и confidence 1.0. Для sidecar-файла
с абсолютным timestamp используется разница `videoStart - telemetryStart`.
Если абсолютного времени нет, распознаётся timestamp в имени файла; иначе слой
стартует с ручным offset 0 и явно нулевой уверенностью. Смещение редактируется с
шагом кадра в Inspector.

Телеметрия хранится отдельными `TimelineTelemetryItem`, но каждый новый слой
жёстко привязан к конкретному `targetClipID`. Источник выбирается автоматически
по asset этого фрагмента: отдельного выбора видео в библиотеке нет. Время датчика
вычисляется из source clock фрагмента, включая trim, постоянную скорость,
speed ramp, reverse и sync offset. При переносе слоя на другой ролик он
перепривязывается к данным нового ролика. Объект можно обрезать по длительности,
удалять, дублировать, копировать/вставлять его оформление и отменять через общий
Undo/Redo Timeline. Он не удлиняет magnetic storyline.

## Виджеты, AI и экспорт

Раздел «Телеметрия» устроен как визуальная библиотека OVRLEY. В нём всегда
видны карточки с примером результата, поиск и категории General, Cycling,
Running, Motorsports, Camera и Other. Для каждой поддерживаемой метрики
показываются допустимые upstream display types из общего OVRLEY manifest: Text,
Linear, Arc, Corner, Heading Tape, G-Force, Lean Angle и четыре режима Lap Timer.
Segmented/reverse параметры старых проектов остаются decodable, но больше не
выдаются за отдельные display types в каталоге.

В библиотеку входят все 12 шаблонов из vendored `ThirdParty/OVRLEY/templates`:
Acid Titanium, Breeze Blue, Burnt Orange, Champagne Basic/Borders/Shadows,
Futuristic HUD, Lavender Gradient, Safa Brian, White + VAM, White Opacity и
White Shadows. Старые стили VeloEdit остаются decodable для совместимости, но
новый browser и Inspector в первую очередь показывают оригинальный каталог.

Карточку можно нажать или перетащить на фрагмент Timeline либо прямо на кадр
Viewer. При drop слой получает начало, длительность, asset и source clock именно
этого фрагмента. Выбранный widget не дублируется статичной картинкой: Viewer
показывает живой renderer, поверх которого остаётся только рамка редактирования.
Drag меняет X/Y, а угловой handle — width/height. Эти normalized координаты записываются в
`TelemetryWidgetLayout`, поэтому положение совпадает в preview, MP4, alpha MOV
и FCPXML fallback.

Каждый widget также имеет независимые opacity, цвета, border, shadow, font и
label. Preview, Timeline, карточки библиотеки и финальный export используют один
`TelemetryOverlayRenderer`: для оригинальных шаблонов он передаёт нормализованные
данные в постоянный локальный Rust/Skia render-server OVRLEY. Подготовленные
шрифты, SVG и конфигурации кэшируются между кадрами, а готовые CGImage — в
ограниченном по памяти кэше VeloEdit. Локальный Core Image renderer остаётся
только аварийным fallback для старых проектов и неподдерживаемых legacy-типов.

AI Director получает нормализованные telemetry peaks до плотной выборки кадров,
использует их при ранжировании action/climax-сцен и выбирает только действительно
доступные speed/G-force/route/altitude widgets. Пользовательский запрос со
словами про GPS, скорость, высоту или телеметрию создаёт независимые слои уже на
этапе композиции фильма.

Обычный export запекает виджеты в видео. Дополнительный export создаёт только
телеметрию в ProRes 4444 MOV с alpha-каналом. FCPXML хранит каждый слой как
отдельный metadata/marker region (source ID, linked asset, widgets, style,
sync offset) и автоматически добавляет rendered reference для точного вида.

## Известные технические ограничения

- FIT importer читает стандартные local definitions и Record fields. Неизвестные
  числовые Record-поля сохраняются как `fit_record_N`; developer fields без
  доступного определения безопасно пропускаются. Compressed timestamp без
  обычного timestamp получает относительное время по порядку записи.
- GPX extensions распознаются по стандартным суффиксам `hr`, `cad`, `power`,
  `speed`, `atemp`; прочие числовые extension-поля сохраняются в custom fields.
- SRT поддерживает распространённые DJI/Insta360 key/value labels. Полностью
  произвольная локализация или зашифрованные camera payloads не угадываются,
  но неизвестные числовые key/value-поля не теряются.
- CSV importer автоматически распознаёт распространённые заголовки, сохраняет
  все прочие числовые колонки и позволяет вручную сопоставить их времени, GPS,
  скорости, высоте, дистанции, курсу, G-force, пульсу, каденсу или мощности.
- Автосинхронизация использует embedded/absolute/file timestamps. Корреляция по
  звуковым пикам и optical-flow пока не применяется; для таких файлов нужен
  ручной frame-accurate offset.
- Route widget рисует локальную линию маршрута без сетевых map tiles.
- Поддержка редких проприетарных MP4 telemetry streams определяется закреплённой
  версией upstream OVRLEY/`telemetry-parser`; неизвестный поток возвращает явное
  предупреждение, а не синтетические метрики.

## Лицензия

OVRLEY распространяется по GNU GPL-3.0-or-later. Частная локальная сборка остаётся
локальной. При передаче приложения третьим лицам распространитель обязан
выполнить условия GPL, сохранить notices и предоставить corresponding source.
См. `ThirdParty/OVRLEY/LICENSE.md` и `ThirdParty/OVRLEY/VELOEDIT_INTEGRATION.md`.
