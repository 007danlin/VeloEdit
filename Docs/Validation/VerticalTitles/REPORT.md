# Проверка вертикальных титров VeloEdit

14 сентября 2026. Проверены все 14 встроенных шаблонов через настоящий рендерер приложения, композицию превью и экспорт MP4.

Пересечение вертикальной полоски с текстом подтверждено и исправлено. Причина находилась в общей адаптации: текст, панель и акцент расширялись независимо вокруг собственных центров. В узком кадре декоративная полоска оказывалась внутри текста. Для каждого шаблона теперь задана согласованная вертикальная композиция; переход к квадратному и горизонтальному формату остаётся плавным.

**Что обнаружено и исправлено**

| Проблема | Исправление и проверка |
| --- | --- |
| Полоска пересекала надпись в Modern, Lower Third и Word Focus | Акцент закреплён у левого края панели, текст имеет отдельный внутренний отступ. Проверены рамки элементов в пяти форматах. |
| Заголовок и подпись сталкивались при длинном тексте | Разнесены области текста, увеличено место для переноса. Проверяются фактические контуры строк Core Text, а не только заданные рамки. |
| Второстепенные подписи уменьшались до 7–9 пикселей на кадре шириной 360 пикселей | Увеличен размер подписей в вертикальной компоновке. Минимум в итоговой матрице — 13,92 пикселя. |
| Длинная фамилия переносилась с отдельной последней буквой | До выбора размера проверяется ширина каждого слова. Core Text больше не получает формально подходящий, но фактически разрывающий слово вариант. |
| «ПЕТРОПАВЛОВСК-КАМЧАТСКИЙ» обрезался | Разрешён перенос на дефисе; дополнительно проверяется, что текстовый фрейм действительно отобразил всю строку. |
| Короткая надпись висела у верхнего края большой области | Текст центрируется по фактическим контурам букв. В панельных шаблонах отсутствие подписи учитывается при размещении заголовка. |
| Контур светлого текста терялся на белом фоне | Увеличена минимальная толщина адаптивного контура. Проверка прозрачности и отсутствия удвоенной заливки во время появления прошла. |
| На коротком титре появление и исчезновение перекрывали друг друга | Длительность фаз и задержки элементов подстраиваются под длительность титра. Каждая фаза занимает не более 30%, оставляя минимум 40% времени для полностью показанного текста. |

**Матрица изображений**

Для каждого из 14 шаблонов проверены шесть вариантов: исходный текст на тёмном фоне; длинный текст на белом; исходный текст на фотографии; длинный текст на фотографии; отсутствие дополнительной подписи; шрифт +30% и жёлтый цвет на контрастной мелкой текстуре. Для Word Focus проверено выделение слова, присутствующего в надписи; для Chapter — число 123.

Всего 84 композиции и 155 непустых текстовых блоков. До исправления найдено 51 срабатывание проверки текста: слишком мелкий шрифт, обрезание, столкновение строк или выход за безопасную область. Это количество проблемных блоков в сценариях, а не 51 независимый дефект. В итоговой матрице таких срабатываний нет. Пересечение декоративных полосок проверяется отдельно.

Основной размер — 360 × 640: он позволяет оценить надписи в масштабе телефона. Дополнительно проверены 360 × 780, 1080 × 1920 и 1080 × 1350. Положение полоски и размещение текста внутри панели проверены также на 1080 × 1080 и 1920 × 1080; существующие тесты рендера охватывают горизонтальный 4K.

| Шаблон | До | После |
| --- | --- | --- |
| Minimal Clean | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/before/title.minimal-clean.v1.png) | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/title.minimal-clean.v1.png) |
| Cinematic | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/before/title.cinematic.v1.png) | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/title.cinematic.v1.png) |
| Modern | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/before/title.modern.v1.png) | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/title.modern.v1.png) |
| Bold | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/before/title.bold.v1.png) | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/title.bold.v1.png) |
| Elegant | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/before/title.elegant.v1.png) | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/title.elegant.v1.png) |
| Dynamic | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/before/title.dynamic.v1.png) | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/title.dynamic.v1.png) |
| Travel | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/before/title.travel.v1.png) | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/title.travel.v1.png) |
| Chapter | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/before/title.chapter.v1.png) | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/title.chapter.v1.png) |
| Location | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/before/title.location.v1.png) | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/title.location.v1.png) |
| Lower Third | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/before/title.lower-third.v1.png) | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/title.lower-third.v1.png) |
| Date | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/before/title.date.v1.png) | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/title.date.v1.png) |
| End Card | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/before/title.end-card.v1.png) | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/title.end-card.v1.png) |
| Clean Captions | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/before/caption.clean.v1.png) | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/caption.clean.v1.png) |
| Word Focus | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/before/caption.word-focus.v1.png) | [6 вариантов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/caption.word-focus.v1.png) |

