# Соответствие киноприёмов инструментам

toolMapping описывает механизм, allowedCommands разрешает исполнение. Пустой allowlist запрещает автоматическое применение.

| ID | Приём | Статус | Разрешённые команды | Переходы / эффекты | Возможный механизм |
| --- | --- | --- | --- | --- | --- |
| camera-movement/handheld | Ручная камера | analysisOnly | — | — | — |
| camera-movement/pan | Панорама камеры | analysisOnly | — | — | — |
| camera-movement/parallax | Параллакс | analysisOnly | — | — | — |
| camera-movement/static | Статичная камера | analysisOnly | — | — | — |
| color/natural-grade | Естественный цвет | analysisOnly | — | — | — |
| composition/architexture | Архитектура как фактура | analysisOnly | — | — | — |
| composition/asymmetry | Асимметрия | analysisOnly | — | — | — |
| composition/centered-composition | Центрированная композиция | analysisOnly | — | — | — |
| composition/central-framing | Центральное кадрирование | analysisOnly | — | — | — |
| composition/clean-frame | Чистые края кадра | analysisOnly | — | — | — |
| composition/contrast-composition | Тональный контраст | analysisOnly | — | — | — |
| composition/diagonal-composition | Диагональная композиция | analysisOnly | — | — | — |
| composition/dirty-frame | Перекрытые края кадра | analysisOnly | — | — | — |
| composition/figure-ground | Фигура и фон | analysisOnly | — | — | — |
| composition/foreground-interest | Значимый передний план | analysisOnly | — | — | — |
| composition/frame-in-frame | Кадр внутри кадра | analysisOnly | — | — | — |
| composition/golden-ratio | Золотое сечение | analysisOnly | — | — | — |
| composition/headroom | Воздух над головой | analysisOnly | — | — | — |
| composition/layered-depth | Многоплановая глубина | analysisOnly | — | — | — |
| composition/lead-room | Пространство перед движением | analysisOnly | — | — | — |
| composition/leading-lines | Направляющие линии | analysisOnly | — | — | — |
| composition/look-space | Пространство взгляда | analysisOnly | — | — | — |
| composition/negative-space | Негативное пространство | analysisOnly | — | — | — |
| composition/one-point-perspective | Одноточечная перспектива | analysisOnly | — | — | — |
| composition/reflections | Отражения | analysisOnly | — | — | — |
| composition/repetition-pattern | Повторение и ритм | analysisOnly | — | — | — |
| composition/rule-of-thirds | Правило третей | analysisOnly | — | — | — |
| composition/screen-in-screen | Экран в кадре | analysisOnly | — | — | — |
| composition/short-siding | Теснота по взгляду | analysisOnly | — | — | — |
| composition/symmetry | Симметрия | analysisOnly | — | — | — |
| composition/tableau | Живая картина | analysisOnly | — | — | — |
| composition/triangular-composition | Треугольная композиция | analysisOnly | — | — | — |
| composition/vanishing-point | Точка схода | analysisOnly | — | — | — |
| composition/visual-weight | Визуальный вес | analysisOnly | — | — | — |
| composition/void | Пустота | analysisOnly | — | — | — |
| composition/voyeur | Скрытая точка наблюдения | analysisOnly | — | — | — |
| composition/windows | Оконные рамки | analysisOnly | — | — | — |
| editing/axial-cut | Осевой скачок крупности | analysisOnly | — | — | trim, setCrop, setTransition:cut |
| editing/crash-cut | Ударная склейка | analysisOnly | — | — | setTransition:cut |
| editing/cross-cut | Параллельный монтаж | analysisOnly | — | — | insert, reorder, setTransition:cut |
| editing/dissolve | Наплыв | applicable | addTransition | cross-dissolve | addTransition |
| editing/fade | Затемнение и выход из чёрного | deferred | — | — | addTransition:fade-through-black (без выдержки поля) |
| editing/flash-cut | Мелькающая вставка | analysisOnly | — | — | insert, trim, setTransition:cut (нужна покадровая вставка) |
| editing/fragments | Монтаж деталей | analysisOnly | — | — | insert, trim, reorder |
| editing/graphic-match | Графическое соответствие | analysisOnly | — | — | trim, setTransition:cut |
| editing/invisible-cut | Невидимая склейка | analysisOnly | — | — | trim, setTransition:cut |
| editing/iris | Ирисовый переход | applicable | addTransition | iris | addTransition |
| editing/jump-cut | Джамп-кат | analysisOnly | — | — | split, trim, rippleDelete, setTransition:cut |
| editing/l-cut-visual | J-cut и L-cut | deferred | — | — | detachAudio (неполное соответствие) |
| editing/match-action | Склейка по действию | analysisOnly | — | — | trim, setTransition:cut |
| editing/match-cut | Смысловая склейка | analysisOnly | — | — | trim, setTransition:cut |
| editing/match-motion | Согласованное движение | analysisOnly | — | — | trim, setTransition:cut |
| editing/match-split | Согласованный разделённый кадр | analysisOnly | — | — | insertOverlay:splitScreen |
| editing/montage | Монтажная последовательность | analysisOnly | — | — | insert, trim, reorder, setTransition:cut |
| editing/quick-cuts | Быстрые склейки | analysisOnly | — | — | trim, reorder, setTransition:cut |
| editing/set-transition | Преображение декорации | deferred | — | — | — |
| editing/smash-cut | Контрастная склейка | analysisOnly | — | — | setTransition:cut |
| editing/split-screen | Разделённый экран | analysisOnly | — | — | insertOverlay:splitScreen |
| editing/transitions | Выбор вида перехода | analysisOnly | — | — | — |
| editing/wipe | Шторка | applicable | addTransition | wipe-left, wipe-right, wipe-up, wipe-down | addTransition |
| effects/datamosh | Датамошинг | deferred | — | — | — |
| effects/deep-focus | Глубокий фокус | analysisOnly | — | — | — |
| effects/film-grain | Плёночное зерно | applicable | addEffect | film-grain | addEffect |
| effects/match-morph | Морфинг | deferred | — | — | — |
| effects/shallow-focus | Малая глубина резкости | analysisOnly | — | — | — |
| effects/vignette | Виньетка | applicable | addEffect | vignette | addEffect |
| framing/choker | Тесный лицевой план | analysisOnly | — | — | — |
| framing/close-up | Крупный план | analysisOnly | — | — | — |
| framing/cowboy-shot | Американский план | analysisOnly | — | — | — |
| framing/cut-ins | Укрупняющая вставка | analysisOnly | — | — | — |
| framing/cutaway | Перебивка | analysisOnly | — | — | insertOverlay:cutaway |
| framing/establishing-shot | Установочный план | analysisOnly | — | — | — |
| framing/extreme-close-up | Сверхкрупный план | analysisOnly | — | — | — |
| framing/extreme-long-shot | Сверхдальний план | analysisOnly | — | — | — |
| framing/full-body | Ростовой план | analysisOnly | — | — | — |
| framing/gesture | План жеста | analysisOnly | — | — | — |
| framing/group-shot | Групповой план | analysisOnly | — | — | — |
| framing/insert | Деталь действия | analysisOnly | — | — | — |
| framing/interview | Интервью | analysisOnly | — | — | — |
| framing/long-shot | Дальний план | analysisOnly | — | — | — |
| framing/master-shot | Общий мастер-план | analysisOnly | — | — | — |
| framing/medium-close-up | Среднекрупный план | analysisOnly | — | — | — |
| framing/medium-shot | Средний план | analysisOnly | — | — | — |
| framing/over-the-shoulder-frame | План через плечо | analysisOnly | — | — | — |
| framing/product | Предметный план | analysisOnly | — | — | — |
| framing/reaction-shot | План реакции | analysisOnly | — | — | — |
| framing/single | Одиночный план | analysisOnly | — | — | — |
| framing/three-shot | План троих | analysisOnly | — | — | — |
| framing/two-shot | Парный план | analysisOnly | — | — | — |
| framing/video-portraits | Видеопортрет | analysisOnly | — | — | — |
| framing/wide-shot | Широкий общий план | analysisOnly | — | — | — |
| genre-looks/documentary-look | Документальная наблюдательность | analysisOnly | — | — | — |
| lighting/golden-hour | Золотой час | analysisOnly | — | — | — |
| lighting/silhouette | Силуэт | analysisOnly | — | — | — |
| time-and-motion/bullet-time | Облёт остановленного действия | deferred | — | — | — |
| time-and-motion/fast-motion | Ускоренное движение | applicable | setSpeed | — | setSpeed |
| time-and-motion/freeze-frame | Стоп-кадр | applicable | freezeFrame | — | freezeFrame |
| time-and-motion/long-take | Длинный план | analysisOnly | — | — | — |
| time-and-motion/reverse-motion | Обратное движение | deferred | — | — | — |
| time-and-motion/slow-motion | Замедленная съёмка | applicable | setSpeed | — | setSpeed |
