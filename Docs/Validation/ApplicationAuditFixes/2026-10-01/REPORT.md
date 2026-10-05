# Исправления по аудиту VeloEdit от 1 октября 2026

Работа выполнена в `/Users/daniellineckij/VeloEdit`. Исходный аудит проверял отдельный commit `178296f09aa70ddf6e521df2358521a3e668e636`, без уже находившихся в основной папке изменений. Эти изменения сохранены. Исходные отчёты и проекты аудита не редактировались; ручные проверки выполнялись на копии проекта.

Основание: `DEFECTS.md`, `REPORT.md`, `COVERAGE.md` и связанный `AUTOMATED-CHECKS.md` из `/Users/daniellineckij/.codex/worktrees/9e94/VeloEdit/Docs/Validation/ApplicationAudit/2026-10-01`. Подтверждённые дефекты A01–A07 и отказы T01–T06 отделены от непроверенных сценариев и гипотез исходного аудита.

Итоговая сборка находится в **`/Users/daniellineckij/VeloEdit/Build/VeloEdit.app`**, build **2026.274.193122**. Исправления A01–A07 и T01–T06 внесены либо подтверждены как уже присутствующие в рабочей версии. На окончательных исходниках прошли **17 Core + 4 App целевых теста**, включая все исходные автоматические отказы и обнаруженные дополнительные регрессии. Полный зелёный прогон окончательного дерева целиком не заявляется.

Во время работы чат «Улучшить монтаж VeloEdit» менял общую папку. Для изоляции был создан промежуточный снимок `Build/AuditFinalSource` в 22:00:17 MSK; [хеши 680 файлов](final-snapshot-files.json) совпали до/после копирования. Его незавершённый Release-прогон обнаружил три отказа персонализации. К этому моменту параллельная работа уже завершилась и исправила два расчёта и пустой fixture. Эти изменения сохранены и перепроверены здесь на актуальном коде. Промежуточная сборка `2026.274.192256` не является итоговой; основной bundle пересобран после завершения другой работы.

## Исправления и подтверждения

| ID | Результат | Проверка |
| --- | --- | --- |
| A01 | Определения стилей перенесены внутрь титров, IDs уникальны. Исправлен UID установленного Basic Title, порядок marker/metadata и представление служебных дорожек. Подключённые титры/музыка/объекты вложены в основной клип с локальным offset: FCP молча отбрасывал их, если оставить соседями в spine. | Регрессионные тесты XML и установленная Apple FCPXML 1.11 DTD; фактический импорт в FCP 12.3 на отдельной библиотеке. Подтверждены 4 клипа, 18 секунд и редактируемый титр «Аудит 🎬 — Русский и Latin». |
| A02 | В текущей рабочей версии уже исправлена обработка выбора объектов таймлайна. Сохранено существующее исправление. | В UI выбран титр, затем последний видеоклип. Инспектор переключился на клип; Delete удалил именно его, оставив титр. Undo восстановил 18 секунд. Автотесты выбора, немедленных правок и истории. |
| A03 | Ограничена ширина панелей, вкладки библиотеки используют адаптивную сетку. Заголовок превью перестраивается в две строки, инструменты допускают горизонтальную прокрутку. | Окна 980×752 и 1280×802 pt с открытой боковой панелью. Библиотека, заголовок превью и экспорт находятся в своих панелях. |
| A04 | Отмена устанавливает итоговый статус, удаляет незавершённые пустые ответы и проверяется после подготовки AI перед продолжением создания. | `cancellingFilmRemovesPendingBubblesAndObsoleteStatus` и остальные `ReliabilityInteractionTests`; смена раздела не возвращает старый статус. |
| A05 | В проект сохраняется пофайловый результат импорта: добавление, дубликат, ошибка. Видны причины для пустых, повреждённых, неподдерживаемых и недоступных файлов; доступны сохранение отчёта и повтор пропущенных. | Смешанная папка с настоящим PNG, дубликатами и ошибками, повтор после исправления файла, повторное открытие проекта. Запись отчёта не меняет редакционную ревизию при импорте только дубликатов. |
| A06 | Кнопкам режимов AI заданы отдельные accessibilityLabel, value, hint и ID. | AX показывает «Быстрый», «Баланс», «Качество», «Максимально», выбранное состояние и индивидуальные подсказки. Полный сеанс VoiceOver не проводился. |
| A07 | Рендер карточек перенесён с UI executor в отдельный actor; ввод имеет debounce. Анимируется карточка под указателем. Подбор текста кэшируется с ограничением памяти, длинный текст сокращается двоичным поиском. | UI принимает повторные строки из 200 символов без пробелов на латинице/кириллице и многострочный emoji-текст; навигация отвечает. Автотесты всех шаблонов в 16:9 и 9:16, нескольких кадров, смены текста/стиля; существующие проверки parity preview/export. |
| T01, T03 | В текущей версии уже разделены предполагаемая BPM-сетка и измеренная синхронизация. Метаданные BPM сами по себе не обрезают клипы и не обещают подтверждённый beat snap. | Исходные тесты проходят; тест с измеренной структурой проверяет длительности 3,5 и 4,0 секунды и объяснение 120 BPM. |
| T02 | Существующее исправление учитывает обученную длительность в допустимом диапазоне исходников. | `learnedDurationAndMusicInfluenceRealAutonomousDecisionGradually` проходит. |
| T04 | Существующие изменения редакционного отбора сохранены. | Все 8 вариантов `editorialRegressionRunsThroughRenderedWinner`, включая MultiDayChapterFixture, проходят. |
| T05 | Существующее исправление покрытия групп событий сохранено. | `sourceTimelineRestoresTest3OrderAndKeepsBuggyFilesTogether` проходит. |
| T06 | Только тест, использующий Debug-only fault injection, ограждён `#if DEBUG` так же, как production hook. Остальные тесты восстановления остаются доступны Release. | Финальная проверка Release ниже. |

