# Editorial Intelligence V3 — финальный статус productionization

Дата завершения: 9 сентября 2026 года  
Основание: `EditorialIntelligenceProductionizationTZ.md` и решение владельца продукта об автоматической активации без ожидания human review.

## Итог

ТЗ завершено и активировано. Editorial Intelligence включён по умолчанию для новых и существующих проектов. Production-решение принимает автоматический rendered verifier V3; отдельное подтверждение человеком не требуется. Human playback и blind evaluation не выдаются за выполненные и остаются последующим источником калибровки, а не блокирующим gate.

Три исходных package-проекта пересобраны на месте. В каждом новый проверенный Timeline является последним и активным, предыдущие Timeline сохранены, checkpoints доступны для отката, оригинальные media не изменялись.

## Что работает в приложении

- Planner, Verifier и Repairer разделены: score планировщика не подтверждает собственный результат.
- Evidence V3 хранит `passed / failed / unknown`, coverage, confidence, provenance и точную render signature для 25 доменов.
- Любой обязательный `failed`, blocking `unknown`, critical/high finding или неподтверждённый intent запрещает commit.
- Проверяются реальные кадры финальной композиции: начало/середина/конец планов, склейки, crop, титры, эффекты, telemetry и границы фильма.
- Локальный semantic verifier измеряет subject/body/face safety, foreground/dominant objects, shot-family identity, visual novelty, progression, completion, hook, closure, bridges, titles и music fit.
- Дубликаты удаляются до фиксированной точки: после удаления заново проверяются возникшие соседства.
- Unsafe framing сначала переводится в полный `fit`; если даже полный исходный кадр остаётся опасным, план исключается.
- После safety repair разрешено восстановление длительности только из неиспользованного подтверждённого usable range. Повторы, freeze-frame padding и искусственное растяжение запрещены.
- Content Budget проверяет нижнюю и верхнюю границы. При объективном недостатке материала фиксируется `compromisedInsufficientContent`, а честная безопасная короткая версия допускается только после документированного rendered safety repair.
- Hook/closure и narrative progression проверяются по отрендерированным кадрам независимо от `fulfilled` planner-а.
- Hard mute применяется к embedded и detached audio. Слышимый итоговый AAC проверяется по integrated LUFS и true peak.
- Preview/export parity подтверждается независимым контрольным H.264/AAC export и повторным декодированием каждой обязательной точки.
- Commit выполняется атомарно под межпроцессной блокировкой и CAS-проверкой manifest; устаревшая генерация не может затереть новый intent.
- Открытие здорового проекта является read-only: terminal intent ledger больше не вызывает повторную запись manifest и ложный конфликт с фоновой миграцией карточек. `save()` и `reload()` синхронизируют CAS fingerprint; успешный reopen очищает старое сообщение об ошибке.
- Перед миграцией создаётся backup; старый Timeline не удаляется; rollback остаётся возможным.
- Release rollout включён автоматически, без кнопок и скрытой ручной активации.

## Пересобранные существующие проекты

| Проект | Активный Timeline | Холст | Длительность | Primary plans | Титры | Score | Probes | Findings | Обязательные bad/unknown | AAC LUFS / dBTP | Preview/export |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `Мой фильм` | `2A8B9E31-2D51-4A51-94C5-91C3C2D0DE80` | 5312×2988 | 81,115 с | 19 | 2 | 0,912883 | 104 | 0 | 0 | −17,016 / −2,360 | 104/104 |
| `тест 3` | `AE4CD34F-FEF3-4ACB-8791-E984FC05941B` | 1080×1920 | 40,107 с | 13 | 2 | 0,912554 | 55 | 0 | 0 | −15,992 / −4,543 | 55/55 |
| `тест 2` | `B8845998-AA5A-4405-9781-DF025C90E096` | 1080×1920 | 38,381 с | 11 | 1 | 0,901641 | 59 | 0 | 0 | −16,004 / −4,577 | 59/59 |

У `тест 3` и `тест 2` исходный звук полностью выключен: `originalAudioVolume = 0`, все video clips muted; выбранная музыка — `Everything You Ever Dreamed`. У `Мой фильм` сохранён явно допустимый исходный звук с `originalAudioVolume = 0.28`.

Запрос `тест 2` на пять минут не выполнен искусственным растягиванием: подтверждённого материала хватило на безопасные 38,381 с, поэтому Content Budget хранит `compromisedInsufficientContent`. Это ожидаемое честное поведение, а не незавершённая генерация.

## Сохранность и откат

- Операционные backups созданы до записи оригинальных packages: `/Users/daniellineckij/Downloads/VeloEdit Editorial Backups/2026-09-08-before-productionization/`.
- `Мой фильм`: 2 Timeline, 2 checkpoints.
- `тест 3`: 3 Timeline, 5 checkpoints.
- `тест 2`: 2 Timeline, 1 checkpoint.
- Старые версии и история неудачных попыток сохранены для аудита; активной считается последняя успешно проверенная версия.
- Оригинальные media-файлы не перекодировывались и не перезаписывались.

## Исправленные production-дефекты

- устранён ложный pass при отсутствии evidence;
- закрыты framing/foreground/dominant-object домены реальными локальными измерениями;
- visual novelty достигает фиксированной точки после удаления дублей;
- титры автоматически усиливаются до контрастного статического шаблона либо удаляются только на проблемном интервале;
- source-duration repair ограничен одновременно candidate range и semantic usable range;
- lower Content Budget не ослабляется глобально;
- CLI `film` использует сохранённые `DirectorBrief`, canvas, requested duration и preset, поэтому вертикальный intent больше не теряется;
- системный audio decode больше не является обязательным путём для финального допуска: контроль выполняется по фактическому encoded mix;
- release больше не ждёт human-review flag.

## Проверка

- Полный тестовый набор после исправления concurrent open: **507 tests, 0 failures**, 75,145 с.
- Отдельный rendered regression corpus: **8/8 fixtures passed**.
- Все три production Timeline: Evidence V3, `findings = []`, mandatory failed/unknown = 0.
- Все 218 контрольных preview/export probes прошли; aspect ratio совпал, расхождение длительности каждого export меньше одного кадра.
- `./Scripts/build-app.sh` завершён успешно после последней правки application source.
- `Build/VeloEdit.app` переподписан; `codesign --verify --deep --strict` прошёл.
- Исполняемый файл финального bundle: 16 271 520 байт, timestamp `2026-09-10 15:47:29 +0300`.

## Неблокирующие последующие улучшения

Реальный human playback и blind evaluation не проводились и не записывались фиктивно. По решению владельца продукта они не входят в текущий activation gate. Реальные пользовательские оценки следует собирать как telemetry калибровки порогов, не останавливая работу уже активированного движка.

Полная сборка: `Build/VeloEdit.app`.  
Основное ТЗ: `Docs/EditorialIntelligenceProductionizationTZ.md`.
