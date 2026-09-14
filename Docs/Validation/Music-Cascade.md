# Проверка музыкального каскада — 10 сентября 2026

Исходники и тесты скопированы в `/tmp/veloedit-cascade-verified`: параллельная задача меняла другие файлы проекта во время компиляции. Снимок позволяет проверить и собрать одну согласованную версию. Музыкальные исходники снимка сверяются с рабочим проектом.

## Реальная сеть

`VELOEDIT_LIVE_CASCADE_MUSIC_TEST=1 swift test --package-path /tmp/veloedit-cascade-verified --scratch-path /tmp/veloedit-cascade-tests --disable-sandbox --jobs 2 --filter MusicCascadeTests`

**10 тестов прошли, включая сетевой сценарий за 58,39 с.** Сетевая проверка специально использовала первую ступень, возвращающую HTTP 403, и только один настоящий резервный провайдер за раз. Встроенной музыки и общего кэша не было. Для повторного запроса исключались все идентификаторы первой песни.

| Источник | Реально скачанная запись | Фактическая длительность | Размер |
| --- | --- | ---: | ---: |
| Audionautix | Acoustic Guitar #1 | 174,42 с | 6 983 153 байта |
| Audionautix | Autumn Sunset | 96,31 с | 1 545 240 байт |
| Scott Buckley | Home Was You | 269,43 с | 10 779 404 байта |
| Scott Buckley | Echoes Of Home | 291,76 с | 11 672 796 байт |

У всех четырёх файлов проверены декодируемое аудио, длительность ≥45 с, непустая waveform, разные идентификаторы/названия и различающееся двоичное содержимое. Атрибуция CC BY 4.0 сохранена. Файлы теста временные и удалены после проверки.

Первый сетевой запуск воспроизвёл HTTP 406 на каталоге Audionautix. После исправления согласования формата ответа каталог и оба MP3 скачались через код приложения. На момент проверки ccMixter API отвечал, но три разных его MP3 вернули HTTP 403; провайдер не подключён.

VPN, прокси и DNS не переключались. Проверено текущее соединение, а не все операторы и регионы.

## Регрессия

Итоговый запуск всех музыкальных тестов, включая отдельную модель HTTP 406:

`swift test --package-path /tmp/veloedit-cascade-verified --scratch-path /tmp/veloedit-cascade-tests --disable-sandbox --jobs 2 --filter 'Music|Soundtrack'`

**84 теста прошли, 0 ошибок; выполнение тестов — 5,01 с.** Opt-in сценарии в обычном запуске выключены; реальное сетевое выполнение отдельно зафиксировано выше.

## Полный bundle

`VELOEDIT_SCRATCH_PATH=/tmp/veloedit-cascade-release ./Scripts/build-app.sh`

Рабочая директория: `/tmp/veloedit-cascade-verified`. **Полная release-сборка завершена успешно**, Swift — 146,29 с. Скрипт также собрал Rust bridge, включил ресурсы и проверил подпись полного VeloEdit.app.

Перед публикацией по SHA-256 сверены все исходники приложения, Resources и ThirdParty снимка с рабочим проектом: различий нет. Проверенный bundle опубликован атомарной заменой в оба места:

- `/Users/daniellineckij/VeloEdit/Build/VeloEdit.app`
- `/Users/daniellineckij/VeloEdit/Build/MusicSearch/VeloEdit.app`

Обе копии прошли `codesign --verify --deep --strict`; исполняемые файлы идентичны собранному снимку. SHA-256 исполняемого файла: `acc1e5498eb4229d7008971ac4b87b10702e0ec4cb6666a935090da0b67fc3b8`.

Хэши исходников и тестов: [Music-Cascade-Build-Source-Hashes.json](Music-Cascade-Build-Source-Hashes.json). Логи: [регрессия](Music-Cascade-Tests.log), [реальная сеть](Music-Cascade-Live.log), [сборка](Music-Cascade-Build.log).