Численные измерения: [до](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/before/measurements.csv), [после](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/measurements.csv). Исходные нарушения: [findings.txt](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/before/findings.txt).

**Анимация, редактирование и экспорт**

Проверены 42 комбинации «шаблон × длительность»: 0,4 / 0,8 / 1,2 секунды. В середине каждой надпись полностью видна. Ещё 336 кадров проверены в шести фазах анимации и четырёх вертикальных размерах; полностью показанный текст остаётся внутри кадра, после окончания титра изображение отсутствует.

Экспортная проверка строит 30-секундный монтаж 360 × 640 из трёх видеофайлов: вертикального, горизонтального с вписыванием и файла с поворотом в метаданных камеры. Все 14 титров проходят через сохранение/загрузку таймлайна, PlaybackEngine и RenderEngine. В каждой надписи сравниваются начало, середина и выход — 42 пары кадров. Допуск средней абсолютной ошибки RGB — 4,5% полного диапазона, с учётом потерь MP4. Геометрия и наличие текста проверяются отдельно от этой метрики.

Все 42 пары прошли: средняя ошибка 0.303%, максимальная 0.727%. Результат: [вертикальный MP4](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/playback/vertical-titles.mp4), [покадровые измерения](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/playback/comparison.csv). Сравнения превью и экспорта: [1](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/playback/comparison-0.png), [2](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/playback/comparison-1.png), [3](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/playback/comparison-2.png), [4](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/after/playback/comparison-3.png).

Все 35 связанных тестов прошли, включая изменение номера главы, команды изменения выбранного титра, обновление остановленного превью, сохранение правок, цвет/размер/прозрачность всех шаблонов, неподвижность титра в фазе удержания и совпадение с экспортом. Проверка выполнена из неизменяемой копии исходников, поскольку соседняя задача одновременно редактировала проект.

**Границы проверки и повторный запуск**

Изображения получены настоящим рендерером; это не дизайнерские макеты. Фоны — встроенная фотография и синтетические контрастные поверхности. Видеоисточники созданы для воспроизводимой проверки кодирования, форматов и поворота. Пользовательские ролики с движущимися людьми, HDR и интерфейсные перекрытия конкретных социальных сетей в эту матрицу не входят. Безопасные поля здесь означают поля шаблона внутри видео. Произвольно большой текст по-прежнему может сокращаться с многоточием после исчерпания допустимых переносов и размера шрифта.

Повторить визуальную матрицу и экспорт:

```sh
VELOEDIT_VERTICAL_TITLE_AUDIT="$PWD/Docs/Validation/VerticalTitles/after" \
  ./Scripts/dev-test.sh --filter VerticalTitleAuditTests
```

Основные изменения: [вертикальные композиции](/Users/daniellineckij/VeloEdit/Sources/VeloEditCore/PortraitTitleTemplates.swift), [адаптация геометрии](/Users/daniellineckij/VeloEdit/Sources/VeloEditCore/AdaptiveTitleLayout.swift), [рендерер](/Users/daniellineckij/VeloEdit/Sources/VeloEditCore/TitleOverlayRenderer.swift), [ограничение анимации](/Users/daniellineckij/VeloEdit/Sources/VeloEditCore/TitleTemplates.swift), [регрессионные проверки](/Users/daniellineckij/VeloEdit/Tests/VeloEditCoreTests/VerticalTitleAuditTests.swift).

**Готовое приложение**

Полный пакет собран командой `./Scripts/build-app.sh` из неизменяемой копии исходников. Сборка 2026.257.180601; `codesign --verify --deep` прошёл. Пять файлов рендерера и компоновки совпадают с проверенной копией по SHA-256.

[VeloEdit.app](/Users/daniellineckij/VeloEdit/Build/VeloEdit.app) · [сведения о сборке](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/BuildInfo.json) · [журнал сборки](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/app-build.log) · [журнал 35 тестов](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/regression-tests.log) · [финальный повтор вертикальной проверки](/Users/daniellineckij/VeloEdit/Docs/Validation/VerticalTitles/vertical-tests.log).