Дополнительно полный прогон обнаружил повторный расчёт признаков сцен при сравнении каждой пары материалов. `EventIntelligenceEngine` теперь строит один индекс на запуск. Существующий тест 320 материалов прошёл за **0,826 с** после результата **13,314 с** до исправления; лимит 12 с не изменялся. Это результаты отдельных запусков под текущей нагрузкой, не аттестация производительности Mac.

## Проверки и сборка

- **Окончательный код:** 17 Core + 4 App теста прошли без ошибок, Debug с оптимизацией `-O`. Среди них — новые проверки аудита, T01–T05, все 8 вариантов rendered winner, отмена, повторный импорт, анализ 320 материалов и три отказа промежуточного снимка: [current-final-targeted-tests.log](current-final-targeted-tests.log).
- **Release:** все тестовые модули промежуточного снимка успешно скомпилированы; 11 Core + 4 App целевых теста прошли. Тем самым подтверждено устранение T06: [final-release-tests.log](final-release-tests.log). После этого файл с условной компиляцией fault injection не менялся.
- **Первый полный Debug-прогон:** 847 зарегистрированных Core-тестов, 20 явных пропусков, 2 отказа; 31 App-тест, 2 явных пропуска, без отказов. Отказы ревизии после повторного импорта и лимита анализа 320 материалов исправлены и повторены успешно: [full-tests.log](full-tests.log), [final-targeted-tests.log](final-targeted-tests.log).
- **Незавершённые повторы:** [Debug](final-full-tests.log) и [Release промежуточного снимка](final-release-full-tests.log) остановлены после перехода к изменившемуся коду. Они не засчитываются как полные успешные прогоны. В Release зарегистрированы `personalizedScorerRewardsTasteButCannotHideTechnicalFailure`, `personalTasteInfluenceGrowsOnlyAfterRepeatedImplicitSignals`, `baseActuallyChangesDirectorDefaultsAndRespectsExplicitDuration`; все три проходят на итоговом коде. Первые два исправлены в расчётах личного влияния; третий получил достаточные исходники вместо требования 75 секунд из пустого набора, assertion сохранён.
- Исходные T01–T05 прошли ещё до новых правок: [baseline-tests.log](baseline-tests.log). Дополнительные проверки совместимости медиа и текста титров: [focused-tests.log](focused-tests.log).
- **FCPXML:** [Audit-final.fcpxml](Audit-final.fcpxml) импортирован в FCP как `VeloEdit Film — Editable 2`, reference — как `VeloEdit Film — Rendered Reference 1`. Обе последовательности доступны; 18 секунд, 4 клипа и редактируемый RU/Latin/emoji титр подтверждены: [UI](ui-verification.json), [DTD и ссылки](final-fcpxml-validation.json). Экспорт [Release CLI](Audit-release.fcpxml) также прошёл Apple DTD и структурно совпал с импортированным XML, кроме пути к новому reference-видео: [проверка](release-fcpxml-validation.json). Код экспортёра после этих проверок не менялся.
- **Полный основной `.app`:** `VELOEDIT_BUILD_CLI=1 ./Scripts/build-app.sh` выполнен успешно после завершения параллельной работы. `codesign --verify --deep --strict` успешен, Source SHA совпадает с текущей рабочей папкой: [лог](current-final-build-app.log), [проверка](current-final-build-verification.json). `git diff --check` без ошибок.

Итоговые идентификаторы:

- Build: `2026.274.193122`.
- Source SHA-256: `31e5bd338b876826ef9214d0763795ecf98d6b9d17cc7a18071916281b8f1262`.
- Executable SHA-256: `bfb0785ab54ca54d3cc191197321a24cf0454ecf5142c2d623285199689aa5cc`.

Команды последней целевой проверки и сборки из `/Users/daniellineckij/VeloEdit`:

```sh
VELOEDIT_DEV_SCRATCH_PATH=/tmp/veloedit-study-focused-swift \
  ./Scripts/dev-test.sh -c debug -Xswiftc -O --no-parallel \
  --filter 'ApplicationAuditRegressionTests|musicStructureMapsStoryEnergyAndBeatDensity|learnedDurationAndMusicInfluenceRealAutonomousDecisionGradually|generatedCutsSnapToTheSelectedLocalTracksBeatGrid|editorialRegressionRunsThroughRenderedWinner|sourceTimelineRestoresTest3OrderAndKeepsBuggyFilesTogether|ReliabilityInteractionTests|eventDiscoveryScalesToMoreThanThreeHundredAssetsWithoutPerAssetReclustering|duplicateImportDoesNotInvalidateFilmOrSourceMap|personalizedScorerRewardsTasteButCannotHideTechnicalFailure|personalTasteInfluenceGrowsOnlyAfterRepeatedImplicitSignals|BundledEditorialTasteTests'

VELOEDIT_BUILD_CLI=1 ./Scripts/build-app.sh
```

## Границы проверки

Использован один Mac с macOS 27.0 и synthetic-материалами. Проверки интерфейса выполнены на отдельной копии Release app с тестовым Bundle ID; для окончательной сборки используется штатный `Scripts/build-app.sh`. UI-инструмент дважды надолго задерживал запуск приложений, поэтому времена его вызовов не представлены как latency VeloEdit. Полная матрица `COVERAGE.md`, VoiceOver, субъективное прослушивание, реальные съёмки, все стадии отмены и другие версии macOS не объявляются пройденными. Перенос оформления сложных эффектов в native FCP не обещается: editable XML сохраняет метаданные, а rendered reference предназначен для визуального результата.
