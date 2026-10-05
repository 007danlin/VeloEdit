# Release

## Локальная сборка

```bash
./Scripts/build-app.sh
codesign --verify --deep --strict Build/VeloEdit.app
```

Без `VELOEDIT_CODESIGN_IDENTITY` создаётся ad-hoc signature для локальной разработки. Это не доверенная подпись разработчика Apple. `sign-app.py` подписывает все Mach-O файлы (включая FFmpeg, Ollama и библиотеки) изнутри наружу, затем приложение; `--deep` используется только при проверке. При Developer ID включаются hardened runtime и secure timestamp. Все вложенные подписи проверяются отдельно, в том числе код в Resources.

## Локальный установочный образ

```bash
python3 Scripts/build-distribution.py
```

Команда полностью пересобирает приложение и создаёт `Build/Distribution/VeloEdit-<version>-<build>-<arch>-local/` с DMG, SHA-256, инструкцией и `distribution.json`. В образе находятся `VeloEdit.app`, ссылка на `/Applications` и лицензии. Установка — перетаскивание приложения в Applications. Никаких фоновых установочных скриптов или изменений системных настроек нет.

После уже выполненного `./Scripts/build-app.sh` можно использовать `--skip-build` для локальной упаковки. Публичный выпуск эту опцию не допускает. Локальный DMG не нотариализован, помечен `local` и не предназначен для публичного распространения. Gatekeeper на другом Mac может заблокировать запуск. Скрипт не обходит Gatekeeper и не меняет quarantine у пользователя.

## Правообладатель и лицензии

Правообладатель: **Daniel L**, по указанию владельца проекта. Компания не обязательна. Имя и необязательный контакт хранятся в `Resources/Legal/publisher.json`; `bundle-legal.py` подставляет их в лицензию и copyright внутри приложения. Имя в сертификате Apple определяется данными Apple Developer Account и может отличаться от выбранного авторского имени.

`LICENSE.txt` в корне относится только к собственному коду и ресурсам. Условия для пользователя собираются из `Resources/Legal/LICENSE.txt`, а сведения о назначении сторонних компонентов — из `Resources/Legal/THIRD_PARTY.txt`. В приложении они доступны через **VeloEdit → Лицензия и компоненты…**. Исходные лицензии сохраняются; добавляется инвентаризация Rust-пакетов и точная конфигурация встроенного FFmpeg.

Текущая сборка включает GPL OVRLEY и FFmpeg с `--enable-gpl`; subprocess/JSON не доказывает юридическую независимость. Папка OVRLEY-Source сама по себе не доказывает полноту Corresponding Source, а ссылки Homebrew/FFmpeg — надлежащую доставку исходников. Уведомления о моделях и транзитивных native-зависимостях также требуют завершения аудита. Перед распространением нужно либо выполнить применимые условия и подтвердить совместимость интеграции, либо заменить соответствующие компоненты. Нельзя удалить чужое авторство или объявить чужие компоненты собственными.

Конкретные незакрытые проверки записаны в `Distribution/legal-review.json`. Публичный режим требует `status: approved` и путь `evidence` к непустому документу в репозитории для каждой проверки. Эти поля заполняются по результатам реальной проверки с зафиксированными версиями, изменениями, способом получения соответствующих исходников и уведомлениями. Сама отметка не создаёт прав и не заменяет проверку.

## Подписанный и нотариализованный выпуск

1. Зарегистрироваться в Apple Developer Program (можно как физическое лицо).
2. В Xcode → Settings → Accounts добавить свой аккаунт, создать или импортировать **Developer ID Application** с приватным ключом в Keychain. Для DMG сертификат Developer ID Installer не нужен; он относится к `.pkg`.
3. Создать профиль `notarytool` в Keychain через интерактивный ввод на своём Mac. Не передавать пароли/приватные ключи в чат или репозиторий:

```bash
xcrun notarytool store-credentials VeloEdit-notary
```

4. Завершить лицензионные проверки выше. Проверить готовность:

```bash
export VELOEDIT_CODESIGN_IDENTITY='Developer ID Application: YOUR LEGAL NAME (TEAMID)'
export VELOEDIT_NOTARY_PROFILE='VeloEdit-notary'
python3 Scripts/build-distribution.py --check
```

5. Собрать публичный выпуск (эта команда отправляет приложение и DMG в сервис нотариализации Apple):

```bash
python3 Scripts/build-distribution.py --release
```

Команда заново строит весь `.app`, проверяет подписи, нотариализует приложение, прикрепляет ticket, собирает и подписывает DMG, нотариализует и прикрепляет ticket к DMG. Успешными считаются только ответ Apple `Accepted`, успешная проверка tickets и Gatekeeper. Готовый каталог публикуется локально атомарно после проверок; при ошибке публичный DMG не выдаётся за готовый. Пароли берутся только из Keychain. Результаты нотариализации и контрольные суммы сохраняются рядом с образом.

Developer ID/hardened runtime требуют проверки запуска на чистом Mac, включая локальный AI, speech worker, телеметрию, импорт и экспорт. Пока нет аккаунта/сертификата, этот сетевой путь остаётся непроверенным; локальная ad-hoc сборка его не подтверждает.

Документация: [Apple Developer ID](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/), [подпись вложенного кода](https://developer.apple.com/library/archive/technotes/tn2206/_index.html), [нотариализация](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [GNU GPL FAQ](https://www.gnu.org/licenses/gpl-faq.en.html#MereAggregation), [FFmpeg](https://ffmpeg.org/legal.html).

## Release gates

- Все tests/build/CLI smoke проходят.
- Реальные import/proxy/preview/final workflows проверены на M4 Air.
- 10 fixtures импортированы в поддерживаемую версию Final Cut Pro.
- Third-party/model licenses зафиксированы.
- Privacy/network audit подтверждает offline default.
- Developer ID signature, notarization и Gatekeeper launch проверены на чистой системе.
